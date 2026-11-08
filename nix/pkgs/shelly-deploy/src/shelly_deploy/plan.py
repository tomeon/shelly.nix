"""Comparing declared component configuration with what a device reports.

Only declared fields are compared.  Write-only fields (passwords, and any value
given as a `_secret`) are not reported by devices, so they cannot be checked:
they are "unreported", and a component whose only possible differences lie in
them is re-sent only when asked to (`switch --force`).  Any other declared
field the device does not report is a change.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FieldPath = tuple[str, ...]

# Fields that SetConfig accepts but GetConfig never returns, by component type,
# as documented at https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/
WRITE_ONLY: dict[str, frozenset[FieldPath]] = {
    "mqtt": frozenset({("pass",)}),
    "wifi": frozenset({("ap", "pass"), ("sta", "pass"), ("sta1", "pass")}),
}


class _Absent:
    """What a field the device does not report "is"."""

    def __repr__(self) -> str:
        return "(absent)"


ABSENT: Any = _Absent()


class SecretError(Exception):
    """A secret file could not be read."""


def read_secret(path: str) -> str:
    """A secret file's contents, without trailing newlines."""
    try:
        return Path(path).read_text(encoding="utf-8").rstrip("\r\n")
    except OSError as e:
        raise SecretError(f"cannot read secret {path}: {e.strerror}") from e
    except UnicodeDecodeError as e:
        raise SecretError(f"cannot read secret {path}: not valid UTF-8") from e


def resolve_secrets(value: Any) -> tuple[Any, frozenset[FieldPath]]:
    """Replace `{"_secret": path}` placeholders with the files' contents.

    Returns the resolved value and the paths at which secrets were found.
    """
    found: set[FieldPath] = set()

    def walk(v: Any, path: FieldPath) -> Any:
        if isinstance(v, dict):
            if set(v) == {"_secret"}:
                found.add(path)
                return read_secret(v["_secret"])
            return {k: walk(x, (*path, k)) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x, (*path, str(i))) for i, x in enumerate(v)]
        return v

    return walk(value, ()), frozenset(found)


def same(a: Any, b: Any) -> bool:
    """JSON equality: unlike `==`, `true` is not `1`."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, int | float) and isinstance(b, int | float):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b, strict=True))
    return type(a) is type(b) and a == b


@dataclass(frozen=True)
class Change:
    """A declared field whose value differs on the device."""

    path: FieldPath
    old: Any
    new: Any
    secret: bool

    def describe(self) -> str:
        def show(value: Any) -> str:
            if value is ABSENT:
                return "(absent)"
            return "<secret>" if self.secret else json.dumps(value, sort_keys=True)

        return f"{'.'.join(self.path)}: {show(self.old)} -> {show(self.new)}"


@dataclass
class ComponentPlan:
    """How one declared component compares with the device."""

    key: str
    desired: dict[str, Any]
    current: Any = None
    changes: list[Change] = field(default_factory=list)
    unreported: list[FieldPath] = field(default_factory=list)

    @property
    def status(self) -> str:
        if self.changes:
            return "changed"
        if self.unreported:
            return "unreported"
        return "unchanged"


def plan_component(key: str, declared: dict[str, Any], current: Any) -> ComponentPlan:
    """Compare a component's declared configuration with the device's."""
    desired, secrets = resolve_secrets(declared)
    plan = ComponentPlan(key=key, desired=desired, current=current)
    write_only = WRITE_ONLY.get(key.partition(":")[0], frozenset())

    def is_secret(path: FieldPath) -> bool:
        return any(s[: len(path)] == path or path[: len(s)] == s for s in secrets)

    def compare(want: Any, have: Any, path: FieldPath) -> None:
        if isinstance(want, dict) and isinstance(have, dict):
            for k, v in want.items():
                if k in have:
                    compare(v, have[k], (*path, k))
                elif (*path, k) in write_only or is_secret((*path, k)):
                    plan.unreported.append((*path, k))
                else:
                    plan.changes.append(
                        Change((*path, k), ABSENT, v, is_secret((*path, k)))
                    )
        elif not same(want, have):
            plan.changes.append(Change(path, have, want, is_secret(path)))

    compare(desired, current, ())
    return plan


def _size(code: str | None) -> str:
    return "none" if code is None else f"{len(code.encode())} bytes"


@dataclass
class ScriptPlan:
    """How one declared script compares with the device.

    `id` is None when the device has no script of that name yet.
    """

    name: str
    code: str
    enable: bool
    id: int | None = None
    current_code: str | None = None
    current_enable: bool | None = None
    running: bool | None = None

    @property
    def code_changed(self) -> bool:
        return self.current_code != self.code

    @property
    def status(self) -> str:
        if self.id is None:
            return "new"
        if (
            self.code_changed
            or self.current_enable != self.enable
            or self.running != self.enable
        ):
            return "changed"
        return "unchanged"

    def describe(self) -> list[str]:
        if self.id is None:
            return [f"code: {_size(self.code)}", f"enable: {json.dumps(self.enable)}"]
        lines = []
        if self.code_changed:
            lines.append(f"code: {_size(self.current_code)} -> {_size(self.code)}")
        if self.current_enable != self.enable:
            lines.append(
                f"enable: {json.dumps(self.current_enable)} -> {json.dumps(self.enable)}"
            )
        if self.running != self.enable:
            lines.append(
                f"running: {json.dumps(self.running)} -> {json.dumps(self.enable)}"
            )
        return lines


def normalise_job(job: dict[str, Any]) -> dict[str, Any]:
    """A schedule job as Schedule.Create takes it, without the device's id."""
    return {
        "enable": bool(job.get("enable", True)),
        "timespec": job.get("timespec"),
        "calls": [
            {"method": call.get("method"), "params": call.get("params") or {}}
            for call in job.get("calls") or []
        ],
    }


def _summary(job: dict[str, Any]) -> str:
    methods = ", ".join(str(call["method"]) for call in job["calls"])
    return f"{job['timespec']}: {methods}" + ("" if job["enable"] else " (disabled)")


@dataclass
class SchedulePlan:
    """How the declared schedule jobs compare with the device's."""

    desired: list[dict[str, Any]]
    current: list[dict[str, Any]]
    # The device's ids for the `current` jobs, in the same order.
    current_ids: list[Any] = field(default_factory=list)

    @property
    def status(self) -> str:
        return "unchanged" if same(self.desired, self.current) else "changed"

    def describe(self) -> list[str]:
        """Removed and added jobs, without their parameters (which may hold secrets)."""
        if self.status == "unchanged":
            return []

        def key(job: dict[str, Any]) -> str:
            return json.dumps(job, sort_keys=True)

        unmatched = [key(job) for job in self.desired]
        removed = []
        for job in self.current:
            if key(job) in unmatched:
                unmatched.remove(key(job))
            else:
                removed.append(job)
        added = [job for job in self.desired if key(job) in unmatched]
        lines = [f"- {_summary(job)}" for job in removed]
        lines += [f"+ {_summary(job)}" for job in added]
        return lines or ["order changed"]


def plan_schedules(declared: list[dict[str, Any]], current: Any) -> SchedulePlan:
    """Compare declared schedule jobs with the device's `Schedule.List` jobs."""
    desired, _ = resolve_secrets(declared)
    jobs = current.get("jobs") if isinstance(current, dict) else None
    jobs = [job for job in jobs or [] if isinstance(job, dict)]
    return SchedulePlan(
        desired=[normalise_job(job) for job in desired],
        current=[normalise_job(job) for job in jobs],
        current_ids=[job.get("id") for job in jobs],
    )
