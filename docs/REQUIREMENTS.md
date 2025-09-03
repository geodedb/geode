# REQUIREMENTS — ISO/IEC 39075 (GQL)–First System

## 0. Scope

This system is a distributed, ACID property‑graph DB that **speaks GQL** per ISO/IEC 39075:2024. The GQL layer is normative for language and semantics; the engine follows the **GQL execution model over binding tables** and the **linear composition** of statements. Binding tables carry **ordered vs unordered** descriptors that directly affect `ORDER BY`, `LIMIT`, and `OFFSET`. :contentReference[oaicite:10]{index=10}

## 1. Conformance & Options (ship‑blocking)

- The implementation **shall** meet the conformance rules for GQL‑implementations and **shall** produce a formal **claim of conformance** covering minimum + any optional features, and define all implementation‑defined/‑dependent items relied on by programs. If any options/extensions are provided, a **GQL Flagger** is required. :contentReference[oaicite:11]{index=11}
- Deliver a **Conformance Profile** document with:
  - Feature claims (Annex D codes where applicable; e.g., **GQ03 UNION**, **GQ04/5 EXCEPT**, **GQ06/7 INTERSECT**, **GQ02 OTHERWISE** if adopted). :contentReference[oaicite:12]{index=12}
  - Implementation‑defined items (e.g., **US001** ordering chosen before OFFSET/LIMIT on unordered tables; **UA005/UA006** path tie‑break). (Clause anchors summarized in the planner doc.) :contentReference[oaicite:13]{index=13}
  - Extensions/reserved words (if any) and whether the Flagger flags them. :contentReference[oaicite:14]{index=14}

## 2. Language Surface (Phase 0 baseline)

- **Queries**
  - `<linear query statement>` composition and hand‑off of **working record/table types**; `<primitive result>`; `<select>` desugaring. :contentReference[oaicite:15]{index=15}
  - `MATCH`/`OPTIONAL MATCH` with **graph patterns**, **variable‑length quantifiers**, **parenthesized path pattern** options per selected Annex D features. **Multi‑path binding** semantics apply.
  - `WHERE` filtering; `YIELD` rename rules and column typing. :contentReference[oaicite:17]{index=17}
  - `ORDER BY`, `LIMIT`, `OFFSET` with correctness w.r.t. **ordered vs unordered** inputs; no unsafe pushdown of OFFSET without stable order. (US001 documented.) :contentReference[oaicite:18]{index=18}
  - Set operations: `UNION [ALL|DISTINCT]`, `EXCEPT [ALL|DISTINCT]`, `INTERSECT [ALL|DISTINCT]`, with feature gating per Annex D. :contentReference[oaicite:19]{index=19}
- **DML & Procedures (parse‑now, enforce‑later)**
  - `<insert statement>` and `<linear data‑modifying statement>` surfaces; read‑only access mode guard. :contentReference[oaicite:20]{index=20}
  - `<procedure body>` flow with `NEXT` and binding contexts (baseline for future procedure support).
- **Literals & Types**
  - Temporal literals per ISO 8601; temporal instant/duration types; normal forms. :contentReference[oaicite:22]{index=22}
  - Comparability semantics; universal comparison is feature‑flagged (GA04). :contentReference[oaicite:23]{index=23}

## 3. Planner/Executor Contracts (must‑haves)

- The planner/executor shall implement the **GQL→Engine crosswalk** (NodeScan, Expand, OPTIONAL as LOJ, Project/Group, Order, Top‑k, SetOps) as documented in `query_engine.md` with clause anchors (14.4, 14.10, 14.12, 16.18–16.19, 22.4). :contentReference[oaicite:24]{index=24}
- **Offset pushdown requires explicit order** (testable rule). :contentReference[oaicite:25]{index=25}
- Path planning honors **UA005/UA006** (deterministic tie‑break documented). (Anchors summarized in planner doc.) :contentReference[oaicite:26]{index=26}

## 3a. Storage Modes (testable)

- The system SHALL provide an in-memory storage option that mirrors the on-disk page/record interfaces for development and testing.
- The preferred/default storage mode is disk-backed; both modes SHALL share invariants (page headers, slotted layout contracts, id alloc semantics).
- Tests SHOULD exercise both modes when relevant; E2E smoke may use in-memory, while performance and durability tests MUST use disk.

## 4. Distributed System Requirements

- **Replication & Meta:** Raft‑backed partitions; meta service maps partition→replicas/leaders and routes queries. :contentReference[oaicite:27]{index=27}
- **Distributed Txn:** 2PC over replicated logs; participants log prepare; recovery consults coordinator/meta to finish in‑doubt txns; batch/parallel prepare for latency. :contentReference[oaicite:28]{index=28}
- **Distributed queries:** Shard‑local subplans with iterative expansion; stateless query service; coordinator aggregates; Bloom filters to cut traffic. :contentReference[oaicite:29]{index=29}
- **Caching:** Read‑mostly cached copies with invalidation via meta/Raft pub‑sub. :contentReference[oaicite:30]{index=30}

## 5. Security Requirements

- **TDE** for pages + WAL (AES‑256‑XTS or equivalent) with master key in HSM/secure wallet; decrypt/encrypt in buffer manager. Optional **TEE** (SGX) mode with enclave‑held keys and WAL integrity. :contentReference[oaicite:31]{index=31}

## 6. Diagnostics & Protocol Requirements

- Map ISO **diagnostics & precedence** to wire statuses; when multiple conditions occur, follow ISO precedence; document UA002 behavior for additional statuses. :contentReference[oaicite:32]{index=32}
- Protocol must expose: request id, transactional outcome, status code/subclass, additional statuses list, and **GQL Flagger** findings when options/extensions are used. :contentReference[oaicite:33]{index=33}

## 7. Test Requirements (gates)

- Positive/negative tests per clause for: MATCH/OPTIONAL; WHERE/YIELD; ORDER/LIMIT/OFFSET legality; SetOps; Quantifiers; CASE & string predicates; Aggregation scoping; Path tie‑break determinism; Offset‑order rule; Conformance Profile traceability. Cross‑reference tests to clauses (Annex A). :contentReference[oaicite:34]{index=34}
