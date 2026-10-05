// Make every Rust consumer use the same local MTP and type maps.
import { chmodSync, existsSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
import { copyTree, makeWritable, walk } from "./runtime.ts";

const [project, source, mtp, maps, iota, destination] = Bun.argv.slice(2);
if (Bun.argv.length !== 8) throw new Error("Expected PROJECT SOURCE MTP MAPS IOTA DESTINATION");
const root = resolve(destination);
copyTree(source, root);
chmodSync(root, statSync(root).mode | 0o200);
if (project !== "mtp") copyTree(mtp, join(root, ".mtp"));
const mtpRoot = project === "mtp" ? root : join(root, ".mtp");
const crates = new Map<string, string>();
for (const manifest of walk(mtpRoot).filter(path => path.endsWith("/Cargo.toml"))) {
  const data = Bun.TOML.parse(readFileSync(manifest, "utf8")) as { package?: { name?: string } };
  if (data.package?.name) crates.set(data.package.name, dirname(manifest));
}
if (project === "omega") copyTree(join(iota, "iota-identity"), join(root, ".identity"), false);
makeWritable(root);
if (project === "omega") {
  const manifest = join(root, "Cargo.toml");
  writeFileSync(manifest, readFileSync(manifest, "utf8").replaceAll("../iota/iota-identity", "./.identity"));
}
for (const manifest of walk(root).filter(path => path.endsWith("/Cargo.toml"))) {
  let text = readFileSync(manifest, "utf8");
  // Preserve feature selections while replacing every independent git revision.
  text = text.replace(/(mtp(?:-[\w-]+)?)\s*=\s*\{([^}]*git\s*=\s*"[^"]*[Mm]ethanium\/mtp[^}]*)(?=\})/g,
    (_, name: string, attributes: string) => {
      const crate = crates.get(name);
      if (!crate) throw new Error(`Unknown MTP crate: ${name}`);
      const path = relative(dirname(manifest), crate) || ".";
      attributes = attributes.replace(/git\s*=\s*"[^"]+"\s*,?\s*/g, "")
        .replace(/(rev|branch|tag)\s*=\s*"[^"]+"\s*,?\s*/g, "");
      return `${name} = { path = "${path}", ${attributes}`;
    });
  if (manifest === join(root, "Cargo.toml") && project === "iota") text = text.replaceAll("exclude = [", 'exclude = [".mtp", ');
  writeFileSync(manifest, text);
}
const mapsDir = join(root, "mtp-type-maps");
rmSync(mapsDir, { recursive: true, force: true });
copyTree(maps, mapsDir, false);
rmSync(join(root, ".cargo/config.toml"), { force: true });

if (project === "iota") {
  // Keep native executables usable before installation without store paths.
  const paths = join(root, "iota-paths/src/lib.rs");
  let text = readFileSync(paths, "utf8").replaceAll(
    'return Err(PathError::MissingRequiredOverride("IOTA_SOCKET"));',
    `let home = absolute_env("HOME")?
                .ok_or(PathError::MissingPlatformDirectory("home directory"))?;
            let runtime = absolute_env("XDG_RUNTIME_DIR")?
                .unwrap_or(xdg_or_home("XDG_STATE_HOME", &home, ".local/state")?);
            return Ok(IpcEndpoint::UnixSocket(runtime.join("iota/iota.sock")));`);
  for (const program of ["daemon", "updater"]) {
    text = text.replaceAll(`.unwrap_or_else(|| install_root().join("current/bin/iota-${program}"))`,
      `.unwrap_or_else(|| {
            let sibling = env::current_exe().ok()
                .and_then(|path| path.parent().map(|parent| parent.join("iota-${program}")));
            sibling.filter(|path| path.is_file())
                .unwrap_or_else(|| install_root().join("current/bin/iota-${program}"))
        })`);
  }
  text = text.replaceAll(".unwrap_or(defaults.asset_dir);", `.unwrap_or_else(|| {
                env::current_exe().ok()
                    .and_then(|path| path.parent()?.parent().map(|parent| parent.join("share/iota/web")))
                    .filter(|path| path.is_dir())
                    .unwrap_or(defaults.asset_dir)
            });`);
  writeFileSync(paths, text);
  const daemon = join(root, "iota-daemon/src/main.rs");
  writeFileSync(daemon, readFileSync(daemon, "utf8").replace(
    "    if !iota_terms::consent::load(&paths.state_dir).has_all_required() {",
    `    if let Err(error) = paths.prepare_writable_directories() {
        eprintln!("Cannot prepare Iota directories: {error}");
        return ExitCode::FAILURE;
    }
    if !iota_terms::consent::load(&paths.state_dir).has_all_required() {`));
  // The installer and bundle validator share this exact static asset contract.
  const assets = walk(join(root, "static/web")).filter(path => statSync(path).isFile()).map(path => relative(root, path)).sort();
  const contract = join(root, "iota-installer/bundle-files.txt");
  writeFileSync(contract, readFileSync(contract, "utf8").trimEnd() + "\n" + assets.join("\n") + "\n");
  const installer = join(root, "iota-installer/src/lib.rs");
  writeFileSync(installer, readFileSync(installer, "utf8").replace("    for unit in [", `    for name in REQUIRED.lines().filter(|name| name.starts_with("static/web/")) {
        install(
            &staging.path().join(name),
            &format!("/usr/local/share/iota/web/{}", &name["static/web/".len()..]),
            "0644",
        )?;
    }
    for unit in [`));
}

// Cargo updates this dependency graph during update-all, never in a sandbox.
const lock = join(root, "Cargo.lock");
if (existsSync(lock)) {
  let text = readFileSync(lock, "utf8");
  text = text.replace(/(\[\[package\]\]\nname = "mtp[^\n]*\n.*?)(?=\n\[\[package\]\]|$)/gs,
    block => block.replace(/^source = .*\n|^checksum = .*\n/gm, ""));
  text = text.replace(/(mtp[\w-]* [\d.]+) \(git\+[^)]+\)/g, "$1");
  writeFileSync(lock, text);
}
