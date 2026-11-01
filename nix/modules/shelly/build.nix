# Module-system plumbing shared by every namespace: assertions, warnings, and
# the manifest that namespaces contribute to.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  failedAssertions = map (x: x.message) (lib.filter (x: !x.assertion) config.assertions);
in {
  options = {
    assertions = mkOption {
      type = types.listOf (types.submodule {
        options = {
          assertion = mkOption {
            type = types.bool;
            description = "Condition that must hold.";
          };
          message = mkOption {
            type = types.str;
            description = "Error shown when `assertion` is false.";
          };
        };
      });
      default = [];
      internal = true;
      description = ''
        Conditions checked when `build.manifest` is evaluated, as in NixOS.
      '';
    };

    warnings = mkOption {
      type = types.listOf types.str;
      default = [];
      internal = true;
      description = ''
        Messages printed when `build.manifest` is evaluated, as in NixOS.
      '';
    };

    build.manifest = mkOption {
      type = types.lazyAttrsOf types.raw;
      default = {};
      description = ''
        The JSON document that `shelly-deploy` reads.  Each namespace
        contributes its own attribute.  Evaluating it checks `assertions` and
        prints `warnings`.
      '';
      apply = manifest:
        if failedAssertions != []
        then throw "\nFailed assertions:\n${lib.concatMapStrings (m: "- ${m}\n") failedAssertions}"
        else lib.showWarnings config.warnings ({version = 1;} // manifest);
    };
  };
}
