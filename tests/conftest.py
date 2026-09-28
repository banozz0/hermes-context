from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path

import pytest


@pytest.fixture
def hermes(monkeypatch):
    """Hermes's source checkout on the path: `HERMES_AGENT_SOURCE`, else the one the running Python imports.

    The checkout goes first even when Hermes is installed editable, whose finder only knows modules from install time.
    Lazy installs stay off: under any Python but its managed one, Hermes's first import of its launch bootstrap
    syncs dependencies into the test's HERMES_HOME, rewrites the real install's launchers and re-executes the process.
    """
    monkeypatch.setenv("HERMES_DISABLE_LAZY_INSTALLS", "1")
    source = os.environ.get("HERMES_AGENT_SOURCE")
    if not source:
        spec = importlib.util.find_spec("hermes_constants")
        if spec is None or spec.origin is None:
            pytest.skip("the plugin integration seam needs Hermes: run under Hermes's Python or set HERMES_AGENT_SOURCE")
        source = str(Path(spec.origin).parent)
    monkeypatch.syspath_prepend(source)


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
