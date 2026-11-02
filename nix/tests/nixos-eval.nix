# Evaluation tests for the NixOS modules' warnings.
{
  inputs,
  lib,
  runCommand,
  self,
  system,
}: let
  warningsOf = module:
    lib.filter (lib.hasPrefix "services.shelly-manager")
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
    .config
    .warnings;

  token = "/run/secrets/shelly-manager-token";

  results = lib.runTests {
    testProxiedApiWithoutTokenWarns = {
      expr = map (lib.hasPrefix "services.shelly-manager.web.openFirewall") (warningsOf {
        services.shelly-manager.api.enable = true;
        services.shelly-manager.web = {
          enable = true;
          openFirewall = true;
        };
      });
      expected = [true];
    };

    testProxiedApiWithTokenDoesNotWarn = {
      expr = warningsOf {
        services.shelly-manager.api = {
          enable = true;
          authTokenFile = token;
        };
        services.shelly-manager.web = {
          enable = true;
          openFirewall = true;
        };
      };
      expected = [];
    };

    testClosedFirewallDoesNotWarn = {
      expr = warningsOf {
        services.shelly-manager.api.enable = true;
        services.shelly-manager.web.enable = true;
      };
      expected = [];
    };

    testOpenApiWithoutTokenWarns = {
      expr = map (lib.hasPrefix "services.shelly-manager.api.openFirewall") (warningsOf {
        services.shelly-manager.api = {
          enable = true;
          listenAddress = "0.0.0.0";
          openFirewall = true;
        };
      });
      expected = [true];
    };

    testOpenApiWithTokenDoesNotWarn = {
      expr = warningsOf {
        services.shelly-manager.api = {
          enable = true;
          listenAddress = "0.0.0.0";
          openFirewall = true;
          authTokenFile = token;
        };
      };
      expected = [];
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
