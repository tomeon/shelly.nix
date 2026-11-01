# shelly.nix

Declarative configuration for [Shelly](https://www.shelly.com/) devices, built on
[shelly-manager](https://github.com/jfmlima/shelly-manager).

- **The Shelly module** describes devices and their configuration as Nix
  modules. Evaluating it produces a JSON manifest. It needs nothing but
  nixpkgs' `lib`.
- **`shelly-deploy`** applies a manifest to devices: `diff` shows what would
  change, `switch` changes it, in the spirit of `nixos-rebuild`, colmena and
  deploy-rs.
- **A flake-parts module** turns `shelly.configurations.<name>` into
  `shellyConfigurations.<name>` and a `nix flake check` check.
- **NixOS modules** for the shelly-manager API, web interface and CLI.
- **Packages**: `shelly-manager` (`-api`, `-cli`, `-core`, `-web`) and
  `shelly-deploy`.

## Quick start

With flake-parts:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    shelly-nix.url = "github:tomeon/shelly.nix";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.shelly-nix.flakeModules.default];
      systems = ["x86_64-linux"];
      shelly.configurations.home = ./shelly.nix;
    };
}
```

```nix
# shelly.nix
{lib, ...}: {
  fleet.defaults = {name, ...}: {
    auth.passwordFile = "/run/secrets/shelly-admin";
    components.sys.device.name = lib.mkDefault name;
  };

  fleet.devices = {
    porch = {
      address = "192.168.1.50";
      mac = "AA:BB:CC:DD:EE:FF";
      tags = ["outdoor"];
      components = {
        "switch:0" = {
          name = "Porch light";
          initial_state = "restore_last";
        };
        mqtt = {
          enable = true;
          server = "mqtt.lan:1883";
          user = "shelly";
          pass._secret = "/run/secrets/mqtt-password";
        };
      };
    };

    kitchen-plug.address = "kitchen-plug.lan";
  };
}
```

```console
$ nix run github:tomeon/shelly.nix#shelly-deploy -- diff --flake .#home
porch (192.168.1.50): Plus1PM, gen 2, firmware 1.4.4
  ~ mqtt (not reported by the device: pass)
      enable: false -> true
      server: null -> "mqtt.lan:1883"
      user: null -> "shelly"
  ~ switch:0
      initial_state: "match_input" -> "restore_last"
      name: null -> "Porch light"
  = sys
...
$ nix run github:tomeon/shelly.nix#shelly-deploy -- switch --flake .#home --on @outdoor
```

Without flakes, through the flake-compat shim in `default.nix`:

```nix
# fleet.nix
let
  shelly-nix = import (builtins.fetchTarball "https://github.com/tomeon/shelly.nix/archive/main.tar.gz");
in
  shelly-nix.lib.shellyConfiguration {modules = [./shelly.nix];}
```

```console
$ shelly-deploy switch -f fleet.nix
```

`shelly-deploy` is `(import shelly-nix).packages.${system}.shelly-deploy`.

## The Shelly module

Evaluate it with `lib.shellyConfiguration {modules = [...];}` (a
`lib.evalModules` wrapper), with the flake-parts module, or with your own
`lib.evalModules` call using `modules.shelly.default` and `class = "shelly"`.

Options live under namespaces. The `fleet` namespace holds devices:

| Option | Description |
| --- | --- |
| `fleet.defaults` | A module applied to every device. Its definitions have normal priority; use `lib.mkDefault` for values devices may override. |
| `fleet.devices.<name>.address` | Host name or IPv4 address, optionally with `:port`. Defaults to `<name>`. |
| `fleet.devices.<name>.mac` | If set, `shelly-deploy` refuses to change a device reporting another MAC. |
| `fleet.devices.<name>.tags` | For selecting devices with `--on @tag`. |
| `fleet.devices.<name>.auth.passwordFile` | The device's `admin` password, read at deploy time. |
| `fleet.devices.<name>.components.<key>` | Component configuration, keyed `sys`, `mqtt`, `switch:0` and so on: the `config` object of the component's `SetConfig` call, as in the [Gen2+ API documentation](https://shelly-api-docs.shelly.cloud/gen2/). |
| `fleet.devices.<name>.deployment.reboot` | `"if-required"` (default) reboots when a change reports `restart_required`; `"never"` doesn't. |
| `fleet.devices.<name>.deployment.allowNetworkChanges` | Must be set to manage `wifi` or `eth`, where a mistake can leave the device unreachable. |

`build.manifest` is the JSON document `shelly-deploy` reads. Evaluating it
checks `assertions` and prints `warnings`, as in NixOS.

Some semantics to be aware of:

- **Only declared fields are managed.** The device keeps its own values for the
  rest. Removing a field from the configuration does not reset it on the device.
  To roll back, revert the configuration and switch again.
- **Secrets stay out of the store.** Write `{ _secret = "/path"; }` in place of
  a value (the convention of nixpkgs' `utils.genJqSecretsReplacementSnippet`);
  `shelly-deploy` substitutes the file's contents, without trailing newlines.
  Paths must be absolute strings outside the Nix store. Path values (`./x`) are
  rejected everywhere, because turning them into JSON would copy them into the
  store.

## `shelly-deploy`

```
shelly-deploy build  [SOURCE]           evaluate and print the manifest
shelly-deploy diff   [SOURCE] [DEVICES] show what switch would change
shelly-deploy switch [SOURCE] [DEVICES] [--force] [--reboot-timeout S]

SOURCE:  --flake FLAKE#NAME (default .#default) | -f FILE [-A ATTR] | --manifest FILE
DEVICES: --on NAMES,GLOBS,@TAGS (repeatable) --parallel N --timeout S
```

`switch` does the following for each device, several devices at once:

1. It resolves the address, then checks that the device is Gen2 or newer and,
   if `mac` is set, that its MAC matches.
2. It reads `Shelly.GetConfig` and compares the declared fields.
3. It calls `SetConfig` for each component that differs, `wifi` and `eth` last.
4. It reboots once if any change reported `restart_required` and waits for the
   device to come back.
5. It reads the configuration again and fails if any change did not take
   effect.

A failure on one device does not stop the others; the exit status is 1 if any
device failed, and 2 for problems with the configuration itself.

Devices do not report some fields, passwords among them, so these cannot be
compared. A component whose only differences might lie in such fields is
marked `?` and sent only with `--force`.

`shelly-deploy` talks to devices with shelly-manager-core's RPC client, which
handles digest authentication. It needs no shelly-manager server or database.
`--flake` and `-f` need `nix` and `nix-instantiate` on `PATH`.

Limitations:

- Gen1 devices are not supported. Their configuration has a different shape,
  set over a different protocol.
- Addresses must be IPv4, as in shelly-manager.
- Components must already exist on the device; scripts and schedules are not
  managed yet.

## NixOS modules

```nix
{inputs, ...}: {
  imports = [inputs.shelly-nix.nixosModules.default];

  services.shelly-manager.api = {
    enable = true;
    authTokenFile = "/run/secrets/shelly-manager-token";
    settings.firmware.advertised_base_url = "http://shelly.lan";
  };

  services.shelly-manager.web = {
    enable = true;
    hostName = "shelly.lan";
    openFirewall = true;
  };
}
```

- **`services.shelly-manager.api`** runs the API as a hardened systemd
  service with a dynamic user. Data is kept in `/var/lib/shelly-manager`.
  - It listens on `127.0.0.1:8000` by default.
  - `settings` becomes the JSON file named by `SHELLY_CONFIG_FILE`.
  - Without `secretKeyFile`, it generates a key on first start and keeps it.
    Changing the key makes stored credentials and backups unreadable.
  - mDNS discovery may need UDP port 5353 open in the firewall.
- **`services.shelly-manager.web`** serves the interface from an nginx virtual
  host, so TLS and the like are configured through
  `services.nginx.virtualHosts.<hostName>`.
  - Unless `apiUrl` is set, it proxies `/api` to the local API and the
    interface uses its own origin, so no CORS setup is needed.
- **`programs.shelly-manager.cli`** installs the `shelly-manager` command.

The package defaults come from this flake's packages for the host's system.

## Development

```console
$ nix develop   # update-sources, update-hashes, dedupe-inputs, update-all
$ nix fmt
$ nix flake check
```

The checks are:

- **`module-eval`**: evaluation tests for the Shelly module.
- **`flake-parts-module`**: evaluates a flake that uses the flake-parts module.
- **`flake-compat`**: checks that `default.nix` exposes the flake's outputs.
- **`shelly-deploy`**: the package, whose build runs pytest against a fake
  Gen2+ device (`nix/pkgs/shelly-deploy/tests/fake_shelly.py`).
- **`nixos-shelly-manager`**: a VM test of the API and web interface modules.
- **`nixos-shelly-deploy`**: a VM test of `shelly-deploy -f` against the fake
  device, end to end.
