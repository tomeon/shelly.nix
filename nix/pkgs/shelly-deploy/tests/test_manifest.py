import json
import subprocess

import pytest
from conftest import entry
from shelly_deploy import manifest
from shelly_deploy.manifest import ManifestError


def test_parse_sorts_and_normalises():
    devices = manifest.parse(
        {
            "version": 1,
            "devices": {
                "b": entry("10.0.0.2", mac="aa:bb:cc:dd:ee:ff"),
                "a": entry("10.0.0.1"),
            },
        }
    )
    assert [d.name for d in devices] == ["a", "b"]
    assert devices[1].mac == "AABBCCDDEEFF"


@pytest.mark.parametrize(
    "document",
    [
        [],
        {"devices": {}},
        {"version": 2, "devices": {}},
        {"version": 1, "devices": []},
        {"version": 1, "devices": {"a": {}}},
        {"version": 1, "devices": {"a": entry("x", components={"sys": 1})}},
    ],
)
def test_parse_rejects_malformed_manifests(document):
    with pytest.raises(ManifestError):
        manifest.parse(document)


def test_select():
    devices = manifest.parse(
        {
            "version": 1,
            "devices": {
                "porch": entry("1", tags=["outdoor"]),
                "patio": entry("2", tags=["outdoor"]),
                "kitchen": entry("3", tags=["indoor"]),
            },
        }
    )

    def names(*selections):
        return [d.name for d in manifest.select(devices, list(selections))]

    assert names() == ["kitchen", "patio", "porch"]
    assert names("@outdoor") == ["patio", "porch"]
    assert names("kitchen,porch") == ["kitchen", "porch"]
    assert names("p*") == ["patio", "porch"]
    assert names("kitchen", "@outdoor") == ["kitchen", "patio", "porch"]
    with pytest.raises(ManifestError, match="no devices match"):
        names("@nothing")


def test_flake_command():
    assert manifest.flake_command(".#home") == [
        "nix",
        "--extra-experimental-features",
        "nix-command flakes",
        "eval",
        "--json",
        '.#shellyConfigurations."home".config.build.manifest',
    ]
    assert manifest.flake_command("github:me/devices")[-1] == (
        'github:me/devices#shellyConfigurations."default".config.build.manifest'
    )
    assert (
        manifest.flake_command("#x")[-1]
        == '.#shellyConfigurations."x".config.build.manifest'
    )


def test_file_command():
    assert manifest.file_command("fleet.nix", None) == [
        "nix-instantiate",
        "--eval",
        "--strict",
        "--json",
        "fleet.nix",
        "-A",
        "config.build.manifest",
    ]
    assert (
        manifest.file_command("fleet.nix", "home")[-1] == "home.config.build.manifest"
    )


def test_evaluate(monkeypatch):
    seen = []

    def run(command, **kwargs):
        seen.append(command)
        return subprocess.CompletedProcess(
            command, 0, stdout=json.dumps({"version": 1})
        )

    monkeypatch.setattr(subprocess, "run", run)
    assert manifest.evaluate(["nix", "eval"], show_trace=True) == {"version": 1}
    assert seen == [["nix", "eval", "--show-trace"]]


def test_evaluate_failure(monkeypatch):
    def run(command, **kwargs):
        raise subprocess.CalledProcessError(1, command)

    monkeypatch.setattr(subprocess, "run", run)
    with pytest.raises(ManifestError, match="evaluation failed"):
        manifest.evaluate(["nix", "eval"])


def test_evaluate_without_nix(monkeypatch):
    def run(command, **kwargs):
        raise FileNotFoundError(command[0])

    monkeypatch.setattr(subprocess, "run", run)
    with pytest.raises(ManifestError, match="is Nix installed"):
        manifest.evaluate(["nix", "eval"])
