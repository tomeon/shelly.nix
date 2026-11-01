{moduleWithSystem}:
moduleWithSystem ({config, ...} @ perSystem: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.shelly-manager.cli;
in {
  options = {
    programs.shelly-manager = {
      cli = {
        enable = lib.mkEnableOption "the shelly-manager CLI";

        package = mkOption {
          type = types.package;
          default = perSystem.config.packages.shelly-manager-cli;
          defaultText = "<shelly-manager-cli>";
          description = ''
            Package providing the shelly-manager CLI.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];
  };
})
