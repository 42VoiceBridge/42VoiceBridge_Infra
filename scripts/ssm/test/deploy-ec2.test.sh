#!/usr/bin/env bash
# deploy-ec2.sh 동작 테스트. 실제 Docker/AWS 없이 PATH 앞에 스텁(docker, aws, curl, mountpoint,
# sleep, chown)을 두고 컨테이너 상태를 파일로 흉내 낸다. 실행: bash scripts/ssm/test/deploy-ec2.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
script=${DEPLOY_SCRIPT:-$repo_root/scripts/ssm/deploy-ec2.sh}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

BE_IMAGE=ghcr.io/42voicebridge/42voicebridge_be:sha-$(printf 'a%.0s' {1..40})
AI_IMAGE=ghcr.io/42voicebridge/42voicebridge_ai:sha-$(printf 'b%.0s' {1..40})
APP_JSON='{"JWT_SECRET":"jwt-value","NCP_TTS_API_KEY_ID":"ncp-id","NCP_TTS_API_KEY":"ncp-key"}'
RDS_JSON='{"username":"dbuser","password":"dbpass"}'

pass=0 fail=0

# --- 스텁 --------------------------------------------------------------------
make_stubs() {
  local bin=$work/bin
  mkdir -p "$bin"

  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
S=$STUB_STATE
echo "docker $*" >>"$S/docker.log"
touch "$S/containers" "$S/networks"
case "$1" in
  info) exit 0 ;;
  ps) cat "$S/containers" ;;
  network)
    case "$2" in
      inspect) grep -Fxq "$3" "$S/networks" ;;
      create) echo "$3" >>"$S/networks" ;;
    esac ;;
  login) cat >"$S/login_stdin" ;;
  pull) exit 0 ;;
  rename) sed -i "s/^$2\$/$3/" "$S/containers" ;;
  stop|start) exit 0 ;;
  rm)
    name=${@: -1}
    sed -i "/^$name\$/d" "$S/containers" ;;
  run)
    if [[ " $* " == *" --entrypoint id "* ]]; then
      [[ -z "${STUB_NO_ID:-}" ]] || exit 1
      [[ "${@: -1}" == -u ]] && echo "${STUB_UID:-1000}" || echo "${STUB_GID:-1000}"
      exit 0
    fi
    [[ -z "${STUB_RUN_FAIL:-}" ]] || exit 1
    args=("$@")
    for i in "${!args[@]}"; do
      case "${args[$i]}" in
        --name) echo "${args[$((i+1))]}" >>"$S/containers" ;;
        --env-file) cp "${args[$((i+1))]}" "$S/env_file_copy" ;;
      esac
    done ;;
  inspect)
    fmt=$3
    case "$fmt" in
      *Running*) echo "${STUB_RUNNING:-true}" ;;
      *RestartCount*) echo "${STUB_RESTARTS:-0}" ;;
      *IPAddress*) echo 172.18.0.5 ;;
    esac ;;
esac
STUB

  cat >"$bin/aws" <<'STUB'
#!/usr/bin/env bash
S=$STUB_STATE
echo "aws $*" >>"$S/aws.log"
case "$1 $2" in
  "secretsmanager get-secret-value")
    [[ "$*" == *rds-secret* ]] && echo "$STUB_RDS_JSON" || echo "$STUB_APP_JSON" ;;
  "s3api head-object") [[ -n "${STUB_POOL_CONTENT+x}" ]] ;;
  "s3 cp") printf '%s' "$STUB_POOL_CONTENT" >"$4" ;;
esac
STUB

  cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
echo "curl $url" >>"$STUB_STATE/curl.log"
case "$url" in
  */v1/health) printf '%s' "${STUB_AI_HEALTH:-200}" ;;
  *) printf '%s' "${STUB_BE_HTTP:-200}" ;;
esac
STUB

  cat >"$bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_MOUNTED:-1}" == 1 ]]
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
  # shellcheck disable=SC2016  # 스텁 본문에서 변수를 펼치지 않는 것이 의도다
  printf '#!/usr/bin/env bash\necho "chown $*" >>"$STUB_STATE/chown.log"\n' >"$bin/chown"
  chmod +x "$bin"/*
}

# run_deploy ARGS... — 격리된 상태 디렉터리에서 스크립트를 실행하고 stdout/stderr/종료코드를 저장한다.
run_deploy() {
  export STUB_STATE=$work/state
  rm -rf "$STUB_STATE" "$work/data"
  mkdir -p "$STUB_STATE" "$work/data"
  [[ -z "${PRESET_CONTAINERS:-}" ]] || printf '%s\n' "$PRESET_CONTAINERS" >"$STUB_STATE/containers"
  export STUB_APP_JSON=${STUB_APP_JSON:-$APP_JSON} STUB_RDS_JSON=$RDS_JSON
  PATH=$work/bin:$PATH VB_DATA_ROOT=$work/data bash "$script" "$@" \
    >"$work/out" 2>"$work/err"
  rc=$?
}

reset_env() {
  unset STUB_NO_ID STUB_RUN_FAIL STUB_RUNNING STUB_RESTARTS STUB_POOL_CONTENT STUB_AI_HEALTH \
    STUB_BE_HTTP STUB_MOUNTED STUB_UID STUB_GID PRESET_CONTAINERS
  export STUB_APP_JSON=$APP_JSON
}

check() { # check DESCRIPTION CONDITION...
  local desc=$1
  shift
  if "$@"; then
    pass=$((pass + 1)); echo "  ok   - $desc"
  else
    fail=$((fail + 1)); echo "  FAIL - $desc"
  fi
}
rc_is() { [[ "$rc" == "$1" ]]; }
log_has() { grep -Fq -- "$1" "$STUB_STATE/docker.log" 2>/dev/null; }
log_lacks() { ! log_has "$1"; }
err_has() { grep -Fq -- "$1" "$work/err"; }
out_lacks() { ! grep -Fq -- "$1" "$work/out" "$work/err"; }
container_exists() { grep -Fxq "$1" "$STUB_STATE/containers" 2>/dev/null; }
container_absent() { ! container_exists "$1"; }

make_stubs
be_args=(be "$BE_IMAGE" ap-northeast-2 app-secret rds-secret rds.example:3306 voicebridge redis.example 6379 bucket-x)
ai_args=(ai "$AI_IMAGE" ap-northeast-2 app-secret bucket-x)

echo "인자·이미지 검증"
reset_env; run_deploy
check "인자 없음 → 사용법 출력, 종료코드 2" rc_is 2
reset_env; run_deploy nope
check "알 수 없는 컴포넌트 → 종료코드 2" rc_is 2
reset_env; run_deploy be ghcr.io/evil/x:sha-1 r s r e d h p b
check "BE에 허용되지 않은 이미지 → 종료코드 2" rc_is 2
reset_env; run_deploy be "$AI_IMAGE" r s r e d h p b
check "BE 자리에 AI 이미지 → 거부" rc_is 2
reset_env; run_deploy ai "$BE_IMAGE" r s b
check "AI 자리에 BE 이미지 → 거부" rc_is 2
reset_env; run_deploy ai "$AI_IMAGE" r s
check "AI 인자 개수 부족 → 종료코드 2" rc_is 2

echo "AI 배포 — 정상 경로"
reset_env; STUB_POOL_CONTENT='{"prompts":["a"]}' run_deploy "${ai_args[@]}"
check "종료코드 0" rc_is 0
check "사용자 정의 네트워크 생성" log_has "network create voicebridge"
check "AI 컨테이너가 voicebridge 네트워크에 연결" log_has "--network voicebridge"
check "AI 포트를 호스트에 게시하지 않음" log_lacks "--publish"
check "호스트 /data/ai를 컨테이너 /data로 마운트" log_has "--volume $work/data/ai:/data"
check "HF_HOME=/data/hf 지정" log_has "HF_HOME=/data/hf"
check "로그 순환 옵션" log_has "max-size=10m"
check "AI 컨테이너 존재" container_exists voicebridge-ai
check "hf/adapters/enroll/jobs 디렉터리 생성" test -d "$work/data/ai/hf" -a -d "$work/data/ai/adapters" -a -d "$work/data/ai/enroll" -a -d "$work/data/ai/jobs"
check "마운트 최상위 /data/ai도 컨테이너 사용자 소유(앱이 enroll·jobs를 직접 생성)" grep -Fq "chown 1000:1000 $work/data/ai" "$STUB_STATE/chown.log"
check "enroll·jobs도 chown 대상" grep -Fq "$work/data/ai/jobs" "$STUB_STATE/chown.log"
check "CPU 학습 허용(ALLOW_CPU_TRAIN=1)" log_has "ALLOW_CPU_TRAIN=1"
check "S3의 프롬프트 풀이 설치됨" test "$(cat "$work/data/ai/script_pool.json" 2>/dev/null)" = '{"prompts":["a"]}'
check "컨테이너 사용자(1000:1000)로 chown" grep -Fq "1000:1000" "$STUB_STATE/chown.log"
check "BE 컨테이너는 건드리지 않음" container_absent voicebridge-be

echo "AI 배포 — /data 미마운트"
reset_env; STUB_MOUNTED=0 run_deploy "${ai_args[@]}"
check "종료코드 1" rc_is 1
check "미마운트 사유 출력" err_has "not a mounted volume"
check "이미지 pull 전에 실패(빠른 실패)" log_lacks "docker pull"
check "컨테이너를 만들지 않음" container_absent voicebridge-ai

echo "AI 배포 — 프롬프트 풀"
reset_env; run_deploy "${ai_args[@]}"
check "S3에 풀이 없어도 배포는 성공" rc_is 0
check "503 경고 출력" err_has "503"
reset_env; STUB_POOL_CONTENT='not json' run_deploy "${ai_args[@]}"
check "S3 풀이 JSON이 아니면 실패" rc_is 1
check "손상된 풀은 설치하지 않음" test ! -f "$work/data/ai/script_pool.json"

echo "AI 배포 — 헬스체크·롤백"
reset_env; STUB_AI_HEALTH=503 run_deploy "${ai_args[@]}"
check "헬스 실패 → 종료코드 1" rc_is 1
check "신규 컨테이너 제거(이전 없음)" container_absent voicebridge-ai
reset_env; STUB_RESTARTS=2 run_deploy "${ai_args[@]}"
check "재시작 루프 → 실패" rc_is 1
check "재시작 사유 출력" err_has "restarted 2 time(s)"
reset_env; PRESET_CONTAINERS="voicebridge-ai" STUB_AI_HEALTH=503 run_deploy "${ai_args[@]}"
check "이전 컨테이너가 있는 상태에서 헬스 실패 → 종료코드 1" rc_is 1
check "이전 컨테이너 복원(voicebridge-ai 유지)" container_exists voicebridge-ai
check "복원한 컨테이너를 다시 시작" log_has "docker start voicebridge-ai"
check "voicebridge-ai-previous 정리됨" container_absent voicebridge-ai-previous
reset_env; PRESET_CONTAINERS="voicebridge-ai" run_deploy "${ai_args[@]}"
check "재배포 성공" rc_is 0
check "성공 후 previous 제거" container_absent voicebridge-ai-previous
reset_env; PRESET_CONTAINERS="voicebridge-ai-previous" run_deploy "${ai_args[@]}"
check "이전 배포 잔여 컨테이너가 있으면 거부" rc_is 1
reset_env; STUB_RUN_FAIL=1 run_deploy "${ai_args[@]}"
check "docker run 실패 → 종료코드 1" rc_is 1
reset_env; STUB_NO_ID=1 run_deploy "${ai_args[@]}"
check "id 조회 불가여도 경고 후 진행" rc_is 0
check "경고 출력" err_has "could not read the AI container user"

echo "BE 배포"
reset_env; run_deploy "${be_args[@]}"
check "종료코드 0" rc_is 0
check "BE도 voicebridge 네트워크에 연결" log_has "--network voicebridge"
check "BE는 80:8080 게시" log_has "--publish 80:8080"
check "env-file 사용" grep -q 'JWT_SECRET=jwt-value' "$STUB_STATE/env_file_copy"
check "DB 접속 정보가 env-file에 들어감" grep -q 'DB_PASSWORD=dbpass' "$STUB_STATE/env_file_copy"
check "AI_SERVER_BASE_URL 미설정 시 env-file에 없음" bash -c "! grep -q AI_SERVER_BASE_URL '$STUB_STATE/env_file_copy'"
check "시크릿 값이 출력에 노출되지 않음" out_lacks "jwt-value"
check "시크릿 값이 docker 명령줄에 노출되지 않음" log_lacks "dbpass"
check "AI 컨테이너는 건드리지 않음" container_absent voicebridge-ai
reset_env; STUB_APP_JSON='{"JWT_SECRET":"j","NCP_TTS_API_KEY_ID":"i","NCP_TTS_API_KEY":"k","AI_SERVER_BASE_URL":"http://voicebridge-ai:8000"}' run_deploy "${be_args[@]}"
check "AI_SERVER_BASE_URL을 시크릿에서 그대로 전달" grep -Fxq 'AI_SERVER_BASE_URL=http://voicebridge-ai:8000' "$STUB_STATE/env_file_copy"
reset_env; STUB_APP_JSON='{"JWT_SECRET":"j"}' run_deploy "${be_args[@]}"
check "필수 시크릿 필드 누락 → 실패" rc_is 1
check "누락 시 이미지 pull 전에 실패" log_lacks "docker pull"
reset_env; STUB_BE_HTTP=000 run_deploy "${be_args[@]}"
check "BE가 응답하지 않으면 실패" rc_is 1
check "BE 신규 컨테이너 제거" container_absent voicebridge-be
reset_env; PRESET_CONTAINERS="voicebridge-be" STUB_BE_HTTP=000 run_deploy "${be_args[@]}"
check "BE 이전 컨테이너 복원" container_exists voicebridge-be
check "BE 복원 컨테이너를 다시 시작" log_has "docker start voicebridge-be"

echo "GHCR 인증"
reset_env; STUB_APP_JSON='{"GHCR_USERNAME":"ghuser","GHCR_READ_TOKEN":"tok-secret"}' run_deploy "${ai_args[@]}"
check "AI 배포에서도 같은 GHCR 시크릿으로 로그인" log_has "docker login ghcr.io --username ghuser --password-stdin"
check "토큰은 stdin으로만 전달" test "$(cat "$STUB_STATE/login_stdin")" = tok-secret
check "토큰이 명령줄·출력에 노출되지 않음" log_lacks "tok-secret"
reset_env; STUB_APP_JSON='{"GHCR_USERNAME":"ghuser"}' run_deploy "${ai_args[@]}"
check "GHCR 필드가 하나만 있으면 실패" rc_is 1

echo
echo "통과 $pass, 실패 $fail"
[[ "$fail" -eq 0 ]]
