{ self, name }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tensamin.${name};
  isOmikron = name == "omikron";
  inherit (lib) mkOption types;
  cert = if cfg.acmeCertDir != null then "${cfg.acmeCertDir}/fullchain.pem" else cfg.certFile;
  key = if cfg.acmeCertDir != null then "${cfg.acmeCertDir}/key.pem" else cfg.keyFile;
  setup = pkgs.writeShellScript "${name}-setup" ''
    set -eu
    umask 077
    install -d -m 0750 -o ${name} -g ${name} ${lib.escapeShellArg cfg.stateDir}
    cd ${lib.escapeShellArg cfg.stateDir}
    install -d -m 0700 -o ${name} -g ${name} certs
    install -m 0644 -o ${name} -g ${name} ${
      lib.escapeShellArg (if cert == null then "" else cert)
    } certs/cert.pem
    ${pkgs.openssl}/bin/openssl pkcs8 -topk8 -nocrypt \
      -in ${lib.escapeShellArg (if key == null then "" else key)} -out certs/key.pem
    chown ${name}:${name} certs/key.pem
    chmod 0600 certs/key.pem
    ${lib.optionalString isOmikron ''
      install -m 0644 -o ${name} -g ${name} ${lib.escapeShellArg cfg.omegaTrustFile} omega.mpkb
    ''}
    ${lib.optionalString (cfg.identityFile != null) ''
      install -m 0600 -o ${name} -g ${name} ${lib.escapeShellArg cfg.identityFile} ${name}.mk
    ''}
    ${lib.optionalString (cfg.publicIdentityFile != null) ''
      install -m 0644 -o ${name} -g ${name} ${lib.escapeShellArg cfg.publicIdentityFile} ${name}.mpkb
    ''}
  '';
in
{
  options.tensamin.${name} = {
    enable = lib.mkEnableOption "Tensamin ${name}";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.${name};
      description = "Central ${name} package, or an explicit replacement.";
    };
    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/${name}";
      description = "Persistent working directory, including identities and certificates.";
    };
    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
    };
    port = mkOption {
      type = types.port;
      default = 443;
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
    };
    certFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime TLS certificate path. Set together with keyFile.";
    };
    keyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime TLS private key path. Never copied into the Nix store.";
    };
    acmeCertDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime directory containing fullchain.pem and key.pem. Restart the service after renewal.";
    };
    identityFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Existing private keyring to install at startup, or null to retain or generate state.";
    };
    publicIdentityFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Matching public key bundle to install at startup.";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional non-secret runtime settings. Listener options take precedence.";
    };
    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description =
        if isOmikron then
          "Runtime environment files, including optional LiveKit credentials."
        else
          "Runtime environment files. Supply DB_URL here; identities are file-based.";
    };
  }
  // lib.optionalAttrs isOmikron {
    id = mkOption {
      type = types.ints.positive;
      description = "Omikron ID assigned by Omega.";
    };
    omegaHost = mkOption {
      type = types.str;
      default = "tensamin.net";
    };
    omegaPort = mkOption {
      type = types.port;
      default = 9187;
    };
    omegaTrustFile = mkOption {
      type = types.str;
      description = "Runtime path to Omega's trusted public key bundle.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          (cfg.acmeCertDir != null && cfg.certFile == null && cfg.keyFile == null)
          || (cfg.acmeCertDir == null && cfg.certFile != null && cfg.keyFile != null);
        message = "tensamin.${name}: set either acmeCertDir or both certFile and keyFile.";
      }
      {
        assertion = (cfg.identityFile == null) == (cfg.publicIdentityFile == null);
        message = "tensamin.${name}: identityFile and publicIdentityFile must be supplied together.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.stateDir;
        message = "tensamin.${name}.stateDir must be absolute.";
      }
    ];
    users.users.${name} = {
      isSystemUser = true;
      group = name;
      home = cfg.stateDir;
    };
    users.groups.${name} = { };
    systemd.tmpfiles.rules = [ "d ${cfg.stateDir} 0750 ${name} ${name} -" ];
    systemd.services.${name} = {
      description = "Tensamin ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment =
        cfg.environment
        // {
          BIND_ADDRESS = cfg.bindAddress;
        }
        // (
          if isOmikron then
            {
              RHO_PORT = toString cfg.port;
              OMEGA_HOST = cfg.omegaHost;
              OMEGA_PORT = toString cfg.omegaPort;
              ID = toString cfg.id;
            }
          else
            { PORT = toString cfg.port; }
        );
      serviceConfig = {
        Type = "simple";
        User = name;
        Group = name;
        WorkingDirectory = cfg.stateDir;
        ExecStart = "${cfg.package}/bin/${name}";
        ExecStartPre = [ "+${setup}" ];
        EnvironmentFile = cfg.environmentFiles;
        Restart = "always";
        RestartSec = "5s";
        UMask = "0077";
        AmbientCapabilities = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.stateDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
      allowedUDPPorts = [ cfg.port ];
    };
  };
}
