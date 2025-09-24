# REQUIREMENTS — ISO/IEC 39075 (GQL)–First System

// CANARY: REQ=REQ-GQL-024; FEATURE="Requirements Scope Accuracy"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=docs; UPDATED=2025-09-22

## 0. Scope

This system is working toward a distributed, ACID property-graph DB that will **speak GQL** per ISO/IEC 39075:2024. Currently implements a SQL-like query engine with GQL syntax parsing. The GQL layer is normative for language and semantics; the engine will follow the **GQL execution model over binding tables** and the **linear composition** of statements. Binding tables carry **ordered vs unordered** descriptors that directly affect `ORDER BY`, `LIMIT`, and `OFFSET`.

**Current Status**: Core linear query operations working (RETURN, ORDER BY, set operations). Path expansion, basic MATCH label/property predicate, OPTIONAL null-preserve semantics, and structural PathCache features partially implemented (cache enrichment & variance guards). MVCC snapshot isolation with phantom prevention instrumentation (RangeTracker) present; recovery corruption latency guard and pagination execution variance envelopes landed. Advanced graph pattern semantics, full optimizer, and distributed features remain partial or stubbed (single-leader scaffolding; no election/snapshot). QUIC transport is experimental; TCP remains primary.

## 1. Conformance & Options (ship-blocking)

- The implementation **shall** meet the conformance rules for GQL-implementations and **shall** produce a formal **claim of conformance** covering minimum + any optional features, and define all implementation-defined/-dependent items relied on by programs. If any options/extensions are provided, a **GQL Flagger** is required.
- Deliver a **Conformance Profile** document with:
  - Feature claims (Annex D codes where applicable; e.g., **GQ03 UNION**, **GQ04/5 EXCEPT**, **GQ06/7 INTERSECT**, **GQ02 OTHERWISE** if adopted).
  - Implementation-defined items (e.g., **US001** ordering chosen before OFFSET/LIMIT on unordered tables; **UA005/UA006** path tie-break).
  - Extensions/reserved words (if any) and whether the Flagger flags them.

## 2. Language Surface (Phase 0 baseline)

- **Queries** (partially implemented)
  - `<linear query statement>` composition - basic only ✅
  - `MATCH`/`OPTIONAL MATCH` - Parser recognizes, execution minimal ❌
  - `WHERE` filtering - basic expressions only ⚠️
  - `ORDER BY`, `LIMIT`, `OFFSET` - working for simple queries ✅
  - Set operations - functional ✅
- **DML & Procedures** ❌ (not implemented)
  - `<insert statement>` and `<linear data-modifying statement>` surfaces; read-only access mode guard.
  - `<procedure body>` flow with `NEXT` and binding contexts (baseline for future procedure support).
- **Literals & Types** (partial)
  - Temporal literals per ISO 8601; temporal instant/duration types; normal forms. ✅
  - Comparability semantics; universal comparison is feature-flagged (GA04). ⚠️

## 3. Planner/Executor Contracts (must-haves)

- The planner/executor implements basic operations (projection, filtering, set ops, pagination legality enforcement). Graph operators (NodeScan, Expand) partially implemented; path expansion supports bounded quantifiers with deterministic tie-break (UA005/UA006). Cost model & plan enumeration not yet present (no cost-based optimization). ⚠️
- **Offset pushdown requires explicit order** (testable rule). ✅
  Path planning honors **UA005/UA006** (deterministic tie-break for bounded multi-branch expansion TESTED — see CANARY aspects: BoundedQuantifierDeterminism & PathQuantifierBoundedVarianceEnvelope). MATCH node label + single property equality predicate execution TESTED/BENCHED (REQ-GQL-017: MatchLabelPropertyVarianceEnvelope); OPTIONAL MATCH null-preserving semantics TESTED (OptionalMatchNullPreserve). Added structural pattern cache (PathCache) with canonical structural key derivation ignoring variable identifiers and literal property values (aspect `PathCacheStructuralKeyDerivation` TESTED) plus hit/miss latency variance envelope (`PathCacheHitMissVarianceEnvelope` BENCHED). Enriched structural key now encodes sorted property key sets (`PathCacheStructuralKeyEnrichment` TESTED), value shape classes per endpoint (`PathCacheStructuralKeyValueShapeEnrichment` TESTED: N,S,B,U,A,O), selectivity class per endpoint (`PathCacheStructuralKeySelectivityEnrichment` TESTED: Z=0,L=1,M=2-3,H=4+), and degree bucket placeholder (`PathCacheStructuralKeyDegreeBucketEnrichment` TESTED; DBU currently unknown bucket pending stats integration); collision envelope benchmark (`PathCacheStructuralKeyCollisionEnvelope` BENCHED) now tightened to enforce ≥92% unique structural signatures (`PathCacheStructuralKeyCollisionTightened`). ⚠️ _Partial path execution (remaining gaps: property predicates over variable-length expansions, chained OPTIONAL over variable-length patterns)_

## 3a. Storage Modes (testable)

The system SHALL provide an in-memory storage option that mirrors the on-disk page/record interfaces for development and testing. ✅
The preferred/default storage mode is disk-backed; both modes SHALL share invariants (page headers, slotted layout contracts, id alloc semantics). ⚠️
Tests SHOULD exercise both modes when relevant; E2E smoke may use in-memory, while performance and durability tests MUST use disk.

## 4. Distributed System Requirements ❌ (COMPLETELY UNIMPLEMENTED - STUBS ONLY)

- **Replication & Meta:** Raft-backed partitions; meta service maps partition→replicas/leaders and routes queries.
- **Distributed Txn:** 2PC over replicated logs; participants log prepare; recovery consults coordinator/meta to finish in-doubt txns.
- **Distributed queries:** Shard-local subplans with iterative expansion; stateless query service; coordinator aggregates.
- **Caching:** Read-mostly cached copies with invalidation via meta/Raft pub-sub.

## 5. Security Requirements

- **TDE** for pages + WAL - basic encryption only, no KMS ⚠️
  - Enable via env: `GEODE_DISK_ENCRYPTION=on`, `GEODE_DISK_KEY_HEX=<64 hex>`, optional `GEODE_WAL_ENCRYPTION=on`
  - PageManager encrypts/decrypts pages; WAL payloads encrypted per-record; files created 0600
  - Key rotation helper: `key_rotate` prints export for env update
- **TLS 1.3** for transport - QUIC experimental; TCP primary ⚠️

## 6. Diagnostics & Protocol Requirements

- Map ISO **diagnostics & precedence** to wire statuses; when multiple conditions occur, follow ISO precedence. ✅
- Protocol must expose: request id, transactional outcome, status code/subclass, additional statuses list, and **GQL Flagger** findings. ✅

## 7. Test Requirements (gates)

- Positive/negative tests per clause for implemented features. ✅
- Graph feature tests pending implementation of core functionality.

## Implementation Status Legend

- ✅ Actually working (tested and functional)
- ⚠️ Partially implemented (incomplete or limited)
- ❌ Not implemented (stub, fake, or missing)

## Reality Check

- ~63–66% of tracked aspects have functional evidence (TESTED); remaining promoted aspects are BENCHED with performance/variance guardrails.
- Residuals present in current snapshot: 6 STUB / 7 IMPL (counts derived from `status.csv`). Target policy remains 0 STUB / 0 IMPL at ship; governance tracks progress and will fail if docs over‑claim versus evidence.
- Advanced optimizer, full MATCH pattern semantics, distributed consensus (election/membership), and external connectors are still pending.
- Governance automation (ImplementationReality delta tool + NEXT plan freshness guard) reduces documentation drift risk.

## 8. Graph Algorithms & Supporting Data Structures (Planned Adoption)

These requirements introduce a tracked backlog of core graph / network algorithms and supporting containers needed for advanced planning, analytics, and future GQL graph pattern optimization. All begin at **STUB** status (no functional code) unless otherwise stated. Each requirement uses CANARY markers to enable evidence‑driven promotion (TESTED/BENCHED) when implementations and tests land. Dates reflect initial registration.

### 8.1 Core Graph Structures

- Generic vertex/edge builders (directed + weighted), concurrency‑safe graph (RWMutex wrapping mutation / reader snapshot semantics)

```text
CANARY: REQ=REQ-GQL-060; FEATURE="Core Graph Builders"; ASPECT=DirectedWeightedBuilders; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_060_CoreGraphBuilders; BENCH=BenchmarkCANARY_REQ_GQL_060_CoreGraphBuilders; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-060; FEATURE="Core Graph Builders"; ASPECT=ConcurrencySafeGraph; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_060_ConcurrencySafe; BENCH=BenchmarkCANARY_REQ_GQL_060_ConcurrencySafe; OWNER=graph; UPDATED=2025-09-20
```

## 10. Strategic High-Priority Requirements (New IDs 074–077)

These four requirements were elevated to top strategic priority (Network Transport, Query Optimizer, Materialized Views, Full-Text Search). They are intentionally scoped to minimal, evidenceable skeletons that unblock downstream work while avoiding over-claiming. Each shall surface experimental flagger codes and land with both functional test(s) and (where specified) variance benchmarks guarding foundational performance characteristics.

### REQ-GQL-074 — QUIC Multiplexing Transport

Problem: Current TCP/stdio transports introduce head-of-line blocking and lack multiplexed stream semantics required for future distributed replication and low-latency interactive workloads.

Scope (Initial Skeleton):

- QUIC listener shim (single process, single certificate path) behind build/runtime flag.
- Stream multiplexer abstraction (logical session → stream id mapping).
- Frame encode/decode integration with existing protocol structs (no semantic change).
- Latency probe harness measuring encode_ns / decode_ns / rtt_ns (JSON lines) for governance variance bench.
- Flagger emission: `TransportQUICExperimental` when enabled.

Out of Scope (Future): congestion control tuning, session resumption, TLS cert rotation, zero-copy buffers, Raft integration.

Acceptance:

1. Test `TestCANARY_REQ_GQL_074_QUICMultiplexingBasic` establishes QUIC session, sends HELLO + RUN_GQL echo query, validates ordered BINDINGS response.
2. Benchmark `BenchmarkCANARY_REQ_GQL_074_QuicFrameLatencyVarianceEnvelope` (N≥48 samples) enforces CV≤0.22, p95/mean≤2.55 for encode, decode, rtt metrics.
3. CANARY aspects: QUICMultiplexing (IMPL→TESTED), QuicFrameLatencyVarianceEnvelope (BENCHED) with UPDATED date freshness.
4. README updated enumerating experimental QUIC support; failure to provide flagger code causes governance failure.

Evidence Plan: Functional test + latency variance envelope JSON; scanner promotion from IMPL→TESTED/BENCHED on merge.

### REQ-GQL-075 — Advanced Cost Model (Enumeration Seed)

Problem: Absence of a cost model prevents principled plan selection, blocking future join order optimization and physical operator choice.

Scope (Seed):

- Factor registry (row_count, selectivity_factor, cpu_cost, io_cost) with calibration harness.
- Enumeration stub (2-way join reorder alternative) returning baseline + swapped order for evidence.
- Calibration snapshot persistence (JSON) and drift report (non-failing unless >15% per-factor drift) for observability.
- Variance bench guarding calibration runtime stability.
- Flagger emission: `CostModelExperimental`.

Out of Scope: histogram stats, n-way join search, dynamic re-optimization, complex cardinality estimation algorithms.

Acceptance:

1. Test `TestCANARY_REQ_GQL_075_AdvancedCostModelFactors` asserts non-zero factor capture & presence of at least two alternative plans.
2. Benchmark `BenchmarkCANARY_REQ_GQL_075_CostModelCalibrationVarianceEnvelope` (CV≤0.20, p95/mean≤2.50) across calibration runs.
3. CANARY aspects: AdvancedCostModel (IMPL→TESTED), CostModelCalibrationVarianceEnvelope (BENCHED), JoinEnumerationSeed (IMPL pending promotion).
4. Drift report emitted when factor weight delta >15% (stdout JSON line) — informational unless threshold exceeded for two consecutive runs (future escalation slice).

Evidence Plan: Factor snapshot, functional test, variance bench metrics; join enumeration seed promotion in later slice once >2-way joins present.

### REQ-GQL-076 — Materialized View Refresh Scheduler

Problem: Recomputing derived projections (aggregations/pattern subsets) inline leads to latency spikes; need scheduled refresh foundation for later incremental maintenance & query rewrite.

Scope (Phase 1):

- In-memory MV catalog and registration API (pattern + projection list).
- Interval-based refresh loop with jitter smoothing & monotonic last_refresh timestamp.
- REFRESH command stub for manual trigger.
- Variance bench for refresh runtime stability on trivial view.
- Flagger emission: `MaterializedViewsExperimental`.

Out of Scope: incremental delta maintenance, persistence, automatic query rewrite, dependency graphs.

Acceptance:

1. Test `TestCANARY_REQ_GQL_076_RefreshSchedulerBasic` registers view, triggers manual refresh, asserts timestamp monotonicity.
2. Benchmark `BenchmarkCANARY_REQ_GQL_076_RefreshSchedulerVarianceEnvelope` (CV≤0.22, p95/mean≤2.55) with N≥40 trivial refresh cycles.
3. CANARY aspects: RefreshScheduler (IMPL→TESTED), RefreshSchedulerVarianceEnvelope (BENCHED).
4. README experimental disclaimer present; governance doc_consistency unaffected (counts auto-aligned).

Evidence Plan: Functional test + variance metrics JSON lines.

### REQ-GQL-077 — Inverted Index Core (Full-Text Search Skeleton)

Problem: Lack of text search access path limits query expressiveness for content-centric graph workloads (labels/properties with unstructured text).

Scope (Phase 1):

- Whitespace + lowercase tokenizer.
- In-memory postings builder mapping term→list(node_id).
- Build API (bulk ingestion) + simple term query executor returning deterministic ordered node ids.
- Variance bench for build & single-term query latency.
- Flagger emission: `FullTextSearchExperimental`.

Out of Scope: persistent storage, ranking (BM25), phrase queries/positions, stemming, incremental updates, concurrency controls.

Acceptance:

1. Test `TestCANARY_REQ_GQL_077_InvertedIndexCoreBasic` indexes 5 docs and searches two terms; asserts deterministic result ordering and correct doc id sets.
2. Benchmark `BenchmarkCANARY_REQ_GQL_077_InvertedIndexBuildQueryVarianceEnvelope` (build/query CV≤0.22, p95/mean≤2.55) across N≥40 samples.
3. CANARY aspects: InvertedIndexCore (IMPL→TESTED), InvertedIndexVarianceEnvelope (BENCHED).
4. README lists experimental status; GAP_ANALYSIS row updated upon promotion.

Evidence Plan: Functional test + variance metrics; future slice may add positional postings & ranking.

### 8.2 DOT Codec

- Canonical marshal (stable attribute ordering)
- Advanced parse: subgraphs, ports, HTML‑ish labels, default attribute scopes

```text
CANARY: REQ=REQ-GQL-061; FEATURE="DOT Codec"; ASPECT=DotMarshalCanonical; STATUS=STUB; TEST=TestCANARY_REQ_GQL_061_DotMarshalCanonical; BENCH=BenchmarkCANARY_REQ_GQL_061_DotMarshalCanonical; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-061; FEATURE="DOT Codec"; ASPECT=DotParseAdvanced; STATUS=STUB; TEST=TestCANARY_REQ_GQL_061_DotParseAdvanced; BENCH=BenchmarkCANARY_REQ_GQL_061_DotParseAdvanced; OWNER=graph; UPDATED=2025-09-20
```

### 8.3 Traversal Algorithms

- BFS, DFS (iterative), IDDFS, Topological Sort (Kahn + DFS variants), Cycle Detection (directed & undirected)

```text
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=BFS; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_BFS; BENCH=BenchmarkCANARY_REQ_GQL_062_BFS; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=DFSIterative; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_DFSIterative; BENCH=BenchmarkCANARY_REQ_GQL_062_DFSIterative; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=IDDFS; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_IDDFSBasics; BENCH=BenchmarkCANARY_REQ_GQL_062_IDDFS; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=TopologicalSortKahn; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_TopoKahn; BENCH=BenchmarkCANARY_REQ_GQL_062_TopoKahn; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=TopologicalSortDFS; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_TopoDFS; BENCH=BenchmarkCANARY_REQ_GQL_062_TopoDFS; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=CycleDetectDirected; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_CycleDirected; BENCH=BenchmarkCANARY_REQ_GQL_062_CycleDirected; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=CycleDetectUndirected; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_CycleUndirected; BENCH=BenchmarkCANARY_REQ_GQL_062_CycleUndirected; OWNER=graph; UPDATED=2025-09-21
```

### 8.4 Shortest Paths

- Unweighted BFS paths, Dijkstra (non‑negative weights), A\*, DAG shortest path, Yen K‑shortest, path cache (memo of resolved segments)

```text
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=UnweightedBFSPaths; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_UnweightedBFSPaths; BENCH=BenchmarkCANARY_REQ_GQL_063_UnweightedBFSPaths; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=Dijkstra; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_Dijkstra; BENCH=BenchmarkCANARY_REQ_GQL_063_Dijkstra; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=AStar; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_AStar; BENCH=BenchmarkCANARY_REQ_GQL_063_AStar; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=DagShortestPath; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_DagShortestPath; BENCH=BenchmarkCANARY_REQ_GQL_063_DagShortestPath; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=YenKShortest; STATUS=STUB; TEST=TestCANARY_REQ_GQL_063_YenKShortest; BENCH=BenchmarkCANARY_REQ_GQL_063_YenKShortest; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=PathCache; STATUS=STUB; TEST=TestCANARY_REQ_GQL_063_PathCache; BENCH=BenchmarkCANARY_REQ_GQL_063_PathCache; OWNER=graph; UPDATED=2025-09-20
```

### 8.5 Connectivity

- Tarjan SCC (authoritative), Kosaraju (validation via Tarjan), Biconnected components, Bridges & Articulation points

```text
CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=TarjanSCC; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_TarjanSCC; BENCH=BenchmarkCANARY_REQ_GQL_064_TarjanSCC; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=KosarajuValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_064_Kosaraju; BENCH=BenchmarkCANARY_REQ_GQL_064_Kosaraju; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=BiconnectedComponents; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_Biconnected; BENCH=BenchmarkCANARY_REQ_GQL_064_Biconnected; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=BridgesArticulation; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_BridgesArticulation; BENCH=BenchmarkCANARY_REQ_GQL_064_BridgesArticulation; OWNER=graph; UPDATED=2025-09-20
```

### 8.6 Spanning Trees

- Kruskal (Union‑Find), Prim (binary heap)

```text
CANARY: REQ=REQ-GQL-065; FEATURE="Spanning Trees"; ASPECT=Kruskal; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_065_Kruskal; BENCH=BenchmarkCANARY_REQ_GQL_065_Kruskal; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-065; FEATURE="Spanning Trees"; ASPECT=Prim; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_065_Prim; BENCH=BenchmarkCANARY_REQ_GQL_065_Prim; OWNER=graph; UPDATED=2025-09-21
```

### 8.7 Flow & Matching

- Edmonds–Karp, Dinic, Hopcroft–Karp

```text
CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=EdmondsKarp; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_EdmondsKarp; BENCH=BenchmarkCANARY_REQ_GQL_066_EdmondsKarp; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=Dinic; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_DinicBasic; BENCH=BenchmarkCANARY_REQ_GQL_066_Dinic; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=HopcroftKarp; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_HopcroftKarpBasic; BENCH=BenchmarkCANARY_REQ_GQL_066_HopcroftKarp; OWNER=graph; UPDATED=2025-09-21
```

### 8.8 Centrality Metrics

- Betweenness, Closeness, Eigenvector, PageRank, Bridge/Leverage, Grey Cardinal composite

```text
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=BetweennessCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Betweenness; BENCH=BenchmarkCANARY_REQ_GQL_067_Betweenness; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=ClosenessCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Closeness; BENCH=BenchmarkCANARY_REQ_GQL_067_Closeness; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=EigenvectorCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Eigenvector; BENCH=BenchmarkCANARY_REQ_GQL_067_Eigenvector; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=PageRank; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_PageRank; BENCH=BenchmarkCANARY_REQ_GQL_067_PageRank; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=BridgeLeverage; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_BridgeLeverage; BENCH=BenchmarkCANARY_REQ_GQL_067_BridgeLeverage; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=GreyCardinalComposite; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_GreyCardinalComposite; BENCH=BenchmarkCANARY_REQ_GQL_067_GreyCardinalComposite; OWNER=graph; UPDATED=2025-09-21
```

### 8.9 Containers & Auxiliary Structures

- Cursor, Queue (signaled), LRU, LFU, Bloom Filter, Skip List, Trie, Union‑Find

```text
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=CursorContainer; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_068_Cursor; OWNER=graph; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueue; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_068_SignaledQueue; OWNER=graph; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=LRUCache; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_LRU; BENCH=BenchmarkCANARY_REQ_GQL_068_LRU; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=LFUCache; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_LFU; BENCH=BenchmarkCANARY_REQ_GQL_068_LFU; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=BloomFilterContainer; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_BloomFilter; BENCH=BenchmarkCANARY_REQ_GQL_068_BloomFilter; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SkipList; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_SkipList; BENCH=BenchmarkCANARY_REQ_GQL_068_SkipList; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=Trie; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_Trie; BENCH=BenchmarkCANARY_REQ_GQL_068_Trie; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=UnionFind; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_UnionFind; BENCH=BenchmarkCANARY_REQ_GQL_068_UnionFind; OWNER=graph; UPDATED=2025-09-21
```

// CDC Core API (added post initial registration but tracked under REQ-GQL-042)
CANARY: REQ=REQ-GQL-042; FEATURE="CDC Core API"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_CoreStartStop; OWNER=streaming; UPDATED=2025-09-20
// Umbrella CDC integrative aspects promoted via new integrative tests (no code changes → keep original date)
CANARY: REQ=REQ-GQL-042; FEATURE="CDC"; ASPECT=APIUmbrella; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_E2EUmbrella; OWNER=streaming; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-042; FEATURE="CDC/Streaming"; ASPECT=APIUmbrella; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_StreamingUmbrella; OWNER=streaming; UPDATED=2025-09-20

### 8.10 Probabilistic Structures

- Bloom Filter (multi‑hash), Count‑Min Sketch (planned)

```text
CANARY: REQ=REQ-GQL-069; FEATURE="Probabilistic"; ASPECT=BloomFilterMultiHash; STATUS=STUB; TEST=TestCANARY_REQ_GQL_069_BloomFilterMultiHash; BENCH=BenchmarkCANARY_REQ_GQL_069_BloomFilterMultiHash; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-069; FEATURE="Probabilistic"; ASPECT=CountMinSketch; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_069_CountMinSketch; BENCH=BenchmarkCANARY_REQ_GQL_069_CountMinSketch; OWNER=graph; UPDATED=2025-09-21
```

### 8.11 String Search (Partial)

- KMP, Rabin–Karp (pending slice utilities refactor) — initially registered as STUB for tracking

```text
CANARY: REQ=REQ-GQL-070; FEATURE="String Search"; ASPECT=KMP; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_070_KMP; BENCH=BenchmarkCANARY_REQ_GQL_070_KMP; OWNER=graph; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-070; FEATURE="String Search"; ASPECT=RabinKarp; STATUS=STUB; TEST=TestCANARY_REQ_GQL_070_RabinKarp; BENCH=BenchmarkCANARY_REQ_GQL_070_RabinKarp; OWNER=graph; UPDATED=2025-09-20
```

### Promotion Criteria (All Graph Algorithm Requirements)

1. TESTED: Deterministic correctness tests (small canonical graphs) + edge cases (empty graph, disconnected, negative or zero weights where valid, multi‑component, pathological ordering).
2. BENCHED: Performance harness on synthetic + scale graphs (power‑law and uniform) with fixed seeds; memory & time metrics captured.
3. Optional: Cross‑validation against reference outputs (e.g., PageRank tolerance, centrality ranking stability) with documented tolerances.

Initial prioritization sequence (execution path enablement): 060 → 062 → 063 → 064/065 → 067 (PageRank first) → 066 (flow) → 068 (containers for optimizations) → 061 (DOT import/export) → 069/070.

## 9. Advanced Domain Specifications: Grey Cardinal & Hyperledger Integration (Planned)

These requirements formalize research outputs from `specs/grey-cardinal` and `specs/hyperledger` into tracked, evidence‑gated implementation targets. They extend the core system with composite centrality analytics (Grey Cardinal) and blockchain / ledger‑aware transactional semantics (Hyperledger-inspired conflict control & graph isomorphism for MVCC validation). All start at **STUB** status.

### 9.1 Grey Cardinal Composite Analytics

Scope: Compose multiple centrality measures with weighting + normalization to produce a single Grey Cardinal score and ranked output; support incremental recomputation and explainability metadata (component contributions). Research sources in `specs/grey-cardinal/`.

Deliverables / Aspects:

- Metric Composition Engine (weighted aggregation + z-score or min-max normalization)
- Incremental Update (affected subgraph delta propagation)
- Explainability Export (per-node component vector + final score)
- Ranking Stability Bench (sensitivity under minor edge perturbations)
- API Surface (GQL extension function `GREY_CARDINAL(node)` guarded by Flagger)

```text
CANARY: REQ=REQ-GQL-071; FEATURE="GreyCardinal"; ASPECT=MetricCompositionEngine; STATUS=STUB; TEST=TestCANARY_REQ_GQL_071_MetricComposition; BENCH=BenchmarkCANARY_REQ_GQL_071_MetricComposition; OWNER=analytics; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-071; FEATURE="GreyCardinal"; ASPECT=IncrementalUpdate; STATUS=STUB; TEST=TestCANARY_REQ_GQL_071_IncrementalUpdate; BENCH=BenchmarkCANARY_REQ_GQL_071_IncrementalUpdate; OWNER=analytics; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-071; FEATURE="GreyCardinal"; ASPECT=ExplainabilityExport; STATUS=STUB; TEST=TestCANARY_REQ_GQL_071_ExplainabilityExport; BENCH=BenchmarkCANARY_REQ_GQL_071_ExplainabilityExport; OWNER=analytics; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-071; FEATURE="GreyCardinal"; ASPECT=RankingStabilityBench; STATUS=STUB; TEST=TestCANARY_REQ_GQL_071_RankingStability; BENCH=BenchmarkCANARY_REQ_GQL_071_RankingStability; OWNER=analytics; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-071; FEATURE="GreyCardinal"; ASPECT=GqlApiFunction; STATUS=STUB; TEST=TestCANARY_REQ_GQL_071_GqlApiFunction; BENCH=BenchmarkCANARY_REQ_GQL_071_GqlApiFunction; OWNER=analytics; UPDATED=2025-09-20
```

### 9.2 Hyperledger‑Inspired Graph MVCC & Conflict Control

Scope: Integrate concepts from Fabric transaction conflict handling & graph isomorphism validation for multi-statement GQL transactions to detect semantic conflicts beyond simple key/version checks. Research sources in `specs/hyperledger/`.

Deliverables / Aspects:

- Read/Write Set Graph Projection (capture property & structural dependencies per txn)
- Isomorphic Conflict Detection (pattern equivalence rather than raw id collision)
- Deferred Validation Phase (pre-commit validation window & abort classification)
- Conflict Classification Diagnostics (extended status codes mapping to ISO additional statuses)
- Benchmark: Conflict Throughput & Abort Ratio under mixed workloads

```text
CANARY: REQ=REQ-GQL-072; FEATURE="HyperledgerGraphMVCC"; ASPECT=RwSetGraphProjection; STATUS=STUB; TEST=TestCANARY_REQ_GQL_072_RwSetGraphProjection; BENCH=BenchmarkCANARY_REQ_GQL_072_RwSetGraphProjection; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-072; FEATURE="HyperledgerGraphMVCC"; ASPECT=IsomorphicConflictDetection; STATUS=STUB; TEST=TestCANARY_REQ_GQL_072_IsomorphicConflict; BENCH=BenchmarkCANARY_REQ_GQL_072_IsomorphicConflict; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-072; FEATURE="HyperledgerGraphMVCC"; ASPECT=DeferredValidationPhase; STATUS=STUB; TEST=TestCANARY_REQ_GQL_072_DeferredValidation; BENCH=BenchmarkCANARY_REQ_GQL_072_DeferredValidation; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-072; FEATURE="HyperledgerGraphMVCC"; ASPECT=ConflictClassificationDiagnostics; STATUS=STUB; TEST=TestCANARY_REQ_GQL_072_ConflictClassification; BENCH=BenchmarkCANARY_REQ_GQL_072_ConflictClassification; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-072; FEATURE="HyperledgerGraphMVCC"; ASPECT=ConflictThroughputBench; STATUS=STUB; TEST=TestCANARY_REQ_GQL_072_ConflictThroughput; BENCH=BenchmarkCANARY_REQ_GQL_072_ConflictThroughput; OWNER=txn; UPDATED=2025-09-20
```

### Promotion Criteria (Advanced Specs)

Grey Cardinal: Promote aspects to TESTED with deterministic multi-metric fusion tests (fixed seed graphs). BENCHED requires stability variance < specified epsilon across perturbation trials.

Hyperledger MVCC: TESTED requires simulation harness generating conflicting & non-conflicting txns with correct classification; BENCHED adds throughput + abort ratio metrics at target concurrency.

### 9.3 MVCC Advanced Early Conflict Detection & Repair (Planned)

Scope: Extend baseline and Hyperledger-inspired MVCC (REQ-GQL-013 / REQ-GQL-072) with proactive detection and mitigation techniques from research artifacts in `specs/mvcc/` (e.g., early read-write dependency prediction, partial rollback strategies, heuristic reordering). Objective: reduce abort ratio and latency variance under high contention workloads while maintaining Snapshot Isolation semantics (future upgrade path to Serializable Snapshot Isolation documented separately).

Deliverables / Aspects:

- Early Conflict Detection (speculative dependency graph; pre-validation during statement execution)
- Predictive Version Check (lightweight bloom / summary filters to detect impending version skew before commit window)
- Conflict Repair Heuristics (local reordering of non-committed operations when safe via commutativity rules)
- Partial Rollback Mechanism (rollback last statement or subgraph mutation set instead of whole transaction when isolation not violated)
- Repair Throughput Bench (contention stress harness measuring aborted txn reduction & added overhead)

```text
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=EarlyConflictDetection; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_EarlyConflictDetection; BENCH=BenchmarkCANARY_REQ_GQL_073_EarlyConflictDetection; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PredictiveVersionCheck; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_PredictiveVersionCheck; BENCH=BenchmarkCANARY_REQ_GQL_073_PredictiveVersionCheck; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=ConflictRepairHeuristics; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_ConflictRepairHeuristics; BENCH=BenchmarkCANARY_REQ_GQL_073_ConflictRepairHeuristics; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PartialRollbackMechanism; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_PartialRollbackMechanism; BENCH=BenchmarkCANARY_REQ_GQL_073_PartialRollbackMechanism; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=RepairThroughputBench; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_RepairThroughputBench; BENCH=BenchmarkCANARY_REQ_GQL_073_RepairThroughputBench; OWNER=txn; UPDATED=2025-09-20
```

Promotion Criteria (MVCC Advanced):

1. TESTED: Harness generates high-contention workload (configurable hot set %) validating: (a) early detection triggers prior to final validation; (b) false-positive rate bounded (document threshold). Partial rollback tests ensure transaction-level atomicity is preserved.
2. BENCHED: Measure abort ratio reduction ≥ target (document baseline vs improved) and added latency overhead ≤ threshold percentage; publish JSON metrics.
3. Evidence must link to isolation invariants: no phenomena violating Snapshot Isolation (G0, G1 anomalies) introduced by heuristics / partial rollback.

#### 9.3.1 MVCC Advanced Phase 2 (Extended Roadmap)

Additional optional enhancements (tracking under the same requirement id) targeting abort ratio reduction, improved precision of early detection, and richer observability. All start at STUB.

Deliverables / New Aspects:

- Sub‑Transaction Rollback Integration (stacked sub‑txn scopes, partial undo without full abort)
- False Positive Reduction (refined early conflict decision requiring write overlap / access classification)
- Predictive Skew Filter (enhanced version summary with lightweight probabilistic mismatch filter)
- Topological Repair Heuristic (dependency graph + safe operation reordering pass)
- Advanced MVCC Telemetry (exposed counters & snapshot API)
- Realistic Contention Benchmark (parametric workload: read/write ratio, hot set %, deterministic RNG)

```text
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=SubTxnRollbackIntegration; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_SubTxnRollbackIntegration; BENCH=BenchmarkCANARY_REQ_GQL_073_SubTxnRollbackIntegration; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=FalsePositiveReduction; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_FalsePositiveReduction; BENCH=BenchmarkCANARY_REQ_GQL_073_FalsePositiveReduction; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PredictiveSkewFilter; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_PredictiveSkewFilter; BENCH=BenchmarkCANARY_REQ_GQL_073_PredictiveSkewFilter; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=TopologicalRepairHeuristic; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_TopologicalRepairHeuristic; BENCH=BenchmarkCANARY_REQ_GQL_073_TopologicalRepairHeuristic; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=AdvancedMvccTelemetry; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_AdvancedMvccTelemetry; BENCH=BenchmarkCANARY_REQ_GQL_073_AdvancedMvccTelemetry; OWNER=txn; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=RealisticContentionBenchmark; STATUS=STUB; TEST=TestCANARY_REQ_GQL_073_RealisticContentionBenchmark; BENCH=BenchmarkCANARY_REQ_GQL_073_RealisticContentionBenchmark; OWNER=txn; UPDATED=2025-09-20
```

Phase 2 Promotion Criteria:

1. TESTED: Each aspect backed by deterministic unit/integration test demonstrating functional semantics (e.g., sub‑txn rollback only reverts inner scope writes; false positive reduction lowers early aborts on pure read overlaps).
2. BENCHED: Benchmark harness captures abort ratio delta vs baseline (≥ defined improvement threshold) and exports JSON metrics; contention benchmark emits structured stats (attempts, early_aborts, repaired, partial_rollbacks, false_positive_estimate).
3. Telemetry counters stable across repeated runs (variance <5% for identical seed) ensuring observability reliability.

## 11. Newly Registered Core Expansion Requirements (IDs 078–084)

These requirements codify additional subsystems referenced in recent design / code review cycles but not yet tracked in this document. All begin at STUB status (no functional code unless stated). Each carries initial CANARY markers to enable evidence‑driven promotion without inflating maturity claims. Dates reflect initial registration (2025‑09‑22). Future slices will enrich scopes; any scope creep requires explicit diff notes in CHANGELOG / GAP_ANALYSIS.

### REQ-GQL-078 — Cluster Coordinator & Raft Leader Skeleton

Problem: Absence of a coordination layer blocks future replication, partition mapping, and distributed transaction orchestration.

Scope (Phase 0 Skeleton):

- In‑process Coordinator service maintaining an in‑memory shard map (single shard fixed).
- Raft interfaces (AppendEntries / RequestVote) returning NotImplemented but structure validates message envelope & term monotonicity.
- Leadership assumption: process starts as leader; follower mode stub.
- Health probe & metrics counters (proposed) for leadership term, append attempts.
- Flagger code: `ClusterCoordinatorExperimental` when enabled via build flag.

Out of Scope: log replication, membership changes, snapshotting, election timeouts, partition rebalancing.

Acceptance (Promotion to TESTED): basic leader status query returns expected static leader id; shard map query returns single shard descriptor; Raft message validation rejects decreasing term numbers.

```text
CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=LeaderStub; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_LeaderStub; BENCH=BenchmarkCANARY_REQ_GQL_078_LeaderStub; OWNER=dist; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=ShardMapStub; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_ShardMapStub; BENCH=BenchmarkCANARY_REQ_GQL_078_ShardMapStub; OWNER=dist; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-078; FEATURE="ClusterCoordinator"; ASPECT=RaftInterfaceValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_078_RaftInterfaceValidation; BENCH=BenchmarkCANARY_REQ_GQL_078_RaftInterfaceValidation; OWNER=dist; UPDATED=2025-09-23
```

### REQ-GQL-079 — Recursive CTE / Recursive Pattern Execution Engine

Problem: Lack of recursive evaluation support prevents expressing transitive closures, hierarchical traversals, and certain analytical patterns mandated / enabled by recursive constructs.

Scope (Phase 1):

- Parser recognition for a minimal recursive WITH binding (anchor + recursive member) or equivalent GQL recursive pattern form.
- Execution driver performing iterative fixpoint with cycle guard and max iteration limit (configurable; default 10k) emitting warning/diagnostic if exceeded.
- Work table representation (binding table) with duplicate elimination (DISTINCT) toggle.
- Flagger: `RecursiveExecutionExperimental` when enabled.

Out of Scope: cost‑based recursion strategy selection, memoized semi‑naive evaluation, path deduplication optimizations.

Acceptance (TESTED): simple parent/child hierarchy returns correct transitive closure; cycle detection test yields diagnostic without infinite loop.

```text
CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=STUB; TEST=TestCANARY_REQ_GQL_079_ParserRecognition; BENCH=BenchmarkCANARY_REQ_GQL_079_ParserRecognition; OWNER=engine; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=FixpointDriver; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_FixpointDriver; BENCH=BenchmarkCANARY_REQ_GQL_079_FixpointDriver; OWNER=engine; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=CycleGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_CycleGuard; BENCH=BenchmarkCANARY_REQ_GQL_079_CycleGuard; OWNER=engine; UPDATED=2025-09-23
```

### REQ-GQL-080 — RLS (Row Level Security) & ABAC Enforcement Framework

Problem: Need fine‑grained access control over nodes/edges/properties based on attributes and declarative policy definitions; currently absent, limiting multi‑tenant and compliance use cases.

Scope (Phase 0):

- Policy catalog: define RLS predicates & ABAC attribute rules (JSON or DSL placeholder) bound to role identifiers.
- Enforcement hook in executor applying additional filter predicates post logical planning (security layer injection).
- Policy cache with LRU invalidation (reusing Containers requirement aspects where possible).
- Flagger: `SecurityRlsAbacExperimental`.

Out of Scope: attribute derivation functions, hierarchical roles, row‑level auditing, policy provenance.

Acceptance (TESTED): policy restricting label=Sensitive nodes excludes them for a role without permission; ABAC attribute key mismatch yields denial diagnostic; cache invalidation test confirms updated policy takes effect without restart.

```text
CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=PolicyCatalog; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_PolicyCatalog; BENCH=BenchmarkCANARY_REQ_GQL_080_PolicyCatalog; OWNER=security; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=EnforcementHook; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_EnforcementHook; BENCH=BenchmarkCANARY_REQ_GQL_080_EnforcementHook; OWNER=security; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=PolicyCache; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_080_PolicyCache; BENCH=BenchmarkCANARY_REQ_GQL_080_PolicyCache; OWNER=security; UPDATED=2025-09-23
```

### REQ-GQL-081 — Monitoring & Metrics Exporter (Prometheus Skeleton)

Problem: Limited visibility into runtime performance & health metrics restricts operational governance and alerting.

Scope (Phase 1):

- Metrics registry (counters, gauges, histograms with fixed buckets) in process.
- Prometheus exposition endpoint (plaintext format) on configurable port (disabled by default).
- Core metrics: query_latency_ms histogram, active_transactions gauge, wal_bytes_written counter, pathcache_hits/misses counters.
- Flagger: `MonitoringPrometheusExperimental`.

Out of Scope: dynamic metric creation at runtime, high‑cardinality label sets, push gateway, secure auth.

Acceptance (TESTED): metrics endpoint returns valid exposition text including at least the core metrics; histogram bucket monotonicity test; disabled mode ensures no listener binds.

```text
CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=MetricsRegistry; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_MetricsRegistry; BENCH=BenchmarkCANARY_REQ_GQL_081_MetricsRegistry; OWNER=ops; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=MetricsRegistryVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_081_MetricsRegistryVarianceEnvelope; OWNER=ops; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=PrometheusEndpoint; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_PrometheusEndpoint; BENCH=BenchmarkCANARY_REQ_GQL_081_PrometheusEndpoint; OWNER=ops; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-081; FEATURE="Monitoring"; ASPECT=CoreMetricsSet; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_081_CoreMetricsSet; BENCH=BenchmarkCANARY_REQ_GQL_081_CoreMetricsSet; OWNER=ops; UPDATED=2025-09-23
```

### REQ-GQL-082 — Backup & Restore (Full + Incremental)

Problem: Lack of durable backup capability (full & incremental) impedes disaster recovery objectives and governance requirements.

Scope (Phase 1):

- Full backup snapshot process quiescing new writes (or using MVCC snapshot) and emitting manifest + page files archive.
- Incremental backup capturing WAL segment deltas since last full/incremental reference point.
- Restore driver validating manifest checksum & page/WAL continuity.
- Flagger: `BackupRestoreExperimental`.

Out of Scope: point‑in‑time recovery beyond last incremental boundary, encrypted backup bundles, parallel backup chunking.

Acceptance (TESTED): full backup + restore round‑trip preserves small dataset integrity (row count & sample property values); incremental after small mutation applies successfully; manifest checksum mismatch test yields diagnostic.

```text
CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=FullBackup; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_FullBackup; BENCH=BenchmarkCANARY_REQ_GQL_082_FullBackup; OWNER=storage; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=IncrementalBackup; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_IncrementalBackup; BENCH=BenchmarkCANARY_REQ_GQL_082_IncrementalBackup; OWNER=storage; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-082; FEATURE="BackupRestore"; ASPECT=RestoreDriver; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_082_RestoreDriver; BENCH=BenchmarkCANARY_REQ_GQL_082_RestoreDriver; OWNER=storage; UPDATED=2025-09-23
```

### REQ-GQL-083 — WAL Compaction & Log Maintenance

Problem: Unbounded WAL growth increases recovery time and disk footprint; need compaction and archival strategy.

Scope (Phase 0):

- Identify checkpoint LSN safe for truncation (all active snapshots behind).
- Compact job rewriting live pages baseline & discarding obsolete WAL segments.
- Archival hook placeholder for shipping truncated segments (no remote I/O yet).
- Flagger: `WalCompactionExperimental`.

Out of Scope: tiered storage integration, remote archival upload, compression heuristics.

Acceptance (TESTED): compaction reduces WAL segment count for synthetic workload; recovery after compaction still replays remaining tail correctly.

```text
CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CheckpointSelection; STATUS=STUB; TEST=TestCANARY_REQ_GQL_083_CheckpointSelection; BENCH=BenchmarkCANARY_REQ_GQL_083_CheckpointSelection; OWNER=storage; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CompactionJob; STATUS=STUB; TEST=TestCANARY_REQ_GQL_083_CompactionJob; BENCH=BenchmarkCANARY_REQ_GQL_083_CompactionJob; OWNER=storage; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=ArchivalHook; STATUS=STUB; TEST=TestCANARY_REQ_GQL_083_ArchivalHook; BENCH=BenchmarkCANARY_REQ_GQL_083_ArchivalHook; OWNER=storage; UPDATED=2025-09-22
```

### REQ-GQL-084 — Selectivity Estimator & Adaptive Optimizer Scaffold

Problem: Lack of foundational statistics & selectivity estimation blocks plan quality improvements and adaptive re‑optimization.

Scope (Phase 1):

- Column/property frequency sampler (reservoir or stratified) producing approximate distinct counts & frequency sketch.
- Simple selectivity estimator API returning estimated row counts for equality & range (numeric) predicates.
- Adaptive feedback hook capturing actual vs estimated row counts to refine factor registry (ties to REQ-GQL-075 cost model).
- Flagger: `SelectivityEstimatorExperimental`.

Out of Scope: multi‑column correlation models, histograms with variable bucket widths, join selectivity estimation, sampling concurrency control.

Acceptance (TESTED): estimator returns finite non‑negative estimates; feedback hook updates calibration snapshot with new observation deltas; over/under estimation ratio reported.

```text
CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=FrequencySampler; STATUS=STUB; TEST=TestCANARY_REQ_GQL_084_FrequencySampler; BENCH=BenchmarkCANARY_REQ_GQL_084_FrequencySampler; OWNER=optimizer; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=EstimatorApi; STATUS=STUB; TEST=TestCANARY_REQ_GQL_084_EstimatorApi; BENCH=BenchmarkCANARY_REQ_GQL_084_EstimatorApi; OWNER=optimizer; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=AdaptiveFeedbackHook; STATUS=STUB; TEST=TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook; BENCH=BenchmarkCANARY_REQ_GQL_084_AdaptiveFeedbackHook; OWNER=optimizer; UPDATED=2025-09-22
```

### Summary of New Requirement IDs (High-Level)

- 078 Cluster coordination skeleton for future distribution.
- 079 Recursive execution enabling hierarchical / transitive queries.
- 080 RLS/ABAC fine‑grained security enforcement.
- 081 Monitoring & metrics export for observability.
- 082 Backup & restore (full + incremental) baseline.
- 083 WAL compaction & log maintenance to bound recovery cost.
- 084 Selectivity estimator feeding adaptive optimization.
- 085 Structured logging & level controls.
- 086 Interactive client REPL shell (multi-line editing, history, meta-commands – initial registration).
- 087 Migration engine (schema+data migrations, ledger, locking, policy enforcement, drift detection, resumable data ops).

All remain STUB; no production claims made until CANARY promotion with tests/benches.

## 12. Structured Logging & Level Controls (REQ-GQL-085)

Robust, configurable logging is required for operability, debugging, and governance correlation. Current ad-hoc `std.debug.print` statements provide no structured level filtering or machine-readable format. This requirement introduces a unified JSON Lines logger shared by `geoded` (server) and `geodec` (client) with runtime level selection.

### Scope (Phase 1 – Implemented in this slice)

- Unified logger module (`src/log/logger.zig`) exporting:
  - Level enum: `trace, debug, info, warn, error, critical` (ordered for filtering)
  - `parseLevel(str)` (case‑insensitive) → Level
  - `setLevel(l: Level)` global threshold (default `info`)
  - `log(level, msg, kv...)` emits single JSON object per line to **stderr** (never mingled with protocol result stdout) with stable key ordering: `ts, level, msg, component, fields (flattened)`
  - Pluggable sink (test harness injects memory buffer)
- CLI flag `--log-level <level>` for both `geoded` and `geodec` selecting minimum emitted level.
- Initial instrumentation points (representative, not exhaustive): server startup, selected configuration toggles, client connection intent.
- Deterministic timestamp override hook (for future test determinism) left unexposed for now; current implementation uses seconds since epoch.

### Out of Scope (Future Phases)

- Structured per-request correlation ids.
- Async buffering & backpressure strategy.
- Log rotation / file sinks.
- Redaction policies and secret detection.
- Span/trace propagation.

### Acceptance (Phase 1)

1. CLI parsing test proves case-insensitive mapping and default fallback (info) – CANARY aspect: `LogLevelCliParsing`.
2. Filtering semantics (messages below threshold suppressed) – CANARY aspect: `LogEmitterFiltering` (test may land separately; initial status STUB until evidence promoted).
3. JSON formatting stable ordering & uppercase level tokens – CANARY aspect: `LogJSONFormat`.
4. Client parity (same flag + level affects client logs) – CANARY aspect: `ClientLoggingParity`.

### CANARY Lines (Interactive REPL)

```text
CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogLevelCliParsing; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogLevelCliParsing; OWNER=ops; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogEmitterFiltering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogEmitterFiltering; OWNER=ops; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=LogJSONFormat; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_085_LogJSONFormat; OWNER=ops; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-085; FEATURE="StructuredLogging"; ASPECT=ClientLoggingParity; STATUS=STUB; TEST=TestCANARY_REQ_GQL_085_ClientLoggingParity; OWNER=ops; UPDATED=2025-09-22
```

Promotion to TESTED for each aspect requires deterministic tests asserting semantics (parsing/fallback, filtering counts, JSON schema compliance, identical level behavior client vs server). Future BENCHED aspect may guard logging throughput variance if performance overhead becomes material.

## 13. Interactive Client REPL (REQ-GQL-086)

Enhance `geodec` with an interactive, feature-rich shell (REPL) comparable to `psql`, providing multi-line editing, history, completion, syntax highlighting, meta-commands, and flexible output formats over a persistent protocol session.

### Scope (Phase 1 – Registration Only)

- Launching `geodec` with no query arguments enters interactive mode.
- Multi-line input buffering with continuation prompts (`geode->`).
- Command history persisted to `~/.geode_history` (configurable via `GEODE_HISTORY`) with max length policy.
- Basic meta-commands (Phase 1): `\help`, `\quit`, `\history`, `\set format`, `\timing`, `\connect`, `\edit` (`\e`), `\list graphs` (`\lg`).
- Session state: current graph, output format (table|json|csv|text), timing toggle, transaction indicator.
- Output formats: minimal table & JSON (others stubbed/flagged until implemented).
- Graceful Ctrl+C handling (cancel buffer or attempt query cancel if running).
- Logging integration (uses StructuredLogging requirement).

### Out of Scope (Deferred Phases)

- Tab completion of schema objects (labels, properties) beyond static keyword list.
- Syntax highlighting ANSI coloration.
- External pager integration, output redirection (`\\o`), shell escapes (`\\!`).
- Embedded server spawn / local `geoded` lifecycle mgmt.
- Advanced formatting (expanded mode `\\x`, CSV quoting rules, border styles, pretty JSON).
- Reverse incremental search (Ctrl+R) if not provided by chosen line editor.

### Acceptance (Promotion Criteria)

1. Launch with no args opens REPL and displays prompt `geode>` (TestCANARY_REQ_GQL_086_ReplLaunchPrompt).
2. Multi-line buffering: entering an unterminated statement (no trailing `;`) produces continuation prompt and accumulates until semicolon (TestCANARY_REQ_GQL_086_MultilineBuffering).
3. History persistence: commands executed are appended to history file (excluding blank lines) and reloaded across sessions (TestCANARY_REQ_GQL_086_HistoryPersistence).
4. Meta-commands basic: `\\help` lists commands; `\\set format json` affects subsequent output mode (TestCANARY_REQ_GQL_086_MetaCommandsBasic).
5. Transaction indicator: after `BEGIN` prompt changes (e.g., `geode*>`) and reverts on COMMIT/ROLLBACK (TestCANARY_REQ_GQL_086_TxnPromptIndicator).
6. Cancellation: Ctrl+C during input clears buffer without exiting; during running query emits cancellation attempt log/event (TestCANARY_REQ_GQL_086_CtrlCCancelBuffer).

### Future BENCHED (Planned)

- Latency variance of REPL round-trip echo queries (VarianceEnvelope).
- History append throughput under large history.

### CANARY Lines

```text
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=ReplLaunchPrompt; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_ReplLaunchPrompt; OWNER=client; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MultilineBuffering; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_MultilineBuffering; OWNER=client; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=HistoryPersistence; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_HistoryPersistence; OWNER=client; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MetaCommandsBasic; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_MetaCommandsBasic; OWNER=client; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=TxnPromptIndicator; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_TxnPromptIndicator; OWNER=client; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=CtrlCCancelBuffer; STATUS=STUB; TEST=TestCANARY_REQ_GQL_086_CtrlCCancelBuffer; OWNER=client; UPDATED=2025-09-22
```

## 14. Migration Engine (REQ-GQL-087)

Introduce a first-class Geode Migration Engine (GME) providing **deterministic, enforced schema & data migration governance**. It supplies a transactional migration ledger, exclusive locking with TTL+heartbeat, policy enforcement (blocking ad‑hoc DDL unless policy allows), idempotent & resumable data migrations with resume tokens, checksum & drift detection, and a CLI / library parity surface (inspired by `golang-migrate` but server‑enforced). All aspects start STUB for traceability; implementation slices will promote individually.

### 14.1 Goals

- Deterministic ordered application of schema (DDL) and optional data migrations under ACID transactions.
- Enforced exclusive migration lock: prevents competing writers & protects partial states; TTL + heartbeat to avoid orphan locks.
- Policy control: allow/deny ad-hoc schema changes outside managed migrations (STRICT vs PERMISSIVE modes) with diagnostics.
- Idempotent, resumable data migrations (chunked transforms) using resume tokens persisted atomically with progress.
- Drift detection: detect divergence between live schema and expected checksum manifest; fail fast or flag per policy.
- Strong observability: metrics & structured logs for start, success, failure, drift, resume events.
- Multi-language API parity (Go primary; Zig shim; Python wrapper planned) plus CLI commands: `migrate create`, `migrate up`, `migrate down`, `migrate status`, `migrate plan`, `migrate verify`, `migrate drift-check`, `migrate resume`.

### 14.2 Non-Goals (Phase 1)

- Automatic migration generation from schema diffs.
- Cross-shard distributed coordination (single-node scope for v0 phase).
- Online zero-downtime dual-write shadowing.
- Data anonymization / masking policies.

### 14.3 Core Artifacts & Metadata

Migration metadata tables (logical names; physical layout TBD in storage slice):

- `geode_schema_migrations` (id, version, name, type={schema|data}, checksum_sha256, applied_at, execution_ms, status, batch, resume_token, attempts, last_error_code, last_error_msg)
- `geode_schema_lock` (lock_id singleton row, owner_id, acquired_at, expires_at, heartbeat_at)
- `geode_migration_policy` (mode STRICT|PERMISSIVE, updated_at, updated_by, checksum)
- `geode_migration_drift` (detected_at, expected_checksum, observed_checksum, severity)

### 14.4 Locking Semantics

- Acquire via optimistic insert/update; must include TTL (expires_at) and periodic heartbeat updates before 50% TTL elapses.
- Heartbeat drift beyond TTL marks lock stale & reclaimable; attempted steal logged with diagnostic; prevention policy forbids steal unless expired.
- Lock release on successful completion or explicit `down` concluding batch.

### 14.5 Policy Enforcement

- STRICT: Any DDL outside managed migration results in policy diagnostic (`MigrationPolicyViolation`).
- PERMISSIVE: Logs warning & records an out-of-band change marker for later drift check.
- Policy changes require lock ownership & are logged with previous checksum.

### 14.6 Data Migration Model

- Data migrations declared as idempotent steps; progress persisted after each chunk inside same txn commit (resume_token advanced).
- Chunk size configurable; abort leaves last committed resume_token so re-run resumes at correct boundary.

### 14.7 Drift & Checksum

- Each migration directory maintains manifest with ordered versions & per-file SHA-256; combined digest stored with each applied migration.
- `drift-check` recomputes digests vs ledger; mismatch triggers diagnostic (`MigrationChecksumMismatch`) and optional hard failure when STRICT.

### 14.8 CLI Commands (Initial Set)

`create`, `plan`, `up`, `down <n|all>`, `status`, `verify`, `drift-check`, `resume`.

### 14.9 Acceptance (Promotion Criteria Examples)

1. Lock acquisition & heartbeat TTL test ensures exclusivity & expiration reclaim path.
2. Up migration applies ordered set; ledger rows inserted with checksums; re-run is a no-op (idempotent detect).
3. Policy STRICT mode blocks direct DDL (simulated) with proper diagnostic code.
4. Checksum mismatch detection surfaces diagnostic & prevents apply.
5. Resume token test: simulated data migration halts mid-way, resume picks up without duplicating work.
6. Drift detection test logs drift row & triggers policy outcome.
7. CLI parity test ensures `status` output aligns with ledger (columns subset).
8. Metrics emission test observes counters increment (applied_total, failed_total, drift_detected_total, lock_steal_attempts_total).

### 14.10 Future Phases

- Distributed coordination (multi-node lock lease via consensus).
- Automatic rollback planning / graph of dependencies.
- Declarative DSL for data transforms with cost-based chunk sizing.
- Dual-phase dry-run + commit window enforcement.

### 14.11 CANARY Lines (Migration Engine)

```text
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=MigrationLedgerSchema; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_MigrationLedgerSchema; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=LockAcquisitionTTLHeartbeat; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_LockAcquisitionTTLHeartbeat; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=UpApplyOrderingIdempotency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_UpApplyOrderingIdempotency; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PolicyEnforcementStrictMode; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_PolicyEnforcementStrictMode; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ChecksumValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_ChecksumValidation; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ResumeTokenDataMigration; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_ResumeTokenDataMigration; OWNER=migration; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_DriftDetection; OWNER=migration; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=CliParityStatusCommand; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_CliParityStatusCommand; OWNER=migration; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ObservabilityMetrics; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_ObservabilityMetrics; OWNER=migration; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftPolicyOutcomeStrict; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict; OWNER=migration; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DownReversalSafety; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_DownReversalSafety; OWNER=migration; UPDATED=2025-09-22
CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PlanDryRunIntegrity; STATUS=STUB; TEST=TestCANARY_REQ_GQL_087_PlanDryRunIntegrity; OWNER=migration; UPDATED=2025-09-22
```

Promotion path: each Migration Engine aspect STUB→TESTED with deterministic unit/integration tests (including simulated ledger + lock harness). BENCHED aspects may be added later for migration throughput & lock acquisition variance.
