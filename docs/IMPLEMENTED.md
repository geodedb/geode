# Implemented Features & Requirements (authoritative)

This file records completed work for clarity, keeping `GAP_ANALYSIS.md` focused on gaps and upcoming work.

## Implemented Requirements (from GAP analysis)

| Requirement ID | Requirement (1–2 lines)                                                                                                        | Source (docs §, ISO)                         | Status      | Evidence (file:line or test name)                                                                                                                               | Notes                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| REQ‑GQL‑002    | ORDER BY key legality policies (idents‑only; forbid calls; forbid path aliases).                                               | query_engine.md §3.2; ISO 14.10              | Implemented | Tests: src/gql.zig “ident_order_only rejects member keys”, “ORDER BY path alias is rejected (policy)”; CLI flags in src/gql/main.zig                            | Gate via parser options                                    |
| REQ‑GQL‑003    | MATCH and OPTIONAL MATCH: nodes, rels, quantifiers, type alternation.                                                          | query_engine.md §3.1; ISO 14.4               | Implemented | Tests: src/gql.zig “multi‑hop…”, “relationship length quantifiers”, “OPTIONAL MATCH…”                                                                           | Printer covers all                                         |
| REQ‑GQL‑004    | Pattern comprehension with alias.                                                                                              | query_engine.md §3.1; ISO (pattern comp.)    | Implemented | Test: src/gql.zig “pattern comprehension basic”                                                                                                                 | AST Expr.PatternComp                                       |
| REQ‑GQL‑005    | Set ops: UNION/INTERSECT/EXCEPT parse (ALL/DISTINCT) and runtime semantics over binding tables.                                | query_engine.md §3.1; ISO 14.12 (+Annex)     | Implemented | Exec: src/exec.zig set‑ops; Tests: “set ops semantics: UNION DISTINCT and INTERSECT/EXCEPT ALL”; “binding table set ops: multi‑column with NULLs”               | Ordering: DISTINCT→sorted; ALL→stable‑left; threshold=2048 |
| REQ‑GQL‑006    | GROUP BY parse + legality (phase‑1 scoping); HAVING allowed forms.                                                             | query_engine.md §3.2; ISO 14.10              | Implemented | Tests: src/planner.zig “planner: group by legality basic”, “planner: having legality”; Parse test: src/gql.zig “GROUP BY with HAVING and ORDER BY NULLS policy” | Phase‑2 adds catalog                                       |
| REQ‑GQL‑007    | Expressions: arithmetic, boolean, NULL tests, IN list, calls, maps.                                                            | query_engine.md §3.2; ISO 16.x               | Implemented | Tests: src/gql.zig “arithmetic and IN list predicate”; “function call and map literal”                                                                          | Extend validator incrementally                             |
| REQ‑GQL‑008    | String predicates: STARTS/ENDS/CONTAINS; regex =~ (parse + eval subset).                                                       | query_engine.md §3.2; ISO 16.x               | Implemented | Tests: src/eval.zig “string predicates and regex basic”; src/gql.zig “string predicates and regex operator parse”                                               | Eval uses simple matcher (^, $, .\*)                       |
| REQ‑GQL‑009    | Temporal literals/types: DATE/TIME/DATETIME/LOCAL DATETIME; validation; normalization; comparisons with session‑offset attach. | query_engine.md §3; ISO 18.x; 14.10          | Implemented | Tests: src/gql.zig temporal printers; planner compareTemporalForOrder; exec stable ORDER BY test                                                                | JSON verbose temporals present                             |
| REQ‑GQL‑010    | JSON AST verbose temporals (kind/raw/parsed).                                                                                  | query_engine.md §3                           | Implemented | Test: src/gql.zig “JSON verbose temporals includes kind/raw/parsed”                                                                                             | CLI flag --ast-json-verbose                                |
| REQ‑GQL‑011    | CLI: normalize temporals; clamp frac; ORDER BY policy flags; AST printers; session offset flag.                                | README.md; query_engine.md; ISO 7 (sessions) | Implemented | src/gql/main.zig flags; print.json includes session_offset_minutes; temporal.parseOffsetMinutes                                                                 | End‑to‑end demo available                                  |
| REQ‑GQL‑012    | Pagination legality: reject OFFSET pushdown without explicit ORDER (US001); allow when safe.                                   | query_engine.md §3.2; ISO 16.18–16.19        | Implemented | Planner tests: “offset pushdown rejected without order”, “offset allowed with explicit order”                                                                   | Policy codified                                            |
| REQ‑GQL‑013    | Stable ORDER BY comparator for temporals incl. NULLS policy per key.                                                           | query_engine.md §3.1; ISO 14.10              | Implemented | Exec tests: “stable ORDER BY with cross‑timezone…”, “ORDER BY nulls policy: FIRST/LAST”                                                                         | Per‑key NULLS FIRST/LAST honored                           |
| REQ‑GQL‑017    | Sessions/timezone: thread CLI session offset into runtime comparators; CLI sort demo.                                          | query_engine.md §3; ISO 7; 14.10             | Implemented | CLI: src/gql/main.zig --session-offset; demo: --demo-sort sorts temporal rows with session offset                                                               | Demo uses first ORDER BY key                               |

## Completed Backlog Items (from NEXT plan)

1. Set ops semantics (DISTINCT/ALL)

- Evidence: src/exec.zig set-ops over binding rows; tests “set ops semantics: UNION DISTINCT and INTERSECT/EXCEPT ALL” and “binding table set ops: multi-column with NULLs”.
- Ordering policy: DISTINCT → deterministically sorted; ALL → stable-left.
- Perf: union DISTINCT uses hash threshold (2048) with a microbench flag (--bench-setops).
- Demo: CLI flag --demo-setops showcases behavior.

2. Temporal session offset end‑to‑end (from Now)

- Comparator attaches session offset; CLI `--session-offset` affects sort demo; tests cover local vs zoned comparisons.

3. Pagination legality + US001 guardrails (from Now)

- Planner enforces explicit ORDER for OFFSET pushdown; tests present; US001 documented.

4. GROUP BY legality (phase‑1) and HAVING legality (from Now)

- Planner legality checks with tests; HAVING allowed forms enforced.

5. Conformance flagger (skeleton) (from Now)

- JSON profile writer exists; CLI flag `--conformance-json` emits the skeleton with key features and policy notes.

## Recently Implemented Features (December 2024)

### OPTIONAL MATCH Implementation (REQ-GQL-015)
- **Location**: src/server/graph/exec.zig:executeOptionalMatch
- **Features**: Full left-outer join semantics with NULL preservation for unmatched patterns
- **Tests**: tests/e2e_optional_match.zig
- **ISO Reference**: 14.4

### Variable-Length Path Expansion (REQ-GQL-016)
- **Location**: src/server/graph/exec.zig:pathExpand
- **Features**: Bounded BFS traversal with [*min..max] syntax, cycle detection
- **Tests**: tests/e2e_optional_match.zig
- **ISO Reference**: 22.4

### Enhanced MVCC Conflict Detection (REQ-GQL-027)
- **Location**: src/server/txn/mvcc.zig:detectConflict, conflictToError
- **Features**: Comprehensive conflict matrix, ISO 40001 error mapping
- **Tests**: tests/e2e_optional_match.zig
- **ISO Reference**: 8

### Storage Catalog Graph Persistence (REQ-GQL-025)
- **Location**: src/storage/catalog.zig:GraphMetadata
- **Features**: Page-based graph storage, --data_dir integration
- **Tests**: tests/e2e_optional_match.zig

### Path Tie-Breaking Policy (UA005/UA006)
- **Location**: src/server/graph/exec.zig:applyPathTieBreaking
- **Policy**: Deterministic selection based on path length, node IDs
- **ISO Reference**: 22.4

### WITH Clause Execution (REQ-GQL-018)
- **Location**: src/server/graph/exec.zig:executeWith
- **Features**: 
  - Projection stage that produces new bindings with only WITH items
  - Supports aliases for projected items
  - Handles aggregation functions (count, sum, avg, min, max)
  - Applies WHERE predicates after WITH projection
  - Integrates seamlessly between MATCH and RETURN stages
- **Tests**: tests/e2e_with_clause.zig
- **ISO Reference**: 14.5

### Deterministic Shortest Path Selection (REQ-GQL-019)
- **Location**: src/server/graph/exec.zig (enhanced pathExpand)
- **Features**:
  - Modified BFS traversal to collect all paths at minimal depth
  - Deterministic tie-breaking when multiple shortest paths exist
  - Applies UA005/UA006 policy: (length, start_id, end_id, intermediate_ids)
  - Ensures consistent results across multiple executions
- **Tests**: tests/unit_shortest_path_tiebreak.zig
- **ISO Reference**: 22.4, UA005/UA006
