{
  perSystem = {
    lib,
    pkgs,
    ...
  }: let
    # Packages with dependency hashes (`npmDepsHash`, `cargoHash`,
    # `vendorHash`, ...) that nvfetcher does not manage.  `update-hashes`
    # refreshes these with nix-update after `update-sources` has bumped `src`.
    nixUpdatePackages = ["shelly-manager-web"];

    cdToplevel = ''
      cd "''${TOPLEVEL?}" || exit
    '';
  in {
    devshells.default = {
      env = lib.mkAfter [
        # Prefer the git toplevel: devshell sets `PRJ_ROOT` to `$PWD` at entry,
        # which is wrong if the shell was entered from a subdirectory.
        {
          name = "TOPLEVEL";
          eval = ''
            $(${lib.getExe pkgs.gitMinimal} rev-parse --show-toplevel 2>/dev/null || printf -- '%s' "$PRJ_ROOT")
          '';
        }
      ];

      commands =
        map (package: {
          inherit package;
          category = "tools";
        }) [
          pkgs.act
          pkgs.flake-edit
          pkgs.nix-update
          pkgs.nvfetcher
        ]
        ++ map (cmd: cmd // {category = "maintenance";}) [
          {
            name = "update-sources";
            help = "Update nvfetcher-managed sources in nix/pkgs/_sources";
            command = ''
              ${cdToplevel}
              exec ${lib.getExe pkgs.nvfetcher} \
                --config nix/pkgs/nvfetcher.toml \
                --build-dir nix/pkgs/_sources \
                "$@"
            '';
          }
          {
            name = "update-hashes";
            help = "Update dependency hashes not managed by nvfetcher (nix-update)";
            command = ''
              ${cdToplevel}
              # nvfetcher owns `src` and `version`; only touch dependency hashes.
              attrs=(${lib.escapeShellArgs nixUpdatePackages})
              for attr in "''${attrs[@]}"; do
                ${lib.getExe pkgs.nix-update} --flake --version=skip --no-src "$@" "$attr"
              done
            '';
          }
          {
            name = "dedupe-inputs";
            help = "Add/remove `follows` to de-duplicate flake inputs (flake-edit)";
            command = ''
              ${cdToplevel}
              exec ${lib.getExe pkgs.flake-edit} follow "$@"
            '';
          }
          {
            name = "update-all";
            help = "Run update-sources, update-hashes, and dedupe-inputs in order";
            command = ''
              update-sources
              update-hashes
              dedupe-inputs
            '';
          }
        ];
    };
  };
}
