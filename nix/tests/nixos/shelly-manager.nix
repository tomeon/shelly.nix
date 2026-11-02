# The API and web interface NixOS modules, together.
{self}: {
  name = "shelly-manager";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.default];

    services.shelly-manager.api = {
      enable = true;
      authTokenFile = "/etc/shelly-manager/auth-token";
      settings.network.timeout = 5;
    };
    services.shelly-manager.web.enable = true;

    environment.etc."shelly-manager/auth-token".text = "test-token";
    environment.systemPackages = [pkgs.curl pkgs.jq];
  };

  testScript = ''
    def status(url, *args):
        return machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {' '.join(args)} {url}").strip()

    auth = "-H 'Authorization: Bearer test-token'"

    machine.wait_for_unit("shelly-manager-api.service")
    machine.wait_for_open_port(8000)
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(80)

    with subtest("the API answers, on localhost only"):
        machine.succeed("curl -sf http://127.0.0.1:8000/api/health | jq -e '.status == \"healthy\"'")
        machine.succeed("ss -Htln 'sport = :8000' | grep -q '127.0.0.1:8000'")

    with subtest("the auth token is required"):
        assert status("http://127.0.0.1:8000/api/credentials") == "401"
        assert status("http://127.0.0.1:8000/api/credentials", auth) == "200"

    with subtest("the settings file is used"):
        machine.succeed("systemctl show -p Environment shelly-manager-api | grep -q SHELLY_CONFIG_FILE=")
        config = machine.succeed("systemctl show -p Environment shelly-manager-api | grep -o 'SHELLY_CONFIG_FILE=[^ ]*' | cut -d= -f2").strip()
        machine.succeed(f"jq -e '.network.timeout == 5' {config}")

    with subtest("the generated secret key is kept, and private"):
        key = machine.succeed("cat /var/lib/private/shelly-manager/secret-key")
        machine.succeed("stat -c %a /var/lib/private/shelly-manager/secret-key | grep -qx 600")
        machine.succeed(
            f"curl -sf -X POST {auth} -H 'Content-Type: application/json' "
            "-d '{\"mac\": \"AABBCCDDEEFF\", \"password\": \"pw\"}' "
            "http://127.0.0.1:8000/api/credentials"
        )
        machine.systemctl("restart shelly-manager-api.service")
        machine.wait_for_open_port(8000)
        assert key == machine.succeed("cat /var/lib/private/shelly-manager/secret-key")
        # Decrypting the stored credential needs the same key.
        machine.succeed(f"curl -sf {auth} http://127.0.0.1:8000/api/credentials | jq -e '.[0].mac == \"AABBCCDDEEFF\"'")

    with subtest("the web interface is served, with the API on the same origin"):
        machine.succeed("curl -sf http://machine/ | grep -q '<div id=\"root\">'")
        machine.succeed("curl -sf http://machine/devices/192.168.1.2 | grep -q '<div id=\"root\">'")
        machine.succeed("curl -sf http://machine/config.js | grep -q 'VITE_BASE_API_URL: window.location.origin'")
        machine.succeed("curl -sf http://machine/api/health | jq -e '.status == \"healthy\"'")
        assert status("http://machine/api/credentials") == "401"
        assert status("http://machine/api/credentials", auth) == "200"
        assert status("http://machine/docs") == "200"
  '';
}
