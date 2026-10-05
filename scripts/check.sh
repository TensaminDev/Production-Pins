#!/usr/bin/env bash
set -euo pipefail

shellcheck scripts/check.sh scripts/release-build.sh scripts/release-client.sh
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
bun build --target=bun --outdir "$temporary" lib/*.ts scripts/*.ts
