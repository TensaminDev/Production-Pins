"""Forgejo release staging, provenance selection, signing and channel refresh."""

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def write(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


class Forgejo:
    def __init__(self):
        self.server = os.environ["FORGEJO_SERVER_URL"].rstrip("/")
        self.repo = os.environ["FORGEJO_REPOSITORY"]
        self.base = f"{self.server}/api/v1/repos/{self.repo}"
        self.token = os.environ["RELEASE_TOKEN"]

    def request(self, path, method="GET", data=None, content_type="application/json", raw=False):
        url = path if path.startswith("https://") else self.base + path
        # Do not forward the API token to an asset redirect on another host.
        if urllib.parse.urlparse(url).netloc != urllib.parse.urlparse(self.server).netloc:
            raise ValueError("Unexpected asset host")
        if data is not None and not isinstance(data, bytes):
            data = json.dumps(data).encode()
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"token {self.token}", "Content-Type": content_type,
        })
        class SameHostRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                if urllib.parse.urlparse(newurl).netloc != urllib.parse.urlparse(req.full_url).netloc:
                    raise ValueError("Refusing authenticated cross-host redirect")
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        with urllib.request.build_opener(SameHostRedirect()).open(request, timeout=120) as response:
            body = response.read()
            return json.loads(body) if body and not raw and "json" in response.headers.get("Content-Type", "") else body

    def release(self, tag, missing=False):
        try:
            return self.request("/releases/tags/" + urllib.parse.quote(tag, safe=""))
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise

    def assets(self, release):
        result = []
        for page in range(1, 100):
            batch = self.request(f"/releases/{release['id']}/assets?limit=50&page={page}")
            result.extend(batch)
            if len(batch) < 50:
                return result
        raise RuntimeError("Too many release assets")

    def download(self, release, name):
        asset = next(asset for asset in self.assets(release) if asset["name"] == name)
        return self.request(asset["browser_download_url"], raw=True)

    def upload(self, release, path):
        # Forgejo's attachment API takes multipart/form-data, not raw bytes.
        boundary = "tensamin-" + os.urandom(16).hex()
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="attachment"; '
                f'filename="{path.name}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
        body += path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        return self.request(f"/releases/{release['id']}/assets?name=" + urllib.parse.quote(path.name),
                            "POST", body, "multipart/form-data; boundary=" + boundary)


def provenance(directory, channel, tag):
    lock = json.loads(Path("flake.lock").read_text())
    sources = {name: lock["nodes"][node]["locked"]
               for name, node in lock["nodes"]["root"]["inputs"].items() if isinstance(node, str)}
    files = {}
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name not in {"release.json", "SHA256SUMS"}:
            files[path.name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                "size": path.stat().st_size}
    write(directory / "release.json", {
        "schema": 1, "channel": channel, "tag": tag, "revision": run("git", "rev-parse", "HEAD"),
        "run_id": os.environ["FORGEJO_RUN_ID"], "sources": sources,
        "lock_sha256": hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest(),
        "architectures": [arch for arch in ["x86_64", "aarch64"]
                          if (directory / f"iota-linux-{arch}").exists()],
        "artifacts": files,
    })
    (directory / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in sorted(directory.iterdir()) if path.is_file() and path.name != "SHA256SUMS"))


def sign(directory, channel, tag, sequence):
    api = Forgejo()
    old = api.release(channel, missing=True)
    if old:
        for asset in api.assets(old):
            if re.fullmatch(r"iota-update-linux-(x86_64|aarch64)\.json", asset["name"]):
                manifest = json.loads(api.download(old, asset["name"]))
                if sequence <= manifest["release_sequence"]:
                    raise RuntimeError("Channel sequence must strictly increase")
    source_sha = json.loads(Path("flake.lock").read_text())
    source_sha = source_sha["nodes"][source_sha["nodes"]["root"]["inputs"]["iota"]]["locked"]["rev"]
    os.environ["IOTA_RELEASE_SOURCE_SHA"] = source_sha
    now = dt.datetime.now(dt.timezone.utc)
    published = now.isoformat(timespec="seconds").replace("+00:00", "Z")
    expires = (now + dt.timedelta(days=14)).isoformat(timespec="seconds").replace("+00:00", "Z")
    host = run("nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem").removesuffix("-linux")
    signer = directory / f"iota-release-linux-{host}"
    verifier = directory / f"iota-bundle-linux-{host}"
    signer.chmod(0o755)
    verifier.chmod(0o755)
    base = f"{api.server}/{api.repo}/releases/download/{tag}"
    contract = directory / "iota-contract/scripts"
    for arch in ["x86_64", "aarch64"]:
        if not (directory / f"iota-linux-{arch}").exists():
            continue
        binaries = directory / f"bin-{arch}"
        binaries.mkdir(exist_ok=True)
        for binary in ["iota", "iota-daemon", "iota-updater"]:
            target = binaries / binary
            target.write_bytes((directory / f"{binary}-linux-{arch}").read_bytes())
            target.chmod(0o755)
        manifest = directory / f"iota-update-linux-{arch}.json"
        run("bash", str(contract / "build-update-manifest.sh"), str(binaries),
            os.environ["IOTA_BASE_VERSION"], channel, str(sequence), published, expires,
            "linux", arch, base, str(manifest))
        public = run(str(signer), "sign", str(manifest), str(manifest) + ".sig")
        if public != os.environ["IOTA_RELEASE_PUBLIC_KEY"]:
            raise RuntimeError("Release signing key does not match the pinned public key")
        url = f"{api.server}/{api.repo}/releases/download/{channel}/{manifest.name}"
        bundle = directory / f"iota-linux-{arch}.zip"
        bundle.unlink(missing_ok=True)
        run("bash", str(contract / "build-release-bundle.sh"), str(binaries),
            json.loads(manifest.read_text())["product_version"], str(manifest), url, public,
            url + ".sig", channel, os.environ.get("IOTA_RELEASE_SIGNING_KEY_ID", "primary"), str(bundle))
        run(str(verifier), str(bundle))


def stage(directory, channel, tag):
    api = Forgejo()
    if api.release(tag, missing=True):
        raise RuntimeError("Immutable release tag already exists")
    release = api.request("/releases", "POST", {
        "tag_name": tag, "target_commitish": run("git", "rev-parse", "HEAD"),
        "name": tag, "body": "Verified central source build. See release.json for provenance.",
        "draft": True, "prerelease": channel == "canary",
    })
    for path in sorted(directory.iterdir()):
        if path.is_file():
            api.upload(release, path)
    # Validate staged attachment bytes before any deployment or visibility change.
    for path in sorted(directory.iterdir()):
        if path.is_file() and hashlib.sha256(api.download(release, path.name)).digest() != hashlib.sha256(path.read_bytes()).digest():
            raise RuntimeError(f"Staged asset mismatch: {path.name}")
    write(directory / "stage.json", {"id": release["id"], "tag": tag})


def publish(directory, channel, tag):
    api = Forgejo()
    immutable = api.release(tag)
    if not immutable["draft"]:
        raise RuntimeError("Expected a staged draft")
    registry = urllib.parse.urlparse(api.server).netloc
    auth = directory / ".registry-auth.json"
    try:
        subprocess.run(["skopeo", "login", "--authfile", str(auth), "--username",
                        os.environ["FORGEJO_REGISTRY_USER"], "--password-stdin", registry],
                       input=api.token, text=True, check=True)
        for image in directory.glob("*-image-linux-*.tar.gz"):
            service, arch = image.name.split("-image-linux-")
            arch = arch.removesuffix(".tar.gz")
            run("skopeo", "--policy", os.environ["CONTAINERS_POLICY"], "copy", "--authfile", str(auth), "docker-archive:" + str(image),
                f"docker://{registry}/{api.repo.split('/')[0]}/{service}:{tag}-{arch}")
        api.request(f"/releases/{immutable['id']}", "PATCH", {"draft": False})
        try:
            update_pointer(api, directory, channel, tag)
        except Exception:
            api.request(f"/releases/{immutable['id']}", "PATCH", {"draft": True})
            raise
    finally:
        auth.unlink(missing_ok=True)


def update_pointer(api, directory, channel, tag):
    pointer = api.release(channel, missing=True)
    new = pointer is None
    if new:
        pointer = api.request("/releases", "POST", {
            "tag_name": channel, "target_commitish": run("git", "rev-parse", "HEAD"),
            "name": channel, "draft": True, "prerelease": channel == "canary",
        })
    backup = []
    names = {path.name for path in directory.glob("iota-update-linux-*.json*")}
    names.update({"channel.json", "electron-release-metadata.json"})
    # A refresh never moves binaries or changes the immutable release identity.
    write(directory / "channel.json", {"channel": channel, "tag": tag,
        "url": f"{api.server}/{api.repo}/releases/tag/{tag}"})
    electron = [json.loads(path.read_text()) for path in directory.glob("electron-release-metadata-*.json")]
    if electron:
        combined = electron[0]
        combined["artifacts"] = [artifact for entry in electron for artifact in entry["artifacts"]]
        write(directory / "electron-release-metadata.json", combined)
    else:
        names.discard("electron-release-metadata.json")
    # Remove stale architecture manifests too, so they cannot advertise another build.
    old_assets = api.assets(pointer)
    names.update(asset["name"] for asset in old_assets if asset["name"].startswith("iota-update-linux-"))
    try:
        for asset in old_assets:
            if asset["name"] in names:
                backup.append((asset["name"], api.download(pointer, asset["name"])))
                api.request(f"/releases/{pointer['id']}/assets/{asset['id']}", "DELETE")
        for name in sorted(names):
            path = directory / name
            if path.exists():
                api.upload(pointer, path)
        api.request(f"/releases/{pointer['id']}", "PATCH", {"draft": False,
            "body": f"Current {channel} build: {tag}. Signed metadata refreshed automatically."})
    except Exception:
        for asset in api.assets(pointer):
            if asset["name"] in names:
                api.request(f"/releases/{pointer['id']}/assets/{asset['id']}", "DELETE")
        for name, raw in backup:
            path = directory / name
            path.write_bytes(raw)
            api.upload(pointer, path)
        if new:
            api.request(f"/releases/{pointer['id']}", "DELETE")
        raise


def select(tag):
    if not re.fullmatch(r"canary-[0-9a-f]{40}-[0-9]+", tag):
        raise ValueError("Select an immutable canary tag")
    api = Forgejo()
    release = api.release(tag)
    data = json.loads(api.download(release, "release.json"))
    if release["draft"] or not release["prerelease"] or data["channel"] != "canary" or data["tag"] != tag:
        raise RuntimeError("Not a published canary")
    result = api.request(f"/actions/runs/{data['run_id']}")
    result = result.get("workflow_run", result)
    if result["conclusion"] != "success" or result["head_sha"] != data["revision"]:
        raise RuntimeError("Canary workflow has not completed successfully")
    revision = data["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid source revision")
    run("git", "fetch", "origin", revision)
    run("git", "checkout", "--detach", revision)
    if hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest() != data["lock_sha256"]:
        raise RuntimeError("Canary lock provenance mismatch")
    Path(".release-selection.json").write_text(json.dumps(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["select", "sign", "stage", "publish", "refresh", "provenance"])
    parser.add_argument("--directory", type=Path, default=Path("release-out"))
    parser.add_argument("--channel", choices=["stable", "canary"], default="canary")
    parser.add_argument("--tag")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.command == "select":
        select(args.tag)
        return
    sequence = int(os.environ.get("RELEASE_SEQUENCE", str(int(time.time()))))
    if not 0 < sequence <= 2100000000:
        raise ValueError("Sequence exceeds Android version-code range")
    if args.command == "refresh":
        api = Forgejo()
        pointer = api.release(args.channel, missing=True)
        if pointer is None:
            return
        tag = json.loads(api.download(pointer, "channel.json"))["tag"]
        release = api.release(tag)
        directory.mkdir(parents=True, exist_ok=True)
        data = json.loads(api.download(release, "release.json"))
        run("git", "fetch", "origin", data["revision"])
        run("git", "checkout", "--detach", data["revision"])
        if hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest() != data["lock_sha256"]:
            raise RuntimeError("Refresh lock provenance mismatch")
        for asset in api.assets(release):
            path = directory / asset["name"]
            if path.name != asset["name"]:
                raise ValueError("Unsafe asset name")
            path.write_bytes(api.download(release, path.name))
        for name, expected in data["artifacts"].items():
            path = directory / name
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected["sha256"]:
                raise RuntimeError(f"Immutable asset mismatch: {name}")
        host = run("nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem").removesuffix("-linux")
        # Helpers are Nix-linked binaries. Restore their exact runtime closure.
        with (directory / f"iota-linux-{host}.nar.gz").open("rb") as archive:
            unzip = subprocess.Popen(["gzip", "-dc"], stdin=archive, stdout=subprocess.PIPE)
            subprocess.run(["nix-store", "--import"], stdin=unzip.stdout, check=True)
            unzip.stdout.close()
            if unzip.wait() != 0:
                raise RuntimeError("Unable to restore release helper closure")
        # Recover the exact contract from the immutable source revision.
        bundle = run("nix", "build", "--no-link", "--print-out-paths", ".#iota-bundle")
        run("cp", "-rL", bundle + "/share/iota", str(directory / "iota-contract"))
        (directory / "iota-contract/static").mkdir(exist_ok=True)
        (directory / "iota-contract/static-web").rename(directory / "iota-contract/static/web")
        for name, destination in [("artifacts.tsv", "iota-updater"), ("bundle-files.txt", "iota-installer")]:
            (directory / "iota-contract" / destination).mkdir(exist_ok=True)
            (directory / "iota-contract" / name).rename(directory / "iota-contract" / destination / name)
        sign(directory, args.channel, tag, sequence)
        update_pointer(api, directory, args.channel, tag)
        return
    if not args.tag:
        parser.error("--tag is required")
    if args.command == "sign":
        sign(directory, args.channel, args.tag, sequence)
    elif args.command == "provenance":
        provenance(directory, args.channel, args.tag)
    elif args.command == "stage":
        stage(directory, args.channel, args.tag)
    elif args.command == "publish":
        publish(directory, args.channel, args.tag)


if __name__ == "__main__":
    main()
