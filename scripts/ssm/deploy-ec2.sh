#!/usr/bin/env bash
set -euo pipefail

# Runs as root through AWS-RunShellScript on ONE instance (ADR 0006: BE, AI and FE each have their own
# instance). Arguments contain resource names, endpoints and an image tag; secret values are fetched
# on the instance with the instance role.
#
#   deploy-ec2.sh be IMAGE REGION APP_SECRET GHCR_SECRET RDS_SECRET_ARN RDS_ENDPOINT DB_NAME REDIS_HOST REDIS_PORT S3_BUCKET
#   deploy-ec2.sh ai IMAGE REGION GHCR_SECRET S3_BUCKET
#   deploy-ec2.sh fe IMAGE REGION GHCR_SECRET PUBLIC_HOST BE_UPSTREAM
#
# 포트 계약(보안그룹과 반드시 일치):
#   BE  호스트 8080 = 컨테이너 8080  ← be-sg가 fe-sg에서만 허용
#   AI  호스트 8000 = 컨테이너 8000  ← ai-sg가 be-sg에서만 허용
#   FE  호스트 80/443 = Caddy(엣지)  ← fe-sg가 인터넷에 공개. FE(nginx) 컨테이너는 포트를 게시하지 않는다.

be_name=voicebridge-be
ai_name=voicebridge-ai
fe_name=voicebridge-fe
edge_name=voicebridge-edge
edge_network=voicebridge-edge
be_port=8080
ai_port=8000
# 엣지(Caddy)가 Let's Encrypt 인증서를 자동 발급·갱신한다. 이미지는 환경에서만 덮어쓴다(테스트·고정용).
edge_image=${VB_EDGE_IMAGE:-caddy:2.10-alpine}
edge_dir=${VB_EDGE_DIR:-/opt/voicebridge/edge}
# 상태 데이터 볼륨(EBS) 마운트 위치. 테스트에서만 덮어쓴다.
data_root=${VB_DATA_ROOT:-/data}
ai_data_dir=$data_root/ai
pool_s3_key=ai/script_pool.json

# 헬스체크 대기 시간.
# BE: 2초 간격 90회 = 180초(기존 값 유지).
# AI: 5초 간격 120회 = 600초. 첫 기동에는 베이스 모델(whisper-small, 약 1GB)을 Hugging Face에서
#     내려받고 CPU로 로딩하는 시간이 들며, 서버는 모델 적재 후에 포트를 열므로 200이면 준비 완료다.
#     이미지 pull 시간은 이 대기와 별개다.
# FE: 2초 간격 60회 = 120초(nginx는 즉시 뜬다). HTTPS 확인은 5초 간격 36회 = 180초.
be_health_attempts=90
be_health_interval=2
ai_health_attempts=120
ai_health_interval=5
fe_health_attempts=60
fe_health_interval=2
https_attempts=36
https_interval=5

usage() {
  echo "Usage: $0 be IMAGE REGION APP_SECRET GHCR_SECRET RDS_SECRET_ARN RDS_ENDPOINT DB_NAME REDIS_HOST REDIS_PORT S3_BUCKET" >&2
  echo "       $0 ai IMAGE REGION GHCR_SECRET S3_BUCKET" >&2
  echo "       $0 fe IMAGE REGION GHCR_SECRET PUBLIC_HOST BE_UPSTREAM" >&2
  exit 2
}

[[ "$#" -ge 1 ]] || usage
component=$1
shift

case "$component" in
  be)
    [[ "$#" -eq 10 ]] || usage
    image=$1 region=$2 app_secret_id=$3 ghcr_secret_id=$4 rds_secret_arn=$5 rds_endpoint=$6
    db_name=$7 redis_host=$8 redis_port=$9 s3_bucket=${10}
    ;;
  ai)
    [[ "$#" -eq 4 ]] || usage
    image=$1 region=$2 ghcr_secret_id=$3 s3_bucket=$4
    ;;
  fe)
    [[ "$#" -eq 5 ]] || usage
    image=$1 region=$2 ghcr_secret_id=$3 public_host=$4 be_upstream=$5
    ;;
  *) usage ;;
esac

# 어느 컴포넌트든 조직 이름과 40자 SHA 태그를 가진 GHCR 이미지만 실행한다. 저장소 이름은
# Infra의 *_IMAGE_REPOSITORY 변수로 run.sh가 조립하므로 여기서는 형식만 확인한다.
if [[ ! "$image" =~ ^ghcr\.io/42voicebridge/[a-z0-9._-]+:sha-[0-9a-f]{40}$ ]]; then
  echo "Unexpected GHCR image name." >&2
  exit 2
fi
export AWS_REGION=$region

for tool in aws jq docker curl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
docker info >/dev/null

app_json='{}'
if [[ "$component" == be ]]; then
  app_json=$(aws secretsmanager get-secret-value --secret-id "$app_secret_id" --query SecretString --output text)
  jq -e 'type == "object"' <<<"$app_json" >/dev/null
fi

required_value() {
  local source=$1
  local key=$2
  local value
  value=$(jq -er --arg key "$key" '.[$key] | strings | select(length > 0)' <<<"$source") || {
    echo "Missing required secret field: $key" >&2
    return 1
  }
  printf '%s' "$value"
}

env_file=$(mktemp)
docker_config=$(mktemp -d)
chmod 600 "$env_file"
export DOCKER_CONFIG=$docker_config
trap 'rm -f -- "$env_file"; rm -rf -- "$docker_config"' EXIT

append_env() {
  local key=$1
  local value=$2
  if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Invalid value for $key" >&2
    return 1
  fi
  printf '%s=%s\n' "$key" "$value" >>"$env_file"
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

# 사용자 정의 bridge 네트워크에서만 컨테이너 이름 DNS가 동작한다(기본 bridge는 불가).
# FE 인스턴스에서 Caddy가 FE 컨테이너를 이름으로 찾는 용도로만 쓴다.
ensure_network() {
  if ! docker network inspect "$1" >/dev/null 2>&1; then
    docker network create "$1" >/dev/null
  fi
}

# --- GHCR 자격 증명 ------------------------------------------------------------

has_ghcr_creds() {
  [[ -n "$(jq -r '.GHCR_USERNAME // ""' <<<"$1")" || -n "$(jq -r '.GHCR_READ_TOKEN // ""' <<<"$1")" ]]
}

# GHCR 자격 증명은 전용 시크릿(GHCR_SECRET)에서 읽는다. BE만 전환 기간 동안 기존 앱 시크릿의
# GHCR_* 필드로 되돌아갈 수 있다(새 시크릿을 만들기 전에도 pull이 끊기지 않게 하는 폴백).
# AI와 FE는 앱 시크릿 읽기 권한이 없으므로 전용 시크릿이 반드시 있어야 한다.
load_ghcr_json() {
  local raw
  ghcr_json='{}'
  if raw=$(aws secretsmanager get-secret-value --secret-id "$ghcr_secret_id" --query SecretString --output text 2>/dev/null) \
    && jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    ghcr_json=$raw
    if [[ "$component" == be ]] && ! has_ghcr_creds "$ghcr_json" && has_ghcr_creds "$app_json"; then
      echo "WARNING: $ghcr_secret_id has no GHCR_* fields; falling back to the app secret (migration period)." >&2
      ghcr_json=$app_json
    fi
  elif [[ "$component" == be ]]; then
    echo "WARNING: could not read $ghcr_secret_id; falling back to GHCR_* in the app secret (migration period)." >&2
    ghcr_json=$app_json
  else
    echo "Cannot read the GHCR secret $ghcr_secret_id. Create it with GHCR_USERNAME and GHCR_READ_TOKEN." >&2
    return 1
  fi
}

ghcr_login() {
  local ghcr_user ghcr_token
  load_ghcr_json || return 1
  ghcr_user=$(jq -r '.GHCR_USERNAME // ""' <<<"$ghcr_json")
  ghcr_token=$(jq -r '.GHCR_READ_TOKEN // ""' <<<"$ghcr_json")
  if [[ -n "$ghcr_user" || -n "$ghcr_token" ]]; then
    if [[ -z "$ghcr_user" || -z "$ghcr_token" ]]; then
      echo "GHCR_USERNAME and GHCR_READ_TOKEN must both be set." >&2
      return 1
    fi
    printf '%s' "$ghcr_token" | docker login ghcr.io --username "$ghcr_user" --password-stdin >/dev/null
  fi
}

# --- 헬스체크 ------------------------------------------------------------------

# 컨테이너가 실행 중이고 호스트 8080이 어떤 HTTP 응답이든 반환하면 성공(BE에는 전용 health가 없다).
wait_be_healthy() {
  local response
  for _ in $(seq 1 "$be_health_attempts"); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$be_name")" != true ]]; then
      return 1
    fi
    response=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 2 "http://127.0.0.1:$be_port/" || true)
    if [[ "$response" != 000 && -n "$response" ]]; then
      return 0
    fi
    sleep "$be_health_interval"
  done
  return 1
}

# AI는 호스트 8000으로 게시되므로 로컬에서 직접 확인한다. 서버가 모델 적재 후에 포트를 열기 때문에
# 200이면 준비 완료다. 기동 실패로 재시작 루프에 들어간 경우(RestartCount > 0)는 모델 로딩 지연이
# 아니라 실패로 본다.
wait_ai_healthy() {
  local response restarts
  for _ in $(seq 1 "$ai_health_attempts"); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$ai_name")" != true ]]; then
      return 1
    fi
    restarts=$(docker inspect -f '{{.RestartCount}}' "$ai_name")
    if [[ "$restarts" != 0 ]]; then
      echo "AI container restarted $restarts time(s) while starting; check 'docker logs $ai_name'." >&2
      return 1
    fi
    response=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 3 "http://127.0.0.1:$ai_port/v1/health" || true)
    if [[ "$response" == 200 ]]; then
      return 0
    fi
    sleep "$ai_health_interval"
  done
  return 1
}

# FE(nginx) 컨테이너는 포트를 게시하지 않으므로 엣지 네트워크의 컨테이너 IP로 확인한다.
wait_fe_healthy() {
  local ip response
  for _ in $(seq 1 "$fe_health_attempts"); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$fe_name")" != true ]]; then
      return 1
    fi
    ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$edge_network\").IPAddress}}" "$fe_name" 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      response=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 "http://$ip:80/" || true)
      if [[ "$response" == 200 ]]; then
        return 0
      fi
    fi
    sleep "$fe_health_interval"
  done
  return 1
}

# Caddy는 설정 오류면 즉시 종료한다. 약 20초 동안 계속 실행 중이고 재시작이 없으면 성공으로 본다.
wait_edge_up() {
  local restarts
  for _ in $(seq 1 10); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$edge_name")" != true ]]; then
      return 1
    fi
    restarts=$(docker inspect -f '{{.RestartCount}}' "$edge_name")
    if [[ "$restarts" != 0 ]]; then
      return 1
    fi
    sleep 2
  done
  return 0
}

# --- 컨테이너 교체 -------------------------------------------------------------

# 이전 컨테이너를 이름만 바꿔 보관하고 새 컨테이너를 띄운다. 헬스체크 실패 시 복원한다.
#   deploy_container NAME HEALTH_FN DOCKER_RUN_ARGS...
deploy_container() {
  local name=$1 health_fn=$2
  shift 2
  local previous="$name-previous"
  local had_previous=false

  if container_exists "$previous"; then
    echo "Previous deployment container still exists; inspect it before retrying." >&2
    return 1
  fi
  if container_exists "$name"; then
    docker rename "$name" "$previous"
    docker stop "$previous" >/dev/null
    had_previous=true
  fi

  restore_previous() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    if [[ "$had_previous" == true ]]; then
      docker rename "$previous" "$name"
      docker start "$name" >/dev/null
      echo "Previous container restored." >&2
    fi
  }

  if ! docker run --detach --name "$name" --restart unless-stopped "$@" >/dev/null; then
    restore_previous
    return 1
  fi
  if ! "$health_fn"; then
    echo "New container $name did not become healthy." >&2
    restore_previous
    return 1
  fi
  if [[ "$had_previous" == true ]]; then
    docker rm "$previous" >/dev/null
  fi
}

# --- AI: 상태 데이터(/data/ai) 준비 --------------------------------------------

# /data가 별도 EBS 볼륨으로 마운트돼 있지 않으면 루트 디스크에 조용히 쓰게 되고,
# EC2 교체 시 모델 캐시와 어댑터가 사라진다. 그래서 마운트가 아니면 배포를 거부한다.
require_data_volume() {
  if ! mountpoint -q "$data_root"; then
    echo "$data_root is not a mounted volume. Check /var/log/voicebridge-data-volume.log." >&2
    return 1
  fi
}

# 이미지를 이미 pull한 뒤 호출한다(컨테이너 실행 사용자를 조회하기 때문).
prepare_ai_data() {
  local pool_local=$ai_data_dir/script_pool.json
  local pool_tmp ai_uid ai_gid

  # AI 서버는 /data 아래에 enroll, jobs를 직접 만들고(비루트 uid 10001) 어댑터·캐시를 쓴다.
  # 마운트한 최상위 디렉터리가 root 소유면 등록·학습 작업이 권한 오류로 실패하므로 같이 맞춘다.
  mkdir -p "$ai_data_dir/hf" "$ai_data_dir/adapters" "$ai_data_dir/enroll" "$ai_data_dir/jobs"

  # 프롬프트 풀은 코드·이미지에 없다. 로컬에 없을 때만 S3(ai/script_pool.json)에서 가져온다.
  # 이미 있는 파일은 덮어쓰지 않는다(갱신하려면 docs/AI-DEPLOYMENT.md 참고).
  if [[ ! -f "$pool_local" ]]; then
    if aws s3api head-object --bucket "$s3_bucket" --key "$pool_s3_key" >/dev/null 2>&1; then
      pool_tmp=$(mktemp "$ai_data_dir/.script_pool.XXXXXX")
      if aws s3 cp "s3://$s3_bucket/$pool_s3_key" "$pool_tmp" --no-progress >/dev/null \
        && jq -e . "$pool_tmp" >/dev/null; then
        chmod 0640 "$pool_tmp"
        mv -f -- "$pool_tmp" "$pool_local"
        echo "Prompt pool installed from s3://$s3_bucket/$pool_s3_key."
      else
        rm -f -- "$pool_tmp"
        echo "Prompt pool in S3 is not valid JSON or could not be downloaded." >&2
        return 1
      fi
    else
      echo "WARNING: $pool_local is missing and s3://$s3_bucket/$pool_s3_key does not exist." \
        "/v1/enroll/next-prompts will return 503 until the prompt pool is uploaded." >&2
    fi
  fi

  # 컨테이너 사용자가 root가 아니면 쓰기 권한이 필요하다. 이미지의 실행 사용자를 조회해 맞춘다.
  if ai_uid=$(docker run --rm --network none --entrypoint id "$image" -u 2>/dev/null) \
    && ai_gid=$(docker run --rm --network none --entrypoint id "$image" -g 2>/dev/null); then
    chown "$ai_uid:$ai_gid" "$ai_data_dir"
    chown -R "$ai_uid:$ai_gid" "$ai_data_dir/hf" "$ai_data_dir/adapters" \
      "$ai_data_dir/enroll" "$ai_data_dir/jobs"
    [[ ! -f "$pool_local" ]] || chown "$ai_uid:$ai_gid" "$pool_local"
  else
    echo "WARNING: could not read the AI container user; data directories keep root ownership." >&2
  fi
}

# --- FE: 엣지(Caddy) 설정 ------------------------------------------------------

# 공개 호스트와 BE 주소는 Terraform 출력에서 오지만 Caddyfile에 들어가므로 형식을 검증한다.
validate_edge_args() {
  if [[ ! "$public_host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "Invalid public host: $public_host" >&2
    return 1
  fi
  if [[ ! "$be_upstream" =~ ^http://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]]; then
    echo "Invalid BE upstream: $be_upstream" >&2
    return 1
  fi
}

# /api/* 는 BE로 그대로 넘기고(경로 접두사 제거 없음: BE가 /api/v1/**를 서비스한다), 나머지는 FE 컨테이너로 보낸다.
# 사이트 주소가 호스트 이름이면 Caddy가 Let's Encrypt 인증서를 자동 발급·갱신하고 http를 https로 리다이렉트한다.
write_caddyfile() {
  local tmp
  mkdir -p "$edge_dir"
  tmp=$(mktemp "$edge_dir/.Caddyfile.XXXXXX")
  cat >"$tmp" <<EOF
$public_host {
	encode gzip

	handle /api/* {
		reverse_proxy $be_upstream
	}

	handle {
		reverse_proxy $fe_name:80
	}
}
EOF
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$edge_dir/Caddyfile"
}

# 인증서 발급은 도메인/DNS/방화벽 같은 외부 요소에 달려 있다. 앱 컨테이너 자체는 정상이므로
# 실패해도 롤백하지 않고 경고로 남긴다(운영자가 docker logs로 원인을 확인한다).
verify_https() {
  local response
  for _ in $(seq 1 "$https_attempts"); do
    response=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
      --resolve "$public_host:443:127.0.0.1" "https://$public_host/" || true)
    if [[ "$response" == 200 ]]; then
      echo "HTTPS verified for $public_host (trusted certificate)."
      return 0
    fi
    sleep "$https_interval"
  done
  echo "WARNING: HTTPS for $public_host was not verified. Check 'docker logs $edge_name'" \
    "(DNS must resolve to this instance and port 80 must be reachable for Let's Encrypt)." >&2
  return 0
}

# --- 배포 ----------------------------------------------------------------------

ghcr_login

case "$component" in
  be)
    rds_json=$(aws secretsmanager get-secret-value --secret-id "$rds_secret_arn" --query SecretString --output text)
    jq -e 'type == "object"' <<<"$rds_json" >/dev/null

    append_env SPRING_PROFILES_ACTIVE prod
    append_env DB_URL "jdbc:mysql://$rds_endpoint/$db_name?serverTimezone=Asia/Seoul&characterEncoding=UTF-8"
    append_env DB_USERNAME "$(required_value "$rds_json" username)"
    append_env DB_PASSWORD "$(required_value "$rds_json" password)"
    append_env REDIS_HOST "$redis_host"
    append_env REDIS_PORT "$redis_port"
    append_env S3_BUCKET "$s3_bucket"
    append_env AWS_REGION "$region"
    append_env JWT_SECRET "$(required_value "$app_json" JWT_SECRET)"
    append_env NCP_TTS_API_KEY_ID "$(required_value "$app_json" NCP_TTS_API_KEY_ID)"
    append_env NCP_TTS_API_KEY "$(required_value "$app_json" NCP_TTS_API_KEY)"

    ai_base_url=$(jq -er '.AI_SERVER_BASE_URL // "" | if type == "string" then . else error("AI_SERVER_BASE_URL must be a string") end' <<<"$app_json")
    if [[ -n "$ai_base_url" ]]; then
      append_env AI_SERVER_BASE_URL "$ai_base_url"
    else
      echo "AI_SERVER_BASE_URL is unset; AI-dependent endpoints will be unavailable."
    fi

    docker pull "$image" >/dev/null
    deploy_container "$be_name" wait_be_healthy \
      --publish "$be_port:$be_port" --env-file "$env_file" "$image"
    echo "Deployed $image; HTTP endpoint responded on port $be_port."
    ;;
  ai)
    require_data_volume
    docker pull "$image" >/dev/null
    prepare_ai_data

    # 호스트의 /data/ai를 컨테이너의 /data로 마운트하면 AI 이미지가 기대하는 경로
    # (/data/hf, /data/adapters, /data/enroll, /data/jobs, /data/script_pool.json)가 그대로 유지된다.
    # 8000은 ai-sg가 be-sg에게만 연다. 로그는 디스크를 채우지 않게 순환시킨다.
    # ALLOW_CPU_TRAIN=1: GPU 없이 CPU로 개인화 학습을 허용한다. AI팀 실측에서 CPU 학습은
    # 17.6분(GPU 18초)이고 어댑터가 바이트 단위로 동일해 느리지만 쓸 수 있는 경로다. 이 값이
    # 없으면 학습기가 CPU 실행을 거부한다.
    deploy_container "$ai_name" wait_ai_healthy \
      --publish "$ai_port:$ai_port" \
      --volume "$ai_data_dir:/data" --env HF_HOME=/data/hf --env ALLOW_CPU_TRAIN=1 \
      --log-opt max-size=10m --log-opt max-file=3 "$image"
    echo "Deployed $image; /v1/health returned 200."
    ;;
  fe)
    validate_edge_args
    ensure_network "$edge_network"
    docker pull "$image" >/dev/null
    docker pull "$edge_image" >/dev/null

    deploy_container "$fe_name" wait_fe_healthy --network "$edge_network" "$image"

    # Caddy 설정이나 이미지가 바뀌었을 수 있으므로 엣지는 매번 교체한다. 인증서는 명명된 볼륨에 보관한다.
    write_caddyfile
    deploy_container "$edge_name" wait_edge_up \
      --network "$edge_network" --publish 80:80 --publish 443:443 \
      --volume "$edge_dir/Caddyfile:/etc/caddy/Caddyfile:ro" \
      --volume voicebridge-caddy-data:/data --volume voicebridge-caddy-config:/config \
      "$edge_image"
    echo "Deployed $image behind $edge_image for $public_host."
    verify_https
    ;;
esac
