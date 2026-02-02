# Wire Protocol Recommendation for a Production Graph Database

## Executive recommendation

Use a **dual-front-door protocol strategy**: make **gRPC over HTTP/2 + TLS 1.3** the primary external client protocol (port 443 by default), while keeping the existing **QUIC+TLS** endpoint as an optional “fast path” for environments where UDP is permitted and performance wins matter. This choice balances **enterprise network reachability** (proxies, L7/L4 load balancers, firewall policies) with **high-performance streaming** and a broad multi-language ecosystem. HTTP/2 provides multiplexed streams and flow control, while gRPC provides first-class deadlines/cancellation, streaming RPCs, and rich metadata for auth, tracing, and audit correlation. citeturn22search1turn22search2turn23search0turn23search0

Geode already documents a QUIC-only newline-delimited JSON protocol with a HELLO handshake, paginated result pulling, and explicit transaction control messages, plus an explicit note that it currently materializes full results before paging. That makes reachability and server memory pressure the two biggest protocol risks for production “real world networks.” citeturn9view0

Non-goals (confirmed): this recommendation **does not redesign MVCC/WAL** internals or **replace ISO GQL**; it defines the protocol surface that can faithfully expose those semantics. citeturn13search1turn16search1

## Requirements extracted from Geode documentation

The following table focuses on protocol-relevant semantics explicitly described in Geode documentation and the gaps implied by that surface.

| Requirement area | What Geode docs say (evidence) | Protocol implications |
|---|---|---|
| Multi-graph support and graph selection | Graphs are “named collections of nodes and relationships,” created via `CREATE GRAPH <name>` and selected via `USE <name>`. citeturn17view0 | Protocol must support **graph addressing** without relying solely on connection state: allow per-request graph, plus optional session default to preserve compatibility with `USE`. |
| Graph-scoped authorization and tenant isolation | Authorization includes RBAC/ABAC/RLS; examples show `GRANT SELECT ON GRAPH SocialNetwork …`, label/property-level grants, and tenant isolation policies based on session context variables (e.g., `SET session.tenant_id = 'tenant-123'`). citeturn7view3 | Protocol needs **identity propagation** + **graph identifier** on requests, and a clear mechanism for session context (tenant attributes) that feeds RLS. |
| Transport, encryption, and handshake | Current wire protocol: **“QUIC+TLS Only: No TCP fallback, mandatory encryption”**; newline-delimited JSON objects; HELLO/HELLO_ACK with `protocol_version` and `capabilities`. citeturn9view0 | If QUIC-only remains the sole endpoint, enterprise firewalls that block UDP ports become an availability risk; protocol design should separate “semantic protocol” from “transport binding,” and keep capability negotiation. |
| Request/response pattern and streaming semantics | Messages: `RUN_GQL`, `PULL`, `BEGIN/COMMIT/ROLLBACK`, `PING`. Results flow: `SCHEMA` then `BINDINGS` pages; max page size 10,000; ordering flags. Current behavior is “Full materialization, then paging” with “Future: Streaming execution with lazy materialization.” citeturn9view0 | Protocol must support **cursor-based streaming** with **backpressure**. A purely pull-based interface is fine, but should not require full result materialization. Add explicit **CANCEL/CLOSE_CURSOR** semantics (not currently documented in the message set). citeturn9view0 |
| Transaction surface (MVCC/SSI, isolation levels, conflicts) | Geode describes MVCC + Serializable Snapshot Isolation (SSI), and lists 6 isolation levels in features plus wire-protocol isolation enumerations (including SNAPSHOT, SERIALIZABLE, STRICT_SERIALIZABLE). citeturn16search1turn9view0 Transaction conflict/serialization failures appear as documented error categories and internal codes (e.g., `ERR_SERIALIZATION_FAILURE`, `ERR_TRANSACTION_CONFLICT`) with retry guidance. citeturn10view0turn12view0 | Protocol needs a **transaction state machine** with explicit tx IDs, savepoints (documented as feature), and stable error mapping that lets clients implement deterministic retry policies. citeturn16search1turn10view0turn12view0 |
| Indexing and index-aware planning | Docs emphasize broad index families, cost-based optimization, EXPLAIN/PROFILE support in protocol and features. citeturn9view0turn13search1turn16search1 Operationally, statistics procedures and index analyze are exposed (e.g., `CALL db.index.analyze(...)`). citeturn11view0 Migration guide notes non-blocking index creation, index build timeouts, and progress/status via `SHOW INDEX BUILD STATUS`, plus `REINDEX DATABASE`. citeturn13search0 | Protocol should support both (a) pure “run GQL” for index DDL and (b) optional structured admin RPCs that expose async build job IDs, status/progress, and cancellation. |
| WAL durability, PITR, backup/restore operations | Docs highlight WAL for point-in-time recovery; backup guides describe full/incremental backups and PITR applying WAL up to a timestamp; operational tooling uses CLI commands (`geode backup`, `geode restore`). citeturn13search1turn18search2turn13search0 | Protocol should treat backup/PITR as **privileged admin operations** (separate service/role gating) and expose “job-like” semantics (start, status, logs). |
| CDC and replication hooks | Multi-datacenter guide describes **CDC replication** patterns, including sinks (Kafka) and consumer config; it also references backpressure/adaptive batching for CDC. citeturn21view0 Features overview claims CDC exists as a capability. citeturn16search1 | Even if Kafka is the common substrate, the protocol should define a **CDC stream contract** (events with ordering identifiers, resume checkpoints) so replication hooks aren’t protocol-undefined. |
| Observability, auditability, tracing IDs | Metrics reference describes multiple access methods including Prometheus `/metrics` and an Admin API; it includes per-client statistics (client_id, user, IP) and WAL metrics. citeturn11view0 AuthZ/AuthN docs show audit logs including a `trace_id`. citeturn7view3turn8view0 | Protocol must carry **request_id/trace_id** end-to-end (client → server logs/audit → response). Prefer transports with standardized metadata propagation. |
| Client ecosystem and real-world network constraints | Geode positions QUIC transport and multiple official client libraries, but also documents operational troubleshooting: “Check firewall allows UDP port 3141.” citeturn9view0turn8view0 | High reliability across enterprise networks generally favors a TCP/443 option; QUIC remains valuable as an optimization lane. (The “UDP is often restricted” aspect is a practical deployment risk; Geode’s own troubleshooting guidance shows this is a first-order concern.) citeturn9view0 |

## Protocol options and scored shortlist

### Candidate families and primary specifications

**Custom binary protocol over QUIC (raw QUIC streams)**  
QUIC provides multiplexed streams, flow control, and connection migration; secured via TLS 1.3 as profiled for QUIC. citeturn22search0turn23search1turn23search0

**gRPC over HTTP/2 with Protobuf**  
gRPC is specified as an application protocol carried over HTTP/2 framing; HTTP/2 provides multiplexing and connection-level flow control. Protobuf defines the binary wire format and schema evolution rules. citeturn22search2turn22search1turn24search0turn24search4

**HTTP/JSON (REST-ish) + WebSocket for streaming**  
JSON is standardized as RFC 8259; WebSocket provides frame-based full-duplex messaging over TCP with an HTTP upgrade handshake. citeturn24search2turn23search2

**Reuse an existing graph DB protocol (Bolt-like)**  
Bolt is a versioned, statement-oriented protocol typically over TCP or WebSocket; it defines a handshake and a typed value system layered above PackStream. citeturn23search3turn23search15turn23search7

**SQL wire protocol compatibility (PostgreSQL protocol)**  
PostgreSQL frontend/backend protocol is message-based over TCP with version negotiation and typed/binary encodings. citeturn22search3

### Scored comparison matrix

Scoring scale: 1 (poor) to 5 (excellent). Weights reflect “production reachability + correctness + performance,” assuming clients run behind typical enterprise controls and load balancers.

Weights:
- Network & ops fit (firewalls/LBs/proxies/debug) 0.20
- Client ecosystem & implementation cost 0.15
- Streaming/backpressure/multiplex/cancel 0.15
- Latency/throughput overhead 0.15
- Semantics fidelity (txns/indexes/multi-graph/error model) 0.15
- Security & identity integration 0.10
- Extensibility/version negotiation 0.10
- Observability correlation 0.05

| Option | Net/Ops | Ecosystem | Stream | Perf | Semantics | Sec | Ext | Obs | Weighted total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gRPC + HTTP/2 + Protobuf | 4.5 | 5.0 | 5.0 | 4.0 | 4.5 | 5.0 | 4.5 | 4.5 | **4.63** |
| Custom binary over QUIC | 2.5 | 3.0 | 5.0 | 5.0 | 5.0 | 5.0 | 4.0 | 3.0 | **4.03** |
| HTTP/JSON + WebSocket | 5.0 | 5.0 | 3.5 | 2.5 | 3.5 | 4.5 | 3.5 | 4.0 | **3.93** |
| PostgreSQL protocol compatibility | 4.0 | 5.0 | 4.0 | 4.0 | 2.5 | 4.0 | 2.5 | 3.5 | **3.66** |
| Bolt-like reuse | 3.5 | 3.5 | 4.5 | 4.0 | 3.5 | 4.0 | 3.5 | 3.0 | **3.73** |

**Sensitivity to weights (what flips the winner)**  
If you increase “Perf” weight materially (e.g., 0.30) and decrease “Net/Ops fit” (e.g., 0.05), the QUIC-native option can overtake gRPC because QUIC’s stream model and handshake characteristics are excellent for low-latency/high-throughput links. citeturn22search0turn23search1  
If you instead increase “Net/Ops fit” weight (common in regulated enterprise environments), gRPC/HTTP/2 dominates because it aligns with ubiquitous TCP/TLS deployment patterns while still providing multiplexed streams and flow control. citeturn22search1turn22search2

## Recommended protocol blueprint

### High-level architecture

**Goal:** preserve the semantics of Geode’s existing message model (HELLO / RUN_GQL / PULL / BEGIN / …) while improving (a) reachability and (b) true streaming execution (no full materialization requirement), and adding missing operational hooks (CDC stream contract, explicit cancellation).

**Recommendation:** define a single “Geode Protocol vNext” semantic spec, then bind it to two transports:

- **Primary transport:** gRPC over HTTP/2 over TLS 1.3 (default 443) citeturn22search2turn22search1turn23search0  
- **Optional transport:** QUIC+TLS (existing port), ideally migrating from NDJSON to a binary framing but keeping message semantics stable citeturn9view0turn22search0turn23search1

This aligns with Geode’s current “capabilities” negotiation model while addressing the explicit “no TCP fallback” constraint documented today. citeturn9view0

### Connection, auth, and capability negotiation

**Session establishment (conceptual flow)**  
This mirrors the current HELLO/HELLO_ACK pattern, but fits naturally into gRPC metadata and unary setup.

```
Client → Server: OpenSession( client_name, client_version, desired_protocol_version,
                             desired_capabilities, default_graph?, session_context? )
             + auth metadata (mTLS identity OR API key OR OAuth/OIDC token)
Server → Client: OpenSessionAck( server_version, negotiated_protocol_version,
                                 negotiated_capabilities,
                                 limits {max_page_rows, max_msg_bytes, ...},
                                 session_id, server_time )
```

Evidence that Geode already expresses protocol versioning/capabilities and mandates TLS: citeturn9view0  
Evidence that Geode supports multiple auth modes (password, API keys, OAuth2/OIDC, mTLS): citeturn8view0  
Evidence that audit events carry trace IDs (protocol should propagate these): citeturn7view3turn8view0

**Design choices**
- **Auth**: transport-level TLS 1.3 is mandatory; mTLS optional; application auth via per-RPC metadata is standard in gRPC. citeturn23search0turn22search2turn22search14  
- **Tracing**: require `trace_id` and `request_id` in metadata; the server must echo them in response metadata and include them in audit logs. Geode already shows `trace_id` in audit log examples. citeturn7view3turn8view0  
- **Version negotiation**: keep the existing `protocol_version` + `capabilities` handshake shape. citeturn9view0  
- **Limits**: send max page sizes and message limits early; Geode already documents max page rows (10k) in the QUIC protocol. citeturn9view0  

### Graph selection and graph-scoped authorization

Geode’s GQL surface uses `CREATE GRAPH` and `USE <graph>` for graph selection. citeturn17view0 Authorization is explicitly graph-scoped (`GRANT … ON GRAPH …`) and tenant isolation can depend on session variables. citeturn7view3

**Protocol requirements**
- Every request includes an explicit `graph` field (string or structured identifier), even if a session has a default.
- The server performs authorization checks against that graph namespace before executing the statement.
- Session context variables (tenant_id, department, clearance) must be set either:
  - via explicit protocol fields (`session_context` map) at session creation and update calls, and/or
  - via GQL `SET session.<key> = <value>` statements (maintain compatibility). citeturn7view3

### Query execution request/response and typed encoding

Geode’s current QUIC protocol sends `RUN_GQL` with `query`, `parameters`, and `mode` (NORMAL/EXPLAIN/PROFILE), and returns `SCHEMA` then pages of `BINDINGS`. citeturn9view0

**Recommended request (logical schema)**
- `Execute`:
  - `request_id`
  - `graph`
  - `gql` (string)
  - `params` (typed map)
  - `mode` = NORMAL | EXPLAIN | PROFILE
  - `timeout_ms` (server-side timeout)
  - `txn_id` (optional)
  - `idempotency_key` (optional; important for retries when the client cannot know if a network failure occurred after commit)

**Typed values**
- Prefer Protobuf for compactness and schema evolution. citeturn24search0turn24search4  
- Define a `Value` oneof covering at minimum:
  - null, bool, int64, double, string, bytes
  - decimal (string or scaled int + scale)
  - timestamp (int64 nanos + tz offset / zone)
  - interval/duration
  - json/jsonb (bytes + declared type)
  - vector (packed float32/float64/int32 with dimension metadata)
  - node/edge/path as structured types (because Geode is a property graph) citeturn17view0turn16search1  
- Maintain a stable `TypeDescriptor` space so new Geode types remain forward-compatible; Geode explicitly has a rich type system. citeturn17view0turn16search1

### Result streaming, pagination, flow control, cancellation, deadlines

Geode’s current protocol:
- is pull-driven via `PULL(page_size)`
- returns `BINDINGS(rows, final)`
- currently “full materialization, then paging,” with a stated future move to streaming execution. citeturn9view0

**Protocol blueprint**
- Treat each execution as creating a **server cursor** (implicit or explicit `cursor_id`).
- Server sends `ResultStart` (schema + metadata) then `RowBatch` frames.
- Client sends `Pull` messages granting credits:
  - `max_rows`
  - optionally `max_bytes` (to reduce oversized batches for large values)
- Cancellation:
  - Add `Cancel(cursor_id | request_id)` and a mandatory server response `Cancelled` (or an ERROR with a stable status).  
  - Rationale: the current published message set does not include a CANCEL message; relying on connection drop is a blunt instrument and complicates pooled connections. citeturn9view0
- Deadlines/timeouts:
  - In gRPC, enforce call deadlines plus server-side `timeout_ms`; server uses the smaller of the two. gRPC is designed for HTTP/2 transport and supports per-call metadata/deadlines in standard implementations. citeturn22search2turn22search22
- Backpressure:
  - HTTP/2 provides flow control at the transport level; QUIC provides flow-controlled streams. citeturn22search1turn22search0
  - The extra pull-credit layer expresses “rows” rather than only “bytes,” and works across both transports, matching Geode’s current PULL model. citeturn9view0

### Transaction state machine and error mapping

Geode exposes isolation levels and explicit transaction control, and documents retry-oriented errors (transaction conflicts, serialization failures). citeturn9view0turn10view0turn12view0

**State machine (logical)**
- `BeginTxn(isolation_level, read_only?, snapshot_hint?) → txn_id, snapshot_metadata`
- `Execute(..., txn_id=...) → cursor_id`
- `Commit(txn_id) → commit_metadata{commit_ts, commit_lsn?} | error`
- `Rollback(txn_id)`
- Savepoints (required by the stated feature set):
  - `Savepoint(txn_id, name)`
  - `RollbackToSavepoint(txn_id, name)`
  - `ReleaseSavepoint(txn_id, name)` citeturn16search1

**Errors**
- Use Geode’s documented structured error format: stable status class/code plus internal error identifiers where present. citeturn10view0turn12view0  
- Add protocol fields:
  - `retryable` boolean
  - `retry_after_ms` (optional)
  - `conflict_targets` (optional; for MVCC/SSI diagnostics)
- Keep ISO GQL status categories (transaction rollback classes, invalid txn state/termination, insufficient privilege). citeturn12view0turn7view3

### Admin/ops extensions: indexes, stats, CDC, backup/PITR

Geode already exposes metrics via procedures and a Prometheus endpoint, and references an Admin API. citeturn11view0 It also documents CDC replication patterns (Kafka sinks/consumers with backpressure controls). citeturn21view0 Backups/PITR are documented as operational workflows. citeturn18search2turn13search0

**Recommended protocol layering**
- **Query service** (common user path): sessions, execute, stream results, transactions.
- **Admin service** (privileged): index lifecycle, backup/restore, CDC subscriptions, health/config introspection.

**Indexes**
- Minimal requirement: support index operations via GQL statements and procedures (already implied). citeturn13search0turn11view0  
- Operationally better: add structured RPCs:
  - `CreateIndex(ddl | structured spec) → job_id`
  - `GetIndexBuildStatus(job_id)` (supports `SHOW INDEX BUILD STATUS`-like semantics)
  - `RebuildIndex(name)` / `ReindexDatabase` citeturn13search0

**CDC stream contract**
Even if Kafka remains the common sink, define a canonical event shape so replication hooks are stable:
- `SubscribeCdc(graph, from_checkpoint, include_before_image, include_metadata) → stream(ChangeEvent)`
- `ChangeEvent` fields: `checkpoint` (monotonic), `txn_id`, `commit_ts`, `operation`, entity identifiers, before/after images.
This directly reflects the CDC configuration options described (before-image, metadata, backpressure). citeturn21view0

**Backup/PITR**
- `StartBackup(mode=full|incremental, destination, compression, encryption) → job_id`
- `ListBackups(destination)`
- `Restore(backup_id, pitr_timestamp?) → job_id`
Geode documentation explicitly describes PITR as “apply WAL segments up to timestamp.” citeturn13search0turn18search2

## Migration and validation plan

### Migration path from the current Geode protocol

Geode currently documents a QUIC+TLS-only newline-delimited JSON protocol with protocol_version=1 and clear message shapes. citeturn9view0 A safe migration keeps those semantics stable while adding a second transport binding.

**Incremental rollout**
- **Phase one: semantic spec freeze**
  - Write a single canonical “execution semantics” spec (transactions, cursor lifecycle, error taxonomy) that both transports must implement.
  - Use the documented ISO-style status codes and internal error codes as the compatibility anchor. citeturn10view0turn12view0

- **Phase two: add gRPC/HTTP/2 endpoint**
  - Implement gRPC service that maps 1:1 to current message concepts: `HELLO`, `RUN_GQL`, `PULL`, `BEGIN`, etc. citeturn9view0turn22search2  
  - Expose it on TCP/443 and keep QUIC/3141 unchanged initially.

- **Phase three: capability-gated improvements**
  - Add true streaming execution (avoid full materialization) under a capability flag, since Geode already calls this out as future behavior. citeturn9view0  
  - Add explicit `CANCEL`/cursor-close semantics (new capability).

- **Phase four: operational APIs**
  - Promote structured admin operations (backup/PITR, CDC subscribe, index build status) behind RBAC roles like `admin`/`dba`. citeturn7view3turn18search2turn21view0

### Validation plan

Geode already provides benchmarking guidance and a “cross-client test harness” claim in features. citeturn16search1turn13search2 The protocol validation plan should directly target protocol-layer risks.

**Microbenchmarks (protocol costs)**
- Serialization/encoding throughput: NDJSON vs Protobuf message encoding for representative result sets (small scalar rows, nested graph values, large bytea/vector payloads). citeturn9view0turn24search0turn24search2  
- Round-trip counts: begin/execute/pull/commit under both transports; enforce “one schema frame then batches” invariant. citeturn9view0turn22search1turn22search0  
- Cancellation latency: time-to-stop execution after CANCEL; verify resource cleanup and cursor invalidation.

**Macrobenchmarks (workload realism)**
- OLTP-ish: high concurrency short traversals + point lookups with index usage (validate P99 latencies and conflict retry behavior). citeturn16search1turn10view0turn11view0  
- Bulk read: large ordered scans with pagination; validate memory plateau (no full materialization). citeturn9view0  
- Bulk ingest: batched writes inside explicit transactions; validate WAL pressure and CDC output rate metrics. citeturn11view0turn21view0  

**Compatibility and robustness**
- Cross-language conformance suite: golden tests for wire encoding, error mapping, transaction state machine, and graph-scoped permission failures. citeturn10view0turn7view3turn16search1  
- Decoder fuzzing: Protobuf decoding fuzz + JSON parser fuzz; ensure unknown-field tolerance (forward compatibility) and strict size limits to reduce DoS risk. citeturn24search0turn24search2  
- Security review checklist: TLS 1.3 configuration, mTLS identity mapping, audit log completeness (trace_id propagation), and least-privilege role coverage across admin endpoints. citeturn23search0turn8view0turn7view3

## References

Geode documentation (accessed 2026-02-02)

- Geode wire protocol specification (QUIC+TLS-only, NDJSON framing, HELLO/RUN_GQL/PULL, materialization vs streaming note). citeturn9view0  
- Geode data model and graphs (`CREATE GRAPH`, `USE`). citeturn17view0  
- Geode security: authentication mechanisms (password, API keys, OAuth2/OIDC, mTLS) and audit events. citeturn8view0  
- Geode authorization: RBAC/ABAC/RLS, graph-scoped grants, tenant isolation patterns, audit log example with `trace_id`. citeturn7view3  
- Geode error codes (transaction conflict/serialization failures and retry guidance). citeturn10view0  
- Geode ISO GQL status code categories and transaction rollback semantics. citeturn12view0  
- Geode metrics and observability (procedures, Prometheus `/metrics`, Admin API mention, WAL metrics). citeturn11view0  
- Geode backup and PITR workflows (full/incremental backup, restore, PITR with WAL replay). citeturn18search2turn13search0  
- Geode multi-datacenter patterns including CDC replication and backpressure controls. citeturn21view0  

Internet standards and protocol specifications (accessed 2026-02-02)

- QUIC transport: Iyengar, J., & Thomson, M. “QUIC: A UDP-Based Multiplexed and Secure Transport” (RFC 9000, DOI: 10.17487/RFC9000). citeturn22search0turn22search28  
- QUIC security: Thomson, M., & Turner, S. “Using TLS to Secure QUIC” (RFC 9001, DOI: 10.17487/RFC9001). citeturn23search1turn23search13  
- TLS 1.3: Rescorla, E. “The Transport Layer Security (TLS) Protocol Version 1.3” (RFC 8446, DOI: 10.17487/RFC8446). citeturn23search0turn23search8turn23search20  
- HTTP/2: “HTTP/2” (RFC 9113, DOI: 10.17487/RFC9113). citeturn22search1turn22search13  
- WebSocket: Fette, I., & Melnikov, A. “The WebSocket Protocol” (RFC 6455, DOI: 10.17487/RFC6455). citeturn23search2turn23search38  
- JSON: Bray, T. “The JavaScript Object Notation (JSON) Data Interchange Format” (RFC 8259, DOI: 10.17487/RFC8259). citeturn24search2turn24search10  

Protocol ecosystems (accessed 2026-02-02)

- gRPC over HTTP/2 protocol details (gRPC Core documentation). citeturn22search2  
- gRPC overview (HTTP/2 transport, streaming, metadata). citeturn22search22turn22search14  
- Protocol Buffers wire format and language specification (Proto3). citeturn24search0turn24search4  
- PostgreSQL frontend/backend protocol (message-based TCP protocol). citeturn22search3  
- entity["company","Neo4j","graph database vendor"] Bolt protocol overview (statement-oriented protocol over TCP/WebSocket). citeturn23search3turn23search15  
- entity["organization","IETF","internet standards body"] RFC publication sources via RFC Editor pages for QUIC/TLS/HTTP/2/WebSocket. citeturn22search0turn23search0turn22search1turn23search2
