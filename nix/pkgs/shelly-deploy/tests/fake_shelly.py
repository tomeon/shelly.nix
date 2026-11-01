#!/usr/bin/env python3
"""A fake Shelly Gen2+ device, for tests.

It speaks enough of the RPC protocol (https://shelly-api-docs.shelly.cloud/gen2/)
for shelly-deploy: device information, component configuration, status and
reboot, with optional digest authentication.  It uses only the standard
library, so that NixOS VM tests can run it with a bare Python.

`GET /_test/state` returns everything, write-only fields included, so that
tests can check what a device was sent.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import hmac
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

# Fields that SetConfig accepts but GetConfig never reports.
WRITE_ONLY = {
    "mqtt": [("pass",)],
    "wifi": [("ap", "pass"), ("sta", "pass"), ("sta1", "pass")],
}

# Component types whose changes take effect only after a restart.
RESTART_REQUIRED = {"ble", "cloud", "eth", "mqtt", "wifi", "ws"}

# Script.GetCode hands out at most this many bytes at a time.
GET_CODE_BYTES = 512

# A script containing this fails as soon as it starts.
CRASH_MARKER = "crash()"


def default_config(mac: str) -> dict[str, Any]:
    """Roughly a Shelly Plus 1PM's configuration."""
    device_id = f"shellyplus1pm-{mac.lower()}"
    return {
        "ble": {"enable": True, "rpc": {"enable": True}, "observer": {"enable": False}},
        "cloud": {"enable": False, "server": "iot.shelly.cloud:6012/jrpc"},
        "input:0": {
            "id": 0,
            "name": None,
            "type": "switch",
            "enable": True,
            "invert": False,
            "factory_reset": True,
        },
        "mqtt": {
            "enable": False,
            "server": None,
            "client_id": device_id,
            "user": None,
            "ssl_ca": None,
            "topic_prefix": device_id,
            "rpc_ntf": True,
            "status_ntf": False,
            "use_client_cert": False,
            "enable_rpc": True,
            "enable_control": True,
        },
        "switch:0": {
            "id": 0,
            "name": None,
            "in_mode": "follow",
            "initial_state": "match_input",
            "auto_on": False,
            "auto_on_delay": 60.0,
            "auto_off": False,
            "auto_off_delay": 60.0,
            "power_limit": 4480,
            "voltage_limit": 280,
            "current_limit": 16.0,
        },
        "sys": {
            "device": {
                "name": None,
                "mac": mac,
                "fw_id": "20241011-114455/1.4.4-g6d2a586",
                "discoverable": True,
                "eco_mode": False,
            },
            "location": {"tz": "Europe/Sofia", "lat": 42.6534, "lon": 23.31119},
            "debug": {
                "level": 2,
                "mqtt": {"enable": False},
                "websocket": {"enable": False},
            },
            "ui_data": {},
            "rpc_udp": {"dst_addr": None, "listen_port": None},
            "sntp": {"server": "time.google.com"},
            "cfg_rev": 10,
        },
        "wifi": {
            "ap": {"ssid": f"ShellyPlus1PM-{mac}", "is_open": True, "enable": False},
            "sta": {
                "ssid": "home",
                "is_open": False,
                "enable": True,
                "ipv4mode": "dhcp",
            },
            "sta1": {
                "ssid": None,
                "is_open": True,
                "enable": False,
                "ipv4mode": "dhcp",
            },
            "roam": {"rssi_thr": -80, "interval": 60},
        },
    }


def _merge(target: dict[str, Any], update: dict[str, Any]) -> None:
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


class FakeShelly:
    """The device's state and RPC behaviour."""

    def __init__(
        self,
        *,
        mac: str = "AABBCCDDEEFF",
        gen: int = 2,
        password: str | None = None,
        boot_seconds: float = 1.0,
    ):
        self.mac = mac
        self.gen = gen
        self.password = password
        self.boot_seconds = boot_seconds
        self.device_id = f"shellyplus1pm-{mac.lower()}"
        self.config = default_config(mac)
        self.lock = threading.Lock()
        self.booted_at = time.monotonic() - 100.0
        self.reboot_at: float | None = None
        self.reboots = 0
        self.calls: list[tuple[str, Any]] = []
        # Script id -> {"id", "name", "enable", "running", "code"}.
        self.scripts: dict[int, dict[str, Any]] = {}
        self.jobs: list[dict[str, Any]] = []
        self.next_id = 1
        # Test hooks: methods that fail, and components that ignore SetConfig.
        self.failing: set[str] = set()
        self.ignoring: set[str] = set()

    # Reboots happen `delay_ms` after Shelly.Reboot; the device then answers
    # nothing for `boot_seconds`, and comes back with its uptime reset.
    def is_down(self) -> bool:
        with self.lock:
            now = time.monotonic()
            if self.reboot_at is not None and now >= self.reboot_at:
                self.booted_at = self.reboot_at + self.boot_seconds
                self.reboot_at = None
                self.reboots += 1
                for script in self.scripts.values():
                    script["running"] = script["enable"] and not _crashes(script)
            return now < self.booted_at

    def device_info(self) -> dict[str, Any]:
        return {
            "name": self.config["sys"]["device"]["name"],
            "id": self.device_id,
            "mac": self.mac,
            "slot": 0,
            "model": "SNSW-001P16EU",
            "gen": self.gen,
            "fw_id": "20241011-114455/1.4.4-g6d2a586",
            "ver": "1.4.4",
            "app": "Plus1PM",
            "auth_en": self.password is not None,
            "auth_domain": self.device_id if self.password is not None else None,
        }

    def reported(self, key: str) -> dict[str, Any]:
        config = copy.deepcopy(self.config[key])
        for path in WRITE_ONLY.get(key.partition(":")[0], []):
            section = config
            for part in path[:-1]:
                section = section.get(part, {})
            section.pop(path[-1], None)
        return config

    def sys_status(self) -> dict[str, Any]:
        return {"mac": self.mac, "uptime": int(time.monotonic() - self.booted_at)}

    def challenge(self) -> str:
        return f'Digest qop="auth", realm="{self.device_id}", nonce="{int(time.time())}", algorithm=SHA-256'

    def authorized(self, header: str | None, method: str) -> bool:
        if self.password is None:
            return True
        if not header or not header.startswith("Digest "):
            return False
        fields = {
            m[1]: m[2] if m[2] is not None else m[3]
            for m in re.finditer(r'(\w+)=(?:"([^"]*)"|([^\s,]+))', header[7:])
        }
        try:
            ha1 = _sha256(f"{fields['username']}:{fields['realm']}:{self.password}")
            ha2 = _sha256(f"{method}:{fields['uri']}")
            expected = _sha256(
                f"{ha1}:{fields['nonce']}:{fields['nc']}:{fields['cnonce']}:{fields['qop']}:{ha2}"
            )
        except KeyError:
            return False
        return (
            fields["username"] == "admin"
            and fields["realm"] == self.device_id
            and hmac.compare_digest(expected, fields.get("response", ""))
        )

    def dispatch(
        self, method: str, params: dict[str, Any]
    ) -> tuple[Any, tuple[int, str] | None]:
        """Run an RPC call, returning `(result, error)`."""
        with self.lock:
            self.calls.append((method, copy.deepcopy(params)))
            if method in self.failing:
                return None, (-103, f"{method} failed (test hook)")
            namespace, _, name = method.lower().partition(".")

            if namespace == "shelly":
                if name == "getdeviceinfo":
                    return self.device_info(), None
                if name == "getconfig":
                    config = {key: self.reported(key) for key in self.config}
                    for script in self.scripts.values():
                        config[f"script:{script['id']}"] = _script_config(script)
                    return config, None
                if name == "getstatus":
                    return {"sys": self.sys_status()}, None
                if name == "reboot":
                    self.reboot_at = (
                        time.monotonic() + params.get("delay_ms", 1000) / 1000
                    )
                    return None, None

            if namespace == "script":
                return self.script_call(name, params)
            if namespace == "schedule":
                return self.schedule_call(name, params)

            if name in ("getconfig", "setconfig", "getstatus"):
                key = f"{namespace}:{params['id']}" if "id" in params else namespace
                if key not in self.config:
                    return None, (
                        -105,
                        f"Argument 'id', value {params.get('id')} not found!",
                    )
                if name == "getconfig":
                    return self.reported(key), None
                if name == "getstatus":
                    return (
                        self.sys_status() if key == "sys" else {"id": params.get("id")}
                    ), None
                config = params.get("config")
                if not isinstance(config, dict):
                    return None, (-103, "Invalid argument 'config'!")
                if key not in self.ignoring:
                    _merge(self.config[key], config)
                    self.config["sys"]["cfg_rev"] += 1
                return {
                    "restart_required": key.partition(":")[0] in RESTART_REQUIRED
                }, None

            return None, (404, f"No handler for {method}")

    def add_script(self, name: str, code: str = "", enable: bool = False) -> int:
        """Put a script on the device, as if created by hand."""
        with self.lock:
            script_id = self.next_id
            self.next_id += 1
            self.scripts[script_id] = {
                "id": script_id,
                "name": name,
                "enable": enable,
                "running": enable,
                "code": code,
            }
            return script_id

    def script_call(self, name: str, params: dict[str, Any]) -> tuple[Any, Any]:
        if name == "list":
            listed = [
                {k: s[k] for k in ("id", "name", "enable", "running")}
                for s in self.scripts.values()
            ]
            return {"scripts": listed}, None
        if name == "create":
            script_id = self.next_id
            self.next_id += 1
            self.scripts[script_id] = {
                "id": script_id,
                "name": params.get("name") or f"script_{script_id}",
                "enable": False,
                "running": False,
                "code": "",
            }
            return {"id": script_id}, None

        script = self.scripts.get(params.get("id"))
        if script is None:
            return None, (-105, f"Argument 'id', value {params.get('id')} not found!")
        if name == "getcode":
            data = script["code"].encode()
            start = int(params.get("offset", 0))
            end = min(len(data), start + GET_CODE_BYTES)
            while end < len(data) and data[end] & 0xC0 == 0x80:
                end -= 1  # Not in the middle of a character.
            return {"data": data[start:end].decode(), "left": len(data) - end}, None
        if name == "putcode":
            if script["running"]:
                return None, (-103, "Script is running!")
            code = params.get("code", "")
            script["code"] = script["code"] + code if params.get("append") else code
            return {"len": len(script["code"].encode())}, None
        if name == "getconfig":
            return _script_config(script), None
        if name == "setconfig":
            config = params.get("config") or {}
            for key in ("name", "enable"):
                if key in config:
                    script[key] = config[key]
            return {"restart_required": False}, None
        if name == "start":
            was_running = script["running"]
            script["running"] = not _crashes(script)
            return {"was_running": was_running}, None
        if name == "stop":
            was_running = script["running"]
            script["running"] = False
            return {"was_running": was_running}, None
        if name == "delete":
            del self.scripts[script["id"]]
            return None, None
        return None, (404, f"No handler for Script.{name}")

    def schedule_call(self, name: str, params: dict[str, Any]) -> tuple[Any, Any]:
        if name == "list":
            return {"jobs": copy.deepcopy(self.jobs), "rev": len(self.calls)}, None
        if name == "deleteall":
            self.jobs = []
            return {"rev": len(self.calls)}, None
        if name == "create":
            if not params.get("timespec") or not params.get("calls"):
                return None, (-103, "Missing argument 'timespec' or 'calls'!")
            job_id = self.next_id
            self.next_id += 1
            job = {"id": job_id, "enable": params.get("enable", True)}
            job["timespec"] = params["timespec"]
            # Like a device, leave out parameters that were not given.
            job["calls"] = [
                {k: v for k, v in call.items() if k != "params" or v}
                for call in params["calls"]
            ]
            self.jobs.append(job)
            return {"id": job_id, "rev": len(self.calls)}, None
        return None, (404, f"No handler for Schedule.{name}")

    def state(self) -> dict[str, Any]:
        with self.lock:
            return {
                "config": copy.deepcopy(self.config),
                "scripts": copy.deepcopy(list(self.scripts.values())),
                "jobs": copy.deepcopy(self.jobs),
                "reboots": self.reboots,
                "calls": [method for method, _ in self.calls],
            }


def _script_config(script: dict[str, Any]) -> dict[str, Any]:
    return {k: script[k] for k in ("id", "name", "enable")}


def _crashes(script: dict[str, Any]) -> bool:
    return CRASH_MARKER in script["code"]


class Handler(BaseHTTPRequestHandler):
    server: Server

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def _send_json(
        self, status: int, body: Any, headers: dict[str, str] | None = None
    ) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        device = self.server.device
        if self.path == "/_test/state":
            self._send_json(200, device.state())
        elif device.is_down():
            self.close_connection = True
        elif self.path == "/shelly" and device.gen < 2:
            self._send_json(
                200,
                {
                    "type": "SHSW-1",
                    "mac": device.mac,
                    "auth": False,
                    "fw": "20230913-112003/v1.14.0",
                },
            )
        elif self.path == "/shelly":
            self._send_json(200, device.device_info())
        else:
            self._send_json(404, {"code": 404, "message": "Not Found"})

    def do_POST(self) -> None:
        device = self.server.device
        if device.is_down():
            # A rebooting device does not answer at all.
            self.close_connection = True
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            frame = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"code": 400, "message": "Bad Request"})
            return
        if self.path.partition("?")[0] != "/rpc" or device.gen < 2:
            self._send_json(404, {"code": 404, "message": "Not Found"})
            return

        method = str(frame.get("method", ""))
        params = frame.get("params") or {}
        if method.lower() != "shelly.getdeviceinfo" and not device.authorized(
            self.headers.get("Authorization"), self.command
        ):
            self._send_json(
                401,
                {"code": 401, "message": "Unauthorized"},
                {"WWW-Authenticate": device.challenge()},
            )
            return

        result, error = device.dispatch(method, params)
        response: dict[str, Any] = {"id": frame.get("id"), "src": device.device_id}
        if error is None:
            response["result"] = result
        else:
            response["error"] = {"code": error[0], "message": error[1]}
        self._send_json(200, response)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], device: FakeShelly):
        super().__init__(address, Handler)
        self.device = device


def serve(device: FakeShelly, host: str = "127.0.0.1", port: int = 0) -> Server:
    """Serve a device from a background thread; `server.shutdown()` stops it."""
    server = Server((host, port), device)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--mac", default="AABBCCDDEEFF")
    parser.add_argument("--gen", type=int, default=2)
    parser.add_argument("--password-file")
    args = parser.parse_args()
    password = None
    if args.password_file:
        with open(args.password_file) as f:
            password = f.read().rstrip("\r\n")
    device = FakeShelly(mac=args.mac, gen=args.gen, password=password)
    Server((args.host, args.port), device).serve_forever()


if __name__ == "__main__":
    main()
