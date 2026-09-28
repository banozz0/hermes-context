"""The plugin's one door into Hermes.

No Hermes release promises the internals below. Every Hermes import and call the plugin makes lives here, so the
dependency surface is this file. An accessor that degrades catches only `ImportError`, `AttributeError` and
`TypeError`, the shapes a moved, renamed or re-signatured internal takes: it falls back, switches off the feature it
serves, logs one warning, and the snapshot's `degraded` list names the feature.
"""
from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

_log = logging.getLogger(__name__)

# Each Hermes internal the plugin reaches, and the features a Hermes without it switches off. Most serve one feature;
# the session database and its routing index are read by several, and each reader switches off its own.
INTERNAL_FEATURES = {
    "gateway.session_context.get_session_env": {"sessions"},
    "hermes_constants.get_hermes_home": {"sessions"},
    "hermes_state.SessionDB": {"titles", "lineage", "backfill"},
    "hermes_state.SessionDB.get_session_title": {"titles"},
    "providers.get_provider_profile": {"context_window"},
    "providers.ProviderProfile.get_model_context_length": {"context_window"},
    "agent.model_metadata.get_cached_context_length": {"context_window"},
    "hermes_state.SessionDB.get_compression_chain": {"lineage"},
    "hermes_constants.get_process_hermes_home": {"lineage", "backfill"},
    "hermes_state.SessionDB.list_gateway_routing_rows": {"lineage", "backfill"},
    "gateway.session.SessionEntry": {"backfill"},
    "hermes_state.SessionDB.get_session": {"backfill"},
    "hermes_state.SessionDB.get_recent_session_model_route": {"backfill"},
    "agent.model_metadata.estimate_tokens_rough": {"tool_history"},
    "agent.model_metadata.estimate_messages_tokens_rough": {"tool_history"},
    "gateway.status.owns_gateway_runtime_lock": {"startup"},
    "agent.memory_provider.spawn_context_thread": {"startup"},
    "agent.delegation_context.is_delegated_child_process_context": {"subagents"},
    "hermes_cli.plugins.VALID_HOOKS": set(),  # Only the hook check reads it; without it the check claims nothing.
}

# Each Hermes hook the plugin registers, and the one feature a Hermes that stopped offering it switches off.
HOOK_FEATURES = {
    "pre_gateway_dispatch": "startup",
    "on_session_start": "sessions",
    "pre_api_request": "sessions",
    "post_api_request": "sessions",
    "on_session_end": "sessions",
    "pre_tool_call": "attention",
    "pre_approval_request": "attention",
    "post_approval_response": "attention",
    "post_tool_call": "tool_history",
    "on_session_reset": "lineage",
}

_CHANGED = (ImportError, AttributeError, TypeError)


@dataclass(frozen=True)
class RoutedSession:
    """One unfinished Discord entry of Hermes's gateway routing index whose session is in this profile's database."""
    session_key: str
    session_id: str
    origin: dict[str, Any]  # Hermes's session source fields.
    title: str | None
    model: str
    provider: str
    base_url: str
    last_prompt_tokens: int
    updated_at: Any  # Hermes's naive local time.


def _default_home() -> Path:
    """Where Hermes keeps its home when nothing overrides it: `HERMES_HOME`, else `~/.hermes`."""
    return Path(os.environ.get("HERMES_HOME", "").strip() or "~/.hermes").expanduser()


class Hermes:
    """One plugin registration's view of Hermes, and the features it has lost so far."""

    def __init__(self) -> None:
        self._lost: set[str] = set()
        self._lock = threading.Lock()
        self._dispatched = False

    def degraded(self) -> list[str]:
        """The lost features, sorted: exactly what the snapshot's `degraded` carries."""
        with self._lock:
            return sorted(self._lost)

    def _lose(self, cause: BaseException | str, *features: str) -> None:
        with self._lock:
            new = [feature for feature in features if feature not in self._lost]
            self._lost.update(new)
        if new:
            _log.warning("Hermes Context switched off %s: this Hermes changed something it reads (%s)", " and ".join(new),
                         cause if isinstance(cause, str) else f"{type(cause).__name__}: {cause}")

    def check(self) -> None:
        """At registration, mark what this Hermes lacks before any hook fires, so the first snapshot says so: the session
        accessor every hook needs, and each hook the plugin registers but Hermes no longer offers."""
        self.session_value("HERMES_SESSION_PLATFORM")
        try:
            from hermes_cli.plugins import VALID_HOOKS

            missing = [hook for hook in HOOK_FEATURES if hook not in VALID_HOOKS]
        except _CHANGED:
            return  # No list to check against, so no claim either way.
        for hook in missing:
            self._lose(f"no {hook} hook", HOOK_FEATURES[hook])

    def profile_home(self) -> Path:
        try:
            from hermes_constants import get_hermes_home

            return Path(get_hermes_home())
        except _CHANGED as exc:
            self._lose(exc, "sessions")
            return _default_home()

    def routing_home(self) -> Path:
        """The process home, whose state database holds a multiplexed gateway's routing index.

        Without Hermes's lookup, its own rule for the process home, never the profile home: a served profile's home
        holds none of the index.
        """
        try:
            from hermes_constants import get_process_hermes_home

            return Path(get_process_hermes_home())
        except _CHANGED as exc:
            self._lose(exc, "lineage", "backfill")
            return _default_home()

    def gateway_dispatched(self) -> None:
        """A gateway dispatched a message to this process: without Hermes's lock check, it now owns the gateway."""
        self._dispatched = True

    def owns_gateway(self) -> bool:
        """Whether this process owns the gateway runtime lock; without Hermes's check, whether a gateway dispatched here."""
        try:
            from gateway.status import owns_gateway_runtime_lock

            return bool(owns_gateway_runtime_lock())
        except _CHANGED as exc:
            self._lose(exc, "startup")
            return self._dispatched

    def thread_factory(self) -> Callable[..., threading.Thread]:
        """Hermes's context-preserving thread starter, else a plain thread."""
        try:
            from agent.memory_provider import spawn_context_thread
        except _CHANGED as exc:
            self._lose(exc, "startup")
            return threading.Thread

        def spawn(target: Callable[[], None], *, name: str, daemon: bool) -> threading.Thread:
            try:
                return spawn_context_thread(target, name=name, daemon=daemon)
            except _CHANGED as exc:
                self._lose(exc, "startup")
                return threading.Thread(target=target, name=name, daemon=daemon)
        return spawn

    def session_value(self, name: str) -> str:
        """One field of the session source Hermes bound to this task, else empty."""
        try:
            from gateway.session_context import get_session_env

            return str(get_session_env(name, "") or "")
        except _CHANGED as exc:
            self._lose(exc, "sessions")
            return ""
        except Exception:
            return ""

    def delegated_child(self) -> bool:
        """Whether a delegated subagent runs this task; without Hermes's check, False, and lane admission alone keeps a
        child's requests off its parent's lane."""
        try:
            from agent.delegation_context import is_delegated_child_process_context

            return bool(is_delegated_child_process_context())
        except _CHANGED as exc:
            self._lose(exc, "subagents")
            return False

    def conversation_title(self, home: Path, session_id: str) -> str | None:
        """Hermes's generated title for a session; None when it has none or this Hermes lost the lookup."""
        if not session_id:
            return None
        try:
            from hermes_state import SessionDB

            with SessionDB(home / "state.db", read_only=True) as db:
                return db.get_session_title(session_id) or None
        except _CHANGED as exc:
            self._lose(exc, "titles")
            return None
        except (OSError, RuntimeError, ValueError, sqlite3.Error):
            return None

    def context_maximum(self, model: str, provider: str, base_url: str) -> int:
        """The model's context window in tokens, else 0."""
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
        except _CHANGED as exc:
            self._lose(exc, "context_window")
            return 0
        except Exception:
            return 0

    def compression_chain(self, home: Path, session_id: str) -> tuple[str, ...]:
        """Hermes's canonical continuation selection, excluding sibling forks."""
        try:
            from hermes_state import SessionDB

            with SessionDB(home / "state.db", read_only=True) as db:
                return tuple(db.get_compression_chain(session_id))
        except _CHANGED as exc:
            self._lose(exc, "lineage")
            return ()
        except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
            _log.warning("Compression lineage unavailable for %s in %s: %s", session_id, home, exc)
            return ()

    def _routing_entries(self, home: Path) -> list[dict[str, Any]]:
        """The gateway's routing index: one saved session entry per routing key."""
        from hermes_state import SessionDB

        with SessionDB(home / "state.db", read_only=True) as db:
            return [json.loads(row["entry_json"]) for row in db.list_gateway_routing_rows()]

    def route_owned(self, home: Path, session_key: str, session_id: str) -> bool:
        """Whether the routing index gives `session_key` to `session_id` alone.

        A Hermes that lost the index leaves only the task's own session to trust, so it owns the lane.
        """
        try:
            return {entry.get("session_id") for entry in self._routing_entries(home)
                    if entry.get("session_key") == session_key} == {session_id}
        except _CHANGED as exc:
            self._lose(exc, "lineage")
            return True
        except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
            _log.warning("Gateway routing ownership unavailable in %s: %s", home, exc)
            return False

    def routed_sessions(self, routing_home: Path, home: Path) -> list[RoutedSession]:
        """The routing index's Discord sessions that live in this profile's own state database.

        A multiplexed gateway keeps every profile's lanes in one index, so an entry whose session is missing from
        `home`'s database is another profile's.
        """
        if not ((routing_home / "state.db").is_file() and (home / "state.db").is_file()):
            return []  # No gateway has routed anything yet.
        try:
            from gateway.session import SessionEntry
            from hermes_state import SessionDB

            entries = []
            for raw in self._routing_entries(routing_home):
                try:
                    entry = SessionEntry.from_dict(raw)
                except (KeyError, TypeError, ValueError):
                    continue
                if not entry.expiry_finalized and entry.origin and entry.origin.platform.value == "discord":
                    entries.append(entry)
            routed = []
            with SessionDB(home / "state.db", read_only=True) as db:
                for entry in entries:
                    session = db.get_session(entry.session_id)
                    if session is None:
                        continue
                    # The latest request's model route, else the session row's (which mixes route changes).
                    model_route = db.get_recent_session_model_route(entry.session_id) or session
                    model, provider, base_url = (str(model_route.get(name) or "")
                                                 for name in ("model", "billing_provider", "billing_base_url"))
                    routed.append(RoutedSession(
                        entry.session_key, entry.session_id, entry.origin.to_dict(), session.get("title") or None,
                        model, provider, base_url, entry.last_prompt_tokens, entry.updated_at,
                    ))
            return routed
        except _CHANGED as exc:
            self._lose(exc, "backfill")
            return []

    def estimated_tokens(self, result: Any) -> int | None:
        """Hermes's own rough estimate of what the result adds to context, images at its learned per-image price; None
        when this Hermes lost its estimator."""
        try:
            from agent.model_metadata import estimate_messages_tokens_rough, estimate_tokens_rough

            if isinstance(result, dict) and result.get("_multimodal") is True and isinstance(result.get("content"), list):
                return estimate_messages_tokens_rough([{"role": "tool", "content": result["content"]}])
            return estimate_tokens_rough(result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str))
        except _CHANGED as exc:
            self._lose(exc, "tool_history")
            return None
