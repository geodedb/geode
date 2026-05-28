# QUIC High-Concurrency Dependency Closeout - 2026-05-28

**Scope:** `devnw/zig/quic`, `geode-client-zig`, `geode`
**Status:** Upstream QUIC fixes are committed and pushed; downstream client and Geode pins are aligned to the final upstream revision.
**Primary crash closed:** TLS `pollCrypto` same-connection contention under concurrent handshake churn.
**Validated high-burst gate:** 3072 parallel clients, mixed reads and mutations, zero retries.
**Open ceiling target:** 4096 fully synchronized single-operation execution still times out and remains the next admission/scheduling target.

## Summary

This cycle kept dependency-library work in `~/src/devnw/zig/quic` first, then rolled the tested pins through `geode-client-zig` and Geode. That keeps Geode's server and client package on one QUIC module instance and avoids local dependency edits being overwritten by package resolution.

The crash described in `QUIC_TLS_POLLCRYPTO_CRASH.md` was a same-connection TLS context race: concurrent endpoint poll workers could retry pending handshake sends and drain the same TLS outbound crypto state. Upstream QUIC now serializes that path. The remaining work shifted from crash safety to high-burst request admission under post-ready application traffic.

Three additional 4096-client variants were tested and rejected in this cycle:

- One-batch server short-header drain: prevented poll-loop monopolization in theory, but starved setup/execution in practice.
- Nonblocking same-connection packet shedding before packet-number tracking: avoided blocking but dropped too many request packets before the 10s execute timeout.
- Two-batch server short-header drain: split the difference but still regressed setup and execution versus the proven four-batch drain.

The final upstream revision therefore restores the proven wider server short-header drain and documents the rejected paths rather than shipping a worse 4096 behavior.

## Dependency Matrix

| Component | Final revision | Notes |
|-----------|----------------|-------|
| `devnw/zig/quic` | `fc7efc2d98a435a82598c2a34f697bde1c7532e2` | Supersedes rejected one-batch and packet-shedding commits; preserves TLS `pollCrypto` serialization, four-batch server receive drain, server short-header drain aligned to that budget, and contended server ACK-frame shedding. |
| `geode-client-zig` | `959a43a7f6981a87131561bb6cb99605272c8ce8` | Pins client package QUIC to `fc7efc2`. |
| `geode` direct `quic` package | `fc7efc2d98a435a82598c2a34f697bde1c7532e2` | Keeps server-side QUIC aligned with client package QUIC. |
| `geode` `geode_client_zig` package | `959a43a7f6981a87131561bb6cb99605272c8ce8` | Pulls the updated client dependency into Geode. |

## Effective Upstream Fixes

1. TLS `pollCrypto` serialization prevents concurrent endpoint poll workers from mutating or draining the same per-connection TLS output state.
2. `REQ-QUIC-HC-142` keeps server endpoints at a bounded four-UDP-batch receive drain so fan-in request bursts do not sit in the kernel FIFO long enough to trigger PTO tails.
3. `REQ-QUIC-HC-123` keeps short-header processing bounded by role. The final server short-header budget intentionally matches the server receive drain.
4. `REQ-QUIC-HC-143` changes server ACK-frame handling to use `tryLock()` for contended ACK-only receive work. Poll workers skip that contended ACK-frame update instead of blocking request delivery behind a response writer.
5. Immediate server STREAM ACKs and initial receive-side flow-control feedback are preserved. The rejected STREAM ACK and receive-side flow-control deferral attempts remain guarded by Geode source-audit tests.

## Geode Changes

- `build.zig.zon` pins direct QUIC and `geode_client_zig` to the final revisions above.
- `tests/test_quic_condition_timedwait_cadence.zig` verifies the active QUIC package source includes:
  - server receive and short-header budgets;
  - contended server ACK-frame handling via `ctx.conn.mu.tryLock()`;
  - absence of server STREAM ACK deferral;
  - immediate initial receive-side flow-control via `advertiseInitialFlowControl()`.

## Verification

All commands were run on 2026-05-28.

| Repo | Command | Result |
|------|---------|--------|
| `devnw/zig/quic` | `zig test src/quic/endpoint.zig --test-filter "endpoint short header poll budget"` | PASS. |
| `devnw/zig/quic` | push hook | PASS: `zig build`, `zig build test`. |
| `geode-client-zig` | `zig build test --summary all` | PASS, 420/420 tests. |
| `geode-client-zig` | push hook | PASS: `zig build test`, `zig build test-fuzz`. |
| `geode` | `zig build test-quic-condition-cadence --summary all` | PASS, 67/67 tests. |
| `geode` | 3072-client single-op mixed E2E command below | PASS, 3072 operations, zero retries, zero reconnects. |

3072-client final-pin gate:

```sh
GEODE_HC_WORKERS=3072 \
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
workers=3072 ops_per_worker=1 ops=3072 reads=2304 mutations=768
setup_ms=3864 elapsed_ms=3107 qps=988.63
avg_read_ms=16.40 avg_mut_ms=15.74 max_ms=71.63
setup_attempts=3072 setup_retries=0
execute_attempts=3072 execute_retries=0 execute_reconnects=0
```

## Rejected 4096 Variants

All 4096 probes used 4096 workers, one operation per worker, mutation stride 4, zero execute retries, 16 poll workers, and a 10s execute timeout.

| Variant | Result | Why rejected |
|---------|--------|--------------|
| One-batch server short-header drain (`4eebb8e`) | `ok=66/4096`, `setup_retries=131` | Starved setup and execution despite reducing the nominal short-header batch size. |
| Nonblocking same-connection short-header shedding (`b8d331d`) | `ok=850/4096`, `setup_retries=0` | Dropped too much request traffic before the execute timeout. |
| Two-batch server short-header drain (local `--fork` probe) | `ok=373/4096`, `setup_retries=42` | Worse than the proven four-batch drain and reintroduced setup retries. |

The restored four-batch short-header drain remains the least-bad tested behavior for this revision line. The 4096 synchronized workload still needs a separate admission/scheduler fix; it is not evidence that the TLS `pollCrypto` crash returned.

## Operational Guidance

- Keep Geode and `geode-client-zig` pinned to the same upstream QUIC commit.
- Keep `GEODE_QUIC_POLL_WORKERS=16` for this revision. Earlier 32-poller experiments increased setup contention and did not improve the 4096 gate.
- Use the 2048 mixed workload as the broad read/mutation no-regression gate.
- Use the 3072 single-op workload as the current high-burst pass gate.
- Treat 4096 synchronized single-op execution as the next scheduler/admission target, not as a dependency-pin target for the rejected QUIC drain variants.

## Follow-Up Work

1. Instrument ready-to-first-STREAM and STREAM-to-handler admission latency at the QUIC endpoint and Geode transport boundary.
2. Add queue-depth counters for request handler admission, response writer wait time, and per-connection app receive wakeups.
3. Separate endpoint packet-drain limits from query/mutation execution admission pressure in the high-concurrency E2E counters.
4. Add a 4096 synchronized single-op regression gate once the post-ready admission bottleneck is fixed.
