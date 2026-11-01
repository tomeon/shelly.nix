{
  inputs,
  self,
  ...
}: {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: {
    checks = {
      inherit (config.packages) shelly-deploy;

      module-eval = pkgs.callPackage ./tests/eval.nix {shellyLib = self.lib;};

      flake-parts-module = pkgs.callPackage ./tests/flake-parts.nix {inherit inputs self system;};
    };
  };
}
