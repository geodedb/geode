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
GEODE_HC_CONNECT_STAGGER_US=500 \
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
client. After the cooperative mutation offload cycle, the accepted sustained
profile uses a 1000 us request stagger:

```sh
GEODE_HC_WORKERS=2048 \
GEODE_HC_OPS_PER_WORKER=8 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=1000 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 900s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

The best accepted sustained run completed all 16384 operations with zero setup
retries, zero execute retries, zero reconnects, zero first-response timeouts,
and 1895.40 QPS after cooperative shard-parallel mutation offload. This gate
exercises 4096 mutations and 12288 reads over 2048 live QUIC connections. The
same run reported p50=457.29 ms, p95=2191.47 ms, p99=3026.73 ms, and
p99.9=3763.53 ms, so completion is clean and throughput improved over the
previous 1111.06 QPS sustained pass, but latency is still above the enterprise
objective.

A final pre-push rerun of the same 2048x8/1000 us gate completed cleanly at
948.72 QPS with p50=1699.74 ms, p95=3918.29 ms, p99=5199.97 ms, and
p99.9=6906.88 ms. Treat the lower rerun as host/runtime variance in the
accepted completion gate; it reinforces that the enterprise latency and QPS
objective remains open.

The next default-path rerun after adding the active-shard diagnostic knob kept
all 16 write shards active and completed the same 2048x8/1000 us sustained
shape with zero setup retries, zero execute retries, zero reconnects, zero
first-response timeouts, and 5037.52 QPS. It reported p50=146.41 ms,
p95=409.98 ms, p99=655.79 ms, and p99.9=976.90 ms. This is the best observed
default-path throughput for the 2048x8 mixed gate, but p50/p95/p99 and the
formal 10k QPS objective still remain open.

After the QUIC `a1858c1` and `geode-client-zig` `942641c` dependency
correction and the cap-80 retune, the 1024x8 mixed gate completed all 8192
operations with zero first-response timeouts at 3523.77 QPS. The corresponding
latency percentiles were p50=244.83 ms, p95=552.59 ms, p99=732.43 ms, and
p99.9=1037.43 ms.

## Promoted Server Defaults

The accepted high-fanout profile is now reflected in Geode's release defaults
instead of living only in the E2E harness environment:

- `GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING` defaults to off. This avoids one idle
  multiplexed acceptor loop per high-fanout single-stream connection. Operators
  that need multi-stream compatibility can set it to `1`.
- `GEODE_QUIC_COOPERATIVE_FIRST_STREAMS` defaults to on. First streams rotate
  through the bounded cooperative scheduler instead of pinning one persistent
  worker or detached owner per live client.
- `GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS` defaults to `512` in optimized
  builds, matching the accepted 2048x8/4096 diagnostic harness profile.
- `GEODE_QUIC_CONNECTION_ADMISSION_THREADS` defaults to `4096` in optimized
  builds so rapid HELLO fanout does not collapse behind the old 1024 detached
  admission cap.
- `GEODE_QUIC_STREAM_QUEUE_CAPACITY` defaults to `8192`, matching the queue
  headroom used by the high-concurrency harness.
- Existing accepted defaults remain in place: `GEODE_QUIC_POLL_WORKERS=16`,
  shard-parallel mutation admission cap `80`, group-commit coalescing `500 us`,
  all 16 group-commit write shards active, and group-commit phase metrics off.

These defaults preserve explicit env overrides for compatibility and
diagnostics. They intentionally do not promote the rejected 64-poll-worker,
80/128 mutation-offload-worker, narrower active-shard, or wider coalescing
experiments.

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

With `GEODE_HC_REQUEST_STAGGER_US=1000` on the same 4096x8 shape after
cooperative mutation offload, the latest scrape-enabled run completed
19467/32768 operations with zero setup retries, zero execute retries, zero
reconnects, and 13301 first-response timeouts. It ran at 343.49 QPS with
p50=3516.23 ms, p95=8935.78 ms, p99=9763.55 ms, and p99.9=9978.00 ms. The
runtime scrape recorded clean response writes (`quic_stream_write_errors=0`,
`quic_stream_write_timeouts=0`, max write 58.3 ms), cheap read execution
(`quic_first_stream_read_query_execute_ns_total=1595085597` across 19226
samples), dominant mutation execution
(`quic_first_stream_mutation_query_execute_ns_total=379504191452` across 6413
samples), dominant coordinator wait (`coord_submit_wait_ns_total=379250098853`),
and a multi-second upstream receive tail
(`quic_poll_recv_short_header_max_ns=9869079842`). The next work remains split
between mutation storage/WAL commit pressure and upstream QUIC short-header
receive/frame processing.

The latest 250 us sustained run after cooperative mutation offload completed
16376/16384 operations at 2048 clients with eight first-response timeouts, so
250 us remains a diagnostic ceiling rather than the accepted sustained gate.

The latest metrics-enabled attribution run completed 26634/32768 operations
with zero setup retries, zero execute retries, zero reconnects, and 6134
first-response timeouts after the runtime scrape and read/mutation execution
split. The scrape showed reads were no longer the dominant executor cost: read
execution accounted for about 1.3 seconds across 22419 samples, while mutation
execution accounted for about 15727 seconds across 7448 samples. Server
response writes were clean (`quic_stream_write_success_total=33963`,
`quic_stream_write_errors_total=0`, `quic_stream_write_timeouts_total=0`), so
the remaining 4096 x 8 tail is mutation execution/storage pressure plus
multi-second QUIC poll cycles and first-stream scheduling delay.

A latency-friendly 1000 us run completed 25800/32768 operations with 6968
first-response timeouts in the prior dependency-pin cycle. Keep both as active
ceiling probes; do not raise the 10s execute timeout to make them pass.

## Rejected 2026-05-29 Follow-Ups

The following experiments were tested and rejected because they regressed the
accepted sustained gates or worsened the 4096x8 stress ceiling:

- QUIC `REQ-QUIC-HC-177` server short-header busy-connection shedding. It
  reduced some receive-loop blocking but lost request packets under 2048x8
  mixed fanout: `16359/16384` completed, `25` first-response timeouts,
  715.39 QPS. QUIC `a1858c1`, `geode-client-zig` `942641c`, and Geode pin the
  revert.
- `GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS=768`. This recreated scheduler
  pressure at 4096x8 mixed fanout: `22484/32768` completed, `10284`
  first-response timeouts, 460.19 QPS.
- `GEODE_HC_POLL_WORKERS=64`. Higher poll-worker parallelism worsened the same
  4096x8 shape: `22207/32768` completed, `10561` first-response timeouts,
  447.78 QPS.
- `GEODE_HC_GROUP_COMMIT_COALESCE_US=750` at 2048x8. One run passed, but
  repeat runs failed with 53 first-response timeouts and scrape-enabled
  attribution failed with 22 first-response timeouts.
- `GEODE_HC_GROUP_COMMIT_COALESCE_US=1000` at 2048x8. This failed with 102
  first-response timeouts on the final dependency line.
- `GEODE_HC_POST_WRITE_POLL=1` at 2048x8. Immediate high-fanout post-write
  endpoint polling failed with 143 first-response timeouts.
- `GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS=640` with 750 us coalescing at
  2048x8. This failed with 101 first-response timeouts.
- `GEODE_HC_MUTATION_ADMISSION_CAP=96` and `192` at 2048x8. Cap 96 was a near
  miss with four first-response timeouts; cap 192 overfed mutation work and
  failed with 336 first-response timeouts. Cap 80 completed cleanly.
- Raising the cooperative mutation offload pool cap from 64 to 128. The server
  failed the 2048x8 readiness gate with `ServerStartupTimeout`, so the offload
  pool remains bounded at 64 release workers.
- `GEODE_HC_POLL_WORKERS=4` at the aggressive 2048x8/250 us profile. Lower
  poll parallelism worsened completion to `16341/16384` with 43
  first-response timeouts.
- `GEODE_HC_MUTATION_ADMISSION_CAP=40` at the aggressive 2048x8/250 us profile.
  Narrowing the mutation window still failed with 12 first-response timeouts
  and lower throughput than the default cap 80 path.
- `GEODE_HC_GROUP_COMMIT_ACTIVE_SHARDS=8`. The 2048x8/1000 us shape completed
  cleanly but only reached 1218.17 QPS, well below the all-shard default-path
  rerun. At the aggressive 2048x8/250 us profile it failed with 102
  first-response timeouts.
- `GEODE_HC_GROUP_COMMIT_ACTIVE_SHARDS=4` at 2048x8/1000 us. This failed with
  one first-response timeout and one missed mutation, so active shard narrowing
  is retained only as a diagnostic sweep knob.
- A batch-shared graph-lock adapter path for consecutive multi-property MERGE
  mutations. It kept 2048x8 completion clean but did not improve throughput
  (`1103.77 QPS`, p50 `1440.79 ms`, p99 `5723.91 ms`) and worsened the 4096x8
  ceiling to `22598/32768` operations with `10170` first-response timeouts and
  `437.67 QPS`, so it was reverted.
- Raising the cooperative mutation offload pool cap from 64 to 80 to match the
  mutation admission window. The 2048x8 sustained gate failed before server
  readiness with `ServerStartupTimeout`, the same failure mode seen by the
  earlier 128-worker variant, so the offload pool stays capped at 64.

The current high-fanout defaults are 512 cooperative first-stream workers, 16
poll workers, 500 us group-commit coalescing, an 80-request shard-parallel
mutation cap, a 64-worker cooperative mutation offload pool for shard-parallel
mutations, all 16 group-commit write shards active, single-stream cooperative
handling by default, and no server short-header packet shedding. The next
implementation target is reducing the mutation storage/WAL commit tail and the
upstream QUIC short-header receive/frame-processing tail exposed by the
2048/4096 ceiling metrics.

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
  500 us; after the final QUIC `a1858c1` dependency correction, narrowing the
  shard-parallel mutation admission cap to 80 restored the 1024x8 and 2048x8
  mixed gates without increasing the coalescing wait. Earlier 100 us, 750 us,
  1000 us, and 2000 us probes remain rejected as defaults.
- `REQ-QUIC-HC-176`: cooperative first-stream pacing now tracks ready-queue
  depth and skips the high-fanout post-turn sleep only when queued ready work
  exceeds the scheduler worker count. The accepted variant passed the 1024x8
  and 2048x8 mixed sustained gates; more aggressive quarter-pool and guarded
  variants were rejected after reruns produced first-response timeouts.
- `REQ-QUIC-HC-178`: shard-parallel first-stream mutations can now move the
  packet execution and group-commit wait to a bounded offload pool after the
  cooperative scheduler grants a mutation permit. The stream owner remains
  marked running, preserving per-stream ordering, and shutdown waits for
  offloaded packets before reclaiming contexts. If the offload queue is full or
  unavailable, the scheduler falls back to the synchronous path.
- `REQ-QUIC-HC-179`: the group-commit coordinator can reserve new node IDs from
  only the first `GEODE_GROUP_COMMIT_ACTIVE_SHARDS` write shards for diagnostic
  sweeps. The production and harness defaults keep all 16 shards active; 4- and
  8-shard sweeps were rejected and not promoted.

Post-change 4096x8 read-only low-stagger probes improved from 11466
first-response timeouts before the shared-cache work to 9851 timeouts after
shared AST and plan hits. The 4096x8 mixed low-stagger probe improved from the
pre-cycle 12293-timeout ceiling to 9045 timeouts after skipping optimizer
admission for mutations. This is still a failing stress ceiling; the passing
sustained gate remains 2048x8 mixed. The tuple-lock striping cycle adds
instrumentation and collision reduction but has not promoted the 4096x8 gate;
the first re-run was invalidated by a concurrent root-owned `goreleaser`
cross-build saturating the host. The backlog-aware pacing cycle promoted the
2048x8 sustained result from 821.63 QPS to 848.39 QPS with zero first-response
timeouts on the prior dependency line. After the final QUIC `a1858c1` revert,
cap 128 produced rare 2048x8 first-response timeouts, and cap 80 restored a
clean 2048x8 sustained pass at 1111.06 QPS. The cooperative mutation offload
cycle then raised the best accepted 2048x8/1000 us sustained pass to 1895.40
QPS with zero first-response timeouts. A final pre-push rerun of the same gate
also passed with zero first-response timeouts at 948.72 QPS. The offload work
still does not promote the 4096x8 stress ceiling. The active-write-shard
diagnostic cycle recorded one all-shard 2048x8/1000 us pass at 5037.52 QPS, but
4- and 8-shard narrowing did not improve the accepted defaults and is not
promoted.

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
  and server default at `16`. The server accepts explicit sweeps up to `64` on the
  v0.1.21+ QUIC dependency line, but the measured 1024x8 mixed A/B did not
  improve throughput and increased poll overruns, so `64` is diagnostic-only.
- `GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING`: defaults to `0` for the high-fanout
  single-stream profile. Set `1` for clients that need additional peer-initiated
  streams on the same authenticated connection.
- `GEODE_QUIC_COOPERATIVE_FIRST_STREAMS`: defaults to `1`. Set `0` only when
  triaging compatibility against the detached-owner or shared-stream-pool paths.
- `GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS`: defaults to `512` in optimized
  builds and remains clamped at `512`.
- `GEODE_QUIC_CONNECTION_ADMISSION_THREADS`: defaults to `4096` in optimized
  builds so high-fanout HELLO admission does not collapse under rapid setup.
- `GEODE_QUIC_STREAM_QUEUE_CAPACITY`: defaults to `8192`.
- `GEODE_QUIC_STALL_CANCEL_MS` (SONNY-6466): the per-connection stall
  watchdog's threshold, default `60000`, clamped to `1000`-`3600000`, checked
  every 5 s. When no stream of a connection has read a message for this long,
  the connection's in-flight reads are cancelled (SQLSTATE 57014). This is the
  only bound on a read whose client vanished without a CONNECTION_CLOSE (the
  vendored quic sends no PINGs and does not enforce its advertised idle
  timeout), and it equally caps a single read running that long on a
  connection with no other stream reading, so keep it above your longest read.
  Connections are told apart by identity, not by peer address. A client that
  does send CONNECTION_CLOSE has its reads cancelled at once, on every stream.
- `GEODE_QUIC_MUTATION_ADMISSION_CAP`: cooperative first-stream mutation window.
  Leave unset in normal operation. General writer-lock mutations keep an
  internal serial cap of `4`; the runtime cap now controls only the
  shard-parallel multi-property `MERGE` window, which defaults to `80`.
- `GEODE_GROUP_COMMIT_COALESCE_US`: group-commit shard worker coalescing wait
  in microseconds, clamped at 5000 us. Leave at the 500 us default unless
  running a documented sweep; 100 us timed out at 2048x8 after the latest
  diagnostics, while 750 us, 1000 us, and 2000 us did not produce a robust
  default and could regress tail latency.
- `GEODE_GROUP_COMMIT_PHASE_METRICS`: opt-in detailed coordinator phase
  timers. Leave unset in normal gates; it adds multiple clock reads and atomics
  per mutation and is intended for attribution runs only.
- `GEODE_HC_METRICS_SCRAPE`: high-concurrency harness switch that enables the
  child metrics server on a private loopback port and prints selected runtime
  counters after the workload. This enables `GEODE_GROUP_COMMIT_PHASE_METRICS`
  by default for the child server unless explicitly overridden.
- `GEODE_HC_GROUP_COMMIT`: harness passthrough for `GEODE_GROUP_COMMIT`, useful
  for direct-path A/B probes. Keep it unset for normal gates.
- `GEODE_HC_GROUP_COMMIT_COALESCE_US`: harness passthrough for
  `GEODE_GROUP_COMMIT_COALESCE_US`.
- `GEODE_HC_GROUP_COMMIT_PHASE_METRICS`: harness passthrough for
  `GEODE_GROUP_COMMIT_PHASE_METRICS`.
- `GEODE_HC_MUTATION_ADMISSION_CAP`: harness passthrough for
  `GEODE_QUIC_MUTATION_ADMISSION_CAP`.
- The cooperative mutation offload pool is derived from the mutation admission
  cap and internally capped at 64 release workers. There is intentionally no
  public `GEODE_QUIC_MUTATION_OFFLOAD_WORKERS` knob after the 128-worker
  variant failed server readiness.
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
- `coord_submit_wait_ns_total`
- `coord_submit_wait_max_ns`
- `coord_queue_wait_ns_total`
- `coord_queue_wait_max_ns`
- `coord_queue_depth_max`
- `coord_coalesce_wait_ns_total`
- `coord_coalesce_wait_max_ns`
- `coord_apply_batch_ns_total`
- `coord_apply_batch_max_ns`
- `coord_apply_ops_loop_ns_total`
- `coord_apply_ops_loop_max_ns`
- `coord_apply_commit_ns_total`
- `coord_apply_commit_max_ns`
- `coord_apply_wake_ns_total`
- `coord_apply_wake_max_ns`

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
latency cost. Coordinator phase timers are opt-in because a 2048x8 scraped run
showed that detailed per-mutation timing can materially perturb the sustained
gate; use them for diagnosis, not as the objective-gate default. The current
best 2048x8 mixed setting is the default 500 us coalescing window with an 80
shard-parallel mutation admission cap.
`mg_rwlock_shared_hold_snapshot_ns_total` should stay at zero for the default
high-concurrency count workload unless RLS policies or a broader query shape
force snapshot execution.

## Shutdown Regression Coverage

The high-fanout server defaults also exercise long-lived background workers in
subprocess tests. The current regression set includes the 3-node real-process
cluster smoke because it caught two SIGTERM teardown stalls that the normal
query benchmarks did not cover:

- Raft outbox shutdown drops stale queued peer sends instead of spending the
  QUIC handshake timeout on every heartbeat/vote after peers are gone.
- Graph-store persistence sleeps through a futex wait on the shutdown word, so
  `stopPersistenceThread()` can wake it before joining the pool.

Use this target after touching server shutdown, cluster transport, persistence,
or thread-pool drain behavior:

```bash
timeout --kill-after=10s 180s zig build test-cluster-3node-subprocess --summary all
```

## Dependency State

As of this cycle, Geode pins:

- QUIC: `a1858c19ad91026eb412db263cb159d68de282ac`
- `geode-client-zig`: `942641cd1e71544560bbfe96db280fa271827a2c`

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

QUIC `8bb3733` then tested server short-header busy-connection shedding, but
the 2048x8 mixed gate rejected it with 25 first-response timeouts. QUIC
`a1858c1` reverts that experiment, and `geode-client-zig` `942641c` carries the
same reverted QUIC pin so Geode's server and embedded client remain aligned.

Dependency changes must be made in the upstream worktrees under
`~/src/devnw/zig/*` before Geode is repinned.

## Host Tuning

Before formal performance gates, apply the UDP buffer and host hygiene from
`docs/performance/host-tuning.md`. Undersized UDP buffers can look like QUIC
or scheduler stalls because packet loss inflates first-response tail.
