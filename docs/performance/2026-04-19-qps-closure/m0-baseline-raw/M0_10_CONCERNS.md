# M0.10 Baseline Capture — Concerns

Captured 2026-04-19 on `perf/qps-closure-2026-04-19` at commit `dc92ef41` (M0.9).

## Summary

Host tuning applied (`net.core.rmem_max=7340032`, `wmem_max=7340032`). Server started clean. Loadtest matrix run sequentially for 5 scenarios × 6 levels × 5s.

**Completed scenarios (3 of 5):** `ping`, `point_read`, `one_hop` — all 6 levels each. Raw JSONs alongside this file.

**Incomplete scenarios (2 of 5):** `two_hop` and `fan_out` never produced output files. Client exit path unclear; server spiralled and had to be SIGKILL'd after 90 min wall (~13 h 09 m CPU time, pegged ~8 cores).

## Root cause surfaced

Server teardown log shows **3,422 DebugAllocator leak reports**, every one rooted at `src/execution/planned_read_runtime.zig:962` (`materializeNode` — `allocator.dupe(u8, entry.key_ptr.*)` for property keys) with nested callers `materializePathRow`/`exploreHops` (line 663) and `materializeNode.graph_name` (line 950). Sample stack in `geode-server.log` (this dir).

Every MATCH row materialization leaks at least two string copies (property key + graph name). Over many queries, heap pressure grows; DebugAllocator's bookkeeping cost on thousands of live blocks dominates CPU and explains the 8-core-peg / 90-min stall.

This is **independent of the QPS regressions** the plan targets. It is a real latent bug exposed by running under DebugAllocator for the first time at this workload. The pre-M0 loadtest run (baseline report `LOADTEST_REPORT_2026_04_19_v0.3.8.md`) did not surface it because that run terminated earlier and the DebugAllocator leak report only fires on teardown.

## Immediate remediation (for M0.10)

1. Kept what we have: `ping`/`point_read`/`one_hop` (18 records × 6 levels = 18 records).
2. Attempting re-run of `two_hop` and `fan_out` at reduced concurrency (1,2,4) with short duration (3s) to build a partial baseline. If the server spirals again, we commit what we have and file the leak as a follow-up.

## Follow-up ticket (to file)

**Title:** `planned_read_runtime.zig materializeNode leaks property-key + graph-name dupes`

**Repro:** run any MATCH query that returns nodes with properties (e.g. `MATCH (n:Person) RETURN n`) under DebugAllocator. Expect one leak per property-key copy in `materializeNode:962` and one leak per graph-name copy in `materializeNode:950`. Path-row case adds more via `materializePathRow:663`.

**Hypothesis:** the `Node` struct returned by `materializeNode` owns the duplicated bytes but the caller never invokes a `deinit`/`freeNode` pass on the row. `owned_entities` tracking in `executePatternQuery` exists for some paths but does not cover the property map's interior string copies. Confirm by cross-referencing `owned_entities.append` call sites against the `materializeNode` allocation sites.

**Suggested fix:** either (a) have `materializeNode` take the caller's arena allocator so results drop with the query, or (b) track each interior dupe in `owned_entities` for explicit free. Arena is cleaner and matches the GAP-0755 per-query arena pool already landed.

**Scope guardrail:** not an M0.10 fix. File as its own GAP and close in a follow-up branch.
