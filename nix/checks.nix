{self, ...}: {
  perSystem = {pkgs, ...}: {
    checks = {
      module-eval = pkgs.callPackage ./tests/eval.nix {shellyLib = self.lib;};
    };
  };
}
