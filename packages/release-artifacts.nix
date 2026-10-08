{
  pkgs,
  project,
  channel,
}:
let
  arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  packages = project.packages;
  branded = name: packages.${name}.overrideAttrs { TENSAMIN_CHANNEL = channel; };
in
{
  packages = pkgs.linkFarm "release-packages-${channel}" (
    map
      (name: {
        inherit name;
        path =
          if
            builtins.elem name [
              "client"
              "client-web"
            ]
          then
            branded name
          else
            packages.${name};
      })
      [
        "iota"
        "iota-portable"
        "iota-bundle"
        "iota-daemon"
        "iota-ui"
        "omikron"
        "omega"
        "iota-container"
        "omikron-container"
        "omega-container"
        "client"
        "client-web"
      ]
  );
  portable =
    pkgs.runCommand "release-portable-${channel}-${arch}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p "$out"
        for binary in iota iota-daemon iota-updater iota-release iota-bundle; do
          cp ${packages.iota-portable}/bin/$binary "$out/$binary-linux-${arch}"
        done
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
          -cf - -C ${packages.iota-portable} bin share | gzip -n > "$out/iota-portable-linux-${arch}.tar.gz"
        ${pkgs.lib.concatMapStringsSep "\n"
          (name: ''
            cp -L ${packages.${"${name}-container"}} "$out/${name}-image-linux-${arch}.tar.gz"
          '')
          [
            "iota"
            "omikron"
            "omega"
          ]
        }
        cp -rL ${packages.iota-bundle}/share/iota "$out/iota-contract"
        chmod -R u+w "$out/iota-contract"
        mkdir -p "$out/iota-contract/iota-updater" "$out/iota-contract/iota-installer" "$out/iota-contract/static"
        mv "$out/iota-contract/artifacts.tsv" "$out/iota-contract/iota-updater/"
        mv "$out/iota-contract/bundle-files.txt" "$out/iota-contract/iota-installer/"
        mv "$out/iota-contract/static-web" "$out/iota-contract/static/web"
      '';
}
