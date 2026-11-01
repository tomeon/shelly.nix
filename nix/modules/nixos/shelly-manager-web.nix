{moduleWithSystem}:
# `moduleWithSystem` passes only the arguments named here.
moduleWithSystem ({config, ...} @ perSystem: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.services.shelly-manager.web;
  api = config.services.shelly-manager.api;

  proxyApi = cfg.apiUrl == null;

  apiHost = let
    address = api.listenAddress;
  in
    if address == "0.0.0.0"
    then "127.0.0.1"
    else if address == "::"
    then "[::1]"
    else if lib.hasInfix ":" address
    then "[${address}]"
    else address;

  # Read by the interface at start-up; see upstream's packages/web/src/lib/api.ts.
  configJs = pkgs.writeText "shelly-manager-web-config.js" ''
    window._env_ = {
      VITE_BASE_API_URL: ${
      if proxyApi
      then "window.location.origin"
      else builtins.toJSON cfg.apiUrl
    },
    };
  '';
in {
  options = {
    services.shelly-manager = {
      web = {
        enable = lib.mkEnableOption "the shelly-manager web interface";

        package = mkOption {
          type = types.package;
          default = perSystem.config.packages.shelly-manager-web;
          defaultText = "<shelly-manager-web>";
          description = ''
            Package providing the shelly-manager web interface.
          '';
        };

        hostName = mkOption {
          type = types.str;
          default = config.networking.fqdnOrHostName;
          defaultText = lib.literalExpression "config.networking.fqdnOrHostName";
          example = "shelly.example.com";
          description = ''
            Name of the nginx virtual host serving the interface.  Configure
            TLS and the like through `services.nginx.virtualHosts.<hostName>`.
          '';
        };

        apiUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://shelly-api.example.com";
          description = ''
            URL at which browsers reach the API.  When null, the virtual host
            proxies `/api` (and the API's `/docs`) to
            `services.shelly-manager.api` on this machine, and the interface
            uses its own origin.
          '';
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open TCP ports 80 and 443 in the firewall.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !proxyApi || api.enable;
        message = "services.shelly-manager.web: set `apiUrl`, or enable `services.shelly-manager.api` on this machine.";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [80 443];

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.hostName} = {
        root = cfg.package;
        locations =
          {
            # A single-page app: unknown paths are client-side routes.
            "/" = {
              tryFiles = "$uri $uri/ /index.html";
              extraConfig = "expires -1;";
            };
            "= /config.js" = {
              alias = configJs;
              extraConfig = "expires -1;";
            };
            # Content-hashed file names.
            "/assets/".extraConfig = ''
              expires 1y;
              add_header Cache-Control "public, immutable";
            '';
          }
          // lib.optionalAttrs proxyApi (lib.genAttrs ["/api/" "/docs"] (_: {
            proxyPass = "http://${apiHost}:${toString api.port}";
            recommendedProxySettings = true;
            # Bulk operations in the interface wait up to ten minutes.
            extraConfig = "proxy_read_timeout 600s;";
          }));
      };
    };
  };
})
