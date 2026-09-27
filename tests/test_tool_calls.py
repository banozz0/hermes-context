from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from conftest import events
from hermes_context_observer.contract import ContractError, validate_event
from hermes_context_observer.observer import Observer, Route

TOOL_CALL_FIELDS = {
    "contract_version", "kind", "event_id", "sequence", "routing_id", "lineage_root_id", "previous_session_id",
    "session_id", "request_event_id", "timestamp", "profile", "tool_name", "skill_name", "estimated_tokens",
    "duration_ms", "status",
}


def identity(*parts: str) -> str:
    """The documented v1 identity, written out here rather than imported so the test pins the format itself."""
    text = json.dumps(list(parts), ensure_ascii=False, separators=(",", ":"))
    return f"hc1:{hashlib.sha256(text.encode('utf-8')).hexdigest()}"


def call(observer: Observer, route: Route, session_id: str, tool_call_id: str, **overrides) -> None:
    fields = dict(request_id="turn:api:1", tool_name="terminal", skill_name=None, estimated_tokens=120,
                  duration_ms=35, status="ok", at="2026-09-24T10:01:00Z")
    fields.update(overrides)
    observer.tool_call_completed(route, session_id, tool_call_id=tool_call_id, **fields)


def test_tool_call_shares_the_request_sequence_and_links_its_request(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha", events_per_segment=2)
    observer.request_completed(route, "one", request_id="turn:api:1", used=10, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:00:00Z")
    call(observer, route, "one", "call-1", tool_name="skill_view", skill_name="writing", estimated_tokens=900)
    call(observer, route, "one", "call-2", status="error", duration_ms=0)
    request, skill, failed = events(tmp_path)
    assert [e["sequence"] for e in (request, skill, failed)] == [1, 2, 3]
    assert [e["kind"] for e in (request, skill, failed)] == ["model_request", "tool_call", "tool_call"]
    assert set(skill) == TOOL_CALL_FIELDS
    assert skill["event_id"] == identity("tool_call", "alpha", "one", "turn:api:1", "call-1")
    assert skill["request_event_id"] == request["event_id"] == identity("alpha", "one", "turn:api:1")
    assert (skill["routing_id"], skill["session_id"], skill["lineage_root_id"], skill["previous_session_id"]) == (
        route.routing_id, "one", "one", None)
    assert (skill["tool_name"], skill["skill_name"], skill["estimated_tokens"], skill["duration_ms"], skill["status"]) == (
        "skill_view", "writing", 900, 35, "ok")
    assert (failed["tool_name"], failed["skill_name"], failed["status"], failed["duration_ms"]) == ("terminal", None, "error", 0)
    assert len(list((tmp_path / "hermes-context/v1/events").glob("*"))) == 2  # rotation counts both kinds
    for event in (request, skill, failed):
        validate_event(event)


def test_tool_call_identity_survives_replay_and_restart(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    first = Observer(tmp_path, "alpha")
    first.session_started(route, "one", at="2026-09-24T10:00:00Z")
    call(first, route, "one", "call-1")
    call(first, route, "one", "call-1", estimated_tokens=5, at="2026-09-24T10:09:00Z")
    before = events(tmp_path)
    restarted = Observer(tmp_path, "alpha")
    call(restarted, route, "one", "call-1", tool_name="read_file", at="2026-09-24T10:10:00Z")
    call(restarted, route, "one", "call-2")
    after = events(tmp_path)
    assert after[:1] == before and len(before) == 1
    assert [e["sequence"] for e in after] == [1, 2]
    assert len({e["event_id"] for e in after}) == 2
    # Providers may reuse an ID in a later response: under another request it is another call.
    call(restarted, route, "one", "call-1", request_id="turn:api:2")
    call(restarted, route, "one", "call-1", request_id=None)
    assert [e["sequence"] for e in events(tmp_path)] == [1, 2, 3, 4]
    # The same string as a request ID is never that request's identity.
    call(restarted, route, "one", "turn:api:1")
    assert identity("alpha", "one", "turn:api:1") not in {e["event_id"] for e in events(tmp_path)}


def test_tool_call_admission_matches_request_events(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.session_started(route, "root", at="2026-09-24T10:00:00Z")
    call(observer, route, "unrelated", "stray")  # a session this lane never ran
    call(observer, Route("beta", "discord", "channel", thread_id="thread"), "root", "foreign")
    call(observer, route, "root", "")  # no tool_call_id, no identity
    assert events(tmp_path) == []
    observer.session_reset("root", "next", at="2026-09-24T10:02:00Z")
    call(observer, route, "root", "late", request_id=None)  # an ended generation still owns its late call
    call(observer, route, "next", "fresh", request_id=None)
    late, fresh = events(tmp_path)
    assert (late["session_id"], late["previous_session_id"], late["request_event_id"]) == ("root", None, None)
    assert (fresh["session_id"], fresh["lineage_root_id"], fresh["previous_session_id"]) == ("next", "root", "root")
    assert json.loads(observer.store.path.read_text())["sessions"][0]["session_id"] == "next"


@pytest.mark.parametrize("edit", [
    {"arguments": "x"}, {"result": "x"}, {"error_message": "x"}, {"current_tool": "x"}, {"context": {}},
    {"kind": "tool_result"}, {"status": "failed"}, {"estimated_tokens": -1}, {"estimated_tokens": 1.5},
    {"duration_ms": -1}, {"duration_ms": True}, {"tool_name": ""}, {"tool_name": None}, {"skill_name": ""},
    {"request_event_id": "turn:api:1"}, {"event_id": "call-1"},
])
def test_tool_call_contract_rejects_anything_outside_the_allowlist(tmp_path: Path, edit: dict):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    call(observer, route, "one", "call-1", tool_name="skill_view", skill_name="writing")
    event = events(tmp_path)[0]
    with pytest.raises(ContractError):
        validate_event({**event, **edit})


def test_request_event_needs_its_kind(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.request_completed(route, "one", request_id="r", used=None, maximum=None,
                               source=None, model=None, provider=None, at="2026-09-24T10:00:00Z")
    event = events(tmp_path)[0]
    for broken in ({k: v for k, v in event.items() if k != "kind"}, {**event, "kind": "tool_call"},
                   {**event, "tool_name": "terminal"}):
        with pytest.raises(ContractError):
            validate_event(broken)


def test_json_schema_agrees_with_the_validator_on_both_kinds():
    jsonschema = pytest.importorskip("jsonschema")
    root = Path(__file__).resolve().parents[1]
    schema = json.loads((root / "contracts/v1/event.schema.json").read_text())
    replay = json.loads((root / "fixtures/v1/events/replay.json").read_text())
    fixture = [event for profile in replay.values() for event in profile]
    assert {event["kind"] for event in fixture} == {"model_request", "tool_call"}
    for event in fixture:
        validate_event(event)
        jsonschema.validate(event, schema)
    tool_call = next(event for event in fixture if event["kind"] == "tool_call")
    for edit in ({"arguments": "x"}, {"status": "failed"}, {"kind": "model_request"}, {"request_event_id": "raw"}):
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate({**tool_call, **edit}, schema)
