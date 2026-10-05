# Central release setup

Only prod-pins publishes releases. Pushes to main and manual canary runs validate
the locked, prepared Rust and client sources, then build combined immutable
releases. Stable dispatch automatically selects a published canary for the exact
commit selected at dispatch and verifies its workflow completed successfully.
If that commit has no successful canary, stable fails before building. Promotion checks out that exact
prod-pins revision, including dependency locks and hashes. It rebuilds with stable
client branding. No input update command runs during promotion.

## Runner and credentials

Use a trusted `nixos` runner with Nix, Git and Bash available for bootstrap.
The workflow's tools use the central nixpkgs and Rust overlay. Source inputs
require SSH read access to every locked repository. Configure these secrets:

- `TENSAMIN_SOURCE_SSH_KEY`, read access to the pinned repositories.
- `TENSAMIN_RELEASE_TOKEN`, prod-pins release and package registry write access,
  and Actions run read access.
- `IOTA_RELEASE_SIGNING_KEY`, 64 hex characters encoding the Ed25519 seed.
- `TENSAMIN_PROD_DEPLOY_SSH_KEY`, key authorized for the server's forced command.
- `NIXOS_FLAKE_WRITE_TOKEN`, infrastructure repository read and write access.
- `ANDROID_KEYSTORE_BASE64`, the existing Android keystore encoded as base64.
- `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_STORE_PASSWORD`, matching
  the existing Android signing identity. Map existing secret names to these
  workflow environment entries if their names differ.

Configure repository variables:

- `IOTA_RELEASE_PUBLIC_KEY`, pinned public key, 64 hex characters.
- `IOTA_RELEASE_SIGNING_KEY_ID`, default `primary`.
- `IOTA_BASE_VERSION`, default `0.1.0`.
- `TENSAMIN_REGISTRY_USER`, token owner's Forgejo username.
- `NIXOS_FLAKE_REPOSITORY`, infrastructure repository as `owner/repository`.
- `NIXOS_FLAKE_BRANCH`, default `main`.
- `TENSAMIN_PROD_DEPLOY_HOST`, deployment SSH hostname.
- `TENSAMIN_PROD_DEPLOY_PORT`, default `22`.
- `TENSAMIN_PROD_DEPLOY_JUMP_HOST`, optional SSH jump hostname, `methanium.net`
  for production. The jump user is `deploy-jump`; both hops use the deploy key.
- `TENSAMIN_PROD_DEPLOY_JUMP_PORT`, default `7930`.
- `TENSAMIN_SSH_KNOWN_HOSTS`, verified host keys for source Git and deployment.

For the production VM set `TENSAMIN_PROD_DEPLOY_HOST=10.201.0.10` and
`TENSAMIN_PROD_DEPLOY_PORT=22`. `TENSAMIN_SSH_KNOWN_HOSTS` must contain verified
entries for `methanium.net` on source Git port 22, `[methanium.net]:7930` for the
jump host, and `10.201.0.10` for the guest on port 22. These are separate host
identities and may have different keys. Include any other locked source SSH
hostnames too. The generated SSH config applies the key and known-hosts file to
both hops, including rollback deployment.

The infrastructure forced command must accept `<nixos-flake commit SHA>`, fetch
and deploy precisely that commit, validate its prod-pins lock, and return success
only after activation and application health checks. It must restore the prior
system and checkout on failure. `deploy-release.py` deliberately rejects the old
wrapper that accepts `<prod-pins commit SHA>`. It commits only infrastructure
`flake.lock`, pushes without force, passes that infrastructure commit through SSH,
then publishes stable. If deployment or publication fails, it reverts the pin
with a normal Git commit and deploys the rollback commit. A revert conflict or
unreachable server fails visibly and needs operator recovery.

## Artifacts and channels

Each immutable release contains:

- `release.json`, exact prod-pins revision, source lock identities, workflow run,
  architectures, artifact sizes and SHA-256 hashes, plus `SHA256SUMS`.
- `iota-linux-ARCH`, `iota-daemon-linux-ARCH`, `iota-updater-linux-ARCH` and signed
  `iota-update-linux-ARCH.json` with `.sig`, using Iota's typed Rust signer.
  These executables are musl-static and run on ordinary Linux without Nix.
- `iota-portable-linux-ARCH.tar.gz`, per-user binaries under `bin` and static
  assets under `share/iota/web`. Extract and run `./bin/iota`. The daemon and
  updater are discovered next to the CLI. Host CA certificates supply TLS trust.
- `iota-linux-ARCH.zip`, checked by `iota-bundle`, with channel trust settings
  and static assets, for system-wide installation through CLI bootstrap.
- `PACKAGE-linux-ARCH.nar.gz`, gzip-compressed Nix closure exports for Iota,
  services, client, web and SDK. Restore with `gzip -dc FILE | nix-store --import`.
  These are separate Nix artifacts, not the unmanaged Linux installation path.
- Docker-loadable Iota, Omikron and Omega images. Registry names are
  `SERVER/tensamin/SERVICE:IMMUTABLE_TAG-ARCH`.
- Signed universal `Tensamin-IMMUTABLE_TAG.apk`, Linux Electron AppImage, deb and
  rpm assets, and per-architecture Electron release metadata.

`stable` and `canary` are the only mutable metadata releases. Each has
`channel.json`, combined `electron-release-metadata.json`, and Iota update
manifests with signatures. Binary URLs always reference an immutable release.
Daily refresh re-signs manifests for the same binary identity with a higher
sequence and 14-day expiry. Publication and refresh share one concurrency group.
Sequences use Unix seconds, must strictly increase, and remain within Android's
version-code bound. Do not publish to these channels outside the serialized flow.

Forgejo attachment replacement is not transactional. On API failure the script
restores prior channel attachments and returns failure. Readers can encounter a
brief missing or mismatched manifest/signature pair and should retry. Old immutable
binary assets remain available. A failed stable promotion retains its draft for
inspection. Registry uploads use immutable tags and can leave unused images if a
later publication step fails.

The workflow tries aarch64 using configured Nix builders and execution support.
If that attempt fails, the x86_64 release includes `aarch64-unavailable.txt` and
`arm-build.log`. Partial aarch64 artifacts are not advertised. Full aarch64
Electron packaging requires execution support as well as a builder. Android is
built on x86_64 using prepared `client-source` and `mtp-sdk`, never the client's
original release SDK dependency. The client's tool shells use central inputs;
platform-tools is adjusted to the version available in central nixpkgs.

## Local validation

```sh
nix develop --impure --expr 'import ./scripts/release-env.nix { root = builtins.toPath (builtins.getEnv "PWD"); }' --command shellcheck scripts/release-build.sh scripts/release-client.sh
nix develop --impure --expr 'import ./scripts/release-env.nix { root = builtins.toPath (builtins.getEnv "PWD"); }' --command ruff check scripts/release.py scripts/deploy-release.py
```

Live Forgejo draft uploads, registry writes and deployment are performed only by
the release workflow after builds and checks. Enabling stable requires the revised
infrastructure wrapper and all signing and deployment credentials above.
