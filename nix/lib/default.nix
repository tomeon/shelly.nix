{lib}: {
  /**
  Evaluate Shelly configuration modules with the generic Shelly module.

  The result is a `lib.evalModules` result; `shelly-deploy` reads its
  `config.build.manifest`.

  # Inputs

  `modules`
  : A module or a list of modules.

  Other arguments (`specialArgs`, `prefix`) are passed to `lib.evalModules`.
  `class` is always `"shelly"`.

  # Example

  ```nix
  shellyConfiguration {
    modules = [
      {fleet.devices.porch.components."switch:0".name = "Porch light";}
    ];
  }
  ```
  */
  shellyConfiguration = {modules ? [], ...} @ args:
    lib.evalModules (args
      // {
        class = "shelly";
        modules = [../modules/shelly] ++ lib.toList modules;
      });
}
