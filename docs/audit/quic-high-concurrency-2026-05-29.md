# QUIC High-Concurrency Request Admission - 2026-05-29

**Scope:** `geode`
**Status:** 4096 mixed read/mutation single-op gate passes with zero setup retries, zero execute retries, and zero reconnects.
**Dependency state:** No new upstream QUIC or `geode-client-zig` commits were required in this cycle. Geode remains pinned to QUIC `fc7efc2d98a435a82598c2a34f697bde1c7532e2` and `geode-client-zig` `959a43a7f6981a87131561bb6cb99605272c8ce8`.

## Summary

The prior 2026-05-28 closeout left 4096 synchronized single-operation execution as the next transport-admission target. This cycle kept the dependency pins aligned and fixed the next Geode-side bottlenecks:

1. The high-concurrency protocol client was polling every WouldBlock at a fixed 100 us cadence. At 4096 local client threads this made the test driver a CPU storm and starved the child server. `REQ-QUIC-HC-149` now polls immediately, then uses a bounded adaptive wait and resets the backoff on successful reads.
2. Cooperative first-stream mutation admission previously allowed up to 128 mutation workers. The storage write path already serializes mutations, so those workers mostly blocked behind the write lock and starved read-tail scheduling. `REQ-QUIC-HC-150` caps the cooperative mutation admission window at 4 while preserving overflow requeue behavior.
3. Failed 4k probes printed thousands of duplicate worker timeout lines. `REQ-QUIC-HC-152` caps per-worker failure logs at 64 while preserving exact counters and final phase summaries.

## Changed Files

- `src/server/quic_connection_handler.zig`
  - Adds `first_stream_scheduler_mutation_limit_cap = 4`.
  - Uses the cap when deriving `FirstStreamScheduler.mutation_limit`.
- `tests/proto_test_util.zig`
  - Adds adaptive read polling for `QuicProtoClient`.
  - Keeps immediate `poll(0)` after writes and after packet reads.
- `tests/e2e_quic_high_concurrency.zig`
  - Caps individual failure log lines without changing counters.
- `tests/test_quic_condition_timedwait_cadence.zig`
  - Source-audits the new mutation window cap, adaptive polling shape, and failure-log backpressure.

## Accepted Verification

All commands below were run on 2026-05-29.

| Command | Result |
|---------|--------|
| `zig build test-quic-condition-cadence --summary all` | PASS, 70/70 tests. |
| 4096 mixed single-op E2E gate below | PASS, 4096/4096 operations, zero retries, zero reconnects. |
| 4096 read-only 250 us low-stagger probe | PASS, 4096/4096 operations, zero retries, zero reconnects. |
| `zig build --summary all` | PASS, debug binary rebuilt after ReleaseFast E2E runs. |

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
setup_ms=5159 elapsed_ms=4136 qps=990.19
avg_read_ms=117.84 avg_mut_ms=116.01 avg_first_op_ms=117.38 max_ms=513.76
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

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

The 250 us mixed read/mutation probe is intentionally more aggressive than the accepted regression gate. It remains useful for measuring the next bottleneck, but it is not yet promoted to a passing gate.

All rows below used 4096 workers, one operation per worker, mutation stride 4, 16 poll workers, zero execute retries, and a 10s execute timeout.

| Variant | Result | Decision |
|---------|--------|----------|
| No new mutation cap | `ok=776/4096` before adaptive polling and `ok=368/4096` after adaptive polling alone | Mutation write-lock contention dominated the mixed workload. |
| Mutation cap 16 | `ok=2963/4096` | Large improvement, but too many cooperative workers still blocked behind the writer path. |
| Mutation cap 4 | `ok=3910/4096` | Best low-stagger mixed result in this cycle; accepted as the regression-safe cap because the 1000 us 4096 gate passes. |
| Mutation cap 2 | `ok=2507/4096` | Too much mutation throttling reduced mixed progress and increased read timeouts. |
| Parked mutation-overflow wait queue | `ok=2287/4096` | Worse than immediate overflow requeue; it delayed mixed progress instead of reducing contention. |

## Known Unrelated Test Failure

`zig build test --summary all` still fails in the existing subprocess cluster smoke:

```text
test_cluster_3node_subprocess.test.three geode subprocesses on loopback form a 3-node Raft cluster
```

The failing nodes repeatedly log `raft transport getOrCreatePeerConnection failed error=HandshakeError` and do not elect a leader. Rebuilding the default debug binary with `zig build --summary all` succeeds, but a direct `timeout 300s zig build test-cluster-3node-subprocess --summary all` run still times out. That failure is in the distributed cluster subprocess path and is not part of the QUIC high-concurrency request-admission changes in this cycle.

## Operational Guidance

- Keep `GEODE_QUIC_POLL_WORKERS=16` for this dependency line.
- Use the 4096 mixed command above as the current no-retry high-concurrency regression gate.
- Keep the 250 us mixed probe as a diagnostic ceiling probe until it clears without raising the execute timeout.
- Do not promote the parked mutation-overflow queue without a better fairness design; the measured result regressed the workload.

## Remaining Work

1. Add transport counters for ready-to-first-EXECUTE latency and response write latency so the 250 us mixed tail can be split between request admission, mutation execution, and response delivery.
2. Add a passing 250 us mixed regression gate once the remaining 186-operation tail from the cap-4 probe is closed.
3. Revisit mutation admission per graph once the storage write path can execute independent graph mutations concurrently.
