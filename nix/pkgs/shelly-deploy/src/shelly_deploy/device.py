"""One device, reached over the Gen2+ RPC protocol through shelly-manager-core."""

from __future__ import annotations

import asyncio
import ipaddress
import socket
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, Self

from core.domain.credentials import Credential
from core.domain.entities.exceptions import (
    DeviceAuthenticationError,
    DeviceCommunicationError,
    ShellyManagerError,
)
from core.domain.value_objects.component_namespace import ComponentNamespace
from core.gateways.network.async_shelly_rpc_client import AsyncShellyRPCClient
from core.gateways.network.rpc_envelope import RpcError, rpc_result
from core.repositories.credentials_repository import CredentialsRepository
from core.services.auth_state_cache import AuthStateCache
from core.services.authentication_service import AuthenticationService
from core.utils.validation import normalize_mac

from .manifest import DeviceSpec
from .plan import (
    ComponentPlan,
    SchedulePlan,
    ScriptPlan,
    SecretError,
    plan_component,
    plan_schedules,
    read_secret,
)

# Components whose misconfiguration can leave a device unreachable.  They are
# applied last, and only when the manifest allows it.
NETWORK_COMPONENTS = frozenset({"wifi", "eth"})

# Gen2+ devices have a single user.
USERNAME = "admin"

# Script code is uploaded in pieces of at most this many bytes.
SCRIPT_CHUNK_BYTES = 1024


class DeviceError(Exception):
    """Something went wrong with one device; other devices carry on."""


class _PasswordFile(CredentialsRepository):
    """The one device's credentials, whatever MAC address it reports."""

    def __init__(self, password: str | None):
        self._password = password

    async def get(self, mac: str) -> Credential | None:
        if self._password is None:
            return None
        return Credential(mac=mac, username=USERNAME, password=self._password)

    async def get_global(self) -> Credential | None:
        return None

    async def set(
        self, mac: str, username: str, password: str, last_seen_ip: str | None = None
    ) -> None:
        raise NotImplementedError

    async def delete(self, mac: str) -> None:
        raise NotImplementedError

    async def list_all(self) -> list[Credential | None]:
        return []


def _component_type(key: str) -> str:
    return key.partition(":")[0]


def _chunks(text: str, size: int) -> list[str]:
    """Split text into pieces of at most `size` UTF-8 bytes, between characters."""
    chunks, current, length = [], [], 0
    for char in text:
        width = len(char.encode())
        if current and length + width > size:
            chunks.append("".join(current))
            current, length = [], 0
        current.append(char)
        length += width
    chunks.append("".join(current))
    return chunks


@dataclass
class DevicePlan:
    """How a device compares with its declared configuration."""

    info: dict[str, Any]
    components: list[ComponentPlan]
    scripts: list[ScriptPlan] = field(default_factory=list)
    schedules: SchedulePlan | None = None

    def pending(self, force: bool = False) -> list[ComponentPlan]:
        """The components to send: those that differ, or all of them if forced.

        Network components come last.
        """
        chosen = [c for c in self.components if force or c.status == "changed"]
        return sorted(
            chosen, key=lambda c: _component_type(c.key) in NETWORK_COMPONENTS
        )

    def pending_scripts(self, force: bool = False) -> list[ScriptPlan]:
        return [s for s in self.scripts if force or s.status != "unchanged"]

    def schedules_pending(self, force: bool = False) -> bool:
        return self.schedules is not None and (
            force or self.schedules.status == "changed"
        )

    def has_pending(self, force: bool = False) -> bool:
        return bool(
            self.pending(force)
            or self.pending_scripts(force)
            or self.schedules_pending(force)
        )

    def differences(self) -> list[str]:
        """What still differs, for reporting changes that did not take effect."""
        found = [
            change.describe()
            for c in self.components
            if c.status == "changed"
            for change in c.changes
        ]
        found += [
            f"script {s.name}: {', '.join(s.describe())}"
            for s in self.scripts
            if s.status != "unchanged"
        ]
        if self.schedules is not None and self.schedules.status == "changed":
            found.append("schedules: " + ", ".join(self.schedules.describe()))
        return found


@dataclass
class ApplyResult:
    applied: list[str] = field(default_factory=list)
    restart_required: list[str] = field(default_factory=list)
    rebooted: bool = False


async def resolve(address: str) -> str:
    """The `ip[:port]` to send requests to for a manifest address."""
    if address.count(":") > 1 or address.startswith("["):
        raise DeviceError("IPv6 addresses are not supported")
    host, sep, port = address.rpartition(":")
    if not sep:
        host, port = address, ""
    elif not port.isdigit():
        raise DeviceError(f"invalid port in address {address}")
    try:
        ipaddress.IPv4Address(host)
        ip = host
    except ValueError:
        loop = asyncio.get_running_loop()
        try:
            infos = await loop.getaddrinfo(
                host, None, family=socket.AF_INET, type=socket.SOCK_STREAM
            )
        except socket.gaierror as e:
            raise DeviceError(f"cannot resolve {host}: {e.strerror}") from e
        ip = infos[0][4][0]
    return f"{ip}:{port}" if port else ip


class Device:
    """A connection to one device.  Use as an async context manager."""

    def __init__(
        self, spec: DeviceSpec, *, timeout: float = 10.0, reboot_timeout: float = 90.0
    ):
        self.spec = spec
        self.timeout = timeout
        self.reboot_timeout = reboot_timeout
        self._target = ""
        self._client: AsyncShellyRPCClient | None = None

    async def __aenter__(self) -> Self:
        try:
            password = (
                read_secret(self.spec.password_file)
                if self.spec.password_file
                else None
            )
        except SecretError as e:
            raise DeviceError(str(e)) from e
        credentials = _PasswordFile(password)

        @asynccontextmanager
        async def repository() -> AsyncIterator[CredentialsRepository]:
            yield credentials

        self._target = await resolve(self.spec.address)
        self._client = AsyncShellyRPCClient(
            timeout=self.timeout,
            connect_timeout=min(self.timeout, 5.0),
            verify=False,
            authentication_service=AuthenticationService(repository),
            auth_state_cache=AuthStateCache(),
        )
        return self

    async def __aexit__(self, *exc: object) -> None:
        if self._client is not None:
            await self._client.close()

    async def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        """Call an RPC method, returning its result."""
        assert self._client is not None, "use Device as an async context manager"
        try:
            response, _ = await self._client.make_rpc_request(
                self._target, method, params, timeout=self.timeout
            )
            return rpc_result(response)
        except RpcError as e:
            raise DeviceError(f"{method}: {e.message} (code {e.code})") from e
        except DeviceAuthenticationError as e:
            hint = (
                "check auth.passwordFile"
                if self.spec.password_file
                else "the device requires a password; set auth.passwordFile"
            )
            raise DeviceError(f"authentication failed ({hint})") from e
        except DeviceCommunicationError as e:
            if str(e.details.get("error", "")).startswith("HTTP 404"):
                raise DeviceError(
                    "no Gen2+ RPC endpoint; Gen1 devices are not supported"
                ) from e
            raise DeviceError(e.message) from e
        except ShellyManagerError as e:
            raise DeviceError(e.message) from e

    async def plan(self) -> DevicePlan:
        """Compare the device with its declared configuration, changing nothing."""
        info = await self.call("Shelly.GetDeviceInfo")
        if not isinstance(info, dict):
            raise DeviceError("unexpected answer to Shelly.GetDeviceInfo")
        gen = info.get("gen")
        if not isinstance(gen, int) or gen < 2:
            raise DeviceError("not a Gen2+ device; Gen1 devices are not supported")

        mac = info.get("mac")
        if self.spec.mac and normalize_mac(str(mac or "")) != self.spec.mac:
            raise DeviceError(
                f"MAC mismatch: expected {self.spec.mac}, device reports {mac}"
            )

        blocked = sorted(
            k for k in self.spec.components if _component_type(k) in NETWORK_COMPONENTS
        )
        if blocked and not self.spec.allow_network_changes:
            raise DeviceError(
                f"refusing to change {', '.join(blocked)} without deployment.allowNetworkChanges"
            )

        return await self._observe(info)

    async def _observe(self, info: dict[str, Any]) -> DevicePlan:
        current = await self.call("Shelly.GetConfig")
        return DevicePlan(
            info=info,
            components=self._compare(current),
            scripts=await self._plan_scripts(),
            schedules=await self._plan_schedules(),
        )

    async def _plan_scripts(self) -> list[ScriptPlan]:
        if not self.spec.scripts:
            return []
        listed = await self.call("Script.List")
        by_name: dict[str, list[dict[str, Any]]] = {}
        for script in (listed or {}).get("scripts") or []:
            by_name.setdefault(script.get("name"), []).append(script)
        plans = []
        for name, wanted in sorted(self.spec.scripts.items()):
            found = by_name.get(name, [])
            if len(found) > 1:
                raise DeviceError(
                    f"script {name}: {len(found)} scripts on the device have this name"
                )
            plan = ScriptPlan(name=name, code=wanted["code"], enable=wanted["enable"])
            if found:
                script = found[0]
                plan.id = script["id"]
                plan.current_code = await self.get_script_code(script["id"])
                plan.current_enable = bool(script.get("enable"))
                plan.running = bool(script.get("running"))
            plans.append(plan)
        return plans

    async def _plan_schedules(self) -> SchedulePlan | None:
        if self.spec.schedules is None:
            return None
        current = await self.call("Schedule.List")
        try:
            return plan_schedules(self.spec.schedules, current)
        except SecretError as e:
            raise DeviceError(f"schedules: {e}") from e

    async def get_script_code(self, script_id: int) -> str:
        """A script's code, read in as many pieces as the device hands out."""
        parts: list[str] = []
        offset = 0
        while True:
            answer = await self.call(
                "Script.GetCode", {"id": script_id, "offset": offset}
            )
            data = (answer or {}).get("data") or ""
            parts.append(data)
            offset += len(data.encode())
            if not data or not (answer or {}).get("left"):
                return "".join(parts)

    def _compare(self, current: Any) -> list[ComponentPlan]:
        if not isinstance(current, dict):
            raise DeviceError("unexpected answer to Shelly.GetConfig")
        plans = []
        for key, declared in sorted(self.spec.components.items()):
            if key not in current:
                raise DeviceError(f"{key}: no such component on this device")
            try:
                plans.append(plan_component(key, declared, current[key]))
            except SecretError as e:
                raise DeviceError(f"{key}: {e}") from e
        return plans

    async def apply(self, plan: DevicePlan, force: bool = False) -> ApplyResult:
        """Send what differs, reboot if needed, and verify the result.

        Order: components, scripts, schedules, then network components.
        """
        result = ApplyResult()

        async def step(label: str, action: Any) -> Any:
            try:
                answer = await action
            except DeviceError as e:
                done = (
                    f" (already applied: {', '.join(result.applied)})"
                    if result.applied
                    else ""
                )
                raise DeviceError(f"{label}: {e}{done}") from e
            result.applied.append(label)
            return answer

        async def send(component: ComponentPlan) -> None:
            answer = await step(
                component.key, self.set_config(component.key, component.desired)
            )
            if isinstance(answer, dict) and answer.get("restart_required"):
                result.restart_required.append(component.key)

        components = plan.pending(force)
        for component in components:
            if _component_type(component.key) not in NETWORK_COMPONENTS:
                await send(component)
        for script in plan.pending_scripts(force):
            await step(f"script {script.name}", self.apply_script(script, force))
        if plan.schedules_pending(force):
            assert plan.schedules is not None
            await step("schedules", self.apply_schedules(plan.schedules))
        for component in components:
            if _component_type(component.key) in NETWORK_COMPONENTS:
                await send(component)

        if result.restart_required and self.spec.reboot == "if-required":
            await self.reboot()
            result.rebooted = True

        remaining = (await self._observe(plan.info)).differences()
        if remaining:
            raise DeviceError(
                f"configuration did not take effect: {'; '.join(remaining)}"
            )
        return result

    async def apply_script(self, plan: ScriptPlan, force: bool = False) -> None:
        """Create, upload, configure and start or stop one script."""
        script_id = plan.id
        running = bool(plan.running)
        if script_id is None:
            created = await self.call("Script.Create", {"name": plan.name})
            script_id = created["id"]
            running = False
        if force or plan.id is None or plan.code_changed:
            if running:
                await self.call("Script.Stop", {"id": script_id})
                running = False
            for i, chunk in enumerate(_chunks(plan.code, SCRIPT_CHUNK_BYTES)):
                await self.call(
                    "Script.PutCode", {"id": script_id, "code": chunk, "append": i > 0}
                )
        if force or plan.current_enable != plan.enable:
            await self.call(
                "Script.SetConfig", {"id": script_id, "config": {"enable": plan.enable}}
            )
        if plan.enable and not running:
            await self.call("Script.Start", {"id": script_id})
        elif not plan.enable and running:
            await self.call("Script.Stop", {"id": script_id})

    async def apply_schedules(self, plan: SchedulePlan) -> None:
        """Replace the device's schedule jobs with the declared ones."""
        await self.call("Schedule.DeleteAll")
        for job in plan.desired:
            await self.call("Schedule.Create", job)

    async def set_config(self, key: str, config: dict[str, Any]) -> Any:
        """Call a component's SetConfig method."""
        component_type, _, index = key.partition(":")
        namespace = ComponentNamespace.for_component_type(component_type).qualifies_as
        params: dict[str, Any] = {"config": config}
        if index:
            params["id"] = int(index)
        return await self.call(f"{namespace}.SetConfig", params)

    async def reboot(self) -> None:
        """Reboot the device and wait until it answers again."""
        before = await self._uptime()
        await self.call("Shelly.Reboot")
        deadline = time.monotonic() + self.reboot_timeout
        went_down = False
        while time.monotonic() < deadline:
            await asyncio.sleep(1)
            try:
                uptime = await self._uptime()
            except DeviceError:
                went_down = True
                continue
            if went_down or (
                before is not None and uptime is not None and uptime < before
            ):
                return
        raise DeviceError(
            f"did not come back within {self.reboot_timeout:g}s of rebooting"
        )

    async def _uptime(self) -> float | None:
        status = await self.call("Sys.GetStatus")
        uptime = status.get("uptime") if isinstance(status, dict) else None
        return uptime if isinstance(uptime, int | float) else None
