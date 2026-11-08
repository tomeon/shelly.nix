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
  `shellyConfigurations.<name>` and a `nix flake check` check (unless
  `shelly.flakeCheck = false`).
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
      scripts.motion-light.code = builtins.readFile ./motion-light.js;
      schedules = [
        {
          timespec = "0 30 22 * * *";
          calls = [{method = "Switch.Set"; params = {id = 0; on = false;};}];
        }
      ];
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
  + script motion-light
      code: 1734 bytes
      enable: true
  ~ schedules (1 job(s))
      + 0 30 22 * * *: Switch.Set
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
`lib.evalModules` wrapper, which passes `specialArgs` and `prefix` through),
with the flake-parts module, or with your own `lib.evalModules` call using
`modules.shelly.default` and `class = "shelly"`.

Options live under namespaces. The `fleet` namespace holds devices:

| Option | Description |
| --- | --- |
| `fleet.defaults` | A module applied to every device. Its definitions have normal priority; use `lib.mkDefault` for values devices may override. |
| `fleet.devices.<name>.address` | Host name or IPv4 address, optionally with `:port`. Defaults to `<name>`. |
| `fleet.devices.<name>.mac` | If set, `shelly-deploy` refuses to change a device reporting another MAC. |
| `fleet.devices.<name>.tags` | For selecting devices with `--on @tag`. |
| `fleet.devices.<name>.auth.passwordFile` | The device's `admin` password, read at deploy time. |
| `fleet.devices.<name>.components.<key>` | Component configuration, keyed `sys`, `mqtt`, `switch:0` and so on: the `config` object of the component's `SetConfig` call, as in the [Gen2+ API documentation](https://shelly-api-docs.shelly.cloud/gen2/). |
| `fleet.devices.<name>.scripts.<script>` | A script, by its name on the device: `code`, and `enable` (default true) for whether it runs, now and at boot. |
| `fleet.devices.<name>.schedules` | Scheduled jobs (`enable`, `timespec`, `calls`; at most 20 jobs of at most 5 calls). Null (the default) leaves the device's schedules alone; a list, even an empty one, replaces them. |
| `fleet.devices.<name>.deployment.reboot` | `"if-required"` (default) reboots when a change reports `restart_required`; `"never"` doesn't. |
| `fleet.devices.<name>.deployment.allowNetworkChanges` | Must be set to manage `wifi` or `eth`, where a mistake can leave the device unreachable. |

`build.manifest` is the JSON document `shelly-deploy` reads. Evaluating it
checks `assertions` and prints `warnings`, as in NixOS.

Some semantics to be aware of:

- **Only declared fields are managed.** The device keeps its own values for the
  rest. Removing a field from the configuration does not reset it on the device.
  To roll back, revert the configuration and switch again.
- **Undeclared scripts are left alone,** and removing a script from the
  configuration does not delete it. Declared schedules, by contrast, replace
  all of the device's jobs.
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
3. It applies what differs, in this order:
   - components (`SetConfig`);
   - scripts: created if missing, code uploaded in chunks, then started or
     stopped;
   - schedules: existing jobs updated in place and missing ones created. If
     that fails, what was done is undone. Leftover jobs, the ones the
     configuration drops, are deleted one by one only after that has
     succeeded. A failure therefore never loses a job the configuration keeps,
     but a failed deletion can leave only some of the leftovers deleted;
   - finally `wifi` and `eth`.
4. After each network change, it waits for the device to reconnect, before
   sending the next one. Devices reconnect about a second after storing new
   WiFi settings, and may not even answer the call that changed them. It looks
   for the device at its declared address (resolved again) and at any static
   IP the changes give it, accepting only a device with the same MAC. If the
   device now answers elsewhere, it says so: update `address`.
5. It reboots once if any change reported `restart_required` and waits for the
   device to come back.
6. It reads the configuration again and fails if any change did not take
   effect.

A failure on one device does not stop the others; the exit status is 1 if any
device failed, and 2 for problems with the configuration itself.

Write-only fields cannot be compared, because devices never report them:
`mqtt.pass` and `wifi.{ap,sta,sta1}.pass`, plus any value given as a
`_secret`. A component whose only differences might lie in such fields is
marked `?` and sent only with `--force`. Any other declared field that the
device does not report counts as a change. If it is still missing after
switching, for example because it is misspelt, verification fails.

`shelly-deploy` talks to devices with shelly-manager-core's RPC client, which
handles digest authentication. It needs no shelly-manager server or database.
`--flake` and `-f` need `nix` and `nix-instantiate` on `PATH`.

Limitations:

- Gen1 devices are not supported. Their configuration has a different shape,
  set over a different protocol.
- Addresses must be IPv4, as in shelly-manager.
- Components must already exist on the device. (Scripts are created as
  needed.)

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
    serverName = "shelly.lan";
    openFirewall = true;
  };

  # The interface sends the token with every request: use it over HTTPS.
  # `addSSL` keeps plain HTTP for devices fetching firmware, which needs no
  # token; `forceSSL` would redirect them too.
  services.nginx.virtualHosts.shelly-manager = {
    addSSL = true;
    sslCertificate = "/var/lib/certs/shelly.lan.crt";
    sslCertificateKey = "/var/lib/certs/shelly.lan.key";
  };
}
```

- **`services.shelly-manager.api`** runs the API as a hardened systemd
  service with a dynamic user. Data is kept in `/var/lib/shelly-manager`.
  - It listens on `127.0.0.1:8000` by default (`address`, `port`).
  - `settings` becomes the JSON file named by `SHELLY_CONFIG_FILE`.
  - Without `secretKeyFile`, it generates a key on first start and keeps it.
    Changing the key makes stored credentials and backups unreadable.
  - The API reads its secrets from files (`SHELLY_SECRET_KEY_FILE`,
    `SHELLY_AUTH_TOKEN_FILE`), never from the environment. Upstream reads
    only the environment; the package adds the `_FILE` variants with a
    patch.
  - mDNS discovery may need UDP port 5353 open in the firewall.
- **`services.shelly-manager.web`** serves the interface from an nginx virtual
  host, `services.nginx.virtualHosts.shelly-manager` by default
  (`virtualHost`), where TLS, listen addresses and the like are configured.
  - `serverName` sets the host name it answers to.
  - Unless `apiUrl` is set, it proxies `/api` to the local API and the
    interface uses its own origin, so no CORS setup is needed.
  - `openFirewall` opens the ports the virtual host listens on, as nginx
    works them out from its listen settings.
- **Unauthenticated access is refused.** If no `api.authTokenFile` is set, the
  API must be reachable from this machine only, or evaluation fails. It is
  reachable from elsewhere when `api.address` is not a numeric loopback
  address, or when the web interface proxies `/api` on one; the firewall does
  not count. Set `services.shelly-manager.api.allowUnauthenticatedAccess =
  true` to allow it anyway, for example on a trusted LAN.
- **The token is only as private as the connection.** Over plain HTTP, anyone
  on the network path can read it. Serve the interface over HTTPS, as in the
  example.
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
