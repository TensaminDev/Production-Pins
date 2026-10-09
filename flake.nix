{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    iota = {
      url = "git+ssh://git@methanium.net/tensamin/iota?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    omikron = {
      url = "git+ssh://git@methanium.net/tensamin/omikron?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    omega = {
      url = "git+ssh://git@methanium.net/tensamin/omega?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    client = {
      url = "git+ssh://git@methanium.net/tensamin/client?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    mtp = {
      url = "git+ssh://git@methanium.net/methanium/mtp?ref=master";
      flake = false;
    };
    mtp-type-maps = {
      url = "git+ssh://git@methanium.net/tensamin/mtp-type-maps?ref=main";
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
