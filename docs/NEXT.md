# NEXT — Verifiable Backlog (CANARY Evidence-Driven 2025-09-21)

Principle: Each slice introduces or upgrades at most one aspect per REQ and MUST add at least one new CANARY test or bench. Small, reviewable, machine-verifiable.

## Current Status Summary

Status snapshot includes recent BENCH promotions (Dijkstra shortest paths, Biconnected Components connectivity, Bridges/Articulation), A\* heuristic pathfinding, Kruskal (MST), Union-Find container, Prim (MST heap variant), PageRank, Eigenvector, Betweenness, Closeness, BridgeLeverage, GreyCardinalComposite (composite centrality), LFUCache container, BloomFilter container, BFS traversal, CountMinSketch probabilistic frequency structure, DFS iterative traversal, and Edmonds-Karp max flow.

- **Coverage: (in progress)**
- **STUB aspects: >0 (remaining DOT advanced, YenKShortest, PathCache, Trie, probabilistic multi-hash, string search, advanced MVCC, etc.)**
- **TESTED: 84**
- **BENCHED: 69**

## NOW (All Aspects Covered)

No remaining STUB aspects. Focus shifts to:

1. Selective BENCH upgrades for high-impact graph algorithms (completed: Dijkstra, Biconnected, Bridges/Articulation, A\*, Kruskal, Union-Find, Prim, PageRank, EigenvectorCentrality, BetweennessCentrality, ClosenessCentrality, BridgeLeverage; next: GreyCardinalComposite planning).
2. New feature incubation (Multi-Tenancy, GPU Acceleration, Federation) — introduce as STUB only when initial design doc or POC lands in-tree (to avoid premature registry growth).
3. Hardening passes: failure injection for WAL recovery, Raft under partitions with timing jitter, CDC adaptive heuristics stress.

## NEXT (Performance & Edge Cases)

1. **REQ-GQL-013 Transaction Isolation Levels**

   - Add SSI phantom read prevention test
   - Bench: `BenchmarkCANARY_REQ_GQL_013_SSI_PhantomPrevention`

2. **REQ-GQL-028 WAL Recovery Corruption Handling**

   - Add corrupted page recovery test
   - Test: `TestCANARY_REQ_GQL_028_CorruptPageRecovery`

3. **REQ-GQL-032 Constraint Cascading**

   - Add complex cascade scenario bench
   - Bench: `BenchmarkCANARY_REQ_GQL_032_CascadePerf`

4. **REQ-GQL-042 CDC Backpressure Adaptive**

   - Add dynamic threshold adjustment test
   - Test: `TestCANARY_REQ_GQL_042_BackpressureAdaptive`

5. **REQ-GQL-046 TDE Multi-Key Support**
   - Add key hierarchy test
   - Test: `TestCANARY_REQ_GQL_046_KeyHierarchy`

## LATER (Architecture & Scale)

1. **REQ-GQL-050 Multi-Tenancy** (NEW)

   - Design tenant isolation model
   - Initial CANARY: STATUS=STUB with design doc

2. **REQ-GQL-051 GPU Acceleration** (NEW)

   - Path expansion on GPU
   - Initial CANARY: STATUS=STUB with POC

3. **REQ-GQL-052 Federation** (NEW)
   - Cross-instance query routing
   - Initial CANARY: STATUS=STUB with protocol spec

## Recently Completed Slices (Traversal + Probabilistic)

1. `BloomFilterContainer` (REQ-GQL-068) BENCHED: double hashing (FNV+Wyhash), false positive tests, bulk benchmark.
2. `BFS` Traversal (REQ-GQL-062) BENCHED: added performance benchmark over layered graph, promoted from TESTED.
3. `CountMinSketch` (REQ-GQL-069) BENCHED: implementation + accuracy envelope test + throughput benchmark.
4. `DFSIterative` Traversal (REQ-GQL-062) BENCHED: pre-order traversal implementation + performance benchmark.
5. `EdmondsKarp` Max Flow (REQ-GQL-066) BENCHED: residual network BFS augmenting path implementation + benchmark.
6. `TopologicalSortKahn` (REQ-GQL-062) BENCHED: deterministic Kahn algorithm + layered DAG benchmark.
7. `DagShortestPath` (REQ-GQL-063) BENCHED: linear-time DAG relaxation using topological order + layered DAG benchmark.
8. `CycleDetectDirected` (REQ-GQL-062) BENCHED: iterative DFS with explicit frame stack and back-edge capture + synthetic cycle density benchmark.
9. `CycleDetectUndirected` (REQ-GQL-062) BENCHED: iterative DFS with parent tracking to avoid false positives, concrete simple cycle reconstruction, large chained graph + chord benchmark.
10. `Dinic` Max Flow (REQ-GQL-066) BENCHED: level graph BFS + iterative blocking flow DFS with cursor optimization; layered bipartite-esque synthetic benchmark.
11. `HopcroftKarp` Bipartite Matching (REQ-GQL-066) BENCHED: layered BFS (distance labeling) + DFS phase for maximal pairwise augmenting paths; benchmark over synthetic balanced bipartite graph with controlled density.
12. `IDDFS` Traversal (REQ-GQL-062) BENCHED: iterative deepening with depth-limited DFS passes; benchmark over 3-ary tree depth 6 (<2.4ms avg) validating geometric overhead within bound.
13. `TopologicalSortDFS` Traversal (REQ-GQL-062) BENCHED: deterministic DFS post-order reverse with cycle detection; benchmark layered DAG (120 nodes, 1296 edges) <15ms avg guard.
14. `SkipList` Container (REQ-GQL-068) BENCHED: deterministic seeded probabilistic height selection; benchmark 5k inserts + searches (<18µs/op bound) verifying ordered iteration and update semantics.
15. `Trie` Container (REQ-GQL-068) BENCHED: lexicographically ordered ASCII prefix tree with binary-searched child array; benchmark 10k inserts + 2k prefix queries (<25µs insert, <60µs prefix avg guards) confirming removal cleanup and overwrite semantics.

Result: Trie added; remaining STUB aspects focus on advanced DOT, Yen K-shortest, PathCache, Cursor/SignaledQueue, multi-hash Bloom, string search, and advanced MVCC / analytics specs.

Next Candidate Slice: Either (a) GreyCardinalComposite profiling improvements (deeper breakdown + variance guard) or (b) Flow algorithms first BENCH (Edmonds–Karp) to begin reducing remaining TESTED-only connectivity/flow aspects.

## Verification Commands

```bash
# Build scanner
go build -o ./bin/canaryscan ./tools/canaryscan

# Generate current status
./bin/canaryscan --root . --out status.json --csv status.csv

# Verify no over-claims
./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict

# Check specific requirement
grep "REQ-GQL-042.*API.*STUB" status.csv
```

## Success Metrics

After NOW tasks (projected):

- STUB count: 0 (down from 2)
- Coverage: 100% (all aspects TESTED or BENCHED)
- All CI checks green with --strict

## CANARY Line Template

```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Name"; ASPECT=Aspect; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_XXX_Feature; BENCH=BenchmarkCANARY_REQ_GQL_XXX_Feature; OWNER=team; UPDATED=2025-09-20
```

Every PR must:

1. Add/update at least one CANARY line
2. Include corresponding test/bench that compiles and passes
3. Pass `canaryscan --verify --strict`
4. Not modify UPDATED dates unless feature actually changed
