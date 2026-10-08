import { chmodSync, cpSync, lstatSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { spawnSync, type SpawnSyncOptionsWithStringEncoding } from "node:child_process";

export function run(args: string[], options: Omit<SpawnSyncOptionsWithStringEncoding, "encoding"> = {}) {
  const result = spawnSync(args[0], args.slice(1), { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"], ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || `${args[0]} failed: ${result.signal ?? result.status}`);
  return result.stdout?.trim() ?? "";
}

// Like pathlib.rglob, do not descend into symlinked directories.
export function walk(root: string): string[] {
  return readdirSync(root).flatMap(name => {
    const path = join(root, name);
    return [path, ...(lstatSync(path).isDirectory() ? walk(path) : [])];
  });
}

export function copyTree(source: string, destination: string, symlinks = true) {
  cpSync(source, destination, { recursive: true, dereference: !symlinks, verbatimSymlinks: symlinks, errorOnExist: true, force: false });
}

export function makeWritable(root: string) {
  for (const path of [root, ...walk(root)]) {
    if (!lstatSync(path).isSymbolicLink()) chmodSync(path, statSync(path).mode | 0o200);
  }
}
