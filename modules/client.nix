{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tensamin.client;
  inherit (lib) mkOption types;
in
{
  options.tensamin.client = {
    enable = lib.mkEnableOption "the static Tensamin web client";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.client-web;
      description = "Static client package with index.html at its output root.";
    };
    hostName = mkOption {
      type = types.str;
      default = "localhost";
    };
    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
    };
  };
  config = lib.mkIf cfg.enable {
    services.nginx.enable = true;
    services.nginx.virtualHosts.${cfg.hostName} = {
      listen = [
        {
          addr = cfg.bindAddress;
          inherit (cfg) port;
        }
      ];
      root = cfg.package;
      locations."/".tryFiles = "$uri $uri/ /index.html";
    };
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
