{lib}: {
  /**
  Evaluate Shelly configuration modules with the generic Shelly module.

  The result is a `lib.evalModules` result; `shelly-deploy` reads its
  `config.build.manifest`.

  # Example

  ```nix
  shellyConfiguration {
    modules = [
      {fleet.devices.porch.components."switch:0".name = "Porch light";}
    ];
  }
  ```
  */
  shellyConfiguration = {
    modules ? [],
    specialArgs ? {},
  }:
    lib.evalModules {
      class = "shelly";
      modules = [../modules/shelly] ++ modules;
      inherit specialArgs;
    };
}
