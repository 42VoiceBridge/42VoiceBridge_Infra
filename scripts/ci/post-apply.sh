#!/usr/bin/env bash
set -euo pipefail

# 3_application을 apply한 뒤(인스턴스가 교체됐을 수 있다) 새 인스턴스를 마지막 성공 배포로 복원한다.
#   post-apply.sh LAYER
# 새 인스턴스는 user_data가 Docker와 SSM 에이전트를 설치할 때까지 시간이 걸리므로 check가 통과할
# 때까지 재시도한 뒤 redeploy한다. 다른 레이어에서는 아무것도 하지 않는다. RUN_SH는 테스트에서만 덮어쓴다.

layer=${1:-}
run_sh=${RUN_SH:-scripts/ssm/run.sh}
tries=${POST_APPLY_TRIES:-12}
pause=${POST_APPLY_PAUSE:-30}

if [[ "$layer" != 3_application ]]; then
  echo "Layer $layer: no redeploy needed."
  exit 0
fi

ready=false
for ((i = 1; i <= tries; i++)); do
  if bash "$run_sh" check; then
    ready=true
    break
  fi
  echo "Instances are not ready yet (attempt $i/$tries); retrying in ${pause}s."
  sleep "$pause"
done
if [[ "$ready" != true ]]; then
  echo "::error::Instances did not become ready after apply. Redeploy manually once they are Online." >&2
  exit 1
fi

bash "$run_sh" redeploy
