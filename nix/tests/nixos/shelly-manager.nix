# The API and web interface NixOS modules, together.
{self}: {
  name = "shelly-manager";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.default];

    services.shelly-manager.api = {
      enable = true;
      authTokenFile = "/etc/${config.environment.etc."shelly-manager/auth-token".target}";
      settings.network.timeout = 5;
    };
    services.shelly-manager.web = {
      enable = true;
      serverName = "shelly.test";
    };

    networking.hosts."127.0.0.1" = [config.services.shelly-manager.web.serverName];
    environment.etc."shelly-manager/auth-token".text = "test-token";
    environment.systemPackages = with pkgs; [curl jq];
  };

  testScript = {nodes, ...}: let
    inherit (nodes.machine) environment services systemd;
    service = systemd.services.shelly-manager-api;
    inherit (services.shelly-manager.api) addresses port;
    web = "http://${services.shelly-manager.web.serverName}";
  in ''
    import json
    import shlex

    port = ${toString port}
    addresses = ${builtins.toJSON addresses}

    def host(address):
        return f"[{address}]" if ":" in address else address

    api = f"http://{host(addresses[0])}:{port}"

    def status(url, *args):
        return machine.succeed(shlex.join(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", *args, url])).strip()

    def main_process_environment():
        pid = machine.succeed("systemctl show -p MainPID --value shelly-manager-api").strip()
        return machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")

    token = ${builtins.toJSON environment.etc."shelly-manager/auth-token".text}
    auth = ["-H", f"Authorization: Bearer {token}"]
    key_file = ${builtins.toJSON service.environment.SHELLY_SECRET_KEY_FILE}

    machine.wait_for_unit("shelly-manager-api.service")
    machine.wait_for_open_port(port)
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(80)

    with subtest("the API answers on each of its addresses, and listens nowhere else"):
        assert addresses == ["127.0.0.1", "::1"], addresses
        listening = machine.succeed(f"ss -Htln 'sport = :{port}'")
        assert len(listening.splitlines()) == len(addresses), listening
        for address in addresses:
            assert f"{host(address)}:{port}" in listening, listening
            machine.succeed(f"curl -sf http://{host(address)}:{port}/api/health | jq -e '.status == \"healthy\"'")

    with subtest("the auth token is required"):
        assert status(f"{api}/api/credentials") == "401"
        assert status(f"{api}/api/credentials", *auth) == "200"

    with subtest("secrets are read from files, not passed in the environment"):
        environ = main_process_environment()
        assert "SHELLY_AUTH_TOKEN_FILE=" in environ, environ
        assert token not in environ, environ
        assert machine.succeed(f"cat {shlex.quote(key_file)}").strip() not in environ, environ

    with subtest("the settings file is used"):
        machine.succeed("jq -e '.network.timeout == 5' ${service.environment.SHELLY_CONFIG_FILE}")

    with subtest("the firmware directory exists"):
        machine.succeed("test -d ${service.environment.SHELLY_FIRMWARE_DIR}")

    with subtest("the generated secret key is kept, and private"):
        key = machine.succeed(f"cat {shlex.quote(key_file)}")
        machine.succeed(f"stat -L -c %a {shlex.quote(key_file)} | grep -qx 600")
        credential = json.dumps({"mac": "AABBCCDDEEFF", "password": "pw"})
        machine.succeed(shlex.join(["curl", "-sf", "-X", "POST", *auth, "-H", "Content-Type: application/json", "-d", credential, f"{api}/api/credentials"]))
        machine.systemctl("restart shelly-manager-api.service")
        machine.wait_for_open_port(port)
        assert key == machine.succeed(f"cat {shlex.quote(key_file)}")
        # Decrypting the stored credential needs the same key.
        machine.succeed(shlex.join(["curl", "-sf", *auth, f"{api}/api/credentials"]) + " | jq -e '.[0].mac == \"AABBCCDDEEFF\"'")

    with subtest("the web interface is served, with the API on the same origin"):
        machine.succeed("curl -sf ${web}/ | grep -q '<div id=\"root\">'")
        machine.succeed("curl -sf ${web}/devices/192.168.1.2 | grep -q '<div id=\"root\">'")
        machine.succeed("curl -sf ${web}/config.js | grep -q 'VITE_BASE_API_URL: window.location.origin'")
        machine.succeed("curl -sf ${web}/api/health | jq -e '.status == \"healthy\"'")
        assert status("${web}/api/credentials") == "401"
        assert status("${web}/api/credentials", *auth) == "200"
        assert status("${web}/docs") == "200"
  '';
}
