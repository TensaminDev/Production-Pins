#!/usr/bin/env bash
set -euo pipefail
work=${1:?}
node=${2:?}
input=${3:?}
cd "$work"

# Resolve private inputs with the server's existing credentials, then build locally.
nix flake update "$input"
nixos-rebuild switch --flake "path:$work#$node" --no-write-lock-file

systemctl is-active container@omega-1 container@iota-1
nixos-container run omega-1 -- systemctl is-active mysql omega
