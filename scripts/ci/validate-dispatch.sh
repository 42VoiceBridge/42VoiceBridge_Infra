#!/usr/bin/env bash
set -euo pipefail

# 배포 이벤트(repository_dispatch)의 payload를 검증한다. 입력은 모두 환경변수로만 받는다
# (워크플로 스크립트에 ${{ }}를 직접 넣지 않기 위함).
#
#   DISPATCH_REF        payload의 ref. refs/heads/main 이어야 한다.
#   DISPATCH_SHA        payload의 sha. 40자 소문자 16진수여야 한다.
#   DISPATCH_IMAGE      payload의 image(선택). 설정 불일치를 잡는 확인용이며 배포에는 쓰지 않는다.
#   IMAGE_REPOSITORY    Infra 저장소 Variables의 *_IMAGE_REPOSITORY. ghcr.io/42voicebridge/<패키지>.
#   COMPONENT_LABEL     오류 메시지에 쓸 이름(be/ai/fe).
#
# 주의: 이것은 입력 "형식" 검사다. 토큰을 가진 호출자가 임의로 적을 수 있으므로 "main CI를 통과한
# 이미지"라는 증명은 아니다. 출처는 verify-source-commit.sh가 따로 확인한다.

label=${COMPONENT_LABEL:-component}
ref=${DISPATCH_REF:-}
sha=${DISPATCH_SHA:-}
payload_image=${DISPATCH_IMAGE:-}
repository=${IMAGE_REPOSITORY:-}

if [[ "$ref" != "refs/heads/main" ]]; then
  echo "::error::$label dispatch must come from main (refs/heads/main)." >&2
  exit 1
fi
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::$label dispatch must include a 40-character lowercase commit SHA." >&2
  exit 1
fi
if [[ ! "$repository" =~ ^ghcr\.io/42voicebridge/[a-z0-9._-]+$ ]]; then
  echo "::error::Repository variable for $label must be ghcr.io/42voicebridge/<package>." >&2
  exit 1
fi

# 이미지 경로는 payload가 아니라 Infra 변수와 SHA로만 조립한다. payload의 image가 있고 다르면 중단한다.
expected="$repository:sha-$sha"
if [[ -n "$payload_image" && "$payload_image" != "$expected" ]]; then
  echo "::error::Payload image does not match the $label image repository variable and sha." >&2
  exit 1
fi

echo "$label image: $expected"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "image=$expected" >>"$GITHUB_OUTPUT"
fi
