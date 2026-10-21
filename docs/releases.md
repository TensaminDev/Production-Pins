# Client and Iota releases

Every push to `main`, or manual Canary run, deploys the committed source pins.
A channel/commit without a published release builds Linux x86_64 and ARM64;
the x86_64 build also signs the universal Android APK.
Only after both builds and Canary deployment succeed does the workflow publish
an immutable `canary-SHA` prerelease. Its web build is deployed to
`https://tensamin-canary.pages.dev` before publication.

Run **Deploy Stable** manually on the same `main` commit to promote it. Stable
requires a successful Canary workflow for exactly that SHA. Before editing its
own pin, Stable requires infrastructure `main` to match the resulting infrastructure
commit recorded by that Canary deployment exactly. Any intervening infrastructure
commit, including another channel's pin update, requires a new Canary run.
Stable rebuilds the same locked sources with
Stable branding and application IDs, deploys Stable, and publishes a normal
`stable-SHA` release. The Stable web app is deployed to
`https://tensamin-stable.pages.dev`. Builds never refresh application dependency pins.

Published releases are never silently replaced. A workflow rerun for an already
published channel and full commit skips native builds, web deployment and
publication. It redeploys infrastructure and records a fresh deployment manifest,
so Canary can revalidate infrastructure changes without replacing downloads.
Stable resolves the latest successful Canary manifest immediately before deployment.
Release sequences and Android
version codes are `1000000000 + github.run_number`, independently increasing for
each channel. Keep workflow names and counters stable. APK upgrades require the
same signing certificate as the installed APK.

Release names contain only the channel and seven SHA characters, for example
`canary-e04f498`. The workflow run number is used only for internal update
sequences and version codes. Provenance and signed metadata retain full commit identities.
Existing tags keep their download URLs, while their display titles can be shortened.

## Infrastructure deployment

Both channels update existing VMs only. Canary selects `canary-pins` and
`tensamin-canary`; Stable selects `prod-pins` and `tensamin-prod`. They do not
deploy hosts, provision guests or change VM capacity. The existing shared
`tensamin-deployment` concurrency group serializes channel workflows.

The deployment job checks out infrastructure `main` from
`nonanium/NixOS-Flake`, edits only the selected pin URL to the current
Production-Pins commit, then runs `nix flake update INPUT` on the runner.
It rejects changes to unrelated root inputs and their locked dependencies,
including shared nodes still used by the other channel. The selected lock must
resolve to the requested Production-Pins commit. The comparison follows the
resolved dependency graph, so Nix's incidental lock-node renames are allowed.

CI builds only the selected VM's system with `--no-update-lock-file`, commits the
pin and lock changes if necessary, then pushes normally to infrastructure
`main`. A rejected push stops deployment. If the desired pin and lock are already
committed, CI uses that existing commit without creating an empty commit.
After confirming the remote SHA, it runs the infrastructure CLI from the clean,
pushed checkout:

```sh
nix run --no-update-lock-file .#tensamin -- deploy --channel canary
# Stable uses --channel stable.
```

The CLI deploys the current lock without updating it and checks the target's
`tensamin-registry.service`. Only after the CLI returns success does CI write
`deployment/manifest.json`, containing `pins` and `infrastructure` with the actual
Production-Pins and resulting infrastructure commit SHAs. Each channel uploads
its `CHANNEL-deployment` artifact. Stable downloads the manifest from the
successful Canary workflow selected for its current Production-Pins commit.
Canary must finish the complete workflow successfully before Stable can use it.

A failure after the infrastructure push leaves the committed desired state on
`main`, but does not produce a new success record. Fix the cause and dispatch a
new Canary run. A successful deployment does not imply publication succeeded;
Pages and release publication still run afterward.

### Deployment access

Both GitHub environments use the existing deployment configuration:

- `INFRASTRUCTURE_TOKEN` checks out and pushes the infrastructure repository.
  Nix source fetches use the workflow's native `github.token`, independently of
  the infrastructure token's organization access and lifetime policy.
- `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` join the runner to the tailnet as
  `tag:tensamin-deploy`.
- `DEPLOY_SSH_KEY` accesses the selected guest through its inventory jump host.
- `DEPLOY_KNOWN_HOSTS` is an environment variable containing reviewed SSH host
  keys for both the jump host and selected VM, including nonstandard port forms.
  Empty configuration fails and SSH uses strict host-key verification.

The SSH Forgejo input uses the existing source-read strategy on the installed
guest. `source-ssh.sh` routes Git's Forgejo SSH commands through the selected
guest with passwordless sudo. That guest's declared SSH configuration selects
`/run/secrets/forgejo-read` and verifies Forgejo's declared host key. The private
read key stays on the guest. Lock resolution and system builds run locally in
CI; no checkout or rebuilt lock is transferred from a remote rebuild.
This requires a migrated, reachable guest with its existing read key installed.
Other inputs retain their existing transport and access requirements.

CI does not need private application decryption keys and does not run
`secrets validate`. Runtime secrets decrypt on the target during activation.

## Signing configuration

Configure these secrets in both the `canary` and `stable` GitHub environments:

- `ANDROID_KEYSTORE_BASE64`, the existing keystore encoded as base64.
- `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_STORE_PASSWORD`.
- `IOTA_RELEASE_SIGNING_KEY`, a 32-byte Ed25519 seed encoded as hex.
- `CLOUDFLARE_API_TOKEN`, with Account / Cloudflare Pages / Edit permission.
- `CLOUDFLARE_ACCOUNT_ID`, the account hosting the two Pages projects.

Set environment variable `IOTA_RELEASE_PUBLIC_KEY` to the corresponding hex
public key. The signer checks it before building the installers. Signing uses
the key ID `primary`. Android signing files exist only in a temporary directory;
Iota signing happens after compilation. Neither private key enters a Nix store
output or release artifact.

## Static web hosting

Both web apps use Cloudflare Pages Direct Upload and the Pages Free static asset
limits. There is no idle hosting fee or static request/bandwidth charge. No Pages
Functions, Worker entry point, paid subscription, or other billed resource is
created. Builds reject runtime code, more than 20,000 files, and files above
25 MiB. Missing paths fall back to `index.html` for client-side routes.

Cloudflare account/domain subscriptions that already exist are separate from
these static deployments. Custom domains can be attached in Pages and routed
through Cloudflare DNS. Server deployments continue to run the backend services;
the web app is not deployed to a NixOS guest.

## Release assets

Commit-specific releases include Linux Client AppImages, deb and rpm packages for both
architectures, one universal Android APK, Iota binaries and portable archives,
and `iota-installer-linux-ARCH.zip`. `SHA256SUMS` and `release-provenance.json`
record the downloaded artifacts and the Production-Pins commit.

The moving `canary` and `stable` releases mirror all assets from the latest
commit-specific release, including the universal APK, Electron AppImage/deb/rpm packages
for both architectures, Iota bundles, checksums and signed update manifests.
Obsolete versioned client packages are removed after successful uploads.
These channel releases are excluded from GitHub Latest and the Obtainium title
filters. Manifests expire after 90 days and reference immutable binary URLs.
Publication refuses to regress or reuse a channel sequence. A transient manifest/signature mismatch
while those two assets upload is rejected; the next hourly check retries.

The client has no built-in updater. Android users can use the docs' Obtainium
imports; desktop users install new packages manually. NixOS-managed Iota updates
through its system configuration. Only unmanaged systemd Iota installations use
the signed updater and its hourly timer.
