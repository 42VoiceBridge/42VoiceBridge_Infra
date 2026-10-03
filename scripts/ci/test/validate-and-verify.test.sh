#!/usr/bin/env bash
# validate-dispatch.sh, verify-source-commit.sh, deploy-component.sh 테스트.
# 실행: bash scripts/ci/test/validate-and-verify.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
validate=$repo_root/scripts/ci/validate-dispatch.sh
verify=$repo_root/scripts/ci/verify-source-commit.sh
deploy=$repo_root/scripts/ci/deploy-component.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0 fail=0
SHA=$(printf 'b%.0s' {1..40})
REPO=ghcr.io/42voicebridge/42voicebridge_ai

check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }

# --- validate-dispatch.sh -------------------------------------------------------
run_validate() { # REF SHA IMAGE REPO
  DISPATCH_REF=$1 DISPATCH_SHA=$2 DISPATCH_IMAGE=$3 IMAGE_REPOSITORY=$4 COMPONENT_LABEL=AI \
    GITHUB_OUTPUT="$work/gh_output" bash "$validate" >"$work/out" 2>&1
  rc=$?
}
: >"$work/gh_output"
echo "payload 형식 검증"
run_validate refs/heads/main "$SHA" "$REPO:sha-$SHA" "$REPO"
check "정상 payload 통과" rc_is 0
check "조립한 이미지를 GITHUB_OUTPUT에 기록" grep -Fxq "image=$REPO:sha-$SHA" "$work/gh_output"
run_validate refs/heads/main "$SHA" "" "$REPO"
check "image 필드가 없어도 통과(SHA와 변수로 조립)" rc_is 0
run_validate refs/heads/develop "$SHA" "" "$REPO";        check "main이 아닌 ref 거부" rc_is 1
run_validate refs/pull/1/merge "$SHA" "" "$REPO";         check "PR ref 거부" rc_is 1
run_validate refs/heads/main "${SHA:0:7}" "" "$REPO";     check "7자 단축 SHA 거부" rc_is 1
run_validate refs/heads/main "${SHA^^}" "" "$REPO";       check "대문자 SHA 거부" rc_is 1
run_validate refs/heads/main "$SHA" "$REPO:sha-$SHA" "ghcr.io/evil/x";  check "다른 조직의 저장소 변수 거부" rc_is 1
run_validate refs/heads/main "$SHA" "$REPO:sha-$SHA" "";  check "저장소 변수가 비어 있으면 거부" rc_is 1
run_validate refs/heads/main "$SHA" "$REPO:sha-$SHA" '<실제-AI-패키지명>'; check "자리 표시자 변수 거부" rc_is 1
run_validate refs/heads/main "$SHA" "ghcr.io/42voicebridge/other:sha-$SHA" "$REPO"
check "payload image가 변수와 다르면 거부(임의 이미지 방지)" rc_is 1
run_validate refs/heads/main "$SHA" "$REPO:sha-$(printf 'c%.0s' {1..40})" "$REPO"
check "payload image의 SHA가 다르면 거부" rc_is 1
run_validate refs/heads/main "$SHA; echo pwned" "" "$REPO"
check "명령 삽입 시도 거부" rc_is 1
check "삽입 문자열이 실행되지 않음" bash -c "! grep -q '^pwned' '$work/out'"

# --- verify-source-commit.sh ----------------------------------------------------
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
echo "curl $url" >>"$STUB_STATE/curl.log"
[[ -z "${STUB_API_FAIL:-}" ]] || exit 22
printf '{"status":"%s"}' "${STUB_STATUS-identical}"
STUB
chmod +x "$work/bin/curl"
export STUB_STATE=$work
run_verify() { # REPO SHA [BASE]
  PATH=$work/bin:$PATH GITHUB_TOKEN=tok bash "$verify" "$@" >"$work/out" 2>&1
  rc=$?
}
echo "출처 검증(소스 레포 main 포함 여부)"
STUB_STATUS=identical run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";  check "main과 같은 커밋 통과" rc_is 0
STUB_STATUS=behind run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";     check "main의 조상 커밋 통과" rc_is 0
STUB_STATUS=ahead run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";      check "main에 없는 새 커밋(ahead) 거부" rc_is 1
STUB_STATUS=diverged run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";   check "다른 가지(diverged) 거부" rc_is 1
STUB_API_FAIL=1 run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";        check "API 오류·존재하지 않는 커밋이면 거부(fail closed)" rc_is 1
STUB_STATUS="" run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA";         check "상태를 알 수 없으면 거부" rc_is 1
run_verify evil/repo "$SHA";                                              check "다른 조직의 소스 레포 거부" rc_is 1
run_verify 42VoiceBridge/42VoiceBridge_AI "${SHA:0:7}";                   check "단축 SHA 거부" rc_is 1
run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA" 'main;rm -rf /';         check "기본 브랜치 이름에 명령 삽입 거부" rc_is 1
STUB_STATUS=identical run_verify 42VoiceBridge/42VoiceBridge_AI "$SHA" develop
check "기본 브랜치를 지정할 수 있음(compare 경로에 반영)" grep -Fq "compare/develop...$SHA" "$work/curl.log"

# --- deploy-component.sh --------------------------------------------------------
cat >"$work/fake_run.sh" <<'STUB'
#!/usr/bin/env bash
echo "run.sh $* | BE=${BE_IMAGE_REPOSITORY:-} AI=${AI_IMAGE_REPOSITORY:-} FE=${FE_IMAGE_REPOSITORY:-}" >"$STUB_STATE/run_call.txt"
STUB
run_deploy() { # COMPONENT
  RUN_SH=$work/fake_run.sh IMAGE_REPOSITORY=$REPO bash "$deploy" "$1" "$SHA" >"$work/out" 2>&1
  rc=$?
}
echo "컴포넌트 배포 매핑"
run_deploy be; check "be → SHA가 BE 자리에만" grep -Fq "run.sh deploy $SHA   | BE=$REPO AI= FE=" "$work/run_call.txt"
run_deploy ai; check "ai → SHA가 AI 자리에만" grep -Fq "run.sh deploy  $SHA  | BE= AI=$REPO FE=" "$work/run_call.txt"
run_deploy fe; check "fe → SHA가 FE 자리에만" grep -Fq "run.sh deploy   $SHA | BE= AI= FE=$REPO" "$work/run_call.txt"
run_deploy xx; check "알 수 없는 컴포넌트 거부" rc_is 2

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
