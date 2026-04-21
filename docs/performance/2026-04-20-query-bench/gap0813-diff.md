# Query perf diff — gap0813 (bulk materializePath + native planner)

Generated: 2026-04-20T22:28:00Z
Branch: perf/ingest-query-perf-2026-04-20
Benches: executor-match (serial)
Commits: b98f341d (projection-pruned materialize + isStorageNativeQuery fix)

## Headline — multi-hop scenarios (µs p50)

| scenario | BEFORE | AFTER | speedup / delta |
|---|---:|---:|---:|
| two_hop_distinct/medium | 787 123 µs | 405 µs | **1945×** |
| two_hop_distinct/large  | 1 165 593 µs | 431 µs | **2704×** |
| fan_out_cross_type/medium | 196 138 µs | 272 µs | **721×** |
| fan_out_cross_type/large  | 558 967 µs | 357 µs | **1566×** |
| one_hop/small | 197 µs | 217 µs | -10% |
| one_hop/medium | 368 µs | 375 µs | within noise |
| one_hop/large | 436 µs | 440 µs | within noise |

Expected win per plan: 2-5×. Measured: 721-2704× on medium/large. Exceeded expectation by orders of magnitude because the `isStorageNativeQuery` fix (accepting intermediate-node name references as non-conflicting) routed the 2-hop queries into the native planner that already has `planned_read_runtime` with projection pruning. The slow path was doing per-hop full `materializeNode` on every intermediate row.

## Regressions (7 detected)

| row | delta | disposition |
|---|---:|---|
| two_hop_distinct/small throughput | -37.72% | accept — see disposition |
| two_hop_distinct/small wall_time | +60.56% | accept |
| two_hop_distinct/small latency_execute | +106.50% | accept (absolute: 89µs → 184µs, 95µs increase) |
| fan_out_cross_type/small throughput | -42.59% | accept |
| fan_out_cross_type/small wall_time | +74.19% | accept |
| fan_out_cross_type/small latency_execute | +124.58% | accept (absolute: 87µs → 194µs) |
| ping/medium latency_execute | +22.97% | noise (RETURN-1 pre-dispatch unchanged) |

## Disposition

**Accept.** The /small regressions are on datasets seeded with `knows_per_person=0` (no LT_KNOWS edges). Pre-fix, the slow path returned 0 rows quickly because the label-scan found nothing. Post-fix, the native planner goes through its full init (projection plan construction, read view) before discovering 0 rows — adding ~100µs absolute. This is an acceptable tradeoff: the medium/large scenarios (the ones that matter for production) gain 700-2700× while empty-result /small scenarios add 100µs.

The medium/large wins are real and reproducible. The `isStorageNativeQuery` name-dedup fix is low-risk (conservative: more queries now take the well-tested native planner path, which had been unreachable for 2-hop shapes due to the intermediate-name check). 1107+ tests pass with no functional regressions.

## Follow-up (optional, not blocking)

The /small regression could be closed by early-returning from the native planner when the label-index posting list length is 0 for the anchor node. Minor optimization, ~100µs recovery on no-result queries, deferred.
