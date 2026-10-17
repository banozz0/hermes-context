# hermes-context — agent brief

macOS menu-bar app plus an observer-only Hermes plugin that shows every live Hermes Discord session and its context pressure.
Public, MIT. `README.md` is both the user guide and the contract's human spec.

## Commands
- Python observer, under Hermes's own Python (the tests find Hermes through it; `HERMES_AGENT_SOURCE` points them at another checkout):
  `uv run --no-project --with pytest --python ~/.hermes/hermes-agent/venv/bin/python python -m pytest -p no:cacheprovider` → all pass.
- Swift app: `swift test --package-path app` → both suites pass.
- While iterating, run one test file (append `tests/test_observer.py`) or `swift test --package-path app --filter <TestClass>`;
  run both full suites once before landing.
- `app/bundle.sh` builds and ad-hoc signs `app/build/HermesContext.app`.
- Headless app check (never draws on screen): see README → Native app, `HERMES_CONTEXT_HEADLESS=1`.
- Installer: `tests/test_installer.py` (in the Python suite) runs `install.sh` against a throwaway Hermes home;
  its end-to-end case skips on a Hermes that manages its own Python.
- Release: `release.sh` builds one from a commit already on `origin/main`; publishing it is a separate step.
- Nightly, `.github/workflows/hermes-compat.yml` runs the Python suite and the discovery probe on Linux against Hermes main
  and the latest release: a test that needs macOS skips itself there, and a break arrives as a `hermes-compat` issue.

## Layout
```
hermes-context/
├── hermes_context_observer/  # the observer-only Hermes plugin (plugin.yaml, observer, events, contract)
├── contracts/v1/             # snapshot and event JSON schemas: the privacy allowlist
├── fixtures/v1/              # sample snapshots and event replays both suites read
├── tests/                    # Python suite, incl. the installer test
├── app/                      # Swift package for the menu-bar app; bundle.sh builds it
│   ├── Sources/              # HermesContext (app) and HermesContextCore (logic)
│   └── Tests/                # app and core suites
├── .github/workflows/        # CI and the nightly hermes-compat run
└── .claude/                  # project Claude Code settings
```

## Rules the tests only partly enforce
- Privacy is an allowlist. Snapshots, events, SQLite and exports carry only the fields `contracts/v1/*.schema.json` names;
  prompts, responses, tool arguments, results and error text never enter any of them.
  A new field is a contract change: schema, `validate_*`, Swift decoder and README together.
- README is the contract's human spec, and `InsightsTests` checks it lists every export field: update it in the same step as the behavior.
- Tests and checks use disposable Hermes homes only. Installing into a real Hermes profile, restarting a gateway
  and publishing a release happen only on the maintainer's explicit go-ahead.
- The app reads Hermes; it never writes Hermes state, sends prompts or opens a network port.
- README → Install and `MIN_HERMES` in `install.sh` name the minimum Hermes version. A change that needs a newer Hermes API raises both.

## Traps
- GitHub dispatches a workflow (`gh workflow run`, even with `--ref`) only once its file is on the default branch.
  Prove a new workflow on its branch with a temporary `push:` trigger, and drop that trigger before merging.
- The telemetry store is WAL mode. macOS `/usr/bin/sqlite3 -readonly` fails on a copy without its `-wal`/`-shm` files
  ("unable to open database file (14)"); inspect it with Python's `sqlite3` instead.
- `swift .github/social-preview.swift` renders `.github/social-preview.png` (1280x640, under 1 MB). GitHub has no API for it:
  upload it in Settings → General → Social preview, then check `gh repo view --json usesCustomOpenGraphImage`.
