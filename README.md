# Tensamin production pins

Shared sources and builds for the client, Iota, Omikron, Omega, MTP, and type maps.

## Build usage

Linux x86_64 and aarch64 packages use one nixpkgs, Rust toolchain, MTP source,
and type-map source. The default package is the Electron client.

```sh
nix build .
nix run .#client
nix build .#client-web
nix build .#iota .#iota-daemon .#iota-ui .#omikron .#omega
nix develop .#iota
nix develop .#client
```

`client-web` contains the static site at its output root. `iota` contains
`iota`, `iota-daemon`, `iota-updater`, `iota-release`, and `iota-bundle`. `iota-ui` exposes
the terminal UI as `bin/iota-ui`. `iota-bundle` adds upstream systemd files,
release scripts, and artifact contracts under `share/iota`. Signed release
manifests and deployment-specific update URLs must be supplied to those scripts.
`iota-portable` builds musl-static binaries using the same sources and Cargo
vendor dependencies. Releases use these binaries for ordinary Linux, with no
Nix installation required. `share/iota/web` contains the pinned static assets.
`iota-container`, `omikron-container` and `omega-container` produce Docker-loadable images.
Mount runtime configuration, identity files, and certificates in their working
directories, `/var/lib/omikron` and `/var/lib/omega`.

`mtp-sdk` builds the SDK from the shared MTP source.

Iota's image runs the daemon as UID/GID 1000 and persists `/var/lib/iota`.
Bind mounts must be writable by that user. Supply writable configuration at
`/var/lib/iota/config/config.yaml`, with `web.mode: network`, `web.bind: 0.0.0.0`,
`web.port: 1984`, and `web.certificate`/`web.key` pointing to mounted TLS files.
Publish both `1984/tcp` and `1984/udp`. Review and accept terms interactively
with `docker exec -it CONTAINER /bin/iota terms accept`, then restart the
container. Use `--restart on-failure` to handle the daemon's restart exit 75.
Images update by pulling a new release and recreating the container.

## Updating builds

```sh
nix run .#update-all
# Recalculate dependency locks and hashes without moving source inputs:
nix run .#update-all -- --no-update
```

Run this from the checkout with SSH access to `git@methanium.net`. The command
supplies Cargo, pnpm, Python, Git, and Nix. It refreshes `flake.lock`, resolves
the transformed Cargo and pnpm dependency graphs into `packages/locks`, and
rebuilds every dependency fetcher to verify `packages/hashes.nix`. Review all
generated changes and build the affected packages before committing.

MTP git dependencies become local paths to the shared input before vendoring.
Omega's identity crate comes from the same Iota input as the Iota binaries.
Both YAML and Rust type-map includes come from `mtp-type-maps`. The SDK and
WASM compile from MTP source, with WASM generated for these same maps. The
packaged Vite plugin reuses that WASM and still generates JavaScript type maps.
Client dependency manifests and pnpm overrides cannot select a release SDK.

Project shells are `iota`, `omikron`, `omega`, `mtp`, and `client`.
The default shell supplies `update-all`. Android/Tauri shells are a followup.

## Source overrides for CI

Override raw source inputs when building current project sources:

```sh
nix build .#iota --override-input iota path:../iota
```

Packages expose `passthru.source`; Rust packages also expose
`passthru.transformedSource`, `passthru.mtp`, and `passthru.mtp-type-maps`.
`lib.mkPackages { system = "x86_64-linux"; sources = { iota = ../iota; }; }`
returns `packages` and `devShells`, and accepts a replacement `hashes` attrset.
Dependency-changing overrides require regenerated locks and vendor hashes.
Use `update-all` in a disposable checkout with the desired input overrides.

Source preparation, dependency updates, and release scripts use Bun from the
central nixpkgs lock, including its built-in TOML and YAML parsers. They fetch no
runtime dependencies. Validate scripts with `bash scripts/check.sh` in the
`scripts/release-env.nix` tools shell.

```sh
nix run .#update-all -- --no-update --override-input iota path:../iota
```

## NixOS modules

Add this flake as `inputs.tensamin`, pass `inputs` through `specialArgs`, and
import the combined module:

```nix
{ inputs, pkgs, ... }: {
  imports = [ inputs.tensamin.nixosModules.default ];
  environment.systemPackages = [
    inputs.tensamin.packages.${pkgs.stdenv.hostPlatform.system}.client
  ];
  tensamin.client.enable = true;
}
```

Individual imports are `nixosModules.iota`, `.omikron`, `.omega`, and `.client`.
All options live under `tensamin.*`, and services are disabled by default.
The client module serves `client-web` through nginx on `127.0.0.1:8080` by
default; installing Electron is separate. Public TLS and Anubis routing belong
to the infrastructure. Production routes host nginx through host Anubis and
a loopback origin to nginx in the internal production VM.

Iota requires TLS for enabled listeners. Omikron and Omega require runtime
certificates; Omikron also needs its ID and Omega trust bundle, and Omega
needs `DB_URL`. Use runtime path strings for secrets. See
[modules/README.md](modules/README.md) for options and state handling.
New module files must be present in the Git-backed flake source before consumers
can import them; local `path:` evaluation includes untracked files.

## Releases and updates

Combined publication belongs to this repository. Stable and canary releases
should contain artifacts built from the same pinned graph. Client dev builds
are local and verification-only, with no dev releases. Android IDs are
`net.tensamin.client`, `net.tensamin.client.canary`, and
`net.tensamin.client.dev`; canary uses yellow icons and dev uses blue outline
branding. Android signing identity must stay consistent and version codes
must increase per application ID.

Images publish to the Forgejo registry as
`SERVER/tensamin/SERVICE:IMMUTABLE_TAG-ARCH`, including `iota`, `omikron`, and
`omega`. Local image revision tags differ from the immutable publication tags.
See [scripts/releases.md](scripts/releases.md) for workflow configuration.

For unmanaged per-user Linux, extract `iota-portable-linux-ARCH.tar.gz` and run
`./bin/iota`. The CLI discovers its sibling daemon and packaged assets. User
IPC defaults to `$XDG_RUNTIME_DIR/iota/iota.sock`, or
`$XDG_STATE_HOME/iota/iota.sock`, with `~/.local/state` as the fallback.
Explicit absolute `IOTA_SOCKET` and `IOTA_DATA_ROOT` overrides still work.
TLS clients use the host CA trust store.

Unmanaged system-wide Linux Iota uses CLI bootstrap with a trusted signed bundle, then
explicit `iota update channel stable`, `iota update check`, and
`iota update apply` operations. Trust lives in `/etc/iota/update.env` and
cannot be replaced by process environment. The pinned upstream bootstrap
enables `iota-update.timer`; disable it with
`sudo systemctl disable --now iota-update.timer` for manual-only updates.
NixOS deployments update through their infrastructure flake.

The infrastructure and this flake have separate nixpkgs locks. Refresh both
when required for security fixes, then build and deploy the affected outputs.
`update-all` verifies dependency fetchers, not full application builds or live
deployment. Infrastructure `lunitely update` pulls published configuration
changes; `lunitely rebuild` activates the local checkout without pulling.
`lunitely boot` and `update --boot` stage the next boot without rebooting.

The production deploy wrapper pins an exact prod-pins SHA, rebuilds with
`--no-update-lock-file`, checks health, and restores the previous generation on
failure. It does not roll back mutable application data. Record successful
runtime pins in the infrastructure lock for later administrator updates.

See the documentation site's [deployment](https://docs.tensamin.net/deployment/),
[updates](https://docs.tensamin.net/updates/), and
[release guide](https://docs.tensamin.net/developers/releases/).
Its Obtainium configuration uses a real JSON import and explicit self-hosted
Forgejo source override. Sync it with release titles and APK layout after the
central publication pipeline is finalized.
