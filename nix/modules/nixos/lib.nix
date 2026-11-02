# Helpers shared by the NixOS modules.
{lib}: {
  # Whether a listen address is reachable only from this machine.
  isLoopback = address:
    address
    == "localhost"
    || lib.hasPrefix "127." address
    || lib.elem address ["::1" "[::1]"]
    || lib.hasPrefix "unix:" address;
}
