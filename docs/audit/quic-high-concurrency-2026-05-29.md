# QUIC High-Concurrency Request Admission - 2026-05-29

**Scope:** `geode`
**Status:** 4096 mixed read/mutation single-op gates pass with zero setup retries, zero execute retries, zero reconnects, and zero first-response timeouts. Sustained mixed read/write load passes at 2048 workers x 8 operations with zero retries/timeouts after shard-parallel mutation admission, tighter cooperative scheduler backoff, backlog-aware cooperative pacing, storage/index contention fixes, shared query-cache hit-path fixes, tuple-lock collision instrumentation, and restart/recovery regression coverage. The 4096 workers x 8 operations ceiling still fails and remains the next throughput target; the latest attribution runs show clean response writes, cheap read execution, dominant mutation execution/storage tail, and multi-second QUIC poll/scheduler cycles.
**Dependency state:** Geode now pins QUIC `06f4aadcf045a0d6295c7e85398b94c7096accb9` and `geode-client-zig` `5ae310237f6cbdf6cc2716fe4eca9f43f4facfbd`. QUIC `06f4aad` preserves the proven `eeeb216` four-batch server receive behavior and adds `REQ-QUIC-HC-168`, routing generic/coalesced long-header dispatch through the same per-connection TLS serializer as the optimized burst receive path.

## Summary

The prior 2026-05-28 closeout left 4096 synchronized single-operation execution as the next transport-admission target. This cycle kept the dependency pins aligned and fixed the next Geode-side bottlenecks:

1. The high-concurrency protocol client was polling every WouldBlock at a fixed 100 us cadence. At 4096 local client threads this made the test driver a CPU storm and starved the child server. `REQ-QUIC-HC-149` now polls immediately, then uses a bounded adaptive wait and resets the backoff on successful reads.
2. Cooperative first-stream mutation admission originally allowed wide mutation fan-out through one class. `REQ-QUIC-HC-150` keeps general writer-lock mutations at a serial cap of 4, while the shard-parallel `MERGE` class now defaults to a 128 cap.
3. Failed 4k probes printed thousands of duplicate worker timeout lines. `REQ-QUIC-HC-152` caps per-worker failure logs at 64 while preserving exact counters and final phase summaries.
4. The cooperative mutation-admission cap is now tunable through `GEODE_QUIC_MUTATION_ADMISSION_CAP`. General writer-lock mutations keep an internal serial cap of 4, while the tunable cap controls the shard-parallel multi-property `MERGE` window and defaults to 128.
5. The high-concurrency E2E summary now reports `read_failed` and `mutation_failed`, making overloaded probes distinguish read-tail transport/scheduler stalls from mutation-specific write pressure.
6. The next 250 us mixed ceiling probe localized the remaining tail to upstream QUIC short-header ACK/frame processing. QUIC `a68d36e` now defers the first server-side STREAM-only standalone ACK so request/response traffic can piggyback ACKs on response packets, while an `AppAckDelay` timer preserves max-ACK-delay behavior for quiet/upload-only peers.
7. `REQ-QUIC-HC-153` adds runtime metrics for server-side QUIC `stream.writeAll` elapsed time (`quic_stream_write_elapsed_ns_total` and `quic_stream_write_elapsed_max_ns`), so operators can split query execution from response delivery.
8. `REQ-QUIC-HC-154` and `REQ-QUIC-HC-155` add high-concurrency harness timing for ready-to-first-EXECUTE lag, EXECUTE write/flush time, first-response wait/read time, response message read time, and first-response timeouts. The 4096/250 us ceiling now shows a measurable client-side wake/write storm in addition to server response tail.
9. The local test-driver start barrier now wakes 64 workers per tick instead of 256 at 1024+ workers. This preserves the configured per-worker request stagger while reducing same-process scheduler contention before the server becomes the bottleneck.
10. `REQ-QUIC-HC-156` keeps low-fanout client behavior unchanged but disables immediate post-write `poll(0)` in 1024+ same-process harness fanout by default. The response read path already polls on WouldBlock, so high-fanout probes avoid spending hundreds of milliseconds per worker inside local client flush calls before the server is the limiting factor.
11. `REQ-QUIC-HC-157` adds first-stream scheduler metrics for ready-queue wait, per-packet processing time, and mutation-admission deferrals. The 4096/250 us diagnostic showed `quic_stream_write_errors_total=0` and `quic_stream_write_timeouts_total=0`, separating response-write health from scheduler and packet-processing tail.
12. `REQ-QUIC-HC-158` fixes an RLS classification bottleneck: authenticated reads no longer treat startup's empty label/expression RLS engines as active row filters. The 4096/250 us stress ceiling now passes with `mg_rwlock_shared_hold_snapshot_ns_total=0`, confirming count reads stay on the label-refcount fast path unless policies are actually installed.
13. `REQ-QUIC-HC-159` changes cooperative mutation overflow from immediate ready-queue requeue to permit-gated parking. Overflow packets keep stream ordering in `pending_packet`, but are only schedulable again when `mutation_inflight < mutation_limit`; `releaseMutationPermit()` wakes one parked waiter. This drops 4096x8 mutation deferrals from multi-million churn to thousands while preserving the 1024x8 sustained pass.
14. Upstream QUIC commit `da08ef4` tested a one-batch server short-header app receive budget. It regressed 1024x8 throughput and 4096 setup, so QUIC `9a35274`, `geode-client-zig` `5a6b65a`, and Geode pinned the revert.
15. `REQ-QUIC-HC-160` splits cooperative mutation admission into a four-wide serial window and a wider shard-parallel window. The wider window is deliberately limited to single no-RETURN node `MERGE` statements with at least two merge properties, matching the `bulkMergeNodeWithReservedIdMultiProp` tuple-lock path instead of the whole-graph writer path.
16. `REQ-QUIC-HC-147` follow-up tightens the cooperative post-turn backoff from the previous 3 ms cap to a 1 ms cap. This keeps poll-worker yielding under high fanout but avoids adding seconds of scheduler latency across sustained multi-operation streams.
17. Upstream QUIC commits `c2874fb` and `76b45ec` tested a short-header wall-clock receive yield after the 4096x8 diagnostics pointed at multi-second poll cycles. The first variant regressed setup retries by shrinking server receive slices; the repaired full-batch variant still regressed the accepted 4096 single-op gate to `ok=1043/4096` with `3053` first-response timeouts. QUIC `108d06d`, `geode-client-zig` `2f1bfe0`, and Geode now pin the revert.
18. `REQ-QUIC-HC-161` exposes the upstream `GEODE_QUIC_SHORT_HEADER_TIMING` diagnostics through the high-concurrency E2E harness as `GEODE_HC_SHORT_HEADER_TIMING`. A 4096x8 diagnostic run split the remaining long poll cycle into cumulative short-header receive work, led by frame processing rather than a single Geode response-write stall. Upstream QUIC `6224b28` tested a slow full-batch yield, but the required 4096 single-op gate rejected it; QUIC `eeeb216`, `geode-client-zig` `533cde8`, and Geode now pin the revert.
19. `REQ-QUIC-HC-162` reduces multi-property `MERGE` contention by reading exact-property posting lengths before copying candidates. The high-concurrency `MERGE (:HCParallel {worker, seq})` shape now copies the tiny `worker` posting instead of always copying the larger `seq` posting before choosing the minimum.
20. `REQ-QUIC-HC-163` replaces the global label-count mutex with atomic per-label refcounts protected by an rwlock for HashMap pointer stability. Existing-label count reads, increments, and decrements now run under a shared lock and mutate only atomics.
21. `REQ-QUIC-HC-164` changes shared AST cache hits/releases from an exclusive mutex to a shared rwlock plus atomic hit/access/refcount fields. Same-query read fanout no longer serializes every cached parse hit.
22. `REQ-QUIC-HC-165` applies the same shared-hit pattern to the shared plan cache and stores cached shared plans on stable heap allocations, avoiding active handles pointing into movable HashMap entries while unrelated misses insert/evict.
23. `REQ-QUIC-HC-166` keeps mutating programs out of the shared optimizer. Mutation fast paths do not consume optimizer hints, and literal-heavy mutation requests create mostly one-shot plan-cache misses under mixed fanout.
24. After the cache/storage cycle, the 4096x8 read-only low-stagger probe improved from 11466 first-response timeouts to 9851. The 4096x8 mixed low-stagger probe improved from the earlier 12293-timeout ceiling to 9045 after mutation optimizer admission was disabled, but it still fails the 10s first-response budget.
25. `REQ-QUIC-HC-167` raises multi-property `MERGE` tuple-lock striping from 4096 to 16384 and heap-allocates the stripe table per graph so the ReleaseFast object file does not carry a large static mutex array. Runtime metrics now expose tuple-lock acquire count, cumulative wait/hold time, and max wait/hold samples. A 65k static-stripe variant was rejected because it regressed the 4096x8 probe and produced a much heavier ReleaseFast compile.
26. Upstream QUIC `REQ-QUIC-HC-168` closes the remaining `pollCrypto` crash surface in the generic/coalesced long-header dispatcher. `processIncomingDatagram()` no longer calls `incoming.processInitial()` or `incoming.processHandshake()` directly for supported Initial/Handshake packets; it uses the endpoint-owned concurrent wrappers so Endpoint.mu protects connection lookup/creation and `endpoint_rx_serial_mu` protects per-connection TLS mutation.
27. `REQ-QUIC-HC-169` adds first-stream phase metrics for query prepare, query execution, and response send. The next 4096x8 diagnostic can now split the existing aggregate packet-processing tail into parse/cache/authorization prep, storage/executor work, and protobuf/QUIC response delivery.
28. `REQ-QUIC-HC-170` turns the high-concurrency E2E harness into an objective runner when `GEODE_HC_OBJECTIVE_GATE=1` is set. The objective mode defaults to 16384 clients x 8 ops, 25% mutations, 99.95% completion, zero first-response timeouts, 10k QPS, p50/p95/p99/p99.9 latency gates, graph-isolation verification, restart/recovery verification, and a bounded server RSS delta. The default test step remains lightweight and strict at 100% completion unless the explicit gate knobs are overridden.
29. `REQ-QUIC-HC-171` fixes the group-commit restart durability gap exposed by the new recovery gate. Clean adapter shutdown now checkpoints loaded per-graph engines even when group-commit writes did not mark the compatibility `GraphStore` dirty, and first-seen labels now go through the sharded engine label API so label dictionaries are broadcast, dirtied, checkpointed, and available when nodes reload.
30. `REQ-QUIC-HC-172` adds scrapeable runtime attribution to the metrics server and high-concurrency harness. The server appends a runtime snapshot callback to `/metrics`, the harness enables a private metrics port with `GEODE_HC_METRICS_SCRAPE=1`, and the metrics server self-wakes its accept loop during shutdown so scrape-enabled lifecycle tests do not hang after a successful read.
31. `REQ-QUIC-HC-173` splits first-stream query execution metrics into read and mutation counters. The latest 4096x8 attribution run showed read execution at about 1.3 seconds total across 22419 samples, while mutation execution consumed about 15727 seconds total across 7448 samples.
32. `REQ-QUIC-HC-174` exposes group-commit shard coalescing through `GEODE_GROUP_COMMIT_COALESCE_US` for controlled sweeps. The default is now 500 us after 2048x8 mixed probes showed 100 us still produced first-response timeouts and 2000 us regressed tail completion.
33. `REQ-QUIC-HC-175` adds opt-in coordinator phase metrics for submit wait, enqueue wait, queue wait, queue depth, coalescing, batch total, begin-txn, apply loop, commit, and wake time. The timers are disabled by default because the 2048x8 diagnostic showed detailed per-mutation timing can perturb the sustained gate.
34. `REQ-QUIC-HC-176` makes cooperative first-stream post-turn pacing backlog-aware. The scheduler now tracks ready-queue depth with an atomic counter and skips the 1 ms high-fanout sleep only when queued ready work exceeds the worker pool. This preserves poller fairness once the scheduler catches up while reducing ready-queue head-of-line delay during 1024/2048 sustained fanout.

## Changed Files

- `src/server/quic_connection_handler.zig`
  - Keeps general writer-lock mutation admission at a serial cap of 4.
  - Adds a shard-parallel mutation admission class for simple multi-property `MERGE`.
  - Uses the effective runtime cap when deriving `FirstStreamScheduler.shard_parallel_mutation_limit`.
  - Parks mutation-overflow packets behind the mutation permit release path instead of immediately spinning them through the ready queue.
  - Lowers cooperative first-stream post-turn sleep to a 1 ms cap so sustained follow-up operations do not accumulate avoidable scheduler tail.
  - Tracks cooperative ready-queue depth and skips the post-turn backoff only while the ready backlog is larger than the scheduler worker pool.
  - Skips the shared optimizer for mutating programs, reusing the same mutation classification later for lock selection.
- `src/storage/graph_storage_adapter.zig`
  - Adds exact-property posting-length probing and copies only the smallest available candidate posting for multi-property `MERGE`.
  - Raises multi-property `MERGE` tuple-lock striping to 16k heap-allocated mutexes per graph.
  - Registers tuple-lock wait/hold metrics as `mg_merge_tuple_lock_*` runtime counters.
  - Resolves first-seen labels through `ShardedGraphEngine.getOrAssignLabel()` so group-commit-created nodes reload with label names after checkpoint/restart.
- `src/graph_store.zig`
  - Replaces the global label-count mutex with atomic refcount values guarded by an rwlock for map stability.
  - Checkpoints loaded per-graph engines during global adapter shutdown after group-commit coordinators drain.
- `src/server/query_ast_cache.zig`
  - Converts shared AST cache hits/releases to shared rwlock access with atomic counters and refcounts.
- `src/server/query_plan_cache.zig`
  - Converts shared plan cache hits/releases to shared rwlock access with atomic counters/refcounts.
  - Stores shared cached plans on stable heap pointers so active handles survive unrelated HashMap inserts and evictions.
- `src/server/main.zig`
  - Adds `GEODE_QUIC_MUTATION_ADMISSION_CAP` as an explicit server runtime override for shard-parallel mutation ceiling probes and emergency tuning.
  - Registers the runtime metrics snapshot callback with the metrics server and clears it before registry teardown.
- `src/monitoring/metrics_server.zig`
  - Appends optional runtime metrics to `/metrics`.
  - Wakes the accept loop during shutdown so a thread blocked in `accept4()` exits after scrape-enabled tests.
- `src/storage/group_commit.zig`
  - Adds `GEODE_GROUP_COMMIT_COALESCE_US` as a bounded runtime knob for shard worker coalescing sweeps.
  - Adds `GEODE_GROUP_COMMIT_PHASE_METRICS` as an opt-in phase attribution switch for coordinator submit and apply timing.
- `tests/proto_test_util.zig`
  - Adds adaptive read polling for `QuicProtoClient`.
  - Keeps immediate `poll(0)` after writes and after packet reads for normal client use.
  - Adds optional `ExecTiming` collection around `executeAndCollectWithTimeoutTiming`.
  - Splits EXECUTE write timing into prepare, stream-write, and post-write poll components.
  - Allows the high-fanout harness to defer the post-write poll while preserving the normal default.
- `tests/e2e_quic_high_concurrency.zig`
  - Caps individual failure log lines without changing counters.
  - Adds read/mutation failure split counters to failed workload summaries.
  - Adds request/response phase timing summaries and reduces high-fanout start-barrier wake batches to 64.
  - Defaults `GEODE_HC_POST_WRITE_POLL` to false for 1024+ workers and true below that threshold.
  - Forwards `GEODE_HC_SHORT_HEADER_TIMING=1` to the child server as `GEODE_QUIC_SHORT_HEADER_TIMING=1` for upstream short-header subphase diagnostics.
  - Adds opt-in objective gate defaults and pass/fail thresholds through `GEODE_HC_OBJECTIVE_GATE=1`.
  - Records successful operation latency samples and emits p50/p95/p99/p99.9 percentiles.
  - Reports child-server RSS before/after client release and gates the delta when `GEODE_HC_MEMORY_GROWTH_MAX_KB` is nonzero.
  - Optionally verifies graph isolation and restart recovery after the workload.
  - Optionally enables the child `/metrics` endpoint with `GEODE_HC_METRICS_SCRAPE=1` and prints selected runtime counters after the workload.
  - Passes through `GEODE_HC_GROUP_COMMIT`, `GEODE_HC_GROUP_COMMIT_COALESCE_US`, `GEODE_HC_GROUP_COMMIT_PHASE_METRICS`, and `GEODE_HC_MUTATION_ADMISSION_CAP` for explicit tuning sweeps.
- `tests/perf/test_group_commit_coordinator.zig`
  - Adds `REQ-QUIC-HC-171` coverage proving sharded coordinator inserts survive adapter teardown/reopen with labels and properties intact.
- `tests/test_quic_condition_timedwait_cadence.zig`
  - Source-audits the mutation window cap, runtime override, adaptive polling shape, failure-log backpressure, failure split counters, response write latency metrics, split timing summaries, deferred high-fanout post-write flushing, and the short-header timing harness switch.
  - Source-audits the smallest-posting MERGE preselect, atomic label refcounts, shared AST/plan cache hit paths, stable shared-plan storage, and read-only optimizer admission.
  - Source-audits the objective gate knobs, percentile emission, graph-isolation verification, restart recovery, RSS gate wiring, adapter-shutdown checkpoint, and group-commit label dictionary persistence guard.
  - Source-audits the runtime metrics scrape callback, accept-loop wake, read/mutation execution split, group-commit coalescing knob, and new harness passthroughs.
  - Source-audits backlog-aware cooperative first-stream pacing and ready-depth accounting.
- `tests/test_metrics_server_lifecycle.zig`
  - Adds a `/metrics` lifecycle regression proving runtime high-concurrency counters are appended and server shutdown returns after a scrape.
- `tests/test_gap0810_parse_cache_wrapper.zig`
  - Adds a concurrent shared AST cache hit/release regression test.
- `tests/test_plan_cache_hit.zig`
  - Adds a concurrent shared plan cache hit/release regression test.
- `src/transport/quic.zig`
  - Records elapsed server-side QUIC stream write time for every response write.
- `src/transport/quic_response_metrics.zig`
  - Exposes cumulative and max response stream-write elapsed counters through runtime metrics.
  - Exposes first-stream ready queue wait, packet-processing, and mutation-deferral counters.
  - Exposes read and mutation query-execution sample, cumulative, and max counters.
- `src/execution/match_operations.zig`
  - Treats empty startup RLS engines as default-allow for fast-path classification, while preserving the RLS fallback as soon as label or expression policies exist.
- `src/security/rls_core.zig`
  - Adds a cheap `hasPolicies()` probe so execution can distinguish an empty expression RLS engine from one that may filter rows.
- `tests/test_rls_expr_engine_wiring.zig`
  - Adds `REQ-QUIC-HC-158` coverage proving empty RLS engines do not force authenticated reads onto the snapshot path and installed policies still do.
- `build.zig`
  - Adds a focused `test-rls-expr-engine-wiring` step for the RLS dispatch regression.
- `build.zig.zon`
  - Pins both direct QUIC and embedded `geode-client-zig` to the upstream server STREAM ACK fanout fix plus the reverts of the rejected one-batch, wall-clock, and slow-batch short-header cadence experiments.
- `docs/performance/quic-high-concurrency.md`
  - Documents the full 16k x 8 objective command, threshold semantics, percentile output, RSS output, and objective gate controls.

## Accepted Verification

All commands below were run on 2026-05-29.

| Command | Result |
|---------|--------|
| `zig build test-rls-expr-engine-wiring --summary all` | PASS, 4/4 tests after the empty-RLS-engine fast-path regression coverage. |
| Upstream QUIC `zig build test -Dtest-filter=thread_safety --summary all` | PASS, 10/10 tests including `generic_long_header_dispatch_uses_serialized_tls_wrappers` after QUIC `06f4aad`. |
| Upstream QUIC `zig build test -Dtest-filter=pending_hs_send --summary all` | PASS, 3/3 tests after QUIC `06f4aad`, preserving the earlier deferred-handshake retry serialization guard. |
| Upstream QUIC `zig build --summary all` | PASS, 10/10 steps after QUIC `06f4aad`. |
| `geode-client-zig` `zig build --summary all` | PASS, 15/15 steps after repinning to QUIC `06f4aad`. |
| `geode-client-zig` `zig build test --summary all` | PASS, 420/420 tests after repinning to QUIC `06f4aad`. |
| `zig build test-quic-condition-cadence --summary all` | PASS, 74/74 tests after shard-parallel mutation admission, permit-gated overflow, dependency source audits, storage/index contention audits, shared cache audits, objective gate source audits, group-commit durability source audits, and runtime metrics scrape/source audits. |
| `zig build test-metrics-server --summary all` | PASS, 4/4 tests including the `/metrics` runtime snapshot append and shutdown wake regression. |
| `zig build test-group-commit-coordinator --summary all` | PASS, 9/9 tests including `REQ-QUIC-HC-171: group commit inserts survive adapter reopen`. |
| `zig build test-graph-storage-adapter-metrics --summary all` | PASS, 4/4 tests after the smallest-posting multi-property `MERGE` preselect and tuple-lock stripe-density regression. |
| `zig build test-plan-cache-hit --summary all` | PASS, 5/5 tests after the shared plan cache concurrent-hit/release and stable-plan-handle changes. |
| `zig build test --summary all -Dtest-shard-total=8 -Dtest-shard-index=1` | PASS, 404/404 tests, including the shared AST cache wrapper concurrent-hit test. |
| `zig build test --summary all -Dtest-shard-total=8 -Dtest-shard-index=7` | PASS, 322/323 tests passed, 1 skipped, including graph-store unit coverage. |
| 1024 workers x 8 ops mixed sustained E2E | PASS, 8192/8192 operations, zero retries, zero reconnects, zero first-response timeouts, 3925.76 QPS. |
| 1024 workers x 8 ops mixed sustained E2E with runtime scrape | PASS, 8192/8192 operations, zero first-response timeouts, 3926.63 QPS, and read/mutation execution split captured through `/metrics`. |
| 1024 workers x 8 ops mixed E2E after gating coordinator phase metrics | PASS, 8192/8192 operations, zero first-response timeouts, 3964.30 QPS with `GEODE_HC_METRICS_SCRAPE` unset. |
| 1024 workers x 8 ops mixed E2E with 500 us coalescing and cap 128 | PASS, 8192/8192 operations, zero first-response timeouts, 3724.24 QPS. This is a small 1024 regression but keeps the lower fan-out gate clean. |
| 2048 workers x 8 ops mixed sustained E2E with default 500 us coalescing and cap 128 | PASS, 16384/16384 operations, zero retries, zero reconnects, zero first-response timeouts, 821.63 QPS with metrics scrape disabled. |
| 2048 workers x 8 ops mixed sustained E2E with 500 us coalescing and cap 128 plus runtime scrape | PASS, 16384/16384 operations, zero retries, zero reconnects, zero first-response timeouts, 1011.66 QPS. Runtime scrape showed mutation execution still dominates, but ready-queue wait and completion improved over the 100 us / cap 512 run. |
| 1024 workers x 8 ops mixed E2E after backlog-aware cooperative pacing | PASS, 8192/8192 operations, zero retries, zero reconnects, zero first-response timeouts, 3867.52 QPS, p50=216.17 ms, p95=476.37 ms, p99=651.68 ms, p99.9=861.51 ms. |
| 2048 workers x 8 ops mixed E2E after backlog-aware cooperative pacing | PASS, 16384/16384 operations, zero retries, zero reconnects, zero first-response timeouts, 848.39 QPS, p50=2154.31 ms, p95=4723.65 ms, p99=6123.36 ms, p99.9=7424.62 ms. |
| 4096 workers x 8 ops mixed E2E after backlog-aware cooperative pacing | FAIL, 23067/32768 operations, zero setup/execute retries, zero reconnects, 9701 first-response timeouts, 432.28 QPS, p50=4991.34 ms, p95=9498.71 ms, p99=9898.76 ms, p99.9=9991.77 ms. |
| 4096 mixed single-op E2E at 250 us | PASS, 4096/4096 operations, zero retries, zero reconnects, zero first-response timeouts, 664.88 QPS after the final QUIC `eeeb216` and client `533cde8` repin. |
| 4096 workers x 8 ops read-only sustained E2E at 250 us | FAIL, 22917/32768 operations, zero setup/execute retries, 9851 first-response timeouts after shared AST/plan cache hit-path changes. This improved from 21302/32768 and 11466 first-response timeouts before the shared-cache work. |
| 4096 workers x 8 ops mixed sustained E2E at 250 us | FAIL, 23723/32768 operations, zero setup/execute retries, 9045 first-response timeouts after mutation optimizer admission was disabled. This is the remaining low-stagger ceiling. |
| 4096 workers x 8 ops mixed sustained E2E at 1000 us | FAIL, 25800/32768 operations, zero setup/execute retries, 6968 first-response timeouts. This is the current latency-friendly ceiling. |
| 4096 workers x 8 ops mixed sustained E2E with runtime scrape at 250 us | FAIL, 26634/32768 operations, zero setup/execute retries, 6134 first-response timeouts. The scrape split the tail into clean server response writes, cheap read execution, dominant mutation execution/storage time, and multi-second QUIC poll/scheduler cycles. |
| `zig build --summary all` after final dependency repin | PASS, 52/52 steps succeeded against QUIC `06f4aad` and `geode-client-zig` `5ae3102`. |
| 1024 mixed single-op E2E after `06f4aad` repin | PASS, 1024/1024 operations, 256 mutations, zero setup/execute retries, zero reconnects, zero first-response timeouts, 3822.45 QPS. |
| 4096 read-only 250 us low-stagger probe | PASS, 4096/4096 operations, zero retries, zero reconnects. |
| 1024 mixed 250 us timing smoke | PASS, 1024/1024 operations at 3822.30 QPS after deferred high-fanout post-write flush, validating the split timing summary path. |
| 8 workers x 2 ops mixed restart smoke | PASS, 16/16 operations, 8 mutations, zero retries, zero reconnects, zero first-response timeouts, `graph_isolation=ok`, `restart_recovery=ok`, and zero gate failures. |
| 8 workers x 2 ops mixed runtime-scrape smoke | PASS, 16/16 operations, 8 mutations, zero retries, zero reconnects, zero first-response timeouts, and the expected runtime metrics printed from `/metrics`. |

### Rejected Pacing Variants

Two scheduler pacing variants were rejected during this cycle:

- Quarter-pool backlog threshold (`ready_depth > workers / 4`): one 2048x8 run passed at 1001.88 QPS with zero first-response timeouts, but a rerun of the same final shape missed two reads (`16382/16384`, two first-response timeouts). This was treated as unstable and not accepted.
- 2048-context guard around the backlog skip: intended to keep 4096+ on the stronger poller-fairness path, but it failed the 2048x8 gate with `16373/16384` operations, 11 first-response timeouts, and 775.63 QPS.

The accepted `REQ-QUIC-HC-176` threshold skips the post-turn sleep only when `ready_depth` exceeds the full cooperative scheduler worker count. That variant passed the 1024x8 and 2048x8 sustained gates and still documents the 4096x8 failure as the next ceiling.

4096 mixed read/mutation gate:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=1 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=1000 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=1 mutation_stride=4 ops=4096 reads=3072 mutations=1024
setup_ms=5119 elapsed_ms=4214 qps=971.94
avg_read_ms=117.60 avg_mut_ms=120.11 avg_first_op_ms=118.23 max_ms=543.07
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

Timing summary from the same accepted run:

```text
timing samples=4096 response_messages=8192 first_response_timeouts=0
avg_ready_to_first_execute_ms=12.65 max_ready_to_first_execute_ms=25.47
avg_execute_write_ms=0.05 avg_execute_prepare_ms=0.00
avg_execute_stream_write_ms=0.04 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=118.10 max_first_response_wait_ms=543.00
avg_first_response_read_ms=118.10 avg_response_read_ms=118.14
avg_response_message_read_ms=59.07
```

4096 mixed read/mutation 250 us single-op gate after the final dependency repin:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=1 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=500 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=1 mutation_stride=4 ops=4096 reads=3072 mutations=1024
setup_ms=5128 elapsed_ms=6160 qps=664.88
avg_read_ms=4628.74 avg_mut_ms=4643.24 avg_first_op_ms=4632.37 max_ms=5742.95
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
timing samples=4096 response_messages=8192 first_response_timeouts=0
avg_ready_to_first_execute_ms=16.62 max_ready_to_first_execute_ms=374.56
avg_execute_write_ms=0.48 avg_execute_prepare_ms=0.34
avg_execute_stream_write_ms=0.13 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=4630.20 max_first_response_wait_ms=5742.86
avg_first_response_read_ms=4630.20 avg_response_read_ms=4630.24
avg_response_message_read_ms=2315.12
```

Diagnostic run with server metrics enabled (`GEODE_HC_CAPTURE_SERVER_LOGS=1`,
`GEODE_QUIC_SHORT_HEADER_TIMING=1`) also passed at 4096/250 us. Key metrics:

```text
quic_first_stream_ready_queue_wait_ns_total=64283178793
quic_first_stream_ready_queue_wait_max_ns=298639307
quic_first_stream_packet_process_ns_total=8565786675
quic_first_stream_packet_process_max_ns=119557461
quic_first_stream_mutation_deferrals_total=51894
mg_rwlock_shared_hold_snapshot_ns_total=0
quic_stream_write_errors_total=0
quic_stream_write_timeouts_total=0
```

1024 mixed 250 us timing smoke:

```text
workers=1024 ops_per_worker=1 mutation_stride=4 ops=1024 reads=768 mutations=256
setup_ms=1370 elapsed_ms=268 qps=3809.44
avg_read_ms=18.63 avg_mut_ms=24.12 avg_first_op_ms=20.00 max_ms=104.36
timing samples=1024 response_messages=2048 first_response_timeouts=0
avg_ready_to_first_execute_ms=3.32 max_ready_to_first_execute_ms=7.44
avg_execute_write_ms=0.48
avg_first_response_wait_ms=19.47 max_first_response_wait_ms=103.24
```

Latest run after deferred high-fanout post-write flushing:

```text
workers=1024 ops_per_worker=1 mutation_stride=4 ops=1024 reads=768 mutations=256
setup_ms=1378 elapsed_ms=267 qps=3822.30
avg_read_ms=16.94 avg_mut_ms=22.92 avg_first_op_ms=18.44 max_ms=112.92
timing samples=1024 response_messages=2048 first_response_timeouts=0
avg_ready_to_first_execute_ms=3.32 max_ready_to_first_execute_ms=6.50
avg_execute_write_ms=0.03 avg_execute_prepare_ms=0.00
avg_execute_stream_write_ms=0.03 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=18.34 max_first_response_wait_ms=112.84
```

1024 workers x 8 operations sustained mixed run after permit-gated mutation overflow:

```sh
GEODE_HC_WORKERS=1024 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 900s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=1024 ops_per_worker=8 mutation_stride=4 ops=8192 reads=6144 mutations=2048
setup_ms=1377 elapsed_ms=2086 qps=3925.76
avg_read_ms=222.91 avg_mut_ms=226.05 avg_first_op_ms=188.09
avg_followup_op_ms=228.78 max_ms=1043.33
setup_attempts=1024 setup_retries=0
execute_attempts=8192 execute_retries=0 execute_reconnects=0
timing samples=8192 response_messages=16384 first_response_timeouts=0
avg_ready_to_first_execute_ms=3.82 max_ready_to_first_execute_ms=39.98
avg_execute_write_ms=0.06 avg_execute_prepare_ms=0.00
avg_execute_stream_write_ms=0.05 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=223.55 max_first_response_wait_ms=1042.84
```

2048 workers x 8 operations sustained mixed run after shard-parallel mutation admission, tighter scheduler backoff, and storage/cache contention fixes:

```sh
GEODE_HC_WORKERS=2048 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 900s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=2048 ops_per_worker=8 mutation_stride=4 ops=16384 reads=12288 mutations=4096
setup_ms=1694 elapsed_ms=19940 qps=821.63
avg_read_ms=2334.74 avg_mut_ms=2385.35 avg_first_op_ms=1130.62
avg_followup_op_ms=2521.22 max_ms=9790.01
setup_attempts=2048 setup_retries=0
execute_attempts=16384 execute_retries=0 execute_reconnects=0
timing samples=16384 response_messages=32768 first_response_timeouts=0
avg_ready_to_first_execute_ms=7.66 max_ready_to_first_execute_ms=104.31
avg_execute_write_ms=0.10 avg_execute_prepare_ms=0.02
avg_execute_stream_write_ms=0.07 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=2347.17 max_first_response_wait_ms=9789.93
avg_response_read_ms=2347.20 avg_response_message_read_ms=1173.60
```

4096 workers x 8 operations sustained mixed low-stagger ceiling:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=8 mutation_stride=4 ops_started=32768
ok=23723 read_failed=6751 mutation_failed=2294 worker_failures=9045
setup_attempts=4096 setup_retries=0
execute_attempts=32768 execute_retries=0 execute_reconnects=0
timing samples=32768 response_messages=47446 first_response_timeouts=9045
avg_ready_to_first_execute_ms=16.32 max_ready_to_first_execute_ms=372.72
avg_execute_write_ms=0.20 avg_execute_prepare_ms=0.07
avg_execute_stream_write_ms=0.11 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=5700.77 max_first_response_wait_ms=10222.99
avg_response_read_ms=5700.81 avg_response_message_read_ms=3937.19
```

Latest 4096 workers x 8 operations runtime-scraped attribution run:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
GEODE_HC_GROUP_COMMIT_COALESCE_US=100 \
GEODE_HC_METRICS_SCRAPE=1 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=8 mutation_stride=4 ops_started=32768
ok=26634 read_failed=3954 mutation_failed=2180 worker_failures=6134
setup_attempts=4096 setup_retries=0
execute_attempts=32768 execute_retries=0 execute_reconnects=0
timing samples=32768 response_messages=53268 first_response_timeouts=6134
elapsed_ms=57420 qps=570.08
latency_percentiles p50_ms=3968.42 p95_ms=9114.24 p99_ms=9977.52 p999_ms=10009.45
```

Runtime attribution from the same run:

```text
quic_stream_write_calls_total=33963
quic_stream_write_success_total=33963
quic_stream_write_errors_total=0
quic_stream_write_timeouts_total=0
quic_stream_write_elapsed_ns_total=3061031412
quic_first_stream_ready_queue_wait_ns_total=50406039745618
quic_first_stream_ready_queue_wait_max_ns=6052970570
quic_first_stream_packet_process_ns_total=15822611798157
quic_first_stream_packet_process_max_ns=12466206639
quic_first_stream_read_query_execute_samples_total=22419
quic_first_stream_read_query_execute_ns_total=1317959083
quic_first_stream_mutation_query_execute_samples_total=7448
quic_first_stream_mutation_query_execute_ns_total=15726946588187
quic_poll_cycle_max_ns=5290337456
quic_poll_overrun_total=881
mg_merge_tuple_lock_hold_ns_total=350946735061
mg_rwlock_shared_hold_ns_total=389746135221
coord_apply_batches_total=1991
coord_apply_ops_total=7448
```

This split changes the next target: response writes and count-read execution
are not the primary limiter in the failing 4096x8 run. The largest measured
cost is successful mutation execution/storage time, with secondary evidence of
multi-second endpoint poll cycles and ready-queue delay.

4096 workers x 8 operations sustained mixed latency-friendly ceiling:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=1000 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=8 mutation_stride=4 ops_started=32768
ok=25800 read_failed=5291 mutation_failed=1677 worker_failures=6968
setup_attempts=4096 setup_retries=0
execute_attempts=32768 execute_retries=0 execute_reconnects=0
timing samples=32768 response_messages=51600 first_response_timeouts=6968
avg_ready_to_first_execute_ms=15.70 max_ready_to_first_execute_ms=95.92
avg_execute_write_ms=0.17 avg_execute_prepare_ms=0.04
avg_execute_stream_write_ms=0.11 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=5425.25 max_first_response_wait_ms=10028.04
```

Metrics-enabled 4096x8 probe on the same proven QUIC behavior showed the
mutation-side effect of `REQ-QUIC-HC-159`: `quic_first_stream_mutation_deferrals_total`
dropped from earlier multi-million requeue churn to thousands (`9508` in the
best diagnostic run), while the remaining failures stayed dominated by first
response wait and short-header receive tail.

4096 read-only x 8 low-stagger probe after shared AST/plan cache hit-path changes:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=0 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=4096 ops_per_worker=8 mutation_stride=0 ops_started=32768
ok=22917 read_failed=9851 mutation_failed=0 worker_failures=9851
setup_attempts=4096 setup_retries=0
execute_attempts=32768 execute_retries=0 execute_reconnects=0
timing samples=32768 response_messages=45834 first_response_timeouts=9851
avg_ready_to_first_execute_ms=17.24 max_ready_to_first_execute_ms=465.80
avg_execute_write_ms=0.23 avg_execute_prepare_ms=0.09
avg_execute_stream_write_ms=0.12 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=6155.72 max_first_response_wait_ms=10045.31
avg_response_read_ms=6155.78 avg_response_message_read_ms=4400.93
```

## Rejected Experiments

The 250 us mixed read/mutation probe is intentionally more aggressive than the
latency-friendly 1000 us regression gate. It now passes after `REQ-QUIC-HC-158`,
but the older failed variants below remain useful context for why a single
global mutation-admission window was not enough. `REQ-QUIC-HC-160` supersedes
the old cap sweep by separating serial writer-lock mutations from
shard-parallel multi-property `MERGE`.

All rows below used 4096 workers, one operation per worker, mutation stride 4, 16 poll workers, zero execute retries, and a 10s execute timeout.

| Variant | Result | Decision |
|---------|--------|----------|
| No new mutation cap | `ok=776/4096` before adaptive polling and `ok=368/4096` after adaptive polling alone | Mutation write-lock contention dominated the mixed workload. |
| Mutation cap 16 | `ok=2963/4096` | Large improvement, but too many cooperative workers still blocked behind the writer path. |
| Mutation cap 4 before `REQ-QUIC-HC-158` | `ok=3910/4096` in the original cap sweep; a later instrumented 250 us ceiling probe under the same machine load reported `ok=1705/4096`, `read_failed=1814`, `mutation_failed=577` | Still the accepted default because the 1000 us 4096 gate passes and higher caps regress reads. Superseded as a 250 us failure by the empty-RLS-engine fix. |
| Mutation cap 2 | `ok=2507/4096` | Too much mutation throttling reduced mixed progress and increased read timeouts. |
| Mutation cap 8 via `GEODE_QUIC_MUTATION_ADMISSION_CAP=8` before `REQ-QUIC-HC-158` | `ok=278/4096`, `read_failed=2863`, `mutation_failed=955` | Rejected. A wider mutation window starved read progress before the empty-RLS fix. |
| Mutation cap 8 via `GEODE_QUIC_MUTATION_ADMISSION_CAP=8` after `REQ-QUIC-HC-158` | PASS, but only `469.82 QPS`, `avg_first_response_wait_ms=6622.24`, worse than the default cap-4 250 us run (`561.28 QPS`, `avg_first_response_wait_ms=5088.21`) | Still rejected. Wider admission lowers mutation deferrals but increases response tail and reduces throughput. |
| Parked mutation-overflow wait queue | `ok=2287/4096` | Worse than immediate overflow requeue; it delayed mixed progress instead of reducing contention. |
| Cooperative first-stream worker ceiling 1024 | `ok=780/4096`, `read_failed=2487`, `mutation_failed=829` | Rejected. Extra scheduler lanes starved transport/poller work and worsened both reads and mutations. |
| QUIC `a68d36e` server STREAM ACK fanout fix at 250 us mixed, before `REQ-QUIC-HC-158` | `ok=2445/4096`, `read_failed=1160`, `mutation_failed=491` | Improved over the prior instrumented ceiling probe (`ok=1705/4096`) but still failed before the empty-RLS-engine fix. |
| Timing instrumentation before wake-batch tuning at 250 us mixed | `ok=1605/4096`, `read_failed=1891`, `mutation_failed=600`, `first_response_timeouts=2491`, `avg_ready_to_first_execute_ms=93.56`, `avg_execute_write_ms=544.80`, `avg_first_response_wait_ms=8749.34` | Rejected as a passing gate, but accepted as a diagnostic: the ceiling includes local client wake/write contention before server response tail. |
| 64-worker start wake batches at 250 us mixed | `ok=2465/4096`, `read_failed=1118`, `mutation_failed=513`, `first_response_timeouts=1631`, `avg_ready_to_first_execute_ms=16.76`, `avg_execute_write_ms=187.68`, `avg_first_response_wait_ms=7415.52` | Improvement over the corrected 256-worker timing run, but still not promoted because 1631 first-response timeouts remain. |
| Split client EXECUTE write timing at 250 us mixed | `ok=1318/4096`, `read_failed=2109`, `mutation_failed=669`, `first_response_timeouts=2778`, `avg_execute_write_ms=205.15`, `avg_execute_prepare_ms=0.67`, `avg_execute_stream_write_ms=0.06`, `avg_execute_post_write_poll_ms=204.40` | Diagnostic only. It proved the remaining local client write cost was almost entirely same-process post-write endpoint polling. |
| Deferred high-fanout post-write flush at 250 us mixed, before `REQ-QUIC-HC-158` | `ok=1823/4096`, `read_failed=1684`, `mutation_failed=589`, `first_response_timeouts=2273`, `avg_execute_write_ms=0.46`, `avg_execute_post_write_poll_ms=0.00`, `avg_first_response_wait_ms=7852.70` | Accepted for harness behavior because it removes client-side write/poll contention and preserves the accepted 1000 us gate. Superseded as a failure by the empty-RLS-engine fix. |
| QUIC one-batch server short-header app budget (`da08ef4`) | 1024x8 PASS but regressed to `2687.79 QPS`; 4096x8 regressed to `ok=15221/32768`, `setup_retries=118`, `first_response_timeouts=17547` | Rejected and reverted upstream in QUIC `9a35274`; downstream pins now point at the revert commit. |
| QUIC short-header wall-clock yield (`c2874fb`/`76b45ec`) | The slice-shrinking variant regressed 4096x8 setup to `ready=3293/4096` at 60s with `setup_retries=2305`. The repaired full-batch variant completed setup but regressed the accepted 4096 single-op gate to `ok=1043/4096`, `first_response_timeouts=3053`. | Rejected and reverted upstream in QUIC `108d06d`; downstream pins later moved to upstream-main revert `eeeb216`. |
| QUIC slow-batch short-header cadence (`6224b28`) | Preserved the four-batch cap but yielded after one complete batch and 500 ms. It regressed the accepted 4096 single-op gate to `ok=1026/4096`, `read_failed=2304`, `mutation_failed=766`, and `first_response_timeouts=3070`. | Rejected and reverted upstream in QUIC `eeeb216`; `geode-client-zig` `533cde8` and Geode pin that revert. |
| 65k static multi-property MERGE tuple-lock stripes | 4096x8 mixed low-stagger probe regressed to `ok=21464/32768`, `read_failed=8468`, `mutation_failed=2836`, and `first_response_timeouts=11304`; ReleaseFast compile also inflated to a multi-minute, multi-GB object build. | Rejected. Final shape uses 16k heap-allocated stripes plus tuple-lock metrics. |
| 16k heap tuple-lock stripes re-run during root `goreleaser` cross-build | 4096x8 mixed low-stagger probe reported `ok=14798/32768`, `first_response_timeouts=17970`, but a concurrent root-owned `goreleaser release --clean` tree was compiling seven cross targets under `/builds/devnw/codepros/geode/geode` for the entire execution window. | Invalidated, not accepted as a regression or improvement measurement. Re-run on an otherwise idle host before changing the current 9045-timeout ceiling. |
| Nonblocking RX-ready callback with a coalesced force-ready hint epoch | 2048x8 mixed ReleaseFast probe regressed from the documented zero-timeout gate to `ok=16381/16384`, `first_response_timeouts=3`, and `avg_first_response_wait_ms=2530.51`. It did lower `quic_poll_recv_short_frame_process_max_ns` below 200 ms, but moved the tail into scheduler/execution wait. | Reverted before commit; the next fix should target execution/storage or a real ready-queue structure, not a context-scan fallback. |
| Direct count-value response that skipped `ExecutionResult` allocation | 2048x8 mixed ReleaseFast probe regressed to `ok=16356/16384`, `first_response_timeouts=28`, and `avg_first_response_wait_ms=3007.02`. It did not reduce the execution tail enough to offset transport/scheduler variance. | Reverted before commit; allocation shaving in the single-row count response is not the current limiter. |
| 64 server poll workers on 1024x8 mixed | PASS, 8192/8192 operations, roughly 3980 QPS, but no material throughput gain over the 16-poller baseline and `quic_poll_overrun_total` increased from 28 to 528 with `quic_poll_cycle_max_ns` rising to about 472 ms. | Rejected as a default. The server keeps a 64-poller explicit override for A/B testing on QUIC v0.1.21+, but the harness default remains 16. |
| 1000 us group-commit coalescing on 1024x8 mixed | PASS, but QPS regressed to about 1413, p95 rose to about 2078 ms, and mutation execution averaged over 1.1 seconds even though coordinator batch size improved to about 11.5 ops/batch. | Rejected. Larger batches did not compensate for added latency and storage tail; the later 2048x8 sweep selected 500 us, not 1000 us. |
| 2048x8 mixed runtime scrape at 100 us coalescing and cap 512 | FAIL, `ok=16378/16384`, `first_response_timeouts=6`, about 720 QPS, p50 about 2469 ms, and mutation execution about 100s total. | Rejected. This shows the earlier default is no longer stable at 2048 after the broader dependency/cache cycle. |
| 64 server poll workers on 2048x8 mixed | FAIL, `ok=16317/16384`, `first_response_timeouts=67`, poll-cycle max about 6.3s, and mutation execution about 137s total. | Rejected. More poll workers increased endpoint contention and timeouts. |
| 2000 us group-commit coalescing on 2048x8 mixed | FAIL, `ok=16369/16384`, `first_response_timeouts=15`, about 706 QPS, and p99 about 8083 ms. | Rejected. The larger window improved average batch size slightly but hurt completion and tail. |
| 64 shard-parallel mutation admission cap on 2048x8 mixed | FAIL, `ok=16309/16384`, `first_response_timeouts=75`, about 661 QPS, and only 3 mutation deferrals. | Rejected. A cap this tight underfeeds the coordinator and worsens completion. |
| 64 shard-parallel mutation admission cap on 4096x8 mixed | FAIL, `ok=14864/32768`, `first_response_timeouts=17904`, about 213 QPS, `mutation_deferrals=519`, and `quic_poll_cycle_max_ns` reached about 26.8 seconds. | Rejected. Throttling shard-parallel mutations this tightly reduced total progress and worsened poll tail. |
| 256 shard-parallel mutation admission cap on 4096x8 mixed | FAIL, `ok=19744/32768`, `first_response_timeouts=13024`, and about 357 QPS. | Rejected. It was better than cap 64 in that older 4096x8 attribution cycle, but the later 2048x8 sustained sweep selected 128 as the default. |
| `GEODE_HC_GROUP_COMMIT=0` direct multi-property MERGE path on 1024x8 mixed | PASS, 8192/8192 operations and 4100.14 QPS, but mutation execution rose to 41.38s total, storage shared-hold time rose to 23.29s, and max mutation execution rose to 273 ms. | Rejected as a default. The small QPS gain did not justify worse storage hold time and mutation executor tail. |
| `GEODE_HC_GROUP_COMMIT_COALESCE_US=0` on 1024x8 mixed | PASS, but regressed to 602.66 QPS, p50 1560 ms, p95 3072 ms, and 51.95s mutation execution. Commit time rose to 16.01s across 1899 batches. | Rejected. The 100 us coalescing window is still necessary for the coordinator path. |
| Always-on coordinator phase timing on 2048x8 mixed scrape | FAIL, `ok=15238/16384`, `first_response_timeouts=1146`, 394.23 QPS. The metrics were useful, but the timing overhead perturbed the sustained gate. | Rejected as a default. Detailed coordinator phase timers now require `GEODE_GROUP_COMMIT_PHASE_METRICS=1`; the harness enables it only for scrape diagnostics unless overridden. |

## Known Unrelated Test Failure

`zig build test --summary all` still fails in the existing subprocess cluster smoke:

```text
test_cluster_3node_subprocess.test.three geode subprocesses on loopback form a 3-node Raft cluster
```

The failing nodes repeatedly log `raft transport getOrCreatePeerConnection failed error=HandshakeError` and do not elect a leader. Rebuilding the default debug binary with `zig build --summary all` succeeds, but a direct `timeout 300s zig build test-cluster-3node-subprocess --summary all` run still times out. That failure is in the distributed cluster subprocess path and is not part of the QUIC high-concurrency request-admission changes in this cycle.

## Operational Guidance

- Keep `GEODE_QUIC_POLL_WORKERS=16` for this dependency line.
- Keep `GEODE_QUIC_MUTATION_ADMISSION_CAP` unset in normal operation. General writer-lock mutations use the fixed serial cap of 4; the default shard-parallel multi-property `MERGE` cap is 128.
- Keep `GEODE_GROUP_COMMIT_COALESCE_US` unset in normal operation. The default is 500 us; 100 us timed out at 2048x8 and 2000 us regressed tail completion.
- Keep `GEODE_GROUP_COMMIT_PHASE_METRICS` unset in normal operation. Set `GEODE_HC_METRICS_SCRAPE=1` when a ceiling probe needs coordinator phase attribution.
- Use the 4096 mixed single-op 250 us command above as the current no-retry high-concurrency regression gate.
- Use the 2048 x 8 mixed command as the current sustained regression gate.
- Keep the 4096 x 8 mixed 250 us and 1000 us commands as failing ceiling probes and the main diagnostics for remaining first-response tail.
- Set `GEODE_HC_METRICS_SCRAPE=1` on ceiling probes when collecting attribution. It enables a private child metrics port and prints the high-concurrency runtime counters without requiring an external scraper.
- Keep `GEODE_HC_POST_WRITE_POLL` unset for high-fanout harness runs. The default remains true below 1024 workers and false at 1024+ workers. Set it to `1` only when comparing against the legacy immediate-flush behavior.
- Do not promote the parked mutation-overflow queue without a better fairness design; the measured result regressed the workload.
- Read `high-concurrency QUIC E2E timing` lines as follows:
  - `avg_ready_to_first_execute_ms` captures local harness wake/scheduling lag after the configured request stagger.
  - `avg_execute_write_ms` captures client-side EXECUTE encode/write/post-write QUIC poll time.
  - `avg_execute_prepare_ms` captures client-side EXECUTE serialization/framing time.
  - `avg_execute_stream_write_ms` captures the QUIC stream write call without the follow-up endpoint poll.
  - `avg_execute_post_write_poll_ms` captures the immediate client endpoint poll used by normal clients and low-fanout harness runs.
  - `avg_first_response_wait_ms` and `first_response_timeouts` capture the first-response tail seen by clients.
  - `quic_stream_write_elapsed_*` runtime metrics capture server-side response `stream.writeAll` latency and should be scraped with `/metrics` when diagnosing production response stalls.
  - `quic_first_stream_read_query_execute_*` and `quic_first_stream_mutation_query_execute_*` split successful server-side executor time by query class.
  - `coord_apply_batches_total` and `coord_apply_ops_total` show the real batch-size effect of group-commit coalescing sweeps.
  - `coord_submit_wait_*`, `coord_queue_wait_*`, `coord_apply_ops_loop_*`, and `coord_apply_commit_*` split mutation executor time inside the coordinator when phase metrics are enabled.

## Remaining Work

1. Reduce mutation execution/storage tail in the 4096x8 mixed ceiling. The latest scrape shows mutation execution dominates successful server work while read execution and response writes are comparatively cheap.
2. Use the opt-in coordinator phase counters on an idle-host 4096x8 scrape to decide whether the next fix belongs in shard apply, WAL commit batching, submitter wake scheduling, or cooperative worker parking.
3. Reduce multi-second QUIC poll cycles at 4096 fanout without regressing setup or the accepted 4096 single-op gate. The rejected wall-clock and one-batch receive experiments remain guardrails.
4. Raise the sustained mixed gate from 2048 x 8 toward 4096 x 8 and then 8192+ workers without increasing the 10s execute timeout.
5. Revisit mutation admission per graph once the storage write path can execute independent graph mutations concurrently.
