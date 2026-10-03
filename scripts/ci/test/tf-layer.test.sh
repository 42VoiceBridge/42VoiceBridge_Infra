#!/usr/bin/env bash
# tf-layer.sh(레이어 순서 강제, 저장된 plan만 apply, 파괴 방지)와 post-apply.sh 테스트.
# terraform/aws를 스텁으로 대체한다. 실행: bash scripts/ci/test/tf-layer.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
layer_sh=$repo_root/scripts/ci/tf-layer.sh
post_sh=$repo_root/scripts/ci/post-apply.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0 fail=0

cat >"$work/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >>"$STUB_STATE/tf.log"
args=("$@")
# -chdir 이후의 하위 명령 찾기
sub=""; for a in "$@"; do case "$a" in -chdir=*) ;; init|plan|apply|show) sub=$a; break ;; esac; done
case "$sub" in
  init) exit 0 ;;
  plan)
    for a in "$@"; do case "$a" in -out=*) out=${a#-out=} ;; esac; done
    [[ -z "${STUB_PLAN_ERROR:-}" ]] || { echo "Error: boom"; exit 1; }
    echo "plan-content-${STUB_PLAN_VARIANT:-v1}" >"$out"
    [[ -n "${STUB_NO_CHANGES:-}" ]] && exit 0
    exit 2 ;;
  show)
    if printf '%s\n' "$@" | grep -q -- '-json'; then
      if [[ -n "${STUB_DESTROY:-}" ]]; then
        echo '{"resource_changes":[{"address":"aws_instance.be","change":{"actions":["delete","create"]}},{"address":"aws_eip.fe","change":{"actions":["create"]}}]}'
      else
        echo '{"resource_changes":[{"address":"aws_eip.fe","change":{"actions":["create"]}}]}'
      fi
    else
      echo "Terraform will perform the following actions: ..."
    fi ;;
  apply) echo "applied $(cat "${!#}")" >>"$STUB_STATE/apply.log" ;;
esac
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$STUB_STATE/aws.log"
key=$(printf '%s\n' "$@" | grep -A1 '^--key$' | tail -1)
layer=${key#dev/}; layer=${layer%/terraform.tfstate}
case " ${STUB_APPLIED:-} " in *" $layer "*) exit 0 ;; *) exit 254 ;; esac
STUB
chmod +x "$work/bin"/*

setup() {
  export STUB_STATE=$work/state
  rm -rf "$STUB_STATE" "$work/plan" && mkdir -p "$STUB_STATE" "$work/plan"
  export GITHUB_STEP_SUMMARY=$work/summary && : >"$GITHUB_STEP_SUMMARY"
}
T() { # T ARGS...
  (cd "$repo_root" && PATH=$work/bin:$PATH \
    TF_VAR_ssh_allowed_cidr=${TF_VAR_ssh_allowed_cidr-203.0.113.5/32} TF_VAR_ssh_key_name=${TF_VAR_ssh_key_name-test-key} \
    bash "$layer_sh" "$@") >"$work/out" 2>&1
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }
out_has() { grep -Fq -- "$1" "$work/out"; }
tf_log_has() { grep -Fq -- "$1" "$STUB_STATE/tf.log"; }

echo "레이어 순서 강제 (하위 state가 없으면 상위 레이어 거부)"
setup; STUB_APPLIED="" T plan 2_storage "$work/plan"
check "1_base 전에 2_storage plan 거부" rc_is 1
check "안내 메시지에 먼저 적용할 레이어" out_has "Layer 1_base has no state yet"
setup; STUB_APPLIED="1_base" T plan 3_application "$work/plan"
check "2_storage 전에 3_application plan 거부" rc_is 1
check "2_storage를 먼저 적용하라는 안내" out_has "Layer 2_storage has no state yet"
check "거부 시 terraform을 실행하지 않음" bash -c "! test -e '$STUB_STATE/tf.log'"
setup; STUB_APPLIED="" T plan 1_base "$work/plan"
check "1_base는 선행 레이어가 없어 plan 가능" rc_is 0
setup; STUB_APPLIED="1_base" T plan 2_storage "$work/plan"
check "1_base 적용 후 2_storage plan 가능" rc_is 0
setup; STUB_APPLIED="" T apply 2_storage "$work/plan"
check "apply도 순서를 강제" rc_is 1
setup; T plan 9_bad "$work/plan"
check "알 수 없는 레이어는 사용법 출력(2)" rc_is 2

echo "plan: 필수 입력 변수 검증"
setup; TF_VAR_ssh_allowed_cidr="" STUB_APPLIED="" T plan 1_base "$work/plan"
check "SSH_ALLOWED_CIDR가 비어 있으면 1_base plan 거부" rc_is 1
check "설정 안내 출력" out_has "SSH_ALLOWED_CIDR"
setup; TF_VAR_ssh_allowed_cidr="0.0.0.0/0" STUB_APPLIED="" T plan 1_base "$work/plan"
check "SSH를 0.0.0.0/0으로 여는 값 거부" rc_is 1
check "거부 시 terraform을 실행하지 않음" bash -c "! test -e '$STUB_STATE/tf.log'"
setup; TF_VAR_ssh_key_name="" STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"
check "SSH_KEY_NAME이 비어 있으면 3_application plan 거부" rc_is 1
setup; TF_VAR_ssh_key_name="" STUB_APPLIED="1_base" T plan 2_storage "$work/plan"
check "2_storage는 SSH 변수가 필요 없음" rc_is 0

echo "plan: 저장·요약·잠금 유지"
setup; STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"
check "종료코드 0" rc_is 0
check "저장된 plan 파일과 메타데이터 생성" test -f "$work/plan/tfplan" -a -f "$work/plan/meta.json" -a -f "$work/plan/plan.txt"
check "메타데이터에 레이어와 커밋과 체크섬" bash -c "jq -e '.layer==\"3_application\" and (.commit|length==40) and (.tfplan_sha256|length==64) and .has_changes==true' '$work/plan/meta.json' >/dev/null"
check "잠금을 끄지 않음(-lock=false 금지)" bash -c "! grep -q -- '-lock=false' '$STUB_STATE/tf.log'"
check "잠금 대기 시간 지정(-lock-timeout)" tf_log_has "-lock-timeout=5m"
check "init은 잠금 파일을 읽기 전용으로" tf_log_has "-lockfile=readonly"
check "요약에 레이어 제목" grep -Fq "Terraform plan: 3_application" "$GITHUB_STEP_SUMMARY"
setup; STUB_APPLIED="1_base 2_storage" STUB_PLAN_ERROR=1 T plan 3_application "$work/plan"
check "plan 실패는 실패로 처리" rc_is 1
setup; STUB_APPLIED="1_base 2_storage" STUB_NO_CHANGES=1 T plan 3_application "$work/plan"
check "변경이 없으면 has_changes=false" bash -c "jq -e '.has_changes==false' '$work/plan/meta.json' >/dev/null"

echo "apply: 검토한 plan 파일만 적용"
setup; STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"; STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "저장된 plan으로 apply 성공" rc_is 0
check "plan 파일을 지정해 apply(재계산 없음)" bash -c "grep -q 'apply .*tfplan' '$STUB_STATE/tf.log'"
check "plan 내용이 그대로 적용됨" grep -Fq "applied plan-content-v1" "$STUB_STATE/apply.log"
setup; STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "plan 없이 apply 거부" rc_is 1
check "plan 먼저 실행하라는 안내" out_has "Run the plan workflow first"
setup; STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"; STUB_APPLIED="1_base 2_storage" T apply 2_storage "$work/plan"
check "다른 레이어의 plan으로는 apply 거부" rc_is 1
setup; STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"; jq '.commit="0000000000000000000000000000000000000000"' "$work/plan/meta.json" >"$work/m" && mv "$work/m" "$work/plan/meta.json"; STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "plan 이후 코드(커밋)가 바뀌었으면 거부" rc_is 1
check "커밋 불일치 안내" out_has "different commit"
setup; STUB_APPLIED="1_base 2_storage" T plan 3_application "$work/plan"; echo tampered >"$work/plan/tfplan"; STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "plan 파일이 바뀌었으면(체크섬 불일치) 거부" rc_is 1
check "적용하지 않음" bash -c "! test -e '$STUB_STATE/apply.log'"
setup; STUB_APPLIED="1_base 2_storage" STUB_NO_CHANGES=1 T plan 3_application "$work/plan"; STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "변경 없는 plan은 적용하지 않고 성공" rc_is 0
check "apply를 실행하지 않음" bash -c "! test -e '$STUB_STATE/apply.log'"

echo "apply: 삭제·교체 방지"
setup; STUB_APPLIED="1_base 2_storage" STUB_DESTROY=1 T plan 3_application "$work/plan"
check "plan 메타데이터에 삭제 건수 기록" bash -c "jq -e '.destroy_count==1' '$work/plan/meta.json' >/dev/null"
check "요약에 삭제 대상 표시" grep -Fq "aws_instance.be" "$GITHUB_STEP_SUMMARY"
STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "삭제·교체가 있으면 allow_destroy 없이 거부" rc_is 1
check "삭제 대상 목록 출력" out_has "aws_instance.be"
check "거부 시 적용하지 않음" bash -c "! test -e '$STUB_STATE/apply.log'"
ALLOW_DESTROY=true STUB_APPLIED="1_base 2_storage" T apply 3_application "$work/plan"
check "allow_destroy=true이면 적용" rc_is 0

echo "post-apply: 인스턴스 교체 후 복원"
cat >"$work/fake_run.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_STATE/run.log"
if [[ "$1" == check ]]; then
  n=$(grep -c '^check' "$STUB_STATE/run.log")
  (( n > ${STUB_CHECK_FAILS:-0} )) || exit 1
fi
STUB
P() { (cd "$repo_root" && PATH=$work/bin:$PATH RUN_SH=$work/fake_run.sh POST_APPLY_TRIES=${TRIES:-5} POST_APPLY_PAUSE=0 bash "$post_sh" "$@") >"$work/out" 2>&1; rc=$?; }
setup; P 1_base
check "3_application이 아니면 아무것도 하지 않음" bash -c "test '$rc' = 0 && ! test -e '$STUB_STATE/run.log'"
setup; P 3_application
check "check 통과 후 redeploy" bash -c "test '$rc' = 0 && grep -qx 'redeploy' '$STUB_STATE/run.log'"
setup; STUB_CHECK_FAILS=2 P 3_application
check "새 인스턴스가 준비될 때까지 check를 재시도" bash -c "test '$rc' = 0 && test \$(grep -c '^check' '$STUB_STATE/run.log') = 3"
setup; STUB_CHECK_FAILS=99 TRIES=3 P 3_application
check "끝내 준비되지 않으면 실패" rc_is 1
check "준비되지 않았으면 redeploy하지 않음" bash -c "! grep -qx 'redeploy' '$STUB_STATE/run.log'"

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
