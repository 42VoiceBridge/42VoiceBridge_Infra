#!/usr/bin/env bash
set -euo pipefail

# 컴포넌트 하나만 배포한다: deploy-component.sh be|ai|fe SHA
# IMAGE_REPOSITORY 환경변수를 해당 컴포넌트의 *_IMAGE_REPOSITORY로 넘기고 run.sh에 SHA를 해당 자리에만 준다.
# RUN_SH는 테스트에서만 덮어쓴다.

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 be|ai|fe SHA" >&2
  exit 2
fi
component=$1
sha=$2
run_sh=${RUN_SH:-scripts/ssm/run.sh}

case "$component" in
  be) export BE_IMAGE_REPOSITORY=${IMAGE_REPOSITORY:?} ; exec bash "$run_sh" deploy "$sha" "" "" ;;
  ai) export AI_IMAGE_REPOSITORY=${IMAGE_REPOSITORY:?} ; exec bash "$run_sh" deploy "" "$sha" "" ;;
  fe) export FE_IMAGE_REPOSITORY=${IMAGE_REPOSITORY:?} ; exec bash "$run_sh" deploy "" "" "$sha" ;;
  *) echo "Unknown component: $component" >&2; exit 2 ;;
esac
