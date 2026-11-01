"""The `shelly-deploy` command."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from typing import Any

from . import manifest
from .device import Device, DeviceError, DevicePlan
from .manifest import DeviceSpec, ManifestError

MARKERS = {"changed": "~", "unreported": "?", "unchanged": "="}


def build_parser() -> argparse.ArgumentParser:
    source = argparse.ArgumentParser(add_help=False)
    group = source.add_argument_group(
        "configuration source (default: --flake .#default)"
    )
    exclusive = group.add_mutually_exclusive_group()
    exclusive.add_argument(
        "--flake",
        metavar="FLAKE#NAME",
        help="evaluate FLAKE's shellyConfigurations.NAME (NAME defaults to `default`)",
    )
    exclusive.add_argument(
        "-f", "--file", metavar="FILE", help="evaluate a configuration in a Nix file"
    )
    exclusive.add_argument(
        "--manifest", metavar="FILE", help="read an already evaluated manifest (JSON)"
    )
    group.add_argument(
        "-A", "--attr", help="attribute of --file holding the configuration"
    )
    group.add_argument(
        "--show-trace", action="store_true", help="pass --show-trace to Nix"
    )
    source.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="log more; repeat for debug output",
    )

    devices = argparse.ArgumentParser(add_help=False)
    devices.add_argument(
        "--on",
        action="append",
        metavar="SELECTION",
        help="comma-separated device names (globs allowed) and @tags; repeatable",
    )
    devices.add_argument(
        "--parallel",
        type=int,
        default=10,
        metavar="N",
        help="devices to work on at once (default: 10)",
    )
    devices.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        metavar="SECONDS",
        help="per-request timeout (default: 10)",
    )

    parser = argparse.ArgumentParser(
        prog="shelly-deploy",
        description="Deploy declarative Shelly device configurations.",
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    commands.add_parser(
        "build",
        parents=[source],
        help="evaluate the configuration and print its manifest",
    )
    commands.add_parser(
        "diff", parents=[source, devices], help="show what `switch` would change"
    )
    switch = commands.add_parser(
        "switch", parents=[source, devices], help="apply the configuration"
    )
    switch.add_argument(
        "--force",
        action="store_true",
        help="send every declared component, changed or not",
    )
    switch.add_argument(
        "--reboot-timeout",
        type=float,
        default=90.0,
        metavar="SECONDS",
        help="how long to wait for a rebooting device (default: 90)",
    )
    return parser


def load_document(args: argparse.Namespace) -> Any:
    if args.attr and not args.file:
        raise ManifestError("-A/--attr requires -f/--file")
    if args.manifest:
        return manifest.load(args.manifest)
    if args.file:
        return manifest.evaluate(
            manifest.file_command(args.file, args.attr), args.show_trace
        )
    return manifest.evaluate(
        manifest.flake_command(args.flake or ".#default"), args.show_trace
    )


def describe_device(spec: DeviceSpec, plan: DevicePlan | None) -> str:
    if plan is None:
        return f"{spec.name} ({spec.address})"
    info = plan.info
    model = info.get("app") or info.get("model") or "unknown model"
    return f"{spec.name} ({spec.address}): {model}, gen {info.get('gen')}, firmware {info.get('ver', '?')}"


def describe_plan(plan: DevicePlan, command: str) -> list[str]:
    lines = []
    for component in plan.components:
        line = f"  {MARKERS[component.status]} {component.key}"
        if component.status == "unreported" or (
            component.unreported and component.changes
        ):
            fields = ", ".join(".".join(p) for p in component.unreported)
            line += f" (not reported by the device: {fields})"
            if component.status == "unreported":
                line += (
                    "; use `switch --force` to send"
                    if command == "diff"
                    else "; not sent without --force"
                )
        lines.append(line)
        lines.extend(f"      {change.describe()}" for change in component.changes)
    return lines


async def deploy(
    args: argparse.Namespace, spec: DeviceSpec, limit: asyncio.Semaphore
) -> str:
    """Diff or switch one device; returns `changed`, `unchanged` or `failed`."""
    plan = None
    lines: list[str] = []
    outcome = "unchanged"
    async with limit:
        try:
            async with Device(
                spec,
                timeout=args.timeout,
                reboot_timeout=getattr(args, "reboot_timeout", 90.0),
            ) as device:
                plan = await device.plan()
                lines += describe_plan(plan, args.command)
                force = getattr(args, "force", False)
                if plan.pending(force):
                    outcome = "changed"
                    if args.command == "switch":
                        result = await device.apply(plan, force)
                        lines.append(f"  applied {', '.join(result.applied)}")
                        if result.restart_required:
                            restart = f"  restart required by {', '.join(result.restart_required)}: "
                            restart += (
                                "rebooted"
                                if result.rebooted
                                else "not rebooting (deployment.reboot = never)"
                            )
                            lines.append(restart)
        except DeviceError as e:
            lines.append(f"  error: {e}")
            outcome = "failed"
    print("\n".join([describe_device(spec, plan), *lines]), flush=True)
    return outcome


async def run(args: argparse.Namespace, devices: list[DeviceSpec]) -> int:
    limit = asyncio.Semaphore(max(1, args.parallel))
    outcomes = await asyncio.gather(*(deploy(args, spec, limit) for spec in devices))
    changed = outcomes.count("changed")
    failed = outcomes.count("failed")
    verb = "to change" if args.command == "diff" else "changed"
    print(
        f"{len(devices)} device(s): {changed} {verb}, {outcomes.count('unchanged')} unchanged, {failed} failed"
    )
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(format="%(levelname)s %(name)s: %(message)s")
    if args.verbose:
        logging.getLogger().setLevel(
            logging.DEBUG if args.verbose > 1 else logging.INFO
        )
    else:
        # shelly-manager-core warns about failures that are reported anyway.
        logging.getLogger("core").setLevel(logging.ERROR)

    try:
        document = load_document(args)
        devices = manifest.parse(document)
        if args.command == "build":
            json.dump(document, sys.stdout, indent=2, sort_keys=True)
            print()
            return 0
        devices = manifest.select(devices, args.on)
    except ManifestError as e:
        print(f"shelly-deploy: {e}", file=sys.stderr)
        return 2

    return asyncio.run(run(args, devices))
