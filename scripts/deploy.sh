#!/usr/bin/env bash
set -euo pipefail
[[ ${CHANNEL:?} == canary || $CHANNEL == stable ]]
[[ ${PINS_REVISION:?} =~ ^[0-9a-f]{40}$ ]]
cd infrastructure
base=$(git rev-parse HEAD)
[[ -z $(git status --porcelain) ]]
[[ $(git rev-parse origin/main) == "$base" ]]
if [[ $CHANNEL == stable ]]; then
  tested=$(jq -er .infrastructure ../deployment/manifest.json)
  [[ $tested =~ ^[0-9a-f]{40}$ ]]
  if [[ $base != "$tested" ]]; then
    echo 'Infrastructure main has changed since the successful Canary deployment. Rerun Canary before Stable.' >&2
    exit 1
  fi
  node=tensamin-prod
  input=prod-pins
else
  node=tensamin-canary
  input=canary-pins
fi
# Read the exported inventory without evaluating a complete NixOS system.
connection=$(nix eval --no-update-lock-file --json .#lib.hosts --apply "hosts:
  let host = hosts.gartenhaus; in {
    address = host.inventory.guests.\"$node\".address;
    jump = \"deploy@\" + host.management.address + \":\" + toString host.management.port;
  }")
host=$(jq -er .address <<< "$connection")
jump=$(jq -er .jump <<< "$connection")
# Reuse the guest's existing read-only Forgejo identity, without exporting its key.
# Git fetches run through it; lock resolution and system builds stay on the runner.
export SOURCE_JUMP="$jump" SOURCE_TARGET="deploy@$host"
export GIT_SSH_COMMAND="bash $PWD/../scripts/source-ssh.sh"
export GIT_SSH_VARIANT=ssh
cp flake.lock ../deployment/base-flake.lock
python3 - "$input" "$PINS_REVISION" <<'PY'
import re
import sys
from pathlib import Path
path = Path('flake.nix')
input_name, revision = sys.argv[1:]
text, count = re.subn(rf'({input_name}\.url = "github:TensaminDev/Production-Pins/)[0-9a-f]{{40}}(";)', rf'\g<1>{revision}\2', path.read_text())
assert count == 1
path.write_text(text)
PY
nix flake update "$input"
python3 ../scripts/check-infrastructure-lock.py ../deployment/base-flake.lock flake.lock "$input" "$PINS_REVISION"
# Evaluate and build only the selected existing VM, with the resolved lock frozen.
nix build --no-update-lock-file --no-link ".#nixosConfigurations.$node.config.system.build.toplevel"
# Persist only this channel's lock change. Do not silently overwrite concurrent edits.
git add flake.lock flake.nix
if ! git diff --cached --quiet; then
  git -c user.name=tensamin-deploy -c user.email=tensamin-deploy@users.noreply.github.com \
    commit -m "Update $CHANNEL pins to $PINS_REVISION"
fi
# Push even when the pin was already desired. A concurrent main update must fail
# before activation, and an unchanged checkout must not create an empty commit.
git -c credential.helper='!gh auth git-credential' push https://github.com/nonanium/NixOS-Flake.git HEAD:main
revision=$(git rev-parse HEAD)
remote_revision=$(git -c credential.helper='!gh auth git-credential' ls-remote https://github.com/nonanium/NixOS-Flake.git refs/heads/main)
[[ ${remote_revision%%$'\t'*} == "$revision" ]]
[[ -z $(git status --porcelain) ]]
nix run --no-update-lock-file .#tensamin -- deploy --channel "$CHANNEL"
[[ $(git rev-parse HEAD) == "$revision" ]]
[[ -z $(git status --porcelain) ]]
# The CLI verifies tensamin-registry.service before returning success.
jq -n --arg pins "$PINS_REVISION" --arg infrastructure "$revision" \
  '{pins: $pins, infrastructure: $infrastructure}' > ../deployment/manifest.json
