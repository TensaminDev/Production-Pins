#!/usr/bin/env bash
set -euo pipefail
[[ ${CHANNEL:?} == canary || $CHANNEL == stable ]]
[[ ${PINS_REVISION:?} =~ ^[0-9a-f]{40}$ ]]
cd infrastructure
base=$(git rev-parse HEAD)
if [[ $CHANNEL == stable ]]; then
  tested=$(jq -er .infrastructure ../deployment/manifest.json)
  [[ $tested =~ ^[0-9a-f]{40}$ ]]
  # Lock-only channel changes are allowed; infrastructure changes need a new trial.
  git show "$tested:flake.nix" | sed -E 's@Production-Pins/[0-9a-f]{40}@Production-Pins/REVISION@g' > ../deployment/tested-flake.nix
  sed -E 's@Production-Pins/[0-9a-f]{40}@Production-Pins/REVISION@g' flake.nix > ../deployment/current-flake.nix
  cmp ../deployment/tested-flake.nix ../deployment/current-flake.nix
  test -z "$(git diff --name-only "$tested" HEAD -- . ':!flake.lock' ':!flake.nix')"
  node=tensamin-prod
  input=prod-pins
else
  node=tensamin-canary
  input=canary-pins
fi
host=$(nix eval --raw ".#deploy.nodes.$node.hostname")
jump=$(nix eval --json ".#deploy.nodes.$node.sshOpts" | jq -r '.[1]')
# The reviewed configuration changes disk layout. Never switch an unmigrated VM.
ssh -J "$jump" "alois@$host" 'test "$(findmnt -n -o FSTYPE /)" = tmpfs && test -d /persist/databases/omega-1'
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
nix build ".#nixosConfigurations.$node.config.system.build.toplevel" --no-link
nix run github:serokell/deploy-rs -- ".#$node" --skip-checks
ssh -J "$jump" "alois@$host" 'systemctl is-active container@omega-1 container@iota-1; sudo -n nixos-container run omega-1 -- systemctl is-active mysql omega'
if [[ $CHANNEL == canary ]]; then
  jq -n --arg pins "$PINS_REVISION" --arg infrastructure "$base" \
    '{pins: $pins, infrastructure: $infrastructure}' > ../deployment/manifest.json
fi
# Persist only this channel's lock change. Do not silently overwrite concurrent edits.
git add flake.lock flake.nix
if ! git diff --cached --quiet; then
  git -c user.name=tensamin-deploy -c user.email=tensamin-deploy@users.noreply.github.com \
    commit -m "Update $CHANNEL pins to $PINS_REVISION"
  git -c credential.helper='!gh auth git-credential' push https://github.com/MethaniumDev/NixOS-Flake.git HEAD:main
fi
