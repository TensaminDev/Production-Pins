{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tensamin.iota;
  inherit (lib) mkOption types;
  format = pkgs.formats.yaml { };
  settings = lib.recursiveUpdate cfg.settings {
    port = cfg.port;
    web = {
      mode = cfg.webMode;
      bind = cfg.bindAddress;
      port = cfg.port;
      required = cfg.webMode != "disabled";
      asset_dir = cfg.assetDir;
    }
    // lib.optionalAttrs (cfg.certFile != null) {
      certificate = cfg.certFile;
      key = cfg.keyFile;
    };
  };
  sourceConfig =
    if cfg.settingsFile != null then cfg.settingsFile else format.generate "iota-config.yaml" settings;
  configFile = "${cfg.stateDir}/config.yaml";
  setup = pkgs.writeShellScript "iota-setup" ''
    set -eu
    umask 077
    ${pkgs.bun}/bin/bun ${./merge-config.ts} ${lib.escapeShellArg sourceConfig} ${lib.escapeShellArg configFile}
    chown iota:iota ${lib.escapeShellArg configFile}
  '';
in
{
  options.tensamin.iota = {
    enable = lib.mkEnableOption "the Tensamin Iota daemon";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.iota-daemon;
    };
    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/iota";
    };
    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/iota";
    };
    runtimeDir = mkOption {
      type = types.str;
      default = "/run/iota";
      description = "IPC socket directory. The socket is owned by iota:iota with mode 0660; add authorized operators to the iota group.";
    };
    logDir = mkOption {
      type = types.str;
      default = "/var/log/iota";
    };
    assetDir = mkOption {
      type = types.str;
      default = "${self.packages.${pkgs.stdenv.hostPlatform.system}.iota.passthru.source}/static/web";
      description = "Static Iota assets. Defaults to the pinned source's shipped web directory.";
    };
    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
    };
    port = mkOption {
      type = types.port;
      default = 1984;
    };
    webMode = mkOption {
      type = types.enum [
        "disabled"
        "loopback"
        "network"
      ];
      default = "network";
      description = "Iota listener mode. Both loopback and network modes require TLS upstream.";
    };
    certFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime TLS certificate path. The iota user needs read access and traversal access to parent directories.";
    };
    keyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime TLS private key path.";
    };
    omegaApiUrl = mkOption {
      type = types.str;
      default = "https://omega.tensamin.net";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
    };
    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
    settings = mkOption {
      type = format.type;
      default = { };
      description = ''
        Operator settings written to stateDir/config.yaml at each startup.
        Listener and asset options take precedence. Omitted iota_id, omikron_host,
        omikron_port and omikron_id retain their daemon values; explicit values,
        including null, replace them. Other edits to the generated file are replaced.
        Identities under stateDir/identity are retained.
      '';
    };
    settingsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Complete runtime YAML configuration replacing generated settings, with the
        same preservation of omitted discovery fields as settings. Listener and TLS
        settings must agree with module options. Relative paths resolve against
        stateDir, not this file's directory.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.certFile == null) == (cfg.keyFile == null);
        message = "tensamin.iota: certFile and keyFile must be supplied together.";
      }
      {
        assertion = cfg.settingsFile != null || cfg.webMode == "disabled" || cfg.certFile != null;
        message = "tensamin.iota: an enabled listener requires certFile and keyFile, or a complete settingsFile with TLS.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path) [
          cfg.stateDir
          cfg.cacheDir
          cfg.runtimeDir
          cfg.logDir
          cfg.assetDir
        ];
        message = "tensamin.iota: directory paths must be absolute.";
      }
    ];
    users.users.iota = {
      isSystemUser = true;
      group = "iota";
      home = cfg.stateDir;
    };
    users.groups.iota = { };
    systemd.tmpfiles.rules = map (path: "d ${path} 0750 iota iota -") [
      cfg.stateDir
      cfg.cacheDir
      cfg.runtimeDir
      cfg.logDir
    ];
    systemd.sockets.iota = {
      description = "Tensamin Iota IPC socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${cfg.runtimeDir}/iota.sock";
        SocketMode = "0660";
        SocketUser = "iota";
        SocketGroup = "iota";
        DirectoryMode = "0750";
        Backlog = 5;
        RemoveOnStop = true;
      };
    };
    systemd.services.iota = {
      description = "Tensamin Iota daemon";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "iota.socket"
      ];
      requires = [ "iota.socket" ];
      environment = {
        OMEGA_API_URL = cfg.omegaApiUrl;
        IOTA_SOCKET = "${cfg.runtimeDir}/iota.sock";
        IOTA_CONFIG_FILE = configFile;
        IOTA_CONFIG_DIR = cfg.stateDir;
        IOTA_STATE_DIR = cfg.stateDir;
        IOTA_CACHE_DIR = cfg.cacheDir;
        IOTA_RUNTIME_DIR = cfg.runtimeDir;
        IOTA_LOG_DIR = cfg.logDir;
        IOTA_ASSET_DIR = cfg.assetDir;
        IOTA_DEPLOYMENT_MODE = "system_socket_activated";
        IOTA_SUPERVISOR = "systemd";
      };
      serviceConfig = {
        Type = "simple";
        User = "iota";
        Group = "iota";
        WorkingDirectory = cfg.stateDir;
        ExecStart = "${cfg.package}/bin/iota-daemon";
        ExecStartPre = [ "+${setup}" ];
        EnvironmentFile = cfg.environmentFiles;
        Restart = "on-failure";
        RestartSec = "5s";
        RestartPreventExitStatus = "0";
        RestartForceExitStatus = "75";
        TimeoutStopSec = "10s";
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        UMask = "0077";
        AmbientCapabilities = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [
          cfg.stateDir
          cfg.cacheDir
          cfg.runtimeDir
          cfg.logDir
        ];
        ReadOnlyPaths = [ cfg.assetDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
    networking.firewall = lib.mkIf (cfg.openFirewall && cfg.webMode != "disabled") {
      allowedTCPPorts = [ cfg.port ];
      allowedUDPPorts = [ cfg.port ];
    };
  };
}
