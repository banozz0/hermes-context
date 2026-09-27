"""install.sh end to end against a throwaway Hermes home; the real `hermes` CLI does the plugin work."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PLUGIN = "hermes-context-observer"
APP = "HermesContext.app"

pytestmark = pytest.mark.skipif(shutil.which("hermes") is None or shutil.which("ditto") is None,
                                reason="needs the hermes CLI and macOS ditto")


@pytest.fixture
def world(tmp_path: Path) -> dict:
    """A throwaway HOME and Hermes home with profiles default and alpha, a stand-in app zip and a stamped script."""
    home, hermes_home, install_dir = tmp_path / "home", tmp_path / "hermes", tmp_path / "Applications"
    home.mkdir()
    hermes_home.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith("HERMES")}
    env.update(HOME=str(home), HERMES_HOME=str(hermes_home))
    subprocess.run(["hermes", "profile", "create", "alpha", "--no-alias", "--no-skills"], env=env, check=True,
                   capture_output=True)
    # A display name turns the default row's label into `Main Bot (default)`.
    subprocess.run(["hermes", "profile", "rename", "default", "Main Bot"], env=env, check=True, capture_output=True)
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
        return next((line.split(":", 1)[1].strip() for line in shown.stdout.splitlines()
                     if line.startswith("Status:")), "absent")
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


def test_preflight_stops_before_touching_anything(world: dict, tmp_path: Path):
    no_hermes = dict(world["env"], PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    refused = run(world, env=no_hermes)
    assert refused.returncode != 0
    assert "needs Hermes" in refused.stderr

    shim = tmp_path / "old-macos"
    shim.mkdir()
    (shim / "sw_vers").write_text("#!/bin/sh\necho 13.6\n")
    (shim / "sw_vers").chmod(0o755)
    old = run(world, env=dict(world["env"], PATH=f"{shim}:{world['env']['PATH']}"))
    assert old.returncode != 0
    assert "needs macOS 14 or later; this Mac runs 13.6" in old.stderr

    assert not world["install_dir"].exists()
    assert not any((home / "plugins" / PLUGIN).exists() for home in world["homes"].values())
