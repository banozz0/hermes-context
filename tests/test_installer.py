"""install.sh end to end against a throwaway Hermes home; the real `hermes` CLI does the plugin work."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PLUGIN = "hermes-context-observer"
APP = "HermesContext.app"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

pytestmark = pytest.mark.skipif(shutil.which("ditto") is None, reason="install.sh runs on macOS only")


def field(output: str, label: str, default: str = "") -> str:
    """The value of a `Label: value` line in a Hermes command's output."""
    return next((line.split(":", 1)[1].strip() for line in output.splitlines() if line.startswith(f"{label}:")), default)


def hermes_keeps_its_launchers() -> bool:
    """False unless Hermes's install stamp is readable and names an update mechanism other than `self`.

    A Hermes that manages its own Python (0.21.5 on) builds a Python into any throwaway HERMES_HOME it runs under and
    repoints its real `hermes` launchers there (seen 2026-09-27). `--version` is a metadata flag, so asking is safe.
    """
    shown = subprocess.run(["hermes", "--version"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    try:
        stamp = json.loads((Path(field(shown.stdout, "Install directory")) / "install-stamp.json").read_text())
    except (OSError, ValueError):
        return False
    return isinstance(stamp, dict) and stamp.get("updateMechanism", "self") != "self"


@pytest.fixture
def bench(tmp_path: Path) -> dict:
    """A throwaway HOME and Hermes home, a stand-in app zip and a stamped script; no Hermes command has run."""
    home, hermes_home, install_dir = tmp_path / "home", tmp_path / "hermes", tmp_path / "Applications"
    home.mkdir()
    hermes_home.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith("HERMES")}
    # Lazy installs off, or the CLI syncs dependencies into this throwaway home.
    env.update(HOME=str(home), HERMES_HOME=str(hermes_home), HERMES_DISABLE_LAZY_INSTALLS="1")
    binary = tmp_path / "zip" / APP / "Contents" / "MacOS" / "HermesContext"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(binary.parents[2]), str(tmp_path / "app.zip")], check=True)
    commit = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], check=True, capture_output=True,
                            text=True).stdout.strip()
    script = tmp_path / "install.sh"
    script.write_text((REPO / "install.sh").read_text().replace("@VERSION@", "0.0.0-test").replace("@COMMIT@", commit))
    env.update(
        HERMES_CONTEXT_PLUGIN_SOURCE=f"file://{REPO}#hermes_context_observer",
        HERMES_CONTEXT_APP_ZIP=str(tmp_path / "app.zip"),
        HERMES_CONTEXT_INSTALL_DIR=str(install_dir),
        HERMES_CONTEXT_NO_OPEN="1",
    )
    homes = {"default": hermes_home, "alpha": hermes_home / "profiles" / "alpha"}
    return {"env": env, "script": script, "install_dir": install_dir, "homes": homes, "home": home}


@pytest.fixture
def world(request) -> dict:
    """The bench with profiles default and alpha, made by the real `hermes` CLI."""
    if shutil.which("hermes") is None:
        pytest.skip("needs the hermes CLI")
    if not hermes_keeps_its_launchers():
        pytest.skip("this Hermes may repoint its real launchers at a throwaway HERMES_HOME; the live install proves install.sh")
    bench = request.getfixturevalue("bench")
    env = bench["env"]
    subprocess.run(["hermes", "profile", "create", "alpha", "--no-alias", "--no-skills"], env=env, check=True,
                   capture_output=True)
    # A display name turns the default row's label into `Main Bot (default)`.
    subprocess.run(["hermes", "profile", "rename", "default", "Main Bot"], env=env, check=True, capture_output=True)
    return bench


def run(world: dict, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    """Fed on stdin, as `curl … | sh -s -- <args>` runs it, so a child reading stdin would eat the script."""
    with world["script"].open() as script:
        return subprocess.run(["sh", "-s", "--", *args], stdin=script, env=env or world["env"], capture_output=True,
                              text=True, timeout=600)


def ok(world: dict, *args: str) -> None:
    result = run(world, *args)
    assert result.returncode == 0, result.stderr


def statuses(world: dict) -> dict[str, str]:
    """Each profile's observer status as `hermes plugins show` reports it, or absent."""
    def status(profile: str) -> str:
        shown = subprocess.run(["hermes", "-p", profile, "plugins", "show", PLUGIN], env=world["env"],
                               capture_output=True, text=True)
        return field(shown.stdout, "Status", "absent")
    return {profile: status(profile) for profile in world["homes"]}


def plugin_files(world: dict) -> dict[str, bytes]:
    root = world["homes"]["default"]
    return {str(path.relative_to(root)): path.read_bytes() for home in world["homes"].values()
            for path in sorted((home / "plugins" / PLUGIN).rglob("*")) if path.is_file() and not {".git", "__pycache__"} & set(path.parts)}


def real_hermes_plugins() -> dict[str, float]:
    """Every plugin directory in the real Hermes home and its modification time."""
    root = Path.home() / ".hermes"
    return {str(path): path.stat().st_mtime for path in [*root.glob("plugins/*"), *root.glob("profiles/*/plugins/*")]}


def test_install_rerun_uninstall_and_purge(world: dict):
    before = real_hermes_plugins()
    installed = run(world)
    assert installed.returncode == 0, installed.stderr
    assert statuses(world) == dict.fromkeys(world["homes"], "enabled")
    # No gateway runs in the throwaway home, so Hermes's restart hint reaches the user.
    assert "No running gateway loaded the observer for: default alpha." in installed.stdout
    assert (world["install_dir"] / APP / "Contents" / "MacOS" / "HermesContext").is_file()
    files = plugin_files(world)
    assert files["profiles/alpha/plugins/hermes-context-observer/observer.py"] == (
        REPO / "hermes_context_observer" / "observer.py").read_bytes()

    binary = world["install_dir"] / APP / "Contents" / "MacOS" / "HermesContext"
    placed = binary.stat().st_ino
    rerun = run(world)
    assert rerun.returncode == 0, rerun.stderr
    assert all(f"Hermes profile {profile} is already connected." in rerun.stdout for profile in world["homes"])
    assert "No running gateway" not in rerun.stdout
    assert "is already this version." in rerun.stdout
    assert plugin_files(world) == files
    assert binary.stat().st_ino == placed, "an identical app is left in place"

    history = world["home"] / "Library" / "Application Support" / "dev.banozz0.hermes-context" / "telemetry.sqlite"
    history.parent.mkdir(parents=True)
    history.write_bytes(b"history")
    bridges = [home / "hermes-context" / "v1" / "snapshot.json" for home in world["homes"].values()]
    for bridge in bridges:
        bridge.parent.mkdir(parents=True, exist_ok=True)
        bridge.write_text("{}")

    ok(world, "--uninstall")
    assert statuses(world) == dict.fromkeys(world["homes"], "absent")
    assert not (world["install_dir"] / APP).exists()
    assert history.is_file() and all(bridge.is_file() for bridge in bridges)

    ok(world, "--uninstall", "--purge")
    assert not history.parent.exists()
    assert not any(bridge.parents[1].exists() for bridge in bridges)
    assert real_hermes_plugins() == before, "the real Hermes home was touched"


def shim(bench: dict, name: str, body: str) -> dict:
    """The bench's environment on the system PATH, with `name` a stand-in command running the given shell body."""
    directory = bench["home"].parent / f"shim-{name}"
    directory.mkdir()
    (directory / name).write_text(f"#!/bin/sh\n{body}\n")
    (directory / name).chmod(0o755)
    return dict(bench["env"], PATH=f"{directory}:{SYSTEM_PATH}")


def test_preflight_stops_before_touching_anything(bench: dict):
    refused = run(bench, env=dict(bench["env"], PATH=SYSTEM_PATH))
    assert refused.returncode != 0
    assert "needs Hermes" in refused.stderr

    old = run(bench, env=shim(bench, "sw_vers", "echo 13.6"))
    assert old.returncode != 0
    assert "needs macOS 14 or later; this Mac runs 13.6" in old.stderr

    outdated = run(bench, env=shim(bench, "hermes", 'echo "Hermes Agent v0.21.4 (2026.9.21)"'))
    assert outdated.returncode != 0
    assert "needs Hermes 0.21.5 or later; this Mac runs 0.21.4. Run `hermes update` first." in outdated.stderr

    assert not bench["install_dir"].exists()
    assert not any((home / "plugins" / PLUGIN).exists() for home in bench["homes"].values())


def test_preflight_passes_a_hermes_it_cannot_date(bench: dict):
    """An unrecognised `--version` line never blocks; the next step (listing profiles) runs."""
    shimmed = run(bench, env=shim(bench, "hermes", 'echo "Hermes Agent (dev build)"'))
    assert "needs Hermes 0" not in shimmed.stderr
    assert "Hermes lists no profiles." in shimmed.stderr
