{moduleWithSystem}:
moduleWithSystem ({} @ perSystem: {lib, ...}: let
  inherit (lib) mkOption types;
in {
  options = {
    services.shelly-manager = {
      api = {
        enable = lib.mkEnableOption "the shelly-manager API";
        package = mkOption {
          type = types.package;
          default = perSystem.config.packages.shelly-manager-api;
          defaultText = "<shelly-manager-api>";
          description = ''
            Package providing the shelly-manager API.
          '';
        };
      };
    };
  };
})
