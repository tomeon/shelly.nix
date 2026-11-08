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

  inherit (import ./lib.nix {inherit lib;}) isLoopback;

  # The virtual host's listen lines ({addr, port, ssl}), as nixpkgs' nginx
  # module computes them (nixos/modules/services/web-servers/nginx).
  nginx = config.services.nginx;
  vhost = nginx.virtualHosts.${cfg.virtualHost};
  isSocket = lib.hasPrefix "unix:";
  withDefaultPorts = lines: let
    complete = ssl: port: line:
      {
        port =
          if isSocket line.addr
          then null
          else port;
        inherit ssl;
      }
      // line;
  in
    lib.optionals (vhost.onlySSL || vhost.addSSL || vhost.forceSSL || vhost.rejectSSL)
    (map (complete true nginx.defaultSSLListenPort) (lib.filter (line: line.ssl or true) lines))
    ++ lib.optionals (!vhost.onlySSL)
    (map (complete false nginx.defaultHTTPListenPort) (lib.filter (line: !(line.ssl or false)) lines));
  listen =
    if vhost.listen != []
    then vhost.listen
    else if nginx.defaultListen != []
    then withDefaultPorts (map (lib.filterAttrs (_: value: value != null)) nginx.defaultListen)
    else
      withDefaultPorts (map (addr: {inherit addr;}) (
        if vhost.listenAddresses != []
        then vhost.listenAddresses
        else nginx.defaultListenAddresses
      ));
  # Lines reachable from other machines: not on loopback addresses or
  # sockets.  Given none at all, nginx listens on port 80 of every address.
  exposedListen =
    if listen == []
    then [
      {
        addr = "*";
        port = 80;
        ssl = false;
      }
    ]
    else lib.filter (line: !(isLoopback line.addr || isSocket line.addr)) listen;
  exposed = lib.unique (map (line: line.addr) exposedListen);
  # A listen line without a port listens on port 80.
  ports = lines:
    lib.unique (map (line:
      if line.port == null
      then 80
      else line.port)
    lines);

  # Where the proxy reaches the API: one of its addresses, a loopback one if
  # there is one, with a wildcard replaced by the loopback address.
  apiHost = let
    address = lib.findFirst isLoopback (lib.head api.addresses) api.addresses;
  in
    if address == "0.0.0.0"
    then "127.0.0.1"
    else if address == "::"
    then "[::1]"
    else if lib.hasInfix ":" address && !lib.hasPrefix "[" address
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

        virtualHost = mkOption {
          type = types.str;
          default = "shelly-manager";
          description = ''
            Name of the nginx virtual host serving the interface, in
            `services.nginx.virtualHosts`.  Configure TLS, listen addresses and
            the like there.

            The default is a name of its own, so that the interface is not
            merged into another virtual host by accident.
          '';
        };

        serverName = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "shelly.example.com";
          description = ''
            Host name under which the interface is served: the virtual host's
            `serverName`.  When null, the virtual host does not set one, and
            nginx uses `virtualHost`.
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
          description = ''
            Open the ports the virtual host listens on in the firewall, other
            than on loopback addresses and sockets: those of its `listen`
            lines, or else of nginx's default listen settings.  With `quic`,
            this includes their UDP ports.
          '';
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
      {
        assertion = !proxyApi || api.authTokenFile != null || api.allowUnauthenticatedAccess || exposed == [];
        message = "services.shelly-manager.web: virtual host ${cfg.virtualHost} serves the API (at /api) on ${lib.concatStringsSep ", " exposed} without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true.";
      }
    ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = ports exposedListen;
      allowedUDPPorts = lib.mkIf vhost.quic (ports (lib.filter (line: line.ssl) exposedListen));
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.virtualHost} = {
        serverName = lib.mkIf (cfg.serverName != null) cfg.serverName;
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
