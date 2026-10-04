"""Make every Rust consumer use the same local MTP and type maps."""

import os
import pathlib
import re
import shutil
import sys

import tomllib

project, source, mtp, maps, iota, destination = sys.argv[1:]
root = pathlib.Path(destination)
shutil.copytree(source, root, symlinks=True)
root.chmod(root.stat().st_mode | 0o200)

if project != "mtp":
    shutil.copytree(mtp, root / ".mtp", symlinks=True)
mtp_root = root if project == "mtp" else root / ".mtp"
crates = {}
for manifest in mtp_root.rglob("Cargo.toml"):
    data = tomllib.loads(manifest.read_text())
    if "name" in data.get("package", {}):
        crates[data["package"]["name"]] = manifest.parent

if project == "omega":
    shutil.copytree(pathlib.Path(iota) / "iota-identity", root / ".identity")
for path in [root, *root.rglob("*")]:
    if not path.is_symlink():
        path.chmod(path.stat().st_mode | 0o200)
if project == "omega":
    manifest = root / "Cargo.toml"
    manifest.write_text(manifest.read_text().replace('../iota/iota-identity', './.identity'))

for manifest in root.rglob("Cargo.toml"):
    text = manifest.read_text()
    # Preserve feature selections while replacing every independent git revision.
    def local_dependency(match, manifest=manifest):
        name, attributes = match.groups()
        path = pathlib.Path(os.path.relpath(crates[name], manifest.parent))
        attributes = re.sub(r'git\s*=\s*"[^"]+"\s*,?\s*', '', attributes)
        attributes = re.sub(r'(rev|branch|tag)\s*=\s*"[^"]+"\s*,?\s*', '', attributes)
        return f'{name} = {{ path = "{path}", {attributes}'

    text = re.sub(r'(mtp(?:-[\w-]+)?)\s*=\s*\{([^}]*git\s*=\s*"[^"]*[Mm]ethanium/mtp[^}]*)(?=\})', local_dependency, text)
    if manifest == root / "Cargo.toml" and project == "iota":
        text = text.replace('exclude = [', 'exclude = [".mtp", ')
    manifest.write_text(text)

maps_dir = root / "mtp-type-maps"
if maps_dir.is_symlink() or maps_dir.is_file():
    maps_dir.unlink()
elif maps_dir.exists():
    shutil.rmtree(maps_dir)
shutil.copytree(maps, maps_dir)

# Cargo reads only configuration from the invocation directory and its parents.
config = root / ".cargo" / "config.toml"
if config.exists():
    config.unlink()

if project == "iota":
    # Keep native executables usable before a system installation, without a
    # shell launcher or store paths in the portable release.
    paths = root / "iota-paths/src/lib.rs"
    text = paths.read_text()
    text = text.replace(
        'return Err(PathError::MissingRequiredOverride("IOTA_SOCKET"));',
        '''let home = absolute_env("HOME")?
                .ok_or(PathError::MissingPlatformDirectory("home directory"))?;
            let runtime = absolute_env("XDG_RUNTIME_DIR")?
                .unwrap_or(xdg_or_home("XDG_STATE_HOME", &home, ".local/state")?);
            return Ok(IpcEndpoint::UnixSocket(runtime.join("iota/iota.sock")));''',
    )
    for program in ["daemon", "updater"]:
        text = text.replace(
            f'.unwrap_or_else(|| install_root().join("current/bin/iota-{program}"))',
            f'''.unwrap_or_else(|| {{
            let sibling = env::current_exe().ok()
                .and_then(|path| path.parent().map(|parent| parent.join("iota-{program}")));
            sibling.filter(|path| path.is_file())
                .unwrap_or_else(|| install_root().join("current/bin/iota-{program}"))
        }})''',
        )
    text = text.replace(
        '.unwrap_or(defaults.asset_dir);',
        '''.unwrap_or_else(|| {
                env::current_exe().ok()
                    .and_then(|path| path.parent()?.parent().map(|parent| parent.join("share/iota/web")))
                    .filter(|path| path.is_dir())
                    .unwrap_or(defaults.asset_dir)
            });''',
    )
    paths.write_text(text)
    daemon = root / "iota-daemon/src/main.rs"
    daemon.write_text(daemon.read_text().replace(
        '    if !iota_terms::consent::load(&paths.state_dir).has_all_required() {',
        '''    if let Err(error) = paths.prepare_writable_directories() {
        eprintln!("Cannot prepare Iota directories: {error}");
        return ExitCode::FAILURE;
    }
    if !iota_terms::consent::load(&paths.state_dir).has_all_required() {''',
        1,
    ))

    # Ship and install every pinned static asset through the existing ZIP
    # contract, so the validator and installer agree about the payload.
    assets = sorted(path.relative_to(root).as_posix() for path in (root / "static/web").rglob("*") if path.is_file())
    contract = root / "iota-installer/bundle-files.txt"
    contract.write_text(contract.read_text().rstrip() + "\n" + "\n".join(assets) + "\n")
    installer = root / "iota-installer/src/lib.rs"
    text = installer.read_text().replace(
        '    for unit in [',
        '''    for name in REQUIRED.lines().filter(|name| name.starts_with("static/web/")) {
        install(
            &staging.path().join(name),
            &format!("/usr/local/share/iota/web/{}", &name["static/web/".len()..]),
            "0644",
        )?;
    }
    for unit in [''',
        1,
    )
    installer.write_text(text)

# Drop git identities for the crates now supplied through local paths. Cargo
# updates the dependency graph during update-all, never inside a sandboxed build.
lock = root / "Cargo.lock"
if lock.exists():
    text = lock.read_text()
    text = re.sub(r'(\[\[package\]\]\nname = "mtp[^\n]*\n.*?)(?=\n\[\[package\]\]|\Z)',
                  lambda m: re.sub(r'^source = .*\n|^checksum = .*\n', '', m[0], flags=re.MULTILINE), text, flags=re.DOTALL)
    text = re.sub(r'(mtp[\w-]* [\d.]+) \(git\+[^)]+\)', r'\1', text)
    lock.write_text(text)
