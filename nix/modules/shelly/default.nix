{moduleWithSystem}:
moduleWithSystem ({} @ perSystem: {lib, ...}: let
  inherit (lib) mkOption types;
in {
  options = {
    devices = mkOption {
      description = "Shelly devices and associated options.";
      default = {};
      type = types.submodule (devices: {
        options = {
          defaults = mkOption {
            type = types.deferredModule;
            default = {};
            description = ''
              Configuration applied to all entries in `devices.devices`.
            '';
          };

          devices = mkOption {
            default = {};
            type = types.attrsOf (types.submodule ({name, ...}: {
              imports = [devices.defaults];

              options = {
                device = mkOption {
                  type = types.nonEmptyStr;
                  default = name;
                  description = ''
                    Host name or IP address identifying the device.
                  '';
                };

                package = mkOption {
                  type = types.package;
                  default = perSystem.config.packages.shelly-manager;
                  description = ''
                    Package providing shelly-manager.
                  '';
                };

                extraArgs = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = ''
                  '';
                };
              };
            }));
          };
        };
      });
    };
  };

  config = {};
})
