#!/usr/bin/env bash
# infra-lock.sh 테스트. aws s3api를 디렉터리 기반 스텁으로 바꾸고 조건부 쓰기(--if-none-match)를 흉내 낸다.
# 경쟁 상황은 스텁이 특정 시점에 상대 락을 만들거나 지우는 방식으로 재현한다.
# 실행: bash scripts/ci/test/infra-lock.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
lock=$repo_root/scripts/ci/infra-lock.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0 fail=0

cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
B=$STUB_BUCKET_DIR
f() { printf '%s/%s' "$B" "${1//\//__}"; }
key=$(printf '%s\n' "$@" | grep -A1 '^--key$' | tail -1)
case "$2" in
  head-object) [[ -e "$(f "$key")" ]] ;;
  put-object)
    body=$(printf '%s\n' "$@" | grep -A1 '^--body$' | tail -1)
    [[ -z "${STUB_PUT_ERROR:-}" ]] || exit 255
    [[ ! -e "$(f "$key")" ]] || exit 254          # PreconditionFailed
    cp "$body" "$(f "$key")"
    # 경쟁 재현: 배포 락이 만들어진 직후 apply 락이 생긴다(한 번만).
    if [[ -n "${STUB_RACE_APPLY:-}" && "$key" == */deploy-* && ! -e "$B/.raced" ]]; then
      : >"$B/.raced"; echo '{"created_at":'"${STUB_NOW:-1000}"'}' >"$(f "locks/dev/apply")"
    fi ;;
  get-object) out=${@: -1}; [[ -e "$(f "$key")" ]] && cp "$(f "$key")" "$out" ;;
  delete-object) rm -f "$(f "$key")" ;;
  list-objects-v2)
    prefix=$(printf '%s\n' "$@" | grep -A1 '^--prefix$' | tail -1)
    # 경쟁 재현: 처음 N번 조회에는 진행 중인 배포 락이 보이다가 이후 사라진다.
    if [[ -n "${STUB_DEPLOY_CLEARS_AFTER:-}" ]]; then
      n=$(cat "$B/.polls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$B/.polls"
      if (( n > STUB_DEPLOY_CLEARS_AFTER )); then rm -f "$(f "locks/dev/deploy-be")"; fi
    fi
    out=""
    for p in "$B"/*; do
      [[ -f "$p" ]] || continue
      k=$(basename "$p"); k=${k//__//}
      [[ "$k" == "$prefix"* ]] && out+="$k"$'\t'
    done
    [[ -n "$out" ]] && printf '%s\n' "${out%$'\t'}" || echo None ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin"/*

fresh() { rm -rf "$work/bucket" && mkdir -p "$work/bucket"; rm -f "$work/bucket/.raced" "$work/bucket/.polls"; export STUB_BUCKET_DIR=$work/bucket; }
L() { # L ARGS... — 대기 시간을 짧게(3번 시도) 해서 실행
  PATH=$work/bin:$PATH LOCK_WAIT_SECONDS=60 LOCK_INTERVAL=20 LOCK_NOW=${STUB_NOW:-1000} bash "$lock" "$@" >"$work/out" 2>&1
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
rc_is() { [[ "$rc" == "$1" ]]; }
has() { [[ -e "$work/bucket/${1//\//__}" ]]; }
absent() { ! has "$1"; }
out_has() { grep -Fq -- "$1" "$work/out"; }

echo "배포 락"
fresh; L acquire deploy ai 11
check "락이 없으면 획득" rc_is 0
check "배포 락 객체가 생김" has locks/dev/deploy-ai
L release deploy ai
check "해제하면 사라짐" absent locks/dev/deploy-ai
fresh; L acquire deploy ai 11; L acquire deploy be 12
check "다른 컴포넌트는 동시에 획득(병렬 배포)" bash -c "test -e '$work/bucket/locks__dev__deploy-ai' && test -e '$work/bucket/locks__dev__deploy-be'"
fresh; L acquire deploy ai 11; L acquire deploy ai 12
check "같은 컴포넌트는 직렬화(두 번째는 대기 후 실패)" rc_is 1
check "시간 초과 메시지" out_has "Timed out waiting for the ai deploy lock"
fresh; : >"$work/bucket/locks__dev__apply"; echo '{"created_at":1000}' >"$work/bucket/locks__dev__apply"; L acquire deploy fe 13
check "apply 락이 있으면 배포는 기다리다 실패" rc_is 1
check "기다리는 동안 배포 락을 남기지 않음" absent locks/dev/deploy-fe
check "대기 사유 출력" out_has "Terraform apply holds the infra lock"

echo "apply 락"
fresh; L acquire apply 21
check "락이 없으면 획득" rc_is 0
check "apply 락 객체가 생김" has locks/dev/apply
L release apply
check "해제하면 사라짐" absent locks/dev/apply
fresh; L acquire apply 21; L acquire apply 22
check "apply가 이미 있으면 두 번째는 실패" rc_is 1
fresh; echo '{"created_at":1000}' >"$work/bucket/locks__dev__deploy-ai"; L acquire apply 23
check "진행 중인 배포가 있으면 apply는 기다리다 실패" rc_is 1
check "실패한 apply는 자기 락을 남기지 않음(배포를 막지 않음)" absent locks/dev/apply
check "대기 사유 출력" out_has "service deployments are still running"

echo "경쟁 상황"
fresh; STUB_RACE_APPLY=1 L acquire deploy ai 31
check "배포 락 생성 직후 apply가 시작되면 배포가 양보(획득 실패)" rc_is 1
check "양보한 배포는 자기 락을 지움" absent locks/dev/deploy-ai
check "apply 락은 그대로 유지" has locks/dev/apply
check "양보 메시지" out_has "yielding"
fresh; echo '{"created_at":1000}' >"$work/bucket/locks__dev__deploy-be"; STUB_DEPLOY_CLEARS_AFTER=1 L acquire apply 32
check "진행 중이던 배포가 끝나면 apply가 이어서 획득" rc_is 0
check "apply 락 보유" has locks/dev/apply

echo "오래된 락 정리"
fresh; echo '{"created_at":1}' >"$work/bucket/locks__dev__apply"; STUB_NOW=100000 L acquire deploy ai 41
check "2시간 넘은 apply 락은 정리하고 획득" rc_is 0
check "정리 경고 출력" out_has "Removing stale lock"
fresh; echo '{"created_at":99000}' >"$work/bucket/locks__dev__apply"; STUB_NOW=100000 L acquire deploy ai 42
check "최근 apply 락은 정리하지 않음" rc_is 1
fresh; echo '{"created_at":1}' >"$work/bucket/locks__dev__deploy-ai"; STUB_NOW=100000 L acquire apply 43
check "오래된 배포 락은 apply가 정리하고 진행" rc_is 0

echo "오류 처리"
fresh; STUB_PUT_ERROR=1 L acquire deploy ai 51
check "락 생성 권한 오류는 대기하지 않고 즉시 실패" rc_is 1
check "권한 확인 안내 출력" out_has "check bucket permissions"
L bogus
check "알 수 없는 명령은 사용법 출력(2)" rc_is 2

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
