# Tests for the flake-parts module, using a flake evaluated on the spot.
{
  inputs,
  lib,
  runCommand,
  self,
  system,
}: let
  testInputs = {
    inherit (inputs) nixpkgs;
    self = {
      outPath = ./.;
      inputs = testInputs;
    };
  };

  eval =
    inputs.flake-parts.lib.evalFlakeModule {
      inputs = testInputs;
      moduleLocation = "${toString ./.}/flake-parts.nix#test-flake";
    } {
      imports = [self.flakeModules.default];
      systems = [system];
      shelly.configurations = {
        example.fleet.devices.porch.components."switch:0".name = "Porch";
        broken.fleet.devices.d.components.wifi.sta.ssid = "unchecked";
      };
    };

  inherit (eval.config) flake;
  checks = flake.checks.${system};

  results = lib.runTests {
    testConfigurationIsEvaluated = {
      expr = flake.shellyConfigurations.example.config.build.manifest.devices.porch.components;
      expected."switch:0".name = "Porch";
    };

    testEveryConfigurationGetsACheck = {
      expr = builtins.attrNames checks;
      expected = ["shelly-broken" "shelly-example"];
    };

    testFailedAssertionsFailTheCheck = {
      expr = (builtins.tryEval checks.shelly-broken.drvPath).success;
      expected = false;
    };
  };
in
  runCommand "shelly-flake-parts-module-tests" {
    passAsFile = ["results"];
    results = builtins.toJSON results;
    manifest = checks.shelly-example;
  } ''
    if [ "$(cat "$resultsPath")" != "[]" ]; then
      echo "Failed tests:" >&2
      cat "$resultsPath" >&2
      exit 1
    fi
    grep -q '"switch:0"' "$manifest"
    touch "$out"
  ''
