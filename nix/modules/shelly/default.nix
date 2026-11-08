# The generic Shelly module.
#
# It depends on nothing but `lib`: evaluating it yields a JSON document,
# `config.build.manifest`, that `shelly-deploy` applies to devices.  Use it
# through `lib.shellyConfiguration`, the flake-parts module, or your own
# `lib.evalModules` call (with `class = "shelly"`).
{
  imports = [
    ./build.nix
    ./fleet.nix
  ];
}
