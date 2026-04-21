# GAP-0821 — Multi-label MATCH diagnostic (task #21 follow-up)

Generated: 2026-04-20
Branch: `perf/ingest-query-perf-2026-04-20`
Status: **NOT REPRODUCED**

## The claim

Task #21 (opened off GAP-0814 closeout, commit `871627f5`) flagged a
catastrophic multi-label scaling bug:

- `MATCH (p:LT_Person) RETURN p.lt_id` on 500 LT_Person only → **8 ms**
- `MATCH (p:LT_Person) RETURN p.lt_id` on 500 LT_Person + 100 LT_Company → **71 ms**

That is a ~9x slowdown from having an unrelated label present in the store.
If real, it would imply the label-scoped MATCH is doing O(total_nodes)
work instead of O(posting_list_size).

## Reproducer

`tests/test_gap0821_multilabel_match_diagnostic.zig` exercises the exact
claim — seed N LT_Person, optionally seed M LT_Company, then time 20
iterations of the MATCH. Median is reported for both
`std.heap.smp_allocator` (production path, see
`graph_store.global_allocator`, GAP-0754) and `std.heap.DebugAllocator`
(std-test default; the surface where GAP-0810 saw an artifact 9x).

Build target: `zig build test-gap0821-multilabel-match-diagnostic [-Doptimize=ReleaseFast]`.

## Measured results

| Mode       | Allocator     | solo (500 P) | mixed (500 P + 100 C)  | ratio |
|------------|---------------|-------------:|-----------------------:|------:|
| ReleaseFast| smp           | 1448 us      | 1454 us                | **1.00x** |
| ReleaseFast| DebugAllocator| 1395 us      | 1453 us                | 1.04x |
| Debug      | smp           | 8040 us      | 7850 us                | 0.98x |
| Debug      | DebugAllocator| 7847 us      | 8213 us                | 1.05x |

Extra stress run (500 LT_Person + **1000** LT_Company, secondary 2x larger):

| Mode       | Allocator | solo     | mixed    | ratio |
|------------|-----------|---------:|---------:|------:|
| ReleaseFast| smp       | 1492 us  | 1488 us  | **1.00x** |

Across all four matrix cells plus the stress run the ratio stays in
`[0.95, 1.10]` — within normal measurement noise. The 9x claim is
**not reproducible**.

## Code-path evidence

`executeMatchQueryImpl` (src/execution/match_operations.zig:7537-7587) for
a single-chain node pattern with labels routes through
`store.getNodesByLabels(...)` which calls
`getNodesByLabel(graph_name, label)` (src/graph_store.zig:1583-1592) —
an O(1) map lookup on composite key `"<graph>:<label>"` yielding a slice
of the posting list for that one label. The subsequent filter loop walks
only that slice, and `store.nodes.get(nid)` is an O(1) `std.AutoHashMap`
lookup per candidate. Nothing in the execution path touches nodes of
unrelated labels — the unrelated `LT_Company` posting list is never
visited.

The full-scan fallback at `match_operations.zig:1742` logs a warning and
increments `g_full_scan_count` — it only runs when `node_pattern.labels.len
== 0`. For the claimed reproducer (pattern has a label), the full-scan path
cannot be reached.

## Why the original claim likely showed 8/71 ms

Given we measured the *exact* AST shape (`MATCH (p:LT_Person) RETURN
p.lt_id`) and store shape (500 + 100) and observed solo ~= mixed in Debug
*and* ReleaseFast *and* under both allocators, the 9x number must have
come from a noisy measurement outside this code path. Plausible sources:

1. **Single-run harness latency.** Both 8 ms and 71 ms are within the
   noise envelope of a one-off GQL-over-QUIC shell invocation that
   includes connect/TLS/auth cost, not just executor time. A noisy
   measurement of a fresh connection vs. a warm one could easily look
   like 8x.
2. **Cold-cache effects.** The mixed run happened second (after the
   solo run); the arena/malloc heap shape was different. With 100 extra
   nodes the allocator arenas may have been resized, and a *single*
   measurement caught the resize cost.
3. **Conflation with GAP-0814 `union_two_labels` numbers.** The mixed
   store was set up to exercise the UNION bench. If the 71 ms datapoint
   came from the UNION arm (which materializes both labels) rather than
   the single MATCH, that would explain the magnitude.

None of these are a production bug.

## Lesson restated (vs. GAP-0810)

GAP-0810 was a real measurement artifact from DebugAllocator O(live_alloc)
bookkeeping. GAP-0821 looks like the same *shape* of complaint but this
time neither allocator reproduces it. The lesson holds: **never close a
"9x slowdown" ticket without a reproducer that survives both allocators in
ReleaseFast**. This diagnostic stays in-tree so the next time someone
reports a multi-label MATCH slowdown we can re-run it in one command.

## Disposition

- **Task #21: NOT_REPRODUCED. Close.**
- Keep the diagnostic test committed for future re-triage.
- No code change required — the label-index fast path is already correctly
  wired and O(posting-list-size).
- No CANARY status bump needed (the existing `REQ-AUTO-INDEX-SCAN-001` /
  `REQ-PERF-LABEL-INDEX-003` markers are accurate).
