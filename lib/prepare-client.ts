import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { walk } from "./runtime.ts";

const root = resolve(Bun.argv[2]);
const workspace = join(root, "pnpm-workspace.yaml");
writeFileSync(workspace, readFileSync(workspace, "utf8").replace(/^  mtp:.*\n/gm, ""));
for (const path of walk(root).filter(path => path.endsWith("/package.json"))) {
  if (relative(root, path).split("/").includes(".mtp-sdk")) continue;
  const data = JSON.parse(readFileSync(path, "utf8"));
  for (const section of ["dependencies", "devDependencies"]) {
    if (data[section] && Object.hasOwn(data[section], "mtp")) {
      data[section].mtp = "link:" + (relative(dirname(path), join(root, ".mtp-sdk")) || ".");
    }
  }
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
}
