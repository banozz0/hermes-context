"""Append-only, profile-scoped event segments; files are never rewritten or pruned.

Each append hard-links the previous newest event as `event-ids/<event_id>.json`, so a replay check costs one
lookup and the next sequence comes from the newest segment alone: an append never lists the whole tree.
"""
from __future__ import annotations

import json
import hashlib
import os
import threading
import uuid
from pathlib import Path
from typing import Any

from .contract import validate_event


class EventStore:
    def __init__(self, directory: Path, *, per_segment: int = 1000):
        if per_segment < 1:
            raise ValueError("per_segment must be positive")
        self.directory = directory / "events"
        self.ids = directory / "event-ids"
        self.per_segment = per_segment

    def generation(self, routing_id: str, session_id: str, lineage_root_id: str | None = None) -> dict[str, Any] | None:
        """Look up an ended generation independently of whether it made requests."""
        try:
            row = json.loads(self._generation_path(routing_id, session_id).read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        if (row["routing_id"] != routing_id or row["session_id"] != session_id or
                (lineage_root_id is not None and row["lineage_root_id"] != lineage_root_id)):
            raise ValueError("generation identity collision or corrupt record")
        return row

    def _generation_path(self, routing_id: str, session_id: str) -> Path:
        identity = json.dumps([routing_id, session_id], ensure_ascii=False, separators=(",", ":"))
        return self.directory.parent / "generations" / f"{hashlib.sha256(identity.encode('utf-8')).hexdigest()}.json"

    def remember_generation(self, row: dict[str, Any]) -> None:
        """Save only lineage/identity metadata before replacing the live row."""
        record = {key: row[key] for key in (
            "routing_id", "session_id", "lineage_root_id", "previous_session_id", "model", "provider"
        )}
        path = self._generation_path(row["routing_id"], row["session_id"])
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.exists():
            if self.generation(row["routing_id"], row["session_id"], row["lineage_root_id"]) is None:
                raise ValueError("generation identity collision")
            return
        temporary = path.parent / f".{uuid.uuid4().hex}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(record, handle, ensure_ascii=False, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.link(temporary, path)
            _fsync_directory(path.parent)
        finally:
            temporary.unlink(missing_ok=True)

    def append(self, event: dict[str, Any]) -> bool:
        """Caller holds the profile's snapshot.lock; return False for a replay."""
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ids.mkdir(exist_ok=True, mode=0o700)
        last = self._last()
        if last is not None:
            # The index trails the tree by the newest event, so a crash mid-append never leaves it behind.
            try:
                os.link(last, self._id_path(last.stem.split("-", 1)[1]))
            except FileExistsError:
                pass
            else:
                _fsync_directory(self.ids)
        index = self._id_path(event["event_id"])
        if index.exists():
            saved = json.loads(index.read_text(encoding="utf-8"))
            validate_event(saved)
            if saved["event_id"] != event["event_id"]:
                raise ValueError("event identity collision or corrupt event")
            return False
        sequence = int(last.stem.split("-", 1)[0]) + 1 if last else 1
        event["sequence"] = sequence
        validate_event(event)
        number, offset = divmod(sequence - 1, self.per_segment)
        segment = self.directory / f"{number + 1:06d}"
        segment.mkdir(mode=0o700, exist_ok=True)
        destination = segment / f"{sequence:012d}-{event['event_id']}.json"
        temporary = segment / f".{os.getpid()}.{threading.get_ident()}.{uuid.uuid4().hex}.tmp"
        body = (json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.link(temporary, destination)  # Exclusive publish; no overwrite of history.
            _fsync_directory(segment)
            if offset == 0:  # The segment's first event, so its directory is new.
                _fsync_directory(self.directory)
        finally:
            temporary.unlink(missing_ok=True)
        return True

    def _last(self) -> Path | None:
        """The newest published event, listing only the newest segment that holds one (zero-padded names sort)."""
        for segment in sorted((path for path in self.directory.iterdir() if path.name.isdigit()), reverse=True):
            last = max(segment.glob("*.json"), default=None)
            if last is not None:
                return last
        return None

    def _id_path(self, event_id: str) -> Path:
        return self.ids / f"{event_id}.json"


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
