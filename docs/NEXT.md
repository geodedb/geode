# NEXT — Verifiable Backlog (CANARY Evidence-Driven 2025-09-21)

Principle: Each slice introduces or upgrades at most one aspect per REQ and MUST add at least one new CANARY test or bench. Small, reviewable, machine-verifiable.

## Current Status Summary

Status snapshot includes recent BENCH promotions (Dijkstra shortest paths, Biconnected Components connectivity, Bridges/Articulation), A\* heuristic pathfinding, Kruskal (MST), Union-Find container, Prim (MST heap variant), PageRank, Eigenvector, Betweenness, Closeness, BridgeLeverage, and GreyCardinalComposite (composite centrality).

- **Coverage: 99.0%** (GreyCardinalComposite promoted; remaining STUB set strategic)
- **STUB aspects: 1**
- **TESTED: 87**
- **BENCHED: 52**

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
