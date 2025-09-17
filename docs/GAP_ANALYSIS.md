# GAP Analysis — geode v0.15.0 (ISO/IEC 39075:2024 GQL)

This is the authoritative conformance and scope ledger. Each requirement uses ID REQ‑GQL‑### and cites
ISO subclauses. Evidence points to concrete files/lines or tests. Quotes from ISO, if any, are ≤25 words
with subclause anchors.

## Requirements Ledger

| Requirement ID | Requirement (1–2 lines) | Source (ISO subclause) | Current Status | Evidence (file:line or test) | Gap / Risk | Deadline | Owner | Notes |
|---|---|---|---|---|---|---|---|---|
| REQ‑GQL‑001 | Wire protocol processes: geoded (server), geodec (CLI); JSON frames HELLO/RUN_GQL/PULL/BEGIN/COMMIT/ROLLBACK | ISO 7 (sessions), 23.2 (diagnostics) | Implemented | src/server/main.zig:1675-1800 (handleFrame); src/client/main.zig; tests/e2e_protocol.zig, tests/e2e_hello_ping.zig | Backpressure/batching TBD | 2025‑09‑30 | wire | Default JSON; TXT optional |
| REQ‑GQL‑002 | HELLO advertises capabilities and conformance profile basics | ISO 24 (conformance) | Implemented | src/server/main.zig:1681-1700 (.HELLO emits caps+conformance); tests/e2e_hello_ping.zig | Health/caps extensions later | 2025‑10‑07 | wire | Include flagger when non‑standard |
| REQ‑GQL‑003 | Transactions: BEGIN/COMMIT/ROLLBACK with session state | ISO 7, 8 (transactions) | Implemented | src/server/main.zig:1761-1800 (.BEGIN/.COMMIT/.ROLLBACK); tests/e2e_protocol_transactions.zig, tests/e2e_protocol_txn_serialization_failure.zig | Isolation error matrix pending | 2025‑10‑21 | txn | 25000 status mapping present |
| REQ‑GQL‑004 | RUN_GQL: RETURN; ORDER BY; LIMIT/OFFSET legality (US001 rejection) | ISO 14.3, 16.16–16.19, 23.2 | Partial | src/server/main.zig:932-1224 (evaluateSimpleQuery); tests/e2e_protocol_multidiag_precedence.zig | Missing MATCH patterns | 2025‑10‑21 | planner | No graph traversal |
| REQ‑GQL‑005 | Set operations: UNION DISTINCT/ALL; INTERSECT/EXCEPT DISTINCT/ALL | ISO 16.10–16.12 | Implemented | src/server/main.zig:1323-1400 (evaluateUnion); tests/e2e_setops_all.zig, tests/e2e_setops_intersect_except.zig | Further perf tuning later | 2025‑11‑04 | engine | Unordered output |
| REQ‑GQL‑006 | EXPLAIN/PROFILE frames; flagger findings | ISO 24, 23.2 | Implemented | src/server/main.zig:1700-1750 (EXPLAIN/PROFILE emission); tests e2e_protocol_profile_*.zig | Freeze schema versioning | 2025‑10‑28 | engine | profile_version=2 present |
| REQ‑GQL‑007 | Core value types: INT, BOOL, STRING, DECIMAL | ISO 18.6–18.8 | Implemented | src/server/main.zig; eval paths; tests/e2e_protocol_decimal_*.zig | Temporal/spatial later | 2025‑11‑18 | eval | 3VL covered in CASE |
| REQ‑GQL‑008 | CASE expression (searched) with 3‑valued logic | ISO 17.7, 18.3 | Implemented | tests/e2e_protocol.zig:116–132 | Add simple CASE parity | 2025‑11‑18 | eval | |
| REQ‑GQL‑009 | DISTINCT projection | ISO 16.9 | Implemented | src/server/main.zig:1100-1150 | Memory use under high dupes | 2025‑10‑28 | engine | Canonicalization for DECIMAL |
| REQ‑GQL‑010 | Diagnostics precedence and folding; US001 aggregation | ISO 23.2; 16.16–16.19 | Implemented | src/diagnostics.zig:55-76; tests/e2e_protocol_multidiag_*.zig | Add mapping table to docs | 2025‑10‑14 | diag | |
| REQ‑GQL‑011 | QUIC transport with TLS 1.3 | Security requirements | Implemented | src/transport/quic.zig; server QUIC listen (src/server/main.zig); tools/cert_gen.zig | Cipher suite audit later | 2025‑10‑21 | wire | QUIC default |
| REQ‑GQL‑012 | WAL checkpoints/compaction hooks | ISO 8 (transactions) | Partial | src/wal/wal.zig; COMMIT/autocommit writes checkpoint | ARIES completeness | 2025‑11‑25 | storage | Recovery exists |
| REQ‑GQL‑013 | MVCC (SI baseline) | ISO 8 | Partial | src/server/main.zig:200-250 (TxnState); session snapshot, commit_ts | Conflict detection missing | 2025‑11‑04 | txn | Write-write conflicts undetected |
| REQ‑GQL‑014 | MATCH patterns: node/edge traversal | ISO 14.4, 22 (graph patterns) | Not Implemented | Parser recognizes (gql/parser.zig); no execution | Core graph feature missing | 2025‑11‑25 | core | Critical gap |
| REQ‑GQL‑015 | OPTIONAL MATCH: left-outer semantics | ISO 14.4 | Not Implemented | Parser recognizes; no execution | Depends on MATCH | 2025‑12‑02 | core | |
| REQ‑GQL‑016 | Path patterns: variable-length traversal | ISO 22.4 | Not Implemented | No PathExpand operator | Limits expressiveness | 2025‑12‑02 | core | |
| REQ‑GQL‑017 | Property access: n.name syntax | ISO 4.3 (property graph model) | Not Implemented | Parser supports; no execution | Property model missing | 2025‑11‑25 | core | |
| REQ‑GQL‑018 | Node/edge labels and filtering | ISO 4.3, 22 | Not Implemented | No label-based filtering | Core graph feature | 2025‑11‑25 | core | |
| REQ‑GQL‑019 | Graph mutations: CREATE/DELETE/MERGE | ISO 15 (data modification) | Not Implemented | Not parsed or executed | DML not in scope yet | 2026‑01‑15 | dml | |
| REQ‑GQL‑020 | WITH clause: query chaining | ISO 14.5 | Not Implemented | Not parsed | Query composition limited | 2025‑12‑15 | planner | |
| REQ‑GQL‑025 | Storage catalog persistence (catalog, adjacency) | impl‑defined storage mgmt | Partial | src/storage/catalog.zig; tests/e2e_catalog_persistence.zig | Missing --data_dir, CSR adjacency | 2025‑11‑25 | storage | |
| REQ‑GQL‑027 | MVCC conflict detection completion | ISO 8 | Partial | Basic timestamps only | No write-write detection | 2025‑11‑04 | txn | Data consistency risk |
| REQ‑GQL‑028 | Distributed scaffold: Raft (leader only) | impl‑defined distribution | Stubbed | src/distributed/raft.zig; single-node only | No actual distribution | 2025‑12‑31 | dist | Feature‑flagged |
| REQ‑GQL‑042 | Distributed scaffold: 2PC coordinator | ISO 8 (distributed txn) | Stubbed | src/distributed/twophase.zig | Network handlers missing | 2025‑12‑31 | dist | Feature‑flagged |
| REQ‑GQL‑043 | Distributed integration with server | ISO 24 | Partial | CLI flags present; no actual distribution | Single-node only | 2025‑12‑31 | dist | |
| REQ‑GQL‑050 | Text format output for SCHEMA/BINDINGS/EXPLAIN/PROFILE | ISO 4.3.6 (binding tables) | Implemented | src/client/main.zig text paths; tests in e2e_protocol.zig | Text profile parity later | 2025‑10‑21 | cli | |

Notes: 
- I: implementation‑defined; U: implementation‑dependent
- Critical gaps: MATCH patterns (REQ‑GQL‑014), property model (REQ‑GQL‑017), path traversal (REQ‑GQL‑016)
- The system currently implements a SQL-like subset of GQL without core graph features

## GQL Conformance Profile

| Feature ID | ISO Subclause | Name | Claimed | Actual | Evidence | Notes |
|---|---|---|---|---|---|---|
| Core | 14.3–14.4 | Linear queries; RETURN | Yes | Partial | e2e_protocol.zig | No MATCH execution |
| Core | 14.4 | MATCH patterns | Yes | No | Parser only | **Critical gap** |
| Core | 14.4 | OPTIONAL MATCH | Yes | No | Parser only | Depends on MATCH |
| Core | 22 | Graph patterns | Yes | No | No execution | **Core feature missing** |
| Core | 4.3 | Property graph model | Yes | No | No property access | **Fundamental gap** |
| Core | 16.16–16.19 | ORDER BY + PAGE | Yes | Yes | multidiag tests | US001 enforced |
| GQ03 | 16.10 | UNION | Yes | Yes | union tests | DISTINCT/ALL working |
| GQ04/05 | 16.11 | EXCEPT | Yes | Yes | except tests | DISTINCT/ALL working |
| GQ06/07 | 16.12 | INTERSECT | Yes | Yes | intersect tests | DISTINCT/ALL working |
| Core | 17.7 / 18.3 | CASE; 3VL | Yes | Yes | CASE test | Working |
| Core | 18.6–18.8 | Numeric core | Yes | Yes | decimal tests | INT/DECIMAL/BOOL |
| Core | 23.2 | Diagnostics | Yes | Yes | multidiag tests | ISO mapping complete |
| Core | 24 | Conformance profile | Partial | Partial | HELLO frame | Flagger present |
| G060 | 22.4 | Bounded path quantifiers | No | No | Not implemented | Deferred |
| Core | 15 | Data modification | No | No | Not implemented | CREATE/DELETE/MERGE missing |
| Core | 14.5 | WITH clause | No | No | Not implemented | Query chaining missing |

**Summary**: The implementation claims GQL conformance but lacks fundamental graph database features. It successfully implements:
- SQL-like query operations (RETURN, ORDER BY, LIMIT, set operations)
- Transaction management
- Diagnostics and profiling
- Storage layer basics

But critically missing:
- **Graph pattern matching** (MATCH clause execution)
- **Property graph model** (node/edge properties, labels)
- **Graph traversal** (path patterns, variable-length)
- **Graph mutations** (CREATE, DELETE, MERGE)

## Implementation-Defined/Dependent Behaviors

| ID | ISO Reference | Behavior | Current Policy | Evidence |
|---|---|---|---|---|
| US001 | 16.16–16.19 | Order for OFFSET on unordered tables | Rejected with diagnostic | src/server/main.zig:442-477 |
| UA005 | 22.4 | Path selection tie-break (shortest) | Not implemented | No path execution |
| UA006 | 22.4 | Path selection tie-break (any) | Not implemented | No path execution |
| UA002 | 23.2 | Multiple diagnostic precedence | Lower code wins | src/diagnostics.zig:55-76 |
| I:ORDER | 14.10 | ORDER BY key restrictions | Identifiers only (default) | e2e_order_policy_toggle.zig |
| I:NULLS | 16.17 | NULL ordering | NULLS FIRST (configurable) | GEODE_NULLS_LAST env var |
| I:COLLATION | 18.x | String collation | Binary comparison | No Unicode collation |
| I:DECIMAL | 18.8 | Decimal canonicalization | Normalized form | e2e_protocol_decimal.zig |

## Risk Assessment

### Critical Risks (P0)
1. **No Graph Database Core**: System cannot execute MATCH patterns or traverse graphs - fundamental requirement missing
2. **False Conformance Claims**: Documentation claims GQL conformance but lacks essential graph features
3. **MVCC Conflicts**: Write-write conflicts undetected, risking data consistency

### High Risks (P1)
1. **Storage Persistence**: No durable catalog or adjacency structures
2. **Property Model**: Cannot access node/edge properties
3. **Path Operations**: No variable-length traversal capability

### Medium Risks (P2)
1. **Distribution**: Single-node only, no scale-out path
2. **Query Composition**: No WITH clause for complex queries
3. **Graph Mutations**: No CREATE/DELETE/MERGE operations

## Recommendations

1. **Immediate**: Update documentation to accurately reflect that this is a SQL-like query engine with GQL syntax parsing, not a graph database
2. **Short-term**: Implement basic MATCH pattern execution with NodeScan and Expand operators
3. **Medium-term**: Add property graph model with label and property filtering
4. **Long-term**: Complete graph traversal, mutations, and distributed execution