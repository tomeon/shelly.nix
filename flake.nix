{
  description = "Declarative tools for managing Shelly devices";

  inputs = {
    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";

    # For `default.nix`, the entry point for Nix without flakes.
    flake-compat.url = "github:edolstra/flake-compat";
    flake-compat.flake = false;

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({
      flake-parts-lib,
      inputs,
      lib,
      moduleWithSystem,
      self,
      ...
    }: {
      imports = [
        inputs.devshell.flakeModule
        inputs.flake-parts.flakeModules.modules
        inputs.treefmt-nix.flakeModule
        ./nix/checks.nix
        ./nix/devshells.nix
      ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem = {
        config,
        pkgs,
        ...
      }: {
        packages = let
          sources = pkgs.callPackage ./nix/pkgs/_sources/generated.nix {};
          shellyManagerPackages = pkgs.callPackages (import ./nix/pkgs/shelly-manager {inherit sources;}) {};
        in {
          inherit
            (shellyManagerPackages)
            shelly-manager
            shelly-manager-api
            shelly-manager-cli
            shelly-manager-core
            shelly-manager-web
            ;

          shelly-deploy = pkgs.callPackage ./nix/pkgs/shelly-deploy {
            inherit (shellyManagerPackages) shelly-manager-core;
          };

          default = config.packages.shelly-manager;
        };

        treefmt = let
          nixCommon = {
            enable = true;
            excludes = ["nix/pkgs/_sources/generated.nix"];
          };
        in {
          flakeFormatter = true;
          projectRootFile = "flake.nix";
          programs.alejandra = nixCommon;
          programs.deadnix =
            nixCommon
            // {
              no-lambda-pattern-names = true;
            };
          programs.statix = nixCommon;
          programs.ruff-check.enable = true;
          programs.ruff-format.enable = true;
          programs.shfmt.enable = true;
          programs.shellcheck.enable = true;
        };
      };

      flake = {
        lib = import ./nix/lib {inherit lib;};

        modules = let
          importModule = lib.flip flake-parts-lib.importApply {inherit moduleWithSystem;};
        in {
          flake = let
            shelly = ./nix/modules/flake-parts;
          in {
            inherit shelly;
            default = shelly;
          };

          nixos = let
            modules = lib.genAttrs' ["api" "cli" "web"] (type: let
              name = "shelly-manager-${type}";
            in {
              inherit name;
              value = importModule (./nix/modules/nixos + "/${name}.nix");
            });

            shelly-manager = {
              imports = builtins.attrValues modules;
            };
          in
            modules
            // {
              inherit shelly-manager;
              default = shelly-manager;
            };

          # The generic module needs no packages, hence no `moduleWithSystem`.
          shelly = let
            shelly-manager = ./nix/modules/shelly;
          in {
            inherit shelly-manager;
            default = shelly-manager;
          };
        };

        flakeModules = self.modules.flake;
        nixosModules = self.modules.nixos;
      };
    });
}
