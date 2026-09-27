"""Live Hermes plugin-discovery probe using only temporary profile homes."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PLUGIN_SOURCE = PROJECT / "hermes_context_observer"
HERMES_SOURCE = Path(os.environ.get("HERMES_AGENT_SOURCE", "/Users/sven/.hermes/hermes-agent"))
if not (HERMES_SOURCE / "hermes_constants.py").is_file():
    raise SystemExit("Hermes source checkout not found; set HERMES_AGENT_SOURCE")
sys.path.insert(0, str(HERMES_SOURCE))


def install_plugin(home: Path) -> None:
    target = home / "plugins" / "hermes-context-observer"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(PLUGIN_SOURCE, target)
    (home / "config.yaml").write_text(
        "plugins:\n  enabled:\n    - hermes-context-observer\n",
        encoding="utf-8",
    )


def snapshot(home: Path) -> dict:
    return json.loads((home / "hermes-context" / "v1" / "snapshot.json").read_text(encoding="utf-8"))

def events(home: Path, kind: str | None = None) -> list[dict]:
    found = [json.loads(path.read_text(encoding="utf-8")) for path in sorted((home / "hermes-context/v1/events").glob("*/*.json"))]
    return [event for event in found if kind in (None, event["kind"])]


def fresh(snapshot: dict, *, at: datetime | None = None) -> bool:
    heartbeat = datetime.fromisoformat(snapshot["gateway"]["heartbeat_at"].replace("Z", "+00:00"))
    age = ((at or datetime.now(timezone.utc)) - heartbeat).total_seconds()
    return age <= snapshot["gateway"]["offline_after_seconds"]


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="hermes-context-plugin-probe-"))
    os.environ["HOME"] = str(root)
    base = root / ".hermes"
    os.environ["HERMES_HOME"] = str(base)
    home_a = base / "profiles" / "alpha"
    home_b = base / "profiles" / "beta"
    home_a.mkdir(parents=True)
    home_b.mkdir(parents=True)
    install_plugin(home_a)
    install_plugin(home_b)

    from gateway.session_context import clear_session_vars, set_session_vars
    from gateway.status import acquire_gateway_runtime_lock, owns_gateway_runtime_lock, release_gateway_runtime_lock
    from hermes_cli.plugins import PluginManager
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    @contextmanager
    def scope(home: Path):
        token = set_hermes_home_override(home)
        try:
            yield
        finally:
            reset_hermes_home_override(token)

    managers: dict[str, PluginManager] = {}
    for name, home in (("alpha", home_a), ("beta", home_b)):
        with scope(home):
            assert acquire_gateway_runtime_lock()
            try:
                manager = PluginManager()
                manager.discover_and_load()
                assert manager.has_hook("on_session_start")
                managers[name] = manager
                # The owning gateway publishes before any dispatch or session hook.
                initial = snapshot(home)
                assert initial["profile"] == name
                assert initial["sessions"] == []
                assert fresh(initial)
            finally:
                release_gateway_runtime_lock()

    @contextmanager
    def lane(name: str, home: Path, session_id: str, thread_id: str = "thread-1"):
        """One Discord turn's task-local routing inside the profile's home, as the gateway binds it."""
        with scope(home):
            tokens = set_session_vars(platform="discord", chat_id="channel-10", chat_name="Shared thread",
                                      thread_id=thread_id, scope_id="guild-1", session_id=session_id,
                                      profile=name, parent_chat_id="channel-10")
            try:
                yield
            finally:
                clear_session_vars(tokens)

    def fire(name: str, home: Path, session_id: str, tool: str | None = None,
             *, manager: PluginManager | None = None, thread_id: str = "thread-1") -> None:
        with lane(name, home, session_id, thread_id):
            (manager or managers[name]).invoke_hook(
                "on_session_start",
                session_id=session_id,
                model=f"model-{name}",
                platform="discord",
            )
            if tool:
                (manager or managers[name]).invoke_hook(
                    "pre_tool_call",
                    session_id=session_id,
                    tool_name=tool,
                    args={"not_serialized": True},
                )

    def request(name: str, home: Path, session_id: str, request_id: str) -> None:
        with lane(name, home, session_id):
            managers[name].invoke_hook(
                "post_api_request", session_id=session_id, api_request_id=request_id,
                model=f"model-{name}", provider="unlisted-provider",
                ended_at=1790244000.0, usage={"prompt_tokens": 30},
                response={"content": "PRIVATE_RESPONSE"}, assistant_message="PRIVATE_MESSAGE",
            )

    def tool(name: str, home: Path, session_id: str, request_id: str, tool_call_id: str, tool_name: str,
             status: str = "ok") -> None:
        with lane(name, home, session_id):
            managers[name].invoke_hook(
                "post_tool_call", tool_name=tool_name, args={"name": "writing", "command": "PRIVATE_ARGUMENT"},
                result="PRIVATE_RESULT " * 40, task_id="task", session_id=session_id, tool_call_id=tool_call_id,
                turn_id=request_id.split(":")[0], api_request_id=request_id, duration_ms=12, status=status,
                error_type="tool_error" if status != "ok" else None,
                error_message="PRIVATE_ERROR" if status != "ok" else None, middleware_trace=[],
            )

    try:
        # A CLI manager loads with no gateway lock: it must not publish a heartbeat.
        with scope(home_a):
            before_cli = snapshot(home_a)
            shadow = PluginManager()
            shadow.discover_and_load()
            assert not owns_gateway_runtime_lock()
            assert snapshot(home_a) == before_cli
            assert acquire_gateway_runtime_lock()
        try:
            fire("alpha", home_a, "alpha-1")
            assert [row["session_id"] for row in snapshot(home_a)["sessions"]] == ["alpha-1"]
            fire("alpha", home_a, "alpha-2", manager=shadow, thread_id="thread-2")
            assert {row["session_id"] for row in snapshot(home_a)["sessions"]} == {"alpha-1", "alpha-2"}
            # Gateway stops, CLI stays loaded and writes a row: no gateway heartbeat renewal.
            before_down = snapshot(home_a)
            with scope(home_a):
                managers["alpha"].unload()
                release_gateway_runtime_lock()
            fire("alpha", home_a, "alpha-2", manager=shadow, thread_id="thread-2")
            after_down = snapshot(home_a)
            assert {row["session_id"] for row in after_down["sessions"]} == {"alpha-1", "alpha-2"}
            assert after_down["gateway"]["heartbeat_at"] == before_down["gateway"]["heartbeat_at"]
            heartbeat = datetime.fromisoformat(after_down["gateway"]["heartbeat_at"].replace("Z", "+00:00"))
            assert not fresh(after_down, at=heartbeat + timedelta(seconds=46))
        finally:
            with scope(home_a):
                shadow.unload()

        with scope(home_a):
            assert acquire_gateway_runtime_lock()
            managers["alpha"] = PluginManager()
            managers["alpha"].discover_and_load()

        fire("alpha", home_a, "alpha-1")
        request("alpha", home_a, "alpha-1", "alpha-turn:api:1")
        tool("alpha", home_a, "alpha-1", "alpha-turn:api:1", "call-a1", "skill_view")
        with scope(home_a):
            release_gateway_runtime_lock()
        with scope(home_b):
            assert acquire_gateway_runtime_lock()
        fire("beta", home_b, "beta-1")
        request("beta", home_b, "beta-1", "beta-turn:api:1")
        tool("beta", home_b, "beta-1", "beta-turn:api:1", "call-b1", "terminal", status="error")
        with scope(home_b):
            release_gateway_runtime_lock()
        with scope(home_a):
            assert acquire_gateway_runtime_lock()
        fire("alpha", home_a, "alpha-1", tool="terminal")
        request("alpha", home_a, "alpha-1", "alpha-turn:api:2")
        alpha = snapshot(home_a)
        beta = snapshot(home_b)
        assert alpha["profile"] == "alpha"
        assert beta["profile"] == "beta"
        assert {row["session_id"] for row in alpha["sessions"]} == {"alpha-1", "alpha-2"}
        assert [row["session_id"] for row in beta["sessions"]] == ["beta-1"]
        assert next(row for row in alpha["sessions"] if row["session_id"] == "alpha-1")["current_tool"] == "terminal"
        assert beta["sessions"][0]["current_tool"] is None
        assert "not_serialized" not in json.dumps(alpha)
        assert "not_serialized" not in json.dumps(beta)
        tool("alpha", home_a, "alpha-1", "alpha-turn:api:2", "call-a2", "terminal")
        tool("alpha", home_a, "alpha-1", "alpha-turn:api:2", "call-a2", "terminal")  # the same hook again
        assert [e["kind"] for e in events(home_a)] == ["model_request", "tool_call", "model_request", "tool_call"]
        assert [e["kind"] for e in events(home_b)] == ["model_request", "tool_call"]
        assert [e["sequence"] for e in events(home_a)] == [1, 2, 3, 4]
        assert len({event["event_id"] for event in events(home_a) + events(home_b)}) == 6
        assert [(e["tool_name"], e["skill_name"], e["status"]) for e in events(home_a, "tool_call") + events(home_b, "tool_call")] == [
            ("skill_view", "writing", "ok"), ("terminal", None, "ok"), ("terminal", None, "error")]
        requests = {e["event_id"] for e in events(home_a, "model_request") + events(home_b, "model_request")}
        assert all(e["request_event_id"] in requests for e in events(home_a, "tool_call") + events(home_b, "tool_call"))
        assert all("PRIVATE" not in json.dumps(event) and "current_tool" not in event
                   for event in events(home_a) + events(home_b))
        assert next(row for row in snapshot(home_a)["sessions"] if row["session_id"] == "alpha-1")["current_tool"] is None

        # Stop only alpha; simulate a stale saved document, then activate without traffic.
        with scope(home_a):
            managers["alpha"].unload()
            release_gateway_runtime_lock()
        stale = snapshot(home_a)
        stale["generated_at"] = "2020-01-01T00:00:00.000Z"
        stale["gateway"]["heartbeat_at"] = stale["generated_at"]
        (home_a / "hermes-context" / "v1" / "snapshot.json").write_text(
            json.dumps(stale), encoding="utf-8"
        )
        assert not fresh(snapshot(home_a))
        with scope(home_a):
            assert acquire_gateway_runtime_lock()
            restarted = PluginManager()
            restarted.discover_and_load()
            managers["alpha"] = restarted
            resumed = snapshot(home_a)
            assert fresh(resumed)
            assert resumed["profile"] == "alpha"
            assert {row["session_id"] for row in resumed["sessions"]} == {"alpha-1", "alpha-2"}
            assert all(row["state"] == "idle" and row["current_tool"] is None for row in resumed["sessions"])
            request("alpha", home_a, "alpha-1", "alpha-turn:api:2")
            tool("alpha", home_a, "alpha-1", "alpha-turn:api:1", "call-a1", "skill_view")
            assert len(events(home_a)) == 4, "a restarted gateway replaying requests and tool calls writes nothing"
        assert snapshot(home_b) == beta
        for home in (home_a, home_b):
            for path in (home / "hermes-context").rglob("*"):
                assert not path.is_file() or b"PRIVATE" not in path.read_bytes(), path
        if keep := os.environ.get("HERMES_CONTEXT_PROBE_KEEP"):
            # The bridge files alone, for a headless app import; the plugin copies and Hermes state stay behind.
            for name, home in (("alpha", home_a), ("beta", home_b)):
                shutil.copytree(home / "hermes-context", Path(keep) / "profiles" / name / "hermes-context")
        print("plugin discovery A→B→A, request and tool-call uniqueness/privacy/replay, same-home no-loss, "
              "gateway-down Offline, restart: ok")
    finally:
        for name, home in (("alpha", home_a), ("beta", home_b)):
            with scope(home):
                managers[name].unload()
                if owns_gateway_runtime_lock():
                    release_gateway_runtime_lock()
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
