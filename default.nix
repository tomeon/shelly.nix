# Entry point for Nix without flakes: this flake's outputs, via flake-compat.
#
#   let
#     shelly-nix = import (builtins.fetchTarball "https://github.com/tomeon/shelly.nix/archive/main.tar.gz");
#   in
#     shelly-nix.lib.shellyConfiguration {modules = [./shelly.nix];}
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  inherit (lock.nodes.${lock.nodes.root.inputs.flake-compat}) locked;
  flake-compat = builtins.fetchTarball {
    url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
in
  (import flake-compat {src = ./.;}).defaultNix
