"""Refresh the shared sources, transformed locks, and fixed-output hashes."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, **kwargs)
    if result.returncode:
        raise SystemExit(result.stderr if kwargs.get("capture_output") else result.returncode)
    return result


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--no-update", action="store_true", help="Keep the current flake inputs")
parser.add_argument("--override-input", nargs=2, action="append", default=[], metavar=("NAME", "SOURCE"))
args = parser.parse_args()
root = Path.cwd()
if not (root / "packages/hashes.nix").exists():
    raise SystemExit("Run update-all from the prod-pins checkout")
if not args.no_update:
    run("nix", "flake", "update", *(item for pair in args.override_input for item in ["--override-input", *pair]))

overrides = [item for pair in args.override_input for item in ["--override-input", *pair]]

system = run("nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem", capture_output=True).stdout


def build(name):
    return run("nix", "build", f"path:{root}#packages.{system}.{name}",
               "--no-link", "--print-out-paths", *overrides, capture_output=True).stdout.strip()


locks = root / "packages/locks"
locks.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="prod-pins-update-") as temporary:
    for name in ["mtp", "iota", "omikron", "omega", "client"]:
        source = build(f"{name}-source")
        dest = Path(temporary) / name
        shutil.copytree(source, dest, symlinks=True)
        for path in [dest, *dest.rglob("*")]:
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
        if name == "client":
            run("pnpm", "install", "--lockfile-only", "--ignore-scripts", "--no-frozen-lockfile", cwd=dest)
            shutil.copyfile(dest / "pnpm-lock.yaml", locks / "client.yaml")
        else:
            run("cargo", "update", "--workspace", cwd=dest)
            shutil.copyfile(dest / "Cargo.lock", locks / f"{name}.lock")

hash_file = root / "packages/hashes.nix"
for key, output in [(n, f"{n}-vendor") for n in ["mtp", "iota", "omikron", "omega"]] + [("sdk", "sdk-deps"), ("client", "client-deps")]:
    # Force a fetch even when the previous hash points at a cached result.
    text = hash_file.read_text()
    original = text
    text = re.sub(rf'({key} = ")[^"]+', rf'\g<1>sha256-{"A" * 43}=', text)
    hash_file.write_text(text)
    result = subprocess.run(["nix", "build", f"path:{root}#packages.{system}.{output}",
                             "--no-link", "--print-out-paths", *overrides], text=True, capture_output=True)
    match = re.search(r"got:\s+(sha256-[A-Za-z0-9+/=]+)", result.stderr)
    if not match:
        hash_file.write_text(original)
        raise SystemExit(result.stderr or f"Could not determine {key} hash")
    hash_file.write_text(re.sub(rf'({key} = ")[^"]+', rf'\g<1>{match[1]}', text))
    build(output)
    print(f"Updated {key}: {match[1]}", flush=True)

print("Updated sources, dependency locks, and verified vendor hashes.")
