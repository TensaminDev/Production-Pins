{
  description = "Shared production sources and builds for Tensamin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    iota = { url = "git+ssh://git@methanium.net/tensamin/iota?ref=main"; flake = false; };
    omikron = { url = "git+ssh://git@methanium.net/tensamin/omikron?ref=main"; flake = false; };
    omega = { url = "git+ssh://git@methanium.net/tensamin/omega?ref=main"; flake = false; };
    client = { url = "git+ssh://git@methanium.net/tensamin/client?ref=dev"; flake = false; };
    mtp = { url = "git+ssh://git@methanium.net/methanium/mtp?ref=master"; flake = false; };
    mtp-type-maps = { url = "git+ssh://git@methanium.net/tensamin/mtp-type-maps?ref=main"; flake = false; };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = nixpkgs.lib.genAttrs systems;
      project = system: import ./packages {
        inherit inputs system;
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ inputs.rust-overlay.overlays.default ];
        };
      };
    in {
      packages = forSystems (system: (project system).packages);
      devShells = forSystems (system: (project system).devShells);
      apps = forSystems (system: {
        update-all = {
          type = "app";
          program = "${self.packages.${system}.update-all}/bin/update-all";
        };
      });
      lib.mkPackages = { system, sources ? {}, hashes ? import ./packages/hashes.nix }:
        import ./packages {
          inherit system hashes;
          inputs = inputs // sources;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };
        };
      nixosModules = if builtins.pathExists ./modules/default.nix
        then import ./modules/default.nix { inherit self; }
        else {};
    };
}
