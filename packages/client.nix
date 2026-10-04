{ pkgs, rust, rustPlatform, inputs, hashes, mtpSource, mtpVendor }:
let
  inherit (pkgs) lib;
  pnpm = pkgs.pnpm;
  sdk-deps = pkgs.fetchPnpmDeps {
    pname = "mtp-sdk";
    version = "0.4.0";
    src = inputs.mtp;
    inherit pnpm;
    fetcherVersion = 4;
    hash = hashes.sdk;
  };
  wasmVersion = (lib.findFirst (p: p.name == "wasm-bindgen") (throw "Missing wasm-bindgen")
    (builtins.fromTOML (builtins.readFile (inputs.mtp + "/Cargo.lock"))).package).version;
  wasmBindgen = pkgs.${"wasm-bindgen-cli_" + builtins.replaceStrings [ "." ] [ "_" ] wasmVersion};
  mtp-sdk = pkgs.stdenv.mkDerivation {
    pname = "mtp-sdk";
    version = "0.4.0";
    src = mtpSource;
    pnpmDeps = sdk-deps;
    cargoDeps = mtpVendor;
    nativeBuildInputs = [ rust pkgs.nodejs pnpm pkgs.pnpmConfigHook rustPlatform.cargoSetupHook wasmBindgen pkgs.lld ];
    MTP_TYPE_MAPS = "${inputs.mtp-type-maps}/type-maps.yaml";
    RUSTFLAGS = "--cfg=web_sys_unstable_apis";
    buildPhase = ''
      runHook preBuild
      cargo build --locked --offline --release -p mtp-wasm --target wasm32-unknown-unknown
      mkdir -p sdk/bindings/wasm/pkg
      wasm-bindgen target/wasm32-unknown-unknown/release/mtp_wasm.wasm \
        --target web --out-dir sdk/bindings/wasm/pkg --out-name mtp_wasm
      pnpm --dir sdk run build:ts
      # The Nix SDK already contains WASM compiled with the authoritative maps.
      # Keep the plugin's YAML generation and aliases, but reuse that build.
      substituteInPlace sdk/dist/vite/index.js \
        --replace-fail 'await runWasmPack(state);' \
        'await fs.cp(path.join(packageRoot, "bindings/wasm/pkg"), state.outDir, { recursive: true });'
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -r sdk/dist sdk/bindings sdk/type-map sdk/package.json "$out/"
      mkdir -p "$out/node_modules"
      cp -rL sdk/node_modules/yaml "$out/node_modules/"
    '';
    passthru.source = inputs.mtp;
  };
  client-source = pkgs.runCommand "client-source" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${inputs.client} "$out"
    chmod -R u+w "$out"
    rm -rf "$out/mtp-type-maps"
    cp -r ${inputs.mtp-type-maps} "$out/mtp-type-maps"
    mkdir -p "$out/.mtp-sdk"
    cp ${inputs.mtp}/sdk/package.json "$out/.mtp-sdk/package.json"
    python - "$out" <<'PY'
    import json, sys, os, re
    from pathlib import Path
    root = Path(sys.argv[1])
    workspace = root / 'pnpm-workspace.yaml'
    workspace.write_text(re.sub(r'^  mtp:.*\n', "", workspace.read_text(), flags=re.M))
    for path in root.rglob('package.json'):
        if '.mtp-sdk' in path.parts:
            continue
        data = json.loads(path.read_text())
        for section in ['dependencies', 'devDependencies']:
            if 'mtp' in data.get(section, {}):
                data[section]['mtp'] = 'link:' + os.path.relpath(root / '.mtp-sdk', path.parent)
        path.write_text(json.dumps(data, indent=2) + '\n')
    PY
    ${lib.optionalString (builtins.pathExists ./locks/client.yaml) ''cp ${./locks/client.yaml} "$out/pnpm-lock.yaml"''}
  '';
  client-deps = pkgs.fetchPnpmDeps {
    pname = "tensamin";
    version = "0.0.11";
    src = client-source;
    inherit pnpm;
    fetcherVersion = 4;
    hash = hashes.client;
  };
  common = {
    version = "0.0.11";
    src = client-source;
    pnpmDeps = client-deps;
    nativeBuildInputs = [ pkgs.nodejs pnpm pkgs.pnpmConfigHook pkgs.makeWrapper ];
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    postPatch = ''
      rm -rf .mtp-sdk
      cp -r ${mtp-sdk} .mtp-sdk
      chmod -R u+w .mtp-sdk
    '';
    passthru = { source = inputs.client; inherit mtp-sdk; };
    meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
  client-web = pkgs.stdenv.mkDerivation (common // {
    pname = "tensamin-web";
    buildPhase = ''
      runHook preBuild
      pnpm run build:web
      runHook postBuild
    '';
    installPhase = ''mkdir -p "$out"; cp -r apps/web/dist/. "$out/"'';
  });
  client = pkgs.stdenv.mkDerivation (common // {
    pname = "tensamin";
    buildPhase = ''
      runHook preBuild
      TENSAMIN_WEB_BASE=./ pnpm run build:web
      pnpm --dir apps/electron run build
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p "$out/lib/tensamin" "$out/bin"
      cp -r apps/electron/dist "$out/lib/tensamin/"
      cp apps/electron/package.json "$out/lib/tensamin/"
      mkdir -p "$out/lib/web/dist"
      cp -r apps/web/dist/. "$out/lib/web/dist/"
      makeWrapper ${pkgs.electron}/bin/electron "$out/bin/tensamin" \
        --add-flags "$out/lib/tensamin" \
        --prefix PATH : ${lib.makeBinPath [ pkgs.pulseaudio ]} \
        --set ELECTRON_OZONE_PLATFORM_HINT auto
      if [ -d apps/electron/build/icons ]; then
        mkdir -p "$out/lib/tensamin/build"
        cp -r apps/electron/build/icons "$out/lib/tensamin/build/icons"
        install -Dm644 apps/electron/build/icons/icon.png "$out/share/icons/hicolor/512x512/apps/tensamin.png"
      fi
      mkdir -p "$out/share/applications"
      cp ${pkgs.makeDesktopItem {
        name = "tensamin";
        desktopName = "Tensamin";
        exec = "tensamin %U";
        icon = "tensamin";
        categories = [ "Network" ];
        mimeTypes = [ "x-scheme-handler/tensamin" ];
      }}/share/applications/* "$out/share/applications/"
    '';
    meta = common.meta // { mainProgram = "tensamin"; };
  });
in { inherit client client-web mtp-sdk client-source client-deps sdk-deps; }
