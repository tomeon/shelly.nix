# Evaluation tests for the NixOS modules: unauthenticated API exposure is
# refused unless explicitly allowed.
{
  inputs,
  lib,
  runCommand,
  self,
  system,
}: let
  evalConfig = module:
    (inputs.nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.default
        {
          nixpkgs.hostPlatform = system;
          boot.isContainer = true;
          system.stateVersion = lib.trivial.release;
        }
        module
      ];
    })
    .config;

  ours = lib.filter (lib.hasPrefix "services.shelly-manager");

  # The modules' failed assertions and warnings.
  complaints = module: let
    config = evalConfig module;
  in {
    failed = ours (map (a: a.message) (lib.filter (a: !a.assertion) config.assertions));
    warnings = ours config.warnings;
  };

  token = "/run/secrets/shelly-manager-token";
  withToken.services.shelly-manager.api.authTokenFile = token;
  apiAndWeb = {
    services.shelly-manager.api.enable = true;
    services.shelly-manager.web.enable = true;
  };
  webRefusal = "services.shelly-manager.web: virtual host shelly-manager serves the API (at /api) on 0.0.0.0 without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true.";
  apiRefusal = "services.shelly-manager.api: the API listens on 0.0.0.0 without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true.";
  none = {
    failed = [];
    warnings = [];
  };

  results = lib.runTests {
    testProxiedApiWithoutTokenIsRefused = {
      expr = complaints {
        imports = [apiAndWeb];
        networking.enableIPv6 = false;
      };
      expected = {
        failed = [webRefusal];
        warnings = [];
      };
    };

    testProxiedApiWithToken = {
      expr = complaints {
        imports = [apiAndWeb];
        services.shelly-manager.api.authTokenFile = token;
      };
      expected = none;
    };

    testProxiedApiAllowedWithoutToken = {
      expr = complaints {
        imports = [apiAndWeb];
        services.shelly-manager.api.allowUnauthenticatedAccess = true;
      };
      expected = none;
    };

    testProxyOnLoopbackOnly = {
      expr = complaints {
        imports = [apiAndWeb];
        services.nginx.virtualHosts.shelly-manager.listenAddresses = ["127.0.0.1" "[::1]"];
      };
      expected = none;
    };

    testProxyOnUnixSocket = {
      expr = complaints {
        imports = [apiAndWeb];
        services.nginx.virtualHosts.shelly-manager.listen = [{addr = "unix:/run/nginx/shelly.sock";}];
      };
      expected = none;
    };

    testProxyOnNoAddressMeansAllAddresses = {
      expr =
        (complaints {
          imports = [apiAndWeb];
          services.nginx.defaultListenAddresses = [];
        }).failed;
      expected = ["services.shelly-manager.web: virtual host shelly-manager serves the API (at /api) on * without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
    };

    # The interface gets a virtual host of its own unless told otherwise.
    testWebVirtualHost = {
      expr = map (module: let
        nginx = (evalConfig {imports = [apiAndWeb withToken module];}).services.nginx;
      in
        lib.mapAttrs (_: vhost: vhost.serverName) (lib.filterAttrs (_: vhost: vhost.root != null) nginx.virtualHosts)) [
        {}
        {services.shelly-manager.web.serverName = "shelly.lan";}
        {services.shelly-manager.web.virtualHost = "shelly.lan";}
      ];
      expected = [
        {shelly-manager = null;}
        {shelly-manager = "shelly.lan";}
        {"shelly.lan" = null;}
      ];
    };

    testFirewallFollowsListenSettings = {
      expr =
        map (module: let
          inherit ((evalConfig {imports = [apiAndWeb withToken module {services.shelly-manager.web.openFirewall = true;}];}).networking.firewall) allowedTCPPorts allowedUDPPorts;
        in {
          tcp = lib.sort lib.lessThan allowedTCPPorts;
          udp = allowedUDPPorts;
        }) [
          {}
          {services.nginx.virtualHosts.shelly-manager.addSSL = true;}
          {services.nginx.virtualHosts.shelly-manager.onlySSL = true;}
          {
            services.nginx.virtualHosts.shelly-manager = {
              onlySSL = true;
              quic = true;
            };
          }
          {services.nginx.defaultHTTPListenPort = 8080;}
          {
            services.nginx.virtualHosts.shelly-manager.listen = [
              {
                addr = "0.0.0.0";
                port = 8443;
                ssl = true;
              }
              {
                addr = "127.0.0.1";
                port = 9000;
              }
              {addr = "unix:/run/nginx/shelly.sock";}
            ];
          }
        ];
      expected = [
        {
          tcp = [80];
          udp = [];
        }
        {
          tcp = [80 443];
          udp = [];
        }
        {
          tcp = [443];
          udp = [];
        }
        {
          tcp = [443];
          udp = [443];
        }
        {
          tcp = [8080];
          udp = [];
        }
        {
          tcp = [8443];
          udp = [];
        }
      ];
    };

    # One socket per address; IPv6 loopback too, where IPv6 is enabled.
    testApiAddresses = {
      expr = map (enableIPv6: let
        config = evalConfig {
          services.shelly-manager.api.enable = true;
          networking.enableIPv6 = enableIPv6;
        };
      in {
        inherit (config.services.shelly-manager.api) addresses;
        inherit (config.systemd.sockets.shelly-manager-api) listenStreams;
      }) [true false];
      expected = [
        {
          addresses = ["127.0.0.1" "::1"];
          listenStreams = ["127.0.0.1:8000" "[::1]:8000"];
        }
        {
          addresses = ["127.0.0.1"];
          listenStreams = ["127.0.0.1:8000"];
        }
      ];
    };

    testApiRefusalNamesExposedAddressesOnly = {
      expr =
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            addresses = ["127.0.0.1" "192.168.1.5" "::1" "::"];
          };
        }).failed;
      expected = ["services.shelly-manager.api: the API listens on 192.168.1.5, :: without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
    };

    # The proxy prefers a loopback address, and replaces a wildcard with one.
    testProxyTarget = {
      expr = map (addresses:
        (evalConfig {
          imports = [apiAndWeb withToken];
          services.shelly-manager.api.addresses = addresses;
        }).services.nginx.virtualHosts.shelly-manager.locations."/api/".proxyPass) [
        ["192.168.1.5" "::1"]
        ["0.0.0.0"]
        ["::"]
        ["192.168.1.5"]
      ];
      expected = [
        "http://[::1]:8000"
        "http://127.0.0.1:8000"
        "http://[::1]:8000"
        "http://192.168.1.5:8000"
      ];
    };

    testRemoteApiIsNotThisMachinesConcern = {
      expr = complaints {
        services.shelly-manager.web = {
          enable = true;
          apiUrl = "https://shelly-api.example.com";
        };
      };
      expected = none;
    };

    testApiOnLoopbackWithoutToken = {
      expr = complaints {services.shelly-manager.api.enable = true;};
      expected = none;
    };

    testApiOnNetworkWithoutTokenIsRefused = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          addresses = ["0.0.0.0"];
        };
      };
      expected = {
        failed = [apiRefusal];
        warnings = [];
      };
    };

    testApiOnOtherLoopbackAddress = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          addresses = ["127.0.0.2"];
        };
      };
      expected = none;
    };

    # Host names are not trusted to be loopback, whatever they look like.
    testApiOnLoopbackLookingHostName = {
      expr =
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            addresses = ["127.office.lan"];
          };
        }).failed;
      expected = ["services.shelly-manager.api: the API listens on 127.office.lan without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
    };

    # Not canonical IPv4 addresses, so looked up as host names.
    testApiOnMalformedLoopbackAddresses = {
      expr = map (address:
        lib.length
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            addresses = [address];
          };
        }).failed) ["127.0.0.999" "127.000.0.1" "127.0.0.01" "127.0.0.1.lan"];
      expected = [1 1 1 1];
    };

    # uvicorn's --host takes no socket path: it is looked up as a name.
    testApiOnUnixLookingHostName = {
      expr =
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            addresses = ["unix:api"];
          };
        }).failed;
      expected = ["services.shelly-manager.api: the API listens on unix:api without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
    };

    testApiOnLoopbackAddressBounds = {
      expr = map (address:
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            addresses = [address];
          };
        }).failed) ["127.255.255.255" "127.0.0.0" "127.10.200.9"];
      expected = [[] [] []];
    };

    testExtraArgsCannotMoveTheListener = {
      expr =
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            authTokenFile = token;
            extraArgs = ["--proxy-headers" "--host" "0.0.0.0" "--port=9000" "--uds" "/run/x" "--fd=3" "--workers=2" "--reload"];
          };
        }).failed;
      expected = ["services.shelly-manager.api.extraArgs: --host, --port=9000, --uds, --fd=3, --workers=2, --reload would change where the API listens, past the authentication check; use addresses and port."];
    };

    testExtraArgsOtherwiseAllowed = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          extraArgs = ["--proxy-headers" "--forwarded-allow-ips" "127.0.0.1"];
        };
      };
      expected = none;
    };

    testApiOnNetworkWithToken = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          addresses = ["0.0.0.0"];
          authTokenFile = token;
        };
      };
      expected = none;
    };

    testApiOnNetworkAllowedWithoutToken = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          addresses = ["0.0.0.0"];
          allowUnauthenticatedAccess = true;
        };
      };
      expected = none;
    };
  };
in
  runCommand "shelly-nixos-module-eval-tests" {
    passAsFile = ["results"];
    results = builtins.toJSON results;
  } ''
    if [ "$(cat "$resultsPath")" != "[]" ]; then
      echo "Failed tests:" >&2
      cat "$resultsPath" >&2
      exit 1
    fi
    touch "$out"
  ''
