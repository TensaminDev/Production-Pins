// Refresh shared sources, transformed locks, and fixed-output hashes.
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { copyTree, makeWritable, run } from "../lib/runtime.ts";

let noUpdate = false;
const overrides: string[] = [];
const args = Bun.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--no-update") noUpdate = true;
  else if (args[i] === "--override-input" && args[i + 1] && args[i + 2]) overrides.push(args[i], args[++i], args[++i]);
  else if (args[i] === "--help" || args[i] === "-h") {
    console.log("Usage: update-all [--no-update] [--override-input NAME SOURCE]...");
    process.exit(0);
  } else throw new Error(`Invalid argument: ${args[i]}`);
}
const root = process.cwd();
if (!existsSync(join(root, "packages/hashes.nix"))) throw new Error("Run update-all from the prod-pins checkout");
if (!noUpdate) run(["nix", "flake", "update", ...overrides], { stdio: "inherit" });
const system = run(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]);
function build(name: string) {
  return run(["nix", "build", `path:${root}#packages.${system}.${name}`, "--no-link", "--print-out-paths", ...overrides], { stdio: "pipe" });
}
const locks = join(root, "packages/locks");
mkdirSync(locks, { recursive: true });
const temporary = mkdtempSync(join(tmpdir(), "prod-pins-update-"));
try {
  for (const name of ["mtp", "iota", "omikron", "omega", "client"]) {
    const dest = join(temporary, name);
    copyTree(build(`${name}-source`), dest);
    makeWritable(dest);
    if (name === "client") {
      run(["pnpm", "install", "--lockfile-only", "--ignore-scripts", "--no-frozen-lockfile"], { cwd: dest, stdio: "inherit" });
      copyFileSync(join(dest, "pnpm-lock.yaml"), join(locks, "client.yaml"));
    } else {
      run(["cargo", "update", "--workspace"], { cwd: dest, stdio: "inherit" });
      copyFileSync(join(dest, "Cargo.lock"), join(locks, `${name}.lock`));
    }
  }
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
const hashFile = join(root, "packages/hashes.nix");
for (const [key, output] of ["mtp", "iota", "omikron", "omega"].map(name => [name, `${name}-vendor`]).concat([["sdk", "sdk-deps"], ["client", "client-deps"]])) {
  const original = readFileSync(hashFile, "utf8");
  const pattern = new RegExp(`(${key} = ")[^"]+`, "g");
  // Force a fetch even when the previous hash points at a cached result.
  const text = original.replace(pattern, `$1sha256-${"A".repeat(43)}=`);
  writeFileSync(hashFile, text);
  const result = spawnSync("nix", ["build", `path:${root}#packages.${system}.${output}`, "--no-link", "--print-out-paths", ...overrides], { encoding: "utf8" });
  const match = result.stderr?.match(/got:\s+(sha256-[A-Za-z0-9+/=]+)/);
  if (!match) {
    writeFileSync(hashFile, original);
    throw result.error ?? new Error(result.stderr || `Could not determine ${key} hash`);
  }
  writeFileSync(hashFile, text.replace(pattern, `$1${match[1]}`));
  build(output);
  console.log(`Updated ${key}: ${match[1]}`);
}
console.log("Updated sources, dependency locks, and verified vendor hashes.");
