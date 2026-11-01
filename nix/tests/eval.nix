# Evaluation tests for the generic Shelly module.
{
  lib,
  runCommand,
  shellyLib,
}: let
  eval = module: (shellyLib.shellyConfiguration {modules = [module];}).config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  example = eval {
    fleet.defaults = {name, ...}: {
      auth.passwordFile = "/run/secrets/shelly";
      components.sys.device.name = lib.mkDefault name;
      components.sys.device.eco_mode = true;
    };
    fleet.devices = {
      porch = {
        address = "192.168.1.50:8080";
        mac = "aa:bb:cc:dd:ee:ff";
        tags = ["outdoor"];
        components."switch:0" = {
          name = "Porch";
          initial_state = "restore_last";
        };
        components.mqtt = {
          enable = true;
          pass._secret = "/run/secrets/mqtt";
        };
      };
      kitchen.components.sys.device.name = "Kitchen plug";
    };
  };

  withDevice = device: eval {fleet.devices.d = device;};

  results = lib.runTests {
    testAddressDefaultsToName = {
      expr = example.fleet.devices.kitchen.address;
      expected = "kitchen";
    };

    testDefaultsMergeDeeply = {
      expr = example.fleet.devices.porch.components.sys;
      expected.device = {
        name = "porch";
        eco_mode = true;
      };
    };

    testDevicesOverrideMkDefault = {
      expr = example.fleet.devices.kitchen.components.sys.device.name;
      expected = "Kitchen plug";
    };

    testMacIsNormalised = {
      expr = example.fleet.devices.porch.mac;
      expected = "AABBCCDDEEFF";
    };

    testManifest = {
      expr = example.build.manifest;
      expected = {
        version = 1;
        devices = {
          porch = {
            address = "192.168.1.50:8080";
            mac = "AABBCCDDEEFF";
            tags = ["outdoor"];
            auth.passwordFile = "/run/secrets/shelly";
            deployment = {
              allowNetworkChanges = false;
              reboot = "if-required";
            };
            scripts = {};
            schedules = null;
            components = {
              sys.device = {
                name = "porch";
                eco_mode = true;
              };
              "switch:0" = {
                name = "Porch";
                initial_state = "restore_last";
              };
              mqtt = {
                enable = true;
                pass._secret = "/run/secrets/mqtt";
              };
            };
          };
          kitchen = {
            address = "kitchen";
            mac = null;
            tags = [];
            auth.passwordFile = "/run/secrets/shelly";
            deployment = {
              allowNetworkChanges = false;
              reboot = "if-required";
            };
            scripts = {};
            schedules = null;
            components.sys.device = {
              name = "Kitchen plug";
              eco_mode = true;
            };
          };
        };
      };
    };

    testEmptyFleet = {
      expr = (eval {}).build.manifest;
      expected = {
        version = 1;
        devices = {};
      };
    };

    testNetworkComponentsNeedOptIn = {
      expr = failedAssertions (withDevice {components.wifi.sta.ssid = "home";});
      expected = ["fleet.devices.d.components.wifi: a mistake in `wifi` can leave the device unreachable; set `fleet.devices.d.deployment.allowNetworkChanges = true` to manage it anyway."];
    };

    testNetworkComponentsWithOptIn = {
      expr = failedAssertions (withDevice {
        components.eth.enable = true;
        deployment.allowNetworkChanges = true;
      });
      expected = [];
    };

    testFailedAssertionsBlockManifest = {
      expr = throws (withDevice {components.wifi.sta.ssid = "home";}).build.manifest;
      expected = true;
    };

    testBadComponentKey = {
      expr = failedAssertions (withDevice {components."Switch 0".name = "x";});
      expected = ["fleet.devices.d.components: `Switch 0` is not a component key (expected e.g. `sys`, `mqtt` or `switch:0`)."];
    };

    testRelativeSecret = {
      expr = failedAssertions (withDevice {components.mqtt.pass._secret = "secrets/mqtt";});
      expected = ["fleet.devices.d.components.mqtt.pass._secret: must be an absolute path (a string) outside the Nix store."];
    };

    testSecretInStore = {
      expr = failedAssertions (withDevice {components.mqtt.pass._secret = "${builtins.storeDir}/abc-secret";});
      expected = ["fleet.devices.d.components.mqtt.pass._secret: must be an absolute path (a string) outside the Nix store."];
    };

    testSecretWithExtraAttributes = {
      expr = failedAssertions (withDevice {
        components.mqtt.pass = {
          _secret = "/run/secrets/mqtt";
          quote = true;
        };
      });
      expected = ["fleet.devices.d.components.mqtt.pass: a `_secret` placeholder must have no other attributes."];
    };

    testSecretInList = {
      expr = failedAssertions (withDevice {components."x:1".args = [{_secret = "relative";}];});
      expected = ["fleet.devices.d.components.x:1.args.0._secret: must be an absolute path (a string) outside the Nix store."];
    };

    # Path values would be copied into the Nix store when turned into JSON.
    testPathInComponentRejected = {
      expr = throws (withDevice {components.mqtt.ssl_ca = /nonexistent/ca.pem;}).build.manifest;
      expected = true;
    };

    testPasswordFileRejectsPathValue = {
      expr = throws (withDevice {auth.passwordFile = /nonexistent/password;}).fleet.devices.d.auth.passwordFile;
      expected = true;
    };

    testPasswordFileRejectsStorePath = {
      expr = throws (withDevice {auth.passwordFile = "${builtins.storeDir}/abc-password";}).fleet.devices.d.auth.passwordFile;
      expected = true;
    };

    testBadMacRejected = {
      expr = throws (withDevice {mac = "not-a-mac";}).fleet.devices.d.mac;
      expected = true;
    };

    testScriptsAndSchedulesInManifest = {
      expr =
        (withDevice {
          scripts.motion.code = "print(1)";
          scripts.idle = {
            code = "";
            enable = false;
          };
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
                {method = "Shelly.Reboot";}
              ];
            }
          ];
        })
        .build
        .manifest
        .devices
        .d;
      expected = {
        address = "d";
        mac = null;
        tags = [];
        auth.passwordFile = null;
        deployment = {
          allowNetworkChanges = false;
          reboot = "if-required";
        };
        components = {};
        scripts = {
          motion = {
            code = "print(1)";
            enable = true;
          };
          idle = {
            code = "";
            enable = false;
          };
        };
        schedules = [
          {
            enable = true;
            timespec = "0 30 22 * * *";
            calls = [
              {
                method = "Switch.Set";
                params = {
                  id = 0;
                  on = false;
                };
              }
              {
                method = "Shelly.Reboot";
                params = {};
              }
            ];
          }
        ];
      };
    };

    testEmptyScheduleListIsKept = {
      expr = (withDevice {schedules = [];}).build.manifest.devices.d.schedules;
      expected = [];
    };

    testScheduleNeedsCalls = {
      expr = throws (withDevice {schedules = [{timespec = "* * * * * *";}];}).build.manifest;
      expected = true;
    };

    testScriptComponentsRejected = {
      expr = failedAssertions (withDevice {components."script:1".enable = true;});
      expected = ["fleet.devices.d.components.script:1: manage scripts with `fleet.devices.d.scripts.<name>` instead."];
    };

    testSecretInSchedule = {
      expr = failedAssertions (withDevice {
        schedules = [
          {
            timespec = "0 0 * * * *";
            calls = [
              {
                method = "HTTP.GET";
                params.url._secret = "relative";
              }
            ];
          }
        ];
      });
      expected = ["fleet.devices.d.schedules.0.calls.0.params.url._secret: must be an absolute path (a string) outside the Nix store."];
    };

    testConflictingDefinitionsRejected = {
      expr =
        throws
        (eval {
          fleet.defaults.components.sys.device.name = "a";
          fleet.devices.d.components.sys.device.name = "b";
        }).build.manifest;
      expected = true;
    };
  };
in
  runCommand "shelly-module-eval-tests" {
    passAsFile = ["results"];
    results = builtins.toJSON results;
  } ''
    if [ "$(cat "$resultsPath")" != "[]" ]; then
      echo "Failed tests:" >&2
      cat "$resultsPath" >&2
      exit 1
    fi
    touch "$out"
  ''
