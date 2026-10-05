{ root, kind ? "tools", channel ? "canary", system ? builtins.currentSystem, sources ? {} }:
let
  central = builtins.getFlake (toString root);
  pkgs = import central.inputs.nixpkgs {
    inherit system;
    overlays = [ central.inputs.rust-overlay.overlays.default ];
  };
  project = central.lib.mkPackages { inherit system sources; };
  # Reuse only the client's tool shells, with central nixpkgs and Rust inputs.
  # Client builds below always consume client-source and mtp-sdk from prod-pins.
  clientTools = (import (central.inputs.client + "/flake.nix")).outputs {
    self = central.inputs.client;
    prod-pins = central // {
      inputs = central.inputs // {
        nixpkgs = central.inputs.nixpkgs // {
          # Use the platform-tools version available in central nixpkgs.
          outPath = pkgs.runCommand "release-client-nixpkgs" {} ''
            mkdir -p "$out"
            cat > "$out/default.nix" <<'EOF'
            args: let
              pkgs = import ${central.inputs.nixpkgs} args;
            in pkgs // { androidenv = pkgs.androidenv // {
              composeAndroidPackages = options: pkgs.androidenv.composeAndroidPackages
                (options // { platformToolsVersion = "37.0.1"; });
            }; }
            EOF
          '';
        };
      };
    };
  };
  branded = name: project.packages.${name}.overrideAttrs {
    TENSAMIN_CHANNEL = channel;
  };
  checked = name: project.packages.${name}.overrideAttrs (old: {
    doCheck = true;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    installPhase = ''mkdir -p "$out"'';
    nativeBuildInputs = old.nativeBuildInputs ++ project.devShells.${name}.nativeBuildInputs;
    preBuild = (old.preBuild or "") + ''
      cargo fmt --all --check
      cargo clippy --locked --offline --workspace --all-targets -- -D warnings
    '';
    cargoTestFlags = [ "--workspace" ];
  });
  mtpCheck = project.packages.iota.overrideAttrs (old: {
    pname = "mtp-checks";
    src = project.packages.mtp-sdk.src;
    cargoDeps = project.packages.mtp-vendor;
    cargoBuildFlags = [ "--workspace" "--exclude" "mtp-wasm" ];
    cargoTestFlags = [ "--workspace" "--exclude" "mtp-wasm" ];
    doCheck = true;
    MTP_TYPE_MAPS = "${project.packages.mtp-sdk.src}/tests/fixtures/example/type-maps.yaml";
    installPhase = ''mkdir -p "$out"'';
    nativeBuildInputs = old.nativeBuildInputs ++ project.devShells.mtp.nativeBuildInputs;
    preBuild = ''
      cargo fmt --all --check
      cargo clippy --locked --offline --workspace --exclude mtp-wasm --all-targets -- -D warnings
    '';
  });
in
if kind == "tools" then pkgs.mkShell {
  CONTAINERS_POLICY = pkgs.writeText "release-containers-policy.json"
    (builtins.toJSON { default = [{ type = "insecureAcceptAnything"; }]; });
  packages = with pkgs; [ nix git (python3.withPackages (p: [ p.pyyaml ])) bash coreutils jq zip gnutar gzip openssh skopeo shellcheck ruff ];
} else if kind == "electron" || kind == "tauri" then
  clientTools.devShells.${system}.${kind}.overrideAttrs (old: {
    buildInputs = builtins.filter (package: !(pkgs.lib.hasPrefix "corepack" (package.pname or "")))
      (old.buildInputs or []) ++ [ pkgs.pnpm ];
    nativeBuildInputs = builtins.filter (package: !(pkgs.lib.hasPrefix "corepack" (package.pname or "")))
      (old.nativeBuildInputs or []);
    shellHook = builtins.replaceStrings
      [ ''cd "$workRoot/tensamin/client"'' ]
      [ ''cd "''${RELEASE_WORK:-$workRoot/tensamin/client}"'' ]
      old.shellHook;
  })
else if kind == "checks" then pkgs.linkFarm "release-checks" (map (name: {
  inherit name;
  path = checked name;
}) [ "iota" "omikron" "omega" ] ++ [ { name = "mtp"; path = mtpCheck; } ])
else if kind == "packages" then pkgs.linkFarm "release-packages" (map (name: {
  inherit name;
  path = if builtins.elem name [ "client" "client-web" ] then branded name else project.packages.${name};
}) [ "iota" "iota-portable" "iota-bundle" "iota-daemon" "iota-ui" "omikron" "omega"
  "iota-container" "omikron-container" "omega-container" "client" "client-web" "mtp-sdk" ])
else throw "Unknown release environment ${kind}"
