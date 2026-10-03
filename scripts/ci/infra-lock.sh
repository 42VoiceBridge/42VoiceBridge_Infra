#!/usr/bin/env bash
set -euo pipefail

# Terraform apply(인스턴스 교체 가능)와 서비스 배포(SSM)가 겹치지 않게 하는 락. S3 조건부 쓰기
# (put-object --if-none-match '*')로 "이미 있으면 실패"를 원자적으로 보장한다.
#
#   infra-lock.sh acquire deploy COMPONENT RUN_ID
#   infra-lock.sh release deploy COMPONENT
#   infra-lock.sh acquire apply RUN_ID
#   infra-lock.sh release apply
#
# 왜 GitHub concurrency만으로는 부족한가: 같은 그룹은 실행 1개 + 대기 1개만 유지하고, 그 사이에 온
# 대기 건은 취소된다. BE/AI/FE 배포가 apply와 겹쳐 대기하면 일부 배포가 조용히 사라질 수 있다.
#
# 규칙(교착 없음):
#   - 배포는 컴포넌트별 락(deploy-<c>)을 잡는다. 같은 컴포넌트는 직렬화되고 다른 컴포넌트는 병렬이다.
#   - apply는 단일 락(apply)을 잡는다.
#   - 각자 "자기 락을 먼저 만든 뒤" 상대 락을 확인한다. 배포는 apply 락이 보이면 자기 락을 지우고 양보하고,
#     apply는 배포 락이 모두 사라질 때까지 기다린다. 동시에 시작해도 한쪽(배포)이 반드시 양보한다.
#   - 비정상 종료로 남은 락은 LOCK_STALE_SECONDS(기본 2시간)가 지나면 정리한다.

bucket=${LOCK_BUCKET:-42voicebridge-tfstate}
prefix=${LOCK_PREFIX:-locks/dev}
wait_seconds=${LOCK_WAIT_SECONDS:-2400}
interval=${LOCK_INTERVAL:-20}
stale_seconds=${LOCK_STALE_SECONDS:-7200}
apply_key=$prefix/apply

usage() {
  echo "Usage: $0 acquire deploy COMPONENT RUN_ID | release deploy COMPONENT | acquire apply RUN_ID | release apply" >&2
  exit 2
}

now() { echo "${LOCK_NOW:-$(date +%s)}"; }

attempts() {
  local n=$((wait_seconds / interval))
  ((n >= 1)) || n=1
  echo "$n"
}

key_exists() { aws s3api head-object --bucket "$bucket" --key "$1" >/dev/null 2>&1; }

# 락을 만든다. 이미 있으면 1을 반환한다. 만들기에 실패했는데 락도 없으면 권한·네트워크 오류이므로 중단한다.
try_create() { # try_create KEY OWNER_LABEL RUN_ID
  local body
  body=$(mktemp)
  jq -n --arg owner "$2" --arg run "$3" --argjson ts "$(now)" --arg repo "${GITHUB_REPOSITORY:-}" \
    '{owner:$owner, run_id:$run, created_at:$ts, repository:$repo}' >"$body"
  if aws s3api put-object --bucket "$bucket" --key "$1" --body "$body" --if-none-match '*' >/dev/null 2>&1; then
    rm -f -- "$body"
    return 0
  fi
  rm -f -- "$body"
  if key_exists "$1"; then
    return 1
  fi
  echo "::error::Could not create lock s3://$bucket/$1 (check bucket permissions for $prefix/*)." >&2
  exit 1
}

delete_key() { aws s3api delete-object --bucket "$bucket" --key "$1" >/dev/null 2>&1 || true; }

# 오래된 락(러너가 비정상 종료한 경우)을 정리한다.
reap_if_stale() {
  local key=$1 tmp created
  key_exists "$key" || return 0
  tmp=$(mktemp)
  if aws s3api get-object --bucket "$bucket" --key "$key" "$tmp" >/dev/null 2>&1; then
    created=$(jq -r '.created_at // 0' "$tmp" 2>/dev/null || echo 0)
    if [[ "$created" =~ ^[0-9]+$ ]] && (($(now) - created > stale_seconds)); then
      echo "::warning::Removing stale lock s3://$bucket/$key (older than ${stale_seconds}s)." >&2
      delete_key "$key"
    fi
  fi
  rm -f -- "$tmp"
}

list_deploy_locks() {
  local out
  out=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix/deploy-" \
    --query 'Contents[].Key' --output text 2>/dev/null || true)
  [[ -z "$out" || "$out" == None ]] || printf '%s\n' "$out" | tr '\t' '\n'
}

acquire_deploy() { # acquire_deploy COMPONENT RUN_ID
  local comp=$1 run_id=$2 key="$prefix/deploy-$1" i
  for ((i = 0; i < $(attempts); i++)); do
    reap_if_stale "$apply_key"
    reap_if_stale "$key"
    if key_exists "$apply_key"; then
      echo "Waiting: Terraform apply holds the infra lock."
      sleep "$interval"
      continue
    fi
    if try_create "$key" "deploy-$comp" "$run_id"; then
      # 내 락을 만든 뒤에 apply 락이 생겼다면 apply가 먼저 시작한 것이므로 양보한다.
      if key_exists "$apply_key"; then
        delete_key "$key"
        echo "Waiting: Terraform apply started; yielding."
        sleep "$interval"
        continue
      fi
      echo "Acquired deploy lock for $comp."
      return 0
    fi
    echo "Waiting: another $comp deployment is running."
    sleep "$interval"
  done
  echo "::error::Timed out waiting for the $comp deploy lock." >&2
  return 1
}

acquire_apply() { # acquire_apply RUN_ID
  local run_id=$1 i got=false
  for ((i = 0; i < $(attempts); i++)); do
    reap_if_stale "$apply_key"
    if try_create "$apply_key" apply "$run_id"; then
      got=true
      break
    fi
    echo "Waiting: another Terraform apply is running."
    sleep "$interval"
  done
  if [[ "$got" != true ]]; then
    echo "::error::Timed out waiting for the apply lock." >&2
    return 1
  fi

  # 진행 중인 배포가 모두 끝나기를 기다린다. 새 배포는 apply 락을 보고 시작하지 않는다.
  for ((i = 0; i < $(attempts); i++)); do
    while read -r key; do
      [[ -z "$key" ]] || reap_if_stale "$key"
    done < <(list_deploy_locks)
    if [[ -z "$(list_deploy_locks)" ]]; then
      echo "Acquired apply lock; no deployments in progress."
      return 0
    fi
    echo "Waiting: service deployments are still running."
    sleep "$interval"
  done
  delete_key "$apply_key"
  echo "::error::Timed out waiting for service deployments to finish." >&2
  return 1
}

[[ "$#" -ge 2 ]] || usage
action=$1
kind=$2
shift 2

case "$action $kind" in
  "acquire deploy") [[ "$#" -eq 2 ]] || usage; acquire_deploy "$1" "$2" ;;
  "release deploy") [[ "$#" -eq 1 ]] || usage; delete_key "$prefix/deploy-$1"; echo "Released deploy lock for $1." ;;
  "acquire apply") [[ "$#" -eq 1 ]] || usage; acquire_apply "$1" ;;
  "release apply") [[ "$#" -eq 0 ]] || usage; delete_key "$apply_key"; echo "Released apply lock." ;;
  *) usage ;;
esac
