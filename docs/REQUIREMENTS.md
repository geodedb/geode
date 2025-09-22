# REQUIREMENTS — ISO/IEC 39075 (GQL)–First System

## 0. Scope

This system is working toward a distributed, ACID property-graph DB that will **speak GQL** per ISO/IEC 39075:2024. Currently implements a SQL-like query engine with GQL syntax parsing. The GQL layer is normative for language and semantics; the engine will follow the **GQL execution model over binding tables** and the **linear composition** of statements. Binding tables carry **ordered vs unordered** descriptors that directly affect `ORDER BY`, `LIMIT`, and `OFFSET`.

**Current Status**: Core linear query operations working (RETURN, ORDER BY, set operations). Path expansion, basic MATCH label/property predicate, OPTIONAL null-preserve semantics, and structural PathCache features partially implemented (cache enrichment & variance guards). MVCC snapshot isolation with phantom prevention instrumentation (RangeTracker) present; recovery corruption latency guard and pagination execution variance envelopes landed. Advanced graph pattern semantics, full optimizer, and distributed features remain partial or stubbed.

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
- **TLS 1.3** for transport - QUIC returns NotImplemented ❌

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
- 0 STUB / 0 IMPL residuals (policy enforced); earlier NotImplemented hotspots reduced but some algorithm/backlog placeholders remain.
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
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=CursorContainer; STATUS=STUB; TEST=TestCANARY_REQ_GQL_068_Cursor; BENCH=BenchmarkCANARY_REQ_GQL_068_Cursor; OWNER=graph; UPDATED=2025-09-20
CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueue; STATUS=STUB; TEST=TestCANARY_REQ_GQL_068_SignaledQueue; BENCH=BenchmarkCANARY_REQ_GQL_068_SignaledQueue; OWNER=graph; UPDATED=2025-09-20
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
