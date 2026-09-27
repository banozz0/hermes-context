from __future__ import annotations

import json
from pathlib import Path

from conftest import read_snapshot
from hermes_context_observer.observer import Observer, Route


def route(profile: str, thread: str, name: str) -> Route:
    return Route(
        profile=profile,
        platform="discord",
        chat_id="channel-10",
        thread_id=thread,
        guild_id="guild-1",
        channel_id="channel-10",
        display_name=name,
        channel_label="#ops",
    )


def build_replay(alpha_home: Path, beta_home: Path) -> None:
    alpha, beta = Observer(alpha_home, "alpha"), Observer(beta_home, "beta")
    alpha_one = route("alpha", "thread-1", "First thread")
    alpha_two = route("alpha", "thread-2", "Second thread")
    beta_one = route("beta", "thread-1", "First thread")

    alpha.session_started(alpha_one, "alpha-1", model="model-a", provider="provider-a", at="2026-09-24T10:00:00.000Z")
    alpha.context_measured(alpha_one, "alpha-1", used=300, maximum=1000, source="provider_reported", at="2026-09-24T10:00:30.000Z")
    alpha.session_started(alpha_two, "alpha-2", model="model-a", provider="provider-a", at="2026-09-24T10:01:00.000Z")
    beta.session_started(beta_one, "beta-1", model="model-b", provider="provider-b", at="2026-09-24T10:02:00.000Z")
    alpha.session_reset("alpha-1", "alpha-3", at="2026-09-24T10:03:00.000Z")
    alpha.mark_idle(alpha_one, "alpha-3", at="2026-09-24T10:04:00.000Z")
    beta.mark_idle(beta_one, "beta-1", at="2026-09-24T10:05:00.000Z")


def test_replay_matches_deterministic_v1_fixtures(tmp_path: Path):
    alpha_home, beta_home = tmp_path / "alpha", tmp_path / "beta"
    build_replay(alpha_home, beta_home)

    fixture_dir = Path(__file__).resolve().parents[1] / "fixtures" / "v1"
    expected_alpha = json.loads((fixture_dir / "alpha.snapshot.json").read_text(encoding="utf-8"))
    expected_beta = json.loads((fixture_dir / "beta.snapshot.json").read_text(encoding="utf-8"))
    assert read_snapshot(alpha_home) == expected_alpha
    assert read_snapshot(beta_home) == expected_beta
