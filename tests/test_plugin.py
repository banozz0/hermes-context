from __future__ import annotations

import ast
import builtins
import functools
import importlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

import hermes_context_observer as plugin
from hermes_context_observer import compat, register
from hermes_context_observer.compat import HOOK_FEATURES, INTERNAL_FEATURES, Hermes
from hermes_context_observer.contract import DEGRADED_FEATURES, effective_freshness, validate_snapshot
from hermes_context_observer.observer import KnownLane, Observer, Route, timestamp

from conftest import read_snapshot


EXPECTED_HOOKS = {
    "pre_gateway_dispatch",
    "on_session_start",
    "pre_api_request",
    "post_api_request",
    "pre_tool_call",
    "post_tool_call",
    "pre_approval_request",
    "post_approval_response",
    "on_session_end",
    "on_session_reset",
}


class FakeContext:
    profile_name = "alpha"

    def __init__(self):
        self.hooks = {}
        self.unload = None

    def register_hook(self, name, callback):
        self.hooks[name] = callback

    def on_unload(self, callback):
        self.unload = callback


class StubHermes(Hermes):
    """The task-local session source and generated title Hermes would hand the plugin, without Hermes."""

    def __init__(self, values: dict[str, str], title: str | None = None):
        super().__init__()
        self.values, self.title = values, title

    def session_value(self, name):
        return self.values.get(name, "")

    def conversation_title(self, home, session_id):
        return self.title

    def delegated_child(self):
        return False


def test_every_feature_has_its_internals_and_hooks_in_the_map():
    assert set(HOOK_FEATURES) == EXPECTED_HOOKS
    assert set().union(*INTERNAL_FEATURES.values(), HOOK_FEATURES.values()) == DEGRADED_FEATURES


def test_the_map_lists_every_hermes_internal_compat_reaches():
    """compat.py imports Hermes only inside its accessors: each name imported there, and each session database method
    called, has an entry. The removal test proves the converse, that every entry is reached."""
    tree = ast.parse(Path(compat.__file__).read_text(encoding="utf-8"))
    reached = {f"{node.module}.{alias.name}" for function in ast.walk(tree) if isinstance(function, ast.FunctionDef)
               for node in ast.walk(function) if isinstance(node, ast.ImportFrom) for alias in node.names}
    reached |= {f"hermes_state.SessionDB.{node.func.attr}" for node in ast.walk(tree)
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and getattr(node.func.value, "id", None) == "db"}
    assert reached - set(INTERNAL_FEATURES) == set()


def test_display_name_precedence_is_thread_then_generated_title_then_fallback(tmp_path: Path):
    values = {
        "HERMES_SESSION_PLATFORM": "discord",
        "HERMES_SESSION_CHAT_ID": "chat-1",
        "HERMES_SESSION_THREAD_ID": "thread-1",
        "HERMES_SESSION_CHAT_NAME": "Discord thread",
        "HERMES_SESSION_ID": "session-1",
    }
    hermes = StubHermes(values, "Generated title")
    assert plugin._route(hermes, "alpha", tmp_path).name == "Discord thread"
    values["HERMES_SESSION_THREAD_ID"] = ""
    assert plugin._route(hermes, "alpha", tmp_path).name == "Generated title"
    assert plugin._route(StubHermes(values), "alpha", tmp_path).name == "alpha discord session"


def write_directory(home: Path, *entries: dict) -> None:
    (home / "channel_directory.json").write_text(
        json.dumps({"updated_at": "2026-09-24T10:00:00Z", "platforms": {"discord": list(entries)}}), encoding="utf-8"
    )


def test_thread_lane_gets_bare_thread_name_and_parent_channel_label(tmp_path: Path):
    write_directory(
        tmp_path,
        {"id": "channel-10", "name": "ops", "guild": "Hermes", "type": "channel"},
        # Hermes may list the channel again, guild-less and named after its session; it must not win.
        {"id": "channel-10", "name": "Hermes / #ops", "type": "group"},
        {"id": "channel-10:thread-1", "name": "ops / Deploy review", "type": "thread", "thread_id": "thread-1"},
    )
    values = {
        "HERMES_SESSION_PLATFORM": "discord",
        "HERMES_SESSION_CHAT_ID": "thread-1",
        "HERMES_SESSION_PARENT_CHAT_ID": "channel-10",
        "HERMES_SESSION_THREAD_ID": "thread-1",
        "HERMES_SESSION_CHAT_NAME": "Hermes / #ops / Deploy review",
        "HERMES_SESSION_ID": "session-1",
    }
    hermes = StubHermes(values)
    route = plugin._route(hermes, "alpha", tmp_path)
    assert (route.name, route.channel_label, route.channel_id) == ("Deploy review", "#ops", "channel-10")
    # A thread whose own name contains the separator keeps it; only the exact known prefix goes.
    values["HERMES_SESSION_CHAT_NAME"] = "Hermes / #ops / Plan / phase 2"
    assert plugin._route(hermes, "alpha", tmp_path).name == "Plan / phase 2"
    # Forum parents carry no '#'.
    values["HERMES_SESSION_CHAT_NAME"] = "Hermes / ops / Forum post"
    assert plugin._route(hermes, "alpha", tmp_path).name == "Forum post"
    # Unknown channel: never guess where the thread name starts.
    values["HERMES_SESSION_PARENT_CHAT_ID"] = "channel-99"
    route = plugin._route(hermes, "alpha", tmp_path)
    assert (route.name, route.channel_label) == ("Hermes / ops / Forum post", None)


def test_unthreaded_lane_gets_channel_label_and_generated_title(tmp_path: Path):
    write_directory(tmp_path, {"id": "channel-20", "name": "planning", "guild": "Hermes", "type": "channel"})
    values = {"HERMES_SESSION_PLATFORM": "discord", "HERMES_SESSION_CHAT_ID": "channel-20", "HERMES_SESSION_ID": "s"}
    route = plugin._route(StubHermes(values, "Weekly planning"), "alpha", tmp_path)
    assert (route.name, route.channel_label) == ("Weekly planning", "#planning")


def test_channel_label_is_one_bounded_line_and_bad_directories_are_ignored(tmp_path: Path):
    values = {"HERMES_SESSION_PLATFORM": "discord", "HERMES_SESSION_CHAT_ID": "channel-20", "HERMES_SESSION_ID": "s"}
    hermes = StubHermes(values)
    write_directory(tmp_path, {"id": "channel-20", "name": "  new\nline\t" + "x" * 200, "guild": "Hermes"})
    label = plugin._route(hermes, "alpha", tmp_path).channel_label
    assert label.startswith("#new line x") and len(label) == 100
    for body in ("not json", '{"platforms": {"discord": {"id": "channel-20"}}}', "[]"):
        (tmp_path / "channel_directory.json").write_text(body, encoding="utf-8")
        assert plugin._route(hermes, "alpha", tmp_path).channel_label is None


def test_cli_registration_does_not_publish_gateway_heartbeat(tmp_path: Path, monkeypatch, hermes):
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: False)
    context = FakeContext()
    register(context)
    try:
        assert not (tmp_path / "hermes-context" / "v1" / "snapshot.json").exists()
        assert set(context.hooks) == EXPECTED_HOOKS
    finally:
        context.unload()


def test_registration_publishes_profile_heartbeat_without_any_hook(tmp_path: Path, monkeypatch, hermes):
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    context = FakeContext()
    path = tmp_path / "hermes-context" / "v1" / "snapshot.json"
    before = datetime.now(timezone.utc).replace(microsecond=0)
    register(context)
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
        validate_snapshot(snapshot)
        assert snapshot["profile"] == "alpha"
        assert snapshot["sessions"] == []
        assert datetime.fromisoformat(snapshot["gateway"]["heartbeat_at"].replace("Z", "+00:00")) >= before
        assert effective_freshness(snapshot, at=datetime.now(timezone.utc)) == "live"
    finally:
        if context.unload:
            context.unload()


def test_registration_restores_saved_rows_without_an_inbound_message(tmp_path: Path, monkeypatch, hermes):
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    route = Route("alpha", "discord", "thread-1", thread_id="thread-1")
    old = Observer(tmp_path, "alpha")
    old.session_started(route, "session-a", at="2020-01-01T00:00:00.000Z")
    path = old.store.path
    assert effective_freshness(json.loads(path.read_text()), at=datetime.now(timezone.utc)) == "offline"
    context = FakeContext()
    register(context)
    try:
        restored = json.loads(path.read_text(encoding="utf-8"))
        validate_snapshot(restored)
        assert [row["session_id"] for row in restored["sessions"]] == ["session-a"]
        assert restored["sessions"][0]["state"] == "idle"
        assert restored["sessions"][0]["timing"]["turn_started_at"] is None
        assert effective_freshness(restored, at=datetime.now(timezone.utc)) == "live"
    finally:
        if context.unload:
            context.unload()


def test_registration_before_the_gateway_lock_starts_once_the_gateway_takes_it(tmp_path: Path, monkeypatch, hermes):
    """Hermes loads the launch profile's plugins during config load, before its gateway claims the runtime lock."""
    from gateway import status
    owns_lock = [False]
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: owns_lock[0])
    routed = Route("alpha", "discord", "thread-2", thread_id="thread-2")
    monkeypatch.setattr(plugin, "_known_lanes", lambda *_args: [
        KnownLane(routed, "session-b", model=None, provider=None, used=None, maximum=0, at="2020-01-01T00:00:00.000Z")])
    old = Observer(tmp_path, "alpha")
    old.session_started(Route("alpha", "discord", "thread-1", thread_id="thread-1"), "session-a",
                        at="2020-01-01T00:00:00.000Z")  # In flight when the previous gateway stopped.
    context = FakeContext()
    register(context)
    try:
        assert read_snapshot(tmp_path)["gateway"]["heartbeat_at"] == "2020-01-01T00:00:00.000Z"
        owns_lock[0] = True
        deadline = time.monotonic() + 5
        while effective_freshness(snapshot := read_snapshot(tmp_path), at=datetime.now(timezone.utc)) != "live":
            assert time.monotonic() < deadline, "no heartbeat after the gateway took the runtime lock"
            time.sleep(0.05)
        validate_snapshot(snapshot)
        assert {row["session_id"]: row["state"] for row in snapshot["sessions"]} == {"session-a": "idle",
                                                                                     "session-b": "idle"}
    finally:
        context.unload()


def test_lost_title_lookup_switches_off_only_titles(tmp_path: Path, monkeypatch, hermes, caplog):
    """A Hermes update that drops the title lookup costs the generated name, never the plugin or the numbers."""
    from agent.model_metadata import save_context_length
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    with SessionDB(tmp_path / "state.db") as db:
        db.create_session("s", "discord")
        db.set_session_title("s", "Weekly planning")  # what the row would be called with the lookup in place
    monkeypatch.delattr(defining_class(SessionDB, "get_session_title"), "get_session_title")
    save_context_length("m", "https://models.example.test/v1", 200_000)
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="channel-20", session_id="s")  # unthreaded: asks for a title
    try:
        assert set(context.hooks) == EXPECTED_HOOKS
        assert "degraded" not in read_snapshot(tmp_path)  # beating, and nothing lost before a title was needed
        context.hooks["on_session_start"](session_id="s")
        context.hooks["post_api_request"](session_id="s", api_request_id="r1", model="m", provider="p",
                                          base_url="https://models.example.test/v1", usage={"prompt_tokens": 50_000})
        snapshot = read_snapshot(tmp_path)
        validate_snapshot(snapshot)
        assert snapshot["degraded"] == ["titles"]
        # Both hooks looked the title up; the loss is logged once.
        assert [r.levelname for r in caplog.records if r.name == "hermes_context_observer.compat"] == ["WARNING"]
        row = snapshot["sessions"][0]
        assert (row["display_name"], row["context"]["used"], row["context"]["percentage"]) == (
            "alpha discord session", 50_000, 25.0)
    finally:
        clear_session_vars(tokens)
        context.unload()


def defining_class(cls: type, name: str) -> type:
    """The class in `cls`'s MRO that defines `name`: Hermes builds SessionDB from mixins."""
    return next(c for c in cls.__mro__ if name in vars(c))


def without(monkeypatch, internal: str) -> None:
    """Hermes without `internal`, as the plugin meets it after a rename: a class attribute is deleted from the class
    that defines it; a module attribute stays for Hermes's own callers, but the plugin's import of it fails."""
    parts = internal.split(".")
    for split in range(len(parts) - 1, 0, -1):
        try:
            owner = importlib.import_module(".".join(parts[:split]))
            break
        except ImportError:
            continue
    *classes, name = parts[split:]
    if classes:
        cls = functools.reduce(getattr, classes, owner)
        monkeypatch.delattr(defining_class(cls, name), name)
        return
    real_import = builtins.__import__

    def blocked(module, globals=None, locals=None, fromlist=(), level=0):
        if (module == owner.__name__ and name in (fromlist or ())
                and (globals or {}).get("__name__", "").startswith("hermes_context_observer")):
            raise ImportError(f"cannot import name {name!r} from {module!r}")
        return real_import(module, globals, locals, fromlist, level)
    monkeypatch.setattr(builtins, "__import__", blocked)


LOST = [*INTERNAL_FEATURES.items(), *((f"hook:{hook}", {feature}) for hook, feature in HOOK_FEATURES.items())]


@pytest.mark.parametrize("internal, features", LOST, ids=[internal for internal, _ in LOST])
def test_hermes_without_an_internal_switches_off_only_its_features(tmp_path: Path, monkeypatch, hermes,
                                                                  internal, features):
    """A Hermes update that drops one internal or hook costs only the features the map gives it: the plugin registers
    and beats, `degraded` names exactly those features, and unless `sessions` is lost a completed request still
    measures context (percentage unknown only without `context_window`)."""
    from agent.model_metadata import save_context_length
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_cli import plugins
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    monkeypatch.setattr(plugin, "Observer", functools.partial(Observer, heartbeat_interval_seconds=0.05))
    base_url = "https://models.example.test/v1"
    save_context_length("m", base_url, 200_000)
    scope = str((tmp_path / "sessions").resolve())
    lane, backfilled = "agent:alpha:discord:group:channel-20", "agent:alpha:discord:thread:thread-1"
    with SessionDB(tmp_path / "state.db") as db:
        for session_id in ("s", "b"):
            db.create_session(session_id, "discord", model="m")
        db.end_session("s", "compression")
        db.create_session("s2", "discord", parent_session_id="s")  # s's compression successor
        # Too bare for backfill, so the live lane is admitted by ownership; thread-1 is backfilled at activation.
        db.save_gateway_routing_entry(lane, json.dumps({"session_key": lane, "session_id": "s"}), scope=scope)
        db.save_gateway_routing_entry(backfilled, json.dumps({
            "session_key": backfilled, "session_id": "b", "platform": "discord", "last_prompt_tokens": 7,
            "origin": {"platform": "discord", "chat_type": "thread", "chat_id": "thread-1", "thread_id": "thread-1",
                       "user_id": "u"},
            "created_at": "2026-09-27T12:00:00", "updated_at": "2026-09-27T12:00:00", "expiry_finalized": False,
        }), scope=scope)
    if internal.startswith("hook:"):
        monkeypatch.setattr(plugins, "VALID_HOOKS", set(plugins.VALID_HOOKS) - {internal.removeprefix("hook:")})
    else:
        without(monkeypatch, internal)
    context = FakeContext()
    register(context)
    hooks = context.hooks
    route = {"model": "m", "provider": "anthropic", "base_url": base_url}
    tokens = set_session_vars(platform="discord", chat_id="channel-20", session_key=lane, session_id="s")
    try:
        assert set(hooks) == EXPECTED_HOOKS
        hooks["pre_gateway_dispatch"]()
        hooks["on_session_start"](session_id="s")
        hooks["pre_api_request"](session_id="s", **route)
        hooks["post_api_request"](session_id="s", api_request_id="r1", usage={"prompt_tokens": 50_000}, **route)
        hooks["pre_tool_call"](session_id="s", tool_name="clarify")
        hooks["pre_approval_request"](session_id="s")
        hooks["post_approval_response"](session_id="s")
        for call, result in (("c1", "done"), ("c2", {"_multimodal": True, "content": [{"type": "text", "text": "x"}]})):
            hooks["post_tool_call"](session_id="s", tool_name="terminal", tool_call_id=call, api_request_id="r1",
                                    result=result, status="ok", duration_ms=1)
        hooks["post_api_request"](session_id="s2", api_request_id="r2", usage={"prompt_tokens": 60_000}, **route)
        hooks["on_session_end"](session_id="s2")
        after, deadline = timestamp(), time.monotonic() + 5
        while (snapshot := read_snapshot(tmp_path))["gateway"]["heartbeat_at"] <= after:  # A beat after every mark.
            assert time.monotonic() < deadline, "no heartbeat after the hooks ran"
            time.sleep(0.02)
        validate_snapshot(snapshot)
        assert snapshot.get("degraded", []) == sorted(features)
        if "sessions" not in features:
            rows = {row["discord_route"]["channel_id"]: row for row in snapshot["sessions"]}
            assert type(rows["channel-20"]["context"]["used"]) is int
            assert (rows["channel-20"]["context"]["percentage"] is None) == ("context_window" in features)
            assert "thread-1" in rows or "backfill" in features  # The backfill path ran, so its losses are real.
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_an_unforeseen_error_never_escapes_a_hook(tmp_path: Path, monkeypatch, hermes, caplog):
    """An error no fallback expects aborts only the plugin's callback, never the Hermes turn, and is logged once."""
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    with SessionDB(tmp_path / "state.db") as db:
        db.create_session("s", "discord")

    def title(self, session_id):
        raise LookupError("a failure no fallback expects")
    monkeypatch.setattr(defining_class(SessionDB, "get_session_title"), "get_session_title", title)
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="channel-20", session_id="s")  # unthreaded: asks for a title
    try:
        for request_id in ("r1", "r2"):
            context.hooks["post_api_request"](session_id="s", api_request_id=request_id, model="m", provider="p",
                                              usage={"prompt_tokens": 5})
        assert [r.getMessage() for r in caplog.records if r.name == "hermes_context_observer"] == [
            "Hermes Context's post_api_request hook failed; Hermes carries on without it"]
        assert "degraded" not in read_snapshot(tmp_path)  # Not a change the plugin can name.
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_registration_never_throws_into_hermes(tmp_path: Path, hermes, caplog):
    """A Hermes whose plugin API changed shape gets a logged, unobserved process, never a failed plugin load."""
    class ChangedContext(FakeContext):
        def register_hook(self, name, callback, priority):  # A new required argument.
            super().register_hook(name, callback)

    register(ChangedContext())
    assert [r.getMessage() for r in caplog.records if r.name == "hermes_context_observer"] == [
        "Hermes Context could not register; this Hermes process goes unobserved"]


def test_register_uses_only_supported_observer_hooks(tmp_path: Path, monkeypatch, hermes):
    context = FakeContext()
    register(context)
    try:
        assert set(context.hooks) == EXPECTED_HOOKS
        assert callable(context.unload)
    finally:
        if context.unload:
            context.unload()


def test_child_request_on_parent_route_does_not_create_a_generation(tmp_path: Path, monkeypatch, hermes):
    from agent.delegation_context import delegated_child_context
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="parent")
    try:
        context.hooks["on_session_start"](session_id="parent")
        with delegated_child_context("child"):
            context.hooks["on_session_start"](session_id="child")
            context.hooks["pre_api_request"](session_id="child")
            context.hooks["post_api_request"](session_id="child", api_request_id="child:1",
                                               model="m", provider="p", usage={"prompt_tokens": 5})
            context.hooks["on_session_end"](session_id="child")
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert (row["session_id"], row["previous_session_id"]) == ("parent", None)
        assert not list((tmp_path / "hermes-context/v1/events").glob("*/*.json"))
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_unknown_lifecycle_hooks_cannot_rotate_a_known_lane(tmp_path: Path, monkeypatch, hermes):
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="parent")
    try:
        context.hooks["on_session_start"](session_id="parent")
        context.hooks["on_session_start"](session_id="unknown")
        context.hooks["pre_api_request"](session_id="unknown", model="m", provider="p")
        context.hooks["post_api_request"](session_id="unknown", api_request_id="u:1", model="m", provider="p")
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert (row["session_id"], row["previous_session_id"]) == ("parent", None)
        assert not list((tmp_path / "hermes-context/v1/events").glob("*/*.json"))
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_competing_compression_sibling_cannot_replace_selected_tip(tmp_path: Path, monkeypatch, hermes):
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    with SessionDB(tmp_path / "state.db") as db:
        db.create_session("parent", "discord")
        db.end_session("parent", "compression")
        db.create_session("candidate-a", "discord", parent_session_id="parent")
        db.create_session("candidate-b", "discord", parent_session_id="parent")
        chain = db.get_compression_chain("parent")
    assert len(chain) == 2
    selected = chain[1]
    sibling = ({"candidate-a", "candidate-b"} - {selected}).pop()
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="parent")
    try:
        context.hooks["on_session_start"](session_id="parent")
        context.hooks["on_session_start"](session_id=sibling)
        context.hooks["pre_api_request"](session_id=sibling)
        context.hooks["post_api_request"](session_id=sibling, api_request_id="sibling:1", model="m", provider="p")
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert row["session_id"] == "parent"
        context.hooks["on_session_start"](session_id=selected)
        context.hooks["pre_api_request"](session_id=selected)
        context.hooks["post_api_request"](session_id=selected, api_request_id="tip:1", model="m", provider="p")
        written = [json.loads(path.read_text()) for path in (tmp_path / "hermes-context/v1/events").glob("*/*.json")]
        assert [(e["session_id"], e["previous_session_id"]) for e in written] == [(selected, "parent")]
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_two_compressions_before_request_preserve_immediate_predecessor(tmp_path: Path, monkeypatch, hermes):
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    with SessionDB(tmp_path / "state.db") as db:
        db.create_session("root", "discord")
        db.end_session("root", "compression")
        db.create_session("middle", "discord", parent_session_id="root")
        db.end_session("middle", "compression")
        db.create_session("latest", "discord", parent_session_id="middle")
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="root")
    try:
        context.hooks["on_session_start"](session_id="root")
        context.hooks["post_api_request"](session_id="latest", api_request_id="latest:1", model="m", provider="p")
        written = [json.loads(path.read_text()) for path in (tmp_path / "hermes-context/v1/events").glob("*/*.json")]
        assert [(e["session_id"], e["lineage_root_id"], e["previous_session_id"]) for e in written] == [
            ("latest", "root", "middle")]
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_compression_successor_links_without_plugin_reset_hook(tmp_path: Path, monkeypatch, hermes):
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    with SessionDB(tmp_path / "state.db") as db:
        db.create_session("parent", "discord")
        db.end_session("parent", "compression")
        db.create_session("successor", "discord", parent_session_id="parent")
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="parent")
    try:
        context.hooks["on_session_start"](session_id="parent")
        context.hooks["post_api_request"](session_id="parent", api_request_id="p:1", model="m", provider="p")
        context.hooks["on_session_start"](session_id="successor")
        context.hooks["pre_api_request"](session_id="successor", model="m", provider="p")
        context.hooks["post_api_request"](session_id="successor", api_request_id="s:1", model="m", provider="p")
        written = [json.loads(path.read_text()) for path in sorted((tmp_path / "hermes-context/v1/events").glob("*/*.json"))]
        assert [(e["session_id"], e["lineage_root_id"], e["previous_session_id"]) for e in written] == [
            ("parent", "parent", None), ("successor", "parent", "parent")]
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert (row["session_id"], row["previous_session_id"]) == ("successor", "parent")
    finally:
        clear_session_vars(tokens)
        context.unload()

def test_gateway_route_switch_without_reset_and_resume_preserve_history(tmp_path: Path, monkeypatch, hermes):
    """Gateway key repoints without a plugin reset hook on recovery and /resume."""
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    key = "agent:alpha:discord:thread:lane:thread"
    scope = str((tmp_path / "sessions").resolve())

    def point_at(session_id: str) -> None:
        with SessionDB(tmp_path / "state.db") as db:
            db.save_gateway_routing_entry(key, json.dumps({"session_key": key, "session_id": session_id}), scope=scope)

    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread",
                              session_key=key, session_id="old")
    try:
        context.hooks["on_session_start"](session_id="unowned")
        assert json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"] == []
        point_at("old")
        context.hooks["on_session_start"](session_id="old")
        context.hooks["post_api_request"](session_id="old", api_request_id="old:1", model="m", provider="p")
        with SessionDB(tmp_path / "state.db") as db:
            db.save_gateway_routing_entry(key, json.dumps({"session_key": key, "session_id": "other"}), scope="other-scope")
        context.hooks["on_session_start"](session_id="other")
        assert json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]["session_id"] == "old"
        with SessionDB(tmp_path / "state.db") as db:
            db.replace_gateway_routing_entries({}, scope="other-scope")
        point_at("recovered")  # No on_session_reset or compression link.
        context.hooks["on_session_start"](session_id="recovered")
        context.hooks["post_api_request"](session_id="recovered", api_request_id="new:1", model="m", provider="p")
        assert json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]["session_id"] == "recovered"

        point_at("old")  # /resume returns to an ended generation without a reset hook.
        context.hooks["pre_api_request"](session_id="old", model="m", provider="p")
        context.hooks["post_api_request"](session_id="old", api_request_id="old:2", model="m", provider="p")
        context.hooks["post_api_request"](session_id="old", api_request_id="old:2", model="m", provider="p")
        context.hooks["on_session_reset"](old_session_id="old", new_session_id="after-resume")
        point_at("after-resume")
        context.hooks["post_api_request"](session_id="after-resume", api_request_id="after:1", model="m", provider="p")
        written = [json.loads(path.read_text()) for path in sorted((tmp_path / "hermes-context/v1/events").glob("*/*.json"))]
        assert [(e["session_id"], e["lineage_root_id"], e["previous_session_id"]) for e in written] == [
            ("old", "old", None), ("recovered", "old", "old"), ("old", "old", None),
            ("after-resume", "old", "old")]
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert (row["session_id"], row["lineage_root_id"], row["previous_session_id"]) == (
            "after-resume", "old", "old")
        context.hooks["post_api_request"](session_id="stranger", api_request_id="stranger:1", model="m", provider="p")
        assert len(list((tmp_path / "hermes-context/v1/events").glob("*/*.json"))) == 4
    finally:
        clear_session_vars(tokens)
        context.unload()

def test_scoped_profiles_use_process_route_index_and_isolate_events(tmp_path: Path, monkeypatch, hermes):
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    scope = str((tmp_path / "sessions").resolve())
    contexts = {}
    for name in ("alpha", "beta"):
        home = tmp_path / "profiles" / name
        home.mkdir(parents=True)
        token = set_hermes_home_override(home)
        try:
            context = FakeContext()
            context.profile_name = name
            register(context)
            contexts[name] = context
        finally:
            reset_hermes_home_override(token)
    try:
        for name, sid in (("alpha", "alpha-old"), ("beta", "beta-old"), ("alpha", "alpha-new")):
            key = f"agent:{name}:discord:thread:lane:thread"
            with SessionDB(tmp_path / "state.db") as db:
                db.save_gateway_routing_entry(key, json.dumps({"session_key": key, "session_id": sid}), scope=scope)
            token = set_hermes_home_override(tmp_path / "profiles" / name)
            vars_token = set_session_vars(platform="discord", chat_id="lane", thread_id="thread",
                                          session_key=key, session_id=sid)
            try:
                contexts[name].hooks["on_session_start"](session_id=sid)
                contexts[name].hooks["post_api_request"](session_id=sid, api_request_id=sid + ":1", model="m", provider="p")
            finally:
                clear_session_vars(vars_token)
                reset_hermes_home_override(token)
        def ids(name):
            directory = tmp_path / "profiles" / name / "hermes-context/v1/events"
            return [json.loads(path.read_text())["session_id"] for path in sorted(directory.glob("*/*.json"))]
        assert ids("alpha") == ["alpha-old", "alpha-new"]
        assert ids("beta") == ["beta-old"]
    finally:
        for context in contexts.values():
            context.unload()


SENTINEL = "PRIVACY-SENTINEL-4c1e"


def test_post_tool_call_publishes_sanitized_usage_once(tmp_path: Path, monkeypatch, hermes):
    from agent.delegation_context import delegated_child_context
    from agent.model_metadata import estimate_messages_tokens_rough, estimate_tokens_rough
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    context = FakeContext()
    register(context)
    tokens = set_session_vars(platform="discord", chat_id="lane", thread_id="thread", session_id="parent")
    private = {"command": SENTINEL, "file_path": SENTINEL, "nested": {"secret": SENTINEL}}
    skill_body = f"# Writing\n{SENTINEL}\n" + "word " * 400
    image = {"_multimodal": True, "content": [{"type": "text", "text": SENTINEL},
                                              {"type": "image_url", "image_url": {"url": "data:image/png;base64," + "A" * 4000}}]}

    def tool(tool_call_id, tool_name, *, result, status="ok", args=None, request="turn-1:api:1", **extra):
        context.hooks["post_tool_call"](
            tool_name=tool_name, args={**private, **(args or {})}, result=result, task_id="task", session_id="parent",
            tool_call_id=tool_call_id, turn_id="turn-1", api_request_id=request, duration_ms=42, status=status,
            error_type="tool_error" if status != "ok" else None, error_message=SENTINEL if status != "ok" else None,
            middleware_trace=[{"note": SENTINEL}], **extra)

    try:
        context.hooks["on_session_start"](session_id="parent")
        context.hooks["post_api_request"](session_id="parent", api_request_id="turn-1:api:1", model="m", provider="p",
                                          usage={"prompt_tokens": 10}, response={"content": SENTINEL})
        context.hooks["pre_tool_call"](session_id="parent", tool_name="skill_view", args=private)
        tool("call-1", "skill_view", args={"name": "writing"}, result=skill_body)
        tool("call-1", "skill_view", args={"name": "writing"}, result=skill_body)  # the same hook again
        tool("call-2", "skill_view", args={"name": SENTINEL}, result=json.dumps({"error": SENTINEL}), status="error")
        tool("call-3", "terminal", result=json.dumps({"output": SENTINEL, "exit_code": 1}), status="error")
        tool("call-4", "terminal", result="blocked by policy", status="blocked")
        tool("call-5", "browser_vision", result=image)
        tool("", "terminal", result=SENTINEL)  # no tool_call_id, no identity
        with delegated_child_context("child"):
            tool("call-6", "terminal", result=SENTINEL)
        clear_session_vars(tokens)
        tokens = set_session_vars(platform="telegram", chat_id="lane", session_id="parent")
        tool("call-7", "terminal", result=SENTINEL)  # not a Discord lane
        files = sorted((tmp_path / "hermes-context/v1/events").glob("*/*.json"))
        written = [json.loads(path.read_text()) for path in files]
        request, *calls = written
        assert [e["sequence"] for e in written] == [1, 2, 3, 4, 5, 6]
        assert [(e["tool_name"], e["skill_name"], e["status"]) for e in calls] == [
            ("skill_view", "writing", "ok"), ("skill_view", None, "error"), ("terminal", None, "error"),
            ("terminal", None, "error"), ("browser_vision", None, "ok")]
        assert calls[0]["estimated_tokens"] == estimate_tokens_rough(skill_body)
        assert calls[3]["estimated_tokens"] == estimate_tokens_rough("blocked by policy")
        assert calls[4]["estimated_tokens"] == estimate_messages_tokens_rough([{"role": "tool", "content": image["content"]}])
        assert all(e["request_event_id"] == request["event_id"] and e["duration_ms"] == 42 for e in calls)
        assert all(e["session_id"] == "parent" and e["lineage_root_id"] == "parent" for e in calls)
        for path in [*files, tmp_path / "hermes-context/v1/snapshot.json"]:
            assert SENTINEL.encode() not in path.read_bytes()
        row = json.loads((tmp_path / "hermes-context/v1/snapshot.json").read_text())["sessions"][0]
        assert (row["state"], row["current_tool"]) == ("working", None)
    finally:
        clear_session_vars(tokens)
        context.unload()


def test_registration_backfills_routed_discord_lanes_with_last_context(tmp_path: Path, monkeypatch, hermes):
    """A fresh install lists every lane the gateway already routes for this profile, before any new request."""
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway import status
    from hermes_state import SessionDB
    from agent.model_metadata import save_context_length
    monkeypatch.setattr(status, "owns_gateway_runtime_lock", lambda: True)
    base_url = "https://models.example.test/v1"
    home = tmp_path / "profiles" / "alpha"
    home.mkdir(parents=True)
    write_directory(home, {"id": "chan-1", "name": "ops", "guild": "Guild"},
                    {"id": "chan-2", "name": "general", "guild": "Guild"})
    # Hermes stores routing times as naive local wall-clock text.
    measured = datetime(2026, 9, 27, 10, 0, 0, 123000, tzinfo=timezone.utc)
    local_text = measured.astimezone().replace(tzinfo=None).isoformat()
    token = set_hermes_home_override(home)
    try:
        save_context_length("m", base_url, 200_000)
        with SessionDB(home / "state.db") as db:
            for sid in ("alpha-thread", "alpha-channel", "alpha-telegram", "alpha-finished"):
                db.create_session(sid, "discord", model="m")
                db.update_token_counts(sid, input_tokens=10, output_tokens=5, api_call_count=1,
                                        billing_provider="p", billing_base_url=base_url)
                db.append_message(sid, "user", content=SENTINEL)
            db.set_session_title("alpha-channel", "Release planning")
    finally:
        reset_hermes_home_override(token)
    scope = str((tmp_path / "sessions").resolve())

    def route_entry(key, sid, *, last_prompt_tokens=0, finalized=False, **origin):
        entry = {"session_key": key, "session_id": sid, "platform": origin.get("platform", "discord"),
                 "origin": {"platform": "discord", "chat_type": "group", "user_id": "u", "user_name": SENTINEL,
                            "chat_topic": SENTINEL, "profile": "alpha", **origin},
                 "last_prompt_tokens": last_prompt_tokens, "created_at": local_text, "updated_at": local_text,
                 "expiry_finalized": finalized}
        with SessionDB(tmp_path / "state.db") as db:
            db.save_gateway_routing_entry(key, json.dumps(entry), scope=scope)

    route_entry("agent:alpha:discord:thread:thread-1", "alpha-thread", last_prompt_tokens=50_000,
                chat_id="thread-1", thread_id="thread-1", parent_chat_id="chan-1", scope_id="guild-1",
                guild_id="guild-1", chat_name="Guild / #ops / Deploy check", chat_type="thread")
    route_entry("agent:alpha:discord:group:chan-2", "alpha-channel",
                chat_id="chan-2", thread_id=None, scope_id="guild-1", guild_id="guild-1", chat_name="Guild / #general")
    route_entry("agent:beta:discord:thread:thread-9", "beta-thread", last_prompt_tokens=9,
                chat_id="thread-9", thread_id="thread-9", chat_name="Other profile's lane", profile="beta")
    route_entry("agent:alpha:telegram:dm:1", "alpha-telegram", last_prompt_tokens=7, platform="telegram",
                chat_id="1", thread_id=None, chat_name="Telegram DM")
    route_entry("agent:alpha:discord:thread:thread-5", "alpha-finished", last_prompt_tokens=5, finalized=True,
                chat_id="thread-5", thread_id="thread-5", chat_name="Finished lane")

    context = FakeContext()
    token = set_hermes_home_override(home)
    try:
        register(context)
    finally:
        reset_hermes_home_override(token)
    try:
        snapshot = json.loads((home / "hermes-context/v1/snapshot.json").read_text())
        validate_snapshot(snapshot)
        rows = {row["session_id"]: row for row in snapshot["sessions"]}
        assert set(rows) == {"alpha-thread", "alpha-channel"}
        thread, channel = rows["alpha-thread"], rows["alpha-channel"]
        assert thread["display_name"] == "Deploy check"
        assert thread["discord_route"] == {"guild_id": "guild-1", "channel_id": "chan-1", "thread_id": "thread-1",
                                           "channel_label": "#ops"}
        assert (thread["state"], thread["current_tool"], thread["model"], thread["provider"]) == ("idle", None, "m", "p")
        assert thread["context"] == {"used": 50_000, "maximum": 200_000, "percentage": 25.0,
                                     "source": "provider_reported", "measured_at": "2026-09-27T10:00:00.123Z"}
        assert thread["timing"] == {"turn_started_at": None, "last_activity_at": "2026-09-27T10:00:00.123Z"}
        assert (thread["lineage_root_id"], thread["previous_session_id"]) == ("alpha-thread", None)
        assert channel["display_name"] == "Release planning"
        assert channel["discord_route"] == {"guild_id": "guild-1", "channel_id": "chan-2", "thread_id": None,
                                            "channel_label": "#general"}
        assert channel["context"] == {"used": None, "maximum": None, "percentage": None, "source": None,
                                      "measured_at": None}
        assert not list((home / "hermes-context/v1/events").glob("*/*.json"))

        # The live path lands on the backfilled row: same routing identity, no second row.
        token = set_hermes_home_override(home)
        vars_token = set_session_vars(platform="discord", chat_id="thread-1", thread_id="thread-1",
                                      parent_chat_id="chan-1", scope_id="guild-1",
                                      chat_name="Guild / #ops / Deploy check",
                                      session_key="agent:alpha:discord:thread:thread-1", session_id="alpha-thread")
        try:
            context.hooks["post_api_request"](session_id="alpha-thread", api_request_id="r1", model="m", provider="p",
                                              base_url=base_url, usage={"prompt_tokens": 60_000})
        finally:
            clear_session_vars(vars_token)
            reset_hermes_home_override(token)
        after = json.loads((home / "hermes-context/v1/snapshot.json").read_text())["sessions"]
        assert len(after) == 2
        assert {row["session_id"]: row["context"]["used"] for row in after} == {"alpha-thread": 60_000,
                                                                               "alpha-channel": None}
        for path in (home / "hermes-context").rglob("*"):
            if path.is_file():
                assert SENTINEL.encode() not in path.read_bytes(), path
    finally:
        context.unload()
