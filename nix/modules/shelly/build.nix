# Module-system plumbing shared by every namespace: assertions, warnings, and
# the manifest that namespaces contribute to.
{
  config,
  lib,
  ...
}: {
  # `assertions` and `warnings`, as in NixOS.
  imports = [lib.genericModules.assertions];

  options = {
    build.manifest = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = {};
      description = ''
        The JSON document that `shelly-deploy` reads.  Each namespace
        contributes its own attribute.  Evaluating it checks `assertions` and
        prints `warnings`.
      '';
      apply = manifest:
        lib.asserts.checkAssertWarn config.assertions config.warnings
        ({version = 1;} // manifest);
    };
  };
}
