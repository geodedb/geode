# Step 2 — merge_prop_index point-read fast path (GAP-0808)

Captured on `perf/qps-closure-2026-04-19` at HEAD `f4f6343c` (post-revert
of the zero-hop guard — fast path enabled unconditionally for
`(:Label {key: scalar})` single-prop patterns).

Loadtest: `geode-test-harness/loadtest/go/geode-loadtest`, 5s per
concurrency level, fresh data dir per scenario, host tuned per
`docs/performance/host-tuning.md` (net.core.rmem_max = 7340032).

## Results vs `docs/audit/LOADTEST_REPORT_2026_04_19_v0.3.8.md` baseline

### point_read

| c | v0.3.8 QPS | after QPS | factor | v0.3.8 p50 | after p50 | after p99 |
|--:|-----------:|----------:|-------:|-----------:|----------:|----------:|
| 1 | 17.6       | **337**   | **19×** | 65 ms      | 2.9 ms    | 3.7 ms    |
| 2 | 21.0       | **530**   | **25×** | 96 ms      | 3.5 ms    | 6.2 ms    |
| 4 | 29.2       | **832**   | **28×** | 131 ms     | 4.5 ms    | 7.4 ms    |
| 8 | 25.6       | **1087**  | **42×** | 314 ms     | 7.0 ms    | 11.7 ms   |

c-scaling: **monotonically increasing** 337 → 530 → 832 → 1087.

### one_hop

| c | v0.3.8 QPS | after QPS | factor | v0.3.8 p99 | after p99 |
|--:|-----------:|----------:|-------:|-----------:|----------:|
| 1 | 6.8        | **140**   | **20×** | 228 ms     | 8.4 ms    |
| 2 | 6.2        | **260**   | **42×** | 1036 ms    | 9.7 ms    |
| 4 | 6.4        | **462**   | **72×** | 1813 ms    | 10.7 ms   |
| 8 | 5.8        | **771**   | **133×**| 3607 ms    | 13.3 ms   |

c-scaling: **monotonically increasing**, and scale factor *grows* with c
(the concurrency bottleneck pre-fix was the O(N) per-query scan — the
heavier the workload, the bigger the win).

### ping (control)

| c | after QPS | after p50 |
|--:|----------:|----------:|
| 1 | 330       | 3.0 ms    |
| 2 | 608       | 3.2 ms    |
| 4 | 941       | 4.0 ms    |
| 8 | 1481      | 5.4 ms    |

ping is within ±2 % of the v0.3.8 baseline — unchanged. This is the
pure-transport floor; point_read c=1 337 QPS now essentially matches
this floor (3 ms per query), meaning the MATCH-specific per-query
cost has been reduced below ping's overhead.

## two_hop and fan_out

Unchanged vs pre-fix (~0.5 QPS c=1, ~1 QPS c=4, saturates c=8 with
errors). These scenarios use the multi-hop traversal path which is
not covered by the merge_prop_index fast path (exploreHops +
materializeEdge dominate, which a single-slot anchor optimization
cannot help). Separate follow-up — track in the next plan.

## What the fix does

`src/execution/planned_read_runtime.collectStartSlots` (the seed-node
enumerator for the planned read runtime) previously always called
`adapter.getNodesByLabel` (returning the full label posting list —
500 LT_Person nodes for the loadtest) and then property-filtered
node-by-node. For a `MATCH (p:Label {key: scalar})` shape with a
scalar-equality property filter, this is O(N) when the
`merge_prop_index` (populated on every `setNodeProperty` — see
`src/graph_store.zig:1638`) already has the answer in O(1).

Added a fast path that:

1. Detects single-label + single-scalar-equality-prop patterns with
   no variable references.
2. Evaluates the prop value to a scalar `PropertyValue`.
3. Calls `store.lookupMergeCandidate(graph, label, key, value)`.
4. On `.found`: returns a single-slot slice (O(1), one node).
5. On `.not_found`: returns empty (authoritative — skip the O(N) scan).
6. On `.not_indexable`: falls through to the existing scan path.

Commits: `21beb882` (fast path), `5b999949` (over-conservative
zero-hop guard), `f4f6343c` (revert of the guard once we verified
multi-hop queries either benefit from or are unaffected by the
fast path).

## User target status

User's ask (this session): "continue iterating until the qps is
properly back >400qps for c1 and properly increasing with c".

- **Properly increasing with c:** ✅ achieved for point_read
  (337→530→832→1087) and one_hop (140→260→462→771).
- **>400 QPS at c=1:** ❌ measured 337. At c=1 we are transport-
  bound — ping also sits at 330 QPS. The MATCH-path per-query cost
  is already below ping's. Pushing past 400 requires either reducing
  the ~3 ms QUIC RTT or letting a single stream hold multiple
  in-flight queries (pipelining). Neither is an application-layer
  change.

The application-layer gap is closed.

## Artifacts

- `f2-point_read.json` — full 4-level after snapshot
- `f2-one_hop.json` — same
- `f2-ping.json` — control
- (RESULTS.md) — this file
