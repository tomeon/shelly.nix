# flake-parts module: Shelly configurations as flake outputs.
#
#   shelly.configurations.home = ./shelly;
#
# becomes `flake.shellyConfigurations.home`, which `shelly-deploy` reads
# (`shelly-deploy switch --flake .#home`), and, unless `shelly.flakeCheck` is
# false, a check that the configuration evaluates.
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

    shelly.flakeCheck = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to add a check, `checks.<system>.shelly-<name>`, for each of
        `shelly.configurations`, so that `nix flake check` catches failed
        assertions.
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
      checks = lib.mkIf config.shelly.flakeCheck (lib.mapAttrs' (name: configuration:
        lib.nameValuePair "shelly-${name}" (
          pkgs.writeText "shelly-${name}-manifest.json"
          (builtins.toJSON configuration.config.build.manifest)
        ))
      config.flake.shellyConfigurations);
    };
  };
}
