"""Scripts and schedules, through shelly-deploy's command line."""

from conftest import entry
from shelly_deploy.device import _chunks
from shelly_deploy.plan import SchedulePlan, normalise_job

LONG_CODE = (
    "// Ünïcödé, to cross chunk boundaries mid-character.\n" + "let x = 1;\n" * 400
)


def calls(device, prefix):
    return [m for m in device.state()["calls"] if m.lower().startswith(prefix.lower())]


def scripts(device):
    return {s["name"]: s for s in device.state()["scripts"]}


def test_chunks_split_between_characters():
    pieces = _chunks(LONG_CODE, 1024)
    assert "".join(pieces) == LONG_CODE
    assert all(len(p.encode()) <= 1024 for p in pieces)
    assert len(pieces) > 1
    assert _chunks("", 1024) == [""]


def test_new_scripts_are_created_uploaded_and_started(device, deploy):
    devices = {
        "porch": entry(
            device.address,
            scripts={"motion": {"code": LONG_CODE, "enable": True}},
        )
    }
    code, out = deploy("diff", devices)
    assert code == 0
    assert "  + script motion\n" in out
    assert scripts(device) == {}

    code, out = deploy("switch", devices)
    assert code == 0, out
    assert "applied script motion" in out
    motion = scripts(device)["motion"]
    assert motion["code"] == LONG_CODE
    assert motion["enable"] is True
    assert motion["running"] is True
    assert len(calls(device, "Script.PutCode")) > 1


def test_unchanged_scripts_are_left_alone(device, deploy):
    devices = {
        "porch": entry(
            device.address, scripts={"motion": {"code": LONG_CODE, "enable": True}}
        )
    }
    assert deploy("switch", devices)[0] == 0
    puts = len(calls(device, "Script.PutCode"))

    code, out = deploy("switch", devices)
    assert code == 0
    assert "  = script motion" in out
    assert "applied" not in out
    assert len(calls(device, "Script.PutCode")) == puts


def test_changed_code_is_uploaded_and_the_script_restarted(device, deploy):
    device.add_script("motion", code="old()", enable=True)
    devices = {
        "porch": entry(
            device.address, scripts={"motion": {"code": "new()", "enable": True}}
        )
    }

    code, out = deploy("diff", devices)
    assert "  ~ script motion\n      code: 5 bytes -> 5 bytes" in out

    code, out = deploy("switch", devices)
    assert code == 0, out
    assert scripts(device)["motion"]["code"] == "new()"
    assert scripts(device)["motion"]["running"] is True
    methods = [
        m
        for m in calls(device, "Script.")
        if m not in ("Script.List", "Script.GetCode")
    ]
    assert methods == ["Script.Stop", "Script.PutCode", "Script.Start"]


def test_disabled_scripts_are_stopped(device, deploy):
    device.add_script("motion", code="x()", enable=True)
    devices = {
        "porch": entry(
            device.address, scripts={"motion": {"code": "x()", "enable": False}}
        )
    }
    code, out = deploy("switch", devices)
    assert code == 0, out
    assert "enable: true -> false" in out
    assert scripts(device)["motion"]["enable"] is False
    assert scripts(device)["motion"]["running"] is False


def test_undeclared_scripts_are_left_alone(device, deploy):
    device.add_script("handmade", code="mine()", enable=True)
    devices = {
        "porch": entry(
            device.address, scripts={"motion": {"code": "x()", "enable": True}}
        )
    }
    assert deploy("switch", devices)[0] == 0
    assert scripts(device)["handmade"] == {
        "id": 1,
        "name": "handmade",
        "enable": True,
        "running": True,
        "code": "mine()",
    }


def test_ambiguous_script_names(device, deploy):
    device.add_script("motion")
    device.add_script("motion")
    code, out = deploy(
        "diff",
        {
            "porch": entry(
                device.address, scripts={"motion": {"code": "", "enable": True}}
            )
        },
    )
    assert code == 1
    assert "script motion: 2 scripts on the device have this name" in out


def test_scripts_that_do_not_start_are_reported(device, deploy):
    devices = {
        "porch": entry(
            device.address, scripts={"bad": {"code": "crash()", "enable": True}}
        )
    }
    code, out = deploy("switch", devices)
    assert code == 1
    assert (
        "configuration did not take effect: script bad: running: false -> true" in out
    )


def test_force_resends_scripts(device, deploy):
    devices = {
        "porch": entry(
            device.address, scripts={"motion": {"code": "x()", "enable": True}}
        )
    }
    assert deploy("switch", devices)[0] == 0
    puts = len(calls(device, "Script.PutCode"))
    code, out = deploy("switch", devices, "--force")
    assert code == 0, out
    assert len(calls(device, "Script.PutCode")) == puts + 1
    assert scripts(device)["motion"]["running"] is True


def test_scripts_restart_after_a_reboot(device, deploy):
    devices = {
        "porch": entry(
            device.address,
            components={"mqtt": {"enable": True}},
            scripts={"motion": {"code": "x()", "enable": True}},
        )
    }
    code, out = deploy("switch", devices)
    assert code == 0, out
    assert device.reboots == 1
    assert scripts(device)["motion"]["running"] is True


JOBS = [
    {
        "enable": True,
        "timespec": "0 30 22 * * *",
        "calls": [{"method": "Switch.Set", "params": {"id": 0, "on": False}}],
    },
    {
        "enable": False,
        "timespec": "0 0 7 * * MON-FRI",
        "calls": [{"method": "Shelly.Reboot", "params": {}}],
    },
]


def test_schedules_are_replaced(device, deploy):
    device.jobs = [
        {
            "id": 99,
            "enable": True,
            "timespec": "@sunset",
            "calls": [{"method": "Switch.Toggle", "params": {"id": 0}}],
        }
    ]
    devices = {"porch": entry(device.address, schedules=JOBS)}

    code, out = deploy("diff", devices)
    assert "  ~ schedules (2 job(s))" in out
    assert "      - @sunset: Switch.Toggle" in out
    assert "      + 0 30 22 * * *: Switch.Set" in out
    assert "      + 0 0 7 * * MON-FRI: Shelly.Reboot (disabled)" in out

    code, out = deploy("switch", devices)
    assert code == 0, out
    assert [normalise_job(job) for job in device.jobs] == JOBS

    deletes = len(calls(device, "Schedule.DeleteAll"))
    code, out = deploy("switch", devices)
    assert code == 0
    assert "  = schedules (2 job(s))" in out
    assert len(calls(device, "Schedule.DeleteAll")) == deletes


def test_schedules_are_untouched_unless_declared(device, deploy):
    device.jobs = [
        {
            "id": 99,
            "enable": True,
            "timespec": "@sunset",
            "calls": [{"method": "Switch.Toggle"}],
        }
    ]
    code, out = deploy(
        "switch",
        {"porch": entry(device.address, components={"switch:0": {"name": "x"}})},
    )
    assert code == 0
    assert "schedules" not in out
    assert calls(device, "Schedule.") == []
    assert len(device.jobs) == 1


def test_an_empty_schedule_list_removes_every_job(device, deploy):
    device.jobs = [
        {
            "id": 99,
            "enable": True,
            "timespec": "@sunset",
            "calls": [{"method": "Switch.Toggle"}],
        }
    ]
    code, out = deploy("switch", {"porch": entry(device.address, schedules=[])})
    assert code == 0, out
    assert device.jobs == []


def test_schedule_secrets_are_resolved(device, deploy, tmp_path):
    token = tmp_path / "token"
    token.write_text("t0ken\n")
    jobs = [
        {
            "enable": True,
            "timespec": "0 0 * * * *",
            "calls": [
                {"method": "HTTP.GET", "params": {"url": {"_secret": str(token)}}}
            ],
        }
    ]
    code, out = deploy("switch", {"porch": entry(device.address, schedules=jobs)})
    assert code == 0, out
    assert device.jobs[0]["calls"][0]["params"] == {"url": "t0ken"}
    assert "t0ken" not in out


def test_reordered_jobs_are_a_change():
    a, b = JOBS
    plan = SchedulePlan(desired=[a, b], current=[b, a])
    assert plan.status == "changed"
    assert plan.describe() == ["order changed"]


def test_apply_order(device, deploy):
    devices = {
        "porch": entry(
            device.address,
            components={"wifi": {"sta": {"ssid": "other"}}, "switch:0": {"name": "x"}},
            scripts={"motion": {"code": "x()", "enable": True}},
            schedules=JOBS[:1],
            deployment={"allowNetworkChanges": True},
        )
    }
    code, out = deploy("switch", devices)
    assert code == 0, out
    assert "applied switch:0, script motion, schedules, wifi" in out
