# GAP_ANALYSIS — ISO‑GQL requirements ledger (authoritative)

Legend for Status: Implemented | Partial | Missing | Blocked

All assertions cite ISO/IEC 39075:2024 subclauses; quotes, if any, are ≤25 words with anchors.

## Requirements Ledger

| Requirement ID | Requirement (1–2 lines) | Source (docs §, ISO) | Current Status | Evidence (file:line or test name) | Gap/Risk | Deadline | Owner | Notes |
| -------------- | ------------------------ | -------------------- | -------------- | ---------------------------------- | -------- | -------- | ----- | ----- |
| REQ‑GQL‑001 | Primitive result with ORDER BY and page: RETURN; ORDER BY per key; LIMIT then OFFSET; enforce US001 for unordered inputs. | query_engine.md §3; ISO 14.10; 16.18–16.19 | Implemented | tests/e2e_protocol.zig; src/planner.zig; src/diagnostics.zig | End‑to‑end over protocol pending | 2025‑09‑15 | core | ordered flag + order_keys must be surfaced via protocol |
| REQ‑GQL‑002 | Linear query statements: MATCH/OPTIONAL over binding tables. | query_engine.md §2; ISO 14.4 | Implemented | src/gql/parser.zig; src/gql/ast.zig; src/gql/print.zig | OPTIONAL legality checks in planner to expand | 2025‑09‑30 | core | |
| REQ‑GQL‑003 | Set operations: UNION [ALL|DISTINCT], INTERSECT, EXCEPT parse; semantics policy documented. | query_engine.md §3.1; ISO 14.12 | Implemented | tests/e2e_protocol_more.zig; src/gql/parser.zig | Runtime via protocol not yet wired | 2025‑10‑15 | core | DISTINCT deterministic; ALL stable‑left (I_) |
| REQ‑GQL‑004 | Expressions: arithmetic, comparisons, boolean, IN/NOT IN, IS [NOT] NULL; precedence incl. chained NOT. | query_engine.md §2; ISO 16.x | Implemented | src/eval.zig; unit tests | — | 2025‑09‑10 | core | |
| REQ‑GQL‑005 | CASE (simple/searched) with 3VL. | query_engine.md §2; ISO 16.x | Implemented | src/eval.zig; tests | — | 2025‑09‑20 | core | |
| REQ‑GQL‑006 | String predicates STARTS WITH, ENDS WITH, CONTAINS. | query_engine.md §2; ISO 16.x | Implemented | src/eval.zig | — | 2025‑09‑25 | core | |
| REQ‑GQL‑007 | Regex operator =~ with anchors and wildcard subset. | query_engine.md §3.1; ISO 16.x | Implemented | src/eval.zig | Alternation/grouping not supported | 2025‑09‑05 | core | subset noted |
| REQ‑GQL‑008 | Temporal literals DATE/TIME/DATETIME/LOCAL DATETIME parse/print JSON. | query_engine.md §2; ISO 18.x | Implemented | src/temporal.zig; tests | Temporal comparisons deferred | 2025‑10‑01 | core | |
| REQ‑GQL‑009 | ORDER BY key legality policy (ident‑only) and diagnostics mapping. | query_engine.md A1.1; ISO 14.10; 23.2 | Implemented | src/diagnostics.zig; src/planner.zig | — | 2025‑10‑31 | core | Policy I_ IllegalOrderKey |
| REQ‑GQL‑010 | US001 enforcement for pagination on unordered tables. | query_engine.md §3; ISO 16.18–16.19 | Implemented | src/planner.zig; tests/e2e_protocol.zig | Protocol surfacing missing | 2025‑09‑10 | core | U_US001 disclosed |
| REQ‑GQL‑011 | Alias/equality lookahead restricted to patterns. | research.md; ISO 14.4; 16.x | Implemented | src/gql/parser.zig | — | 2025‑09‑01 | core | |
| REQ‑GQL‑012 | Mixed‑type equality policy; TypeMismatch on cross‑type ordering. | query_engine.md; ISO 16.x; 23.2 | Implemented | src/eval.zig; src/diagnostics.zig | — | 2025‑09‑05 | core | I_ equality normalization |
| REQ‑GQL‑013 | CLI micro‑benchmarks. | USAGE.md; query_engine.md §4 | Implemented | src/gql/main.zig | — | 2025‑09‑01 | core | |
| REQ‑GQL‑014 | Diagnostics mapping + precedence + flagger. | query_engine.md A1.1; ISO 23.2; 24.* | Implemented | src/diagnostics.zig | Ensure precedence in protocol | 2025‑10‑31 | core | |
| REQ‑GQL‑015 | Parameters ($param) parse/bind. | query_engine.md §3.2; ISO 16.x | Implemented | src/gql/parser.zig; src/eval.zig | — | 2025‑10‑15 | core | |
| REQ‑GQL‑016 | Aggregation + GROUP BY legality + HAVING. | query_engine.md; ISO 14.10; 16.x | Implemented | src/planner.zig; tests/e2e_protocol_planner.zig | Protocol wiring pending | 2025‑11‑15 | core | |
| REQ‑GQL‑017 | Path tie‑break policy (UA005/UA006). | query_engine.md; UA005/UA006 | Implemented | src/planner.zig helpers | Path operators not yet in runtime | 2025‑12‑15 | core | U_ tiebreak (length,id) |
| REQ‑GQL‑018 | Conformance documentation per 24.* | ISO 24.* | Implemented | docs/CONFORMANCE_MATRIX.md; this file | Keep synchronized | 2025‑09‑01 | core | |
| REQ‑GQL‑023 | Processes geoded/geodec; JSON default; txt optional. | BINARY_PROTOCOL.md; ISO 24.* | Missing | src/server/main.zig; src/client/main.zig (stubs) | Network protocol absent | 2025‑12‑31 | core | |
| REQ‑GQL‑024 | Binary protocol: HELLO/BEGIN/COMMIT/ROLLBACK/RUN_GQL/PULL; statuses; SCHEMA/BINDINGS/EXPLAIN. | BINARY_PROTOCOL.md; ISO 23.2; 24.* | Missing | — | Precedence, ordered flag, order_keys, JSON Lines | 2026‑01‑15 | core | |
| REQ‑GQL‑025 | Storage engine baseline (slotted pages, CSR, property heap). | REQUIREMENTS.md §4; research.md | Missing | src/storage/* (sketches) | Persistence/scale blocked | 2026‑03‑31 | core | |
| REQ‑GQL‑026 | WAL/ARIES, page‑LSN, checkpoints, recovery. | REQUIREMENTS.md §4 | Missing | — | Durability blocker | 2026‑04‑30 | core | |
| REQ‑GQL‑027 | Transactions: MVCC (SI) + locks; demarcation. | REQUIREMENTS.md §4; ISO §8 | Missing | — | Correctness/visibility | 2026‑02‑28 | core | |
| REQ‑GQL‑028 | Distributed scaffold: Raft stub, 2PC, shard map. | REQUIREMENTS.md §6; research.md | Missing | — | Feature‑gated; single‑node first | 2026‑05‑31 | core | |
| REQ‑GQL‑029 | Docs: Conformance Profile + Diagnostics table with anchors. | ISO 24.*; 23.2 | Partial | docs/README.md; this file | Add README table; ensure CLI surfaces codes | 2025‑09‑15 | core | |

I_ = implementation‑defined; U_ = implementation‑dependent (ISO usage).

## GQL Conformance Profile (Initial)

Scope: front‑end (lexer/parser/AST/printers) and evaluator subset; planner/exec contracts documented. Not a full engine claim.

| Feature ID (Annex D / Clause) | Name | Supported? | Rationale | Engine implications (parser/planner/storage/protocol) | Test hook |
| ----------------------------- | ---- | ---------- | --------- | ----------------------------------------------------- | --------- |
| 14.4 | MATCH / OPTIONAL MATCH | Yes (parse) | Core surface | Parser/AST/Printer; planner legality later | src/gql/parser.zig tests |
| 14.10 | Primitive result; ORDER BY; GROUP BY/HAVING | Yes (parse+rules) | Result shaping & pagination | Parser/AST; planner ORDER policy (US001) | tests/e2e_protocol*.zig |
| 14.12 | SELECT and set operations | Yes (parse) | Set composition | Parser/AST; set‑op semantics documented (I_) | tests/e2e_protocol_more.zig |
| 16.x | Expressions incl. CASE, IN/NOT IN, IS… | Yes (subset eval) | Usability | Parser/AST; evaluator subset | unit tests; e2e CASE |
| 16.x | Regex operator =~ | Yes (subset) | Filtering | Evaluator simple matcher; no alt/group | unit tests |
| 18.x | Temporal literals | Yes | Interop | Parser/Printer; JSON verbose | unit tests |
| 16.18–16.19 | OFFSET & LIMIT | Yes | Pagination | Planner policy; US001 guard (U_) | tests/e2e_protocol.zig |
| 23.2 | Diagnostics | Yes | Protocol integration | diagnostics layer; precedence policy | src/diagnostics.zig |
| 24.* | Conformance | Doc‑only | Documentation | GAP ledger + profile maintained | this file |

Profile notes:
- U_US001: unordered pagination may introduce impl‑dependent order; we reject by default without explicit ORDER BY (16.18–16.19).
- UA005/UA006: deterministic path tie‑break policy (length, id) reserved; surfaced when path ops land.
- Set‑ops: DISTINCT deterministically sorted; ALL preserves stable‑left order (I_). 

Counts by Status (this run)
- Implemented: 18 • Partial: 1 • Missing: 6 • Blocked: 0

Top risks
- Protocol/server not implemented (REQ‑GQL‑023/024) blocks e2e flows.
- Durability (REQ‑GQL‑026) and MVCC (REQ‑GQL‑027) missing; cannot claim ACID.
- Storage baseline absent (REQ‑GQL‑025); executor limited to in‑memory demos.
- Distributed scaffold deferred (REQ‑GQL‑028); interface stability risk.
