# GitHub deployment

Push updated `flake.lock` pins to `main` to deploy Canary. After testing that deployment, manually run **Deploy Stable** with its successful Canary run ID. Stable uses that run's exact pins and rejects infrastructure code changes since the trial. Passing build or process checks never promotes Stable automatically.

Both workflows run on GitHub-hosted Ubuntu, join the tailnet temporarily, build locally, and deploy with deploy-rs through Gartenhaus. The selected channel's infrastructure lock is committed only after deployment checks pass. Client installers, release signing and registry publication are not part of these server deployment workflows; the former Forgejo workflows referenced missing release scripts.

Infrastructure `flake.nix` records separate immutable Stable and Canary revisions. Ordinary `nix flake update` cannot promote Stable by following a moving branch. Only manual Stable promotion changes its recorded revision.

## Repository settings

In `TensaminDev/Production-Pins`, enable Actions and allow `actions/*`, `cachix/install-nix-action` and `tailscale/github-action`. Leave default workflow permissions read-only. The workflows request Contents read and Actions read. No source-repository write tokens are needed for public application dependencies.

Create environments named `canary` and `stable`, restricted to `main`. Canary needs no approval. Give Stable required reviewers if your GitHub plan supports them. Stable is manual regardless. Protect `main` from force pushes and protect workflow changes through review.

Set these secrets in each environment:

- `INFRASTRUCTURE_TOKEN`: a fine-grained GitHub PAT whose resource owner is `nonanium`, limited to `NixOS-Flake`, with **Contents read and write** and Metadata read. It checks out the private configuration and commits the selected channel's lock. It needs no Actions write, administration, packages or source-repository permissions. A GitHub App installation token with the same repository access can replace it later.
- `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`: a Tailscale OAuth client with **Auth keys write**, restricted to `tag:tensamin-deploy`. Make that tag an allowed tag for the client. Grant that tag TCP access to Gartenhaus on port 23 only. Guest traffic crosses the SSH jump connection, so direct tailnet routes to guest subnets are unnecessary.
- `DEPLOY_SSH_KEY`: an unencrypted Ed25519 private key dedicated to this environment. The Canary and Stable keys are already generated on the workstation at `~/.ssh/methanium-deploy/{canary,stable}` and their public halves are declared in the NixOS flake (`access.nix`). Both authenticate as `deploy` on the Gartenhaus jump host. Each Tensamin guest's `deploy` account accepts only its own channel's key and uses passwordless sudo for NixOS activation. Deployments do not use the personal `alois` account.
- `FORGEJO_READ_KEY`: a read-only Forgejo deploy key authorized for `old-nix/nextcloud` and `old-alex/ap-tracker`. The private key is at `~/.ssh/methanium-deploy/forgejo-read` (the same key the servers use for their own checkouts).

Set environment variable `DEPLOY_KNOWN_HOSTS` to verified SSH host-key lines for `[100.105.184.79]:23`, the selected guest's private IPv4 address, and `[git.internal.methanium.net]:2222`. Obtain keys through an already trusted connection. Do not trust an unauthenticated scan as verification.

The same infrastructure token may be defined as an organization secret with access limited to Production-Pins if both environments share it. Stable's SSH key should remain environment-scoped. Never use a personal administrator SSH key for Actions.

## Initial activation

The current infrastructure refactor changes guest disk layout and database ownership. Migrate the guests as described in the infrastructure impermanence guide before enabling automatic deployments. The deployment script refuses guests without a tmpfs root and container-local Omega database directory. Missing secrets or incomplete migration cause a failed run, never a production promotion.

After setting secrets and authorizing the public keys declaratively, run **Deploy Canary** manually once. Inspect the resulting `canary-deployment` artifact and logs. After your trial, run **Deploy Stable**, entering that Canary run's numeric ID. Repeat with each new release candidate.
