from __future__ import annotations

import json
from pathlib import Path

import pytest


@pytest.fixture
def fixed_times():
    return {
        "t0": "2026-09-24T10:00:00.000Z",
        "t1": "2026-09-24T10:01:00.000Z",
        "t2": "2026-09-24T10:02:00.000Z",
        "t3": "2026-09-24T10:03:00.000Z",
    }


def read_snapshot(home: Path) -> dict:
    path = home / "hermes-context" / "v1" / "snapshot.json"
    return json.loads(path.read_text(encoding="utf-8"))


def events(home: Path) -> list[dict]:
    """Every published event file under a profile home, in file-name (sequence) order."""
    return [json.loads(path.read_text()) for path in sorted((home / "hermes-context/v1/events").glob("*/*.json"))]
