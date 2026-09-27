"""Pins the extra v1 fixtures the native list consumes; all are produced by the real Observer."""
from __future__ import annotations

import json
from pathlib import Path

from conftest import read_snapshot
from hermes_context_observer.observer import Observer, Route

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "v1"


LABELS = {"channel-10": "#ops", "channel-20": "#planning"}


def route(profile: str, thread: str | None, name: str, *, channel: str = "channel-10") -> Route:
    return Route(
        profile=profile,
        platform="discord",
        chat_id=channel,
        thread_id=thread,
        guild_id="guild-1",
        channel_id=channel,
        display_name=name,
        channel_label=LABELS[channel],
    )


def build_before_reset(home: Path) -> None:
    """alpha just before /new rotates thread-1: the same lane as alpha.snapshot.json, older generation."""
    alpha = Observer(home, "alpha")
    alpha_one = route("alpha", "thread-1", "First thread")
    alpha.session_started(alpha_one, "alpha-1", model="model-a", provider="provider-a", at="2026-09-24T10:00:00.000Z")
    alpha.context_measured(alpha_one, "alpha-1", used=300, maximum=1000, source="provider_reported", at="2026-09-24T10:00:30.000Z")
    alpha.session_started(route("alpha", "thread-2", "Second thread"), "alpha-2", model="model-a", provider="provider-a", at="2026-09-24T10:01:00.000Z")


def build_gamma(home: Path) -> None:
    """Needs attention, working with context, a fresh idle lane, and an unthreaded lane idle for over 24 hours."""
    gamma = Observer(home, "gamma")
    planning = route("gamma", None, "Weekly planning", channel="channel-20")
    scratch = route("gamma", "thread-5", "Scratch notes")
    deploy = route("gamma", "thread-3", "Deploy review")
    refactor = route("gamma", "thread-4", "Refactor docs")
    gamma.session_started(planning, "gamma-1", model="model-g", provider="provider-g", at="2026-09-22T08:00:00.000Z")
    gamma.mark_idle(planning, "gamma-1", at="2026-09-22T08:05:00.000Z")
    gamma.session_started(scratch, "gamma-4", model="model-g", provider="provider-g", at="2026-09-23T10:30:00.000Z")
    gamma.mark_idle(scratch, "gamma-4", at="2026-09-23T10:31:00.000Z")
    gamma.session_started(deploy, "gamma-2", model="model-g", provider="provider-g", at="2026-09-24T09:49:00.000Z")
    gamma.context_measured(deploy, "gamma-2", used=45000, maximum=200000, source="provider_reported", at="2026-09-24T09:49:30.000Z")
    gamma.mark_attention(deploy, "gamma-2", at="2026-09-24T09:50:00.000Z")
    gamma.session_started(refactor, "gamma-3", model="model-h", provider="provider-g", at="2026-09-24T10:02:00.000Z")
    gamma.context_measured(refactor, "gamma-3", used=90000, maximum=200000, source="provider_reported", at="2026-09-24T10:02:30.000Z")
    gamma.mark_working(refactor, "gamma-3", tool="terminal", at="2026-09-24T10:03:00.000Z")


CASES = {
    "before-reset/alpha.snapshot.json": build_before_reset,
    "list/gamma.snapshot.json": build_gamma,
}


def write_fixtures(scratch: Path) -> None:
    """Deliberately rewrite every v1 fixture from the real Observer (run from tests/ with pytest installed)."""
    from test_replay_fixture import build_replay

    homes = {"alpha.snapshot.json": scratch / "alpha", "beta.snapshot.json": scratch / "beta"}
    build_replay(homes["alpha.snapshot.json"], homes["beta.snapshot.json"])
    for name, build in CASES.items():
        homes[name] = scratch / name.replace("/", "_")
        build(homes[name])
    for name, home in homes.items():
        target = FIXTURES / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((home / "hermes-context" / "v1" / "snapshot.json").read_bytes())
        target.chmod(0o600)


def test_list_fixtures_match_real_observer_output(tmp_path: Path):
    for name, build in CASES.items():
        home = tmp_path / name.replace("/", "_")
        build(home)
        assert read_snapshot(home) == json.loads((FIXTURES / name).read_text(encoding="utf-8")), name
