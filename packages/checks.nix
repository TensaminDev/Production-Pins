{
  pkgs,
  project,
  root,
  inputs,
  system,
}:
{
  scripts =
    pkgs.runCommand "release-script-checks"
      {
        nativeBuildInputs = [
          pkgs.bun
          pkgs.shellcheck
        ];
      }
      ''
        cd ${root}
        mkdir -p "$out"
        bun build --target=bun --outdir "$out" packages/*.ts modules/*.ts
        shellcheck ${import ./release-build.nix { inherit pkgs; }} \
          ${project.packages.client-release-desktop} \
          ${project.packages.client-release-android}
      '';
}
// pkgs.lib.genAttrs [ "client" "iota" "omikron" "omega" ] (
  name:
  pkgs.linkFarm "${name}-checks" (
    pkgs.lib.mapAttrsToList (check: path: {
      name = check;
      inherit path;
    }) inputs.${name}.checks.${system}
  )
)
