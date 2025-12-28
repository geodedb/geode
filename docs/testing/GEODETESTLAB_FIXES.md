## Geodetestlab Fix Plan

- **Enforce query-only automation**: `geode shell` now rejects non-interactive use; migrate all scripted setup/fixtures to `geode query` and remove any reliance on embedded fallbacks.
- **Server lifecycle**: geodetestlab server manager must always start a real server (no embedded mode) and pass the active listen address into client invocations to avoid `ConnectionRefused`.
- **Spec cleanup**: replace `command: "shell"` cases with `command: "query"` (or equivalent) across specs (nested queries, edge cases, basic setup, recursive/CTE, chained ops, functions, advanced math, etc.); drop output expectations tied to shell banners.
- **Runner wiring**: ensure test runner injects the managed server address/port into query invocations for both embedded and server phases, and adjusts any templates that assumed shell behavior.
- **Failure triage**: top patterns to eradicate: `exit code` (1046), `execution error` (45), `missing` (8), `stderr missing` (7). Use logs at `/home/benji/src/spyder/geode/test_logs/run_20251124_193745` to map failing specs to fixes.
- **Validation**: after spec and runner updates, rerun `make geodetestlab` and confirm clean runs for previously failing suites (`nested_queries_basic`, `geode_edge_cases_errors`, `geode_basic`, session/storage, data modification). Iterate until zero `ConnectionRefused`/non-interactive shell errors remain.
