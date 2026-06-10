# Gap Closure Journal — 2026-06-10 round

Plan: `docs/superpowers/plans/2026-06-10-gap-register-closure.md`
Branch: `gap-closure-2026-06-10`

## Closure log

GAP-0863a — closed — commit 487a2424 — test-e2e compiles and runs (graph_algos rewrite to real API + Zig 0.16 fuzz/bench/test migration across 22 files; 84/86 steps green; residual: gql_conformance T11/T12/T14 count(*) pushdown + unseeded G1/G2 fixture, documented in KNOWN_TEST_ISSUES.md)

GAP-0863b — closed — commit 5083a30e — test-perf-c-introspection-index green (8/8, 0 leaks). Root cause was NOT a freeable FEK (getFEK returns [32]u8 by value): the 3 leaked allocations were the process-global FLE KeyManager lazily created on testing.allocator when ambient FLE-catalog contamination (stale /tmp/geode_fle_catalog.dat + GEODE_MASTER_KEY) flipped the suite's email writes onto the real encrypt path. Fix: property-writing tests defer resetGlobalKeyStateForTesting() + new deterministic regression test that reproduces the contaminated-environment failure in an isolated GEODE_DATA_DIR (verified RED: exact 3-leak trace at fle_integration.zig:469). FLE sibling steps re-verified (gap0854 1/1, gps-fle-enforcement 11/11, gap0852 5/5, simple-merge-fastpath 11/11).
