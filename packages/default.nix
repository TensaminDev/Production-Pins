{
  inputs,
  pkgs,
  system,
}:
let
  iota = inputs.iota.packages.${system};
  client = inputs.client.packages.${system};
in
{
  packages = {
    default = client.default;
    client = client.default;
    client-web = client.web;
    client-source = client.default.src;
    client-release-desktop = client.release-desktop;
    client-release-android = client.release-android;
    iota = iota.default;
    iota-portable = iota.portable;
    iota-bundle = iota.bundle;
    iota-container = iota.container;
    iota-daemon = iota.default.overrideAttrs {
      pname = "iota-daemon";
      cargoBuildFlags = [
        "-p"
        "iota-daemon"
      ];
      meta.mainProgram = "iota-daemon";
    };
    iota-ui = iota.default.overrideAttrs {
      pname = "iota-ui";
      cargoBuildFlags = [
        "-p"
        "iota"
      ];
      postInstall = iota.default.postInstall + ''mv "$out/bin/iota" "$out/bin/iota-ui"'';
      meta.mainProgram = "iota-ui";
    };
    omikron = inputs.omikron.packages.${system}.default;
    omikron-container = inputs.omikron.packages.${system}.container;
    omega = inputs.omega.packages.${system}.default;
    omega-container = inputs.omega.packages.${system}.container;
    update-all = pkgs.writeShellApplication {
      name = "update-all";
      runtimeInputs = [ pkgs.nix ];
      text = ''exec nix flake update "$@"'';
    };
  };
}
