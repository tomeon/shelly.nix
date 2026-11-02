from __future__ import annotations

import copy
import json
from collections.abc import Callable, Iterator
from typing import Any

import pytest
from fake_shelly import FakeShelly, serve
from shelly_deploy import cli
from shelly_deploy import device as device_module


@pytest.fixture(autouse=True)
def quick_reconnects(monkeypatch: pytest.MonkeyPatch) -> None:
    """Look for reconnecting devices sooner than real devices need.

    As with real devices, the fake starts reconnecting (after 0.2s) before
    shelly-deploy looks for it again.
    """
    monkeypatch.setattr(device_module, "RECONNECT_DELAY", 0.5)


@pytest.fixture
def make_device() -> Iterator[Callable[..., FakeShelly]]:
    """Start fake devices; each gets `address` and `port` attributes.

    `hosts` are the local addresses the device is served on, all with the same
    port; the first is its `address`.
    """
    servers = []

    def make(*, hosts: tuple[str, ...] = ("127.0.0.1",), **kwargs: Any) -> FakeShelly:
        device = FakeShelly(**kwargs)
        first = serve(device, hosts[0])
        port = first.server_address[1]
        servers.append(first)
        servers.extend(serve(device, host, port) for host in hosts[1:])
        device.address = f"{hosts[0]}:{port}"
        device.port = port
        return device

    yield make
    for server in servers:
        server.shutdown()
        server.server_close()


@pytest.fixture
def device(make_device: Callable[..., FakeShelly]) -> FakeShelly:
    return make_device()


def entry(address: str, **overrides: Any) -> dict[str, Any]:
    """A manifest entry, as the Nix module would produce it."""
    result: dict[str, Any] = {
        "address": address,
        "mac": None,
        "tags": [],
        "auth": {"passwordFile": None},
        "deployment": {"allowNetworkChanges": False, "reboot": "if-required"},
        "components": {},
    }
    for key, value in overrides.items():
        if (
            isinstance(value, dict)
            and isinstance(result.get(key), dict)
            and key != "components"
        ):
            result[key] = {**result[key], **value}
        else:
            result[key] = copy.deepcopy(value)
    return result


@pytest.fixture
def deploy(tmp_path, capsys) -> Callable[..., tuple[int, str]]:
    """Run shelly-deploy on a manifest; returns its exit code and output."""

    def run(
        command: str, devices: dict[str, dict[str, Any]], *args: str
    ) -> tuple[int, str]:
        path = tmp_path / "manifest.json"
        path.write_text(json.dumps({"version": 1, "devices": devices}))
        extra = ["--timeout", "3"] if command != "build" else []
        if command == "switch":
            extra += ["--reboot-timeout", "15"]
        code = cli.main([command, "--manifest", str(path), *extra, *args])
        captured = capsys.readouterr()
        return code, captured.out + captured.err

    return run
