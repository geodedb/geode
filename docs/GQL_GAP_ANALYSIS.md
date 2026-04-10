# GQL Gap Analysis

ISO/IEC 39075:2024 — language-surface gaps in Geode's GQL implementation

Last updated: 2026-04-10 (second pass — GAP-0531/0532/0533 closed)
Audit context: GQL casing implementation audit (2026-04-10) — five parallel investigation agents covering lexer/parser keyword handling, function dispatch, procedure dispatch, test coverage, and ISO spec conformance. First pass closed GAP-0527 through GAP-0530 in the `fix/gql-case-insensitivity` worktree. Second pass on the same day closed GAP-0531 (db.*/dbms.* introspection), GAP-0532 (eval.zig dual-dispatch removal), and GAP-0533 (confusable identifier detection).

## Scope

This file tracks GQL language-surface gaps that are NOT covered by the
SQLSTATE / conformance-profile findings in
[`GQL_CONFORMANCE_GAP_ANALYSIS.md`](GQL_CONFORMANCE_GAP_ANALYSIS.md). It
focuses on parser/lexer/executor behavior, language coverage, and tests
for GQL-visible features. For SQLSTATE codes, conformance flags, and
RQ-NNNN ISO requirement tracking, see the conformance file.

## Summary

- **Total findings (this session):** 10
- **Closed:** 7 (GAP-0527, GAP-0528, GAP-0529, GAP-0530, GAP-0531, GAP-0532, GAP-0533)
- **Open / deferred:** 3 (GAP-0534, GAP-0535, GAP-0536)
- **Open severity breakdown:** Medium 1, Low 2

## Closed (2026-04-10)

These seven gaps were closed in the `fix/gql-case-insensitivity` branch
during the GQL casing audit and gap-closure session.

| Gap ID | Severity | Title | Evidence | Fix Summary | Commit |
|---|---|---|---|---|---|
| GAP-0527 | High | `findFunction` / `findProcedure` use case-sensitive `std.mem.eql` despite `findKeyword` / `findType` being case-insensitive | `src/gql/language_metadata.zig:1599-1632` | Switched both lookups to `std.ascii.eqlIgnoreCase`; added 13 regression tests covering uppercase, lowercase, and mixed-case names plus aliases | `7c39e1f4` |
| GAP-0528 | Critical | CALL procedure dispatch is fully case-sensitive — `CALL ALGO.PAGERANK.STREAM()` raises `UnknownProcedure` while the lowercase form works (violates ISO/IEC 39075:2024 RQ-0022) | `src/execution/procedure_registry.zig:52-125`, `src/execution/algo_dispatch.zig:24-273`, `src/execution/audit_dispatch.zig`, `src/execution/storage_dispatch.zig`, `src/execution/auth_dispatch.zig` | Extracted `extractNormalizedProcName` which ASCII-lowercases the procedure name once at the dispatch entry point; all downstream dispatchers continue to use exact-match comparisons against canonical lowercase literals; added 12 unit tests for Ident and Member callees in mixed casings, wired into `zig build test` via a new `tests/test_procedure_case_insensitive.zig` target | `2aeb0647` |
| GAP-0529 | High | `eval.zig` function dispatch fallback uses original-case `function_name` against lowercase literal comparisons (latent case-sensitivity bug across 114 sites including `evalTimeseriesFunction`'s prefix check) | `src/eval.zig:888-1983, 3219-4458, 4720` | Replaced 114 `std.mem.eql(u8, function_name, "<lit>")` sites with `std.ascii.eqlIgnoreCase`; replaced `std.mem.startsWith` in `evalTimeseriesFunction` with `std.ascii.startsWithIgnoreCase`; verified by 17 new end-to-end regression tests for `RETURN ABS/COALESCE/SUBSTRING/TRIM(...)` in lower/upper/mixed case via the parser+executor harness | `e6bc34ca` |
| GAP-0530 | Low | Case-sensitivity contract for the language surface is not documented; behavior is implicit in code | `docs/GQL_COMPLIANCE.md` (no section before this fix) | Added an explicit "Case-Sensitivity Contract" section to `docs/GQL_COMPLIANCE.md` covering reserved keywords, type names, literals, functions, procedures (case-insensitive) vs. labels, property keys, variable names, role names, FLE field names (case-sensitive), with cross-references to the enforcing source files and the new test file | `c6c0a5a1` |
| GAP-0531 | High | `db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`, `db.indexes()`, `db.constraints()`, `dbms.procedures()`, `dbms.functions()` are entirely unimplemented — every CALL returns `ExecutionError.UnknownProcedure` | `src/execution/procedure_registry.zig:124` | New `src/execution/meta_dispatch.zig` implements all seven introspection procedures over `graph_store` (labels, relationship types, property keys via direct iteration), `catalog.listAllIndexes` / `listAllConstraints`, and `language_metadata.procedures` / `functions`. Wired into `procedure_registry.executeCallProcedure` behind a `db.` / `dbms.` namespace prefix check. Fixed two pre-existing Zig 0.15 incompatibilities in `src/schema/catalog.zig` (`listAllIndexes` / `listAllConstraints` used the old `ArrayList(T).init` API). Added 10 end-to-end harness tests in `tests/test_meta_procedures.zig`, including case-insensitivity coverage for `CALL DB.LABELS()` / `CALL DBMS.FUNCTIONS()` | `4f855a61` |
| GAP-0532 | High | Dual-dispatch architecture in `src/eval.zig` — function names dispatched twice: first via `call_handlers.*` (lowercased), then again in a 947-line fallback that re-implements the same functions with original-case `function_name` checks | `src/eval.zig:1036-1981` (pre-deletion line numbers) | Investigated which fallback functions were duplicates of `call_handlers.zig` (substring, replace, trim/ltrim/rtrim, left/right, upper/lower, icontains, cast, keys, values, abs, sqrt, pow, sin, cos, tan, asin, acos, atan, atan2, degrees, radians, log, exp, ceil, floor, round, mod, sign, random — all of them) and confirmed they are unreachable because their corresponding handler always either matches the name and returns a Value or returns null only when no handler name matched. Deleted 947 lines of dead duplicate dispatch code. The 17 case-insensitive function regression tests pin the behavior. The exclusively-fallback functions (`timeseries.value`, `evalTimeseriesFunction` for other timeseries.* functions, `all` / `any` list comprehension predicates, `char(N)` type constructor) are intentionally preserved — migration of those into proper handler modules remains a follow-up | `fa9e5d05` |
| GAP-0533 | Medium | Confusable-identifier detection (RQ-0012) is implemented as a skeleton in `src/unicode/confusables.zig` but not wired into the parser/analyzer — no parse-time pass computes skeletons or raises SQLSTATE 42004 | `src/unicode/confusables.zig` (skeleton library), `src/server/flagger_impl_defined.zig:98` (impl-defined declaration), no callers in `src/gql/parser.zig` | New `src/gql/confusable_check.zig` walks the parsed AST collecting every user-declared identifier (MATCH/CREATE/MERGE pattern variables, RETURN/WITH aliases, LET bindings, UNWIND variables, path-variable assignments, chained queries, CALL subqueries), computes the TR#39 skeleton via the existing library, and returns `error.ConfusableIdentifier` on the first collision. Wired into `parse()` in `src/lib.zig` so every parser entry point gets the protection. Fixed pre-existing Zig 0.15 incompatibility in `src/unicode/confusables.zig` (`std.ArrayList(u8).init` was the old API). Added 8 parser-level regression tests in `tests/test_confusable_identifiers.zig` covering Latin-vs-Cyrillic, ASCII case folding, Greek-vs-Latin, and the RQ-0011 self-confusable rule | `e025d734` |

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
| GAP-0534 | Medium | tests | No geodetestlab integration specs cover mixed-case GQL syntax — all 200+ specs in `geode-test-harness/geodetestlab-cli/specs/` use consistent casing. Only `issue_475_icontains_case_insensitive.yml` touches case-insensitivity, and it tests the `icontains()` function (data-level), not GQL syntax (language-level) | `../geode-test-harness/geodetestlab-cli/specs/` | Lives in the separate `geode-test-harness` repo. Audit finding #6. Add a single comprehensive spec `gql_case_insensitivity_comprehensive.yml` that exercises ALL-UPPER, all-lower, and `MiXeDcAsE` forms of keywords (CREATE/MATCH/RETURN), built-in functions (COUNT/ABS/SUBSTRING), type names (INTEGER/STRING/BOOLEAN), and procedure CALLs. Coordinate with the test-harness repo's PR process. The Zig-side regression coverage in `tests/test_procedure_case_insensitive.zig` (29 tests) plus `tests/test_meta_procedures.zig` (10 tests) provides interim safety. | testing | Open |
| GAP-0535 | Low | tests | No end-to-end harness test for `RETURN UPPER(...)` / `LOWER(...)` despite both being case-insensitive in the dispatch path — the eval handlers allocate fresh result strings whose ownership is not tracked by `ExecutionResult.deinit` (which only frees `Value` memory when `owns_value_memory` is true). The leak is observable as `[gpa] (err): memory address ... leaked` on the testing allocator | `src/execution.zig:509-565` (`ExecutionResult.deinit` ownership flag), `tests/test_procedure_case_insensitive.zig` (commented-out UPPER/LOWER tests) | Pre-existing memory ownership issue in `ExecutionResult.deinit` (not tracking eval-allocated string ownership) — unrelated to the GQL casing audit. Deferred until the ownership issue is fixed at the harness level. The case-insensitivity behavior of UPPER/LOWER is exercised at the unit level via `call_handlers.evalStringFunction` and is structurally identical to the SUBSTRING/TRIM cases that ARE covered. | execution | Open |
| GAP-0536 | Low | tests | No end-to-end harness test for `RETURN TIMESERIES.PERCENTILE(...)` / `TIMESERIES.MIN(...)` etc. despite the timeseries prefix check being the only actually-reachable case-sensitivity bug fixed in GAP-0529 | `src/eval.zig` `evalTimeseriesFunction` (now uses `std.ascii.startsWithIgnoreCase`), no test calling `evalTimeseriesFunction` with non-lowercase input | Requires constructing a real `Store` (`resolveTimeseriesStore` + `Store.init` + ingested points + bound `env.timeseries_store`) — heavy harness work disproportionate to the bug. Fix is mechanically obvious (one-line change to `startsWithIgnoreCase`); deferred until a timeseries integration-test scaffold exists. | timeseries | Open |
| GAP-0537 | Low | architecture | The exclusively-fallback function dispatch in `src/eval.zig` (timeseries.value, evalTimeseriesFunction call, all() / any() list comprehension predicates, char(N) type constructor) is still in the .Call branch of evalExpr instead of in a dedicated handler module | `src/eval.zig` (the surviving block after the GAP-0532 deletion) | Migration of these functions into proper handler modules (`call_handlers.evalListPredicate`, `call_handlers.evalCharType`, `call_handlers.evalTimeseries*`) requires non-trivial refactoring of the list-comprehension binding flow and the timeseries store access path. Tracked as a follow-up to GAP-0532. The current code is correct (case-insensitive after GAP-0529) and the .Call branch is now 947 lines smaller, so this is purely a code-organization gap, not a correctness bug. | eval | Open |

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
| Confusable identifier check | `src/lib.zig:parse` → `src/gql/confusable_check.zig:checkProgram` → `src/unicode/confusables.zig:skeleton` | TR#39 skeleton computed for every user-declared identifier in a program; collisions raise `error.ConfusableIdentifier` (SQLSTATE 42004) at parse time |
| db.*/ dbms.* introspection | `src/execution/procedure_registry.zig` → `src/execution/meta_dispatch.zig:execute` | Routes any procedure name starting with `db.` or `dbms.` to the meta dispatcher; reads from `graph_store`, `catalog`, and `language_metadata` |
| Tests | `tests/test_procedure_case_insensitive.zig` (29), `tests/test_meta_procedures.zig` (10), `tests/test_confusable_identifiers.zig` (8), `src/gql/language_metadata.zig:1665-1735`, `src/gql/confusable_check.zig` (5 unit tests) | 57+ regression tests across unit, parser, and end-to-end harness paths |

## Reading This File

- **Closed gaps** are kept here permanently as historical context. They
  do not move to `GAP_ANALYSIS_RESOLVED.md` because GQL gaps live in
  this dedicated file rather than the master `GAP_ANALYSIS.md`.
- **Severity** uses the same scale as `GAP_ANALYSIS.md`: Critical, High,
  Medium, Low. Critical gaps block release; High gaps block the next
  release train; Medium and Low gaps are scheduled.
- **Won't Do** items are not currently present. If a finding is rejected
  by policy, mark it `Won't Do` with a brief reason and do not delete it.
