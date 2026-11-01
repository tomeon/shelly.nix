{moduleWithSystem}:
# `moduleWithSystem` passes only the arguments named here.
moduleWithSystem ({config, ...} @ perSystem: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.services.shelly-manager.api;

  stateDir = "/var/lib/shelly-manager";

  settingsFormat = pkgs.formats.json {};

  secretFile = types.pathWith {
    inStore = false;
    absolute = true;
  };

  # Upstream reads its secrets from the environment only.
  start = pkgs.writeShellScript "shelly-manager-api-start" ''
    set -eu
    ${
      if cfg.secretKeyFile == null
      then ''
        key="$STATE_DIRECTORY/secret-key"
        if [ ! -s "$key" ]; then
          # A Fernet key: 32 random bytes, URL-safe base64.
          head -c 32 /dev/urandom | base64 | tr '+/' '-_' >"$key.tmp"
          mv "$key.tmp" "$key"
        fi
      ''
      else ''
        key="$CREDENTIALS_DIRECTORY/secret-key"
      ''
    }
    SHELLY_SECRET_KEY=$(cat "$key")
    export SHELLY_SECRET_KEY
    ${lib.optionalString (cfg.authTokenFile != null) ''
      SHELLY_AUTH_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/auth-token")
      export SHELLY_AUTH_TOKEN
    ''}
    exec ${lib.getExe cfg.package} \
      --host ${lib.escapeShellArg cfg.listenAddress} \
      --port ${toString cfg.port} \
      ${lib.escapeShellArgs cfg.extraArgs}
  '';
in {
  options = {
    services.shelly-manager = {
      api = {
        enable = lib.mkEnableOption "the shelly-manager API";

        package = mkOption {
          type = types.package;
          default = perSystem.config.packages.shelly-manager-api;
          defaultText = "<shelly-manager-api>";
          description = ''
            Package providing the shelly-manager API.
          '';
        };

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "0.0.0.0";
          description = ''
            Address the API listens on.  The default suits the web interface on
            the same machine, which proxies to it; listen on a LAN address if
            devices fetch firmware from the API directly.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 8000;
          description = "Port the API listens on.";
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open `port` in the firewall.";
        };

        secretKeyFile = mkOption {
          type = types.nullOr secretFile;
          default = null;
          example = "/run/secrets/shelly-manager-key";
          description = ''
            File holding the Fernet key that encrypts stored credentials and
            backups (generate one with
            `openssl rand -base64 32 | tr '+/' '-_'`).  When null, a key is
            generated on first start and kept in ${stateDir}.  Changing the key
            makes existing credentials and backups unreadable.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr secretFile;
          default = null;
          example = "/run/secrets/shelly-manager-token";
          description = ''
            File holding a shared token that the API and web interface then
            require (`Authorization: Bearer <token>`).  When null, access is
            not authenticated.
          '';
        };

        settings = mkOption {
          type = types.submodule {freeformType = settingsFormat.type;};
          default = {};
          example = {
            firmware.advertised_base_url = "http://192.168.1.10:8000";
            network.timeout = 5;
            logging.level = "DEBUG";
          };
          description = ''
            shelly-manager configuration, written to the JSON file named by
            `SHELLY_CONFIG_FILE`.  See upstream's `AppSettings` for the
            available sections (`network`, `logging`, `backup`, `firmware`,
            ...).  Data lives in ${stateDir}.
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["--proxy-headers"];
          description = "Extra arguments for uvicorn.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    systemd.services.shelly-manager-api = {
      description = "shelly-manager API";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      path = [pkgs.coreutils];

      environment = {
        SHELLY_CONFIG_FILE = settingsFormat.generate "shelly-manager.json" cfg.settings;
        SHELLY_DATA_DIR = stateDir;
        SHELLY_FIRMWARE_DIR = "${stateDir}/firmware";
      };

      serviceConfig = {
        ExecStart = start;
        Restart = "on-failure";

        DynamicUser = true;
        StateDirectory = "shelly-manager";
        StateDirectoryMode = "0700";
        WorkingDirectory = stateDir;
        UMask = "0077";
        LoadCredential =
          lib.optional (cfg.secretKeyFile != null) "secret-key:${toString cfg.secretKeyFile}"
          ++ lib.optional (cfg.authTokenFile != null) "auth-token:${toString cfg.authTokenFile}";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        # AF_NETLINK: network interface enumeration for mDNS discovery.
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_NETLINK" "AF_UNIX"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged"];
      };
    };
  };
})
