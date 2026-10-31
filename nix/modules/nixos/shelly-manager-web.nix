{moduleWithSystem}:
moduleWithSystem ({} @ perSystem: {lib, ...}: let
  inherit (lib) mkOption types;
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
      };
    };
  };
})
