from __future__ import annotations

import hashlib
import fcntl
import json
import os
import threading
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

from .contract import CONTRACT_VERSION, effective_freshness, validate_snapshot
from .events import EventStore

OWNER_POLL_SECONDS = 1.0  # How soon a registered observer notices its gateway claimed the runtime lock.


def timestamp(value: str | float | datetime | None = None) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        moment = datetime.now(timezone.utc)
    elif isinstance(value, datetime):
        moment = value.astimezone(timezone.utc)
    else:
        moment = datetime.fromtimestamp(float(value), tz=timezone.utc)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def v1_identity(*parts: str) -> str:
    """`hc1:` plus SHA-256 of the parts as compact UTF-8 JSON; the raw IDs are never written."""
    text = json.dumps(list(parts), ensure_ascii=False, separators=(",", ":"))
    return f"hc1:{hashlib.sha256(text.encode('utf-8')).hexdigest()}"


def request_identity(profile: str, session_id: str, request_id: str) -> str:
    return v1_identity(profile, session_id, request_id)


@dataclass(frozen=True)
class Route:
    profile: str
    platform: str
    chat_id: str
    thread_id: str | None = None
    guild_id: str | None = None
    channel_id: str | None = None
    display_name: str | None = None
    channel_label: str | None = None
    session_key: str | None = None  # Gateway ownership proof; never serialized.

    @property
    def discord_route(self) -> dict[str, str | None]:
        return {
            "guild_id": self.guild_id,
            "channel_id": self.channel_id or self.chat_id,
            "thread_id": self.thread_id,
            "channel_label": self.channel_label,
        }

    @property
    def routing_id(self) -> str:
        return v1_identity(self.profile, self.platform, self.chat_id, self.thread_id or "")

    @property
    def name(self) -> str:
        return self.display_name or f"{self.profile} {self.platform} session"


@dataclass(frozen=True)
class KnownLane:
    """A lane the gateway already routes, with Hermes's last provider-reported prompt size."""
    route: Route
    session_id: str
    model: str | None
    provider: str | None
    used: int | None
    maximum: int
    at: str


class SnapshotStore:
    """Atomic replace-only writer; a stable lock serializes same-home writers."""

    def __init__(self, hermes_home: Path):
        self.directory = Path(hermes_home) / "hermes-context" / "v1"
        self.path = self.directory / "snapshot.json"

    @contextmanager
    def locked(self) -> Iterator[None]:
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self.directory / "snapshot.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def write(self, snapshot: dict[str, Any]) -> None:
        validate_snapshot(snapshot)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        body = (json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        temporary = self.directory / f".{self.path.name}.{os.getpid()}.{threading.get_ident()}.{uuid.uuid4().hex}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            try:
                directory_fd = os.open(self.directory, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError:
                pass
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


class Observer:
    """Thread-safe state machine producing one current row per routing lane."""

    def __init__(
        self,
        hermes_home: Path,
        profile: str,
        *,
        offline_after_seconds: int = 45,
        heartbeat_interval_seconds: float = 15.0,
        thread_factory: Callable[..., threading.Thread] | None = None,
        gateway_owner: Callable[[], bool] | None = None,
        events_per_segment: int = 1000,
        compression_chain: Callable[[str], tuple[str, ...]] | None = None,
        route_owner: Callable[[Route, str], bool] | None = None,
        known_lanes: Callable[[], list[KnownLane]] | None = None,
    ):
        self.profile = profile
        self.offline_after_seconds = int(offline_after_seconds)
        self.heartbeat_interval_seconds = float(heartbeat_interval_seconds)
        self.store = SnapshotStore(Path(hermes_home))
        self.events = EventStore(self.store.directory, per_segment=events_per_segment)
        self._compression_chain = compression_chain or (lambda _session_id: ())
        self._route_owner = route_owner or (lambda _route, _session_id: False)
        self._known_lanes = known_lanes or (lambda: [])
        self._gateway_owner = gateway_owner or (lambda: True)
        self._lanes: dict[str, dict[str, Any]] = {}
        self._recovery_heartbeat: str | None = None
        self._restore_snapshot()
        self._lock = threading.RLock()
        self._heartbeat_at: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._thread_factory = thread_factory or threading.Thread

    def _restore_snapshot(self) -> None:
        saved = self._read_snapshot()
        if saved is None:
            return
        self._load_lanes(saved)
        if effective_freshness(saved, at=datetime.now(timezone.utc)) == "live":
            return  # Another instance still owns live work in this home.
        if not self._gateway_owner():
            return
        self._recovery_heartbeat = saved["gateway"]["heartbeat_at"]
        for row in self._lanes.values():
            row["state"] = "idle"  # In-flight work cannot survive a stale gateway.
            row["current_tool"] = None
            row["timing"]["turn_started_at"] = None

    def _read_snapshot(self) -> dict[str, Any] | None:
        try:
            saved = json.loads(self.store.path.read_text(encoding="utf-8"))
            validate_snapshot(saved)
            if saved["profile"] != self.profile:
                raise ValueError("Snapshot profile does not match this observer")
            return saved
        except FileNotFoundError:
            return None

    def _load_lanes(self, snapshot: dict[str, Any]) -> None:
        self._lanes = {row["routing_id"]: row for row in snapshot["sessions"]}

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        with self._lock, self.store.locked():
            # Read under the same stable lock used by other processes; never
            # publish cached lanes over a newer snapshot.
            saved = self._read_snapshot()
            if saved is not None:
                self._load_lanes(saved)
                self._heartbeat_at = saved["gateway"]["heartbeat_at"]
                if saved["gateway"]["heartbeat_at"] == self._recovery_heartbeat:
                    # Until a write lands, every transaction repeats the reset: one that publishes
                    # nothing must not let stale in-flight rows back out under a fresh heartbeat.
                    for row in self._lanes.values():
                        row["state"] = "idle"
                        row["current_tool"] = None
                        row["timing"]["turn_started_at"] = None
            yield

    def _empty_context(self) -> dict[str, Any]:
        return {"used": None, "maximum": None, "percentage": None, "source": None, "measured_at": None}

    def _provider_context(self, used: int | None, maximum: int | None, source: str | None,
                          moment: str) -> dict[str, Any]:
        if type(used) is int and used >= 0 and type(maximum) is int and maximum > 0 and source:
            return {"used": used, "maximum": maximum, "percentage": min(100.0, round(used / maximum * 100, 6)),
                    "source": source, "measured_at": moment}
        return self._empty_context()

    def _new_row(
        self,
        route: Route,
        session_id: str,
        *,
        model: str | None,
        provider: str | None,
        at: str,
        previous_session_id: str | None = None,
        lineage_root_id: str | None = None,
        state: str = "working",
    ) -> dict[str, Any]:
        return {
            "routing_id": route.routing_id,
            "profile": route.profile,
            "platform": route.platform,
            "session_id": session_id,
            "lineage_root_id": lineage_root_id or session_id,
            "previous_session_id": previous_session_id,
            "discord_route": route.discord_route,
            "display_name": route.name,
            "state": state,
            "model": model,
            "provider": provider,
            "context": self._empty_context(),
            "current_tool": None,
            "timing": {
                "turn_started_at": at if state == "working" else None,
                "last_activity_at": at,
            },
        }

    def _ensure_row(
        self,
        route: Route,
        session_id: str,
        *,
        at: str,
        model: str | None = None,
        provider: str | None = None,
    ) -> dict[str, Any] | None:
        row = self._lanes.get(route.routing_id)
        if row is None:
            if route.session_key and not self._route_owner(route, session_id):
                return None
            row = self._new_row(route, session_id, model=model, provider=provider, at=at)
            self._lanes[route.routing_id] = row
        elif row["session_id"] != session_id:
            chain = self._compression_chain(row["session_id"])
            successors = chain[1:chain.index(session_id) + 1] if (
                chain and chain[0] == row["session_id"] and session_id in chain[1:]
            ) else ()
            if not successors and not self._route_owner(route, session_id):
                return None
            for successor in successors or (session_id,):
                self.events.remember_generation(row)
                known = self.events.generation(route.routing_id, successor)
                row = self._new_row(route, successor, model=model, provider=provider, at=at,
                                    previous_session_id=known["previous_session_id"] if known else row["session_id"],
                                    lineage_root_id=known["lineage_root_id"] if known else row["lineage_root_id"])
                self._lanes[route.routing_id] = row
        else:
            if model:
                row["model"] = model
            if provider:
                row["provider"] = provider
            row["display_name"] = route.name
            row["discord_route"] = route.discord_route
        return row

    def _current_row(
        self,
        route: Route,
        session_id: str,
        *,
        at: str,
        model: str | None = None,
        provider: str | None = None,
    ) -> dict[str, Any] | None:
        return self._ensure_row(route, session_id, at=at, model=model, provider=provider)

    def _publish(self, at: str) -> None:
        if self._gateway_owner():
            self._heartbeat_at = at
        elif self._heartbeat_at is None:
            return  # No gateway has published yet; CLI must not invent its heartbeat.
        snapshot = {
            "contract_version": CONTRACT_VERSION,
            "profile": self.profile,
            "generated_at": at,
            "freshness": "live",
            "gateway": {
                "heartbeat_at": self._heartbeat_at,
                "offline_after_seconds": self.offline_after_seconds,
            },
            "sessions": [self._lanes[key] for key in sorted(self._lanes)],
        }
        self.store.write(snapshot)
        self._recovery_heartbeat = None

    def heartbeat(self, at: str | float | datetime | None = None) -> None:
        if not self._gateway_owner():
            return
        moment = timestamp(at)
        with self._transaction():
            if self._gateway_owner():
                self._publish(moment)

    def session_started(
        self,
        route: Route,
        session_id: str,
        *,
        model: str | None = None,
        provider: str | None = None,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            row = self._ensure_row(route, session_id, at=moment, model=model, provider=provider)
            if row is None:
                return
            row["state"] = "working"
            row["current_tool"] = None
            row["timing"]["turn_started_at"] = moment
            row["timing"]["last_activity_at"] = moment
            self._publish(moment)

    def session_reset(
        self,
        old_session_id: str,
        new_session_id: str,
        *,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            for routing_id, current in list(self._lanes.items()):
                if current["session_id"] != old_session_id:
                    continue
                if old_session_id == new_session_id:
                    return
                self.events.remember_generation(current)
                replacement = dict(current)
                replacement["session_id"] = new_session_id
                replacement["previous_session_id"] = old_session_id
                replacement["state"] = "idle"
                replacement["context"] = self._empty_context()
                replacement["current_tool"] = None
                replacement["timing"] = {"turn_started_at": None, "last_activity_at": moment}
                self._lanes[routing_id] = replacement
                self._publish(moment)
                return

    def mark_working(
        self,
        route: Route,
        session_id: str,
        *,
        tool: str | None = None,
        model: str | None = None,
        provider: str | None = None,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            row = self._current_row(route, session_id, at=moment, model=model, provider=provider)
            if row is not None:
                self._working(row, tool, moment)

    def _working(self, row: dict[str, Any], tool: str | None, moment: str) -> None:
        row["state"] = "working"
        row["current_tool"] = tool
        row["timing"]["turn_started_at"] = row["timing"]["turn_started_at"] or moment
        row["timing"]["last_activity_at"] = moment
        self._publish(moment)

    def mark_attention(
        self,
        route: Route,
        session_id: str,
        *,
        tool: str | None = None,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            row = self._current_row(route, session_id, at=moment)
            if row is None:
                return
            row["state"] = "needs_attention"
            row["current_tool"] = tool
            row["timing"]["last_activity_at"] = moment
            self._publish(moment)

    def mark_idle(
        self,
        route: Route,
        session_id: str,
        *,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            row = self._current_row(route, session_id, at=moment)
            if row is None:
                return
            row["state"] = "idle"
            row["current_tool"] = None
            row["timing"]["turn_started_at"] = None
            row["timing"]["last_activity_at"] = moment
            self._publish(moment)

    def context_measured(
        self,
        route: Route,
        session_id: str,
        *,
        used: int,
        maximum: int,
        source: str,
        at: str | float | datetime | None = None,
    ) -> None:
        moment = timestamp(at)
        with self._transaction():
            row = self._current_row(route, session_id, at=moment)
            if row is None:
                return
            row["context"] = {
                "used": int(used),
                "maximum": int(maximum),
                "percentage": round((int(used) / int(maximum)) * 100, 6) if maximum else 0.0,
                "source": source,
                "measured_at": moment,
            }
            row["timing"]["last_activity_at"] = moment
            self._publish(moment)

    def request_completed(
        self,
        route: Route,
        session_id: str,
        *,
        request_id: str,
        used: int | None,
        maximum: int | None,
        source: str | None,
        model: str | None,
        provider: str | None,
        at: str | float | datetime | None = None,
    ) -> None:
        """Record one completed request; request identity survives observer restarts."""
        if not request_id or not session_id or route.profile != self.profile:
            return
        moment = timestamp(at)
        with self._transaction():
            row = self._owning_row(route, session_id, at=moment, model=model, provider=provider)
            if row is None:
                return
            context = self._provider_context(used, maximum, source, moment)
            event = self._event(
                "model_request", request_identity(route.profile, session_id, request_id), route, row, session_id, moment,
                model=model or row["model"], provider=provider or row["provider"], state="working", context=context,
            )
            if not self.events.append(event):
                return
            if row is self._lanes[route.routing_id]:
                row["model"], row["provider"] = event["model"], event["provider"]
                row["context"] = context
                row["state"] = "working"
                row["timing"]["last_activity_at"] = moment
                self._publish(moment)

    def tool_call_completed(
        self,
        route: Route,
        session_id: str,
        *,
        tool_call_id: str,
        request_id: str | None,
        tool_name: str,
        skill_name: str | None,
        estimated_tokens: int,
        duration_ms: int,
        status: str,
        at: str | float | datetime | None = None,
    ) -> None:
        """Record one completed tool call like a request, and clear its lane's current tool in the same transaction."""
        if not session_id or route.profile != self.profile:
            return
        moment = timestamp(at)
        with self._transaction():
            row = self._owning_row(route, session_id, at=moment)
            if row is None:
                return
            if tool_call_id and tool_name:
                # Hermes makes tool_call_ids unique only within one model response, so the issuing request is part
                # of the identity; the "tool_call" tag keeps it apart from every request identity.
                event_id = v1_identity("tool_call", route.profile, session_id, request_id or "", tool_call_id)
                self.events.append(self._event(
                    "tool_call", event_id, route, row, session_id, moment,
                    request_event_id=request_identity(route.profile, session_id, request_id) if request_id else None,
                    tool_name=tool_name, skill_name=skill_name, estimated_tokens=estimated_tokens,
                    duration_ms=duration_ms, status=status,
                ))
            if row is self._lanes.get(route.routing_id):
                self._working(row, None, moment)

    def _event(self, kind: str, event_id: str, route: Route, row: dict[str, Any], session_id: str, moment: str,
               **fields: Any) -> dict[str, Any]:
        return {
            "contract_version": CONTRACT_VERSION,
            "kind": kind,
            "event_id": event_id,
            "sequence": 0,  # Allocated under the shared lock by EventStore.
            "routing_id": route.routing_id,
            "lineage_root_id": row["lineage_root_id"],
            "previous_session_id": row["previous_session_id"],
            "session_id": session_id,
            "timestamp": moment,
            "profile": self.profile,
            **fields,
        }

    def _owning_row(self, route: Route, session_id: str, *, at: str, model: str | None = None,
                    provider: str | None = None) -> dict[str, Any] | None:
        """The lane's current generation, else an ended generation this lane recorded; unknown IDs get nothing."""
        row = self._ensure_row(route, session_id, at=at, model=model, provider=provider)
        return row if row is not None else self.events.generation(route.routing_id, session_id)

    def backfill(self, known_lanes: Callable[[], list[KnownLane]]) -> None:
        """Add a row for each lane the gateway already routes, so a fresh install lists it before its next request.

        Rows already held win. Only the gateway owner reads the lanes; no event is written, since no request ran.
        """
        if not self._gateway_owner():
            return
        lanes = known_lanes()
        if not lanes:
            return
        with self._transaction():
            added = False
            for lane in lanes:
                route = lane.route
                if route.profile != self.profile or route.routing_id in self._lanes:
                    continue
                known = self.events.generation(route.routing_id, lane.session_id) or {}
                row = self._new_row(route, lane.session_id, model=lane.model, provider=lane.provider, at=lane.at,
                                    previous_session_id=known.get("previous_session_id"),
                                    lineage_root_id=known.get("lineage_root_id"), state="idle")
                row["context"] = self._provider_context(lane.used, lane.maximum, "provider_reported", lane.at)
                self._lanes[route.routing_id] = row
                added = True
            if added:
                self._publish(timestamp())

    def start_heartbeat(self) -> None:
        """Beat while this process owns the gateway runtime lock, backfilling known lanes just before the first beat.

        Hermes loads the launch profile's plugins before its gateway claims the lock, so a process that does not
        own it yet polls cheaply until it does. A CLI never claims it, so it never beats.
        """
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            owned = self._gateway_owner()
            if owned:
                self.backfill(self._known_lanes)
                self.heartbeat()  # Publish before returning; a reader may check immediately after activation.

            def run() -> None:
                if not owned:
                    while not self._gateway_owner():
                        if self._stop.wait(OWNER_POLL_SECONDS):
                            return
                    with self._lock:
                        self._restore_snapshot()  # Construction skipped stale-turn recovery: no lock yet.
                    self.backfill(self._known_lanes)
                    self.heartbeat()
                while not self._stop.wait(self.heartbeat_interval_seconds):
                    if not self._gateway_owner():
                        return
                    self.heartbeat()

            try:
                thread = self._thread_factory(target=run, name=f"hermes-context:{self.profile}", daemon=True)
            except TypeError:
                thread = self._thread_factory(run, name=f"hermes-context:{self.profile}", daemon=True)
            self._thread = thread
            thread.start()

    def close(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=min(max(self.heartbeat_interval_seconds, 0.1), 1.0))
