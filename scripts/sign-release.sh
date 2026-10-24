#!/usr/bin/env bash
set -euo pipefail
arch=${RELEASE_SYSTEM%-linux}
[[ $arch == x86_64 || $arch == aarch64 ]]
contract="$PWD/build-output/iota-contract"
binary_directory=$(mktemp -d)
trap 'rm -rf "$binary_directory"' EXIT
mkdir -p release
for binary in iota iota-daemon iota-updater iota-release iota-bundle; do
  install -m 0755 "build-output/$binary-linux-$arch" "$binary_directory/$binary"
done
export IOTA_RELEASE_SOURCE_SHA
IOTA_RELEASE_SOURCE_SHA=$(jq -er '.nodes[.nodes.root.inputs.iota].locked.rev' flake.lock)
export IOTA_RELEASE_SIGNING_KEY_ID=primary
manifest="$PWD/release/iota-update-linux-$arch.json"
base_url="https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG"
bash "$contract/scripts/build-update-manifest.sh" "$binary_directory" \
  "0.1.$RELEASE_SEQUENCE" "$CHANNEL" "$RELEASE_SEQUENCE" "$PUBLISHED_AT" "$EXPIRES_AT" \
  linux "$arch" "$base_url" "$manifest"
public_key=$("$binary_directory/iota-release" sign "$manifest" "$manifest.sig")
[[ $public_key == "$IOTA_RELEASE_PUBLIC_KEY" ]]
product_version=$(jq -er .product_version "$manifest")
# Existing Iota installers require this URL. GitHub redirects it after the repo move.
channel_url="https://github.com/TensaminDev/Production-Pins/releases/download/$CHANNEL/iota-update-linux-$arch.json"
bundle="$PWD/release/iota-installer-linux-$arch.zip"
bash "$contract/scripts/build-release-bundle.sh" "$binary_directory" "$product_version" \
  "$manifest" "$channel_url" "$public_key" "$channel_url.sig" "$CHANNEL" primary "$bundle"
"$binary_directory/iota-bundle" "$bundle"
for binary in iota iota-daemon iota-updater; do
  cp "build-output/$binary-linux-$arch" release/
done
cp "build-output/iota-portable-linux-$arch.tar.gz" release/
cp build-output/*.AppImage build-output/*.deb build-output/*.rpm release/
cp "build-output/electron-release-metadata-$arch.json" release/
if [[ $arch == x86_64 ]]; then
  cp "build-output/Tensamin-$RELEASE_TAG.apk" release/
fi
