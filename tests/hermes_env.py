"""How the tests and the probe reach Hermes without letting Hermes touch its real install.

Importing this turns Hermes's lazy installs off for the whole process: under any Python but its managed one,
Hermes's first import of its launch bootstrap syncs dependencies into the running HERMES_HOME, rewrites the real
install's `hermes` launchers to point there and re-executes the process (seen on Hermes 0.21.5, 2026-09-27).
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path

os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"


def hermes_source() -> str | None:
    """Hermes's source checkout: `HERMES_AGENT_SOURCE`, else the one the running Python imports, else None.

    Callers put it first on the path even when Hermes is installed editable, whose finder only knows modules from
    install time.
    """
    if os.environ.get("HERMES_AGENT_SOURCE"):
        return os.environ["HERMES_AGENT_SOURCE"]
    spec = importlib.util.find_spec("hermes_constants")
    return str(Path(spec.origin).parent) if spec and spec.origin else None
