from __future__ import annotations

import json
import multiprocessing
import stat
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from conftest import read_snapshot
from hermes_context_observer.contract import effective_freshness, validate_snapshot
from hermes_context_observer.observer import Observer, Route


def discord_route(profile: str, thread: str, name: str) -> Route:
    return Route(
        profile=profile,
        platform="discord",
        chat_id="channel-10",
        thread_id=thread,
        guild_id="guild-1",
        channel_id="channel-10",
        display_name=name,
    )


def concurrent_writer(home: str, lane: str, ready) -> None:
    observer = Observer(Path(home), "alpha")
    ready.wait(timeout=10)
    observer.session_started(discord_route("alpha", lane, lane), lane)
    for _ in range(5):
        observer.heartbeat()


def test_two_threads_stay_distinct_and_reset_replaces_generation(tmp_path: Path, fixed_times):
    observer = Observer(tmp_path, "alpha", offline_after_seconds=45)
    first = discord_route("alpha", "thread-1", "First thread")
    second = discord_route("alpha", "thread-2", "Second thread")

    observer.session_started(first, "session-a", model="model-a", provider="provider-a", at=fixed_times["t0"])
    observer.session_started(second, "session-b", model="model-a", provider="provider-a", at=fixed_times["t1"])
    observer.session_reset("session-a", "session-c", at=fixed_times["t2"])

    snapshot = read_snapshot(tmp_path)
    assert len(snapshot["sessions"]) == 2
    lanes = {row["discord_route"]["thread_id"]: row for row in snapshot["sessions"]}
    assert lanes["thread-1"]["session_id"] == "session-c"
    assert lanes["thread-1"]["previous_session_id"] == "session-a"
    assert lanes["thread-1"]["lineage_root_id"] == "session-a"
    assert lanes["thread-2"]["session_id"] == "session-b"
    validate_snapshot(snapshot)

    # The previous turn may unwind after /new; it must not resurrect its generation.
    observer.mark_idle(first, "session-a", at=fixed_times["t3"])
    assert {row["discord_route"]["thread_id"]: row["session_id"] for row in read_snapshot(tmp_path)["sessions"]} == {
        "thread-1": "session-c",
        "thread-2": "session-b",
    }


def test_heartbeat_continues_without_session_traffic(tmp_path: Path):
    observer = Observer(tmp_path, "alpha", heartbeat_interval_seconds=0.02)
    observer.start_heartbeat()
    try:
        initial = read_snapshot(tmp_path)
        assert initial["sessions"] == []
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            updated = read_snapshot(tmp_path)
            if updated["gateway"]["heartbeat_at"] != initial["gateway"]["heartbeat_at"]:
                break
            time.sleep(0.01)
        else:
            raise AssertionError("heartbeat did not advance without session traffic")
        validate_snapshot(updated)
        assert updated["profile"] == "alpha"
    finally:
        observer.close()


def test_restart_keeps_lanes_but_clears_abandoned_turn(tmp_path: Path, fixed_times):
    route = Route("alpha", "discord", "thread-1", thread_id="thread-1")
    first = Observer(tmp_path, "alpha")
    first.session_started(route, "session-a", at=fixed_times["t1"])
    first.mark_attention(route, "session-a", tool="clarify", at=fixed_times["t2"])
    second = Observer(tmp_path, "alpha")
    second.heartbeat(at=fixed_times["t3"])
    restored = read_snapshot(tmp_path)
    assert len(restored["sessions"]) == 1
    assert restored["sessions"][0]["session_id"] == "session-a"
    assert restored["sessions"][0]["state"] == "idle"
    assert restored["sessions"][0]["current_tool"] is None
    assert restored["sessions"][0]["timing"]["turn_started_at"] is None


def test_two_observers_in_same_home_do_not_erase_newer_rows(tmp_path: Path, fixed_times):
    first = Observer(tmp_path, "alpha")
    second = Observer(tmp_path, "alpha")  # CLI loaded before gateway's first event.
    lane_a = discord_route("alpha", "thread-1", "First thread")
    lane_b = discord_route("alpha", "thread-2", "Second thread")
    first.session_started(lane_a, "session-a", at=fixed_times["t0"])
    second.heartbeat(at=fixed_times["t1"])
    assert [row["session_id"] for row in read_snapshot(tmp_path)["sessions"]] == ["session-a"]
    second.session_started(lane_b, "session-b", at=fixed_times["t2"])
    assert {row["session_id"] for row in read_snapshot(tmp_path)["sessions"]} == {"session-a", "session-b"}
    first.session_reset("session-a", "session-c", at=fixed_times["t3"])
    second.heartbeat()
    assert {row["session_id"] for row in read_snapshot(tmp_path)["sessions"]} == {"session-b", "session-c"}


def test_gateway_down_with_cli_alive_keeps_row_but_goes_offline(tmp_path: Path):
    owns_gateway = [True]
    gateway = Observer(tmp_path, "alpha", gateway_owner=lambda: owns_gateway[0])
    cli = Observer(tmp_path, "alpha", gateway_owner=lambda: False)
    route = discord_route("alpha", "thread-1", "First")
    gateway.start_heartbeat()
    gateway.session_started(route, "session-a")
    before = read_snapshot(tmp_path)
    assert effective_freshness(before, at=datetime.now(timezone.utc)) == "live"
    gateway.close()
    owns_gateway[0] = False
    cli.start_heartbeat()
    cli.heartbeat(at=datetime.now(timezone.utc) + timedelta(seconds=60))
    cli.mark_working(route, "session-a", tool="terminal", at=datetime.now(timezone.utc) + timedelta(seconds=60))
    after = read_snapshot(tmp_path)
    assert [row["session_id"] for row in after["sessions"]] == ["session-a"]
    assert after["gateway"]["heartbeat_at"] == before["gateway"]["heartbeat_at"]
    assert effective_freshness(after, at=datetime.now(timezone.utc) + timedelta(seconds=60)) == "offline"
    cli.close()


def test_new_instance_does_not_idle_fresh_work_from_another_instance(tmp_path: Path):
    first = Observer(tmp_path, "alpha")
    first.session_started(discord_route("alpha", "thread-1", "First"), "session-a")
    second = Observer(tmp_path, "alpha")
    second.start_heartbeat()
    try:
        row, = read_snapshot(tmp_path)["sessions"]
        assert row["state"] == "working"
        assert row["session_id"] == "session-a"
    finally:
        second.close()


def test_concurrent_processes_reconcile_in_one_home(tmp_path: Path):
    context = multiprocessing.get_context("spawn")
    ready = context.Barrier(2)
    workers = [context.Process(target=concurrent_writer, args=(str(tmp_path), f"thread-{index}", ready))
               for index in range(2)]
    for worker in workers:
        worker.start()
    try:
        for worker in workers:
            worker.join(timeout=20)
            assert worker.exitcode == 0
        assert {row["session_id"] for row in read_snapshot(tmp_path)["sessions"]} == {"thread-0", "thread-1"}
        validate_snapshot(read_snapshot(tmp_path))
    finally:
        for worker in workers:
            if worker.is_alive():
                worker.terminate()
                worker.join(timeout=5)


def test_two_profiles_in_one_thread_and_a_b_a_writes_are_isolated(tmp_path: Path, fixed_times):
    home_a, home_b = tmp_path / "home-a", tmp_path / "home-b"
    observer_a = Observer(home_a, "alpha")
    observer_b = Observer(home_b, "beta")
    route_a = discord_route("alpha", "shared-thread", "Shared thread")
    route_b = discord_route("beta", "shared-thread", "Shared thread")

    observer_a.session_started(route_a, "alpha-1", model="m-a", provider="p-a", at=fixed_times["t0"])
    observer_b.session_started(route_b, "beta-1", model="m-b", provider="p-b", at=fixed_times["t1"])
    observer_a.mark_working(route_a, "alpha-1", tool="terminal", at=fixed_times["t2"])

    snap_a, snap_b = read_snapshot(home_a), read_snapshot(home_b)
    assert snap_a["profile"] == "alpha"
    assert snap_b["profile"] == "beta"
    assert [row["session_id"] for row in snap_a["sessions"]] == ["alpha-1"]
    assert [row["session_id"] for row in snap_b["sessions"]] == ["beta-1"]
    assert snap_a["sessions"][0]["current_tool"] == "terminal"
    assert snap_b["sessions"][0]["current_tool"] is None


def test_provider_usage_updates_context_without_lifetime_token_fallback(tmp_path: Path, fixed_times):
    observer = Observer(tmp_path, "alpha")
    route = discord_route("alpha", "thread-1", "First thread")
    observer.session_started(route, "session-a", model="m", provider="p", at=fixed_times["t0"])

    observer.context_measured(
        route,
        "session-a",
        used=300,
        maximum=1000,
        source="provider_reported",
        at=fixed_times["t1"],
    )

    context = read_snapshot(tmp_path)["sessions"][0]["context"]
    assert context == {
        "used": 300,
        "maximum": 1000,
        "percentage": 30.0,
        "source": "provider_reported",
        "measured_at": fixed_times["t1"],
    }


def test_atomic_replacement_never_exposes_partial_json(tmp_path: Path, fixed_times):
    observer = Observer(tmp_path, "alpha")
    route = discord_route("alpha", "thread-1", "First thread")
    observer.session_started(route, "session-a", model="m", provider="p", at=fixed_times["t0"])
    path = tmp_path / "hermes-context" / "v1" / "snapshot.json"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE((path.parent / "snapshot.lock").stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    failures: list[Exception] = []
    finished = threading.Event()

    def read_loop() -> None:
        while not finished.is_set():
            try:
                validate_snapshot(json.loads(path.read_text(encoding="utf-8")))
            except Exception as exc:  # a torn read is the failure under test
                failures.append(exc)
                finished.set()

    reader = threading.Thread(target=read_loop)
    reader.start()
    for index in range(100):
        observer.mark_working(
            route,
            "session-a",
            tool="terminal" if index % 2 else None,
            at=f"2026-09-24T10:04:{index % 60:02d}.000Z",
        )
    finished.set()
    reader.join(timeout=5)

    assert failures == []
    assert not list(path.parent.glob("*.tmp"))
