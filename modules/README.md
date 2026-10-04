# NixOS modules

`import ./default.nix { inherit self; }` returns `default`, `iota`, `omikron`,
`omega`, and `client`. `default` imports all four component modules. The flake's
existing conditional import accepts this interface directly.

These new files must be included in the consuming Git checkout for Git-backed
flake evaluation. Verification used `path:` to include the untracked modules.

All options live under `tensamin`, with no `services.tensamin` wrapper or legacy
`services.iota`, `services.omikron`, or `services.omega` aliases.

## Interfaces

All components have `enable`, `package`, `bindAddress`, `port`, and
`openFirewall`. Services are disabled by default. Package defaults resolve via
`self.packages.${pkgs.stdenv.hostPlatform.system}`.

| Component | Package | Bind address | Port | Open firewall |
| --- | --- | --- | --- | --- |
| `tensamin.iota` | `iota-daemon` | `0.0.0.0` | 1984 | true |
| `tensamin.omikron` | `omikron` | `0.0.0.0` | 443 | true |
| `tensamin.omega` | `omega` | `0.0.0.0` | 443 | true |
| `tensamin.client` | `client-web` | `127.0.0.1` | 8080 | false |

Iota, Omikron, and Omega open TCP and UDP. Client opens only TCP when requested.

### Iota

- `stateDir`, `cacheDir`, `runtimeDir`, `logDir` default to `/var/lib/iota`,
  `/var/cache/iota`, `/run/iota`, `/var/log/iota`.
- `assetDir` defaults to the central `iota` package's pinned source
  `static/web` directory. This is upstream's shipped asset directory, currently
  containing its 404 page, not the client application. Override it to serve
  other assets.
- `webMode` is `network` by default, or `loopback` or `disabled`. Upstream
  requires TLS for both enabled modes. Set `bindAddress` explicitly for loopback.
- `certFile` and `keyFile` are nullable runtime path strings, supplied together.
  An enabled listener requires them unless `settingsFile` supplies complete TLS
  configuration.
- `omegaApiUrl` defaults to `https://omega.tensamin.net`.
- `environmentFiles` is a list of runtime path strings, defaulting to `[]`.
- `settings` contains YAML-compatible operator configuration, defaulting to `{}`.
  Module listener and asset options take precedence. Startup rewrites the mutable
  `stateDir/config.yaml`, preserving omitted `iota_id`, `omikron_host`,
  `omikron_port`, and `omikron_id`. Explicit values, including null, override them.
  Other daemon/operator edits to this file are replaced at the next startup.
- `settingsFile` is a nullable runtime path string. It replaces generated
  settings, with the same preservation of omitted discovery fields. Its listener
  and TLS settings must agree with the module's firewall and capability options.
  Relative paths resolve against `stateDir`, not the source file's directory.

The systemd service and socket are named `iota`. IPC uses
`${runtimeDir}/iota.sock`, mode `0660`, owned by `iota:iota`. Add authorized
operators to the `iota` group. Daemon identities remain under
`${stateDir}/identity`; the module does not reseed them. Exit code 75 forces a
restart. Config paths, deployment mode, supervisor, and all mutable directories
are passed through the upstream `IOTA_*` environment contract.

### Omikron and Omega

- `stateDir` defaults to `/var/lib/omikron` or `/var/lib/omega` and is the working
  directory of the matching systemd service and service user.
- Set either `acmeCertDir`, containing `fullchain.pem` and `key.pem`, or both
  `certFile` and `keyFile`. All are nullable runtime path strings. Startup copies
  the certificate to `certs/cert.pem` and converts the key to unencrypted PKCS8
  at `certs/key.pem`, owned by the service user with mode `0600`.
- `identityFile` and `publicIdentityFile` are nullable runtime path strings,
  supplied together. Startup copies them to `omikron.mk` and `omikron.mpkb`, or
  `omega.mk` and `omega.mpkb`. Null retains existing state or lets upstream
  generate an identity. Supplied identities are reapplied on every startup.
- `environment` is an attribute set of non-secret string settings, default `{}`.
  Module-generated listener and Omikron discovery variables take precedence.
- `environmentFiles` is a list of runtime environment paths, default `[]`.
  Systemd loads these after the declared environment, so they can override it.
  Keep listener variables consistent with firewall options. Omega requires
  `DB_URL`; it uses file-based identities, not `PRIVATE_KEY`/`PUBLIC_KEY`.

Omikron also requires positive `id` and `omegaTrustFile`, the runtime Omega public
key bundle copied to `omega.mpkb`. `omegaHost` defaults to `tensamin.net` and
`omegaPort` to the upstream default 9187. Set it to the deployed Omega listener
port, whose module default is 443. These become `ID`, `OMEGA_HOST`, `OMEGA_PORT`,
`RHO_PORT`, and `BIND_ADDRESS`. Omega uses `PORT` and `BIND_ADDRESS`.

Trust and identity installation runs for both manual TLS and ACME. Configure
certificate issuance separately and restart the corresponding service after
renewal so it recopies certificates. Environment and secret path strings do not
copy secret contents into the Nix store.

### Client

`hostName` defaults to `localhost`. The module enables nginx and adds that
virtual host with an explicit HTTP listener at `bindAddress:port`, using
`client-web`'s output root and SPA fallback to `/index.html`. Configure public
TLS/proxy routing separately. It does not configure Anubis, guest accounts, or
install the Electron client.

## Verification

The combined module was evaluated with actual central package outputs in
minimal x86_64-linux and aarch64-linux NixOS container configurations. All
assertions passed and `system.build.toplevel.drvPath` evaluated. Checks included
both server TLS branches, all services disabled, Iota disabled-listener mode,
a custom Iota runtime directory, and a custom nginx listener. Missing Omikron
TLS produces the intended assertion. Evaluation does not build or start the
applications.
