{
  inputs,
  lib,
  self,
  ...
}: {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: {
    checks =
      lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        nixos-shelly-deploy = pkgs.testers.runNixOSTest (import ./tests/nixos/shelly-deploy.nix {inherit self;});
        nixos-shelly-manager = pkgs.testers.runNixOSTest (import ./tests/nixos/shelly-manager.nix {inherit self;});
      }
      // {
        inherit (config.packages) shelly-deploy;

        module-eval = pkgs.callPackage ./tests/eval.nix {shellyLib = self.lib;};

        flake-parts-module = pkgs.callPackage ./tests/flake-parts.nix {inherit inputs self system;};

        # flake-compat, as `default.nix` uses it, exposes the same outputs to
        # Nix without flakes.  (`src = self` rather than `default.nix`'s
        # `./.`, which flake-compat copies again in pure evaluation.)
        flake-compat = let
          compat = (import inputs.flake-compat {src = self;}).defaultNix;
          sameDrv = a: b: a.drvPath == b.drvPath;
        in
          assert sameDrv compat.packages.${system}.shelly-deploy config.packages.shelly-deploy;
          assert (compat.lib.shellyConfiguration {}).config.build.manifest
          == {
            version = 1;
            devices = {};
          };
          assert builtins.attrNames compat.nixosModules == builtins.attrNames self.nixosModules;
            pkgs.emptyFile;
      };
  };
}
