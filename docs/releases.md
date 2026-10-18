# Client and Iota releases

Every push to `main`, or manual Canary run, builds the committed source pins for
Linux x86_64 and ARM64. The x86_64 build also signs the universal Android APK.
Only after both builds and Canary deployment succeed does the workflow publish
an immutable `canary-RUN-SHA` prerelease.

Run **Deploy Stable** manually on the same `main` commit to promote it. Stable
requires a successful Canary workflow for exactly that SHA and the existing
infrastructure compatibility check. It rebuilds the same locked sources with
Stable branding and application IDs, deploys Stable, and publishes a normal
`stable-RUN-SHA` release. Builds never refresh application dependency pins.

Published releases are never silently replaced. Rerunning an already published
run fails; manually dispatch a new run instead. Release sequences and Android
version codes are `1000000000 + github.run_number`, independently increasing for
each channel. Keep workflow names and counters stable. APK upgrades require the
same signing certificate as the installed APK.

## Signing configuration

Configure these secrets in both the `canary` and `stable` GitHub environments:

- `ANDROID_KEYSTORE_BASE64`, the existing keystore encoded as base64.
- `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_STORE_PASSWORD`.
- `IOTA_RELEASE_SIGNING_KEY`, a 32-byte Ed25519 seed encoded as hex.

Set environment variable `IOTA_RELEASE_PUBLIC_KEY` to the corresponding hex
public key. The signer checks it before building the installers. Signing uses
the key ID `primary`. Android signing files exist only in a temporary directory;
Iota signing happens after compilation. Neither private key enters a Nix store
output or release artifact.

## Release assets

Numbered releases include Linux Client AppImages, deb and rpm packages for both
architectures, one universal Android APK, Iota binaries and portable archives,
and `iota-installer-linux-ARCH.zip`. `SHA256SUMS` and `release-provenance.json`
record the downloaded artifacts and the Production-Pins commit.

Iota's moving `canary` and `stable` releases contain only signed update manifests.
They are excluded from GitHub Latest and the Obtainium title filters. Manifests
expire after 90 days and reference immutable binary URLs. Publication refuses
to regress or reuse a channel sequence. A transient manifest/signature mismatch
while those two assets upload is rejected; the next hourly check retries.

The client has no built-in updater. Android users can use the docs' Obtainium
imports; desktop users install new packages manually. NixOS-managed Iota updates
through its system configuration. Only unmanaged systemd Iota installations use
the signed updater and its hourly timer.
