"""Hermes Context observer plugin.

The callbacks deliberately read only routing metadata and lifecycle counters. Raw hook
arguments, messages, model output, reasoning, and tool results are never handed to the
bridge state machine: a tool result is reduced to Hermes's rough token estimate here, and
the only argument ever read is a successful skill_view call's skill name.
"""
from __future__ import annotations

import functools
import json
import logging
import sqlite3
from pathlib import Path
from typing import Any, Callable

from .compat import Hermes
from .contract import CHANNEL_LABEL_MAX
from .observer import KnownLane, Observer, Route, timestamp

_log = logging.getLogger(__name__)


def _clean(value: Any) -> str | None:
    """One line of plain text: control characters and runs of whitespace become single spaces."""
    if not isinstance(value, str):
        return None
    text = " ".join("".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in value).split())
    return text[:CHANNEL_LABEL_MAX] or None


def _discord_channels(home: Path) -> dict[str, tuple[str | None, str | None]]:
    """Channel ID → (channel name, guild name) from this profile's read-only gateway channel directory.

    Hermes may list a channel twice, once as a guild-less group named after its session; the guild entry wins.
    """
    try:
        entries = json.loads((home / "channel_directory.json").read_text(encoding="utf-8"))["platforms"]["discord"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    channels: dict[str, tuple[str | None, str | None]] = {}
    for entry in (entries if isinstance(entries, list) else []):
        if isinstance(entry, dict) and not entry.get("thread_id"):
            channel_id, guild = str(entry.get("id")), _clean(entry.get("guild"))
            if guild or channel_id not in channels:
                channels[channel_id] = (_clean(entry.get("name")), guild)
    return channels


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


def _route(hermes: Hermes, profile: str, home: Path) -> Route | None:
    if hermes.delegated_child():
        return None  # A child borrows its parent's Discord route, not its generation.
    source = {name: hermes.session_value(f"HERMES_SESSION_{name.upper()}")
              for name in ("platform", "chat_id", "thread_id", "parent_chat_id", "chat_name", "scope_id")}
    return _discord_route(profile, source, _discord_channels(home),
                          title=lambda: hermes.conversation_title(home, hermes.session_value("HERMES_SESSION_ID").strip()),
                          session_key=hermes.session_value("HERMES_SESSION_KEY").strip() or None)


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


def _session_id(hermes: Hermes, payload: dict[str, Any]) -> str:
    return str(payload.get("session_id") or hermes.session_value("HERMES_SESSION_ID") or "").strip()


def _known_lanes(hermes: Hermes, routing_home: Path, home: Path, profile: str) -> list[KnownLane]:
    """Discord lanes the gateway already routes for this profile, with Hermes's last prompt size."""
    try:
        channels = _discord_channels(home)
        maximum = functools.cache(hermes.context_maximum)
        lanes = []
        for routed in hermes.routed_sessions(routing_home, home):
            route = _discord_route(profile, routed.origin, channels,
                                   title=lambda: routed.title, session_key=routed.session_key)
            if route is None:
                continue
            lanes.append(KnownLane(
                route, routed.session_id, model=routed.model or None, provider=routed.provider or None,
                used=routed.last_prompt_tokens or None,  # Zero means no request yet.
                maximum=maximum(routed.model, routed.provider, routed.base_url),
                at=timestamp(routed.updated_at),  # Naive local time.
            ))
        return lanes
    except (OSError, RuntimeError, ValueError, TypeError, sqlite3.Error) as exc:
        _log.warning("Routed lanes unavailable for %s: %s", profile, exc)
        return []


def _skill_name(tool_name: str, args: Any, status: str) -> str | None:
    """A skill_view call's `name`, only once Hermes resolved it: a failed call's name is whatever the model typed."""
    if tool_name != "skill_view" or status != "ok" or not isinstance(args, dict):
        return None
    name = args.get("name")
    return (name.strip() or None) if isinstance(name, str) else None


def _guarded(hook: str, callback: Callable[..., None]) -> Callable[..., None]:
    """The callback, unable to throw into the Hermes turn that fired it; its first failure is logged."""
    failed = False

    @functools.wraps(callback)
    def guarded(**payload: Any) -> None:
        nonlocal failed
        try:
            callback(**payload)
        except Exception:
            if not failed:
                failed = True
                _log.warning("Hermes Context's %s hook failed; Hermes carries on without it", hook, exc_info=True)
    return guarded


def register(ctx) -> None:
    """Register observer-only callbacks on Hermes's supported lifecycle surface.

    Never throws: a Hermes change may cost features, never the plugin's place in Hermes.
    """
    try:
        _register(ctx)
    except Exception:
        _log.warning("Hermes Context could not register; this Hermes process goes unobserved", exc_info=True)


def _register(ctx) -> None:
    hermes = Hermes()
    hermes.check()
    home = hermes.profile_home()
    routing_home = hermes.routing_home()
    profile = str(ctx.profile_name)
    observer = Observer(
        home,
        profile,
        thread_factory=hermes.thread_factory(),
        gateway_owner=hermes.owns_gateway,
        compression_chain=lambda session_id: hermes.compression_chain(home, session_id),
        # The gateway's current routing index, not the borrowed task-local session ID.
        route_owner=lambda route, session_id: bool(route.session_key) and hermes.route_owned(
            routing_home, route.session_key, session_id),
        known_lanes=lambda: _known_lanes(hermes, routing_home, home, profile),
        degraded=hermes.degraded,
    )

    def pre_gateway_dispatch(**_payload: Any) -> None:
        hermes.gateway_dispatched()
        observer.start_heartbeat()

    def on_session_start(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is None or not session_id:
            return
        observer.start_heartbeat()
        observer.session_started(
            route,
            session_id,
            model=str(payload.get("model") or "") or None,
        )

    def pre_api_request(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
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
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        request_id = str(payload.get("api_request_id") or "").strip()
        if route is None or not session_id or not request_id:
            return
        ended_at = payload.get("ended_at")
        model = str(payload.get("model") or "")
        provider = str(payload.get("provider") or "")
        usage = payload.get("usage")
        used = usage.get("prompt_tokens") if isinstance(usage, dict) else None
        maximum = hermes.context_maximum(model, provider, str(payload.get("base_url") or ""))
        observer.request_completed(
            route, session_id, request_id=request_id,
            used=used, maximum=maximum, source="provider_reported" if used is not None else None,
            model=model or None, provider=provider or None, at=ended_at,
        )

    def pre_tool_call(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is None or not session_id:
            return
        tool = str(payload.get("tool_name") or "") or None
        if tool == "clarify":
            observer.mark_attention(route, session_id, tool=tool)
        else:
            observer.mark_working(route, session_id, tool=tool)

    def post_tool_call(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is None or not session_id:
            return
        tool_name = str(payload.get("tool_name") or "").strip()
        status = "ok" if payload.get("status") == "ok" else "error"  # blocked, cancelled and timeout failed too
        duration = payload.get("duration_ms")
        observer.tool_call_completed(
            route, session_id, tool_call_id=str(payload.get("tool_call_id") or "").strip(),
            request_id=str(payload.get("api_request_id") or "").strip() or None,
            tool_name=tool_name, skill_name=_skill_name(tool_name, payload.get("args"), status),
            estimated_tokens=hermes.estimated_tokens(payload.get("result")),
            duration_ms=duration if type(duration) is int and duration >= 0 else 0, status=status,
        )

    def pre_approval_request(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is not None and session_id:
            observer.mark_attention(route, session_id, tool=None)

    def post_approval_response(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is not None and session_id:
            observer.mark_working(route, session_id, tool=None)

    def on_session_end(**payload: Any) -> None:
        route = _route(hermes, profile, home)
        session_id = _session_id(hermes, payload)
        if route is not None and session_id:
            observer.mark_idle(route, session_id)

    def on_session_reset(**payload: Any) -> None:
        if hermes.delegated_child():
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
        ctx.register_hook(name, _guarded(name, callback))
    ctx.on_unload(observer.close)
    observer.start_heartbeat()
