# shelly-deploy, end to end: a configuration in a Nix file, evaluated by
# `shelly-deploy -f`, applied to a fake device with authentication.
{self}: {
  name = "shelly-deploy";

  nodes.machine = {pkgs, ...}: let
    shelly-deploy = self.packages.${pkgs.stdenv.hostPlatform.system}.shelly-deploy;

    fleetModule = pkgs.writeText "fleet-module.nix" ''
      {
        fleet.defaults.auth.passwordFile = "/etc/shelly/admin-password";
        fleet.devices.porch = {
          address = "porch.lan";
          mac = "aa:bb:cc:dd:ee:ff";
          tags = ["outdoor"];
          components = {
            "switch:0" = {
              name = "Porch light";
              initial_state = "restore_last";
            };
            mqtt = {
              enable = true;
              server = "mqtt.lan:1883";
              pass._secret = "/etc/shelly/mqtt-password";
            };
          };
          scripts.hello.code = "print('hello from shelly.nix');";
          schedules = [
            {
              timespec = "0 30 22 * * *";
              calls = [
                {
                  method = "Switch.Set";
                  params = {
                    id = 0;
                    on = false;
                  };
                }
              ];
            }
          ];
        };
      }
    '';

    # Just what the Shelly module needs, so that the test does not depend on
    # the whole repository.
    shellyNix = pkgs.lib.fileset.toSource {
      root = ../..;
      fileset = pkgs.lib.fileset.unions [../../lib ../../modules/shelly];
    };

    fleet = pkgs.writeText "fleet.nix" ''
      let
        lib = import ${pkgs.path}/lib;
        shelly = import ${shellyNix}/lib {inherit lib;};
      in
        shelly.shellyConfiguration {modules = [${fleetModule}];}
    '';
  in {
    networking.hosts."127.0.0.1" = ["porch.lan"];

    systemd.services.fake-shelly = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${shelly-deploy.fakeDevice} --port 80 --password-file /etc/shelly/admin-password";
    };

    environment.etc = {
      "shelly/admin-password".text = "admin-secret\n";
      "shelly/mqtt-password".text = "mqtt-secret";
      "shelly/fleet.nix".source = fleet;
    };

    environment.systemPackages = [shelly-deploy pkgs.curl];
  };

  testScript = ''
    import json

    def device():
        return json.loads(machine.succeed("curl -sf http://porch.lan/_test/state"))

    machine.wait_for_unit("fake-shelly.service")
    machine.wait_for_open_port(80)

    with subtest("build evaluates the configuration"):
        manifest = json.loads(machine.succeed("shelly-deploy build -f /etc/shelly/fleet.nix"))
        assert manifest["devices"]["porch"]["mac"] == "AABBCCDDEEFF", manifest

    with subtest("diff shows pending changes and changes nothing"):
        out = machine.succeed("shelly-deploy diff -f /etc/shelly/fleet.nix")
        assert "~ switch:0" in out, out
        assert "+ script hello" in out, out
        assert "~ schedules (1 job(s))" in out, out
        assert device()["config"]["switch:0"]["name"] is None

    with subtest("switch applies the configuration"):
        out = machine.succeed("shelly-deploy switch -f /etc/shelly/fleet.nix --on @outdoor")
        state = device()
        assert state["config"]["switch:0"]["name"] == "Porch light", state
        assert state["config"]["switch:0"]["in_mode"] == "follow", state
        assert state["config"]["mqtt"]["pass"] == "mqtt-secret", state
        assert state["reboots"] == 1, state
        [script] = state["scripts"]
        assert script["name"] == "hello" and script["running"], state
        [job] = state["jobs"]
        assert job["timespec"] == "0 30 22 * * *", state
        assert "secret" not in out, out

    with subtest("a second switch changes nothing"):
        out = machine.succeed("shelly-deploy switch -f /etc/shelly/fleet.nix")
        assert "1 device(s): 0 changed, 1 unchanged, 0 failed" in out, out

    with subtest("selecting nothing is an error"):
        machine.fail("shelly-deploy diff -f /etc/shelly/fleet.nix --on @indoor")
  '';
}
