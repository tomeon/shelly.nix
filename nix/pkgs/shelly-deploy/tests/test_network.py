"""Network changes: reconnection, lost answers, and devices that move."""

from conftest import entry
from fake_shelly import FakeShelly


def wifi(device, sta, **overrides):
    return {
        "porch": entry(
            device.address,
            components={"wifi": {"sta": sta}},
            deployment={"allowNetworkChanges": True},
            **overrides,
        )
    }


def test_network_changes_wait_for_the_reconnect(device, deploy):
    # The fake drops off the network 0.2s after a WiFi change, for a second.
    code, out = deploy("switch", wifi(device, {"ssid": "other"}))
    assert code == 0, out
    assert device.config["wifi"]["sta"]["ssid"] == "other"
    assert device.reconnects == 1
    assert device.reboots == 0


def test_verification_rides_out_a_dropped_connection(device, deploy):
    # The device goes away for a second in the middle of verification (the
    # second Shelly.GetConfig; the first is the plan's).
    device.outages["Shelly.GetConfig"] = (2, 1.0)
    code, out = deploy("switch", wifi(device, {"ssid": "other"}))
    assert code == 0, out
    assert device.state()["calls"].count("Shelly.GetConfig") == 3


def test_a_lost_answer_to_a_network_change_is_verified(device, deploy):
    # The device stores the change but never answers the SetConfig call.
    device.dropping.add("Wifi.SetConfig")
    code, out = deploy("switch", wifi(device, {"ssid": "other"}))
    assert code == 0, out
    assert "no answer to wifi while the device reconnected; verified afterwards" in out
    assert device.config["wifi"]["sta"]["ssid"] == "other"


def test_a_device_given_a_static_ip_is_followed(make_device, deploy):
    device = make_device(hosts=("127.0.0.1", "127.0.0.2"), ip="127.0.0.1")
    sta = {"ipv4mode": "static", "ip": "127.0.0.2", "netmask": "255.0.0.0"}
    code, out = deploy("switch", wifi(device, sta))
    assert code == 0, out
    assert device.ip == "127.0.0.2"
    assert (
        f"the device now answers at 127.0.0.2:{device.port}; update its `address`"
        in out
    )


def test_a_static_ip_change_also_survives_a_reboot(make_device, deploy):
    device = make_device(hosts=("127.0.0.1", "127.0.0.2"), ip="127.0.0.1")
    devices = wifi(device, {"ipv4mode": "static", "ip": "127.0.0.2"})
    devices["porch"]["components"]["mqtt"] = {"enable": True}  # Requires a restart.
    code, out = deploy("switch", devices)
    assert code == 0, out
    assert device.reboots == 1
    assert "update its `address`" in out


def test_a_device_that_does_not_come_back_is_reported(make_device, deploy):
    # Nothing serves 127.0.0.3, so the device is cut off once it moves there.
    device = make_device(ip="127.0.0.1")
    code, out = deploy(
        "switch", wifi(device, {"ipv4mode": "static", "ip": "127.0.0.3"})
    )
    assert code == 1
    assert f"no answer at {device.address}, 127.0.0.3:{device.port} within 15s" in out
    assert "the change may have moved the device or cut it off" in out


def test_another_device_at_the_old_address_is_not_mistaken_for_it(make_device, deploy):
    device = make_device(hosts=("127.0.0.1", "127.0.0.2"), ip="127.0.0.1")
    # Once the device has moved, a different device answers at its old address.
    impostor = FakeShelly(mac="112233445566")
    device.successor = impostor
    code, out = deploy(
        "switch", wifi(device, {"ipv4mode": "static", "ip": "127.0.0.2"})
    )
    assert code == 0, out
    # It was asked who it is, and then left alone.
    assert "Shelly.GetDeviceInfo" in impostor.state()["calls"]
    assert "Shelly.GetConfig" not in impostor.state()["calls"]
    assert f"the device now answers at 127.0.0.2:{device.port}" in out


def test_an_http_error_is_not_mistaken_for_a_reconnect(device, deploy):
    # A device that answers with an HTTP error is reachable: the failure is
    # reported at once, not waited out as a reconnect.  (The second
    # Shelly.GetConfig is verification's.)
    device.http_errors["Shelly.GetConfig"] = 2
    code, out = deploy("switch", wifi(device, {"ssid": "other"}))
    assert code == 1
    assert "HTTP 500" in out
    assert "no answer at" not in out
