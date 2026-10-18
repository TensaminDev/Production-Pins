#!/usr/bin/env bash
set -euo pipefail
[[ $CHANNEL == canary || $CHANNEL == stable ]]
cd release
# Validate the merged native builds before making any public release.
for arch in x86_64 aarch64; do
  jq -e --arg channel "$CHANNEL" --argjson sequence "$RELEASE_SEQUENCE" \
    '.channel == $channel and .release_sequence == $sequence' "iota-update-linux-$arch.json" >/dev/null
  expires_at=$(jq -er .expires_at "iota-update-linux-$arch.json")
  (( $(date -d "$expires_at" +%s) > $(date +%s) ))
  while IFS=$'\t' read -r name hash size; do
    [[ $(sha256sum "$name" | cut -d ' ' -f 1) == "$hash" ]]
    [[ $(stat -c %s "$name") == "$size" ]]
  done < <(jq -r '.artifacts[] | [.url | split("/")[-1]] + [.sha256, (.size | tostring)] | @tsv' "iota-update-linux-$arch.json")
done
test -s "Tensamin-$RELEASE_TAG.apk"
if gh release view "$CHANNEL" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' > channel-assets.txt 2>/dev/null; then
  for arch in x86_64 aarch64; do
    if grep -Fxq "iota-update-linux-$arch.json" channel-assets.txt; then
      previous=$(mktemp -d)
      gh release download "$CHANNEL" --repo "$GITHUB_REPOSITORY" \
        --pattern "iota-update-linux-$arch.json" --dir "$previous"
      old_sequence=$(jq -er .release_sequence "$previous/iota-update-linux-$arch.json")
      rm -rf "$previous"
      (( RELEASE_SEQUENCE > old_sequence )) || {
        echo "Refusing to regress or reuse the $CHANNEL update sequence" >&2
        exit 1
      }
    fi
  done
fi
rm -f channel-assets.txt
printf '%s\n' "$IOTA_RELEASE_PUBLIC_KEY" > IOTA_RELEASE_PUBLIC_KEY
jq -n --arg pins "$GITHUB_SHA" --arg channel "$CHANNEL" --argjson sequence "$RELEASE_SEQUENCE" \
  '{pins: $pins, channel: $channel, sequence: $sequence}' > release-provenance.json
rm -f SHA256SUMS
sha256sum -- * > SHA256SUMS
prerelease=false
[[ $CHANNEL != canary ]] || prerelease=true
# A draft may be replaced on retry; a published release is never overwritten.
if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft > draft-state.txt 2>/dev/null; then
  [[ $(<draft-state.txt) == true ]] || exit 1
  gh release delete "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --yes
fi
rm -f draft-state.txt
gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
  --title "$RELEASE_TAG" --notes "Client and Iota $CHANNEL release from $GITHUB_SHA." \
  --draft --prerelease="$prerelease" --latest=false
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" -- *
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false \
  --prerelease="$prerelease" --latest="$([[ $CHANNEL == stable ]] && echo true || echo false)"
if ! gh release view "$CHANNEL" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$CHANNEL" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
    --title "$CHANNEL" --notes "Signed Iota $CHANNEL update metadata. Download installers from the numbered releases." \
    --prerelease="$prerelease" --latest=false
fi
gh release upload "$CHANNEL" --repo "$GITHUB_REPOSITORY" --clobber \
  iota-update-linux-*.json iota-update-linux-*.json.sig
