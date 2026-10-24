{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    iota = {
      url = "github:TensaminDev/Iota/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.type-maps.follows = "mtp-type-maps";
    };
    omikron = {
      url = "github:TensaminDev/Omikron/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.type-maps.follows = "mtp-type-maps";
    };
    omega = {
      url = "github:TensaminDev/Omega/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.type-maps.follows = "mtp-type-maps";
      # Keep Omega's identity crate at its own Cargo.lock-compatible Iota pin.
    };
    client = {
      url = "github:TensaminDev/Client/dev";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.mtp-type-maps.follows = "mtp-type-maps";
    };
    mtp = {
      url = "github:nonanium/MTP/master";
      flake = false;
    };
    mtp-type-maps = {
      url = "github:TensaminDev/MTP-Type-Maps/main";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forSystems = nixpkgs.lib.genAttrs systems;
      project =
        system:
        import ./packages {
          inherit inputs system;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };
        };
    in
    {
      packages = forSystems (system: (project system).packages);
      devShells = forSystems (system: {
        default = import ./packages/release-environment.nix {
          root = self;
          central = self;
          inherit system;
        };
      });
      apps = forSystems (system: {
        update-all = {
          type = "app";
          program = "${self.packages.${system}.update-all}/bin/update-all";
        };
      });
      checks = forSystems (
        system:
        import ./packages/checks.nix {
          inherit inputs system;
          pkgs = import nixpkgs { inherit system; };
          project = project system;
          root = self;
        }
      );
      lib.mkPackages =
        {
          system,
          sources ? { },
        }:
        import ./packages {
          inherit system;
          inputs = inputs // sources;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };
        };
      nixosModules =
        if builtins.pathExists ./modules/default.nix then
          import ./modules/default.nix { inherit self; }
        else
          { };
    };
}
