import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

const [source, destination] = Bun.argv.slice(2);
const settings = Bun.YAML.parse(readFileSync(source, "utf8")) || {};
if (existsSync(destination)) {
  const previous = Bun.YAML.parse(readFileSync(destination, "utf8")) || {};
  // Retain discovery state unless the operator explicitly supplies it.
  for (const field of ["iota_id", "omikron_host", "omikron_port", "omikron_id"]) {
    if (!Object.hasOwn(settings, field) && Object.hasOwn(previous, field)) settings[field] = previous[field];
  }
}
const temporary = destination + ".new";
writeFileSync(temporary, Bun.YAML.stringify(settings));
chmodSync(temporary, 0o640);
renameSync(temporary, destination);
