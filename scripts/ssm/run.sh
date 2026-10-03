#!/usr/bin/env bash
set -euo pipefail

mode=${1:-}
be_sha=${2:-}
ai_sha=${3:-}
region=${AWS_REGION:-ap-northeast-2}
application_dir=infra/environments/dev/3_application
storage_dir=infra/environments/dev/2_storage

usage() {
  echo "Usage: $0 check|deploy [BE 40-character commit SHA] [AI 40-character commit SHA]" >&2
  exit 2
}

if [[ "$mode" != check && "$mode" != deploy ]]; then
  usage
fi
if [[ "$mode" == deploy ]]; then
  if [[ -z "$be_sha" && -z "$ai_sha" ]]; then
    echo "Deploy requires at least one of the BE or AI 40-character lowercase commit SHAs." >&2
    exit 2
  fi
  for sha in "$be_sha" "$ai_sha"; do
    if [[ -n "$sha" && ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "Commit SHAs must be 40 lowercase hex characters." >&2
      exit 2
    fi
  done
fi

terraform -chdir="$application_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null
instance_id=$(terraform -chdir="$application_dir" output -raw ec2_instance_id)
if [[ ! "$instance_id" =~ ^i-[0-9a-f]+$ ]]; then
  echo "Application state has no EC2 instance ID. Apply Terraform layers first." >&2
  exit 1
fi

echo "Waiting for SSM managed instance $instance_id to be Online..."
online=false
for _ in $(seq 1 30); do
  ping_status=$(aws ssm describe-instance-information \
    --region "$region" --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text)
  if [[ "$ping_status" == Online ]]; then
    online=true
    break
  fi
  sleep 10
done
if [[ "$online" != true ]]; then
  echo "EC2 is not Online in SSM. Check its agent, role and outbound connectivity." >&2
  exit 1
fi

parameters_file=$(mktemp)
trap 'rm -f -- "$parameters_file"' EXIT

# SSM 명령 하나를 보내고 끝날 때까지 기다린다.
#   run_ssm_command LABEL EXECUTION_TIMEOUT_SECONDS  (parameters_file은 호출 전에 채워 둔다)
run_ssm_command() {
  local label=$1 timeout=$2
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
  attempts=$(( (timeout + 60) / 5 ))
  for _ in $(seq 1 "$attempts"); do
    if ! invocation=$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" --instance-id "$instance_id" \
      --output json 2>/dev/null); then
      sleep 5
      continue
    fi
    status=$(jq -r '.Status' <<<"$invocation")
    case "$status" in
      Pending|InProgress|Delayed) sleep 5 ;;
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

if [[ "$mode" == check ]]; then
  # /data 마운트까지 확인한다. AI 배포는 별도 EBS 볼륨이 마운트돼 있어야 한다.
  jq -n '{commands:["set -e", "systemctl is-active amazon-ssm-agent", "docker info >/dev/null", "mountpoint -q /data", "echo \"Data volume mounted at /data\"", "echo SSM and Docker ready"], executionTimeout:["60"]}' >"$parameters_file"
  run_ssm_command check 60
  exit 0
fi

terraform -chdir="$storage_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null
app_secret_name=$(terraform -chdir="$application_dir" output -raw app_secret_name)
app_bucket=$(terraform -chdir="$storage_dir" output -raw s3_bucket_name)

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

# AI를 먼저 배포한다. AI가 실패하면 BE는 건드리지 않는다.
# AI 타임아웃 1800초: 큰 이미지 pull + 모델 다운로드/로딩 대기(최대 600초) + 여유.
if [[ -n "$ai_sha" ]]; then
  write_deploy_parameters 1800 ai "ghcr.io/42voicebridge/42voicebridge_ai:sha-$ai_sha" \
    "$region" "$app_secret_name" "$app_bucket"
  run_ssm_command deploy-ai 1800
fi

if [[ -n "$be_sha" ]]; then
  rds_endpoint=$(terraform -chdir="$storage_dir" output -raw rds_endpoint)
  rds_secret_arn=$(terraform -chdir="$storage_dir" output -raw rds_secret_arn)
  db_name=$(terraform -chdir="$storage_dir" output -raw db_name)
  redis_host=$(terraform -chdir="$storage_dir" output -raw redis_endpoint)
  redis_port=$(terraform -chdir="$storage_dir" output -raw redis_port)

  write_deploy_parameters 900 be "ghcr.io/42voicebridge/42voicebridge_be:sha-$be_sha" \
    "$region" "$app_secret_name" "$rds_secret_arn" "$rds_endpoint" "$db_name" \
    "$redis_host" "$redis_port" "$app_bucket"
  run_ssm_command deploy-be 900
fi
