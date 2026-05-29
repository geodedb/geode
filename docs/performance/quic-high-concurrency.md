# QUIC High-Concurrency Operations

This page records the current Geode QUIC high-concurrency gate, diagnostics,
and tuning controls. It is the operator-facing companion to
`docs/audit/quic-high-concurrency-2026-05-29.md`.

## Current Gate

The current no-retry high-concurrency regression gate is 4096 parallel clients,
one operation per client, mixed reads and mutations at a 3:1 read/write ratio.
The latest accepted run uses a 250 us request stagger:

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

The latest 2026-05-29 upstream-main revert run completed all 4096 operations with zero
setup retries, zero execute retries, zero reconnects, zero first-response
timeouts, and 664.88 QPS.

## Sustained Gate

The current sustained mixed read/write pass is 2048 clients x 8 operations per
client:

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

The latest accepted sustained run completed all 16384 operations with zero
setup retries, zero execute retries, zero reconnects, zero first-response
timeouts, and 1189.34 QPS. This gate exercises 4096 mutations and 12288 reads
over 2048 live QUIC connections.

## Stress Ceiling

The 4096-worker mixed workload with 8 operations per client is still the failing
stress ceiling and the next throughput target. The low-stagger probe remains:

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
GEODE_HC_METRICS_SCRAPE=1 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

The latest metrics-enabled 250 us attribution run completed 26634/32768
operations with zero setup retries, zero execute retries, zero reconnects, and
6134 first-response timeouts after the runtime scrape and read/mutation
execution split. It ran at 570.08 QPS with p50=3968 ms, p95=9114 ms, and
p99=9977 ms. The scrape showed reads were no longer the dominant executor
cost: read execution accounted for about 1.3 seconds across 22419 samples,
while mutation execution accounted for about 15727 seconds across 7448 samples.
Server response writes were clean (`quic_stream_write_success_total=33963`,
`quic_stream_write_errors_total=0`, `quic_stream_write_timeouts_total=0`), so
the remaining 4096 x 8 tail is mutation execution/storage pressure plus
multi-second QUIC poll cycles and first-stream scheduling delay.

A latency-friendly 1000 us run completed 25800/32768 operations with 6968
first-response timeouts in the prior dependency-pin cycle. Keep both as active
ceiling probes; do not raise the 10s execute timeout to make them pass.

## Enterprise Objective Gate

The full target gate is now encoded directly in the E2E harness behind
`GEODE_HC_OBJECTIVE_GATE=1`. It sets the formal single-instance target defaults:

- 16384 live clients.
- 8 operations per client.
- 131072 total operations.
- 25% successful mutations minimum.
- 99.95% successful completion minimum.
- zero first-response timeouts.
- p50 < 20 ms, p95 < 100 ms, p99 < 250 ms, p99.9 < 1000 ms.
- 10000 QPS minimum.
- mutation visibility verification.
- graph-isolation verification.
- restart/recovery verification using the same data directory.
- server RSS delta bound of 2 GiB by default.

Run it only on a host prepared for high thread and UDP fanout:

```sh
GEODE_HC_OBJECTIVE_GATE=1 \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=250 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 2400s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

The objective gate intentionally remains opt-in; the default build step keeps
the lightweight smoke defaults. The individual gates are independently tunable
for diagnostic sweeps:

- `GEODE_HC_MIN_COMPLETION_PPM`: success threshold in parts per million. The
  objective default is `999500`.
- `GEODE_HC_MIN_MUTATION_PPM`: successful mutation share in parts per million.
  The objective default is `250000`.
- `GEODE_HC_REQUIRE_ZERO_FIRST_RESPONSE_TIMEOUTS`: requires
  `first_response_timeouts=0` when true.
- `GEODE_HC_MIN_QPS`: minimum whole-operation throughput.
- `GEODE_HC_P50_MAX_MS`, `GEODE_HC_P95_MAX_MS`, `GEODE_HC_P99_MAX_MS`,
  `GEODE_HC_P999_MAX_MS`: percentile latency limits. A value of `0` disables
  the corresponding check.
- `GEODE_HC_GRAPH_ISOLATION_VERIFY`: creates a separate graph and asserts that
  `HCParallel` mutations are not visible there.
- `GEODE_HC_RESTART_VERIFY`: stops the child server, restarts on the same data
  directory, and asserts the committed mutation count survives recovery.
- `GEODE_HC_MEMORY_GROWTH_MAX_KB`: server RSS delta limit measured after
  workload clients are released and joined. A value of `0` reports RSS without
  gating it.

Passing the objective gate is the condition for claiming the 16k x 8 enterprise
target. A lower-scale pass should be recorded as a sustained gate or ceiling
probe, not as objective completion.

## 2026-05-29 Contention Fixes

The latest Geode-side cycle reduced avoidable shared-state contention before
the next QUIC receive/scheduler pass:

- `REQ-QUIC-HC-162`: multi-property `MERGE` now reads exact-property posting
  lengths first and copies only the smallest candidate posting list. This keeps
  `MERGE (:HCParallel {worker, seq})` from copying large `seq` lists while a
  much smaller `worker` posting exists.
- `REQ-QUIC-HC-163`: graph/label refcounts now use atomic counters under a
  map-stability rwlock. Hot count reads and existing-label mutation refcount
  bumps no longer serialize on one global label-count mutex.
- `REQ-QUIC-HC-164`: shared AST cache hits and releases now use a shared lock
  and atomic hit/ref counters. Same-query read fanout no longer takes the
  exclusive AST cache mutex for every hit.
- `REQ-QUIC-HC-165`: shared plan cache hits and releases now use the same
  shared-lock/atomic pattern, and cached plan handles point at stable heap
  storage instead of movable HashMap entries.
- `REQ-QUIC-HC-166`: mutating programs skip the shared optimizer. Mutation
  fast paths do not use optimizer hints, and literal-heavy mutation text creates
  one-shot cache misses and evictions under mixed fanout.
- `REQ-QUIC-HC-167`: multi-property `MERGE` tuple locks now use a 16k
  heap-allocated stripe table plus runtime wait/hold counters. This keeps
  unrelated `{worker, seq}` tuples from sharing the old 4096-stripe mutex table
  as often, while avoiding the ReleaseFast object bloat observed with a 65k
  static mutex table.
- `REQ-QUIC-HC-170`: the E2E harness now has an opt-in objective gate for the
  16384 x 8 enterprise target, with completion, mutation-share, QPS, latency,
  graph-isolation, restart/recovery, and RSS-delta checks.
- `REQ-QUIC-HC-171`: group-commit restart durability now checkpoints loaded
  per-graph engines during adapter shutdown and resolves first-seen labels
  through the sharded engine API. This broadcasts and dirties label
  dictionaries, preventing nodes from reloading without label names after
  high-concurrency mutation batches.
- `REQ-QUIC-HC-172`: the metrics server can append a runtime snapshot callback
  to `/metrics`, and the high-concurrency harness can enable and scrape it with
  `GEODE_HC_METRICS_SCRAPE=1`. The metrics server also self-wakes its accept
  loop during shutdown so scrape-enabled regression tests do not hang after a
  successful metrics read.
- `REQ-QUIC-HC-173`: first-stream query execution metrics now split read and
  mutation samples into separate cumulative and max counters. This makes a
  failing mixed ceiling distinguish cheap count reads from mutation/storage
  execution tail without inferring from client latency alone.
- `REQ-QUIC-HC-174`: group-commit shard coalescing is tunable through
  `GEODE_GROUP_COMMIT_COALESCE_US` for controlled sweeps. The default remains
  100 us because a 1000 us sweep increased batch size but regressed throughput
  and tail latency.

Post-change 4096x8 read-only low-stagger probes improved from 11466
first-response timeouts before the shared-cache work to 9851 timeouts after
shared AST and plan hits. The 4096x8 mixed low-stagger probe improved from the
pre-cycle 12293-timeout ceiling to 9045 timeouts after skipping optimizer
admission for mutations. This is still a failing stress ceiling; the passing
sustained gate remains 2048x8 mixed. The tuple-lock striping cycle adds
instrumentation and collision reduction but has not promoted the 4096x8 gate;
the first re-run was invalidated by a concurrent root-owned `goreleaser`
cross-build saturating the host.

## Restart And Durability Checks

High-concurrency mutation passes must verify more than in-memory visibility.
The restart check now uses the same data directory, performs a graceful child
server stop, starts a fresh server, and verifies `HCParallel` mutation counts
through the normal QUIC client path.

The storage-level regression for this path is:

```sh
zig build test-group-commit-coordinator --summary all
```

It includes `REQ-QUIC-HC-171: group commit inserts survive adapter reopen`,
which submits through the sharded coordinator, checkpoints, tears down the
global adapter/store, reopens the same data directory, and verifies the label
posting and properties survived reload.

The current low-scale QUIC restart smoke is:

```sh
GEODE_HC_WORKERS=8 \
GEODE_HC_OPS_PER_WORKER=2 \
GEODE_HC_MUTATION_STRIDE=2 \
GEODE_HC_CONNECT_STAGGER_US=100 \
GEODE_HC_REQUEST_STAGGER_US=100 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_GRAPH_ISOLATION_VERIFY=1 \
GEODE_HC_RESTART_VERIFY=1 \
GEODE_HC_MEMORY_GROWTH_MAX_KB=1048576 \
timeout 600s zig build test-quic-high-concurrency-e2e --summary all
```

The accepted run completed 16/16 operations, 8 mutations, zero retries, zero
first-response timeouts, `graph_isolation=ok`, `restart_recovery=ok`, and no
gate failures. This is not the enterprise objective pass; it is the regression
smoke proving the restart/recovery and graph-isolation gates work.

## Core Knobs

- `GEODE_QUIC_POLL_WORKERS`: server endpoint poll workers. Keep the harness
  default at `16`. The server accepts explicit sweeps up to `64` on the
  v0.1.21+ QUIC dependency line, but the measured 1024x8 mixed A/B did not
  improve throughput and increased poll overruns, so `64` is diagnostic-only.
- `GEODE_QUIC_MUTATION_ADMISSION_CAP`: cooperative first-stream mutation window.
  Leave unset in normal operation. General writer-lock mutations keep an
  internal serial cap of `4`; the runtime cap now controls only the
  shard-parallel multi-property `MERGE` window, which defaults to `512`.
- `GEODE_GROUP_COMMIT_COALESCE_US`: group-commit shard worker coalescing wait
  in microseconds, clamped at 5000 us. Leave at the 100 us default unless
  running a documented sweep; 1000 us regressed the mixed workload despite
  larger average coordinator batches.
- `GEODE_HC_METRICS_SCRAPE`: high-concurrency harness switch that enables the
  child metrics server on a private loopback port and prints selected runtime
  counters after the workload.
- `GEODE_HC_GROUP_COMMIT_COALESCE_US`: harness passthrough for
  `GEODE_GROUP_COMMIT_COALESCE_US`.
- `GEODE_HC_MUTATION_ADMISSION_CAP`: harness passthrough for
  `GEODE_QUIC_MUTATION_ADMISSION_CAP`.
- `GEODE_HC_POST_WRITE_POLL`: high-concurrency harness client flush behavior.
  Defaults to true below 1024 workers and false at 1024+ workers. Set `1` only
  for legacy immediate post-write poll comparisons.
- `GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS`: harness override for server
  cooperative first-stream workers. The server clamps the production value to
  512.
- `GEODE_HC_REQUEST_STAGGER_US`: offered-load shaping across already connected
  clients. The single-op accepted gate uses `250`; sustained ceiling probes
  should record both `250` and `1000`.
- `GEODE_HC_SHORT_HEADER_TIMING`: high-concurrency harness diagnostic switch.
  When set to `1`, the child server receives
  `GEODE_QUIC_SHORT_HEADER_TIMING=1` and emits upstream QUIC short-header
  receive subphase metrics. Leave unset for normal performance gates because
  the extra timing reads add measurement overhead.

## Reading Timing Output

The high-concurrency E2E harness emits a single timing line after each run.
The most important fields are:

- `avg_ready_to_first_execute_ms`: local harness wake/scheduling lag after the
  configured request stagger.
- `avg_execute_write_ms`: total client-side EXECUTE encode, stream write, and
  optional post-write poll time.
- `avg_execute_prepare_ms`: client-side serialization and framing time.
- `avg_execute_stream_write_ms`: `stream.writeAll` elapsed time, excluding the
  follow-up endpoint poll.
- `avg_execute_post_write_poll_ms`: immediate client endpoint `poll(0)` time.
  This is expected to be near zero for 1024+ harness fanout unless
  `GEODE_HC_POST_WRITE_POLL=1` is set.
- `first_response_timeouts`: operations that timed out before the first response
  message arrived.
- `avg_first_response_wait_ms`: client-observed time from EXECUTE write
  completion to the first response message.
- `avg_response_message_read_ms`: average per-message response read time across
  all response messages.
- `latency_percentiles`: sorted successful operation latency samples with
  p50/p95/p99/p99.9 in milliseconds. These percentiles are the values used by
  the objective latency gate.
- `memory`: child-server RSS at server start and after workload clients are
  released. Use this with `GEODE_HC_MEMORY_GROWTH_MAX_KB` for leak/regression
  gates.
- `gate`: final objective summary with completion PPM, mutation PPM, raw
  failure count, and gate-failure count.

When `avg_execute_post_write_poll_ms` is high, the local same-process client
driver is contributing to the measurement. When `avg_execute_write_ms` is low
and `first_response_timeouts` remains high, shift the investigation to server
polling, cooperative first-stream scheduling, query execution, response write
latency, or kernel UDP drops.

## Server Metrics

Scrape these runtime metrics when a ceiling probe has high first-response tail:

- `quic_stream_write_elapsed_ns_total`
- `quic_stream_write_elapsed_max_ns`
- `quic_first_stream_ready_queue_wait_ns_total`
- `quic_first_stream_ready_queue_wait_max_ns`
- `quic_first_stream_packet_process_ns_total`
- `quic_first_stream_packet_process_max_ns`
- `quic_first_stream_mutation_deferrals_total`
- `quic_first_stream_read_query_execute_samples_total`
- `quic_first_stream_read_query_execute_ns_total`
- `quic_first_stream_read_query_execute_max_ns`
- `quic_first_stream_mutation_query_execute_samples_total`
- `quic_first_stream_mutation_query_execute_ns_total`
- `quic_first_stream_mutation_query_execute_max_ns`
- `mg_rwlock_shared_hold_snapshot_ns_total`
- `mg_merge_tuple_lock_acquired_total`
- `mg_merge_tuple_lock_wait_ns_total`
- `mg_merge_tuple_lock_hold_ns_total`
- `mg_merge_tuple_lock_max_wait_ns_observed`
- `mg_merge_tuple_lock_max_hold_ns_observed`
- `quic_poll_cycle_max_ns`
- `quic_poll_transport_max_ns`
- `quic_poll_recv_short_endpoint_map_max_ns`
- `quic_poll_recv_short_rx_serial_wait_max_ns`
- `quic_poll_recv_short_conn_lock_wait_max_ns`
- `quic_poll_recv_short_decrypt_max_ns`
- `quic_poll_recv_short_frame_process_max_ns`
- `quic_poll_recv_short_ack_send_max_ns`
- `quic_poll_overrun_total`
- `coord_apply_batches_total`
- `coord_apply_ops_total`

The response write metrics split server-side `stream.writeAll` latency from
query execution and receive/admission stalls. First-stream metrics split
scheduler queueing, application packet processing, and mutation-admission
requeue churn. `REQ-QUIC-HC-169` further splits first-stream packet processing
into query prepare, query execution, and response-send phase timings through
`quic_first_stream_query_prepare_ns_total`,
`quic_first_stream_query_execute_ns_total`, and
`quic_first_stream_response_send_ns_total`. `REQ-QUIC-HC-173` then splits query
execution into read and mutation counters; in the current 4096x8 ceiling, that
split shows mutation execution dominates successful server-side work while
reads stay comparatively cheap. Poll metrics identify endpoint poll saturation
and short-header processing stalls. Coordinator counters reveal whether longer
coalescing waits are actually increasing batch size enough to justify the
latency cost.
`mg_rwlock_shared_hold_snapshot_ns_total` should stay at zero for the default
high-concurrency count workload unless RLS policies or a broader query shape
force snapshot execution.

## Dependency State

As of this cycle, Geode pins:

- QUIC: `06f4aadcf045a0d6295c7e85398b94c7096accb9`
- `geode-client-zig`: `5ae310237f6cbdf6cc2716fe4eca9f43f4facfbd`

QUIC `108d06d` reverts the rejected `c2874fb`/`76b45ec` short-header
wall-clock yield experiments and preserves the proven `a68d36e`/`9a35274`
four-batch server receive behavior. Those cadence experiments are documented as
rejected because they regressed the accepted 4096 single-op gate to 3053/4096
first-response timeouts. QUIC `6224b28` then tested a conservative slow-batch
yield after one full batch and 500 ms, but it also regressed the accepted 4096
single-operation gate. QUIC `eeeb216` is the upstream-main revert of that
experiment, so downstream consumers track upstream `main` while preserving the
proven four-batch receive behavior.

QUIC `06f4aad` then closes the remaining `pollCrypto` race class documented in
`QUIC_TLS_POLLCRYPTO_CRASH.md`: generic and coalesced long-header Initial and
Handshake packets now dispatch through the same serialized wrappers as the
optimized receive drain, so TLS `processCrypto`/`pollCrypto` remains
single-writer per connection even outside the hot burst path.

Dependency changes must be made in the upstream worktrees under
`~/src/devnw/zig/*` before Geode is repinned.

## Host Tuning

Before formal performance gates, apply the UDP buffer and host hygiene from
`docs/performance/host-tuning.md`. Undersized UDP buffers can look like QUIC
or scheduler stalls because packet loss inflates first-response tail.
