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
# Read connection details without resolving the infrastructure's flake inputs.
connection=$(nix eval --impure --json --expr "
  let host = (import ./hosts).gartenhaus; in {
    address = host.inventory.guests.\"$node\".address;
    jump = \"deploy@\" + host.management.address + \":\" + toString host.management.port;
  }")
host=$(jq -er .address <<< "$connection")
jump=$(jq -er .jump <<< "$connection")
target="deploy@$host"
# The reviewed configuration changes disk layout. Never switch an unmigrated VM.
if ! ssh -J "$jump" "$target" 'test "$(findmnt -n -o FSTYPE /)" = tmpfs && test -d /persist/databases/omega-1'; then
  echo "Guest $node is not yet migrated to the impermanent layout." >&2
  echo 'Perform the migration in docs/guides/impermanence.md (nixos-flake) before enabling deployments.' >&2
  exit 1
fi
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
# Transfer the reviewed GitHub checkout. Private GitHub credentials stay on Actions.
remote=$(ssh -J "$jump" "$target" 'mktemp -d /var/tmp/tensamin-deploy.XXXXXXXXXX')
[[ $remote =~ ^/var/tmp/tensamin-deploy\.[a-zA-Z0-9]{10}$ ]]
trap 'ssh -J "$jump" "$target" "sudo -n rm -rf -- $remote"' EXIT
git archive HEAD | ssh -J "$jump" "$target" "tar -x -C $remote"
scp -o "ProxyJump=$jump" flake.nix "$target:$remote/flake.nix"
ssh -J "$jump" "$target" "sudo -n bash -s -- $remote $node $input" < ../scripts/update-server.sh
scp -o "ProxyJump=$jump" "$target:$remote/flake.lock" flake.lock
if [[ $CHANNEL == canary ]]; then
  jq -n --arg pins "$PINS_REVISION" --arg infrastructure "$base" \
    '{pins: $pins, infrastructure: $infrastructure}' > ../deployment/manifest.json
fi
# Persist only this channel's lock change. Do not silently overwrite concurrent edits.
git add flake.lock flake.nix
if ! git diff --cached --quiet; then
  git -c user.name=tensamin-deploy -c user.email=tensamin-deploy@users.noreply.github.com \
    commit -m "Update $CHANNEL pins to $PINS_REVISION"
  git -c credential.helper='!gh auth git-credential' push https://github.com/nonanium/NixOS-Flake.git HEAD:main
fi
