# GQL implementation gap analysis (authoritative ledger)

This file tracks requirements against ISO/IEC 39075:2024 (GQL). It is evidence‑driven and idempotent.
We paraphrase ISO text and cite subclauses (e.g., 14.4 MATCH; 14.10 primitive result, ORDER BY & page;
16.18–16.19 pagination; 18.x types; 7 sessions; 23.2 diagnostics; 24 conformance). Quotes, if any,
are ≤25 words and include subclause anchors.

Legend for Status: Implemented | Partial | Missing | Blocked

Note: Completed/implemented items have moved to docs/IMPLEMENTED.md. This file lists only open gaps (Partial/Missing/Blocked).

## Requirements Ledger

| Requirement ID | Requirement (1–2 lines)                                                                                                 | Source (docs §, ISO)                       | Current Status | Evidence (file:line or test name)                                                                                          | Gap/Risk                                              | Deadline   | Owner | Notes                                                 |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ---------- | ----- | ----------------------------------------------------- |
| REQ‑GQL‑001    | Primitive result with ORDER BY & page: RETURN; ORDER BY ASC/DESC per key; LIMIT then OFFSET; obey US001 when unordered. | query_engine.md §3; ISO 14.10; 16.18–16.19 | Partial        | Tests: src/gql.zig “ORDER BY with ASC and DESC per key”; Planner tests: src/planner.zig “offset pushdown rejected/allowed” | Runtime evaluator only demos first key; multi‑key TBD | 2025‑09‑15 | core  | Parser/AST/printing done; planner policy enforced     |
| REQ‑GQL‑014    | Diagnostics mapping (codes) and conformance flagger.                                                                    | query_engine.md §8; ISO 23.2; 24.\*        | Missing        | —                                                                                                                          | Risk of drift and poor UX                             | 2025‑10‑31 | core  | Define codes (US001, GroupByIllegal, IllegalOrderKey) |
| REQ‑GQL‑015    | Parameters ($param) parsing/binding; substitution; tests.                                                               | query_engine.md §3.2; ISO 16.x             | Missing        | —                                                                                                                          | Needed for real apps                                  | 2025‑10‑15 | core  | Bind map in CLI/tests                                 |
| REQ‑GQL‑016    | Aggregation semantics (phase‑2): aggregate catalog (COUNT/SUM/MIN/MAX), HAVING evaluation.                              | query_engine.md §3.2; ISO 14.10            | Partial        | Planner legality tests exist; no eval                                                                                      | Feature incomplete                                    | 2025‑11‑15 | core  | Add eval + tests                                      |

## GQL Conformance Profile (Initial)

Scope: front-end (parser/AST/printers) plus selected planner policies; not a runtime/engine conformance claim.

| Clause/Feature (ID) | Name                                    | Supported?                            | Rationale                   | Engine implications (parser/planner/storage/protocol) | Test hook                               |
| ------------------- | --------------------------------------- | ------------------------------------- | --------------------------- | ----------------------------------------------------- | --------------------------------------- |
| 14.4                | MATCH / OPTIONAL MATCH                  | Yes (parse)                           | Core language               | Parser/AST/Printer; future planner legality           | src/gql.zig:40/380/401                  |
| 14.10               | Primitive result; ORDER BY & GROUP BY   | Yes (parse); Partial (group legality) | Needed for result shaping   | Parser/AST; planner ORDER policy                      | src/gql.zig:18/258/425                  |
| 16.18               | OFFSET                                  | Yes                                   | Pagination control          | Planner policy (US001)                                | src/planner.zig:105/119                 |
| 16.19               | LIMIT                                   | Yes                                   | Pagination control          | Exec top-k harness                                    | src/gql.zig:18; src/exec.zig:55         |
| 14.12               | SELECT desugaring; UNION                | Yes (parse)                           | Set composition             | Parser/AST; dedup TBD                                 | src/gql.zig:280/332                     |
| Set ops (Annex)     | INTERSECT / EXCEPT                      | Yes (parse)                           | Completeness                | Parser/AST; semantics later                           | src/gql.zig:353                         |
| 16.x                | Expressions incl. CASE and string preds | Yes (parse)                           | Usability                   | Parser/AST                                            | src/gql.zig:62/239                      |
| 18.x                | Temporal types (DATE/TIME/DATETIME)     | Yes                                   | Interop, ORDER BY stability | Parser; temporal module; planner                      | src/temporal.zig tests; src/exec.zig:55 |
| 23.2                | Diagnostics                             | No (planned)                          | Protocol integration        | Diagnostics layer                                     | —                                       |
| 24.\*               | Conformance                             | Doc-only                              | Documentation               | GAP + Profile                                         | This file                               |

### Profile Notes

- US001 (implementation-dependent ordering when paginating unordered tables) is documented and enforced in planner policy checks (ISO 16.18–16.19).
- UA005/UA006 (path tie-breaking) will be documented with chosen deterministic policy when path search is added.
- Set‑ops ordering policy (impl‑defined, documented): DISTINCT variants return deterministically sorted rows (lexicographic by value types: Null < Bool < Int < Str; row‑wise), ALL variants preserve stable‑left (left input) order while honoring multiplicities.
