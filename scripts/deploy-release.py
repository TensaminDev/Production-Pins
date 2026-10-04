"""Commit only the infrastructure pin, deploy that commit, revert on failure."""

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def main():
    revision = run("git", "rev-parse", "HEAD")
    repository = os.environ["NIXOS_FLAKE_REPOSITORY"]
    branch = os.environ.get("NIXOS_FLAKE_BRANCH", "main")
    server = os.environ["FORGEJO_SERVER_URL"].rstrip("/")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Invalid infrastructure repository")
    with tempfile.TemporaryDirectory(prefix="tensamin-deploy-") as temporary:
        root = Path(temporary)
        askpass = root / "askpass"
        askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) printf "%s\\n" token;; *) printf "%s\\n" "$NIXOS_FLAKE_WRITE_TOKEN";; esac\n')
        askpass.chmod(0o700)
        env = os.environ | {"GIT_ASKPASS": str(askpass), "GIT_TERMINAL_PROMPT": "0"}
        checkout = root / "infrastructure"
        run("git", "clone", "--branch", branch, "--single-branch", f"{server}/{repository}.git", str(checkout), env=env)
        original = run("git", "rev-parse", "HEAD", cwd=checkout)
        # Fail before pushing if the forced command has not adopted the new contract.
        wrapper = (checkout / "garten/tensamin-prod/services/deploy.nix").read_text()
        if "<nixos-flake commit SHA>" not in wrapper:
            raise RuntimeError("Deployment wrapper must accept <nixos-flake commit SHA> before promotion")
        url = f"git+ssh://git@methanium.net/{os.environ['FORGEJO_REPOSITORY']}?ref=main&rev={revision}"
        run("nix", "flake", "lock", "--override-input", "prod-pins", url, cwd=checkout)
        lock = json.loads((checkout / "flake.lock").read_text())
        if lock["nodes"][lock["nodes"]["root"]["inputs"]["prod-pins"]]["locked"]["rev"] != revision:
            raise RuntimeError("Infrastructure pin mismatch")
        run("git", "add", "flake.lock", cwd=checkout)
        identity = ["git", "-c", "user.name=Tensamin releases", "-c", "user.email=releases@tensamin.net"]
        changed = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=checkout, check=False).returncode
        if changed not in {0, 1}:
            raise RuntimeError("Unable to inspect infrastructure pin changes")
        if changed:
            run(*identity, "commit", "-m", f"tensamin-prod: pin {revision}", cwd=checkout)
        commit = run("git", "rev-parse", "HEAD", cwd=checkout)
        key = root / "deploy-key"
        key.write_text(os.environ["TENSAMIN_PROD_DEPLOY_SSH_KEY"] + "\n")
        key.chmod(0o600)
        known = root / "known_hosts"
        known.write_text(os.environ["TENSAMIN_SSH_KNOWN_HOSTS"] + "\n")
        config = root / "ssh_config"
        host = os.environ["TENSAMIN_PROD_DEPLOY_HOST"]
        port = os.environ.get("TENSAMIN_PROD_DEPLOY_PORT", "22")
        jump_host = os.environ.get("TENSAMIN_PROD_DEPLOY_JUMP_HOST", "")
        jump_port = os.environ.get("TENSAMIN_PROD_DEPLOY_JUMP_PORT", "7930")
        for hostname in [host, jump_host]:
            if hostname and not re.fullmatch(r"[A-Za-z0-9_.:-]+", hostname):
                raise ValueError("Invalid deployment SSH hostname")
        for value in [port, jump_port]:
            if not value.isdecimal() or not 1 <= int(value) <= 65535:
                raise ValueError("Invalid deployment SSH port")
        config.write_text(
            f"Host tensamin-deploy\n  HostName {host}\n  Port {port}\n  User deploy\n"
            + ("  ProxyJump tensamin-deploy-jump\n" if jump_host else "")
            + (f"Host tensamin-deploy-jump\n  HostName {jump_host}\n  Port {jump_port}\n"
               "  User deploy-jump\n" if jump_host else "")
            + f'Host *\n  IdentityFile "{key}"\n  IdentitiesOnly yes\n'
            f'  StrictHostKeyChecking yes\n  UserKnownHostsFile "{known}"\n'
            "  BatchMode yes\n  ConnectTimeout 15\n"
        )
        ssh = ["ssh", "-F", str(config), "-T", "tensamin-deploy"]
        # Prepare and validate SSH before publishing an infrastructure change.
        run("ssh", "-G", "-F", str(config), "tensamin-deploy")
        if changed:
            run("git", "push", "origin", f"HEAD:refs/heads/{branch}", cwd=checkout, env=env)
        try:
            subprocess.run([*ssh, commit], check=True)
            # Publication is inside the transaction, so failed publication restores the pin.
            subprocess.run(["python3", "scripts/release.py", "publish", "--channel", "stable",
                            "--tag", os.environ["RELEASE_TAG"]], check=True)
        except BaseException:
            if not changed:
                raise
            # A normal revert preserves unrelated concurrent infrastructure commits.
            run("git", "fetch", "origin", branch, cwd=checkout, env=env)
            run("git", "reset", "--hard", f"origin/{branch}", cwd=checkout)
            run(*identity, "revert", "--no-edit", commit, cwd=checkout)
            run("git", "push", "origin", f"HEAD:refs/heads/{branch}", cwd=checkout, env=env)
            rollback = run("git", "rev-parse", "HEAD", cwd=checkout)
            subprocess.run([*ssh, rollback], check=True)
            raise
        Path("release-out/deployment.json").write_text(json.dumps({
            "previous_infrastructure": original, "infrastructure": commit, "prod_pins": revision,
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
