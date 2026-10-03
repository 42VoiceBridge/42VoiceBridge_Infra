#!/usr/bin/env bash
set -euo pipefail

# 레이어 하나의 plan 또는 apply. 레이어는 반드시 1_base → 2_storage → 3_application 순서로 적용한다.
#   tf-layer.sh plan  LAYER PLAN_DIR   plan을 저장하고 요약·메타데이터를 PLAN_DIR에 쓴다.
#   tf-layer.sh apply LAYER PLAN_DIR   PLAN_DIR의 저장된 plan 파일만 apply한다(검토한 plan 그대로).
#
# 하위 레이어의 state가 없는 첫 배포에서는 상위 레이어를 plan할 수 없다(remote state를 읽기 때문).
# 그래서 하위 레이어가 apply되기 전에는 상위 레이어의 plan·apply를 거부한다.
# 잠금은 유지한다(-lock=false 금지). 다른 작업이 잠금을 쥐고 있으면 -lock-timeout 동안 기다린다.

base_dir=${TF_BASE_DIR:-infra/environments/dev}
state_bucket=${TF_STATE_BUCKET:-42voicebridge-tfstate}
layers=(1_base 2_storage 3_application)

usage() {
  echo "Usage: $0 plan|apply 1_base|2_storage|3_application PLAN_DIR" >&2
  exit 2
}

[[ "$#" -eq 3 ]] || usage
mode=$1
layer=$2
plan_dir=$3
[[ "$mode" == plan || "$mode" == apply ]] || usage

known=false
for l in "${layers[@]}"; do [[ "$l" == "$layer" ]] && known=true; done
[[ "$known" == true ]] || usage

dir=$base_dir/$layer
mkdir -p "$plan_dir"
plan_dir=$(cd "$plan_dir" && pwd)

# 하위 레이어가 먼저 apply돼 있어야 한다.
for l in "${layers[@]}"; do
  [[ "$l" != "$layer" ]] || break
  if ! aws s3api head-object --bucket "$state_bucket" --key "dev/$l/terraform.tfstate" >/dev/null 2>&1; then
    echo "::error::Layer $l has no state yet. Plan and apply layers in order: 1_base, 2_storage, 3_application." >&2
    exit 1
  fi
done

current_commit() { git rev-parse HEAD; }

tf_init() { terraform -chdir="$dir" init -reconfigure -lockfile=readonly -input=false -no-color >/dev/null; }

summarize() { # summarize LINE...  — GitHub Actions 요약에 쓴다
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# 기본값이 없는 입력 변수는 Infra 저장소 Variables에서 TF_VAR_*로 받는다. 비어 있으면 plan이 의미 없이 진행되므로
# 시작 전에 확인한다. SSH를 전체 공개(0.0.0.0/0)로 여는 값은 허용하지 않는다.
require_inputs() {
  case "$layer" in
    1_base)
      if [[ -z "${TF_VAR_ssh_allowed_cidr:-}" ]]; then
        echo "::error::Set the Infra repository variable SSH_ALLOWED_CIDR (your IP, e.g. 203.0.113.5/32)." >&2
        exit 1
      fi
      if [[ "$TF_VAR_ssh_allowed_cidr" == "0.0.0.0/0" ]]; then
        echo "::error::SSH_ALLOWED_CIDR must not be 0.0.0.0/0." >&2
        exit 1
      fi
      ;;
    3_application)
      if [[ -z "${TF_VAR_ssh_key_name:-}" ]]; then
        echo "::error::Set the Infra repository variable SSH_KEY_NAME (an existing EC2 key pair name)." >&2
        exit 1
      fi
      ;;
  esac
}

if [[ "$mode" == plan ]]; then
  require_inputs
  tf_init
  rc=0
  terraform -chdir="$dir" plan -input=false -no-color -lock-timeout=5m -detailed-exitcode \
    -out="$plan_dir/tfplan" >"$plan_dir/plan-output.txt" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    tail -n 40 "$plan_dir/plan-output.txt" >&2
    echo "::error::terraform plan failed for $layer." >&2
    exit 1
  fi
  has_changes=false
  [[ "$rc" -eq 2 ]] && has_changes=true

  terraform -chdir="$dir" show -no-color "$plan_dir/tfplan" >"$plan_dir/plan.txt"
  # JSON 플랜은 민감값을 마스킹하지 않을 수 있으므로 파괴 감지에만 쓰고 아티팩트(PLAN_DIR)에는 남기지 않는다.
  plan_json=$(mktemp)
  terraform -chdir="$dir" show -json "$plan_dir/tfplan" >"$plan_json"
  jq -r '.resource_changes[]? | select(.change.actions | index("delete")) | "\(.address) [\(.change.actions | join(","))]"' \
    "$plan_json" >"$plan_dir/destroys.txt"
  rm -f -- "$plan_json"
  destroy_count=$(wc -l <"$plan_dir/destroys.txt" | tr -d ' ')

  jq -n --arg layer "$layer" --arg commit "$(current_commit)" \
    --arg sha "$(sha256sum "$plan_dir/tfplan" | cut -d ' ' -f1)" \
    --argjson changes "$has_changes" --argjson destroys "$destroy_count" \
    '{layer:$layer, commit:$commit, tfplan_sha256:$sha, has_changes:$changes, destroy_count:$destroys}' \
    >"$plan_dir/meta.json"

  summarize "## Terraform plan: $layer" "" "- commit: \`$(current_commit)\`" "- changes: $has_changes" "- resources to destroy or replace: $destroy_count"
  if [[ "$destroy_count" -gt 0 ]]; then
    summarize "" "**Destroy/replace (apply needs allow_destroy):**" '```' "$(cat "$plan_dir/destroys.txt")" '```'
  fi
  summarize "" '```' "$(head -n 300 "$plan_dir/plan.txt")" '```' "" "_Truncated to 300 lines; the full plan is in the plan artifact._"
  echo "Plan saved: changes=$has_changes, destroy/replace=$destroy_count"
  exit 0
fi

# --- apply -------------------------------------------------------------------------

for f in tfplan meta.json; do
  [[ -f "$plan_dir/$f" ]] || { echo "::error::Missing $f in $plan_dir. Run the plan workflow first." >&2; exit 1; }
done
if [[ "$(jq -r '.layer' "$plan_dir/meta.json")" != "$layer" ]]; then
  echo "::error::The saved plan is for a different layer." >&2
  exit 1
fi
if [[ "$(jq -r '.commit' "$plan_dir/meta.json")" != "$(current_commit)" ]]; then
  echo "::error::The plan was made on a different commit than this run. Plan again on this commit." >&2
  exit 1
fi
if [[ "$(jq -r '.tfplan_sha256' "$plan_dir/meta.json")" != "$(sha256sum "$plan_dir/tfplan" | cut -d ' ' -f1)" ]]; then
  echo "::error::The saved plan file does not match its recorded checksum." >&2
  exit 1
fi
if [[ "$(jq -r '.has_changes' "$plan_dir/meta.json")" != true ]]; then
  echo "No changes in the saved plan; nothing to apply."
  exit 0
fi

destroy_count=$(jq -r '.destroy_count' "$plan_dir/meta.json")
if [[ "$destroy_count" != 0 && "${ALLOW_DESTROY:-false}" != true ]]; then
  echo "::error::The plan destroys or replaces $destroy_count resource(s). Review them and re-run with allow_destroy=true:" >&2
  cat "$plan_dir/destroys.txt" >&2
  exit 1
fi

tf_init
terraform -chdir="$dir" apply -input=false -no-color -lock-timeout=5m "$plan_dir/tfplan"
summarize "## Terraform apply: $layer" "" "Applied the saved plan from commit \`$(current_commit)\`."
