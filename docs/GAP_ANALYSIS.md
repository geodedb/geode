# GAP Analysis — geode v0.15.0 (ISO/IEC 39075:2024 GQL)

This is the authoritative conformance and scope ledger. Each requirement uses ID REQ‑GQL‑### and cites
ISO subclauses. Evidence points to concrete files/lines or tests. Quotes from ISO, if any, are ≤25 words
with subclause anchors.

## Requirements Ledger

|| Requirement ID | Requirement (1–2 lines) | Source (research § / query_engine § and ISO) | Current Status | Evidence (file:line or test) | Gap / Risk | Deadline | Owner | Notes |
||---|---|---|---|---|---|---|---|---|
|| REQ‑GQL‑001 | Wire protocol processes: geoded (server), geodec (CLI); JSON frames HELLO/RUN_GQL/PULL/BEGIN/COMMIT/ROLLBACK | query_engine.md §Wire; ISO 7 (sessions), 23.2 (diagnostics) | Implemented | src/server/main.zig (.HELLO/.RUN_GQL/.PULL/.BEGIN/.COMMIT/.ROLLBACK); QUIC and stdio share processMessage; src/client/main.zig; tests/e2e_protocol.zig, tests/e2e_hello_ping.zig | Backpressure/batching TBD | 2025‑09‑30 | wire | Default JSON; TXT optional |
|| REQ‑GQL‑002 | HELLO advertises capabilities and conformance profile basics | query_engine.md §Wire; ISO 24 (conformance) | Implemented | src/server/main.zig (.HELLO emits caps+conformance digest/features); tests/e2e_hello_ping.zig | Health/caps extensions later | 2025‑10‑07 | wire | Include flagger when non‑standard |
|| REQ‑GQL‑003 | Transactions: BEGIN/COMMIT/ROLLBACK with session state | ISO 7, §8 | Implemented | src/server/main.zig (.BEGIN/.COMMIT/.ROLLBACK); tests/e2e_protocol_transactions.zig, tests/e2e_protocol_txn_serialization_failure.zig | Isolation error matrix pending | 2025‑10‑21 | txn | 25000 status mapping present |
|| REQ‑GQL‑004 | RUN_GQL: RETURN; ORDER BY; LIMIT/OFFSET legality (US001 rejection) | ISO 14.3, 16.16–16.19, 23.2 | Implemented | src/server/main.zig (.RUN_GQL parse+legality; US001 guard; --order-keys expr policy); tests/e2e_protocol_multidiag_precedence.zig, tests/e2e_order_policy_toggle.zig | Configurable policy toggle later | 2025‑10‑21 | planner | Policy: identifiers‑only keys (I:) default; expr allowed with flag |
|| REQ‑GQL‑005 | Set operations: UNION DISTINCT/ALL; INTERSECT/EXCEPT DISTINCT/ALL | ISO 16.10–16.12 | Implemented | src/server/main.zig (UNION path; evaluateBinarySet for INTERSECT/EXCEPT); tests/e2e_setops_all.zig, tests/e2e_setops_mixed_nulls.zig, tests/e2e_explain_setops.zig, tests/e2e_setops_intersect_except.zig | Further perf tuning later | 2025‑11‑04 | engine | Unordered output |
|| REQ‑GQL‑006 | EXPLAIN/PROFILE frames; flagger findings | query_engine.md §Explain/Profile; ISO 24, 23.2 | Implemented | src/server/main.zig (EXPLAIN/PROFILE emission); tests e2e_protocol_profile_*.zig | Freeze schema versioning | 2025‑10‑28 | engine | profile_version=2 present |
|| REQ‑GQL‑007 | Core value types: INT, BOOL, STRING, DECIMAL | ISO 18.6–18.8 | Implemented | src/server/main.zig; eval paths; tests/e2e_protocol_decimal_*.zig | Temporal/spatial later | 2025‑11‑18 | eval | 3VL covered in CASE |
|| REQ‑GQL‑008 | CASE expression (searched) with 3‑valued logic | ISO 17.7, 18.3 | Implemented | tests/e2e_protocol.zig:116–132 | Add simple CASE parity | 2025‑11‑18 | eval | |
|| REQ‑GQL‑009 | DISTINCT projection | ISO 16.9 | Implemented | src/server/main.zig | Memory use under high dupes | 2025‑10‑28 | engine | Canonicalization for DECIMAL |
|| REQ‑GQL‑010 | Diagnostics precedence and folding; US001 aggregation | ISO 23.2; 16.16–16.19 | Implemented | src/server/main.zig; tests/e2e_protocol_multidiag_*.zig | Add mapping table to docs | 2025‑10‑14 | diag | |
|| REQ‑GQL‑011 | QUIC transport with TLS 1.3 | query_engine.md §Transport; Security | Implemented | src/transport/quic.zig; server QUIC listen (src/server/main.zig); tools/cert_gen.zig | Cipher suite audit later | 2025‑10‑21 | wire | QUIC default |
|| REQ‑GQL‑012 | WAL checkpoints/compaction hooks | Storage/WAL; ISO §8 | Partial | src/wal/wal.zig; COMMIT/autocommit writes checkpoint and compacts per GEODE_WAL_COMPACT_INTERVAL | ARIES completeness | 2025‑11‑25 | storage | Recovery exists |
|| REQ‑GQL‑013 | MVCC (SI baseline) | ISO §8 | Partial | src/txn/manager.zig; server txn usage (session snapshot, commit_ts) | Conflict matrix pending | 2025‑11‑04 | txn | |
|| REQ‑GQL‑025 | Storage catalog persistence (catalog, adjacency) | impl‑defined storage mgmt | Partial | src/storage/catalog.zig; src/storage/page_manager.zig; tests/e2e_catalog_persistence.zig | Implement --data_dir and on-disk save/load; adjacency CSR later | 2025‑11‑25 | storage | |
|| REQ‑GQL‑028 | Distributed scaffold: Raft (leader only) with feature flag | research.md §6; ISO out‑of‑scope for wire | Implemented | src/distributed/raft.zig; src/distributed/mod.zig (start/tick/status); tests in file | Heartbeat tuning; callbacks | 2025‑10‑14 | dist | Leader in single‑node |
|| REQ‑GQL‑042 | Distributed scaffold: 2PC coordinator interfaces | research.md §6; ISO §8 (txn) | Implemented | src/distributed/twophase.zig; mod.zig begin/commit/abort; tests in file | Network handlers stubbed | 2025‑10‑21 | dist | Feature‑flagged |
|| REQ‑GQL‑043 | Distributed integration with server: CLI/env, HELLO caps, tests | query_engine.md §Wire; ISO 24 | Implemented | src/server/main.zig (CLI/env flags; HELLO caps); tests/e2e_distributed.zig | Health endpoint later | 2025‑10‑14 | dist | Client forwards flags in stdio |
|| REQ‑GQL‑050 | Text format output for SCHEMA/BINDINGS/EXPLAIN/PROFILE | ISO 4.3.6 (binding tables) | Implemented | src/client/main.zig text paths; tests text format in e2e_protocol.zig | Text profile parity later | 2025‑10‑21 | cli | |

Notes: I: implementation‑defined; U: implementation‑dependent. Policy samples: ORDER keys ident‑only (I:), NullsFirst vs Last (I: flag), US001 enforced (U: policy disclosed). HELLO now includes conformance digest and features; ORDER key toggle scaffold present in tests.

## GQL Conformance Profile (Initial)

|| Feature ID | Name | Supported? | Rationale | Engine Implications (parser / planner / storage / protocol) | Test Hook |
||---|---|---|---|---|---|
|| 14.3–14.4 | Linear queries; RETURN | Yes | Milestone‑1 minimum | Lexer/Parser/Executor; BINDINGS; RUN_GQL | e2e_protocol Valid ORDER/LIMIT |
|| 16.16–16.19 | ORDER BY + PAGE | Yes | Pagination legality | Planner legality + diagnostics; ordered metadata | multidiag precedence test |
|| 16.10–16.12 | UNION | Yes (DISTINCT/ALL) | Basic set ops | Merge + dedup; unordered output | union tests |
|| 17.7 / 18.3 | CASE; 3VL | Yes | Usability baseline | Eval/type rules; JSON emit | CASE test |
|| 18.6–18.8 | Numeric core | Yes | Required | Type coercion; decimal canonicalization | decimal tests |
|| 23.2 | Diagnostics | Partial | Catalog present | additional_statuses; precedence folding | multidiag tests |
|| 24.* | Conformance profile & flags | Partial | Disclosure baseline | Flagger in frames; docs tables | flags tests |
|| G060 | Bounded path quantifiers | No | Deferred | PathExpand later | cutline |

Profile disclosures (I:/U:): Collation=binary (I:), ORDER key policy ident‑only (I:), NullsLast via env (I:), US001 rejection (U: policy disclosed), Decimal key canonicalization (I:).
