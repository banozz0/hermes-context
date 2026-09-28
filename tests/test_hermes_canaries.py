"""Canaries: fail as soon as Hermes drops a hook the plugin registers or stops passing a payload key it reads.

Both read the Hermes under test, so the nightly run against Hermes main and its latest release catches a rename
before it silently zeroes the numbers. The keys are derived from the plugin's own callbacks, never listed by hand.
"""
from __future__ import annotations

import ast
import inspect
import os
import textwrap
from pathlib import Path

import pytest

from hermes_context_observer import register
from hermes_env import hermes_source
from test_plugin import FakeContext

SKIPPED_DIRS = {"tests", "evals", "venv", "node_modules"}


def registered_hooks() -> dict:
    """Hook name → callback, as the plugin registers them."""
    context = FakeContext()
    register(context)
    context.unload()
    return context.hooks


def _read(node: ast.AST, paths: dict[str, str]) -> tuple[ast.Name, str] | None:
    """`(name, key path)` when `node` reads `name.get("key")` or `name["key"]` and `name` holds a path in `paths`,
    or chains onto such a read, like `payload.get("usage", {}).get("prompt_tokens")`."""
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get" and node.args:
        base, key = node.func.value, node.args[0]
    elif isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load):
        base, key = node.value, node.slice
    else:
        return None
    if not (isinstance(key, ast.Constant) and isinstance(key.value, str)):
        return None
    if isinstance(base, ast.Name) and base.id in paths:
        return base, paths[base.id] + key.value
    if inner := _read(base, paths):
        return inner[0], f"{inner[1]}.{key.value}"
    return None


def payload_reads(function, param: str) -> set[str]:
    """Keys `function` reads from its payload `param`, as `key` or `key.subkey`, including in module helpers it
    hands the payload to, like `_session_id(payload)`. Any other use of the payload fails, so no read goes unseen."""
    lines, first = inspect.getsourcelines(function)
    tree = ast.parse(textwrap.dedent("".join(lines)))
    root = {param: ""}
    paths = dict(root)
    for node in ast.walk(tree):  # `usage = payload.get("usage")` makes `usage` hold the path `usage.`
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and (read := _read(node.value, root)):
            paths[node.targets[0].id] = read[1] + "."
    keys, followed = set(), set()
    for node in ast.walk(tree):
        if read := _read(node, paths):
            followed.add(read[0])
            keys.add(read[1])
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
              and inspect.isfunction(helper := function.__globals__.get(node.func.id))):
            params = list(inspect.signature(helper).parameters)
            for index, arg in enumerate(node.args):
                if isinstance(arg, ast.Name) and arg.id == param:
                    followed.add(arg)
                    keys |= payload_reads(helper, params[index])
    unseen = [first + node.lineno - 1 for node in ast.walk(tree)
              if isinstance(node, ast.Name) and node.id == param and node not in followed]
    assert not unseen, f"{function.__qualname__} uses its payload where payload_reads cannot follow, at lines {unseen}"
    return keys


def callback_reads(hook: str, callback) -> set[str]:
    """Keys a hook callback reads; one whose payload is named `_payload` promises to read none."""
    payload = next(p.name for p in inspect.signature(callback).parameters.values() if p.kind is p.VAR_KEYWORD)
    keys = payload_reads(callback, payload)
    assert keys or payload.startswith("_"), f"{hook}: found no payload reads, so teach payload_reads the callback's shape"
    return keys


def _called(node: ast.AST) -> str | None:
    if isinstance(node, ast.Call):
        return getattr(node.func, "id", None) or getattr(node.func, "attr", None)
    return None


def _stored_keys(function: ast.FunctionDef) -> set[str]:
    """String keys a function puts into its **kwargs or into the dict it returns."""
    names = {function.args.kwarg.arg} if function.args.kwarg else set()
    names |= {node.value.id for node in ast.walk(function) if isinstance(node, ast.Return) and isinstance(node.value, ast.Name)}
    keys = set()
    for node in ast.walk(function):
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Store) and getattr(node.value, "id", None) in names:
            keys.add(getattr(node.slice, "value", None))
        elif _called(node) == "setdefault" and getattr(node.func.value, "id", None) in names and node.args:
            keys.add(getattr(node.args[0], "value", None))
    return keys


class HermesSource:
    """The Hermes source under test, parsed on demand; tests and evals excluded, since their fake calls prove nothing."""

    def __init__(self, root: Path):
        self.root = root
        self.texts = {}
        for folder, dirs, files in os.walk(root):
            dirs[:] = [name for name in dirs if name not in SKIPPED_DIRS and not name.startswith(".")]
            for name in files:
                if name.endswith(".py"):
                    path = Path(folder, name)
                    self.texts[path] = path.read_text(encoding="utf-8", errors="replace")
        self.nodes = {}

    def _nodes(self, *markers: str):
        """Every AST node of each file whose text holds any of `markers`."""
        for path, text in self.texts.items():
            if any(marker in text for marker in markers):
                if path not in self.nodes:
                    self.nodes[path] = list(ast.walk(ast.parse(text)))
                yield from ((path, node) for node in self.nodes[path])

    def sites(self, hook: str) -> list[tuple[Path, ast.Call]]:
        """Every call that dispatches `hook`: its name first, then a keyword payload.

        A call handing a wrapper the payload positionally is not one. Today only the CLI's and the TUI's own
        session-boundary notifiers fire `on_session_reset` that way: neither is Discord, and neither passes the old
        session id without which the plugin's reset does nothing.
        """
        return [(path, node) for path, node in self._nodes(f'"{hook}"', f"'{hook}'")
                if isinstance(node, ast.Call) and node.keywords and node.args
                and isinstance(node.args[0], ast.Constant) and node.args[0].value == hook]

    def functions(self, name: str | None) -> list[ast.FunctionDef]:
        return [node for _, node in self._nodes(f"def {name}(")
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name]

    def fields(self, name: str) -> set[str]:
        return {field.target.id for _, node in self._nodes(f"class {name}")
                if isinstance(node, ast.ClassDef) and node.name == name
                for field in node.body if isinstance(field, ast.AnnAssign) and isinstance(field.target, ast.Name)}

    def passes(self, call: ast.Call, key: str) -> bool:
        """Whether the call passes `key`: as a keyword, a field of a spread dataclass, a key its wrapper adds, or,
        for `key.subkey`, a key the function building that keyword's value stores."""
        top, _, sub = key.partition(".")
        for keyword in call.keywords:
            if keyword.arg == top:
                return not sub or any(sub in _stored_keys(f) for f in self.functions(_called(keyword.value)))
            if keyword.arg is None and not sub:  # `**_CallIds(...).hook_kwargs()`
                for node in ast.walk(keyword.value):
                    if (name := _called(node)) and top in self.fields(name):
                        return True
        return not sub and any(top in _stored_keys(f) for f in self.functions(_called(call)))  # `_fire_approval_hook`


def test_hermes_still_offers_every_hook_the_plugin_registers(hermes):
    valid = getattr(pytest.importorskip("hermes_cli.plugins"), "VALID_HOOKS", None)
    if valid is None:
        pytest.skip("this Hermes exposes no list of valid hooks to check against")
    assert set(registered_hooks()) - set(valid) == set()


def test_hermes_still_passes_every_payload_key_the_plugin_reads(hermes):
    reads = {hook: callback_reads(hook, callback) for hook, callback in registered_hooks().items()}
    source = HermesSource(Path(hermes_source()))
    problems = []
    for hook, keys in sorted(reads.items()):
        sites = source.sites(hook)
        if not sites:
            problems.append(f"{hook}: Hermes dispatches it nowhere")
        for key in sorted(keys):
            dropped = [f"{path.relative_to(source.root)}:{call.lineno}" for path, call in sites if not source.passes(call, key)]
            if dropped:
                problems.append(f"{hook}: {', '.join(dropped)} no longer passes {key}")
    assert not problems, "\n".join(problems)
