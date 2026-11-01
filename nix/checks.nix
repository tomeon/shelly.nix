{self, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks = {
      inherit (config.packages) shelly-deploy;

      module-eval = pkgs.callPackage ./tests/eval.nix {shellyLib = self.lib;};
    };
  };
}
