# QUIC High-Concurrency Dependency Closeout - 2026-05-28

**Scope:** `devnw/zig/quic`, `geode-client-zig`, `geode`
**Status:** Upstream QUIC fixes and downstream dependency pins shipped to local branches; Geode verification covers 2048 concurrent clients with mixed reads and mutations.
**Primary risk closed:** TLS `pollCrypto` crash under concurrent handshake churn.
**Remaining limit:** Fully synchronized 4096-operation execution still times out after every client reaches ready state.

## Summary

This cycle moved the high-concurrency fixes into the upstream QUIC library first, then pinned both
Geode downstream consumers to the same upstream revision.

The root crash in `QUIC_TLS_POLLCRYPTO_CRASH.md` was a same-connection TLS context race: two endpoint
poll workers could drive a pending handshake retry and drain the same TLS outbound crypto buffer at
the same time. Upstream QUIC now serializes that path. After the crash was closed, the next bottleneck
was request-tail latency: synchronized client request bursts left STREAM frames behind the server
receive budget and forced avoidable PTO tails. Upstream QUIC now uses a role-aware endpoint receive
budget: clients keep the one-batch budget, while servers drain four UDP batches per poll cycle.

Geode itself did not add a new transport lock in this cycle. The direct fix belongs in QUIC because
the unsafe state is a per-connection TLS/endpoint invariant inside the library. Geode's local changes
pin the library revisions, preserve the 16-poller contention cap, and expand regression tests that
guard the dependency source shape.

## Dependency matrix

| Component | Pinned revision | Notes |
|-----------|-----------------|-------|
| `devnw/zig/quic` | `553975f8da04e079888e78f12dc43a68e2fb4d07` | Includes `292fb1aa` TLS `pollCrypto` serialization and `553975f8` server receive-burst draining. |
| `geode-client-zig` | `0fb1eaee496a7983f3d200272990c92586fc20e8` | Pins the client package to the same QUIC revision. |
| `geode` direct `quic` package | `553975f8da04e079888e78f12dc43a68e2fb4d07` | Keeps server-side QUIC and client-package QUIC in sync. |
| `geode` `geode_client_zig` package | `0fb1eaee496a7983f3d200272990c92586fc20e8` | Pulls the updated client dependency into the Geode build graph. |

## Fixes landed upstream

1. `292fb1aa2e7a1da80768c6d11bbf3354a7410a79` serializes pending per-connection handshake crypto
   retry work. It prevents concurrent endpoint poll workers from mutating or draining the same TLS
   `pollCrypto` output buffer.

2. `553975f8da04e079888e78f12dc43a68e2fb4d07` adds `REQ-QUIC-HC-142`, a role-aware receive-drain
   budget for endpoint polling. Client endpoints continue to drain one UDP batch per poll cycle.
   Server endpoints drain four batches, which materially reduces request-tail PTO during synchronized
   high-fanout traffic.

3. `0fb1eaee496a7983f3d200272990c92586fc20e8` in `geode-client-zig` updates the client package to
   consume the same QUIC server receive-burst fix.

## Geode changes

- `build.zig.zon` pins direct QUIC and `geode_client_zig` to the fixed revisions above.
- `src/server/main.zig` keeps the 16 endpoint-poller cap. The cap remains important because the QUIC
  library now serializes per-connection TLS context access; adding poll workers beyond the tested cap
  increased setup contention rather than throughput.
- `tests/test_quic_condition_timedwait_cadence.zig` now verifies the vendored QUIC source contains:
  `REQ-QUIC-HC-137` for TLS context serialization, `REQ-QUIC-HC-142` for server receive bursts,
  role-aware packet-budget helpers, and the updated short-header/initial receive-budget checks.

## Verification

All commands were run from the relevant repo on 2026-05-28.

| Repo | Command | Result |
|------|---------|--------|
| `devnw/zig/quic` | `zig build test` via pre-push hook | PASS before push of `553975f8`. |
| `geode-client-zig` | `zig build test --summary all` | PASS, 420/420 tests. |
| `geode` | `zig build test-quic-condition-cadence --summary all` | PASS, 66/66 tests. |
| `geode` | `GEODE_HC_WORKERS=2048 GEODE_HC_OPS_PER_WORKER=2 GEODE_HC_MUTATION_STRIDE=4 GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' GEODE_HC_CONNECT_STAGGER_US=1000 GEODE_HC_REQUEST_STAGGER_US=1000 GEODE_HC_EXEC_TIMEOUT_SECS=6 GEODE_HC_EXEC_RETRIES=0 GEODE_HC_POLL_WORKERS=16 timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all` | PASS: 2048 clients, 4096 operations, 3072 reads, 1024 mutations, 1972.24 QPS, zero setup retries, zero execution retries, zero reconnects. |

Representative 2048-client E2E result:

```text
workers=2048 ops=4096 reads=3072 mutations=1024
setup_ms=2747 elapsed_ms=2076 qps=1972.24
avg_read_ms=9.73 avg_mut_ms=9.29 max_ms=83.13
setup_attempts=2048 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

The same test shape also passed in a later clean-tree verification after reverting the 32-poller
experiment:

```text
workers=2048 ops=4096 reads=3072 mutations=1024
setup_ms=2743 elapsed_ms=5562 qps=736.40
avg_read_ms=653.42 avg_mut_ms=553.93 max_ms=3602.18
setup_attempts=2048 setup_retries=0
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

The second run is slower, but still validates the critical property for this cycle: no deadlock,
no `pollCrypto` crash, no setup retries, no execution retries, and no reconnects while processing
mixed reads and mutations from 2048 parallel clients.

## Negative result retained

A fully synchronized 4096-client single-operation run reached ready state for every client but timed
out most execution requests:

```text
workers=4096 ops=4096 reads=3072 mutations=1024
ready=4096 ops_started=4096 ok=1014 worker_failures=3082
execute_attempts=4096 execute_retries=0 execute_reconnects=0
```

This is no longer the TLS `pollCrypto` crash. The next bottleneck is post-handshake scheduling and
backpressure once all clients issue requests at the same time.

Raising `GEODE_QUIC_POLL_WORKERS` and the local server cap to 32 was tested and rejected. It worsened
setup contention:

```text
workers=4096 ready=305/4096
setup_attempts=31629 setup_retries=27765
```

The local Geode server cap remains 16 until the post-handshake scheduling limit is fixed and measured.

## Operational guidance

- Keep Geode and `geode-client-zig` pinned to the same upstream QUIC commit when updating either
  package. Dual QUIC revisions in the build graph make concurrency failures harder to reproduce.
- Keep `GEODE_QUIC_POLL_WORKERS` at or below 16 for this revision. More endpoint poll workers add
  lock contention around per-connection TLS serialization and did not improve 4096-client throughput.
- Use `GEODE_HC_CONNECT_STAGGER_US=1000` and `GEODE_HC_REQUEST_STAGGER_US=1000` for regression
  confirmation of the fixed 2048-client mixed workload. Remove or lower staggering only when
  specifically testing scheduler burst behavior.
- Treat 4096 synchronized post-ready execution as the next performance target, not as evidence that
  the TLS crash fix regressed.

## Follow-up work

The next cycle should target the server request scheduler after connection readiness:

1. Instrument ready-to-first-STREAM and STREAM-to-handler admission latency at the endpoint and Geode
   transport boundaries.
2. Separate endpoint packet draining from query execution admission pressure in the high-concurrency
   E2E counters.
3. Add a regression test that requires a bounded success ratio for 4096 synchronized single-operation
   requests once the post-handshake bottleneck is fixed.
4. Re-test the endpoint poller cap only after the scheduler instrumentation shows the limiting queue.
