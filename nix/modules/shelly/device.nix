# One device in `fleet.devices`.
{
  lib,
  name,
  ...
}: let
  inherit (lib) mkOption types;

  # Any JSON value.  Unlike `pkgs.formats.json`, paths are rejected: turning one
  # into JSON would copy the file into the world-readable Nix store.
  jsonValue =
    types.nullOr (types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      (types.attrsOf jsonValue)
      (types.listOf jsonValue)
    ])
    // {description = "JSON value";};

  # A path given as a string, so that it is never copied into the Nix store.
  externalFile =
    types.addCheck types.str (s: lib.hasPrefix "/" s && !lib.hasPrefix "${builtins.storeDir}/" s)
    // {description = "absolute path (as a string) outside the Nix store";};

  macPattern = "([0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}";
  normaliseMac = mac: lib.toUpper (lib.replaceStrings [":" "-"] ["" ""] mac);
in {
  options = {
    name = mkOption {
      type = types.str;
      default = name;
      readOnly = true;
      description = "The device's name, i.e. its attribute name in `fleet.devices`.";
    };

    address = mkOption {
      type = types.nonEmptyStr;
      default = name;
      defaultText = lib.literalExpression "name";
      example = "192.168.1.50";
      description = ''
        Host name or IPv4 address at which `shelly-deploy` reaches the device,
        optionally followed by `:port`.  IPv6 is not supported.
      '';
    };

    mac = mkOption {
      type = types.nullOr (types.strMatching macPattern);
      default = null;
      example = "AA:BB:CC:DD:EE:FF";
      apply = mac:
        if mac == null
        then null
        else normaliseMac mac;
      description = ''
        The device's MAC address.  When set, `shelly-deploy` refuses to change
        a device reporting a different one, e.g. after a DHCP lease moved.
      '';
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["outdoor"];
      description = ''
        Tags for selecting devices with `shelly-deploy --on @tag`.
      '';
    };

    auth.passwordFile = mkOption {
      type = types.nullOr externalFile;
      default = null;
      example = "/run/secrets/shelly-admin";
      description = ''
        File holding the device's `admin` password, read by `shelly-deploy` at
        deploy time.  Leave unset for devices without authentication.
      '';
    };

    components = mkOption {
      type = types.attrsOf (types.attrsOf jsonValue);
      default = {};
      example = lib.literalExpression ''
        {
          sys.device.eco_mode = true;
          "switch:0" = {
            name = "Porch light";
            initial_state = "restore_last";
          };
          mqtt = {
            enable = true;
            server = "mqtt.lan:1883";
            user = "shelly";
            pass._secret = "/run/secrets/mqtt-password";
          };
        }
      '';
      description = ''
        Component configuration, keyed by component key (`sys`, `mqtt`,
        `switch:0`, ...).  Each value is the `config` object of the component's
        `SetConfig` RPC call, as documented at
        <https://shelly-api-docs.shelly.cloud/gen2/>.

        Only the fields given here are managed; the device keeps its own values
        for the rest.  Removing a field does not reset it on the device.

        Write `{ _secret = "/path/to/file"; }` in place of a value that must
        stay out of the Nix store; `shelly-deploy` substitutes the file's
        contents (without trailing newlines) at deploy time.

        Scripts are managed with `scripts`, not as `script:<id>` components.
      '';
    };

    scripts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          code = mkOption {
            type = types.str;
            example = lib.literalExpression "builtins.readFile ./motion.js";
            description = "The script's source code.";
          };

          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether the script runs, from now on and at boot.  When false,
              the script is stopped and does not start at boot.
            '';
          };
        };
      });
      default = {};
      example = lib.literalExpression ''
        {
          motion-light.code = builtins.readFile ./motion-light.js;
        }
      '';
      description = ''
        Scripts, keyed by their name on the device.  A script that does not
        exist yet is created.  Scripts on the device that are not declared here
        are left alone: removing a script from this set does not delete it.
      '';
    };

    schedules = mkOption {
      type = types.nullOr (types.listOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether the job runs.";
          };

          timespec = mkOption {
            type = types.nonEmptyStr;
            example = "0 0 7 * * MON-FRI";
            description = ''
              When the job runs, in Shelly's cron-like format (seconds first);
              see <https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Schedule>.
            '';
          };

          calls = mkOption {
            type = types.nonEmptyListOf (types.submodule {
              options = {
                method = mkOption {
                  type = types.nonEmptyStr;
                  example = "Switch.Set";
                  description = "The RPC method to call.";
                };

                params = mkOption {
                  type = types.attrsOf jsonValue;
                  default = {};
                  example = {
                    id = 0;
                    on = true;
                  };
                  description = "The method's parameters.";
                };
              };
            });
            description = "The RPC calls the job makes, in order.";
          };
        };
      }));
      default = null;
      example = lib.literalExpression ''
        [
          {
            timespec = "0 30 22 * * *";
            calls = [{method = "Switch.Set"; params = {id = 0; on = false;};}];
          }
        ]
      '';
      description = ''
        Scheduled jobs.  When null, the device's schedules are left alone.
        Otherwise, they are replaced by these jobs whenever they differ; an
        empty list removes them all.
      '';
    };

    deployment = {
      reboot = mkOption {
        type = types.enum ["if-required" "never"];
        default = "if-required";
        description = ''
          Whether `shelly-deploy` reboots the device when a change reports
          `restart_required`.
        '';
      };

      allowNetworkChanges = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Allow managing the `wifi` and `eth` components.  A mistake there can
          leave the device unreachable, recoverable only by a factory reset.
        '';
      };
    };
  };
}
