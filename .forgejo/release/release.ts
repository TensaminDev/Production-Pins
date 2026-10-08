// Forgejo release staging, provenance selection, signing and channel refresh.
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { parseArgs } from "node:util";
import { run } from "../../packages/runtime.ts";

type Asset = { id: number; name: string; browser_download_url: string };
type Release = { id: number; tag_name: string; draft: boolean; prerelease: boolean };
type Provenance = {
  schema: number; channel: string; tag: string; revision: string; run_id: string;
  lock_sha256: string; architectures: string[]; sources: Record<string, unknown>;
  artifacts: Record<string, { sha256: string; size: number }>;
};
function env(name: string) {
  const value = process.env[name];
  if (value === undefined) throw new Error(`Missing ${name}`);
  return value;
}
function readJSON(path: string) { return JSON.parse(readFileSync(path, "utf8")); }
function writeJSON(path: string, data: unknown) { writeFileSync(path, JSON.stringify(data, null, 2) + "\n"); }
function sha256(data: Uint8Array) { return createHash("sha256").update(data).digest("hex"); }
function files(directory: string) { return readdirSync(directory).sort().map(name => join(directory, name)).filter(path => statSync(path).isFile()); }
function matching(directory: string, pattern: RegExp) { return readdirSync(directory).filter(name => pattern.test(name)).map(name => join(directory, name)); }

class HTTPError extends Error {
  constructor(public status: number, url: string) { super(`HTTP ${status}: ${url}`); }
}
class Forgejo {
  server = env("FORGEJO_SERVER_URL").replace(/\/+$/, "");
  repo = env("FORGEJO_REPOSITORY");
  base = `${this.server}/api/v1/repos/${this.repo}`;
  token = env("RELEASE_TOKEN");

  async request(path: string, method = "GET", data?: unknown, contentType = "application/json", raw = false): Promise<any> {
    let url = path.startsWith("https://") ? path : this.base + path;
    if (new URL(url).host !== new URL(this.server).host) throw new Error("Unexpected asset host");
    let body = data === undefined ? undefined : data instanceof Uint8Array ? data : JSON.stringify(data);
    const signal = AbortSignal.timeout(120_000);
    // Handle redirects explicitly so the token never reaches a different host.
    for (let redirects = 0; redirects <= 10; redirects++) {
      const response = await fetch(url, { method, body, headers: { Authorization: `token ${this.token}`, "Content-Type": contentType }, redirect: "manual", signal });
      if ([301, 302, 303, 307, 308].includes(response.status) && response.headers.has("location")) {
        const next = new URL(response.headers.get("location")!, url);
        if (next.host !== new URL(url).host) throw new Error("Refusing authenticated cross-host redirect");
        if (method !== "GET" && method !== "HEAD") {
          if (![301, 302, 303].includes(response.status) || method !== "POST") throw new HTTPError(response.status, url);
          method = "GET";
          body = undefined;
        }
        await response.body?.cancel();
        url = next.href;
        continue;
      }
      if (!response.ok) throw new HTTPError(response.status, url);
      const bytes = Buffer.from(await response.arrayBuffer());
      return bytes.length && !raw && response.headers.get("content-type")?.includes("json") ? JSON.parse(bytes.toString()) : bytes;
    }
    throw new Error("Too many redirects");
  }
  async release(tag: string, missing = false): Promise<Release | null> {
    try { return await this.request("/releases/tags/" + encodeURIComponent(tag)); }
    catch (error) {
      if (missing && error instanceof HTTPError && error.status === 404) return null;
      throw error;
    }
  }
  async assets(release: Release): Promise<Asset[]> {
    const result: Asset[] = [];
    for (let page = 1; page < 100; page++) {
      const batch = await this.request(`/releases/${release.id}/assets?limit=50&page=${page}`) as Asset[];
      result.push(...batch);
      if (batch.length < 50) return result;
    }
    throw new Error("Too many release assets");
  }
  async download(release: Release, name: string): Promise<Buffer> {
    const asset = (await this.assets(release)).find(asset => asset.name === name);
    if (!asset) throw new Error(`Missing release asset: ${name}`);
    return this.request(asset.browser_download_url, "GET", undefined, "application/json", true);
  }
  async upload(release: Release, path: string) {
    const boundary = "tensamin-" + randomBytes(16).toString("hex");
    const body = Buffer.concat([
      Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="attachment"; filename="${basename(path)}"\r\nContent-Type: application/octet-stream\r\n\r\n`),
      readFileSync(path), Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    return this.request(`/releases/${release.id}/assets?name=${encodeURIComponent(basename(path))}`, "POST", body, "multipart/form-data; boundary=" + boundary);
  }
}

function provenance(directory: string, channel: string, tag: string) {
  const lock = readJSON("flake.lock");
  const sources = Object.fromEntries(Object.entries(lock.nodes.root.inputs).filter(([, node]) => typeof node === "string").map(([name, node]) => [name, lock.nodes[node as string].locked]));
  const artifacts = Object.fromEntries(files(directory).filter(path => !["release.json", "SHA256SUMS"].includes(basename(path))).map(path => [basename(path), { sha256: sha256(readFileSync(path)), size: statSync(path).size }]));
  writeJSON(join(directory, "release.json"), {
    schema: 1, channel, tag, revision: run(["git", "rev-parse", "HEAD"]), run_id: env("FORGEJO_RUN_ID"), sources,
    lock_sha256: sha256(readFileSync("flake.lock")),
    architectures: ["x86_64", "aarch64"].filter(arch => existsSync(join(directory, `iota-linux-${arch}`))), artifacts,
  });
  writeFileSync(join(directory, "SHA256SUMS"), files(directory).filter(path => basename(path) !== "SHA256SUMS").map(path => `${sha256(readFileSync(path))}  ${basename(path)}\n`).join(""));
}

async function sign(directory: string, channel: string, tag: string, sequence: number) {
  const api = new Forgejo();
  const old = await api.release(channel, true);
  if (old) {
    for (const asset of await api.assets(old)) {
      if (/^iota-update-linux-(x86_64|aarch64)\.json$(?!\n)/.test(asset.name)) {
        const manifest = JSON.parse((await api.download(old, asset.name)).toString());
        if (sequence <= manifest.release_sequence) throw new Error("Channel sequence must strictly increase");
      }
    }
  }
  const lock = readJSON("flake.lock");
  process.env.IOTA_RELEASE_SOURCE_SHA = lock.nodes[lock.nodes.root.inputs.iota].locked.rev;
  const now = Date.now();
  const published = new Date(now).toISOString().replace(/\.\d{3}Z$/, "Z");
  const expires = new Date(now + 14 * 86400_000).toISOString().replace(/\.\d{3}Z$/, "Z");
  const host = run(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]).replace(/-linux$/, "");
  const signer = join(directory, `iota-release-linux-${host}`);
  const verifier = join(directory, `iota-bundle-linux-${host}`);
  chmodSync(signer, 0o755);
  chmodSync(verifier, 0o755);
  const base = `${api.server}/${api.repo}/releases/download/${tag}`;
  const contract = join(directory, "iota-contract/scripts");
  for (const arch of ["x86_64", "aarch64"]) {
    if (!existsSync(join(directory, `iota-linux-${arch}`))) continue;
    const binaries = join(directory, `bin-${arch}`);
    mkdirSync(binaries, { recursive: true });
    for (const binary of ["iota", "iota-daemon", "iota-updater"]) {
      const target = join(binaries, binary);
      copyFileSync(join(directory, `${binary}-linux-${arch}`), target);
      chmodSync(target, 0o755);
    }
    const manifest = join(directory, `iota-update-linux-${arch}.json`);
    run(["bash", join(contract, "build-update-manifest.sh"), binaries, env("IOTA_BASE_VERSION"), channel, String(sequence), published, expires, "linux", arch, base, manifest]);
    const publicKey = run([signer, "sign", manifest, manifest + ".sig"]);
    if (publicKey !== env("IOTA_RELEASE_PUBLIC_KEY")) throw new Error("Release signing key does not match the pinned public key");
    const url = `${api.server}/${api.repo}/releases/download/${channel}/${basename(manifest)}`;
    const bundle = join(directory, `iota-linux-${arch}.zip`);
    rmSync(bundle, { force: true });
    run(["bash", join(contract, "build-release-bundle.sh"), binaries, readJSON(manifest).product_version, manifest, url, publicKey, url + ".sig", channel, process.env.IOTA_RELEASE_SIGNING_KEY_ID ?? "primary", bundle]);
    run([verifier, bundle]);
  }
}

async function stage(directory: string, channel: string, tag: string) {
  const api = new Forgejo();
  if (await api.release(tag, true)) throw new Error("Immutable release tag already exists");
  const release = await api.request("/releases", "POST", {
    tag_name: tag, target_commitish: run(["git", "rev-parse", "HEAD"]), name: tag,
    body: "Verified central source build. See release.json for provenance.", draft: true, prerelease: channel === "canary",
  });
  for (const path of files(directory)) await api.upload(release, path);
  // Validate staged attachment bytes before deployment or visibility changes.
  for (const path of files(directory)) {
    if (sha256(await api.download(release, basename(path))) !== sha256(readFileSync(path))) throw new Error(`Staged asset mismatch: ${basename(path)}`);
  }
  writeJSON(join(directory, "stage.json"), { id: release.id, tag });
}

async function publish(directory: string, channel: string, tag: string) {
  const api = new Forgejo();
  const immutable = (await api.release(tag))!;
  if (!immutable.draft) throw new Error("Expected a staged draft");
  const registry = new URL(api.server).host;
  const auth = join(directory, ".registry-auth.json");
  try {
    run(["skopeo", "login", "--authfile", auth, "--username", env("FORGEJO_REGISTRY_USER"), "--password-stdin", registry], { input: api.token });
    for (const image of matching(directory, /-image-linux-.*\.tar\.gz$/)) {
      const [service, suffix] = basename(image).split("-image-linux-");
      const arch = suffix.replace(/\.tar\.gz$/, "");
      run(["skopeo", "--policy", env("CONTAINERS_POLICY"), "copy", "--authfile", auth, "docker-archive:" + image, `docker://${registry}/${api.repo.split("/")[0]}/${service}:${tag}-${arch}`]);
    }
    await api.request(`/releases/${immutable.id}`, "PATCH", { draft: false });
    try { await updatePointer(api, directory, channel, tag); }
    catch (error) {
      await api.request(`/releases/${immutable.id}`, "PATCH", { draft: true });
      throw error;
    }
  } finally { rmSync(auth, { force: true }); }
}

async function updatePointer(api: Forgejo, directory: string, channel: string, tag: string) {
  let pointer = await api.release(channel, true);
  const isNew = pointer === null;
  if (!pointer) pointer = await api.request("/releases", "POST", {
    tag_name: channel, target_commitish: run(["git", "rev-parse", "HEAD"]), name: channel, draft: true, prerelease: channel === "canary",
  });
  const release = pointer!;
  const backup: [string, Buffer][] = [];
  const names = new Set(matching(directory, /^iota-update-linux-.*\.json.*$/).map(path => basename(path)));
  names.add("channel.json");
  names.add("electron-release-metadata.json");
  // A refresh never moves binaries or changes the immutable release identity.
  writeJSON(join(directory, "channel.json"), { channel, tag, url: `${api.server}/${api.repo}/releases/tag/${tag}` });
  const electron = matching(directory, /^electron-release-metadata-.*\.json$/).map(readJSON);
  if (electron.length) {
    const combined = electron[0];
    combined.artifacts = electron.flatMap(entry => entry.artifacts);
    writeJSON(join(directory, "electron-release-metadata.json"), combined);
  } else names.delete("electron-release-metadata.json");
  const oldAssets = await api.assets(release);
  for (const asset of oldAssets) if (asset.name.startsWith("iota-update-linux-")) names.add(asset.name);
  try {
    for (const asset of oldAssets) {
      if (names.has(asset.name)) {
        backup.push([asset.name, await api.download(release, asset.name)]);
        await api.request(`/releases/${release.id}/assets/${asset.id}`, "DELETE");
      }
    }
    for (const name of [...names].sort()) {
      const path = join(directory, name);
      if (existsSync(path)) await api.upload(release, path);
    }
    await api.request(`/releases/${release.id}`, "PATCH", { draft: false, body: `Current ${channel} build: ${tag}. Signed metadata refreshed automatically.` });
  } catch (error) {
    for (const asset of await api.assets(release)) {
      if (names.has(asset.name)) await api.request(`/releases/${release.id}/assets/${asset.id}`, "DELETE");
    }
    for (const [name, raw] of backup) {
      const path = join(directory, name);
      writeFileSync(path, raw);
      await api.upload(release, path);
    }
    if (isNew) await api.request(`/releases/${release.id}`, "DELETE");
    throw error;
  }
}

async function select(tag?: string) {
  const api = new Forgejo();
  if (!tag) {
    const revision = run(["git", "rev-parse", "HEAD"]);
    const candidates: string[] = [];
    for (let page = 1; page < 100; page++) {
      const releases = await api.request(`/releases?limit=50&page=${page}`) as Release[];
      candidates.push(...releases.filter(release => !release.draft && release.prerelease && new RegExp(`^canary-${revision}-[0-9]+$(?!\\n)`).test(release.tag_name)).map(release => release.tag_name));
      if (releases.length < 50) break;
    }
    if (!candidates.length) throw new Error(`Commit ${revision} has no published canary. Wait for its canary workflow to succeed before starting stable.`);
    tag = candidates.reduce((best, candidate) => BigInt(candidate.split("-").at(-1)!) > BigInt(best.split("-").at(-1)!) ? candidate : best);
  }
  if (!/^canary-[0-9a-f]{40}-[0-9]+$(?!\n)/.test(tag)) throw new Error("Select an immutable canary tag");
  const release = (await api.release(tag))!;
  const data = JSON.parse((await api.download(release, "release.json")).toString()) as Provenance;
  if (release.draft || !release.prerelease || data.channel !== "canary" || data.tag !== tag) throw new Error("Not a published canary");
  let result = await api.request(`/actions/runs/${data.run_id}`);
  result = Object.hasOwn(result, "workflow_run") ? result.workflow_run : result;
  const conclusion = Object.hasOwn(result, "conclusion") ? result.conclusion : result.status;
  const head = Object.hasOwn(result, "head_sha") ? result.head_sha : result.commit_sha;
  if (conclusion !== "success" || head !== data.revision) throw new Error("Canary workflow has not completed successfully");
  if (!/^[0-9a-f]{40}$(?!\n)/.test(data.revision)) throw new Error("Invalid source revision");
  run(["git", "fetch", "origin", data.revision]);
  run(["git", "checkout", "--detach", data.revision]);
  if (sha256(readFileSync("flake.lock")) !== data.lock_sha256) throw new Error("Canary lock provenance mismatch");
  writeFileSync(".release-selection.json", JSON.stringify(data));
}

async function main() {
  const { values, positionals } = parseArgs({ args: Bun.argv.slice(2), allowPositionals: true, options: {
    directory: { type: "string", default: "release-out" }, channel: { type: "string", default: "canary" }, tag: { type: "string" }, help: { type: "boolean", short: "h" },
  } });
  if (values.help) { console.log("Usage: release.ts select|sign|stage|publish|refresh|provenance [--directory PATH] [--channel stable|canary] [--tag TAG]"); return; }
  const [command] = positionals;
  if (positionals.length !== 1 || !["select", "sign", "stage", "publish", "refresh", "provenance"].includes(command)) throw new Error("Invalid release command");
  const channel = values.channel!;
  if (!["stable", "canary"].includes(channel)) throw new Error("Invalid channel");
  const directory = resolve(values.directory!);
  if (command === "select") { await select(values.tag); return; }
  const sequenceText = process.env.RELEASE_SEQUENCE ?? String(Math.floor(Date.now() / 1000));
  const sequence = Number(sequenceText);
  if (!/^\s*\+?\d+\s*$/.test(sequenceText) || !Number.isInteger(sequence) || sequence <= 0 || sequence > 2100000000) throw new Error("Sequence exceeds Android version-code range");
  if (command === "refresh") {
    const api = new Forgejo();
    const pointer = await api.release(channel, true);
    if (!pointer) return;
    const tag = JSON.parse((await api.download(pointer, "channel.json")).toString()).tag;
    const release = (await api.release(tag))!;
    mkdirSync(directory, { recursive: true });
    const data = JSON.parse((await api.download(release, "release.json")).toString()) as Provenance;
    run(["git", "fetch", "origin", data.revision]);
    run(["git", "checkout", "--detach", data.revision]);
    if (sha256(readFileSync("flake.lock")) !== data.lock_sha256) throw new Error("Refresh lock provenance mismatch");
    for (const asset of await api.assets(release)) {
      if (basename(join(directory, asset.name)) !== asset.name) throw new Error("Unsafe asset name");
      writeFileSync(join(directory, asset.name), await api.download(release, asset.name));
    }
    for (const [name, expected] of Object.entries(data.artifacts)) {
      if (sha256(readFileSync(join(directory, name))) !== expected.sha256) throw new Error(`Immutable asset mismatch: ${name}`);
    }
    const host = run(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]).replace(/-linux$/, "");
    // Restore the exact Nix helper closure, checking both pipeline processes.
    run(["bash", "-o", "pipefail", "-c", 'gzip -dc "$1" | nix-store --import', "release-refresh", join(directory, `iota-linux-${host}.nar.gz`)], { stdio: "inherit" });
    const bundle = run(["nix", "build", "--no-link", "--print-out-paths", ".#iota-bundle"]);
    run(["cp", "-rL", bundle + "/share/iota", join(directory, "iota-contract")]);
    mkdirSync(join(directory, "iota-contract/static"), { recursive: true });
    renameSync(join(directory, "iota-contract/static-web"), join(directory, "iota-contract/static/web"));
    for (const [name, destination] of [["artifacts.tsv", "iota-updater"], ["bundle-files.txt", "iota-installer"]]) {
      mkdirSync(join(directory, "iota-contract", destination), { recursive: true });
      renameSync(join(directory, "iota-contract", name), join(directory, "iota-contract", destination, name));
    }
    await sign(directory, channel, tag, sequence);
    await updatePointer(api, directory, channel, tag);
    return;
  }
  if (!values.tag) throw new Error("--tag is required");
  if (command === "sign") await sign(directory, channel, values.tag, sequence);
  else if (command === "provenance") provenance(directory, channel, values.tag);
  else if (command === "stage") await stage(directory, channel, values.tag);
  else if (command === "publish") await publish(directory, channel, values.tag);
}

await main();
