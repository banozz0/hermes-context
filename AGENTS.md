# hermes-context — agent brief

macOS menu-bar app plus an observer-only Hermes plugin that shows every live Hermes Discord session and its context pressure. Public, MIT. `README.md` is both the user guide and the contract's human spec.

## Working here
- Python observer, under Hermes's own Python (the tests find Hermes through it; `HERMES_AGENT_SOURCE` points them at another checkout): `uv run --no-project --with pytest --python ~/.hermes/hermes-agent/venv/bin/python python -m pytest -p no:cacheprovider` → all pass.
- Swift app: `swift test --package-path app` → both suites pass. `app/bundle.sh` builds and ad-hoc signs `app/build/HermesContext.app`.
- Headless app check (never draws on screen): see README → Native app, `HERMES_CONTEXT_HEADLESS=1`.
- Installer: `tests/test_installer.py` (in the Python suite) runs `install.sh` against a throwaway Hermes home. `release.sh` builds a release; publishing it is a separate step.

## Rules the tests only partly enforce
- Privacy is an allowlist. Snapshots, events, SQLite and exports carry only the fields `contracts/v1/*.schema.json` names; prompts, responses, tool arguments, results and error text never enter any of them. A new field is a contract change: schema, `validate_*`, Swift decoder and README together.
- README is the contract's human spec, and `InsightsTests` checks it lists every export field: update it in the same step as the behavior.
- Tests and checks use disposable Hermes homes only. Installing into a real Hermes profile, restarting a gateway and publishing a release happen only on the maintainer's explicit go-ahead.
- The app reads Hermes; it never writes Hermes state, sends prompts or opens a network port.
- README → Install names the minimum Hermes version. A change that needs a newer Hermes API raises it there.
