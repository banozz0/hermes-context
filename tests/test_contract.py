from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from hermes_context_observer.contract import DEGRADED_FEATURES, ContractError, effective_freshness, validate_snapshot


FORBIDDEN_KEYS = {
    "message",
    "messages",
    "prompt",
    "prompts",
    "response",
    "responses",
    "reasoning",
    "tool_arguments",
    "tool_results",
    "tool_history",
    "conversation_history",
}


def all_keys(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_keys(child)


def test_versioned_fixtures_are_valid_and_privacy_allowlisted():
    fixture_dir = Path(__file__).resolve().parents[1] / "fixtures" / "v1"
    fixtures = sorted(fixture_dir.glob("*.json"))
    assert [path.name for path in fixtures] == [
        "alpha.snapshot.json",
        "beta.snapshot.json",
    ]
    for path in fixtures:
        payload = json.loads(path.read_text(encoding="utf-8"))
        validate_snapshot(payload)
        assert FORBIDDEN_KEYS.isdisjoint(set(all_keys(payload)))


def test_stale_heartbeat_overlays_last_snapshot_as_offline():
    fixture = Path(__file__).resolve().parents[1] / "fixtures" / "v1" / "alpha.snapshot.json"
    payload = json.loads(fixture.read_text(encoding="utf-8"))
    heartbeat = datetime.fromisoformat(payload["gateway"]["heartbeat_at"].replace("Z", "+00:00"))
    threshold = timedelta(seconds=payload["gateway"]["offline_after_seconds"])
    assert effective_freshness(payload, at=heartbeat + threshold) == "live"
    assert effective_freshness(payload, at=heartbeat + threshold + timedelta(milliseconds=1)) == "offline"
    assert payload["sessions"]  # Staleness must not erase the last known sessions.


def test_unknown_fields_are_rejected(tmp_path: Path):
    fixture = Path(__file__).resolve().parents[1] / "fixtures" / "v1" / "alpha.snapshot.json"
    payload = json.loads(fixture.read_text(encoding="utf-8"))
    payload["sessions"][0]["message"] = "must never be emitted"
    with pytest.raises(ContractError, match="message"):
        validate_snapshot(payload)


@pytest.mark.parametrize("label", ["", "#" + "x" * 100, 7])
def test_channel_label_is_a_bounded_string_or_null(label):
    fixture = Path(__file__).resolve().parents[1] / "fixtures" / "v1" / "alpha.snapshot.json"
    payload = json.loads(fixture.read_text(encoding="utf-8"))
    payload["sessions"][0]["discord_route"]["channel_label"] = None
    validate_snapshot(payload)
    payload["sessions"][0]["discord_route"]["channel_label"] = label
    with pytest.raises(ContractError, match="channel_label"):
        validate_snapshot(payload)


def alpha_fixture() -> dict:
    return json.loads((Path(__file__).resolve().parents[1] / "fixtures" / "v1" / "alpha.snapshot.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("degraded", [["titles"], ["backfill", "sessions", "titles"], sorted(DEGRADED_FEATURES)])
def test_degraded_names_what_an_update_switched_off(degraded):
    payload = alpha_fixture()
    payload["degraded"] = degraded
    validate_snapshot(payload)


@pytest.mark.parametrize("degraded", [[], ["titles", "titles"], ["titles", "backfill"], ["title"],
                                      ["AttributeError: get_session_title"], [["titles"]], "titles", None])
def test_degraded_holds_only_sorted_unique_feature_names(degraded):
    payload = alpha_fixture()
    payload["degraded"] = degraded
    with pytest.raises(ContractError, match="degraded"):
        validate_snapshot(payload)


def test_snapshot_schema_agrees_on_degraded():
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((Path(__file__).resolve().parents[1] / "contracts/v1/snapshot.schema.json").read_text())
    payload = alpha_fixture()
    jsonschema.validate(payload, schema)  # Absent: nothing lost.
    assert set(schema["properties"]["degraded"]["items"]["enum"]) == DEGRADED_FEATURES
    for degraded in ([], ["titles", "titles"], ["title"]):
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate({**payload, "degraded": degraded}, schema)
    jsonschema.validate({**payload, "degraded": ["titles"]}, schema)
