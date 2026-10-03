#!/usr/bin/env bash
set -euo pipefail

# Runs as root through AWS-RunShellScript. Arguments contain resource names,
# endpoints and an image tag; secret values are fetched on the instance.
if [[ "$#" -ne 9 ]]; then
  echo "Expected image, region, app secret, RDS secret, endpoint, DB name, Redis host/port and S3 bucket." >&2
  exit 2
fi
image=$1
region=$2
app_secret_id=$3
rds_secret_arn=$4
rds_endpoint=$5
db_name=$6
redis_host=$7
redis_port=$8
s3_bucket=$9
export AWS_REGION=$region

case "$image" in
  ghcr.io/42voicebridge/42voicebridge_be:sha-*) ;;
  *) echo "Unexpected GHCR image name." >&2; exit 2 ;;
esac

for tool in aws jq docker curl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
docker info >/dev/null

app_json=$(aws secretsmanager get-secret-value --secret-id "$app_secret_id" --query SecretString --output text)
rds_json=$(aws secretsmanager get-secret-value --secret-id "$rds_secret_arn" --query SecretString --output text)
jq -e 'type == "object"' <<<"$app_json" >/dev/null
jq -e 'type == "object"' <<<"$rds_json" >/dev/null

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

ghcr_user=$(jq -r '.GHCR_USERNAME // ""' <<<"$app_json")
ghcr_token=$(jq -r '.GHCR_READ_TOKEN // ""' <<<"$app_json")
if [[ -n "$ghcr_user" || -n "$ghcr_token" ]]; then
  if [[ -z "$ghcr_user" || -z "$ghcr_token" ]]; then
    echo "GHCR_USERNAME and GHCR_READ_TOKEN must both be set." >&2
    exit 1
  fi
  printf '%s' "$ghcr_token" | docker login ghcr.io --username "$ghcr_user" --password-stdin >/dev/null
fi
docker pull "$image" >/dev/null

app_name=voicebridge-be
previous_name=voicebridge-be-previous
if docker ps -a --format '{{.Names}}' | grep -Fxq "$previous_name"; then
  echo "Previous deployment container still exists; inspect it before retrying." >&2
  exit 1
fi

had_previous=false
if docker ps -a --format '{{.Names}}' | grep -Fxq "$app_name"; then
  docker rename "$app_name" "$previous_name"
  docker stop "$previous_name" >/dev/null
  had_previous=true
fi

restore_previous() {
  docker rm -f "$app_name" >/dev/null 2>&1 || true
  if [[ "$had_previous" == true ]]; then
    docker rename "$previous_name" "$app_name"
    docker start "$app_name" >/dev/null
    echo "Previous container restored." >&2
  fi
}

if ! docker run --detach --name "$app_name" --restart unless-stopped \
  --publish 80:8080 --env-file "$env_file" "$image" >/dev/null; then
  restore_previous
  exit 1
fi

healthy=false
for attempt in $(seq 1 90); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$app_name")" != true ]]; then
    break
  fi
  response=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 2 http://127.0.0.1/ || true)
  if [[ "$response" != 000 && -n "$response" ]]; then
    healthy=true
    break
  fi
  sleep 2
done

if [[ "$healthy" != true ]]; then
  echo "New container did not answer HTTP on port 80." >&2
  restore_previous
  exit 1
fi

if [[ "$had_previous" == true ]]; then
  docker rm "$previous_name" >/dev/null
fi
echo "Deployed $image; HTTP endpoint responded."
