"""The manifest: what the Nix modules produce and shelly-deploy applies."""

from __future__ import annotations

import fnmatch
import json
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from core.utils.validation import normalize_mac

MANIFEST_VERSION = 1

NIX_FEATURES = ["--extra-experimental-features", "nix-command flakes"]


class ManifestError(Exception):
    """The manifest could not be produced, or does not make sense."""


@dataclass(frozen=True)
class DeviceSpec:
    """One device's entry in the manifest."""

    name: str
    address: str
    mac: str | None
    tags: tuple[str, ...]
    password_file: str | None
    components: dict[str, dict[str, Any]]
    reboot: str
    allow_network_changes: bool
    # Script name -> {"code": str, "enable": bool}.
    scripts: dict[str, dict[str, Any]] = field(default_factory=dict)
    # None leaves the device's schedules alone.
    schedules: list[dict[str, Any]] | None = None

    @classmethod
    def from_manifest(cls, name: str, raw: Any) -> DeviceSpec:
        try:
            auth = raw.get("auth") or {}
            deployment = raw.get("deployment") or {}
            mac = raw.get("mac")
            components = raw.get("components") or {}
            if not all(isinstance(c, dict) for c in components.values()):
                raise TypeError("component configurations must be objects")
            scripts = raw.get("scripts") or {}
            for script in scripts.values():
                if not isinstance(script["code"], str):
                    raise TypeError("script code must be a string")
            schedules = raw.get("schedules")
            if schedules is not None:
                for job in schedules:
                    if not isinstance(job["timespec"], str) or not job["calls"]:
                        raise TypeError("schedule jobs need a timespec and calls")
            return cls(
                name=name,
                address=raw["address"],
                mac=normalize_mac(mac) if mac else None,
                tags=tuple(raw.get("tags") or ()),
                password_file=auth.get("passwordFile"),
                components=components,
                reboot=deployment.get("reboot", "if-required"),
                allow_network_changes=bool(
                    deployment.get("allowNetworkChanges", False)
                ),
                scripts={
                    script_name: {
                        "code": script["code"],
                        "enable": bool(script.get("enable", True)),
                    }
                    for script_name, script in scripts.items()
                },
                schedules=None if schedules is None else list(schedules),
            )
        except (AttributeError, KeyError, TypeError) as e:
            raise ManifestError(f"device {name}: malformed entry ({e})") from e


def parse(document: Any) -> list[DeviceSpec]:
    """The devices in a manifest document, sorted by name."""
    if not isinstance(document, dict) or document.get("version") != MANIFEST_VERSION:
        raise ManifestError(
            f"not a manifest this version understands (expected version {MANIFEST_VERSION})"
        )
    devices = document.get("devices", {})
    if not isinstance(devices, dict):
        raise ManifestError("`devices` must be an object")
    return [DeviceSpec.from_manifest(name, devices[name]) for name in sorted(devices)]


def flake_command(ref: str) -> list[str]:
    """The command evaluating the manifest of `flake#name` (name defaults to `default`)."""
    flake, _, name = ref.partition("#")
    installable = f'{flake or "."}#shellyConfigurations."{name or "default"}".config.build.manifest'
    return ["nix", *NIX_FEATURES, "eval", "--json", installable]


def file_command(path: str, attr: str | None) -> list[str]:
    """The command evaluating the manifest of a configuration in a Nix file."""
    attr_path = f"{attr}.config.build.manifest" if attr else "config.build.manifest"
    return ["nix-instantiate", "--eval", "--strict", "--json", path, "-A", attr_path]


def evaluate(command: list[str], show_trace: bool = False) -> Any:
    """Run a Nix evaluation command and parse its JSON output."""
    if show_trace:
        command = [*command, "--show-trace"]
    try:
        result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    except FileNotFoundError as e:
        raise ManifestError(f"{command[0]} not found; is Nix installed?") from e
    except subprocess.CalledProcessError as e:
        raise ManifestError(f"evaluation failed: {shlex.join(command)}") from e
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise ManifestError(f"evaluation did not produce JSON: {e}") from e


def load(path: str) -> Any:
    """Read an already evaluated manifest."""
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"cannot read manifest {path}: {e}") from e


def select(devices: list[DeviceSpec], selections: list[str] | None) -> list[DeviceSpec]:
    """The devices matching any of the selections.

    Each selection is a comma-separated list of device names, which may be
    globs, and `@tag`s.  No selections means every device.
    """
    if not selections:
        return devices
    patterns = [p.strip() for s in selections for p in s.split(",") if p.strip()]

    def matches(device: DeviceSpec) -> bool:
        return any(
            p[1:] in device.tags
            if p.startswith("@")
            else fnmatch.fnmatchcase(device.name, p)
            for p in patterns
        )

    chosen = [d for d in devices if matches(d)]
    if not chosen:
        raise ManifestError(f"no devices match {', '.join(patterns)}")
    return chosen
