"""The plugin's one door into Hermes.

No Hermes release promises the internals below. Every Hermes import and call the plugin makes lives here, so the
dependency surface is this file. An accessor that degrades catches only `ImportError`, `AttributeError` and
`TypeError`, the shapes a moved, renamed or re-signatured internal takes: it switches off its one feature, logs one
warning, and the snapshot's `degraded` list names the feature.
"""
from __future__ import annotations

import json
import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

_log = logging.getLogger(__name__)

# Each Hermes internal the plugin reaches, and the one feature a Hermes without it switches off. `SessionDB` itself
# (its import and read-only constructor) serves titles, lineage and backfill; each accessor marks its own feature.
INTERNAL_FEATURES = {
    "gateway.session_context.get_session_env": "sessions",
    "hermes_constants.get_hermes_home": "sessions",
    "hermes_state.SessionDB.get_session_title": "titles",
    "providers.get_provider_profile": "context_window",
    "providers.ProviderProfile.get_model_context_length": "context_window",
    "agent.model_metadata.get_cached_context_length": "context_window",
    "hermes_state.SessionDB.get_compression_chain": "lineage",
    "hermes_constants.get_process_hermes_home": "lineage",
    "hermes_state.SessionDB.list_gateway_routing_rows": "backfill",  # Route ownership (lineage) reads it too.
    "gateway.session.SessionEntry": "backfill",
    "hermes_state.SessionDB.get_session": "backfill",
    "hermes_state.SessionDB.get_recent_session_model_route": "backfill",
    "agent.model_metadata.estimate_tokens_rough": "tool_history",
    "agent.model_metadata.estimate_messages_tokens_rough": "tool_history",
    "gateway.status.owns_gateway_runtime_lock": "startup",
    "agent.memory_provider.spawn_context_thread": "startup",
    "agent.delegation_context.is_delegated_child_process_context": "subagents",
}

# Each Hermes hook the plugin registers, and the one feature a Hermes that stopped firing it switches off.
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


class Hermes:
    """One plugin registration's view of Hermes, and the features it has lost so far."""

    def __init__(self) -> None:
        self._lost: set[str] = set()
        self._lock = threading.Lock()

    def degraded(self) -> list[str]:
        """The lost features, sorted: exactly what the snapshot's `degraded` carries."""
        with self._lock:
            return sorted(self._lost)

    def _lose(self, feature: str, error: BaseException) -> None:
        with self._lock:
            if feature in self._lost:
                return
            self._lost.add(feature)
        _log.warning("Hermes Context switched off %s: this Hermes changed an internal it reads (%s: %s)",
                     feature, type(error).__name__, error)

    def profile_home(self) -> Path:
        from hermes_constants import get_hermes_home

        return Path(get_hermes_home())

    def routing_home(self) -> Path:
        """The process home, whose state database holds a multiplexed gateway's routing index."""
        from hermes_constants import get_process_hermes_home

        return Path(get_process_hermes_home())

    def gateway_owner(self) -> Callable[[], bool]:
        from gateway.status import owns_gateway_runtime_lock

        return owns_gateway_runtime_lock

    def thread_factory(self) -> Callable[..., threading.Thread] | None:
        """Hermes's context-preserving thread starter, else None for a plain thread."""
        try:
            from agent.memory_provider import spawn_context_thread
        except Exception:
            return None
        return spawn_context_thread

    def session_value(self, name: str) -> str:
        """One field of the session source Hermes bound to this task, else empty."""
        try:
            from gateway.session_context import get_session_env

            return str(get_session_env(name, "") or "")
        except Exception:
            return ""

    def delegated_child(self) -> bool:
        from agent.delegation_context import is_delegated_child_process_context

        return is_delegated_child_process_context()

    def conversation_title(self, home: Path, session_id: str) -> str | None:
        """Hermes's generated title for a session; None when it has none or this Hermes lost the lookup."""
        if not session_id:
            return None
        try:
            from hermes_state import SessionDB

            with SessionDB(home / "state.db", read_only=True) as db:
                return db.get_session_title(session_id) or None
        except _CHANGED as exc:
            self._lose("titles", exc)
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
        except Exception:
            return 0

    def compression_chain(self, home: Path, session_id: str) -> tuple[str, ...]:
        """Hermes's canonical continuation selection, excluding sibling forks."""
        try:
            from hermes_state import SessionDB

            with SessionDB(home / "state.db", read_only=True) as db:
                return tuple(db.get_compression_chain(session_id))
        except (OSError, RuntimeError, ValueError, TypeError, sqlite3.Error) as exc:
            _log.warning("Compression lineage unavailable for %s in %s: %s", session_id, home, exc)
            return ()

    def routing_entries(self, home: Path) -> list[dict[str, Any]]:
        """The gateway's routing index: one saved session entry per routing key."""
        from hermes_state import SessionDB

        with SessionDB(home / "state.db", read_only=True) as db:
            return [json.loads(row["entry_json"]) for row in db.list_gateway_routing_rows()]

    def routed_sessions(self, routing_home: Path, home: Path) -> list[RoutedSession]:
        """The routing index's Discord sessions that live in this profile's own state database.

        A multiplexed gateway keeps every profile's lanes in one index, so an entry whose session is missing from
        `home`'s database is another profile's.
        """
        if not ((routing_home / "state.db").is_file() and (home / "state.db").is_file()):
            return []  # No gateway has routed anything yet.
        from gateway.session import SessionEntry
        from hermes_state import SessionDB

        entries = []
        for raw in self.routing_entries(routing_home):
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

    def estimated_tokens(self, result: Any) -> int:
        """Hermes's own rough estimate of what the result adds to context; images at its learned per-image price."""
        from agent.model_metadata import estimate_messages_tokens_rough, estimate_tokens_rough

        if isinstance(result, dict) and result.get("_multimodal") is True and isinstance(result.get("content"), list):
            return estimate_messages_tokens_rough([{"role": "tool", "content": result["content"]}])
        return estimate_tokens_rough(result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str))
