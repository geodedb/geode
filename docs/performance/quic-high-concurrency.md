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
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

The latest 250 us run completed 23723/32768 operations with zero setup retries,
zero execute retries, zero reconnects, and 9045 first-response timeouts after
the storage/cache contention cycle. A latency-friendly 1000 us run completed
25800/32768 operations with 6968 first-response timeouts in the prior
dependency-pin cycle. Keep both as active ceiling probes; do not raise the 10s
execute timeout to make them pass.

With server metrics enabled, permit-gated mutation overflow and shard-parallel
mutation admission reduced scheduler churn enough to promote the sustained gate
from 1024 x 8 to 2048 x 8. The remaining 4096 x 8 tail is still concentrated in
first-response wait, cooperative packet processing, and QUIC short-header
receive processing.

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

Post-change 4096x8 read-only low-stagger probes improved from 11466
first-response timeouts before the shared-cache work to 9851 timeouts after
shared AST and plan hits. The 4096x8 mixed low-stagger probe improved from the
pre-cycle 12293-timeout ceiling to 9045 timeouts after skipping optimizer
admission for mutations. This is still a failing stress ceiling; the passing
sustained gate remains 2048x8 mixed. The tuple-lock striping cycle adds
instrumentation and collision reduction but has not promoted the 4096x8 gate;
the first re-run was invalidated by a concurrent root-owned `goreleaser`
cross-build saturating the host.

## Core Knobs

- `GEODE_QUIC_POLL_WORKERS`: server endpoint poll workers. Keep at `16` for the
  current QUIC dependency line; higher values contend on serialized crypto
  polling.
- `GEODE_QUIC_MUTATION_ADMISSION_CAP`: cooperative first-stream mutation window.
  Leave unset in normal operation. General writer-lock mutations keep an
  internal serial cap of `4`; the runtime cap now controls only the
  shard-parallel multi-property `MERGE` window, which defaults to `512`.
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

The response write metrics split server-side `stream.writeAll` latency from
query execution and receive/admission stalls. First-stream metrics split
scheduler queueing, application packet processing, and mutation-admission
requeue churn. Poll metrics identify endpoint poll saturation and short-header
processing stalls. `mg_rwlock_shared_hold_snapshot_ns_total` should stay at
zero for the default high-concurrency count workload unless RLS policies or a
broader query shape force snapshot execution.

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
