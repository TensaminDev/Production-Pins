{ pkgs }:
pkgs.writeShellScript "release-build" ''
  set -euo pipefail
  root=$(pwd)
  export NIX_CONFIG="''${NIX_CONFIG:-}
  max-jobs = 1
  cores = 2"
  channel=''${1:?Channel required}
  out=$(realpath -m "''${2:?Output directory required}")
  [[ $channel == stable || $channel == canary ]]
  mkdir -p "$out"
  export TENSAMIN_CHANNEL=$channel ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export TENSAMIN_ANDROID_VERSION_CODE=''${RELEASE_SEQUENCE:?}
  system=''${3:-${pkgs.stdenv.hostPlatform.system}}
  environment() {
    nix build --impure --no-update-lock-file --no-link --print-out-paths --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"$1\"; channel = \"$channel\"; system = \"$system\"; }"
  }
  environment checks >/dev/null
  portable=$(environment portable)
  cp -rL "$portable/." "$out/"
  chmod -R u+w "$out"
  arch=''${system%-linux}
  if [[ $arch == x86_64 ]]; then
    web=$(environment web)
    tar -czf "$out/client-web.tar.gz" -C "$web" .
  fi
  work_root=$(mktemp -d)
  trap 'rm -rf "$work_root"' EXIT
  work=$work_root/tensamin/client
  mkdir -p "$work"
  mtp_source=$(nix eval --impure --raw --expr "(builtins.getFlake \"$root\").inputs.mtp.outPath")
  cp -r "$mtp_source" "$work_root/mtp"
  chmod -R u+w "$work_root/mtp"
  source=$(nix build --no-update-lock-file --no-link --print-out-paths ".#packages.$system.client-source")
  cp -r "$source/." "$work/"
  chmod -R u+w "$work"
  export RELEASE_ROOT=$root RELEASE_OUT=$out RELEASE_WORK=$work RELEASE_ARCH=$arch
  export TENSAMIN_RELEASE_TAG=''${RELEASE_TAG:?} TENSAMIN_RELEASE_VERSION=$RELEASE_TAG
  export TENSAMIN_RELEASE_ASSET_BASE_URL="''${GITHUB_SERVER_URL:-https://github.com}/''${GITHUB_REPOSITORY:?}/releases/download/$RELEASE_TAG"
  # Pinned client revisions may still read the previous variable name.
  export FORGEJO_RELEASE_ASSET_BASE_URL=$TENSAMIN_RELEASE_ASSET_BASE_URL
  desktop=$(environment client-desktop)
  nix develop --impure --no-update-lock-file --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"electron\"; system = \"$system\"; }" \
    --command bash "$desktop"
  if [[ $arch == x86_64 ]]; then
    android=$(environment client-android)
    nix develop --impure --no-update-lock-file --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"tauri\"; }" \
      --command bash "$android"
  fi
''
