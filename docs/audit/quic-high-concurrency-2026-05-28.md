# QUIC High-Concurrency Dependency Closeout - 2026-05-28

**Scope:** `devnw/zig/quic`, `geode-client-zig`, `geode`
**Status:** Upstream QUIC fixes are committed and pushed, downstream client pins are committed and pushed, and Geode is pinned to the final downstream revisions.
**Primary crash closed:** TLS `pollCrypto` same-connection contention under concurrent handshake churn.
**Stable gate now covered:** 2048 parallel clients with mixed reads and mutations, plus a 3072-client single-operation burst.
**Remaining limit:** Fully synchronized 4096-client execution still exceeds the current no-timeout gate after all clients reach ready state.

## Summary

This cycle kept the transport fixes in the upstream QUIC library under `~/src/devnw/zig/quic` first, then rolled the resulting pins through `geode-client-zig` and Geode. That keeps the server and client package on one QUIC build graph and prevents local dependency changes from being overwritten by package updates.

The root crash described in `QUIC_TLS_POLLCRYPTO_CRASH.md` was a same-connection TLS context race: multiple endpoint poll workers could concurrently retry pending handshake sends and drain the same TLS outbound crypto buffer. Upstream QUIC now serializes that path. After the crash was closed, the next bottleneck was high fan-in request scheduling: synchronized client request bursts could leave application STREAM packets and retransmits waiting behind server receive pressure.

The final upstream state keeps the proven four-batch server receive drain, keeps server short-header processing aligned with that drain, and sheds contended server ACK-frame work with a nonblocking connection mutex path. Two attempted optimizations were explicitly rejected because Geode E2E load tests regressed: deferring server STREAM ACKs and deferring initial receive-side flow-control updates.

## Dependency Matrix

| Component | Final revision | Notes |
|-----------|----------------|-------|
| `devnw/zig/quic` | `6934965a1f9603aa96cf9b36c97a26a7493d5cab` | Includes TLS `pollCrypto` serialization, bounded four-batch server receive drain, server short-header drain aligned to that receive budget, and nonblocking contended server ACK-frame handling. |
| `geode-client-zig` | `b963a956ec9b736e0fb777312dc0d4e29ec3e63b` | Pins the client package to QUIC `6934965`. |
| `geode` direct `quic` package | `6934965a1f9603aa96cf9b36c97a26a7493d5cab` | Keeps server-side QUIC and client-package QUIC in sync. |
| `geode` `geode_client_zig` package | `b963a956ec9b736e0fb777312dc0d4e29ec3e63b` | Pulls the updated client dependency into the Geode build graph. |

## Effective Upstream Fixes

1. TLS `pollCrypto` serialization prevents concurrent endpoint poll workers from mutating or draining the same per-connection TLS output state.
2. `REQ-QUIC-HC-142` keeps server endpoints at a bounded four-UDP-batch receive drain so fan-in request bursts do not sit in the kernel FIFO long enough to trigger PTO tails.
3. `REQ-QUIC-HC-123` keeps short-header processing bounded by role. The final server short-header budget matches the server receive drain; the one-batch server short-header cap was tested and rejected.
4. `REQ-QUIC-HC-143` changes server ACK-frame handling to use `tryLock()` for contended ACK-only receive work. Poll workers skip that contended ACK-frame update instead of blocking request delivery behind a response writer.
5. Immediate server STREAM ACKs and initial receive-side flow-control feedback are preserved. The rejected `REQ-QUIC-HC-144` and `REQ-QUIC-HC-145` deferral attempts are now guarded against by Geode source-audit tests.

## Geode Changes

- `build.zig.zon` pins direct QUIC and `geode_client_zig` to the final revisions above.
- `tests/test_quic_condition_timedwait_cadence.zig` expands the pinned dependency source audit:
  - uses a wider package-hash search window so long dependency comments do not fall back to stale cached packages;
  - verifies server receive and short-header budgets are present and aligned;
  - verifies contended server ACK-frame handling uses `ctx.conn.mu.tryLock()`;
  - verifies server STREAM ACK deferral is absent;
  - verifies initial receive-side flow-control still calls `advertiseInitialFlowControl()`.

## Verification

All commands were run on 2026-05-28.

| Repo | Command | Result |
|------|---------|--------|
| `devnw/zig/quic` | `zig build cross-smoke --summary all` | PASS. |
| `devnw/zig/quic` | `zig build test -Dtest-filter=contention_load --summary all` | PASS, 6/6 tests. |
| `devnw/zig/quic` | push hook | PASS: `zig build`, `zig build test`. |
| `geode-client-zig` | `zig build test --summary all` | PASS, 420/420 tests. |
| `geode-client-zig` | push hook | PASS: `zig build test`, `zig build test-fuzz`. |
| `geode` | `zig build test-quic-condition-cadence --summary all` | PASS, 67/67 tests. |
| `geode` | 2048-client mixed E2E command below | PASS, 4096 operations, zero retries, zero reconnects. |
| `geode` | 3072-client single-op mixed E2E command below | PASS, 3072 operations, zero retries, zero reconnects. |
| `geode` | 4096-client single-op mixed E2E command below | FAIL: all clients ready, 2929/4096 operations completed, zero retries/reconnects. |

2048-client mixed read/mutation gate:

```sh
GEODE_HC_WORKERS=2048 \
GEODE_HC_OPS_PER_WORKER=2 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=1000 \
GEODE_HC_EXEC_TIMEOUT_SECS=6 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

Result:

```text
workers=2048 ops_per_worker=2 ops=4096 reads=3072 mutations=1024
setup_ms=2679 elapsed_ms=2076 qps=1972.42
avg_read_ms=13.57 avg_mut_ms=12.35 max_ms=87.58
setup_attempts=2048 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

3072-client single-operation gate:

```text
workers=3072 ops_per_worker=1 ops=3072 reads=2304 mutations=768
setup_ms=3802 elapsed_ms=3107 qps=988.56
avg_read_ms=16.58 avg_mut_ms=16.02 max_ms=74.39
setup_attempts=3072 setup_retries=0
execute_attempts=3072 execute_retries=0 execute_reconnects=0
```

4096-client single-operation probe:

```text
workers=4096 ops_per_worker=1 ops=4096
connected=4096 hello_ok=4096 ready=4096 ops_started=4096 ok=2929
worker_failures=1167
setup_attempts=4096 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

This 4096 result is not the TLS `pollCrypto` crash and not connection setup churn. All clients reached ready state and no retries or reconnects were needed. The remaining limit is post-ready application request admission under a fully synchronized burst.

## Rejected Intermediate Changes

- Server STREAM ACK deferral: reduced standalone ACK work but caused Geode request timeouts under load.
- Receive-path flow-control deferral: caused the 2048 mixed gate to fail with 1108 worker timeouts.
- One-batch server short-header cap: reduced 4096 burst completion to 511/4096 operations. Restoring the four-batch server short-header drain raised the final 4096 completion to 2929/4096.

## Operational Guidance

- Keep Geode and `geode-client-zig` pinned to the same upstream QUIC commit.
- Keep `GEODE_QUIC_POLL_WORKERS=16` for this revision. Earlier 32-poller experiments increased setup contention and did not improve the 4096 gate.
- Use the 2048 mixed workload as the no-regression gate for reads plus mutations.
- Use the 3072 single-op workload as the current high-burst pass gate.
- Treat 4096 synchronized single-op execution as the next scheduler/admission target, not as evidence of the TLS crash returning.

## Follow-Up Work

1. Instrument ready-to-first-STREAM and STREAM-to-handler admission latency at the QUIC endpoint and Geode transport boundary.
2. Add queue-depth counters for request handler admission, response writer wait time, and per-connection app receive wakeups.
3. Separate endpoint packet-drain limits from query/mutation execution admission pressure in the high-concurrency E2E counters.
4. Add a regression gate for 4096 synchronized single-op requests once the post-ready admission bottleneck is fixed.
