#!/usr/bin/env bash
set -euo pipefail

root=$(pwd)
channel=${1:?Usage: release-build.sh CHANNEL OUTPUT_DIRECTORY}
out=$(realpath -m "${2:?Output directory required}")
[[ $channel == stable || $channel == canary ]]
mkdir -p "$out"
export TENSAMIN_CHANNEL=$channel ELECTRON_SKIP_BINARY_DOWNLOAD=1
export TENSAMIN_ANDROID_VERSION_CODE=${RELEASE_SEQUENCE:?Release sequence required}
system=${3:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}
expr="import $root/scripts/release-env.nix { root = builtins.toPath \"$root\"; kind = \"packages\"; channel = \"$channel\"; system = \"$system\"; }"
nix build --impure --no-link --expr "import $root/scripts/release-env.nix { root = builtins.toPath \"$root\"; kind = \"checks\"; system = \"$system\"; }"
packages=$(nix build --impure --no-link --print-out-paths --expr "$expr")
arch=$system
arch=${arch%-linux}
printf '%s\n' "$packages" > "$out/packages-$arch.txt"
for name in iota iota-daemon iota-ui omikron omega client client-web mtp-sdk; do
    # Nix closures, unlike a plain copy of a Nix binary, retain runtime libraries.
    package=$(realpath "$packages/$name")
    mapfile -t closure < <(nix-store --query --requisites "$package")
    nix-store --export "${closure[@]}" | gzip -n > "$out/$name-linux-$arch.nar.gz"
done
for binary in iota iota-daemon iota-updater; do
    cp "$packages/iota-portable/bin/$binary" "$out/$binary-linux-$arch"
done
tar -czf "$out/iota-portable-linux-$arch.tar.gz" -C "$packages/iota-portable" bin share
cp -L "$packages/iota-container" "$out/iota-image-linux-$arch.tar.gz"
cp -L "$packages/omikron-container" "$out/omikron-image-linux-$arch.tar.gz"
cp -L "$packages/omega-container" "$out/omega-image-linux-$arch.tar.gz"
cp "$packages/iota-portable/bin/iota-release" "$out/iota-release-linux-$arch"
cp "$packages/iota-portable/bin/iota-bundle" "$out/iota-bundle-linux-$arch"
cp -rL "$packages/iota-bundle/share/iota" "$out/iota-contract"
chmod -R u+w "$out/iota-contract"
# The helpers' relative script paths are part of the Iota contract.
mkdir -p "$out/iota-contract/iota-updater" "$out/iota-contract/iota-installer"
mv "$out/iota-contract/artifacts.tsv" "$out/iota-contract/iota-updater/"
mv "$out/iota-contract/bundle-files.txt" "$out/iota-contract/iota-installer/"
mkdir -p "$out/iota-contract/static"
mv "$out/iota-contract/static-web" "$out/iota-contract/static/web"

work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT
work=$work_root/tensamin/client
mkdir -p "$work"
mtp_source=$(nix build --no-link --print-out-paths ".#packages.$system.mtp-source")
cp -r "$mtp_source" "$work_root/mtp"
chmod -R u+w "$work_root/mtp"
source=$(nix build --no-link --print-out-paths ".#packages.$system.client-source")
cp -r "$source/." "$work/"
chmod -R u+w "$work"
rm -rf "$work/.mtp-sdk"
cp -rL "$packages/mtp-sdk" "$work/.mtp-sdk"
chmod -R u+w "$work/.mtp-sdk"
export RELEASE_ROOT=$root RELEASE_OUT=$out RELEASE_WORK=$work RELEASE_ARCH=$arch
export TENSAMIN_RELEASE_TAG=${RELEASE_TAG:?} TENSAMIN_RELEASE_VERSION=$RELEASE_TAG
export FORGEJO_RELEASE_ASSET_BASE_URL="${FORGEJO_SERVER_URL:?}/${FORGEJO_REPOSITORY:?}/releases/download/$RELEASE_TAG"
pushd "$work" >/dev/null
nix develop --impure --expr "import $root/scripts/release-env.nix { root = builtins.toPath \"$root\"; kind = \"electron\"; system = \"$system\"; }" \
    --command bash "$root/scripts/release-client.sh" desktop
if [[ $arch == x86_64 ]]; then
    nix develop --impure --expr "import $root/scripts/release-env.nix { root = builtins.toPath \"$root\"; kind = \"tauri\"; }" \
        --command bash "$root/scripts/release-client.sh" android
fi
popd >/dev/null
