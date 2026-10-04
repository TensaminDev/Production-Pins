{ inputs, pkgs, system, hashes ? import ./hashes.nix }:
let
  inherit (pkgs) lib;
  rust = pkgs.rust-bin.stable.latest.default.override {
    targets = [ "wasm32-unknown-unknown" "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-musl" ];
    extensions = [ "rust-src" "rustfmt" "clippy" ];
  };
  rustPlatform = pkgs.makeRustPlatform { cargo = rust; rustc = rust; };
  projects = [ "iota" "omikron" "omega" "mtp" ];
  prepared = lib.genAttrs projects (name: pkgs.runCommand "${name}-source" {
    nativeBuildInputs = [ pkgs.python3 ] ++ lib.optional (name == "iota") rust;
  } ''
    python ${../lib/prepare-source.py} ${name} ${inputs.${name}} ${inputs.mtp} \
      ${inputs.mtp-type-maps} ${inputs.iota} "$out"
    ${lib.optionalString (name == "iota") ''
      rustfmt --edition 2024 "$out/iota-paths/src/lib.rs" "$out/iota-installer/src/lib.rs" "$out/iota-daemon/src/main.rs"
    ''}
  '');
  sources = lib.genAttrs projects (name:
    let lock = ./locks + "/${name}.lock";
    in if builtins.pathExists lock then pkgs.runCommand "${name}-locked-source" {} ''
      cp -r ${prepared.${name}} "$out"
      chmod -R u+w "$out"
      cp ${lock} "$out/Cargo.lock"
    '' else prepared.${name});
  vendors = lib.genAttrs projects (name: rustPlatform.fetchCargoVendor {
    pname = "${name}-vendor";
    version = "0.1.0";
    src = sources.${name};
    hash = hashes.${name};
  });
  mkRust = name: flags: rustPlatform.buildRustPackage {
    pname = name;
    version = "0.1.0";
    src = sources.${name};
    cargoDeps = vendors.${name};
    cargoBuildFlags = flags;
    nativeBuildInputs = [ pkgs.cmake pkgs.perl pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl pkgs.sqlite ] ++ lib.optional (name == "omega") pkgs.libmysqlclient;
    dontUseCmakeConfigure = true;
    MTP_TYPE_MAPS = "${inputs.mtp-type-maps}/type-maps.yaml";
    doCheck = false;
    postInstall = lib.optionalString (name == "iota") ''
      mkdir -p "$out/share/iota"
      cp -r static/web "$out/share/iota/web"
    '';
    passthru = {
      source = inputs.${name};
      transformedSource = sources.${name};
      inherit (inputs) mtp mtp-type-maps;
    };
    meta = { platforms = [ "x86_64-linux" "aarch64-linux" ]; mainProgram = name; };
  };
  iota = mkRust "iota" [ "-p" "iota" "-p" "iota-daemon" "-p" "iota-updater" "-p" "iota-installer" ];
  staticPkgs = pkgs.pkgsStatic;
  iotaPortable = rustPlatform.buildRustPackage {
    pname = "iota-portable";
    inherit (iota) version src cargoDeps cargoBuildFlags postInstall;
    nativeBuildInputs = [ pkgs.cmake pkgs.perl pkgs.pkg-config pkgs.binutils pkgs.removeReferencesTo staticPkgs.stdenv.cc ];
    buildInputs = [ staticPkgs.openssl staticPkgs.sqlite staticPkgs.zlib ];
    OPENSSL_STATIC = "1";
    SQLITE3_STATIC = "1";
    env.PKG_CONFIG_ALLOW_CROSS = "1";
    # Keep build scripts on the native host and cross-link only the payload.
    buildPhase = ''
      runHook preBuild
      export CARGO_TARGET_${pkgs.stdenv.buildPlatform.rust.cargoEnvVarTarget}_LINKER=${pkgs.stdenv.cc}/bin/cc
      export CARGO_TARGET_${staticPkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}_LINKER=${staticPkgs.stdenv.cc}/bin/${staticPkgs.stdenv.cc.targetPrefix}cc
      export CC_${pkgs.stdenv.buildPlatform.rust.cargoEnvVarTarget}=${pkgs.stdenv.cc}/bin/cc
      export CC_${staticPkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}=${staticPkgs.stdenv.cc}/bin/${staticPkgs.stdenv.cc.targetPrefix}cc
      export CC_${builtins.replaceStrings [ "-" ] [ "_" ] staticPkgs.stdenv.hostPlatform.rust.rustcTarget}=${staticPkgs.stdenv.cc}/bin/${staticPkgs.stdenv.cc.targetPrefix}cc
      export CXX_${builtins.replaceStrings [ "-" ] [ "_" ] staticPkgs.stdenv.hostPlatform.rust.rustcTarget}=${staticPkgs.stdenv.cc}/bin/${staticPkgs.stdenv.cc.targetPrefix}c++
      unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
      export CARGO_TARGET_${staticPkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}_RUSTFLAGS="-L native=${lib.getLib staticPkgs.zlib}/lib --remap-path-prefix=/nix/store=/usr/src"
      cargo build --locked --offline --release -j "$NIX_BUILD_CORES" \
        --target ${staticPkgs.stdenv.hostPlatform.rust.rustcTarget} ${lib.escapeShellArgs iota.cargoBuildFlags}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for binary in iota iota-daemon iota-updater iota-release iota-bundle; do
        cp "target/${staticPkgs.stdenv.hostPlatform.rust.rustcTarget}/release/$binary" "$out/bin/"
      done
      runHook postInstall
    '';
    dontUseCmakeConfigure = true;
    MTP_TYPE_MAPS = "${inputs.mtp-type-maps}/type-maps.yaml";
    doCheck = false;
    # Reject accidental dynamic linkage before these binaries reach a release.
    postFixup = ''
      for binary in "$out"/bin/*; do
        # Prebuilt Rust std retains compiler source paths in panic messages.
        remove-references-to -t ${rust} "$binary"
        if readelf -l "$binary" | grep -q INTERP || readelf -d "$binary" | grep -q NEEDED; then
          echo "Non-portable ELF: $binary" >&2
          exit 1
        fi
      done
    '';
    allowedReferences = [ "out" ];
    meta = iota.meta;
  };
  clientPackages = import ./client.nix {
    inherit pkgs rust rustPlatform inputs hashes;
    mtpSource = sources.mtp;
    mtpVendor = vendors.mtp;
  };
  packages = {
    inherit iota;
    iota-portable = iotaPortable;
    iota-bundle = pkgs.runCommand "iota-bundle" {} ''
      mkdir -p "$out/bin" "$out/share/iota"
      cp -r ${iota}/bin/. "$out/bin/"
      cp -r ${inputs.iota}/systemd "$out/share/iota/"
      cp -r ${sources.iota}/scripts "$out/share/iota/"
      cp ${inputs.iota}/iota-updater/artifacts.tsv "$out/share/iota/"
      cp -r ${iota}/share/iota/web "$out/share/iota/static-web"
      cp ${sources.iota}/iota-installer/bundle-files.txt "$out/share/iota/"
    '';
    iota-daemon = iota.overrideAttrs {
      pname = "iota-daemon";
      cargoBuildFlags = [ "-p" "iota-daemon" ];
      meta.mainProgram = "iota-daemon";
    };
    iota-ui = iota.overrideAttrs {
      pname = "iota-ui";
      cargoBuildFlags = [ "-p" "iota" ];
      postInstall = iota.postInstall + ''mv "$out/bin/iota" "$out/bin/iota-ui"'';
      meta.mainProgram = "iota-ui";
    };
    omikron = mkRust "omikron" [];
    omega = mkRust "omega" [];
    iota-container = pkgs.dockerTools.buildLayeredImage {
      name = "tensamin/iota";
      tag = "${inputs.iota.shortRev or "local"}";
      contents = [ iotaPortable pkgs.cacert pkgs.dockerTools.binSh ];
      fakeRootCommands = ''
        mkdir -p var/lib/iota/config var/lib/iota/runtime tmp
        chmod 1777 tmp
        chown -R 1000:1000 var/lib/iota
      '';
      enableFakechroot = true;
      config = {
        Entrypoint = [ "${iotaPortable}/bin/iota-daemon" ];
        User = "1000:1000";
        WorkingDir = "/var/lib/iota";
        Volumes = { "/var/lib/iota" = {}; };
        ExposedPorts = { "1984/tcp" = {}; "1984/udp" = {}; };
        Env = [
          "HOME=/var/lib/iota"
          "IOTA_DATA_ROOT=/var/lib/iota"
          "IOTA_DEPLOYMENT_MODE=user_local"
          "IOTA_ASSET_DIR=${iotaPortable}/share/iota/web"
          "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        ];
      };
    };
    omikron-container = pkgs.dockerTools.buildLayeredImage {
      name = "tensamin/omikron";
      tag = "${inputs.omikron.shortRev or "local"}";
      contents = [ packages.omikron pkgs.cacert pkgs.dockerTools.binSh ];
      config = {
        Entrypoint = [ "${packages.omikron}/bin/omikron" ];
        WorkingDir = "/var/lib/omikron";
        Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      };
    };
    omega-container = pkgs.dockerTools.buildLayeredImage {
      name = "tensamin/omega";
      tag = "${inputs.omega.shortRev or "local"}";
      contents = [ packages.omega pkgs.cacert pkgs.dockerTools.binSh ];
      config = {
        Entrypoint = [ "${packages.omega}/bin/omega" ];
        WorkingDir = "/var/lib/omega";
        Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      };
    };
    inherit (clientPackages) client client-web mtp-sdk;
    default = packages.client;
    update-all = pkgs.writeShellApplication {
      name = "update-all";
      runtimeInputs = [ pkgs.nix pkgs.git pkgs.python3 rust pkgs.nodejs pkgs.pnpm pkgs.coreutils ];
      text = ''exec python ${../scripts/update-all.py} "$@"'';
    };
  } // lib.mapAttrs' (name: value: lib.nameValuePair "${name}-source" value) prepared
    // lib.mapAttrs' (name: value: lib.nameValuePair "${name}-vendor" value) vendors
    // { inherit (clientPackages) client-source client-deps sdk-deps; };
in {
  inherit packages;
  devShells = lib.genAttrs [ "iota" "omikron" "omega" "mtp" "client" ] (name: pkgs.mkShell {
    packages = [ rust pkgs.git pkgs.cmake pkgs.perl pkgs.pkg-config pkgs.nodejs pkgs.pnpm pkgs.wasm-pack ];
    buildInputs = [ pkgs.openssl pkgs.sqlite ] ++ lib.optional (name == "omega") pkgs.libmysqlclient;
    MTP_TYPE_MAPS = "${inputs.mtp-type-maps}/type-maps.yaml";
  }) // { default = pkgs.mkShell { packages = [ packages.update-all ]; }; };
}
