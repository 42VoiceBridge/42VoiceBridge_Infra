#!/usr/bin/env bash
# run.sh 흐름 테스트: 입력 검증, AI → BE 배포 순서, AI 실패 시 BE 미배포, check 모드.
# terraform/aws/sleep을 스텁으로 대체하므로 AWS 자격 증명이 필요 없다.
# 실행: bash scripts/ssm/test/run.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0 fail=0
AI_SHA=$(printf 'b%.0s' {1..40})
BE_SHA=$(printf 'a%.0s' {1..40})

cat >"$work/bin/terraform" <<'STUB'
#!/usr/bin/env bash
# terraform -chdir=DIR init|output ...
case "$*" in
  *"output -raw ec2_instance_id"*) echo i-0abc123 ;;
  *"output -raw app_secret_name"*) echo voicebridge/dev/app ;;
  *"output -raw s3_bucket_name"*) echo bucket-x ;;
  *"output -raw"*) echo "value-for-${@: -1}" ;;
esac
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$STUB_STATE/aws.log"
case "$1 $2" in
  "ssm describe-instance-information") echo "${STUB_PING:-Online}" ;;
  "ssm send-command")
    # --parameters file://... 의 마지막 명령(실제 배포 줄)을 기록한다.
    f=$(printf '%s\n' "$@" | grep '^file://' | sed 's#^file://##')
    echo "send $(jq -r '.commands[-1]' "$f") timeout=$(jq -r '.executionTimeout[0]' "$f")" >>"$STUB_STATE/sends.log"
    jq -r '.commands | join(" ; ")' "$f" >>"$STUB_STATE/commands.log"
    n=$(wc -l <"$STUB_STATE/sends.log" | tr -d ' ')
    echo "cmd-$n" ;;
  "ssm get-command-invocation")
    id=$(printf '%s\n' "$@" | grep '^cmd-')
    n=${id#cmd-}
    status=Success
    [[ "$n" == "${STUB_FAIL_AT:-0}" ]] && status=Failed
    jq -n --arg s "$status" '{Status:$s, StandardOutputContent:"out", StandardErrorContent:""}' ;;
  "s3 cp") exit 0 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin"/*

run() {
  export STUB_STATE=$work/state
  rm -rf "$STUB_STATE" && mkdir -p "$STUB_STATE" && : >"$STUB_STATE/sends.log"
  (cd "$repo_root" && PATH=$work/bin:$PATH bash scripts/ssm/run.sh "$@") >"$work/out" 2>"$work/err"
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }
sends() { wc -l <"$STUB_STATE/sends.log" | tr -d ' '; }
send_n_has() { sed -n "${1}p" "$STUB_STATE/sends.log" | grep -Fq -- "$2"; }
err_has() { grep -Fq -- "$1" "$work/err"; }

echo "입력 검증"
run;                           check "모드 없음 → 2" rc_is 2
run deploy;                    check "deploy에 SHA가 없으면 → 2" rc_is 2
run deploy abc;                check "짧은 BE SHA → 2" rc_is 2
run deploy "" "${AI_SHA^^}";   check "대문자 AI SHA → 2" rc_is 2
run deploy "$BE_SHA" "xyz";    check "잘못된 AI SHA → 2" rc_is 2
check "검증 실패 시 SSM 명령을 보내지 않음" test "$(sends)" = 0

echo "check 모드"
run check
check "종료코드 0" rc_is 0
check "SSM 명령 1개" test "$(sends)" = 1
check "/data 마운트를 확인하는 명령 포함" grep -Fq 'mountpoint -q /data' "$STUB_STATE/commands.log"
check "마운트 확인이 set -e 아래 독립 명령(&&로 묶이지 않음)" bash -c "! grep -F 'mountpoint -q /data &&' '$STUB_STATE/commands.log'"
STUB_PING=ConnectionLost run check
check "SSM이 Online이 아니면 실패" rc_is 1

echo "deploy: 배포 순서와 타임아웃"
run deploy "$BE_SHA" "$AI_SHA"
check "둘 다 지정 → 종료코드 0" rc_is 0
check "명령 2개" test "$(sends)" = 2
check "1번째가 AI" send_n_has 1 "42voicebridge_ai:sha-$AI_SHA"
check "AI 타임아웃 1800초" send_n_has 1 "timeout=1800"
check "2번째가 BE" send_n_has 2 "42voicebridge_be:sha-$BE_SHA"
check "BE 타임아웃 900초" send_n_has 2 "timeout=900"
run deploy "$BE_SHA" ""
check "BE만 → 명령 1개(BE)" bash -c "test '$(sends)' = 1 && grep -q 'be:sha-' '$STUB_STATE/sends.log'"
run deploy "" "$AI_SHA"
check "AI만 → 명령 1개(AI)" bash -c "test '$(sends)' = 1 && grep -q 'ai:sha-' '$STUB_STATE/sends.log'"

echo "이미지 저장소 변수"
AI_IMAGE_REPOSITORY=ghcr.io/42voicebridge/custom-ai run deploy "" "$AI_SHA"
check "AI_IMAGE_REPOSITORY 값으로 이미지 조립" send_n_has 1 "custom-ai:sha-$AI_SHA"
AI_IMAGE_REPOSITORY="ghcr.io/evil/x" run deploy "" "$AI_SHA"
check "다른 조직 경로는 거부 → 2" rc_is 2
check "거부 시 SSM 명령을 보내지 않음" test "$(sends)" = 0
AI_IMAGE_REPOSITORY='<실제-AI-패키지명>' run deploy "" "$AI_SHA"
check "자리 표시자 값은 거부 → 2" rc_is 2
BE_IMAGE_REPOSITORY=ghcr.io/42voicebridge/custom-be run deploy "$BE_SHA" ""
check "BE_IMAGE_REPOSITORY 값으로 이미지 조립" send_n_has 1 "custom-be:sha-$BE_SHA"
AI_IMAGE_REPOSITORY="" run deploy "" "$AI_SHA"
check "변수가 비어 있으면 기본 AI 이미지 이름" send_n_has 1 "42voicebridge_ai:sha-$AI_SHA"

echo "deploy: AI 실패 시 BE 미배포"
STUB_FAIL_AT=1 run deploy "$BE_SHA" "$AI_SHA"
check "종료코드 1" rc_is 1
check "BE 명령을 보내지 않음(명령 1개)" test "$(sends)" = 1
check "실패 사유 출력" err_has "deploy-ai failed"

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
