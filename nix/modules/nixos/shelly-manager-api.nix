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

  inherit (import ./lib.nix {inherit lib;}) isLoopback;

  # uvicorn options that decide where it listens.
  bindingArgs =
    lib.filter (
      arg:
        lib.any (option: arg == option || lib.hasPrefix "${option}=" arg)
        ["--host" "--port" "--uds" "--fd"]
    )
    cfg.extraArgs;

  stateDir = "/var/lib/shelly-manager";
  # The key generated when `secretKeyFile` is null.
  generatedKeyFile = "${stateDir}/secret-key";

  settingsFormat = pkgs.formats.json {};

  secretFile = types.pathWith {
    inStore = false;
    absolute = true;
  };
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

        address = mkOption {
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

            The API reads the key from this file (`SHELLY_SECRET_KEY_FILE`), by
            way of a systemd credential.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr secretFile;
          default = null;
          example = "/run/secrets/shelly-manager-token";
          description = ''
            File holding a shared token that the API and web interface then
            require (`Authorization: Bearer <token>`).  When null, access is
            not authenticated, and the API may only be reachable from this
            machine unless `allowUnauthenticatedAccess` is set.
          '';
        };

        allowUnauthenticatedAccess = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allow other machines to reach the API without `authTokenFile`:
            through a non-loopback `address`, or through the web interface's
            `/api` proxy.  Anyone who can reach it can then change and reboot
            your devices.  Without this, such a configuration is refused.

            ::: {.note}
            Firmware downloads at `/api/firmware/<id>/download` never require
            the token: devices fetch them and cannot send it.
            :::
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
          description = ''
            Extra arguments for uvicorn.  Where the API listens is set with
            `address` and `port` alone, so `--host`, `--port`, `--uds` and
            `--fd` are refused here.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = bindingArgs == [];
        message = "services.shelly-manager.api.extraArgs: ${lib.concatStringsSep ", " bindingArgs} would change where the API listens, past the authentication check; use address and port.";
      }
      {
        assertion = cfg.authTokenFile != null || cfg.allowUnauthenticatedAccess || isLoopback cfg.address;
        message = "services.shelly-manager.api: the API listens on ${cfg.address} without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true.";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    systemd.services.shelly-manager-api = {
      description = "Shelly Manager API, for discovering, configuring and updating Shelly devices";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];

      # The API reads its secrets from these files (patched in; see
      # nix/pkgs/shelly-manager).  `%d` is the credentials directory.
      environment = {
        SHELLY_CONFIG_FILE = settingsFormat.generate "shelly-manager.json" cfg.settings;
        SHELLY_DATA_DIR = stateDir;
        SHELLY_FIRMWARE_DIR = "${stateDir}/firmware";
        SHELLY_SECRET_KEY_FILE =
          if cfg.secretKeyFile != null
          then "%d/secret-key"
          else generatedKeyFile;
        SHELLY_AUTH_TOKEN_FILE = lib.mkIf (cfg.authTokenFile != null) "%d/auth-token";
      };

      # Generate a Fernet key (32 random bytes, URL-safe base64) if there is
      # none, writing it beside its final name first so that it is never seen
      # half-written.
      preStart = lib.mkIf (cfg.secretKeyFile == null) ''
        key=$SHELLY_SECRET_KEY_FILE
        if ! [ -s "$key" ]; then
          tmp=$(mktemp "$(dirname "$key")/.$(basename "$key").XXXXXXXXXX")
          head -c 32 /dev/urandom | base64 | tr '+/' '-_' >"$tmp"
          mv "$tmp" "$key"
        fi
      '';

      # uvicorn takes the last of repeated options: the module's come last.
      script = ''
        exec ${lib.getExe cfg.package} ${lib.escapeShellArgs (cfg.extraArgs ++ ["--host" cfg.address "--port" (toString cfg.port)])}
      '';

      serviceConfig = {
        Restart = "on-failure";

        DynamicUser = true;
        StateDirectory = ["shelly-manager" "shelly-manager/firmware"];
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
