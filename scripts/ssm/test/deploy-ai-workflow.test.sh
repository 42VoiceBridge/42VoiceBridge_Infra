#!/usr/bin/env bash
# deploy-ai.yml의 "Validate dispatch payload" 단계를 YAML에서 그대로 꺼내 입력별로 실행한다.
# 실행: bash scripts/ssm/test/deploy-ai-workflow.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
pass=0 fail=0
SHA=$(printf 'b%.0s' {1..40})
REPO=ghcr.io/42voicebridge/42voicebridge_ai

python3 - "$repo_root/.github/workflows/deploy-ai.yml" "$work/validate.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["deploy"]["steps"]
step = next(s for s in steps if s.get("name") == "Validate dispatch payload")
open(sys.argv[2], "w").write(step["run"])
trigger = wf.get("on") or wf.get(True)
assert trigger["repository_dispatch"]["types"] == ["deploy-ai"], trigger
print("trigger types: deploy-ai only")
PY

run() { # run REF SHA IMAGE REPO
  AI_REF=$1 AI_SHA=$2 AI_PAYLOAD_IMAGE=$3 AI_IMAGE_REPOSITORY=$4 bash "$work/validate.sh" >"$work/out" 2>&1
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }

run refs/heads/main "$SHA" "$REPO:sha-$SHA" "$REPO"
check "정상 payload 통과" rc_is 0
run refs/heads/main "$SHA" "" "$REPO"
check "image 필드가 없어도 통과(SHA와 변수로 조립)" rc_is 0
run refs/heads/develop "$SHA" "" "$REPO"
check "main이 아닌 ref 거부" rc_is 1
run refs/pull/1/merge "$SHA" "" "$REPO"
check "PR ref 거부" rc_is 1
run refs/heads/main "${SHA:0:7}" "" "$REPO"
check "7자 단축 SHA 거부" rc_is 1
run refs/heads/main "${SHA^^}" "" "$REPO"
check "대문자 SHA 거부" rc_is 1
run refs/heads/main "$SHA" "$REPO:sha-$SHA" "ghcr.io/evil/x"
check "다른 조직의 저장소 변수 거부" rc_is 1
run refs/heads/main "$SHA" "$REPO:sha-$SHA" ""
check "저장소 변수가 비어 있으면 거부" rc_is 1
run refs/heads/main "$SHA" "ghcr.io/42voicebridge/other:sha-$SHA" "$REPO"
check "payload image가 변수와 다르면 거부(임의 이미지 방지)" rc_is 1
run refs/heads/main "$SHA" "$REPO:sha-$(printf 'c%.0s' {1..40})" "$REPO"
check "payload image의 SHA가 다르면 거부" rc_is 1
run refs/heads/main "$SHA; echo pwned" "" "$REPO"
check "명령 삽입 시도 거부" rc_is 1
check "삽입 문자열이 실행되지 않음" bash -c "! grep -q '^pwned' '$work/out'"

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
