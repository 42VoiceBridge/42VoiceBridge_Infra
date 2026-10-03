#!/usr/bin/env bash
# deploy-ec2.sh 동작 테스트. 실제 Docker/AWS 없이 PATH 앞에 스텁(docker, aws, curl, mountpoint,
# sleep, chown)을 두고 컨테이너 상태를 파일로 흉내 낸다. 실행: bash scripts/ssm/test/deploy-ec2.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
script=${DEPLOY_SCRIPT:-$repo_root/scripts/ssm/deploy-ec2.sh}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

SHA_A=$(printf 'a%.0s' {1..40})
SHA_B=$(printf 'b%.0s' {1..40})
SHA_C=$(printf 'c%.0s' {1..40})
BE_IMAGE=ghcr.io/42voicebridge/42voicebridge_be:sha-$SHA_A
AI_IMAGE=ghcr.io/42voicebridge/42voicebridge_ai:sha-$SHA_B
FE_IMAGE=ghcr.io/42voicebridge/42voicebridge_fe:sha-$SHA_C
APP_JSON='{"JWT_SECRET":"jwt-value","NCP_TTS_API_KEY_ID":"ncp-id","NCP_TTS_API_KEY":"ncp-key"}'
RDS_JSON='{"username":"dbuser","password":"dbpass"}'
GHCR_JSON='{"GHCR_USERNAME":"ghuser","GHCR_READ_TOKEN":"tok-secret"}'

pass=0 fail=0

# --- 스텁 --------------------------------------------------------------------
make_stubs() {
  local bin=$work/bin
  mkdir -p "$bin"

  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
S=$STUB_STATE
echo "docker $*" >>"$S/docker.log"
touch "$S/containers" "$S/networks"
case "$1" in
  info) exit 0 ;;
  ps) cat "$S/containers" ;;
  network)
    case "$2" in
      inspect) grep -Fxq "$3" "$S/networks" ;;
      create) echo "$3" >>"$S/networks" ;;
    esac ;;
  login) cat >"$S/login_stdin" ;;
  pull) exit 0 ;;
  rename) sed -i "s/^$2\$/$3/" "$S/containers" ;;
  stop|start) exit 0 ;;
  rm)
    name=${@: -1}
    sed -i "/^$name\$/d" "$S/containers" ;;
  run)
    if [[ " $* " == *" --entrypoint id "* ]]; then
      [[ -z "${STUB_NO_ID:-}" ]] || exit 1
      [[ "${@: -1}" == -u ]] && echo "${STUB_UID:-1000}" || echo "${STUB_GID:-1000}"
      exit 0
    fi
    [[ -z "${STUB_RUN_FAIL:-}" ]] || exit 1
    args=("$@")
    for i in "${!args[@]}"; do
      case "${args[$i]}" in
        --name) echo "${args[$((i+1))]}" >>"$S/containers" ;;
        --env-file) cp "${args[$((i+1))]}" "$S/env_file_copy" ;;
      esac
    done ;;
  inspect)
    fmt=$3
    name=${@: -1}
    case "$fmt" in
      *Running*)
        if [[ "$name" == voicebridge-edge && -n "${STUB_EDGE_RUNNING:-}" ]]; then echo "$STUB_EDGE_RUNNING"
        elif [[ "$name" == voicebridge-fe && -n "${STUB_FE_RUNNING:-}" ]]; then echo "$STUB_FE_RUNNING"
        else echo "${STUB_RUNNING:-true}"; fi ;;
      *RestartCount*) echo "${STUB_RESTARTS:-0}" ;;
      *IPAddress*) echo 172.18.0.5 ;;
    esac ;;
esac
STUB

  cat >"$bin/aws" <<'STUB'
#!/usr/bin/env bash
S=$STUB_STATE
echo "aws $*" >>"$S/aws.log"
case "$1 $2" in
  "secretsmanager get-secret-value")
    case "$*" in
      *rds-secret*) echo "$STUB_RDS_JSON" ;;
      *ghcr-secret*)
        [[ -z "${STUB_GHCR_MISSING:-}" ]] || exit 254
        echo "$STUB_GHCR_JSON" ;;
      *) echo "$STUB_APP_JSON" ;;
    esac ;;
  "s3api head-object") [[ -n "${STUB_POOL_CONTENT+x}" ]] ;;
  "s3 cp") printf '%s' "$STUB_POOL_CONTENT" >"$4" ;;
esac
STUB

  cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
echo "curl $*" >>"$STUB_STATE/curl.log"
case "$url" in
  https://*) printf '%s' "${STUB_HTTPS:-200}" ;;
  http://127.0.0.1:8000/v1/health) printf '%s' "${STUB_AI_HEALTH:-200}" ;;
  http://127.0.0.1:8080/) printf '%s' "${STUB_BE_HTTP:-200}" ;;
  http://172.18.0.5:80/) printf '%s' "${STUB_FE_HTTP:-200}" ;;
  *) printf '000' ;;
esac
STUB

  cat >"$bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_MOUNTED:-1}" == 1 ]]
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
  # shellcheck disable=SC2016  # 스텁 본문에서 변수를 펼치지 않는 것이 의도다
  printf '#!/usr/bin/env bash\necho "chown $*" >>"$STUB_STATE/chown.log"\n' >"$bin/chown"
  chmod +x "$bin"/*
}

# run_deploy ARGS... — 격리된 상태 디렉터리에서 스크립트를 실행하고 stdout/stderr/종료코드를 저장한다.
run_deploy() {
  export STUB_STATE=$work/state
  rm -rf "$STUB_STATE" "$work/data" "$work/edge"
  mkdir -p "$STUB_STATE" "$work/data"
  [[ -z "${PRESET_CONTAINERS:-}" ]] || printf '%s\n' "$PRESET_CONTAINERS" >"$STUB_STATE/containers"
  export STUB_APP_JSON=${STUB_APP_JSON:-$APP_JSON} STUB_RDS_JSON=$RDS_JSON STUB_GHCR_JSON=${STUB_GHCR_JSON:-$GHCR_JSON}
  PATH=$work/bin:$PATH VB_DATA_ROOT=$work/data VB_EDGE_DIR=$work/edge VB_EDGE_IMAGE=caddy:test \
    bash "$script" "$@" >"$work/out" 2>"$work/err"
  rc=$?
}

reset_env() {
  unset STUB_NO_ID STUB_RUN_FAIL STUB_RUNNING STUB_RESTARTS STUB_POOL_CONTENT STUB_AI_HEALTH \
    STUB_BE_HTTP STUB_FE_HTTP STUB_HTTPS STUB_MOUNTED STUB_UID STUB_GID PRESET_CONTAINERS \
    STUB_GHCR_MISSING STUB_EDGE_RUNNING STUB_FE_RUNNING
  export STUB_APP_JSON=$APP_JSON STUB_GHCR_JSON=$GHCR_JSON
}

check() { # check DESCRIPTION CONDITION...
  local desc=$1
  shift
  if "$@"; then
    pass=$((pass + 1)); echo "  ok   - $desc"
  else
    fail=$((fail + 1)); echo "  FAIL - $desc"
  fi
}
rc_is() { [[ "$rc" == "$1" ]]; }
log_has() { grep -Fq -- "$1" "$STUB_STATE/docker.log" 2>/dev/null; }
log_lacks() { ! log_has "$1"; }
err_has() { grep -Fq -- "$1" "$work/err"; }
out_has() { grep -Fq -- "$1" "$work/out"; }
out_lacks() { ! grep -Fq -- "$1" "$work/out" "$work/err"; }
container_exists() { grep -Fxq "$1" "$STUB_STATE/containers" 2>/dev/null; }
container_absent() { ! container_exists "$1"; }
run_line() { grep -F -- "docker run" "$STUB_STATE/docker.log" | grep -F -- "--name $1 " | head -1; }
run_has() { run_line "$1" | grep -Fq -- "$2"; }
run_lacks() { ! run_has "$1" "$2"; }

make_stubs
be_args=(be "$BE_IMAGE" ap-northeast-2 app-secret ghcr-secret rds-secret rds.example:3306 voicebridge redis.example 6379 bucket-x)
ai_args=(ai "$AI_IMAGE" ap-northeast-2 ghcr-secret bucket-x)
fe_args=(fe "$FE_IMAGE" ap-northeast-2 ghcr-secret ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com http://10.0.1.10:8080)

echo "인자·이미지 검증"
reset_env; run_deploy
check "인자 없음 → 사용법 출력, 종료코드 2" rc_is 2
reset_env; run_deploy nope
check "알 수 없는 컴포넌트 → 종료코드 2" rc_is 2
reset_env; run_deploy be ghcr.io/evil/x:sha-1 r s g r e d h p b
check "다른 조직의 이미지 → 종료코드 2" rc_is 2
reset_env; run_deploy ai "ghcr.io/42voicebridge/42voicebridge_ai:latest" r g b
check "sha 태그가 아닌 이미지 거부(latest)" rc_is 2
reset_env; run_deploy ai "ghcr.io/42voicebridge/42voicebridge_ai:sha-${SHA_B:0:7}" r g b
check "7자 단축 SHA 태그 거부" rc_is 2
reset_env; run_deploy ai "$AI_IMAGE" r g
check "AI 인자 개수 부족 → 종료코드 2" rc_is 2
reset_env; run_deploy fe "$FE_IMAGE" r g host
check "FE 인자 개수 부족 → 종료코드 2" rc_is 2
reset_env; run_deploy be "$BE_IMAGE" r a g
check "BE 인자 개수 부족 → 종료코드 2" rc_is 2

echo "AI 배포 — 정상 경로"
reset_env; STUB_POOL_CONTENT='{"prompts":["a"]}' run_deploy "${ai_args[@]}"
check "종료코드 0" rc_is 0
check "AI 8000을 호스트 8000으로 게시(be-sg가 BE에서만 허용)" run_has voicebridge-ai "--publish 8000:8000"
check "Docker 사용자 정의 네트워크를 쓰지 않음" run_lacks voicebridge-ai "--network"
check "네트워크를 만들지 않음" log_lacks "network create"
check "호스트 /data/ai를 컨테이너 /data로 마운트" run_has voicebridge-ai "--volume $work/data/ai:/data"
check "HF_HOME=/data/hf 지정" run_has voicebridge-ai "HF_HOME=/data/hf"
check "CPU 학습 허용(ALLOW_CPU_TRAIN=1)" run_has voicebridge-ai "ALLOW_CPU_TRAIN=1"
check "로그 순환 옵션" run_has voicebridge-ai "max-size=10m"
check "AI 컨테이너 존재" container_exists voicebridge-ai
check "hf/adapters/enroll/jobs 디렉터리 생성" test -d "$work/data/ai/hf" -a -d "$work/data/ai/adapters" -a -d "$work/data/ai/enroll" -a -d "$work/data/ai/jobs"
check "S3의 프롬프트 풀이 설치됨" test "$(cat "$work/data/ai/script_pool.json" 2>/dev/null)" = '{"prompts":["a"]}'
check "마운트 최상위 /data/ai도 컨테이너 사용자 소유(앱이 enroll·jobs를 직접 생성)" grep -Fq "chown 1000:1000 $work/data/ai" "$STUB_STATE/chown.log"
check "enroll·jobs도 chown 대상" grep -Fq "$work/data/ai/jobs" "$STUB_STATE/chown.log"
check "BE·FE 컨테이너는 건드리지 않음" container_absent voicebridge-be
check "앱 시크릿을 읽지 않음(AI 역할에는 읽기 권한이 없다)" bash -c "! grep -q 'app-secret' '$STUB_STATE/aws.log'"

echo "AI 배포 — /data 미마운트"
reset_env; STUB_MOUNTED=0 run_deploy "${ai_args[@]}"
check "종료코드 1" rc_is 1
check "미마운트 사유 출력" err_has "not a mounted volume"
check "이미지 pull 전에 실패(빠른 실패)" log_lacks "docker pull"
check "컨테이너를 만들지 않음" container_absent voicebridge-ai

echo "AI 배포 — 프롬프트 풀"
reset_env; run_deploy "${ai_args[@]}"
check "S3에 풀이 없어도 배포는 성공" rc_is 0
check "503 경고 출력" err_has "503"
reset_env; STUB_POOL_CONTENT='not json' run_deploy "${ai_args[@]}"
check "S3 풀이 JSON이 아니면 실패" rc_is 1
check "손상된 풀은 설치하지 않음" test ! -f "$work/data/ai/script_pool.json"

echo "AI 배포 — 헬스체크·롤백"
reset_env; STUB_AI_HEALTH=503 run_deploy "${ai_args[@]}"
check "헬스 실패 → 종료코드 1" rc_is 1
check "신규 컨테이너 제거(이전 없음)" container_absent voicebridge-ai
reset_env; STUB_RESTARTS=2 run_deploy "${ai_args[@]}"
check "재시작 루프 → 실패" rc_is 1
check "재시작 사유 출력" err_has "restarted 2 time(s)"
reset_env; PRESET_CONTAINERS="voicebridge-ai" STUB_AI_HEALTH=503 run_deploy "${ai_args[@]}"
check "이전 컨테이너가 있는 상태에서 헬스 실패 → 종료코드 1" rc_is 1
check "이전 컨테이너 복원(voicebridge-ai 유지)" container_exists voicebridge-ai
check "복원한 컨테이너를 다시 시작" log_has "docker start voicebridge-ai"
check "voicebridge-ai-previous 정리됨" container_absent voicebridge-ai-previous
reset_env; PRESET_CONTAINERS="voicebridge-ai" run_deploy "${ai_args[@]}"
check "재배포 성공" rc_is 0
check "성공 후 previous 제거" container_absent voicebridge-ai-previous
reset_env; PRESET_CONTAINERS="voicebridge-ai-previous" run_deploy "${ai_args[@]}"
check "이전 배포 잔여 컨테이너가 있으면 거부" rc_is 1
reset_env; STUB_RUN_FAIL=1 run_deploy "${ai_args[@]}"
check "docker run 실패 → 종료코드 1" rc_is 1
reset_env; STUB_NO_ID=1 run_deploy "${ai_args[@]}"
check "id 조회 불가여도 경고 후 진행" rc_is 0
check "경고 출력" err_has "could not read the AI container user"

echo "BE 배포"
reset_env; run_deploy "${be_args[@]}"
check "종료코드 0" rc_is 0
check "BE는 호스트 8080 = 컨테이너 8080 (be-sg 8080과 일치)" run_has voicebridge-be "--publish 8080:8080"
check "예전 80:8080 매핑이 남아 있지 않음" run_lacks voicebridge-be "--publish 80:8080"
check "Docker 네트워크를 만들지 않음" log_lacks "network create"
check "env-file 사용" grep -q 'JWT_SECRET=jwt-value' "$STUB_STATE/env_file_copy"
check "DB 접속 정보가 env-file에 들어감" grep -q 'DB_PASSWORD=dbpass' "$STUB_STATE/env_file_copy"
check "AI_SERVER_BASE_URL 미설정 시 env-file에 없음" bash -c "! grep -q AI_SERVER_BASE_URL '$STUB_STATE/env_file_copy'"
check "시크릿 값이 출력에 노출되지 않음" out_lacks "jwt-value"
check "시크릿 값이 docker 명령줄에 노출되지 않음" log_lacks "dbpass"
check "헬스체크를 8080으로 수행" grep -Fq "http://127.0.0.1:8080/" "$STUB_STATE/curl.log"
check "AI·FE 컨테이너는 건드리지 않음" container_absent voicebridge-ai
reset_env; STUB_APP_JSON='{"JWT_SECRET":"j","NCP_TTS_API_KEY_ID":"i","NCP_TTS_API_KEY":"k","AI_SERVER_BASE_URL":"http://10.0.1.20:8000"}' run_deploy "${be_args[@]}"
check "AI_SERVER_BASE_URL을 시크릿에서 그대로 전달(고정 사설 IP)" grep -Fxq 'AI_SERVER_BASE_URL=http://10.0.1.20:8000' "$STUB_STATE/env_file_copy"
reset_env; STUB_APP_JSON='{"JWT_SECRET":"j"}' run_deploy "${be_args[@]}"
check "필수 시크릿 필드 누락 → 실패" rc_is 1
check "누락 시 이미지 pull 전에 실패" log_lacks "docker pull"
reset_env; STUB_BE_HTTP=000 run_deploy "${be_args[@]}"
check "BE가 응답하지 않으면 실패" rc_is 1
check "BE 신규 컨테이너 제거" container_absent voicebridge-be
reset_env; PRESET_CONTAINERS="voicebridge-be" STUB_BE_HTTP=000 run_deploy "${be_args[@]}"
check "BE 이전 컨테이너 복원" container_exists voicebridge-be
check "BE 복원 컨테이너를 다시 시작" log_has "docker start voicebridge-be"

echo "FE 배포 (nginx + Caddy 엣지)"
reset_env; run_deploy "${fe_args[@]}"
check "종료코드 0" rc_is 0
check "엣지 전용 네트워크 생성" log_has "network create voicebridge-edge"
check "FE(nginx) 컨테이너는 포트를 게시하지 않음" run_lacks voicebridge-fe "--publish"
check "FE 컨테이너가 엣지 네트워크에 연결" run_has voicebridge-fe "--network voicebridge-edge"
check "엣지가 80과 443을 게시" bash -c "grep -F -- '--name voicebridge-edge ' '$STUB_STATE/docker.log' | grep -F -- '--publish 80:80' | grep -Fq -- '--publish 443:443'"
check "인증서 보관용 명명된 볼륨" run_has voicebridge-edge "--volume voicebridge-caddy-data:/data"
check "Caddyfile을 읽기 전용으로 마운트" run_has voicebridge-edge "$work/edge/Caddyfile:/etc/caddy/Caddyfile:ro"
check "엣지 이미지를 pull" log_has "docker pull caddy:test"
check "Caddyfile에 공개 호스트(인증서 자동 발급 대상)" grep -Fq "ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com {" "$work/edge/Caddyfile"
check "/api/*는 BE 사설 IP:8080으로 그대로 프록시" grep -Fq "reverse_proxy http://10.0.1.10:8080" "$work/edge/Caddyfile"
check "나머지는 FE 컨테이너 80으로" grep -Fq "reverse_proxy voicebridge-fe:80" "$work/edge/Caddyfile"
check "경로 접두사 제거 설정이 없음(BE가 /api/v1/**를 서비스)" bash -c "! grep -Eq 'strip_prefix|uri ' '$work/edge/Caddyfile'"
check "HTTPS 검증 성공 메시지" out_has "HTTPS verified"
check "Docker Hub 이미지를 --resolve로 로컬에서 검증" grep -Fq -- "--resolve ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com:443:127.0.0.1" "$STUB_STATE/curl.log"
reset_env; STUB_HTTPS=000 run_deploy "${fe_args[@]}"
check "HTTPS가 검증되지 않아도 배포는 성공(앱은 정상)" rc_is 0
check "HTTPS 미검증 경고 출력" err_has "HTTPS for"
check "엣지 컨테이너는 유지됨" container_exists voicebridge-edge
reset_env; STUB_FE_HTTP=503 run_deploy "${fe_args[@]}"
check "FE 헬스 실패 → 종료코드 1" rc_is 1
check "FE 실패 시 엣지를 시작하지 않음" container_absent voicebridge-edge
check "FE 실패 시 Caddyfile을 쓰지 않음" test ! -f "$work/edge/Caddyfile"
reset_env; STUB_EDGE_RUNNING=false run_deploy "${fe_args[@]}"
check "엣지가 즉시 종료(설정 오류 등) → 종료코드 1" rc_is 1
check "엣지 신규 컨테이너 제거" container_absent voicebridge-edge
reset_env; run_deploy fe "$FE_IMAGE" r ghcr-secret 'bad host;rm -rf /' http://10.0.1.10:8080
check "호스트 이름에 명령 삽입 시도 → 거부" rc_is 1
check "거부 시 컨테이너를 만들지 않음" container_absent voicebridge-fe
reset_env; run_deploy fe "$FE_IMAGE" r ghcr-secret host.example.com 'http://evil.example.com:8080'
check "BE 업스트림이 사설 IP 형식이 아니면 거부" rc_is 1
reset_env; run_deploy fe "$FE_IMAGE" r ghcr-secret $'host.example.com\nevil' http://10.0.1.10:8080
check "개행이 든 호스트 거부" rc_is 1
reset_env; PRESET_CONTAINERS="voicebridge-fe" STUB_FE_HTTP=503 run_deploy "${fe_args[@]}"
check "FE 이전 컨테이너 복원" container_exists voicebridge-fe

echo "GHCR 인증 (전용 시크릿)"
reset_env; run_deploy "${ai_args[@]}"
check "AI도 같은 GHCR 시크릿으로 로그인" log_has "docker login ghcr.io --username ghuser --password-stdin"
check "토큰은 stdin으로만 전달" test "$(cat "$STUB_STATE/login_stdin")" = tok-secret
check "토큰이 명령줄·출력에 노출되지 않음" bash -c "! grep -q 'tok-secret' '$STUB_STATE/docker.log' '$work/out' '$work/err'"
reset_env; run_deploy "${fe_args[@]}"
check "FE도 GHCR 시크릿으로 로그인" log_has "docker login ghcr.io --username ghuser"
reset_env; STUB_GHCR_JSON='{"GHCR_USERNAME":"ghuser"}' run_deploy "${ai_args[@]}"
check "GHCR 필드가 하나만 있으면 실패" rc_is 1
reset_env; STUB_GHCR_MISSING=1 run_deploy "${ai_args[@]}"
check "AI는 GHCR 시크릿이 없으면 실패(폴백 없음)" rc_is 1
check "시크릿 생성 안내 출력" err_has "Create it with GHCR_USERNAME"
reset_env; STUB_GHCR_MISSING=1 run_deploy "${fe_args[@]}"
check "FE도 GHCR 시크릿이 없으면 실패" rc_is 1

echo "GHCR 인증 — BE 전환 기간 폴백"
reset_env; run_deploy "${be_args[@]}"
check "전용 시크릿이 있으면 그 값으로 로그인" log_has "docker login ghcr.io --username ghuser"
check "전용 시크릿 사용 시 폴백 경고 없음" bash -c "! grep -q 'falling back' '$work/err'"
reset_env; STUB_GHCR_MISSING=1 STUB_APP_JSON='{"JWT_SECRET":"j","NCP_TTS_API_KEY_ID":"i","NCP_TTS_API_KEY":"k","GHCR_USERNAME":"olduser","GHCR_READ_TOKEN":"old-token"}' run_deploy "${be_args[@]}"
check "전용 시크릿이 아직 없으면 기존 앱 시크릿 값으로 로그인(pull 유지)" log_has "docker login ghcr.io --username olduser"
check "폴백 경고 출력" err_has "falling back"
check "BE 배포 성공" rc_is 0
reset_env; STUB_GHCR_JSON='{}' STUB_APP_JSON='{"JWT_SECRET":"j","NCP_TTS_API_KEY_ID":"i","NCP_TTS_API_KEY":"k","GHCR_USERNAME":"olduser","GHCR_READ_TOKEN":"old-token"}' run_deploy "${be_args[@]}"
check "전용 시크릿이 비어 있고 앱 시크릿에 값이 있으면 폴백" log_has "docker login ghcr.io --username olduser"
reset_env; STUB_GHCR_MISSING=1 run_deploy "${be_args[@]}"
check "양쪽 모두 자격 증명이 없으면(공개 패키지) 로그인 없이 진행" bash -c "! grep -q 'docker login' '$STUB_STATE/docker.log'"

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
