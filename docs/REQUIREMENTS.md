# REQUIREMENTS — ISO/IEC 39075 (GQL)–First System

## 0. Scope

This system is working toward a distributed, ACID property-graph DB that will **speak GQL** per ISO/IEC 39075:2024. Currently implements a SQL-like query engine with GQL syntax parsing. The GQL layer is normative for language and semantics; the engine will follow the **GQL execution model over binding tables** and the **linear composition** of statements. Binding tables carry **ordered vs unordered** descriptors that directly affect `ORDER BY`, `LIMIT`, and `OFFSET`.

**Current Status**: Core query operations working (RETURN, ORDER BY, set operations). Graph features (MATCH patterns, property access, traversal) not yet implemented.

## 1. Conformance & Options (ship-blocking)

- The implementation **shall** meet the conformance rules for GQL-implementations and **shall** produce a formal **claim of conformance** covering minimum + any optional features, and define all implementation-defined/-dependent items relied on by programs. If any options/extensions are provided, a **GQL Flagger** is required.
- Deliver a **Conformance Profile** document with:
  - Feature claims (Annex D codes where applicable; e.g., **GQ03 UNION**, **GQ04/5 EXCEPT**, **GQ06/7 INTERSECT**, **GQ02 OTHERWISE** if adopted).
  - Implementation-defined items (e.g., **US001** ordering chosen before OFFSET/LIMIT on unordered tables; **UA005/UA006** path tie-break).
  - Extensions/reserved words (if any) and whether the Flagger flags them.

## 2. Language Surface (Phase 0 baseline)

- **Queries** (partially implemented)
  - `<linear query statement>` composition and hand-off of **working record/table types**; `<primitive result>`; `<select>` desugaring. ✅
  - `MATCH`/`OPTIONAL MATCH` with **graph patterns**, **variable-length quantifiers**, **parenthesized path pattern** options. ❌ *Parser recognizes, execution not implemented*
  - `WHERE` filtering ✅; `YIELD` rename rules and column typing. ⚠️
  - `ORDER BY`, `LIMIT`, `OFFSET` with correctness w.r.t. **ordered vs unordered** inputs; no unsafe pushdown of OFFSET without stable order. (US001 documented.) ✅
  - Set operations: `UNION [ALL|DISTINCT]`, `EXCEPT [ALL|DISTINCT]`, `INTERSECT [ALL|DISTINCT]`. ✅
- **DML & Procedures** ❌ (not implemented)
  - `<insert statement>` and `<linear data-modifying statement>` surfaces; read-only access mode guard.
  - `<procedure body>` flow with `NEXT` and binding contexts (baseline for future procedure support).
- **Literals & Types** (partial)
  - Temporal literals per ISO 8601; temporal instant/duration types; normal forms. ✅
  - Comparability semantics; universal comparison is feature-flagged (GA04). ⚠️

## 3. Planner/Executor Contracts (must-haves)

- The planner/executor shall implement the **GQL→Engine crosswalk** (NodeScan, Expand, OPTIONAL as LOJ, Project/Group, Order, Top-k, SetOps) as documented in `query_engine.md`. ⚠️ *Currently missing graph operators*
- **Offset pushdown requires explicit order** (testable rule). ✅
- Path planning honors **UA005/UA006** (deterministic tie-break documented). ❌ *No path execution*

## 3a. Storage Modes (testable)

- The system SHALL provide an in-memory storage option that mirrors the on-disk page/record interfaces for development and testing. ✅
- The preferred/default storage mode is disk-backed; both modes SHALL share invariants (page headers, slotted layout contracts, id alloc semantics). ⚠️
- Tests SHOULD exercise both modes when relevant; E2E smoke may use in-memory, while performance and durability tests MUST use disk.

## 4. Distributed System Requirements ❌ (not implemented)

- **Replication & Meta:** Raft-backed partitions; meta service maps partition→replicas/leaders and routes queries.
- **Distributed Txn:** 2PC over replicated logs; participants log prepare; recovery consults coordinator/meta to finish in-doubt txns.
- **Distributed queries:** Shard-local subplans with iterative expansion; stateless query service; coordinator aggregates.
- **Caching:** Read-mostly cached copies with invalidation via meta/Raft pub-sub.

## 5. Security Requirements

- **TDE** for pages + WAL (configurable). ✅
  - Enable via env: `GEODE_DISK_ENCRYPTION=on`, `GEODE_DISK_KEY_HEX=<64 hex>`, optional `GEODE_WAL_ENCRYPTION=on`
  - PageManager encrypts/decrypts pages; WAL payloads encrypted per-record; files created 0600
  - Key rotation helper: `key_rotate` prints export for env update
- **TLS 1.3** for transport security. ✅ *QUIC with TLS implemented*

## 6. Diagnostics & Protocol Requirements

- Map ISO **diagnostics & precedence** to wire statuses; when multiple conditions occur, follow ISO precedence. ✅
- Protocol must expose: request id, transactional outcome, status code/subclass, additional statuses list, and **GQL Flagger** findings. ✅

## 7. Test Requirements (gates)

- Positive/negative tests per clause for implemented features. ✅
- Graph feature tests pending implementation of core functionality.

## Implementation Status Legend
- ✅ Implemented and tested
- ⚠️ Partially implemented
- ❌ Not implemented