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
from .plan import ComponentPlan, SecretError, plan_component, read_secret

# Components whose misconfiguration can leave a device unreachable.  They are
# applied last, and only when the manifest allows it.
NETWORK_COMPONENTS = frozenset({"wifi", "eth"})

# Gen2+ devices have a single user.
USERNAME = "admin"


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


@dataclass
class DevicePlan:
    """How a device compares with its declared configuration."""

    info: dict[str, Any]
    components: list[ComponentPlan]

    def pending(self, force: bool = False) -> list[ComponentPlan]:
        """The components to send: those that differ, or all of them if forced.

        Network components come last.
        """
        chosen = [c for c in self.components if force or c.status == "changed"]
        return sorted(
            chosen, key=lambda c: _component_type(c.key) in NETWORK_COMPONENTS
        )


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

        current = await self.call("Shelly.GetConfig")
        return DevicePlan(info=info, components=self._compare(current))

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
        """Send pending components, reboot if needed, and verify the result."""
        result = ApplyResult()
        pending = plan.pending(force)
        for component in pending:
            try:
                answer = await self.set_config(component.key, component.desired)
            except DeviceError as e:
                done = (
                    f" (already applied: {', '.join(result.applied)})"
                    if result.applied
                    else ""
                )
                raise DeviceError(f"{component.key}: {e}{done}") from e
            result.applied.append(component.key)
            if isinstance(answer, dict) and answer.get("restart_required"):
                result.restart_required.append(component.key)

        if result.restart_required and self.spec.reboot == "if-required":
            await self.reboot()
            result.rebooted = True

        current = await self.call("Shelly.GetConfig")
        unconverged = [c for c in self._compare(current) if c.status == "changed"]
        if unconverged:
            details = "; ".join(ch.describe() for c in unconverged for ch in c.changes)
            raise DeviceError(f"configuration did not take effect: {details}")
        return result

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
