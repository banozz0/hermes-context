# hermes-context — agent brief

macOS menu-bar app plus an observer-only Hermes plugin that shows every live Hermes Discord session and its context pressure. Private repo for now; the goal is a public open-source release. Spec, dashboard and journal: vault `Projects/Hermes System/Hermes Context/`.

## Working here
- Python observer: `uv run --no-project --with pytest --python /Users/sven/.hermes/hermes-agent/venv/bin/python python -m pytest -p no:cacheprovider` → all pass.
- Swift app: `swift test --package-path app` → both suites pass. `app/bundle.sh` builds and ad-hoc signs `app/build/HermesContext.app`.
- Headless app check (never draws on screen): see README → Native app, `HERMES_CONTEXT_HEADLESS=1`.

## Rules the tests only partly enforce
- Privacy is an allowlist. Snapshots, events, SQLite and exports carry only the fields `contracts/v1/*.schema.json` names; prompts, responses, tool arguments, results and error text never enter any of them. A new field is a contract change: schema, `validate_*`, Swift decoder and README together.
- README is the contract's human spec, and `InsightsTests` checks it lists every export field: update it in the same step as the behavior.
- The live plugin copies in `/Users/sven/.hermes/profiles/*/plugins/hermes-context-observer/` and any gateway restart are protected actions: Sven approves the exact command first. Tests use disposable homes only.
- The app reads Hermes; it never writes Hermes state, sends prompts or opens a network port.
