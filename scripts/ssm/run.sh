#!/usr/bin/env bash
set -euo pipefail

# 사용법: run.sh check|measure|deploy|redeploy [BE SHA] [AI SHA] [FE SHA]
#   check    세 인스턴스의 SSM 연결, Docker, (AI) /data 마운트를 확인한다.
#   measure  세 인스턴스의 메모리·CPU·디스크·컨테이너 사용량을 수집해 출력한다(사양 확정용, 읽기 전용).
#   deploy   지정한 컴포넌트의 이미지만 해당 인스턴스에 배포한다. 순서는 AI → BE → FE.
#            앞 컴포넌트가 실패하면 뒤 컴포넌트는 배포하지 않는다.
#   redeploy 컴포넌트별로 마지막에 성공한 배포(SSM Parameter Store 기록)를 다시 배포한다.
#            Terraform apply가 인스턴스를 교체한 뒤 새 인스턴스를 최신 상태로 맞추는 용도다.

mode=${1:-}
be_sha=${2:-}
ai_sha=${3:-}
fe_sha=${4:-}
region=${AWS_REGION:-ap-northeast-2}
application_dir=infra/environments/dev/3_application
storage_dir=infra/environments/dev/2_storage
param_prefix=${VB_PARAM_PREFIX:-/voicebridge/dev/deployed}

# 이미지 저장소 경로는 Infra 저장소 Variables(BE_/AI_/FE_IMAGE_REPOSITORY)에서 받는다.
# 비어 있으면 기본 이름을 쓴다. 이벤트 payload의 이미지 경로는 신뢰하지 않고 SHA만 쓴다.
be_repo=${BE_IMAGE_REPOSITORY:-ghcr.io/42voicebridge/42voicebridge_be}
ai_repo=${AI_IMAGE_REPOSITORY:-ghcr.io/42voicebridge/42voicebridge_ai}
fe_repo=${FE_IMAGE_REPOSITORY:-ghcr.io/42voicebridge/42voicebridge_fe}
repo_pattern='^ghcr\.io/42voicebridge/[a-z0-9._-]+$'

usage() {
  echo "Usage: $0 check|measure|deploy|redeploy [BE 40-character SHA] [AI 40-character SHA] [FE 40-character SHA]" >&2
  exit 2
}

case "$mode" in
  check | measure | redeploy) ;;
  deploy)
    if [[ -z "$be_sha" && -z "$ai_sha" && -z "$fe_sha" ]]; then
      echo "Deploy requires at least one of the BE, AI or FE 40-character lowercase commit SHAs." >&2
      exit 2
    fi
    ;;
  *) usage ;;
esac
for sha in "$be_sha" "$ai_sha" "$fe_sha"; do
  if [[ -n "$sha" && ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Commit SHAs must be 40 lowercase hex characters." >&2
    exit 2
  fi
done
for repo in "$be_repo" "$ai_repo" "$fe_repo"; do
  if [[ ! "$repo" =~ $repo_pattern ]]; then
    echo "Image repository must look like ghcr.io/42voicebridge/<package>: $repo" >&2
    exit 2
  fi
done

terraform -chdir="$application_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null

parameters_file=$(mktemp)
trap 'rm -f -- "$parameters_file"' EXIT

tf_output() { # tf_output DIR NAME
  terraform -chdir="$1" output -raw "$2"
}

# 인스턴스 ID는 보내기 직전에 매번 다시 조회한다. Terraform apply가 인스턴스를 교체한 뒤에도
# 오래된 ID를 대상으로 삼지 않도록 하기 위함이다(교체 중이면 SSM 전송이 실패해 눈에 띄게 멈춘다).
resolve_instance() { # resolve_instance be|ai|fe
  local id
  id=$(tf_output "$application_dir" "$1_instance_id")
  if [[ ! "$id" =~ ^i-[0-9a-f]+$ ]]; then
    echo "Application state has no $1 instance ID. Apply Terraform layers first." >&2
    return 1
  fi
  printf '%s' "$id"
}

wait_online() { # wait_online INSTANCE_ID
  local ping_status
  echo "Waiting for SSM managed instance $1 to be Online..."
  for _ in $(seq 1 30); do
    ping_status=$(aws ssm describe-instance-information \
      --region "$region" --filters "Key=InstanceIds,Values=$1" \
      --query 'InstanceInformationList[0].PingStatus' --output text)
    if [[ "$ping_status" == Online ]]; then
      return 0
    fi
    sleep 10
  done
  echo "EC2 $1 is not Online in SSM. Check its agent, role and outbound connectivity." >&2
  return 1
}

# SSM 명령 하나를 보내고 끝날 때까지 기다린다.
#   run_ssm_command LABEL EXECUTION_TIMEOUT_SECONDS INSTANCE_ID  (parameters_file은 호출 전에 채워 둔다)
run_ssm_command() {
  local label=$1 timeout=$2 instance_id=$3
  local command_id invocation status attempts

  command_id=$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "VoiceBridge $label" \
    --parameters "file://$parameters_file" \
    --query 'Command.CommandId' --output text)
  echo "SSM command ($label): $command_id"

  # 명령의 executionTimeout보다 1분 더 기다린다. 5초 간격으로 확인한다.
  attempts=$(((timeout + 60) / 5))
  for _ in $(seq 1 "$attempts"); do
    if ! invocation=$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" --instance-id "$instance_id" \
      --output json 2>/dev/null); then
      sleep 5
      continue
    fi
    status=$(jq -r '.Status' <<<"$invocation")
    case "$status" in
      Pending | InProgress | Delayed) sleep 5 ;;
      Success)
        jq -r '.StandardOutputContent, .StandardErrorContent | select(length > 0)' <<<"$invocation"
        echo "SSM $label succeeded."
        return 0
        ;;
      *)
        jq -r '.StandardOutputContent, .StandardErrorContent | select(length > 0)' <<<"$invocation"
        echo "SSM $label failed: $status" >&2
        return 1
        ;;
    esac
  done
  echo "Timed out waiting for SSM command $command_id ($label)." >&2
  return 1
}

# --- check ---------------------------------------------------------------------

if [[ "$mode" == check ]]; then
  for comp in be ai fe; do
    instance_id=$(resolve_instance "$comp")
    wait_online "$instance_id"
    # AI는 /data 마운트까지 확인한다(AI 배포는 별도 EBS 볼륨이 마운트돼 있어야 한다).
    if [[ "$comp" == ai ]]; then
      jq -n '{commands:["set +e", "systemctl is-active amazon-ssm-agent", "docker info >/dev/null 2>&1; echo docker_rc=$?", "lsblk", "echo ---", "cat /var/log/voicebridge-data-volume.log 2>&1 || echo NOLOG", "echo ---", "mountpoint /data; echo mount_rc=$?"], executionTimeout:["60"]}' >"$parameters_file"
    else
      jq -n --arg comp "$comp" '{commands:["set -e", "systemctl is-active amazon-ssm-agent", "docker info >/dev/null", "echo \"SSM and Docker ready (" + $comp + ")\""], executionTimeout:["60"]}' >"$parameters_file"
    fi
    run_ssm_command "check-$comp" 60 "$instance_id"
  done
  exit 0
fi

# --- measure -------------------------------------------------------------------

# 사양 확정에 쓰는 지표를 수집한다. 읽기 전용이며 비밀값을 출력하지 않는다.
# available 메모리, 컨테이너별 CPU·메모리, 디스크 사용률, 부하가 핵심이다(docs/OPERATIONS-SIZING.md).
if [[ "$mode" == measure ]]; then
  for comp in be ai fe; do
    instance_id=$(resolve_instance "$comp")
    wait_online "$instance_id"
    jq -n --arg comp "$comp" '{commands:[
      "set +e",
      "echo \"== " + $comp + " $(date -u +%FT%TZ)\"",
      "uptime",
      "free -m",
      "df -h / /data 2>/dev/null",
      "docker ps --format \"{{.Names}} {{.Status}}\"",
      "docker stats --no-stream --format \"{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})\"",
      "docker images --format \"{{.Repository}}:{{.Tag}} {{.Size}}\""
    ], executionTimeout:["120"]}' >"$parameters_file"
    run_ssm_command "measure-$comp" 120 "$instance_id"
  done
  exit 0
fi

# --- redeploy: 마지막에 성공한 배포 기록에서 SHA를 복원한다 ------------------------

if [[ "$mode" == redeploy ]]; then
  for comp in be ai fe; do
    if image=$(aws ssm get-parameter --region "$region" --name "$param_prefix/$comp" \
      --query Parameter.Value --output text 2>/dev/null) && [[ "$image" =~ :sha-([0-9a-f]{40})$ ]]; then
      case "$comp" in
        be) be_sha=${BASH_REMATCH[1]} ;;
        ai) ai_sha=${BASH_REMATCH[1]} ;;
        fe) fe_sha=${BASH_REMATCH[1]} ;;
      esac
      echo "Restoring $comp from the last recorded deployment (sha ${BASH_REMATCH[1]:0:7})."
    else
      echo "No recorded deployment for $comp; skipping."
    fi
  done
  if [[ -z "$be_sha" && -z "$ai_sha" && -z "$fe_sha" ]]; then
    echo "Nothing to redeploy."
    exit 0
  fi
fi

# --- deploy ----------------------------------------------------------------------

terraform -chdir="$storage_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null
app_secret_name=$(tf_output "$application_dir" app_secret_name)
ghcr_secret_name=$(tf_output "$application_dir" ghcr_secret_name)
app_bucket=$(tf_output "$storage_dir" s3_bucket_name)

script_sha=$(sha256sum scripts/ssm/deploy-ec2.sh | cut -d ' ' -f1)
script_uri="s3://$app_bucket/deploy/scripts/$script_sha.sh"
script_path="/tmp/voicebridge-deploy-$script_sha.sh"
aws s3 cp scripts/ssm/deploy-ec2.sh "$script_uri" --region "$region" --no-progress >/dev/null

# 컴포넌트별 SSM 명령을 만든다. 스크립트 내려받기와 해시 검증은 공통이고, 마지막 줄만 다르다.
#   write_deploy_parameters EXECUTION_TIMEOUT_SECONDS DEPLOY_ARGS...
write_deploy_parameters() {
  local timeout=$1
  shift
  jq -n \
    --arg uri "$script_uri" --arg path "$script_path" --arg checksum "$script_sha" \
    --arg timeout "$timeout" --args \
    '{commands:[
      "set -e",
      "aws s3 cp " + ([$uri, $path] | @sh),
      "echo " + ([$checksum + "  " + $path] | @sh) + " | sha256sum -c -",
      "bash " + ([$path] + $ARGS.positional | @sh)
    ], executionTimeout:[$timeout]}' "$@" >"$parameters_file"
}

# 성공한 배포를 기록한다. Terraform apply로 인스턴스가 교체되면 이 기록으로 redeploy한다.
# 기록 실패는 배포 성공을 뒤집지 않는다(권한이 없으면 경고만 남긴다).
record_deployed() { # record_deployed COMPONENT IMAGE
  if ! aws ssm put-parameter --region "$region" --name "$param_prefix/$1" \
    --type String --value "$2" --overwrite >/dev/null 2>&1; then
    echo "WARNING: could not record $1 deployment in SSM Parameter Store ($param_prefix/$1)." \
      "After an instance replacement this component must be redeployed by hand." >&2
  fi
}

# AI를 먼저 배포한다. AI가 실패하면 BE와 FE는 건드리지 않는다.
# AI 타임아웃 1800초: 큰 이미지 pull + 모델 다운로드/로딩 대기(최대 600초) + 여유.
if [[ -n "$ai_sha" ]]; then
  instance_id=$(resolve_instance ai)
  wait_online "$instance_id"
  image="$ai_repo:sha-$ai_sha"
  write_deploy_parameters 1800 ai "$image" "$region" "$ghcr_secret_name" "$app_bucket"
  run_ssm_command deploy-ai 1800 "$instance_id"
  record_deployed ai "$image"
fi

if [[ -n "$be_sha" ]]; then
  instance_id=$(resolve_instance be)
  wait_online "$instance_id"
  rds_endpoint=$(tf_output "$storage_dir" rds_endpoint)
  rds_secret_arn=$(tf_output "$storage_dir" rds_secret_arn)
  db_name=$(tf_output "$storage_dir" db_name)
  redis_host=$(tf_output "$storage_dir" redis_endpoint)
  redis_port=$(tf_output "$storage_dir" redis_port)

  image="$be_repo:sha-$be_sha"
  write_deploy_parameters 900 be "$image" "$region" "$app_secret_name" "$ghcr_secret_name" \
    "$rds_secret_arn" "$rds_endpoint" "$db_name" "$redis_host" "$redis_port" "$app_bucket"
  run_ssm_command deploy-be 900 "$instance_id"
  record_deployed be "$image"
fi

if [[ -n "$fe_sha" ]]; then
  instance_id=$(resolve_instance fe)
  wait_online "$instance_id"
  fe_public_host=$(tf_output "$application_dir" fe_public_host)
  be_upstream=$(tf_output "$application_dir" be_upstream)

  image="$fe_repo:sha-$fe_sha"
  write_deploy_parameters 900 fe "$image" "$region" "$ghcr_secret_name" "$fe_public_host" "$be_upstream"
  run_ssm_command deploy-fe 900 "$instance_id"
  record_deployed fe "$image"
fi
