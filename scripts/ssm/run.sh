#!/usr/bin/env bash
set -euo pipefail

mode=${1:-}
be_sha=${2:-}
region=${AWS_REGION:-ap-northeast-2}
application_dir=infra/environments/dev/3_application
storage_dir=infra/environments/dev/2_storage

if [[ "$mode" != check && "$mode" != deploy ]]; then
  echo "Usage: $0 check|deploy [backend 40-character commit SHA]" >&2
  exit 2
fi
if [[ "$mode" == deploy && ! "$be_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Deploy requires the 40-character lowercase SHA of the BE main commit." >&2
  exit 2
fi

terraform -chdir="$application_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null
instance_id=$(terraform -chdir="$application_dir" output -raw ec2_instance_id)
if [[ ! "$instance_id" =~ ^i-[0-9a-f]+$ ]]; then
  echo "Application state has no EC2 instance ID. Apply Terraform layers first." >&2
  exit 1
fi

echo "Waiting for SSM managed instance $instance_id to be Online..."
online=false
for attempt in $(seq 1 30); do
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

if [[ "$mode" == check ]]; then
  jq -n '{commands:["set -e", "systemctl is-active amazon-ssm-agent", "docker info >/dev/null", "echo SSM and Docker ready"], executionTimeout:["60"]}' >"$parameters_file"
else
  terraform -chdir="$storage_dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null
  app_secret_name=$(terraform -chdir="$application_dir" output -raw app_secret_name)
  rds_endpoint=$(terraform -chdir="$storage_dir" output -raw rds_endpoint)
  rds_secret_arn=$(terraform -chdir="$storage_dir" output -raw rds_secret_arn)
  db_name=$(terraform -chdir="$storage_dir" output -raw db_name)
  redis_host=$(terraform -chdir="$storage_dir" output -raw redis_endpoint)
  redis_port=$(terraform -chdir="$storage_dir" output -raw redis_port)
  app_bucket=$(terraform -chdir="$storage_dir" output -raw s3_bucket_name)
  image="ghcr.io/42voicebridge/42voicebridge_be:sha-$be_sha"

  script_sha=$(sha256sum scripts/ssm/deploy-ec2.sh | cut -d ' ' -f1)
  script_uri="s3://$app_bucket/deploy/scripts/$script_sha.sh"
  script_path="/tmp/voicebridge-deploy-$script_sha.sh"
  aws s3 cp scripts/ssm/deploy-ec2.sh "$script_uri" --region "$region" --no-progress >/dev/null

  jq -n \
    --arg uri "$script_uri" --arg path "$script_path" --arg checksum "$script_sha" \
    --arg image "$image" --arg region "$region" --arg app_secret "$app_secret_name" \
    --arg rds_secret "$rds_secret_arn" --arg rds_endpoint "$rds_endpoint" \
    --arg db_name "$db_name" --arg redis_host "$redis_host" \
    --arg redis_port "$redis_port" --arg app_bucket "$app_bucket" \
    '{commands:[
      "set -e",
      "aws s3 cp " + ([$uri, $path] | @sh),
      "echo " + ([$checksum + "  " + $path] | @sh) + " | sha256sum -c -",
      "bash " + ([$path, $image, $region, $app_secret, $rds_secret, $rds_endpoint, $db_name, $redis_host, $redis_port, $app_bucket] | @sh)
    ], executionTimeout:["900"]}' >"$parameters_file"
fi

command_id=$(aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "VoiceBridge $mode" \
  --parameters "file://$parameters_file" \
  --query 'Command.CommandId' --output text)
echo "SSM command: $command_id"

for attempt in $(seq 1 180); do
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
      echo "SSM $mode succeeded."
      exit 0
      ;;
    *)
      jq -r '.StandardOutputContent, .StandardErrorContent | select(length > 0)' <<<"$invocation"
      echo "SSM $mode failed: $status" >&2
      exit 1
      ;;
  esac
done
echo "Timed out waiting for SSM command $command_id." >&2
exit 1
