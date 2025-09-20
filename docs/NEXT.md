# NEXT — Verifiable Backlog (CANARY Evidence-Driven 2025-09-20)

Principle: Each slice introduces or upgrades at most one aspect per REQ and MUST add at least one new CANARY test or bench. Small, reviewable, machine-verifiable.

## Current Status Summary
- **Coverage: 97.1%** (102 of 105 aspects TESTED or BENCHED)
- **STUB aspects: 3** (CDC API, Raft, Baseline Refresh)  
- **TESTED: 73**
- **BENCHED: 29**

## NOW (Critical STUB → TESTED Upgrades)

1. **REQ-GQL-042 CDC Core API** (Currently: STUB)
   - Why: Core CDC API marked STUB but test reference exists
   - What: Verify test implementation or implement missing start/stop lifecycle
   - Test: Ensure `TestCANARY_REQ_GQL_042_CDC_StartStop` is implemented
   - CANARY: Update line in docs/PROMPTS.md to STATUS=TESTED once test passes
   - Acceptance: `canaryscan` shows REQ-GQL-042 API aspect as TESTED

2. **REQ-GQL-040 Raft Consensus** (Currently: STUB)  
   - Why: Distributed foundation marked STUB
   - What: Implement basic leader election state machine
   - Test: Add `TestCANARY_REQ_GQL_040_RaftLeaderElection`
   - CANARY: Update src/distributed/raft.zig STATUS to TESTED
   - Acceptance: Basic 3-node election completes within timeout

3. **REQ-GQL-010 Benchmark Baseline Refresh** (Currently: IMPL)
   - Why: Tool exists but no test coverage
   - What: Add test for baseline refresh functionality
   - Test: `TestCANARY_REQ_GQL_010_BenchBaselineRefresh`
   - CANARY: Update src/tools/bench_regress.zig to include test
   - Acceptance: Baseline file update verified with known input

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

After NOW tasks:
- STUB count: 0 (down from 3)
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