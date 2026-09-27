from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from conftest import events
from hermes_context_observer.contract import ContractError, validate_event
from hermes_context_observer.observer import Observer, Route


def test_production_events_match_fixed_replay_fixture(tmp_path: Path):
    from test_replay_fixture import route

    a_home, b_home = tmp_path / "alpha", tmp_path / "beta"
    a, b = Observer(a_home, "alpha", events_per_segment=2), Observer(b_home, "beta", events_per_segment=2)
    first = route("alpha", "thread-1", "First thread")
    second = route("beta", "thread-1", "First thread")
    a.request_completed(first, "alpha-1", request_id="turn-a:api:1", used=300, maximum=1000,
                        source="provider_reported", model="model-a", provider="provider-a", at="2026-09-24T10:00:30Z")
    a.tool_call_completed(first, "alpha-1", tool_call_id="call-a1", request_id="turn-a:api:1", tool_name="skill_view",
                          skill_name="writing", estimated_tokens=900, duration_ms=40, status="ok", at="2026-09-24T10:00:40Z")
    a.tool_call_completed(first, "alpha-1", tool_call_id="call-a2", request_id="turn-a:api:1", tool_name="terminal",
                          skill_name=None, estimated_tokens=120, duration_ms=1500, status="ok", at="2026-09-24T10:00:50Z")
    b.request_completed(second, "beta-1", request_id="turn-b:api:1", used=None, maximum=None,
                        source=None, model="model-b", provider="provider-b", at="2026-09-24T10:01:30Z")
    b.tool_call_completed(second, "beta-1", tool_call_id="call-b1", request_id="turn-b:api:1", tool_name="read_file",
                          skill_name=None, estimated_tokens=30, duration_ms=5, status="error", at="2026-09-24T10:01:40Z")
    a.session_reset("alpha-1", "alpha-3", at="2026-09-24T10:02:00Z")
    # A late call from the ended generation still lands under it.
    a.tool_call_completed(first, "alpha-1", tool_call_id="call-a3", request_id="turn-a:api:1", tool_name="terminal",
                          skill_name=None, estimated_tokens=0, duration_ms=2, status="ok", at="2026-09-24T10:02:10Z")
    a.request_completed(first, "alpha-3", request_id="turn-c:api:1", used=400, maximum=1000,
                        source="provider_reported", model="model-a", provider="provider-a", at="2026-09-24T10:02:30Z")
    a.tool_call_completed(first, "alpha-3", tool_call_id="call-c1", request_id="turn-c:api:1", tool_name="skill_view",
                          skill_name="research", estimated_tokens=2400, duration_ms=60, status="ok", at="2026-09-24T10:02:40Z")
    expected = json.loads((Path(__file__).resolve().parents[1] / "fixtures/v1/events/replay.json").read_text())
    assert {"alpha": events(a_home), "beta": events(b_home)} == expected


def test_requests_replay_restart_rotation_and_reset_in_two_homes(tmp_path: Path):
    a_home, b_home = tmp_path / "alpha", tmp_path / "beta"
    route_a = Route("alpha", "discord", "channel", thread_id="thread")
    route_b = Route("beta", "discord", "channel", thread_id="thread")
    a = Observer(a_home, "alpha", events_per_segment=2)
    b = Observer(b_home, "beta", events_per_segment=2)
    a.session_started(route_a, "old", model="a", at="2026-09-24T10:00:00Z")
    for request_id, used in (("r1", 30), ("r2", 40), ("r3", 50)):
        a.request_completed(route_a, "old", request_id=request_id, used=used, maximum=100,
                            source="provider_reported", model="a", provider="p", at="2026-09-24T10:01:00Z")
    b.session_started(route_b, "other", model="b", at="2026-09-24T10:00:00Z")
    b.request_completed(route_b, "other", request_id="r1", used=None, maximum=None,
                        source=None, model="b", provider="q", at="2026-09-24T10:02:00Z")
    a.session_reset("old", "new", at="2026-09-24T10:03:00Z")
    a.request_completed(route_a, "new", request_id="r4", used=60, maximum=100,
                        source="provider_reported", model="a", provider="p", at="2026-09-24T10:04:00Z")
    # Replaying through a new observer must keep the old identity and never emit again.
    restarted = Observer(a_home, "alpha", events_per_segment=2)
    restarted.request_completed(route_a, "old", request_id="r1", used=30, maximum=100,
                                source="provider_reported", model="a", provider="p", at="2026-09-24T10:01:00Z")
    restarted.request_completed(route_a, "new", request_id="r4", used=60, maximum=100,
                                source="provider_reported", model="a", provider="p", at="2026-09-24T10:04:00Z")
    alpha, beta = events(a_home), events(b_home)
    assert len(alpha) == 4 and len(beta) == 1
    assert [e["sequence"] for e in alpha] == [1, 2, 3, 4]
    assert len({e["event_id"] for e in alpha + beta}) == 5
    assert [e["context"]["used"] for e in alpha] == [30, 40, 50, 60]
    assert {e["routing_id"] for e in alpha} == {route_a.routing_id}
    assert {e["lineage_root_id"] for e in alpha} == {"old"}
    assert [e["session_id"] for e in alpha] == ["old", "old", "old", "new"]
    assert alpha[-1]["previous_session_id"] == "old"
    assert beta[0]["context"] == {"used": None, "maximum": None, "percentage": None, "source": None, "measured_at": None}
    assert len(list((a_home / "hermes-context/v1/events").glob("*"))) == 2
    assert all(set(e) == {"contract_version", "kind", "event_id", "sequence", "routing_id", "lineage_root_id", "previous_session_id", "session_id", "timestamp", "profile", "model", "provider", "state", "context"} for e in alpha + beta)
    for e in alpha + beta:
        validate_event(e)
    assert events(b_home) == beta


def test_append_and_replay_list_only_the_newest_segment(tmp_path: Path, monkeypatch):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha", events_per_segment=2)

    def request(request_id: str) -> None:
        observer.request_completed(route, "one", request_id=request_id, used=None, maximum=None,
                                   source=None, model="m", provider="p", at="2026-09-24T10:00:00Z")

    for n in range(1, 6):
        request(f"r{n}")  # Sequences 1-5 fill segments 000001 and 000002 and start 000003.
    listed = []
    for name in ("scandir", "listdir"):
        real = getattr(os, name)
        monkeypatch.setattr(os, name, lambda path=".", real=real: listed.append(Path(path).name) or real(path))
    request("r6")  # Fills 000003.
    request("r7")  # Rotates into 000004.
    request("r1")  # Replays the first event, three segments back.
    monkeypatch.undo()
    assert [e["sequence"] for e in events(tmp_path)] == [1, 2, 3, 4, 5, 6, 7]
    assert not {"000001", "000002"} & set(listed)


def test_event_contract_rejects_unapproved_content(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.request_completed(route, "one", request_id="r", used=None, maximum=None,
                               source=None, model=None, provider=None, at="2026-09-24T10:00:00Z")
    event = events(tmp_path)[0]
    for field in ("current_tool", "messages", "prompts", "responses", "reasoning", "tool_arguments", "tool_results", "previews"):
        with pytest.raises(ContractError):
            validate_event({**event, field: "do not retain"})
    with pytest.raises(ContractError):
        validate_event({**event, "context": {**event["context"], "current_tool": "terminal"}})
    with pytest.raises(ContractError):
        validate_event({**event, "timestamp": "not-a-time"})


def test_interleaved_observers_share_a_sequence_and_replay_is_immutable(tmp_path: Path):
    first, second = Observer(tmp_path, "alpha", events_per_segment=2), Observer(tmp_path, "alpha", events_per_segment=2)
    route_a = Route("alpha", "discord", "channel", thread_id="a")
    route_b = Route("alpha", "discord", "channel", thread_id="b")
    first.request_completed(route_a, "one", request_id="turn-1:api:1", used=10, maximum=100,
                            source="provider_reported", model="m", provider="p", at="2026-09-24T10:00:00Z")
    second.request_completed(route_b, "two", request_id="turn-2:api:1", used=20, maximum=100,
                             source="provider_reported", model="m", provider="p", at="2026-09-24T10:01:00Z")
    first.request_completed(route_a, "one", request_id="turn-3:api:1", used=30, maximum=100,
                            source="provider_reported", model="m", provider="p", at="2026-09-24T10:02:00Z")
    before = events(tmp_path)
    assert [e["sequence"] for e in before] == [1, 2, 3]
    second.request_completed(route_a, "one", request_id="turn-1:api:1", used=99, maximum=100,
                             source="provider_reported", model="m", provider="p", at="2026-09-24T10:09:00Z")
    assert events(tmp_path) == before
    assert {e["routing_id"] for e in before} == {route_a.routing_id, route_b.routing_id}


def test_unknown_request_cannot_become_an_ended_generation(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.session_started(route, "current", at="2026-09-24T10:00:00Z")
    observer.request_completed(route, "unrelated", request_id="unrelated:1", used=10, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:01:00Z")
    assert events(tmp_path) == []
    assert json.loads(observer.store.path.read_text())["sessions"][0]["session_id"] == "current"


def test_older_known_generation_keeps_its_predecessor_after_two_resets(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.session_started(route, "root", at="2026-09-24T10:00:00Z")
    observer.session_reset("root", "middle", at="2026-09-24T10:01:00Z")
    observer.request_completed(route, "middle", request_id="mid:1", used=10, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:02:00Z")
    observer.session_reset("middle", "latest", at="2026-09-24T10:03:00Z")
    observer.request_completed(route, "middle", request_id="mid:2", used=20, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:04:00Z")
    observer.request_completed(route, "root", request_id="root:late", used=30, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:05:00Z")
    assert [e["previous_session_id"] for e in events(tmp_path)] == ["root", "root", None]
    assert json.loads(observer.store.path.read_text())["sessions"][0]["session_id"] == "latest"


def test_zero_event_intermediate_generation_has_stable_predecessor(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="thread")
    observer = Observer(tmp_path, "alpha")
    observer.session_started(route, "root", at="2026-09-24T10:00:00Z")
    observer.session_reset("root", "middle", at="2026-09-24T10:01:00Z")
    observer.session_reset("middle", "latest", at="2026-09-24T10:02:00Z")
    restarted = Observer(tmp_path, "alpha")
    restarted.request_completed(route, "middle", request_id="mid:late", used=None, maximum=None,
                                source=None, model="old-model", provider="p", at="2026-09-24T10:03:00Z")
    assert [(e["session_id"], e["lineage_root_id"], e["previous_session_id"]) for e in events(tmp_path)] == [
        ("middle", "root", "root")]
    registry = [json.loads(path.read_text()) for path in (tmp_path / "hermes-context/v1/generations").glob("*.json")]
    assert len(registry) == 2
    assert all(set(row) == {"routing_id", "session_id", "lineage_root_id", "previous_session_id", "model", "provider"}
               for row in registry)
    assert json.loads(restarted.store.path.read_text())["sessions"][0]["session_id"] == "latest"


def test_overfull_context_keeps_reported_occupancy_without_invalid_percentage(tmp_path: Path):
    route = Route("alpha", "discord", "channel", thread_id="a")
    observer = Observer(tmp_path, "alpha")
    observer.request_completed(route, "one", request_id="overflow:api:1", used=120, maximum=100,
                               source="provider_reported", model="m", provider="p", at="2026-09-24T10:00:00Z")
    event = events(tmp_path)[0]
    assert event["context"]["used"] == 120
    assert event["context"]["maximum"] == 100
    assert event["context"]["percentage"] == 100.0
