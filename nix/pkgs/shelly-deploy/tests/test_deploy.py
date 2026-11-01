"""shelly-deploy against fake devices, through its command line."""

import json

from conftest import entry


def set_configs(device):
    return [m for m in device.state()["calls"] if m.endswith(".SetConfig")]


def test_diff_changes_nothing(device, deploy):
    code, out = deploy(
        "diff",
        {"porch": entry(device.address, components={"switch:0": {"name": "Porch"}})},
    )
    assert code == 0
    assert "  ~ switch:0\n" in out
    assert 'name: null -> "Porch"' in out
    assert "1 device(s): 1 to change, 0 unchanged, 0 failed" in out
    assert device.config["switch:0"]["name"] is None
    assert set_configs(device) == []


def test_switch_applies_declared_fields_only(device, deploy):
    components = {
        "switch:0": {"name": "Porch", "initial_state": "restore_last"},
        "sys": {"device": {"name": "porch"}},
    }
    code, out = deploy(
        "switch", {"porch": entry(device.address, components=components)}
    )
    assert code == 0, out
    assert "applied switch:0, sys" in out or "applied sys, switch:0" in out
    assert device.config["switch:0"]["name"] == "Porch"
    assert device.config["switch:0"]["initial_state"] == "restore_last"
    assert device.config["switch:0"]["in_mode"] == "follow"
    assert device.config["sys"]["device"]["name"] == "porch"
    assert device.config["sys"]["device"]["eco_mode"] is False
    assert device.reboots == 0


def test_switch_is_idempotent(device, deploy):
    devices = {
        "porch": entry(device.address, components={"switch:0": {"name": "Porch"}})
    }
    assert deploy("switch", devices)[0] == 0
    calls = len(set_configs(device))

    code, out = deploy("switch", devices)
    assert code == 0
    assert "  = switch:0" in out
    assert "applied" not in out
    assert "1 device(s): 0 changed, 1 unchanged, 0 failed" in out
    assert len(set_configs(device)) == calls


def test_force_resends_unchanged_components(device, deploy):
    devices = {"porch": entry(device.address, components={"switch:0": {"name": None}})}
    code, out = deploy("switch", devices, "--force")
    assert code == 0
    assert "applied switch:0" in out
    assert set_configs(device) == ["Switch.SetConfig"]


def test_secrets_are_substituted_and_never_shown(device, deploy, tmp_path):
    secret = tmp_path / "mqtt-password"
    secret.write_text("hunter2\n")
    mqtt = {"enable": True, "server": "mqtt.lan:1883", "pass": {"_secret": str(secret)}}
    devices = {"porch": entry(device.address, components={"mqtt": mqtt})}

    code, out = deploy("switch", devices)
    assert code == 0, out
    assert device.config["mqtt"]["pass"] == "hunter2"
    assert device.config["mqtt"]["server"] == "mqtt.lan:1883"
    assert "hunter2" not in out

    # The device never reports the password, so it cannot be compared.
    code, out = deploy("switch", devices)
    assert code == 0
    assert "? mqtt (not reported by the device: pass); not sent without --force" in out
    assert "applied" not in out

    code, out = deploy("diff", devices)
    assert "use `switch --force` to send" in out


def test_reboots_when_a_change_requires_it(device, deploy):
    devices = {"porch": entry(device.address, components={"mqtt": {"enable": True}})}
    code, out = deploy("switch", devices)
    assert code == 0, out
    assert "restart required by mqtt: rebooted" in out
    assert device.reboots == 1


def test_reboot_policy_never(device, deploy):
    devices = {
        "porch": entry(
            device.address,
            components={"mqtt": {"enable": True}},
            deployment={"reboot": "never"},
        )
    }
    code, out = deploy("switch", devices)
    assert code == 0
    assert "restart required by mqtt: not rebooting (deployment.reboot = never)" in out
    assert device.reboots == 0


def test_mac_mismatch_changes_nothing(device, deploy):
    devices = {
        "porch": entry(
            device.address, mac="112233445566", components={"switch:0": {"name": "x"}}
        )
    }
    code, out = deploy("switch", devices)
    assert code == 1
    assert "MAC mismatch: expected 112233445566, device reports AABBCCDDEEFF" in out
    assert set_configs(device) == []


def test_matching_mac(device, deploy):
    devices = {
        "porch": entry(
            device.address, mac="AABBCCDDEEFF", components={"switch:0": {"name": "x"}}
        )
    }
    assert deploy("switch", devices)[0] == 0


def test_unknown_component(device, deploy):
    code, out = deploy(
        "switch",
        {"porch": entry(device.address, components={"cover:0": {"name": "x"}})},
    )
    assert code == 1
    assert "cover:0: no such component on this device" in out


def test_network_components_need_opt_in(device, deploy):
    devices = {
        "porch": entry(device.address, components={"wifi": {"sta": {"ssid": "other"}}})
    }
    code, out = deploy("switch", devices)
    assert code == 1
    assert "refusing to change wifi without deployment.allowNetworkChanges" in out
    assert device.config["wifi"]["sta"]["ssid"] == "home"


def test_network_components_go_last(device, deploy, tmp_path):
    secret = tmp_path / "wifi"
    secret.write_text("wifi-password")
    components = {
        "wifi": {"sta": {"ssid": "other", "pass": {"_secret": str(secret)}}},
        "switch:0": {"name": "x"},
    }
    devices = {
        "porch": entry(
            device.address,
            components=components,
            deployment={"allowNetworkChanges": True},
        )
    }
    code, out = deploy("switch", devices)
    assert code == 0, out
    # Method names are case-insensitive; shelly-manager-core spells it `Wifi`.
    assert [m.lower() for m in set_configs(device)] == [
        "switch.setconfig",
        "wifi.setconfig",
    ]
    assert device.config["wifi"]["sta"]["ssid"] == "other"
    assert device.config["wifi"]["sta"]["pass"] == "wifi-password"
    assert device.config["wifi"]["sta"]["ipv4mode"] == "dhcp"
    assert device.reboots == 1


def test_gen1_devices_are_rejected(make_device, deploy):
    device = make_device(gen=1)
    code, out = deploy(
        "diff",
        {"old": entry(device.address, components={"sys": {"device": {"name": "x"}}})},
    )
    assert code == 1
    assert "Gen1 devices are not supported" in out


def test_password_protected_device(make_device, deploy, tmp_path):
    device = make_device(password="correct horse")
    good = tmp_path / "good"
    good.write_text("correct horse\n")
    bad = tmp_path / "bad"
    bad.write_text("wrong")
    components = {"switch:0": {"name": "Porch"}}

    code, out = deploy(
        "switch",
        {
            "porch": entry(
                device.address, components=components, auth={"passwordFile": str(good)}
            )
        },
    )
    assert code == 0, out
    assert device.config["switch:0"]["name"] == "Porch"

    code, out = deploy(
        "diff",
        {
            "porch": entry(
                device.address, components=components, auth={"passwordFile": str(bad)}
            )
        },
    )
    assert code == 1
    assert "authentication failed (check auth.passwordFile)" in out

    code, out = deploy("diff", {"porch": entry(device.address, components=components)})
    assert code == 1
    assert "the device requires a password; set auth.passwordFile" in out

    code, out = deploy(
        "diff",
        {
            "porch": entry(
                device.address, auth={"passwordFile": str(tmp_path / "missing")}
            )
        },
    )
    assert code == 1
    assert "cannot read secret" in out


def test_host_names_are_resolved(device, deploy):
    port = device.address.rpartition(":")[2]
    code, out = deploy(
        "switch",
        {"porch": entry(f"localhost:{port}", components={"switch:0": {"name": "x"}})},
    )
    assert code == 0, out
    assert device.config["switch:0"]["name"] == "x"


def test_unresolvable_and_ipv6_addresses(deploy):
    code, out = deploy(
        "diff", {"a": entry("no-such-host.invalid"), "b": entry("fe80::1")}
    )
    assert code == 1
    assert "cannot resolve no-such-host.invalid" in out
    assert "IPv6 addresses are not supported" in out


def test_one_failure_does_not_stop_the_others(device, deploy):
    devices = {
        "dead": entry("127.0.0.1:1"),
        "porch": entry(device.address, components={"switch:0": {"name": "x"}}),
    }
    code, out = deploy("switch", devices)
    assert code == 1
    assert "2 device(s): 1 changed, 0 unchanged, 1 failed" in out
    assert device.config["switch:0"]["name"] == "x"


def test_selection(make_device, deploy):
    porch, kitchen = make_device(), make_device()
    devices = {
        "porch": entry(
            porch.address, tags=["outdoor"], components={"switch:0": {"name": "p"}}
        ),
        "kitchen": entry(kitchen.address, components={"switch:0": {"name": "k"}}),
    }
    code, out = deploy("switch", devices, "--on", "@outdoor")
    assert code == 0
    assert porch.config["switch:0"]["name"] == "p"
    assert kitchen.config["switch:0"]["name"] is None

    code, out = deploy("switch", devices, "--on", "@nothing")
    assert code == 2
    assert "no devices match @nothing" in out


def test_failed_component_reports_what_was_applied(device, deploy):
    device.failing.add("Switch.SetConfig")
    components = {"input:0": {"name": "in"}, "switch:0": {"name": "x"}}
    code, out = deploy(
        "switch", {"porch": entry(device.address, components=components)}
    )
    assert code == 1
    assert (
        "switch:0: Switch.SetConfig: Switch.SetConfig failed (test hook) (code -103) (already applied: input:0)"
        in out
    )


def test_changes_that_do_not_take_effect(device, deploy):
    device.ignoring.add("switch:0")
    code, out = deploy(
        "switch",
        {"porch": entry(device.address, components={"switch:0": {"name": "x"}})},
    )
    assert code == 1
    assert 'configuration did not take effect: name: null -> "x"' in out


def test_build_prints_the_manifest(deploy):
    devices = {
        "porch": entry("10.0.0.1", components={"sys": {"device": {"name": "x"}}})
    }
    code, out = deploy("build", devices)
    assert code == 0
    assert json.loads(out) == {"version": 1, "devices": devices}


def test_bad_manifest(deploy, tmp_path):
    code, out = deploy("diff", {"porch": {"no": "address"}})
    assert code == 2
    assert "device porch: malformed entry" in out
