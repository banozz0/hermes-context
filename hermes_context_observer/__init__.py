"""Hermes Context observer plugin.

The callbacks deliberately read only routing metadata and lifecycle counters. Raw hook
arguments, messages, model output, reasoning, and tool results are never handed to the
bridge state machine: a tool result is reduced to Hermes's rough token estimate here, and
the only argument ever read is a successful skill_view call's skill name.
"""
from __future__ import annotations

import json
import logging
import sqlite3
from pathlib import Path
from typing import Any, Callable

from .contract import CHANNEL_LABEL_MAX
from .observer import KnownLane, Observer, Route, timestamp


def _session_value(name: str) -> str:
    try:
        from gateway.session_context import get_session_env

        return str(get_session_env(name, "") or "")
    except Exception:
        return ""


def _conversation_title(home: Path, session_id: str) -> str | None:
    if not session_id:
        return None
    try:
        from hermes_state import SessionDB

        with SessionDB(home / "state.db", read_only=True) as db:
            return db.get_session_title(session_id) or None
    except (OSError, RuntimeError, ValueError, sqlite3.Error):
        return None


def _clean(value: Any) -> str | None:
    """One line of plain text: control characters and runs of whitespace become single spaces."""
    if not isinstance(value, str):
        return None
    text = " ".join("".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in value).split())
    return text[:CHANNEL_LABEL_MAX] or None


def _discord_channels(home: Path) -> dict[str, tuple[str | None, str | None]]:
    """Channel ID → (channel name, guild name) from this profile's read-only gateway channel directory."""
    try:
        entries = json.loads((home / "channel_directory.json").read_text(encoding="utf-8"))["platforms"]["discord"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    return {str(entry.get("id")): (_clean(entry.get("name")), _clean(entry.get("guild")))
            for entry in (entries if isinstance(entries, list) else [])
            if isinstance(entry, dict) and not entry.get("thread_id")}


def _thread_name(chat_name: str, channel: str | None, guild: str | None) -> str:
    """Hermes names a thread `Guild / #channel / thread`; keep the thread only when the prefix is known exactly."""
    prefixes = []
    if channel and guild:
        prefixes += [f"{guild} / #{channel} / ", f"{guild} / {channel} / "]
    if channel:
        prefixes.append(f"{channel} / ")
    for prefix in prefixes:
        if chat_name.startswith(prefix) and chat_name[len(prefix):].strip():
            return chat_name[len(prefix):]
    return chat_name


def _route(profile: str, home: Path) -> Route | None:
    from agent.delegation_context import is_delegated_child_process_context

    if is_delegated_child_process_context():
        return None  # A child borrows its parent's Discord route, not its generation.
    source = {name: _session_value(f"HERMES_SESSION_{name.upper()}")
              for name in ("platform", "chat_id", "thread_id", "parent_chat_id", "chat_name", "scope_id")}
    return _discord_route(profile, source, _discord_channels(home),
                          title=lambda: _conversation_title(home, _session_value("HERMES_SESSION_ID").strip()),
                          session_key=_session_value("HERMES_SESSION_KEY").strip() or None)


def _discord_route(profile: str, source: dict[str, Any], channels: dict[str, tuple[str | None, str | None]], *,
                   title: Callable[[], str | None], session_key: str | None) -> Route | None:
    """A Route from Hermes's session source fields, whether bound to this task or saved in the routing index.

    A thread is named after its Discord thread; an unthreaded lane asks `title` for Hermes's generated title.
    """
    def value(name: str) -> str:
        raw = source.get(name)
        return str(raw).strip() if raw is not None else ""

    platform = value("platform").lower()
    chat_id = value("chat_id")
    if platform != "discord" or not chat_id:
        return None
    thread_id = value("thread_id") or None
    channel_id = value("parent_chat_id") or chat_id
    channel, guild = channels.get(channel_id, (None, None))
    if thread_id:
        raw = value("chat_name")
        chat_name = _clean(_thread_name(raw, channel, guild)) if raw else None
    else:
        chat_name = title()
    return Route(
        profile=profile,
        platform=platform,
        chat_id=chat_id,
        thread_id=thread_id,
        guild_id=value("scope_id") or None,
        channel_id=channel_id,
        display_name=chat_name,
        channel_label=_clean(f"#{channel}") if channel and guild else channel,
        session_key=session_key,
    )


def _session_id(payload: dict[str, Any]) -> str:
    return str(payload.get("session_id") or _session_value("HERMES_SESSION_ID") or "").strip()


def _context_maximum(model: str, provider: str, base_url: str) -> int:
    if not model:
        return 0
    try:
        from providers import get_provider_profile
        from agent.model_metadata import get_cached_context_length

        profile = get_provider_profile(provider)
        known = profile.get_model_context_length(model) if profile else None
        if type(known) is int and known > 0:
            return known
        cached = get_cached_context_length(model, base_url)
        return cached if type(cached) is int and cached > 0 else 0
    except Exception:
        return 0


def _compression_chain(home: Path, session_id: str) -> tuple[str, ...]:
    """Use Hermes's canonical continuation selection, excluding sibling forks."""
    try:
        from hermes_state import SessionDB

        with SessionDB(home / "state.db", read_only=True) as db:
            return tuple(db.get_compression_chain(session_id))
    except (OSError, RuntimeError, ValueError, TypeError, sqlite3.Error) as exc:
        logging.getLogger(__name__).warning("Compression lineage unavailable for %s in %s: %s", session_id, home, exc)
        return ()


def _routing_entries(home: Path) -> list[dict[str, Any]]:
    """The gateway's routing index: one saved session entry per routing key."""
    from hermes_state import SessionDB

    with SessionDB(home / "state.db", read_only=True) as db:
        return [json.loads(row["entry_json"]) for row in db.list_gateway_routing_rows()]


def _route_owner(home: Path, route: Route, session_id: str) -> bool:
    """The gateway's current routing index, not the borrowed task-local session ID."""
    if not route.session_key:
        return False
    try:
        owners = {entry.get("session_id") for entry in _routing_entries(home)
                  if entry.get("session_key") == route.session_key}
        return owners == {session_id}
    except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
        logging.getLogger(__name__).warning("Gateway routing ownership unavailable in %s: %s", home, exc)
        return False


def _known_lanes(routing_home: Path, home: Path, profile: str) -> list[KnownLane]:
    """Discord lanes the gateway already routes for this profile, with Hermes's last prompt size.

    A multiplexed gateway keeps every profile's lanes in one index, so a lane is this profile's
    only when its session lives in this profile's own state database.
    """
    if not ((routing_home / "state.db").is_file() and (home / "state.db").is_file()):
        return []  # No gateway has routed anything yet.
    try:
        from gateway.session import SessionEntry
        from hermes_state import SessionDB

        entries = []
        for raw in _routing_entries(routing_home):
            try:
                entry = SessionEntry.from_dict(raw)
            except (KeyError, TypeError, ValueError):
                continue
            if not entry.expiry_finalized and entry.origin and entry.origin.platform.value == "discord":
                entries.append(entry)
        channels = _discord_channels(home)
        maximums: dict[tuple[str, str, str], int] = {}
        lanes = []
        with SessionDB(home / "state.db", read_only=True) as db:
            for entry in entries:
                session = db.get_session(entry.session_id)
                if session is None:
                    continue  # Another profile's lane.
                route = _discord_route(profile, entry.origin.to_dict(), channels,
                                       title=lambda: session.get("title") or None, session_key=entry.session_key)
                if route is None:
                    continue
                # The latest request's model route, else the session row's (which mixes route changes).
                model_route = db.get_recent_session_model_route(entry.session_id) or session
                key = tuple(str(model_route.get(name) or "") for name in ("model", "billing_provider", "billing_base_url"))
                if key not in maximums:
                    maximums[key] = _context_maximum(*key)
                lanes.append(KnownLane(
                    route, entry.session_id, model=key[0] or None, provider=key[1] or None,
                    used=entry.last_prompt_tokens or None,  # Zero means no request yet.
                    maximum=maximums[key], at=timestamp(entry.updated_at),  # Naive local time.
                ))
        return lanes
    except (OSError, RuntimeError, ValueError, TypeError, sqlite3.Error) as exc:
        logging.getLogger(__name__).warning("Routed lanes unavailable for %s: %s", profile, exc)
        return []


def _estimated_tokens(result: Any) -> int:
    """Hermes's own rough estimate of what the result adds to context; images at its learned per-image price."""
    from agent.model_metadata import estimate_messages_tokens_rough, estimate_tokens_rough

    if isinstance(result, dict) and result.get("_multimodal") is True and isinstance(result.get("content"), list):
        return estimate_messages_tokens_rough([{"role": "tool", "content": result["content"]}])
    return estimate_tokens_rough(result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str))


def _skill_name(tool_name: str, args: Any, status: str) -> str | None:
    """A skill_view call's `name`, only once Hermes resolved it: a failed call's name is whatever the model typed."""
    if tool_name != "skill_view" or status != "ok" or not isinstance(args, dict):
        return None
    name = args.get("name")
    return (name.strip() or None) if isinstance(name, str) else None


def register(ctx) -> None:
    """Register observer-only callbacks on Hermes's supported lifecycle surface."""
    from hermes_constants import get_hermes_home, get_process_hermes_home
    from gateway.status import owns_gateway_runtime_lock

    try:
        from agent.memory_provider import spawn_context_thread
    except Exception:
        spawn_context_thread = None

    thread_factory = spawn_context_thread
    home = Path(get_hermes_home())
    routing_home = Path(get_process_hermes_home())
    observer = Observer(
        home,
        str(ctx.profile_name),
        thread_factory=thread_factory,
        gateway_owner=owns_gateway_runtime_lock,
        compression_chain=lambda session_id: _compression_chain(home, session_id),
        route_owner=lambda route, session_id: _route_owner(routing_home, route, session_id),
    )
    profile = observer.profile

    def pre_gateway_dispatch(**_payload: Any) -> None:
        observer.start_heartbeat()

    def on_session_start(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is None or not session_id:
            return
        observer.start_heartbeat()
        observer.session_started(
            route,
            session_id,
            model=str(payload.get("model") or "") or None,
        )

    def pre_api_request(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is None or not session_id:
            return
        observer.mark_working(
            route,
            session_id,
            model=str(payload.get("model") or "") or None,
            provider=str(payload.get("provider") or "") or None,
            at=payload.get("started_at"),
        )

    def post_api_request(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        request_id = str(payload.get("api_request_id") or "").strip()
        if route is None or not session_id or not request_id:
            return
        ended_at = payload.get("ended_at")
        model = str(payload.get("model") or "")
        provider = str(payload.get("provider") or "")
        usage = payload.get("usage")
        used = usage.get("prompt_tokens") if isinstance(usage, dict) else None
        maximum = _context_maximum(model, provider, str(payload.get("base_url") or ""))
        observer.request_completed(
            route, session_id, request_id=request_id,
            used=used, maximum=maximum, source="provider_reported" if used is not None else None,
            model=model or None, provider=provider or None, at=ended_at,
        )

    def pre_tool_call(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is None or not session_id:
            return
        tool = str(payload.get("tool_name") or "") or None
        if tool == "clarify":
            observer.mark_attention(route, session_id, tool=tool)
        else:
            observer.mark_working(route, session_id, tool=tool)

    def post_tool_call(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is None or not session_id:
            return
        tool_name = str(payload.get("tool_name") or "").strip()
        status = "ok" if payload.get("status") == "ok" else "error"  # blocked, cancelled and timeout failed too
        duration = payload.get("duration_ms")
        observer.tool_call_completed(
            route, session_id, tool_call_id=str(payload.get("tool_call_id") or "").strip(),
            request_id=str(payload.get("api_request_id") or "").strip() or None,
            tool_name=tool_name, skill_name=_skill_name(tool_name, payload.get("args"), status),
            estimated_tokens=_estimated_tokens(payload.get("result")),
            duration_ms=duration if type(duration) is int and duration >= 0 else 0, status=status,
        )

    def pre_approval_request(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is not None and session_id:
            observer.mark_attention(route, session_id, tool=None)

    def post_approval_response(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is not None and session_id:
            observer.mark_working(route, session_id, tool=None)

    def on_session_end(**payload: Any) -> None:
        route = _route(profile, home)
        session_id = _session_id(payload)
        if route is not None and session_id:
            observer.mark_idle(route, session_id)

    def on_session_reset(**payload: Any) -> None:
        from agent.delegation_context import is_delegated_child_process_context
        if is_delegated_child_process_context():
            return
        old_session_id = str(payload.get("old_session_id") or "").strip()
        new_session_id = str(payload.get("new_session_id") or payload.get("session_id") or "").strip()
        if old_session_id and new_session_id:
            observer.session_reset(old_session_id, new_session_id)

    callbacks = {
        "pre_gateway_dispatch": pre_gateway_dispatch,
        "on_session_start": on_session_start,
        "pre_api_request": pre_api_request,
        "post_api_request": post_api_request,
        "pre_tool_call": pre_tool_call,
        "post_tool_call": post_tool_call,
        "pre_approval_request": pre_approval_request,
        "post_approval_response": post_approval_response,
        "on_session_end": on_session_end,
        "on_session_reset": on_session_reset,
    }
    for name, callback in callbacks.items():
        ctx.register_hook(name, callback)
    ctx.on_unload(observer.close)
    observer.backfill(lambda: _known_lanes(routing_home, home, profile))
    observer.start_heartbeat()
