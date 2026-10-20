#!/usr/bin/env bash
set -euo pipefail

# Nix's Git fetcher supplies SSH options, the host and git-upload-pack command.
# Run Forgejo SSH on the guest so its declared read key and known host are used.
for argument in "$@"; do
  if [[ $argument == git@git.internal.nonanium.net || $argument == git.internal.nonanium.net ]]; then
    printf -v command '%q ' ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$@"
    exec ssh -J "${SOURCE_JUMP:?}" "${SOURCE_TARGET:?}" "sudo -n $command"
  fi
done
exec ssh "$@"
