#!/usr/bin/env bash
set -euo pipefail

# 배포하려는 SHA가 소스 레포의 main 브랜치에 포함되는지 GitHub API로 확인한다(출처 검증).
#   verify-source-commit.sh SOURCE_REPOSITORY SHA [BASE_BRANCH=main]
# compare/<base>...<sha> 의 status가 identical(같음) 또는 behind(main의 조상)이면 main에 포함된 커밋이다.
# ahead(main에 없는 새 커밋), diverged(다른 가지)이거나 조회에 실패하면 배포하지 않는다(fail closed).
# GITHUB_TOKEN이 있으면 인증해서 호출한다(공개 레포의 읽기 한도 완화용). 소스 레포는 공개 레포다.

if [[ "$#" -lt 2 ]]; then
  echo "Usage: $0 SOURCE_REPOSITORY SHA [BASE_BRANCH]" >&2
  exit 2
fi
repo=$1
sha=$2
base=${3:-main}
api=${GITHUB_API_URL:-https://api.github.com}

if [[ ! "$repo" =~ ^42VoiceBridge/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::Source repository must belong to 42VoiceBridge: $repo" >&2
  exit 1
fi
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Invalid commit SHA." >&2
  exit 1
fi
if [[ ! "$base" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "::error::Invalid base branch." >&2
  exit 1
fi

auth=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

if ! response=$(curl --fail --silent --show-error --max-time 30 \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "${auth[@]}" "$api/repos/$repo/compare/$base...$sha"); then
  echo "::error::Could not verify $sha against $repo@$base (commit not found or API error). Not deploying." >&2
  exit 1
fi

status=$(jq -r '.status // ""' <<<"$response")
case "$status" in
  identical | behind)
    echo "Verified: ${sha:0:7} is on $repo@$base ($status)."
    ;;
  *)
    echo "::error::${sha:0:7} is not on $repo@$base (compare status: ${status:-unknown}). Not deploying." >&2
    exit 1
    ;;
esac
