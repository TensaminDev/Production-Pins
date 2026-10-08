{
  root,
  kind ? "tools",
  channel ? "canary",
  system ? builtins.currentSystem,
  sources ? { },
}:
let
  central = builtins.getFlake (toString root);
  pkgs = import central.inputs.nixpkgs {
    inherit system;
    overlays = [ central.inputs.rust-overlay.overlays.default ];
  };
  project = central.lib.mkPackages { inherit system sources; };
  # Reuse only the client's tool shells, with central nixpkgs and Rust inputs.
  clientTools = central.inputs.client;
  checks = import ./checks.nix {
    inherit
      pkgs
      project
      root
      system
      ;
    inputs = central.inputs;
  };
  artifacts = import ./release-artifacts.nix { inherit pkgs project channel; };
  client = clientTools.packages.${system};
in
if kind == "tools" then
  pkgs.mkShell {
    CONTAINERS_POLICY = pkgs.writeText "release-containers-policy.json" (
      builtins.toJSON { default = [ { type = "insecureAcceptAnything"; } ]; }
    );
    packages = with pkgs; [
      nix
      git
      bun
      bash
      coreutils
      jq
      zip
      gnutar
      gzip
      openssh
      skopeo
      shellcheck
    ];
  }
else if kind == "electron" || kind == "tauri" then
  clientTools.devShells.${system}.${kind}.overrideAttrs (old: {
    buildInputs =
      builtins.filter (package: !(pkgs.lib.hasPrefix "corepack" (package.pname or ""))) (
        old.buildInputs or [ ]
      )
      ++ [ pkgs.pnpm ];
    nativeBuildInputs = builtins.filter (
      package: !(pkgs.lib.hasPrefix "corepack" (package.pname or ""))
    ) (old.nativeBuildInputs or [ ]);
    shellHook = ''cd "''${RELEASE_WORK:?}"'' + "\n" + old.shellHook;
  })
else if kind == "client-desktop" then
  client.release-desktop
else if kind == "client-android" then
  client.release-android
else if kind == "checks" then
  pkgs.linkFarm "release-checks" (
    pkgs.lib.mapAttrsToList (name: path: {
      inherit name path;
    }) checks
  )
else if kind == "portable" then
  artifacts.portable
else if kind == "packages" then
  artifacts.packages
else if kind == "build" then
  import ./release-build.nix { inherit pkgs; }
else
  throw "Unknown release environment ${kind}"
