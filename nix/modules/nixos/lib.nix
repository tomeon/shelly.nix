# Helpers shared by the NixOS modules.
{lib}: {
  # Whether a listen address is reachable only from this machine.  Numeric
  # addresses only: a host name (even "localhost", or one starting "127.")
  # could resolve to anything.
  isLoopback = address:
    builtins.match "127(\\.[0-9]{1,3}){3}" address
    != null
    || lib.elem address ["::1" "[::1]"]
    || lib.hasPrefix "unix:" address;
}
