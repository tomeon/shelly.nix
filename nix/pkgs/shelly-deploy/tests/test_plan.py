import pytest
from shelly_deploy.plan import SecretError, plan_component, resolve_secrets, same


def test_same_is_strict_about_booleans():
    assert not same(True, 1)
    assert not same(0, False)
    assert same(1, 1.0)
    assert same({"a": [1, {"b": None}]}, {"a": [1, {"b": None}]})
    assert not same({"a": 1}, {"a": 1, "b": 2})
    assert not same([1], [1, 2])
    assert not same("1", 1)


def test_only_declared_fields_are_compared():
    plan = plan_component(
        "switch:0", {"name": "Porch"}, {"id": 0, "name": "Porch", "in_mode": "flip"}
    )
    assert plan.status == "unchanged"


def test_nested_changes_are_reported_by_path():
    plan = plan_component(
        "sys",
        {"device": {"name": "Porch", "eco_mode": True}},
        {"device": {"name": None, "eco_mode": True}},
    )
    assert plan.status == "changed"
    assert [c.describe() for c in plan.changes] == ['device.name: null -> "Porch"']


def test_fields_the_device_does_not_report():
    plan = plan_component("mqtt", {"enable": True, "pass": "x"}, {"enable": True})
    assert plan.status == "unreported"
    assert plan.unreported == [("pass",)]


def test_an_object_replacing_a_scalar_is_a_change():
    plan = plan_component("x", {"a": {"b": 1}}, {"a": None})
    assert [c.describe() for c in plan.changes] == ['a: null -> {"b": 1}']


def test_lists_are_compared_whole():
    plan = plan_component("x", {"a": [1, 2]}, {"a": [1, 2, 3]})
    assert [c.describe() for c in plan.changes] == ["a: [1, 2, 3] -> [1, 2]"]


def test_secrets_are_resolved_and_masked(tmp_path):
    secret = tmp_path / "secret"
    secret.write_text("hunter2\n\n")
    plan = plan_component(
        "mqtt",
        {"user": "u", "token": {"_secret": str(secret)}},
        {"user": "u", "token": "old"},
    )
    assert plan.desired == {"user": "u", "token": "hunter2"}
    assert [c.describe() for c in plan.changes] == ["token: <secret> -> <secret>"]


def test_secrets_inside_lists_are_masked(tmp_path):
    secret = tmp_path / "secret"
    secret.write_text("s3cret")
    plan = plan_component("x", {"args": ["a", {"_secret": str(secret)}]}, {"args": []})
    assert plan.desired == {"args": ["a", "s3cret"]}
    assert [c.describe() for c in plan.changes] == ["args: <secret> -> <secret>"]


def test_missing_secret_file(tmp_path):
    with pytest.raises(SecretError, match="cannot read secret"):
        resolve_secrets({"pass": {"_secret": str(tmp_path / "missing")}})


def test_objects_with_more_than_a_secret_are_left_alone():
    value = {"_secret": "/x", "other": 1}
    assert resolve_secrets(value) == (value, frozenset())
