# Helpers shared by the NixOS modules.
{lib}: {
  # Whether a listen address is a loopback IP address.  Numeric addresses
  # only, in canonical form: anything else (a host name, even "localhost" or
  # one starting "127.", or an out-of-range or zero-padded octet) is looked up
  # as a name, and could resolve to anything.
  isLoopback = let
    octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  in
    address:
      builtins.match "127\\.${octet}\\.${octet}\\.${octet}" address
      != null
      || lib.elem address ["::1" "[::1]"];
}
