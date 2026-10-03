#!/usr/bin/env bash
# run.sh 흐름 테스트: 입력 검증, 인스턴스별 대상 선택, AI → BE → FE 순서와 실패 시 중단,
# 배포 기록(SSM Parameter Store)과 redeploy, check 모드. terraform/aws/sleep을 스텁으로 대체하므로
# AWS 자격 증명이 필요 없다. 실행: bash scripts/ssm/test/run.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0 fail=0
SHA_B=$(printf 'b%.0s' {1..40})
SHA_A=$(printf 'a%.0s' {1..40})
SHA_C=$(printf 'c%.0s' {1..40})

cat >"$work/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >>"$STUB_STATE/terraform.log"
case "$*" in
  *"output -raw be_instance_id"*) echo i-0be0000000000001 ;;
  *"output -raw ai_instance_id"*) echo i-0a10000000000002 ;;
  *"output -raw fe_instance_id"*) echo i-0fe0000000000003 ;;
  *"output -raw app_secret_name"*) echo voicebridge/dev/app ;;
  *"output -raw ghcr_secret_name"*) echo voicebridge/dev/ghcr ;;
  *"output -raw fe_public_host"*) echo ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com ;;
  *"output -raw be_upstream"*) echo http://10.0.1.10:8080 ;;
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
    f=$(printf '%s\n' "$@" | grep '^file://' | sed 's#^file://##')
    iid=$(printf '%s\n' "$@" | grep -A1 '^--instance-ids$' | tail -1)
    echo "send $iid $(jq -r '.commands[-1]' "$f") timeout=$(jq -r '.executionTimeout[0]' "$f")" >>"$STUB_STATE/sends.log"
    jq -r '.commands | join(" ; ")' "$f" >>"$STUB_STATE/commands.log"
    n=$(wc -l <"$STUB_STATE/sends.log" | tr -d ' ')
    echo "cmd-$n" ;;
  "ssm get-command-invocation")
    id=$(printf '%s\n' "$@" | grep '^cmd-')
    n=${id#cmd-}
    status=Success
    [[ "$n" == "${STUB_FAIL_AT:-0}" ]] && status=Failed
    jq -n --arg s "$status" '{Status:$s, StandardOutputContent:"out", StandardErrorContent:""}' ;;
  "ssm put-parameter")
    [[ -z "${STUB_PUT_FAIL:-}" ]] || exit 254
    name=$(printf '%s\n' "$@" | grep -A1 '^--name$' | tail -1)
    value=$(printf '%s\n' "$@" | grep -A1 '^--value$' | tail -1)
    echo "$name=$value" >>"$STUB_STATE/params.log" ;;
  "ssm get-parameter")
    name=$(printf '%s\n' "$@" | grep -A1 '^--name$' | tail -1)
    comp=${name##*/}
    var="STUB_PARAM_$(printf '%s' "$comp" | tr a-z A-Z)"
    [[ -n "${!var:-}" ]] || exit 254
    echo "${!var}" ;;
  "s3 cp") exit 0 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin"/*

run() {
  export STUB_STATE=$work/state
  rm -rf "$STUB_STATE" && mkdir -p "$STUB_STATE" && : >"$STUB_STATE/sends.log" && : >"$STUB_STATE/params.log"
  (cd "$repo_root" && PATH=$work/bin:$PATH bash scripts/ssm/run.sh "$@") >"$work/out" 2>"$work/err"
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }
sends() { wc -l <"$STUB_STATE/sends.log" | tr -d ' '; }
send_n_has() { sed -n "${1}p" "$STUB_STATE/sends.log" | grep -Fq -- "$2"; }
err_has() { grep -Fq -- "$1" "$work/err"; }
out_has() { grep -Fq -- "$1" "$work/out"; }
param_has() { grep -Fq -- "$1" "$STUB_STATE/params.log"; }
unset_stubs() { unset STUB_PING STUB_FAIL_AT STUB_PUT_FAIL STUB_PARAM_BE STUB_PARAM_AI STUB_PARAM_FE BE_IMAGE_REPOSITORY AI_IMAGE_REPOSITORY FE_IMAGE_REPOSITORY; }

echo "입력 검증"
unset_stubs; run;                          check "모드 없음 → 2" rc_is 2
run bogus;                                 check "알 수 없는 모드 → 2" rc_is 2
run deploy;                                check "deploy에 SHA가 없으면 → 2" rc_is 2
run deploy abc;                            check "짧은 BE SHA → 2" rc_is 2
run deploy "" "${SHA_B^^}";                check "대문자 AI SHA → 2" rc_is 2
run deploy "" "" "xyz";                    check "잘못된 FE SHA → 2" rc_is 2
check "검증 실패 시 SSM 명령을 보내지 않음" test "$(sends)" = 0

echo "check 모드 — 인스턴스별 점검"
unset_stubs; run check
check "종료코드 0" rc_is 0
check "SSM 명령 3개(BE, AI, FE)" test "$(sends)" = 3
check "각 명령이 해당 인스턴스 ID로 전송" bash -c "grep -q 'i-0be0000000000001' '$STUB_STATE/sends.log' && grep -q 'i-0a10000000000002' '$STUB_STATE/sends.log' && grep -q 'i-0fe0000000000003' '$STUB_STATE/sends.log'"
check "AI 점검에만 /data 마운트 확인" bash -c "test \$(grep -c 'mountpoint -q /data' '$STUB_STATE/commands.log') = 1 && grep 'mountpoint -q /data' '$STUB_STATE/commands.log' | grep -q 'ready (ai)'"
check "마운트 확인이 set -e 아래 독립 명령(&&로 묶이지 않음)" bash -c "! grep -F 'mountpoint -q /data &&' '$STUB_STATE/commands.log'"
STUB_PING=ConnectionLost run check
check "SSM이 Online이 아니면 실패" rc_is 1

echo "measure 모드 — 사양 확정용 지표 수집"
unset_stubs; run measure
check "종료코드 0, 명령 3개(BE, AI, FE)" bash -c "test '$rc' = 0 && test '$(sends)' = 3"
check "각 인스턴스로 전송" bash -c "grep -q 'i-0be0000000000001' '$STUB_STATE/sends.log' && grep -q 'i-0a10000000000002' '$STUB_STATE/sends.log' && grep -q 'i-0fe0000000000003' '$STUB_STATE/sends.log'"
check "메모리·CPU·디스크·컨테이너 지표를 수집" bash -c "grep -q 'free -m' '$STUB_STATE/commands.log' && grep -q 'docker stats --no-stream' '$STUB_STATE/commands.log' && grep -q 'df -h' '$STUB_STATE/commands.log' && grep -q 'uptime' '$STUB_STATE/commands.log'"
check "읽기 전용(배포·삭제·재시작 명령이 없음)" bash -c "! grep -E 'docker (run|rm|stop|start|pull)|rm -|systemctl (restart|stop)' '$STUB_STATE/commands.log'"
check "배포 기록을 남기지 않음" bash -c "! test -s '$STUB_STATE/params.log'"
check "measure는 SHA를 요구하지 않음" rc_is 0

echo "deploy — 컴포넌트별 대상·순서·인자"
unset_stubs; run deploy "$SHA_A" "$SHA_B" "$SHA_C"
check "셋 다 지정 → 종료코드 0, 명령 3개" bash -c "test '$rc' = 0 && test '$(sends)' = 3"
check "1번째가 AI이고 AI 인스턴스로 전송" send_n_has 1 "i-0a10000000000002"
check "AI 이미지는 AI 변수 기본값과 SHA로 조립" send_n_has 1 "42voicebridge_ai:sha-$SHA_B"
check "AI는 GHCR 시크릿과 버킷을 받음(앱 시크릿 없음)" bash -c "sed -n 1p '$STUB_STATE/sends.log' | grep -q 'voicebridge/dev/ghcr' && ! sed -n 1p '$STUB_STATE/sends.log' | grep -q 'voicebridge/dev/app'"
check "AI 타임아웃 1800초" send_n_has 1 "timeout=1800"
check "2번째가 BE이고 BE 인스턴스로 전송" send_n_has 2 "i-0be0000000000001"
check "BE 인자에 앱 시크릿과 GHCR 시크릿이 모두 포함" bash -c "sed -n 2p '$STUB_STATE/sends.log' | grep -q 'voicebridge/dev/app' && sed -n 2p '$STUB_STATE/sends.log' | grep -q 'voicebridge/dev/ghcr'"
check "BE 타임아웃 900초" send_n_has 2 "timeout=900"
check "3번째가 FE이고 FE 인스턴스로 전송" send_n_has 3 "i-0fe0000000000003"
check "FE 인자에 공개 호스트(EIP DNS)" send_n_has 3 "ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com"
check "FE 인자에 BE 업스트림(고정 사설 IP:8080)" send_n_has 3 "http://10.0.1.10:8080"
check "FE 이미지는 FE 변수 기본값과 SHA로 조립" send_n_has 3 "42voicebridge_fe:sha-$SHA_C"
run deploy "" "" "$SHA_C"
check "FE만 → 명령 1개(FE 인스턴스)" bash -c "test '$(sends)' = 1 && grep -q 'i-0fe0000000000003' '$STUB_STATE/sends.log'"
run deploy "$SHA_A" ""
check "BE만 → 명령 1개(BE 인스턴스)" bash -c "test '$(sends)' = 1 && grep -q 'i-0be0000000000001' '$STUB_STATE/sends.log'"
run deploy "" "$SHA_B"
check "AI만 → 명령 1개(AI 인스턴스)" bash -c "test '$(sends)' = 1 && grep -q 'i-0a10000000000002' '$STUB_STATE/sends.log'"
check "배포 직전에 인스턴스 ID를 조회(오래된 ID를 쓰지 않음)" grep -Fq "output -raw ai_instance_id" "$STUB_STATE/terraform.log"

echo "deploy — 앞 컴포넌트가 실패하면 뒤 컴포넌트는 배포하지 않음"
STUB_FAIL_AT=1 run deploy "$SHA_A" "$SHA_B" "$SHA_C"
check "AI 실패 → 종료코드 1" rc_is 1
check "BE·FE 명령을 보내지 않음(명령 1개)" test "$(sends)" = 1
check "실패 사유 출력" err_has "deploy-ai failed"
STUB_FAIL_AT=2 run deploy "$SHA_A" "$SHA_B" "$SHA_C"
check "BE 실패 → 종료코드 1" rc_is 1
check "FE를 배포하지 않음(명령 2개)" test "$(sends)" = 2

echo "배포 기록(SSM Parameter Store)"
unset_stubs; run deploy "$SHA_A" "$SHA_B" "$SHA_C"
check "성공한 컴포넌트마다 이미지가 기록됨" bash -c "grep -q '/voicebridge/dev/deployed/ai=.*ai:sha-$SHA_B' '$STUB_STATE/params.log' && grep -q '/voicebridge/dev/deployed/be=.*be:sha-$SHA_A' '$STUB_STATE/params.log' && grep -q '/voicebridge/dev/deployed/fe=.*fe:sha-$SHA_C' '$STUB_STATE/params.log'"
STUB_FAIL_AT=1 run deploy "$SHA_A" "$SHA_B" "$SHA_C"
check "실패한 배포는 기록하지 않음" bash -c "! grep -q 'deployed/ai' '$STUB_STATE/params.log'"
STUB_PUT_FAIL=1 run deploy "" "$SHA_B"
check "기록 권한이 없어도 배포는 성공" rc_is 0
check "기록 실패 경고 출력" err_has "could not record ai deployment"

echo "redeploy — 인스턴스 교체 후 마지막 배포로 복원"
unset_stubs
STUB_PARAM_AI="ghcr.io/42voicebridge/42voicebridge_ai:sha-$SHA_B" STUB_PARAM_BE="ghcr.io/42voicebridge/42voicebridge_be:sha-$SHA_A" STUB_PARAM_FE="ghcr.io/42voicebridge/42voicebridge_fe:sha-$SHA_C" run redeploy
check "종료코드 0, 명령 3개" bash -c "test '$rc' = 0 && test '$(sends)' = 3"
check "AI → BE → FE 순서로 기록된 SHA를 배포" bash -c "sed -n 1p '$STUB_STATE/sends.log' | grep -q 'ai:sha-$SHA_B' && sed -n 2p '$STUB_STATE/sends.log' | grep -q 'be:sha-$SHA_A' && sed -n 3p '$STUB_STATE/sends.log' | grep -q 'fe:sha-$SHA_C'"
STUB_PARAM_AI="ghcr.io/42voicebridge/42voicebridge_ai:sha-$SHA_B" run redeploy
check "기록이 있는 컴포넌트만 배포(AI만)" bash -c "test '$(sends)' = 1 && grep -q 'ai:sha-$SHA_B' '$STUB_STATE/sends.log'"
check "기록이 없는 컴포넌트는 건너뛴다는 메시지" out_has "No recorded deployment for be"
unset_stubs; run redeploy
check "기록이 전혀 없으면 아무것도 하지 않고 성공" bash -c "test '$rc' = 0 && test '$(sends)' = 0"
STUB_PARAM_AI="garbage-value" run redeploy
check "형식이 맞지 않는 기록은 무시" bash -c "test '$rc' = 0 && test '$(sends)' = 0"

echo "이미지 저장소 변수"
unset_stubs; AI_IMAGE_REPOSITORY=ghcr.io/42voicebridge/custom-ai run deploy "" "$SHA_B"
check "AI_IMAGE_REPOSITORY 값으로 이미지 조립" send_n_has 1 "custom-ai:sha-$SHA_B"
BE_IMAGE_REPOSITORY=ghcr.io/42voicebridge/custom-be run deploy "$SHA_A" ""
check "BE_IMAGE_REPOSITORY 값으로 이미지 조립" send_n_has 1 "custom-be:sha-$SHA_A"
FE_IMAGE_REPOSITORY=ghcr.io/42voicebridge/custom-fe run deploy "" "" "$SHA_C"
check "FE_IMAGE_REPOSITORY 값으로 이미지 조립" send_n_has 1 "custom-fe:sha-$SHA_C"
AI_IMAGE_REPOSITORY="ghcr.io/evil/x" run deploy "" "$SHA_B"
check "다른 조직 경로는 거부 → 2" rc_is 2
check "거부 시 SSM 명령을 보내지 않음" test "$(sends)" = 0
FE_IMAGE_REPOSITORY='<실제-FE-패키지명>' run deploy "" "" "$SHA_C"
check "자리 표시자 값은 거부 → 2" rc_is 2
AI_IMAGE_REPOSITORY="" run deploy "" "$SHA_B"
check "변수가 비어 있으면 기본 이름 사용" send_n_has 1 "42voicebridge_ai:sha-$SHA_B"

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
