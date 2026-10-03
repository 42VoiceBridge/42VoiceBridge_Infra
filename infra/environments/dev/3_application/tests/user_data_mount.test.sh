#!/usr/bin/env bash
# user_data.sh.tftpl의 데이터 볼륨 마운트 로직 분기 테스트. blkid/mkfs/mount 등을 스텁으로 대체하고
# fstab·마운트 경로를 임시 디렉터리로 바꿔서 실행한다(호스트의 /etc/fstab, /data는 건드리지 않는다).
# 실행: bash infra/environments/dev/3_application/tests/user_data_mount.test.sh
set -uo pipefail

tpl=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/user_data.sh.tftpl
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
pass=0 fail=0

mkdir -p "$work/bin"
cat >"$work/bin/blkid" <<'STUB'
#!/usr/bin/env bash
echo "blkid $*" >>"$T/calls"
if [[ "$1" == -p ]]; then exit "${STUB_BLKID_RC:-0}"; fi   # -p: 시그니처 탐지
echo "1111-2222-uuid"                                      # -o value -s UUID
STUB
# shellcheck disable=SC2016  # 스텁 본문의 변수는 스텁 실행 시점에 펼쳐져야 한다
printf '#!/usr/bin/env bash\necho "mkfs $*" >>"$T/calls"\n' >"$work/bin/mkfs"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "mount $*" >>"$T/calls"\n' >"$work/bin/mount"
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/mountpoint"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin"/*

# 템플릿에서 함수 본문만 꺼내 경로를 임시 디렉터리로 치환한다. 장치 존재 검사는 일반 파일로 대체한다.
run_case() { # run_case DEVICE_EXISTS(1/0) BLKID_RC
  export T=$work/case STUB_BLKID_RC=$2
  rm -rf "$T" && mkdir -p "$T" && : >"$T/fstab"
  [[ "$1" == 1 ]] && : >"$T/device"
  awk '/^mount_data_volume\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$tpl" \
    | sed -e "s#\${data_device}#$T/device#" -e "s#/etc/fstab#$T/fstab#g" \
          -e "s#mount_point=/data#mount_point=$T/data#" -e 's/ -b "/ -e "/g' >"$T/fn.sh"
  PATH=$work/bin:$PATH bash -c "source '$T/fn.sh'; mount_data_volume" >"$T/out" 2>"$T/err"
  rc=$?
}
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "  ok   - $d"; else fail=$((fail+1)); echo "  FAIL - $d"; fi; }
called() { grep -q "^$1" "$T/calls" 2>/dev/null; }
not_called() { ! called "$1"; }

echo "빈 볼륨(blkid -p 종료코드 2)"
run_case 1 2
check "성공" test "$rc" = 0
check "xfs 포맷 수행" called "mkfs -t xfs"
check "fstab에 UUID로 등록(nofail)" grep -q '^UUID=1111-2222-uuid .* xfs defaults,nofail' "$T/fstab"
check "마운트 수행" called "mount "
check "ai/hf, ai/adapters 생성" test -d "$T/data/ai/hf" -a -d "$T/data/ai/adapters"

echo "기존 데이터가 있는 볼륨(blkid -p 종료코드 0)"
run_case 1 0
check "성공" test "$rc" = 0
check "포맷하지 않음(데이터 보존)" not_called "mkfs"
check "fstab 등록" grep -q '^UUID=1111-2222-uuid ' "$T/fstab"

echo "blkid 자체 오류(종료코드 1)"
run_case 1 1
check "실패로 종료" test "$rc" = 1
check "절대 포맷하지 않음" not_called "mkfs"
check "fstab을 건드리지 않음" test ! -s "$T/fstab"
check "포맷 거부 사유 출력" grep -q "refusing to format" "$T/err"

echo "장치가 나타나지 않음"
run_case 0 2
check "실패로 종료" test "$rc" = 1
check "포맷하지 않음" not_called "mkfs"
check "사유 출력" grep -q "did not appear" "$T/err"

echo "멱등성: 이미 fstab에 있으면 중복 등록하지 않음"
run_case 1 0
echo "UUID=1111-2222-uuid $T/data xfs defaults,nofail 0 2" >"$T/fstab"
PATH=$work/bin:$PATH bash -c "source '$T/fn.sh'; mount_data_volume" >/dev/null 2>&1
check "fstab 항목이 1개" test "$(grep -c '^UUID=1111-2222-uuid ' "$T/fstab")" = 1

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
