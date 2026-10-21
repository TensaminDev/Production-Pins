#!/usr/bin/env bash
set -euo pipefail
[[ ${CHANNEL:?} == canary || $CHANNEL == stable ]]
[[ ${GITHUB_REF:?} == refs/heads/main ]]
[[ ${GITHUB_SHA:?} =~ ^[0-9a-f]{40}$ ]]
[[ ${GITHUB_RUN_NUMBER:?} =~ ^[1-9][0-9]*$ ]]
sequence=$((1000000000 + GITHUB_RUN_NUMBER))
(( sequence <= 2100000000 ))
for name in ANDROID_KEYSTORE_BASE64 ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD IOTA_RELEASE_SIGNING_KEY IOTA_RELEASE_PUBLIC_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing release configuration: $name in the $CHANNEL environment" >&2
    exit 1
  fi
done
[[ $IOTA_RELEASE_PUBLIC_KEY =~ ^[0-9a-f]{64}$ ]]
tag="$CHANNEL-${GITHUB_SHA:0:7}"
publish=true
if release=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft,targetCommitish --jq '[.isDraft, .targetCommitish] | @tsv' 2>/dev/null); then
  IFS=$'\t' read -r draft target <<< "$release"
  if [[ $draft != true ]]; then
    [[ $target == "$GITHUB_SHA" ]] || {
      echo "Release $tag belongs to a different full commit; refusing a short-hash collision." >&2
      exit 1
    }
    publish=false
  fi
fi
if [[ $CHANNEL == stable ]]; then
  canary_run_id=$(gh api --method GET \
    "repos/$GITHUB_REPOSITORY/actions/workflows/canary.yml/runs" \
    -f head_sha="$GITHUB_SHA" -f status=success -f branch=main \
    --jq '.workflow_runs | map(select(.head_sha == "'"$GITHUB_SHA"'" and .conclusion == "success")) | first | .id // empty')
  [[ $canary_run_id =~ ^[0-9]+$ ]] || {
    echo "Stable requires a successful Canary run for exactly $GITHUB_SHA" >&2
    exit 1
  }
fi
published_at=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .created_at)
expires_at=$(date -u -d "$published_at +90 days" +%Y-%m-%dT%H:%M:%SZ)
{
  echo "tag=$tag"
  echo "publish=$publish"
  echo "sequence=$sequence"
  echo "published_at=$published_at"
  echo "expires_at=$expires_at"
} >> "$GITHUB_OUTPUT"
