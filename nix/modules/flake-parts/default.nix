# flake-parts module: Shelly configurations as flake outputs.
#
#   shelly.configurations.home = ./shelly;
#
# becomes `flake.shellyConfigurations.home`, which `shelly-deploy` reads
# (`shelly-deploy switch --flake .#home`), and a check that the configuration
# evaluates, so that `nix flake check` catches failed assertions.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  shellyLib = import ../../lib {inherit lib;};
in {
  options = {
    shelly.configurations = mkOption {
      type = types.lazyAttrsOf types.deferredModule;
      default = {};
      example = lib.literalExpression ''
        {
          home = {
            imports = [./shelly];
            fleet.devices.porch.components."switch:0".name = "Porch light";
          };
        }
      '';
      description = ''
        Shelly configurations: modules for the generic Shelly module, each
        evaluated into `flake.shellyConfigurations.<name>`.
      '';
    };

    flake.shellyConfigurations = mkOption {
      type = types.lazyAttrsOf types.raw;
      default = {};
      description = ''
        Evaluated Shelly configurations, as returned by
        `lib.shellyConfiguration`.  `shelly-deploy --flake .#<name>` reads
        `shellyConfigurations.<name>.config.build.manifest`.
      '';
    };
  };

  config = {
    flake.shellyConfigurations =
      lib.mapAttrs (_: module: shellyLib.shellyConfiguration {modules = [module];})
      config.shelly.configurations;

    perSystem = {pkgs, ...}: {
      checks = lib.mapAttrs' (name: configuration:
        lib.nameValuePair "shelly-${name}" (
          pkgs.writeText "shelly-${name}-manifest.json"
          (builtins.toJSON configuration.config.build.manifest)
        ))
      config.flake.shellyConfigurations;
    };
  };
}
