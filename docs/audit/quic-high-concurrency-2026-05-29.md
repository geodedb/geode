# QUIC High-Concurrency Request Admission - 2026-05-29

**Scope:** `geode`
**Status:** 4096 mixed read/mutation single-op gates pass with zero setup retries, zero execute retries, zero reconnects, and zero first-response timeouts. Sustained mixed read/write load now passes at 2048 workers x 8 operations with zero retries/timeouts after shard-parallel mutation admission and tighter cooperative scheduler backoff. The 4096 workers x 8 operations ceiling still fails and remains the next throughput target; the dominant tail is now QUIC receive/first-response latency, not mutation requeue spin.
**Dependency state:** Geode now pins QUIC `9a35274086e8cfb9cab5b78fa7471506aec03d3e` and `geode-client-zig` `5a6b65a012e02db2a7acb6d0f37f2251f171edf0`. QUIC `9a35274` is the upstream revert of the rejected one-batch server short-header app receive experiment, preserving the proven `a68d36e` behavior while keeping the rejected commit out of downstream pins.

## Summary

The prior 2026-05-28 closeout left 4096 synchronized single-operation execution as the next transport-admission target. This cycle kept the dependency pins aligned and fixed the next Geode-side bottlenecks:

1. The high-concurrency protocol client was polling every WouldBlock at a fixed 100 us cadence. At 4096 local client threads this made the test driver a CPU storm and starved the child server. `REQ-QUIC-HC-149` now polls immediately, then uses a bounded adaptive wait and resets the backoff on successful reads.
2. Cooperative first-stream mutation admission previously allowed up to 128 mutation workers. The storage write path already serializes mutations, so those workers mostly blocked behind the write lock and starved read-tail scheduling. `REQ-QUIC-HC-150` caps the cooperative mutation admission window at 4 while preserving overflow requeue behavior.
3. Failed 4k probes printed thousands of duplicate worker timeout lines. `REQ-QUIC-HC-152` caps per-worker failure logs at 64 while preserving exact counters and final phase summaries.
4. The cooperative mutation-admission cap is now tunable through `GEODE_QUIC_MUTATION_ADMISSION_CAP`. General writer-lock mutations keep an internal serial cap of 4, while the tunable cap controls the shard-parallel multi-property `MERGE` window and defaults to 512.
5. The high-concurrency E2E summary now reports `read_failed` and `mutation_failed`, making overloaded probes distinguish read-tail transport/scheduler stalls from mutation-specific write pressure.
6. The next 250 us mixed ceiling probe localized the remaining tail to upstream QUIC short-header ACK/frame processing. QUIC `a68d36e` now defers the first server-side STREAM-only standalone ACK so request/response traffic can piggyback ACKs on response packets, while an `AppAckDelay` timer preserves max-ACK-delay behavior for quiet/upload-only peers.
7. `REQ-QUIC-HC-153` adds runtime metrics for server-side QUIC `stream.writeAll` elapsed time (`quic_stream_write_elapsed_ns_total` and `quic_stream_write_elapsed_max_ns`), so operators can split query execution from response delivery.
8. `REQ-QUIC-HC-154` and `REQ-QUIC-HC-155` add high-concurrency harness timing for ready-to-first-EXECUTE lag, EXECUTE write/flush time, first-response wait/read time, response message read time, and first-response timeouts. The 4096/250 us ceiling now shows a measurable client-side wake/write storm in addition to server response tail.
9. The local test-driver start barrier now wakes 64 workers per tick instead of 256 at 1024+ workers. This preserves the configured per-worker request stagger while reducing same-process scheduler contention before the server becomes the bottleneck.
10. `REQ-QUIC-HC-156` keeps low-fanout client behavior unchanged but disables immediate post-write `poll(0)` in 1024+ same-process harness fanout by default. The response read path already polls on WouldBlock, so high-fanout probes avoid spending hundreds of milliseconds per worker inside local client flush calls before the server is the limiting factor.
11. `REQ-QUIC-HC-157` adds first-stream scheduler metrics for ready-queue wait, per-packet processing time, and mutation-admission deferrals. The 4096/250 us diagnostic showed `quic_stream_write_errors_total=0` and `quic_stream_write_timeouts_total=0`, separating response-write health from scheduler and packet-processing tail.
12. `REQ-QUIC-HC-158` fixes an RLS classification bottleneck: authenticated reads no longer treat startup's empty label/expression RLS engines as active row filters. The 4096/250 us stress ceiling now passes with `mg_rwlock_shared_hold_snapshot_ns_total=0`, confirming count reads stay on the label-refcount fast path unless policies are actually installed.
13. `REQ-QUIC-HC-159` changes cooperative mutation overflow from immediate ready-queue requeue to permit-gated parking. Overflow packets keep stream ordering in `pending_packet`, but are only schedulable again when `mutation_inflight < mutation_limit`; `releaseMutationPermit()` wakes one parked waiter. This drops 4096x8 mutation deferrals from multi-million churn to thousands while preserving the 1024x8 sustained pass.
14. Upstream QUIC commit `da08ef4` tested a one-batch server short-header app receive budget. It regressed 1024x8 throughput and 4096 setup, so QUIC `9a35274`, `geode-client-zig` `5a6b65a`, and Geode now pin the revert.
15. `REQ-QUIC-HC-160` splits cooperative mutation admission into a four-wide serial window and a wider shard-parallel window. The wider window is deliberately limited to single no-RETURN node `MERGE` statements with at least two merge properties, matching the `bulkMergeNodeWithReservedIdMultiProp` tuple-lock path instead of the whole-graph writer path.
16. `REQ-QUIC-HC-147` follow-up tightens the cooperative post-turn backoff from the previous 3 ms cap to a 1 ms cap. This keeps poll-worker yielding under high fanout but avoids adding seconds of scheduler latency across sustained multi-operation streams.

## Changed Files

- `src/server/quic_connection_handler.zig`
  - Keeps general writer-lock mutation admission at a serial cap of 4.
  - Adds a shard-parallel mutation admission class for simple multi-property `MERGE`.
  - Uses the effective runtime cap when deriving `FirstStreamScheduler.shard_parallel_mutation_limit`.
  - Parks mutation-overflow packets behind the mutation permit release path instead of immediately spinning them through the ready queue.
  - Lowers cooperative first-stream post-turn sleep to a 1 ms cap so sustained follow-up operations do not accumulate avoidable scheduler tail.
- `src/server/main.zig`
  - Adds `GEODE_QUIC_MUTATION_ADMISSION_CAP` as an explicit server runtime override for shard-parallel mutation ceiling probes and emergency tuning.
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
- `tests/test_quic_condition_timedwait_cadence.zig`
  - Source-audits the mutation window cap, runtime override, adaptive polling shape, failure-log backpressure, failure split counters, response write latency metrics, split timing summaries, and deferred high-fanout post-write flushing.
- `src/transport/quic.zig`
  - Records elapsed server-side QUIC stream write time for every response write.
- `src/transport/quic_response_metrics.zig`
  - Exposes cumulative and max response stream-write elapsed counters through runtime metrics.
  - Exposes first-stream ready queue wait, packet-processing, and mutation-deferral counters.
- `src/execution/match_operations.zig`
  - Treats empty startup RLS engines as default-allow for fast-path classification, while preserving the RLS fallback as soon as label or expression policies exist.
- `src/security/rls_core.zig`
  - Adds a cheap `hasPolicies()` probe so execution can distinguish an empty expression RLS engine from one that may filter rows.
- `tests/test_rls_expr_engine_wiring.zig`
  - Adds `REQ-QUIC-HC-158` coverage proving empty RLS engines do not force authenticated reads onto the snapshot path and installed policies still do.
- `build.zig`
  - Adds a focused `test-rls-expr-engine-wiring` step for the RLS dispatch regression.
- `build.zig.zon`
  - Pins both direct QUIC and embedded `geode-client-zig` to the upstream server STREAM ACK fanout fix plus the revert of the rejected one-batch short-header experiment.

## Accepted Verification

All commands below were run on 2026-05-29.

| Command | Result |
|---------|--------|
| `zig build test-rls-expr-engine-wiring --summary all` | PASS, 4/4 tests after the empty-RLS-engine fast-path regression coverage. |
| Upstream QUIC `zig build test --summary all` | PASS, 116/126 tests passed, 10 skipped, after reverting the rejected one-batch short-header experiment. |
| `geode-client-zig` `zig build test --summary all` | PASS, 420/420 tests after repinning to QUIC `9a35274`. |
| `zig build test-quic-condition-cadence --summary all` | PASS, 72/72 tests after shard-parallel mutation admission, permit-gated overflow, and dependency source audits. |
| 1024 workers x 8 ops mixed sustained E2E | PASS, 8192/8192 operations, zero retries, zero reconnects, zero first-response timeouts, 3471.63 QPS. |
| 2048 workers x 8 ops mixed sustained E2E | PASS, 16384/16384 operations, zero retries, zero reconnects, zero first-response timeouts, 1007.96 QPS. |
| 4096 mixed single-op E2E at 250 us | PASS, 4096/4096 operations, zero retries, zero reconnects, zero first-response timeouts, 884.81 QPS. |
| 4096 workers x 8 ops mixed sustained E2E at 250 us | FAIL, 21719/32768 operations, zero setup/execute retries, 11049 first-response timeouts. This is the remaining low-stagger ceiling. |
| 4096 workers x 8 ops mixed sustained E2E at 1000 us | FAIL, 25800/32768 operations, zero setup/execute retries, 6968 first-response timeouts. This is the current latency-friendly ceiling. |
| `zig build --summary all` after final dependency repin | PASS, 52/52 steps succeeded against QUIC `9a35274` and `geode-client-zig` `5a6b65a`. |
| 4096 read-only 250 us low-stagger probe | PASS, 4096/4096 operations, zero retries, zero reconnects. |
| 1024 mixed 250 us timing smoke | PASS, 1024/1024 operations at 3822.30 QPS after deferred high-fanout post-write flush, validating the split timing summary path. |

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

4096 mixed read/mutation 250 us single-op gate after the shard-parallel admission follow-up:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=1 \
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
workers=4096 ops_per_worker=1 mutation_stride=4 ops=4096 reads=3072 mutations=1024
setup_ms=5456 elapsed_ms=4629 qps=884.81
avg_read_ms=2857.71 avg_mut_ms=2865.69 avg_first_op_ms=2859.71 max_ms=4474.02
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
timing samples=4096 response_messages=8192 first_response_timeouts=0
avg_ready_to_first_execute_ms=15.26 max_ready_to_first_execute_ms=291.16
avg_execute_write_ms=0.40 avg_execute_prepare_ms=0.23
avg_execute_stream_write_ms=0.17 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=2858.11 max_first_response_wait_ms=4473.95
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
setup_ms=1372 elapsed_ms=2359 qps=3471.63
avg_read_ms=178.46 avg_mut_ms=437.95 avg_first_op_ms=218.13
avg_followup_op_ms=246.93 max_ms=1568.67
setup_attempts=1024 setup_retries=0
execute_attempts=8192 execute_retries=0 execute_reconnects=0
timing samples=8192 response_messages=16384 first_response_timeouts=0
avg_ready_to_first_execute_ms=3.64 max_ready_to_first_execute_ms=27.71
avg_execute_write_ms=0.05 avg_execute_prepare_ms=0.00
avg_execute_stream_write_ms=0.04 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=243.22 max_first_response_wait_ms=1568.61
```

2048 workers x 8 operations sustained mixed run after shard-parallel mutation admission and tighter scheduler backoff:

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
setup_ms=2784 elapsed_ms=16254 qps=1007.96
avg_read_ms=1887.27 avg_mut_ms=1898.42 avg_first_op_ms=1006.68
avg_followup_op_ms=2016.26 max_ms=9529.83
setup_attempts=2048 setup_retries=0
execute_attempts=16384 execute_retries=0 execute_reconnects=0
timing samples=16384 response_messages=32768 first_response_timeouts=0
avg_ready_to_first_execute_ms=8.92 max_ready_to_first_execute_ms=158.01
avg_execute_write_ms=0.15 avg_execute_prepare_ms=0.07
avg_execute_stream_write_ms=0.07 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=1889.70 max_first_response_wait_ms=9529.74
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
ok=21719 read_failed=8313 mutation_failed=2736 worker_failures=11049
setup_attempts=4096 setup_retries=0
execute_attempts=32768 execute_retries=0 execute_reconnects=0
timing samples=32768 response_messages=43438 first_response_timeouts=11049
avg_ready_to_first_execute_ms=15.82 max_ready_to_first_execute_ms=481.04
avg_execute_write_ms=0.19 avg_execute_prepare_ms=0.07
avg_execute_stream_write_ms=0.10 avg_execute_post_write_poll_ms=0.00
avg_first_response_wait_ms=6076.92 max_first_response_wait_ms=10052.57
```

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

4096 read-only low-stagger probe:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=1 \
GEODE_HC_MUTATION_STRIDE=0 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result after adaptive polling:

```text
workers=4096 ops_per_worker=1 mutation_stride=0 ops=4096 reads=4096 mutations=0
setup_ms=5489 elapsed_ms=6010 qps=681.43
avg_read_ms=4077.53 max_ms=5841.88
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
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

## Known Unrelated Test Failure

`zig build test --summary all` still fails in the existing subprocess cluster smoke:

```text
test_cluster_3node_subprocess.test.three geode subprocesses on loopback form a 3-node Raft cluster
```

The failing nodes repeatedly log `raft transport getOrCreatePeerConnection failed error=HandshakeError` and do not elect a leader. Rebuilding the default debug binary with `zig build --summary all` succeeds, but a direct `timeout 300s zig build test-cluster-3node-subprocess --summary all` run still times out. That failure is in the distributed cluster subprocess path and is not part of the QUIC high-concurrency request-admission changes in this cycle.

## Operational Guidance

- Keep `GEODE_QUIC_POLL_WORKERS=16` for this dependency line.
- Keep `GEODE_QUIC_MUTATION_ADMISSION_CAP` unset in normal operation. General writer-lock mutations use the fixed serial cap of 4; the default shard-parallel multi-property `MERGE` cap is 512.
- Use the 4096 mixed single-op 250 us command above as the current no-retry high-concurrency regression gate.
- Use the 2048 x 8 mixed command as the current sustained regression gate.
- Keep the 4096 x 8 mixed 250 us and 1000 us commands as failing ceiling probes and the main diagnostics for remaining first-response tail.
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

## Remaining Work

1. Scrape `quic_stream_write_elapsed_*` during the next 250 us mixed run to separate server response write stalls from query execution and QUIC receive/admission stalls.
2. Add scheduler-side phase counters for cooperative first-stream dequeue, query execution, and response write completion so long first-response tails can be split without relying only on client timing.
3. Raise the sustained mixed gate from 2048 x 8 toward 4096 x 8 and then 8192+ workers without increasing the 10s execute timeout.
4. Revisit mutation admission per graph once the storage write path can execute independent graph mutations concurrently.
