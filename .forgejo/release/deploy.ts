// Commit only the infrastructure pin, deploy that commit, revert on failure.
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { run } from "../../packages/runtime.ts";

function env(name: string) {
  const value = process.env[name];
  if (value === undefined) throw new Error(`Missing ${name}`);
  return value;
}
const revision = run(["git", "rev-parse", "HEAD"]);
const channel = env("RELEASE_CHANNEL");
if (channel !== "stable" && channel !== "canary") throw new Error("Invalid deployment channel");
const deployment = channel === "canary" ? "CANARY" : "PROD";
const input = channel === "canary" ? "canary-pins" : "prod-pins";
const repository = env("NIXOS_FLAKE_REPOSITORY");
const branch = process.env.NIXOS_FLAKE_BRANCH ?? "main";
const server = env("FORGEJO_SERVER_URL").replace(/\/+$/, "");
if (!/^[\w.-]+\/[\w.-]+$(?!\n)/.test(repository)) throw new Error("Invalid infrastructure repository");
const root = mkdtempSync(join(tmpdir(), "tensamin-deploy-"));
try {
  const askpass = join(root, "askpass");
  writeFileSync(askpass, '#!/bin/sh\ncase "$1" in *Username*) printf "%s\\n" token;; *) printf "%s\\n" "$NIXOS_FLAKE_WRITE_TOKEN";; esac\n');
  chmodSync(askpass, 0o700);
  const gitEnv = { ...process.env, GIT_ASKPASS: askpass, GIT_TERMINAL_PROMPT: "0" };
  const checkout = join(root, "infrastructure");
  run(["git", "clone", "--branch", branch, "--single-branch", `${server}/${repository}.git`, checkout], { env: gitEnv });
  const original = run(["git", "rev-parse", "HEAD"], { cwd: checkout });
  const wrapper = readFileSync(join(checkout, "vm/tensamin-prod/services/deploy.nix"), "utf8");
  if (!wrapper.includes("<nixos-flake commit SHA>")) throw new Error("Deployment wrapper must accept <nixos-flake commit SHA> before promotion");
  const url = `git+ssh://git@methanium.net/${env("FORGEJO_REPOSITORY")}?ref=main&rev=${revision}`;
  run(["nix", "flake", "lock", "--override-input", input, url], { cwd: checkout });
  const lock = JSON.parse(readFileSync(join(checkout, "flake.lock"), "utf8"));
  if (lock.nodes[lock.nodes.root.inputs[input]].locked.rev !== revision) throw new Error("Infrastructure pin mismatch");
  run(["git", "add", "flake.lock"], { cwd: checkout });
  const identity = ["git", "-c", "user.name=Tensamin releases", "-c", "user.email=releases@tensamin.net"];
  const changed = spawnSync("git", ["diff", "--cached", "--quiet"], { cwd: checkout }).status;
  if (changed !== 0 && changed !== 1) throw new Error("Unable to inspect infrastructure pin changes");
  if (changed) run([...identity, "commit", "-m", `tensamin-${channel === "stable" ? "prod" : "canary"}: pin ${revision}`], { cwd: checkout });
  const commit = run(["git", "rev-parse", "HEAD"], { cwd: checkout });
  const key = join(root, "deploy-key");
  writeFileSync(key, env(`TENSAMIN_${deployment}_DEPLOY_SSH_KEY`) + "\n");
  chmodSync(key, 0o600);
  const known = join(root, "known_hosts");
  writeFileSync(known, env("TENSAMIN_SSH_KNOWN_HOSTS") + "\n");
  const config = join(root, "ssh_config");
  const host = env(`TENSAMIN_${deployment}_DEPLOY_HOST`);
  const port = process.env[`TENSAMIN_${deployment}_DEPLOY_PORT`] ?? "22";
  const jumpHost = process.env[`TENSAMIN_${deployment}_DEPLOY_JUMP_HOST`] ?? "";
  const jumpPort = process.env[`TENSAMIN_${deployment}_DEPLOY_JUMP_PORT`] ?? "7930";
  const jumpUser = channel === "canary" ? "deploy-canary-jump" : "deploy-jump";
  for (const hostname of [host, jumpHost]) if (hostname && !/^[A-Za-z0-9_.:-]+$(?!\n)/.test(hostname)) throw new Error("Invalid deployment SSH hostname");
  for (const value of [port, jumpPort]) if (!/^\d+$(?!\n)/.test(value) || Number(value) < 1 || Number(value) > 65535) throw new Error("Invalid deployment SSH port");
  writeFileSync(config,
    `Host tensamin-deploy\n  HostName ${host}\n  Port ${port}\n  User deploy\n`
    + (jumpHost ? "  ProxyJump tensamin-deploy-jump\n" : "")
    + (jumpHost ? `Host tensamin-deploy-jump\n  HostName ${jumpHost}\n  Port ${jumpPort}\n  User ${jumpUser}\n` : "")
    + `Host *\n  IdentityFile "${key}"\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile "${known}"\n  BatchMode yes\n  ConnectTimeout 15\n`);
  const ssh = ["ssh", "-F", config, "-T", "tensamin-deploy"];
  run(["ssh", "-G", "-F", config, "tensamin-deploy"]);
  if (changed) run(["git", "push", "origin", `HEAD:refs/heads/${branch}`], { cwd: checkout, env: gitEnv });
  // Await transactional commands so interruption can enter the rollback path.
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  async function transaction(args: string[]) {
    await new Promise<void>((resolve, reject) => {
      const child = spawn(args[0], args.slice(1), { stdio: "inherit", signal: controller.signal });
      let failure: Error | undefined;
      child.on("error", error => { failure = error; });
      child.on("close", (code, signal) => {
        if (failure) reject(failure);
        else if (code !== 0) reject(new Error(`${args[0]} failed: ${signal ?? code}`));
        else resolve();
      });
    });
  }
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", interrupt);
  try {
    await transaction([...ssh, commit]);
    // Publication is inside the transaction, so failure restores the pin.
    await transaction([process.execPath, ".forgejo/release/release.ts", "publish", "--channel", channel, "--tag", env("RELEASE_TAG")]);
  } catch (error) {
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", interrupt);
    if (!changed) throw error;
    // A normal revert preserves unrelated concurrent infrastructure commits.
    run(["git", "fetch", "origin", branch], { cwd: checkout, env: gitEnv });
    run(["git", "reset", "--hard", `origin/${branch}`], { cwd: checkout });
    run([...identity, "revert", "--no-edit", commit], { cwd: checkout });
    run(["git", "push", "origin", `HEAD:refs/heads/${branch}`], { cwd: checkout, env: gitEnv });
    const rollback = run(["git", "rev-parse", "HEAD"], { cwd: checkout });
    run([...ssh, rollback], { stdio: "inherit" });
    throw error;
  } finally {
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", interrupt);
  }
  writeFileSync("release-out/deployment.json", JSON.stringify({ previous_infrastructure: original, infrastructure: commit, prod_pins: revision }, null, 2) + "\n");
} finally { rmSync(root, { recursive: true, force: true }); }
