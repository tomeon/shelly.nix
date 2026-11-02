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
  apiAndWeb = {
    services.shelly-manager.api.enable = true;
    services.shelly-manager.web.enable = true;
  };
  webRefusal = "services.shelly-manager.web: nixos serves the API (at /api) on 0.0.0.0 without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true.";
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
        services.nginx.virtualHosts.nixos.listenAddresses = ["127.0.0.1" "[::1]"];
      };
      expected = none;
    };

    testProxyOnNoAddressMeansAllAddresses = {
      expr =
        (complaints {
          imports = [apiAndWeb];
          services.nginx.defaultListenAddresses = [];
        }).failed;
      expected = ["services.shelly-manager.web: nixos serves the API (at /api) on * without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
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
          listenAddress = "0.0.0.0";
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
          listenAddress = "127.0.0.2";
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
            listenAddress = "127.office.lan";
          };
        }).failed;
      expected = ["services.shelly-manager.api: the API listens on 127.office.lan without authentication; set services.shelly-manager.api.authTokenFile, or services.shelly-manager.api.allowUnauthenticatedAccess = true."];
    };

    # Not canonical IPv4 addresses, so looked up as host names.
    testApiOnMalformedLoopbackAddresses = {
      expr = map (listenAddress:
        lib.length
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            inherit listenAddress;
          };
        }).failed) ["127.0.0.999" "127.000.0.1" "127.0.0.01" "127.0.0.1.lan"];
      expected = [1 1 1 1];
    };

    testApiOnLoopbackAddressBounds = {
      expr = map (listenAddress:
        (complaints {
          services.shelly-manager.api = {
            enable = true;
            inherit listenAddress;
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
            extraArgs = ["--proxy-headers" "--host" "0.0.0.0" "--port=9000" "--uds" "/run/x" "--fd=3"];
          };
        }).failed;
      expected = ["services.shelly-manager.api.extraArgs: --host, --port=9000, --uds, --fd=3 would change where the API listens, past the authentication check; use listenAddress and port."];
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
          listenAddress = "0.0.0.0";
          authTokenFile = token;
        };
      };
      expected = none;
    };

    testApiOnNetworkAllowedWithoutToken = {
      expr = complaints {
        services.shelly-manager.api = {
          enable = true;
          listenAddress = "0.0.0.0";
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
