"""Comparing declared component configuration with what a device reports.

Only declared fields are compared.  A declared field the device does not
report, such as a password, cannot be checked; it is "unreported", and such a
component is only re-sent when asked to (`switch --force`).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FieldPath = tuple[str, ...]


class SecretError(Exception):
    """A secret file could not be read."""


def read_secret(path: str) -> str:
    """A secret file's contents, without trailing newlines."""
    try:
        return Path(path).read_text().rstrip("\r\n")
    except OSError as e:
        raise SecretError(f"cannot read secret {path}: {e.strerror}") from e


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
            return "<secret>" if self.secret else json.dumps(value, sort_keys=True)

        return f"{'.'.join(self.path)}: {show(self.old)} -> {show(self.new)}"


@dataclass
class ComponentPlan:
    """How one declared component compares with the device."""

    key: str
    desired: dict[str, Any]
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
    plan = ComponentPlan(key=key, desired=desired)

    def is_secret(path: FieldPath) -> bool:
        return any(s[: len(path)] == path or path[: len(s)] == s for s in secrets)

    def compare(want: Any, have: Any, path: FieldPath) -> None:
        if isinstance(want, dict) and isinstance(have, dict):
            for k, v in want.items():
                if k in have:
                    compare(v, have[k], (*path, k))
                else:
                    plan.unreported.append((*path, k))
        elif not same(want, have):
            plan.changes.append(Change(path, have, want, is_secret(path)))

    compare(desired, current, ())
    return plan
