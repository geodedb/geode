# GQL Gap Analysis

Last updated: 2026-06-10

This file now contains only open/deferred GQL language-surface gaps. Earlier GAP-0527 through GAP-0533 entries live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| Gap ID | Severity | Category | Title | Evidence | Next action | Owner | Status |
|---|---|---|---|---|---|---|---|
| GAP-0534 | Medium | tests | No geodetestlab integration specs cover mixed-case GQL syntax. | `../geode-test-harness/geodetestlab-cli/specs/` uses consistent casing except unrelated `icontains()` coverage. | Add `gql_case_insensitivity_comprehensive.yml` in the harness repo covering mixed-case keywords, functions, type names, and procedure calls. | testing | Open |
| GAP-0535 | Low | tests / ownership | No end-to-end harness test for `RETURN UPPER(...)` / `LOWER(...)`; eval-allocated string ownership is not tracked by `ExecutionResult.deinit`. | `src/execution.zig:509-565`; commented-out UPPER/LOWER cases in `tests/test_procedure_case_insensitive.zig`. | Fix `ExecutionResult` value-memory ownership, then enable E2E string-function casing tests. | execution | Open |
| GAP-0536 | Low | tests / time-series | No E2E harness test for non-lowercase `TIMESERIES.*` calls even though the prefix check was the reachable casing bug. | `src/eval.zig` `evalTimeseriesFunction`; no real store-bound mixed-case timeseries test. | Build a time-series integration-test scaffold with real `Store` and bound `env.timeseries_store`. | timeseries | Open |
| GAP-0537 | Low | architecture | Exclusively-fallback function dispatch remains in `evalExpr` instead of dedicated handler modules. | Surviving `.Call` branch handles `timeseries.value`, `evalTimeseriesFunction`, `all()` / `any()`, and `char(N)`. | Move these into focused `call_handlers` modules after list-comprehension binding and time-series store access are factored. | eval | Open |
