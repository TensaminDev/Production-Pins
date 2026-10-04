{ root, kind ? "tools", channel ? "canary", system ? builtins.currentSystem }:
let
  central = builtins.getFlake (toString root);
  pkgs = import central.inputs.nixpkgs {
    inherit system;
    overlays = [ central.inputs.rust-overlay.overlays.default ];
  };
  project = central.lib.mkPackages { inherit system; };
  # Reuse only the client's tool shells, with central nixpkgs and Rust inputs.
  # Client builds below always consume client-source and mtp-sdk from prod-pins.
  clientTools = (import (central.inputs.client + "/flake.nix")).outputs {
    self = central.inputs.client;
    nixpkgs = central.inputs.nixpkgs // {
      # The client's old SDK platform-tools pin is absent in central nixpkgs.
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
    rust-overlay = central.inputs.rust-overlay;
  };
  branded = name: project.packages.${name}.overrideAttrs {
    TENSAMIN_CHANNEL = channel;
  };
  checked = name: project.packages.${name}.overrideAttrs (old: {
    doCheck = true;
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
    cargoBuildFlags = [ "--workspace" ];
    cargoTestFlags = [ "--workspace" ];
    doCheck = true;
    installPhase = ''mkdir -p "$out"'';
    nativeBuildInputs = old.nativeBuildInputs ++ project.devShells.mtp.nativeBuildInputs;
    preBuild = ''
      cargo fmt --all --check
      cargo clippy --locked --offline --workspace --all-targets -- -D warnings
    '';
  });
in
if kind == "tools" then pkgs.mkShell {
  packages = with pkgs; [ nix git (python3.withPackages (p: [ p.pyyaml ])) bash coreutils jq zip gnutar gzip openssh skopeo shellcheck ruff ];
} else if kind == "electron" || kind == "tauri" then clientTools.devShells.${system}.${kind}
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
