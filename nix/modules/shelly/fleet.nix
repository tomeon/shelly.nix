# The `fleet` namespace: the devices to deploy and what to deploy to them.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.fleet;

  # Component keys as Shelly reports them: `sys`, `mqtt`, `switch:0`, ...
  componentKeyPattern = "[a-z][a-z0-9_]*(:[0-9]+)?";

  # Components whose misconfiguration can leave a device unreachable.
  networkComponents = ["wifi" "eth"];

  isStorePath = lib.hasPrefix "${builtins.storeDir}/";

  # Every `{ _secret = ...; }` placeholder in a value, as `{ path; secret; }`.
  findSecrets = path: value:
    if lib.isAttrs value
    then
      if value ? _secret
      then [{inherit path value;}]
      else lib.concatLists (lib.mapAttrsToList (k: findSecrets (path ++ [k])) value)
    else if lib.isList value
    then lib.concatLists (lib.imap0 (i: findSecrets (path ++ [(toString i)])) value)
    else [];

  deviceAssertions = name: device: let
    where = "fleet.devices.${lib.strings.escapeNixIdentifier name}";
    componentKeys = lib.attrNames device.components;
    secrets = lib.concatLists (lib.mapAttrsToList (key: findSecrets [key]) device.components);
    showPath = path: lib.concatStringsSep "." path;
  in
    map (key: {
      assertion = builtins.match componentKeyPattern key != null;
      message = "${where}.components: `${key}` is not a component key (expected e.g. `sys`, `mqtt` or `switch:0`).";
    })
    componentKeys
    ++ map (key: {
      assertion = device.deployment.allowNetworkChanges || !(lib.elem key componentKeys);
      message = "${where}.components.${key}: a mistake in `${key}` can leave the device unreachable; set `${where}.deployment.allowNetworkChanges = true` to manage it anyway.";
    })
    networkComponents
    ++ lib.concatMap (s: let
      secret = s.value._secret;
    in [
      {
        assertion = lib.attrNames s.value == ["_secret"];
        message = "${where}.components.${showPath s.path}: a `_secret` placeholder must have no other attributes.";
      }
      {
        assertion = lib.isString secret && lib.hasPrefix "/" secret && !isStorePath secret;
        message = "${where}.components.${showPath s.path}._secret: must be an absolute path (a string) outside the Nix store.";
      }
    ])
    secrets;

  toManifest = device: {
    inherit (device) address mac tags components;
    auth = {inherit (device.auth) passwordFile;};
    deployment = {inherit (device.deployment) allowNetworkChanges reboot;};
  };
in {
  options.fleet = {
    defaults = mkOption {
      type = types.deferredModule;
      default = {};
      example = lib.literalExpression ''
        {name, ...}: {
          auth.passwordFile = "/run/secrets/shelly";
          components.sys.device.name = lib.mkDefault name;
        }
      '';
      description = ''
        A module applied to every device in `fleet.devices`.  Definitions here
        have normal priority: use `lib.mkDefault` for values that individual
        devices may override.
      '';
    };

    devices = mkOption {
      type = types.attrsOf (types.submoduleWith {
        shorthandOnlyDefinesConfig = true;
        modules = [
          ./device.nix
          {imports = [cfg.defaults];}
        ];
      });
      default = {};
      example = lib.literalExpression ''
        {
          porch = {
            address = "192.168.1.50";
            mac = "AA:BB:CC:DD:EE:FF";
            components."switch:0".name = "Porch light";
          };
        }
      '';
      description = ''
        Shelly devices, keyed by a name of your choosing.
      '';
    };
  };

  config = {
    assertions = lib.concatLists (lib.mapAttrsToList deviceAssertions cfg.devices);
    build.manifest.devices = lib.mapAttrs (_: toManifest) cfg.devices;
  };
}
