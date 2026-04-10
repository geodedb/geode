# GQL Gap Analysis

ISO/IEC 39075:2024 — language-surface gaps in Geode's GQL implementation

Last updated: 2026-04-10
Audit context: GQL casing implementation audit (2026-04-10) — five parallel investigation agents covering lexer/parser keyword handling, function dispatch, procedure dispatch, test coverage, and ISO spec conformance. Closed via the `fix/gql-case-insensitivity` worktree on the same day.

## Scope

This file tracks GQL language-surface gaps that are NOT covered by the
SQLSTATE / conformance-profile findings in
[`GQL_CONFORMANCE_GAP_ANALYSIS.md`](GQL_CONFORMANCE_GAP_ANALYSIS.md). It
focuses on parser/lexer/executor behavior, language coverage, and tests
for GQL-visible features. For SQLSTATE codes, conformance flags, and
RQ-NNNN ISO requirement tracking, see the conformance file.

## Summary

- **Total findings (this session):** 10
- **Closed:** 4 (GAP-0527, GAP-0528, GAP-0529, GAP-0530)
- **Open / deferred:** 6 (GAP-0531 through GAP-0536)
- **Open severity breakdown:** High 2, Medium 2, Low 2

## Closed (2026-04-10)

These four gaps were closed in the `fix/gql-case-insensitivity` branch
during the GQL casing audit and gap-closure session.

| Gap ID | Severity | Title | Evidence | Fix Summary | Commit |
|---|---|---|---|---|---|
| GAP-0527 | High | `findFunction` / `findProcedure` use case-sensitive `std.mem.eql` despite `findKeyword` / `findType` being case-insensitive | `src/gql/language_metadata.zig:1599-1632` | Switched both lookups to `std.ascii.eqlIgnoreCase`; added 13 regression tests covering uppercase, lowercase, and mixed-case names plus aliases | `7c39e1f4` |
| GAP-0528 | Critical | CALL procedure dispatch is fully case-sensitive — `CALL ALGO.PAGERANK.STREAM()` raises `UnknownProcedure` while the lowercase form works (violates ISO/IEC 39075:2024 RQ-0022) | `src/execution/procedure_registry.zig:52-125`, `src/execution/algo_dispatch.zig:24-273`, `src/execution/audit_dispatch.zig`, `src/execution/storage_dispatch.zig`, `src/execution/auth_dispatch.zig` | Extracted `extractNormalizedProcName` which ASCII-lowercases the procedure name once at the dispatch entry point; all downstream dispatchers continue to use exact-match comparisons against canonical lowercase literals; added 12 unit tests for Ident and Member callees in mixed casings, wired into `zig build test` via a new `tests/test_procedure_case_insensitive.zig` target | `2aeb0647` |
| GAP-0529 | High | `eval.zig` function dispatch fallback uses original-case `function_name` against lowercase literal comparisons (latent case-sensitivity bug across 114 sites including `evalTimeseriesFunction`'s prefix check) | `src/eval.zig:888-1983, 3219-4458, 4720` | Replaced 114 `std.mem.eql(u8, function_name, "<lit>")` sites with `std.ascii.eqlIgnoreCase`; replaced `std.mem.startsWith` in `evalTimeseriesFunction` with `std.ascii.startsWithIgnoreCase`; verified by 17 new end-to-end regression tests for `RETURN ABS/COALESCE/SUBSTRING/TRIM(...)` in lower/upper/mixed case via the parser+executor harness | `e6bc34ca` |
| GAP-0530 | Low | Case-sensitivity contract for the language surface is not documented; behavior is implicit in code | `docs/GQL_COMPLIANCE.md` (no section before this fix) | Added an explicit "Case-Sensitivity Contract" section to `docs/GQL_COMPLIANCE.md` covering reserved keywords, type names, literals, functions, procedures (case-insensitive) vs. labels, property keys, variable names, role names, FLE field names (case-sensitive), with cross-references to the enforcing source files and the new test file | `c6c0a5a1` |

### Audit clarification on GAP-0529

The original audit (#2) framed GAP-0529 as a critical correctness bug
"affecting the majority of functions". Investigation during gap closure
showed this was overstated:

- The **first-pass dispatch** in `src/eval.zig:854-879` already lowercases
  the function name into `lowercase_fn` before passing it to
  `call_handlers.evalMathFunction`, `evalStringFunction`,
  `evalTypeCastFunction`, `evalCollectionFunction`, `evalAggregateFunction`,
  and `evalAdvancedTypeFunction`. So common math/string/cast/collection/
  aggregate calls (`COUNT`, `SUM`, `ABS`, `SQRT`, `SUBSTRING`, `REPLACE`,
  `TRIM`, `UPPER`, `LOWER`, etc.) work today regardless of case.
- `tryBasicFunction` at `src/eval.zig:3219` is invoked at line 2092 with
  the already-lowercased name (`lowercase_name`), so its checks against
  literal lowercase strings are reached with safe input.
- The duplicated dispatch at lines 1036-1971 is **dead code**: any
  function that reaches it has already been rejected by every handler,
  which does not happen for the names duplicated there.

The actually-reachable bug was in `evalTimeseriesFunction`'s
`std.mem.startsWith(u8, function_name, "timeseries.")` prefix check.
The fix is still uniform and defensive across all 114 sites because
removing the duplication is a separate refactor (see GAP-0532) and
hardening the dead code against a future call_handlers refactor is
cheap insurance.

## Open / Deferred Findings

These items were identified during the audit and gap-closure session
but intentionally deferred. Each row records the reason and a pointer
to the next action.

| Gap ID | Severity | Category | Title | Evidence | Why Deferred / Next Action | Owner | Status |
|---|---|---|---|---|---|---|---|
| GAP-0531 | High | feature | `db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`, `db.indexes()`, `db.constraints()`, `dbms.procedures()`, `dbms.functions()` are entirely unimplemented — every CALL to these standard graph-database introspection procedures returns `ExecutionError.UnknownProcedure` (regardless of casing) | `src/execution/procedure_registry.zig:124` | Feature work, not a casing bug. Audit finding #5. Needs its own design pass to define result schemas, RBAC policy, and test fixtures. Implementing these is the natural follow-up to GAP-0528 since the procedure-dispatch infrastructure is now ready. | execution | Open |
| GAP-0532 | High | architecture | Dual-dispatch architecture in `src/eval.zig` — function names are dispatched twice: first via `call_handlers.evalMathFunction` / `evalStringFunction` / etc. (which receive lowercased input and handle the common cases), then again in a fallback at lines 888-1983 that re-implements the same functions with original-case `function_name` checks. After GAP-0529 the fallback is correct, but the duplication wastes ~50 redundant comparisons per call and is a maintenance trap | `src/eval.zig:845-1983` (first pass at 845-881, fallback at 888-1983) | Architectural refactor; needs its own design pass. Related audit findings #4 and #8. The first step is to identify which functions are exclusively in the fallback (`timeseries.*`, `char(N)`) and migrate them into the appropriate handler module, then delete the duplicates. Should be a standalone branch with its own benchmark verification. | eval | Open |
| GAP-0533 | Medium | conformance | Confusable-identifier detection (RQ-0012) is "implemented as skeleton" but not wired into the parser/analyzer — `src/unicode/confusables.zig` provides the TR#39 skeleton algorithm and the SQLSTATE 42004 code is registered, but no parse-time or semantic-analysis pass actually computes skeletons for identifiers and raises 42004 on collisions | `src/unicode/confusables.zig`, `src/server/flagger_impl_defined.zig:98`, no callers in `src/gql/parser.zig` or `src/gql/semantic_analyzer.zig` | Listed as "Closed / Implemented" for the SQLSTATE registration in [`GQL_CONFORMANCE_GAP_ANALYSIS.md`](GQL_CONFORMANCE_GAP_ANALYSIS.md) row #5 (RQ-0012), but actual enforcement at parse time is missing. The skeleton library exists; needs a single pass over identifiers in the analyzer that hashes each into its skeleton and detects same-skeleton collisions in the same scope. | conformance | Open |
| GAP-0534 | Medium | tests | No geodetestlab integration specs cover mixed-case GQL syntax — all 200+ specs in `geode-test-harness/geodetestlab-cli/specs/` use consistent casing. Only `issue_475_icontains_case_insensitive.yml` touches case-insensitivity, and it tests the `icontains()` function (data-level), not GQL syntax (language-level) | `../geode-test-harness/geodetestlab-cli/specs/` | Lives in the separate `geode-test-harness` repo. Audit finding #6. Add a single comprehensive spec `gql_case_insensitivity_comprehensive.yml` that exercises ALL-UPPER, all-lower, and `MiXeDcAsE` forms of keywords (CREATE/MATCH/RETURN), built-in functions (COUNT/ABS/SUBSTRING), type names (INTEGER/STRING/BOOLEAN), and procedure CALLs. Coordinate with the test-harness repo's PR process. The Zig-side regression coverage in `tests/test_procedure_case_insensitive.zig` (29 tests) provides interim safety. | testing | Open |
| GAP-0535 | Low | tests | No end-to-end harness test for `RETURN UPPER(...)` / `LOWER(...)` despite both being case-insensitive in the dispatch path — the eval handlers allocate fresh result strings whose ownership is not tracked by `ExecutionResult.deinit` (which only frees `Value` memory when `owns_value_memory` is true). The leak is observable as `[gpa] (err): memory address ... leaked` on the testing allocator | `src/execution.zig:509-565` (`ExecutionResult.deinit` ownership flag), `tests/test_procedure_case_insensitive.zig` (commented-out UPPER/LOWER tests) | Pre-existing memory ownership issue in `ExecutionResult.deinit` (not tracking eval-allocated string ownership) — unrelated to the GQL casing audit. Deferred until the ownership issue is fixed at the harness level. The case-insensitivity behavior of UPPER/LOWER is exercised at the unit level via `call_handlers.evalStringFunction` and is structurally identical to the SUBSTRING/TRIM cases that ARE covered. | execution | Open |
| GAP-0536 | Low | tests | No end-to-end harness test for `RETURN TIMESERIES.PERCENTILE(...)` / `TIMESERIES.MIN(...)` etc. despite the timeseries prefix check being the only actually-reachable case-sensitivity bug fixed in GAP-0529 | `src/eval.zig:4720` (now uses `std.ascii.startsWithIgnoreCase`), no test calling `evalTimeseriesFunction` with non-lowercase input | Requires constructing a real `Store` (`resolveTimeseriesStore` + `Store.init` + ingested points + bound `env.timeseries_store`) — heavy harness work disproportionate to the bug. Fix is mechanically obvious (one-line change to `startsWithIgnoreCase`); deferred until a timeseries integration-test scaffold exists. | timeseries | Open |

## Where the Contract is Enforced

The case-sensitivity rules verified by GAP-0527 / 0528 / 0529 are now
enforced at the following sites. Future refactors that touch these
points should run `zig build test` to confirm the regression suite in
`tests/test_procedure_case_insensitive.zig` still passes.

| Layer | File:Line | Mechanism |
|---|---|---|
| Lexer | `src/gql/lexer.zig:259` → `src/gql/token.zig:423-435` | `keywordKind` calls `std.ascii.toUpper` and looks up an uppercase comptime `KeywordMap` |
| Parser | `src/gql/parser.zig` | Consumes `TokenKind` enum values, never raw text, for keyword decisions |
| Function metadata | `src/gql/language_metadata.zig:1599-1607` | `findFunction` uses `std.ascii.eqlIgnoreCase` (matches `findKeyword`/`findType`) |
| Procedure metadata | `src/gql/language_metadata.zig:1620-1632` | `findProcedure` uses `std.ascii.eqlIgnoreCase` for both name and alias |
| Procedure dispatch | `src/execution/procedure_registry.zig:52-125` | `extractNormalizedProcName` ASCII-lowercases the procedure name once at the dispatch entry point |
| Function evaluator | `src/eval.zig` | All 114 dispatch comparisons use `std.ascii.eqlIgnoreCase`; `evalTimeseriesFunction` uses `std.ascii.startsWithIgnoreCase` |
| Tests | `tests/test_procedure_case_insensitive.zig`, `src/gql/language_metadata.zig:1665-1735` | 29 regression tests across unit and end-to-end harness paths |

## Reading This File

- **Closed gaps** are kept here permanently as historical context. They
  do not move to `GAP_ANALYSIS_RESOLVED.md` because GQL gaps live in
  this dedicated file rather than the master `GAP_ANALYSIS.md`.
- **Severity** uses the same scale as `GAP_ANALYSIS.md`: Critical, High,
  Medium, Low. Critical gaps block release; High gaps block the next
  release train; Medium and Low gaps are scheduled.
- **Won't Do** items are not currently present. If a finding is rejected
  by policy, mark it `Won't Do` with a brief reason and do not delete it.
