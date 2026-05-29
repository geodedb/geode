# Crash: TLS1.3 `pollCrypto` data race → SIGSEGV under concurrent connection churn

**Reported:** 2026-05-28
**Build:** geode `main` @ `935f197f` (`v0.6.4-63-g935f197f`), Zig 0.16.0, ReleaseSafe
**Deps:** `tls-0.1.7-mtEaLPZ…`, `quic-0.1.21-gBIqUYqB…` (the 2026-05-28 vendor pin), `thread_pool-0.2.4`
**Severity:** High — unrecoverable panic (exit 139 / SIGSEGV) takes down the whole server process.
**Status:** fixed upstream and pinned downstream on 2026-05-28.

This is a **different** failure from the #864 pollLoop-saturation deadlock. #864 is fixed on
this build (see "What is NOT affected"). This crash is a concurrency/memory-safety bug in the
TLS handshake-output path.

## 0. Resolution status

The TLS `pollCrypto` crash is closed by the upstream QUIC dependency and the matching Geode
dependency pins:

| Repo | Commit | Purpose |
|------|--------|---------|
| `devnw/zig/quic` | `292fb1aa2e7a1da80768c6d11bbf3354a7410a79` | Serializes deferred per-connection TLS handshake retries so concurrent endpoint poll workers cannot drain the same TLS `pollCrypto` buffer. |
| `devnw/zig/quic` | `553975f8da04e079888e78f12dc43a68e2fb4d07` | Adds a server-side receive-drain budget for request bursts after the crash fix, preventing high-fanout STREAM frames from being stranded behind PTO. |
| `devnw/zig/quic` | `fc7efc2d98a435a82598c2a34f697bde1c7532e2` | Final pushed v0.1.21 pin for Geode: preserves TLS serialization and the proven server receive/short-header drain after rejecting narrower drain variants. |
| `devnw/zig/quic` | `9a35274086e8cfb9cab5b78fa7471506aec03d3e` | Reverts the rejected one-batch server short-header app receive experiment, keeping the proven `a68d36e` behavior on upstream `main`. |
| `devnw/zig/quic` | `108d06d9bc3852a897699d83a677a61677f3f0a2` | Reverts the rejected `c2874fb`/`76b45ec` wall-clock short-header receive-yield experiments after they regressed Geode's accepted 4096 single-op gate. |
| `devnw/zig/quic` | `6224b28fc1654ccd20d1b5dc951e6502cb984aa7` | Rejected slow-batch server short-header cadence experiment; it regressed Geode's accepted 4096 single-op gate and is kept here only as an audit waypoint. |
| `devnw/zig/quic` | `eeeb2161ccd94c60f7c6b645bcfd16e20202593a` | Reverts the rejected `6224b28` slow-batch cadence experiment on upstream `main`, preserving the proven four-batch receive behavior. |
| `devnw/codepros/geode/geode-client-zig` | `959a43a7f6981a87131561bb6cb99605272c8ce8` | Pins the client package to the same QUIC fix set. |
| `devnw/codepros/geode/geode-client-zig` | `5a6b65a012e02db2a7acb6d0f37f2251f171edf0` | Pins the client package to QUIC `9a35274` so downstream consumers do not observe the rejected intermediate QUIC commit. |
| `devnw/codepros/geode/geode-client-zig` | `2f1bfe03fdf51476346ff8aca1c3e7c235a98931` | Pins the client package to QUIC `108d06d` so client and server both consume the accepted four-batch receive behavior. |
| `devnw/codepros/geode/geode-client-zig` | `b7eef87da566cf051ae5cd9e30b1d51507c59b9e` | Rejected client pin to QUIC `6224b28`; retained as an audit waypoint only. |
| `devnw/codepros/geode/geode-client-zig` | `533cde8f9b587e0a0b9065bb2f346f224479f02e` | Pins the client package to QUIC `eeeb216` so client and server share the upstream-main revert. |
| `devnw/codepros/geode/geode` | this dependency update | Pins direct `quic` and `geode_client_zig` dependencies to the same upstream QUIC revision. |

Regression coverage now includes the Geode vendored-source guard
`test-quic-condition-cadence`, which checks the upstream `REQ-QUIC-HC-137` TLS serialization
and `REQ-QUIC-HC-142` server receive-drain shape, plus the high-concurrency QUIC E2E mixed
read/write harness.

Latest verified Geode high-concurrency run:

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

Latest result after the 2026-05-29 empty-RLS-engine, mutation-permit,
shard-parallel admission, and final dependency-pin follow-ups: 4096 clients
connected and completed 4096 operations, including 1024 mutations, at 664.88 QPS
with zero setup retries, zero execution retries, zero reconnects, zero
first-response timeouts, and no `pollCrypto` crash. The sustained mixed gate is
now 2048 workers x 8 operations
(`16384/16384` complete, zero first-response timeouts, 1081.10 QPS).

Known remaining throughput limit: sustained 4096 workers x 8 operations still
fails within the 10s execute timeout (`ok=20475/32768` at 250 us request
stagger, `ok=25800/32768` at 1000 us in the latest final runs). That is a
separate post-handshake transport/scheduler ceiling and is documented in
`docs/audit/quic-high-concurrency-2026-05-29.md`.

---

## 1. Symptom

Under a write workload that ramps connection concurrency (rapid TLS handshake churn), a
thread-pool worker panics:

```
thread 40 panic: source and destination arguments have non-equal lengths
  std/array_list.zig:662:37            in toOwnedSlice          (zig 0.16 stdlib)
  tls-0.1.7/src/tls13/context.zig:934  in pollCrypto
  quic-0.1.21/src/quic/endpoint.zig:1860 in pollWithStats
  src/transport/quic.zig:617           in pollOnce
  src/transport/thread_pool.zig:337    in runSubmittedTask
  thread_pool-0.2.4/src/pool.zig:2067  in invokeTask
  thread_pool-0.2.4/src/pool.zig:1644  in workerMain
```

The panicking thread varies run to run (observed thread 40, thread 32), confirming this is not
tied to a single worker — it is whichever worker wins the race.

Container exits `139` (128 + SIGSEGV). On a 3-control-plane k8s cluster this is exactly the
api/pds CrashLoopBackOff symptom we saw under Playwright load (many parallel browser sessions →
many concurrent api→geode handshakes).

## 2. Reproduction

Build the server from main and run it locally:

```sh
cd ~/src/devnw/codepros/geode/geode
zig build -Doptimize=ReleaseSafe                  # produces zig-out/bin/geode
docker build -f Dockerfile.prebuilt -t geode:main-935f197f .
docker run -d --name geode-test -p 3141:3141/udp \
  -e GEODE_ADMIN_PASSWORD='QaGeodeSecret2024!' -e LOG_LEVEL=info geode:main-935f197f
```

Drive it with the loadtest harness on the **write** scenario, ramping concurrency:

```sh
cd ~/src/devnw/codepros/geode/geode-test-harness/loadtest/go
go build -o /tmp/geode-loadtest .
/tmp/geode-loadtest \
  -dsn 'quic://127.0.0.1:3141?insecure=true&user=geode&pass=QaGeodeSecret2024!' \
  -scenario edge_create \
  -levels '1,8,32,64,128' \
  -duration 5s
docker ps -a --filter name=geode-test --format '{{.Status}}'   # -> Exited (139)
```

Observed reproduction rate:

| Run | Workload | Result |
|-----|----------|--------|
| 1 | edge_create ramp 1→128 | **CRASH** (exit 139) at the c≥32 transition |
| 2 | edge_create ramp 1→128 | **CRASH** (exit 139) |
| 3 | edge_create ramp 1→128 | **CRASH** (exit 139) |
| — | edge_create **c=8 only** | clean (331 QPS, 0 errors, no crash) |
| — | two_hop ramp 1→128 (reads) | clean (0 errors through c=64; 10% timeouts at c=128, no crash) |
| — | full qaseed (130 users + all entities) | clean, 16s, no crash |

The trigger is **connection churn at a concurrency step-up under writes**, not raw query volume.
A single steady concurrency level (even c=8 writes at 331 QPS) does not trip it; the ramp's
rapid open/teardown of many connections does.

## 3. Faulting code

`tls-0.1.7/src/tls13/context.zig:931-936`:

```zig
/// Produce outbound CRYPTO payload for the given encryption level when available.
pub fn pollCrypto(self: *Context, allocator: std.mem.Allocator, level: EncryptionLevel) ![]u8 {
    var stream = self.streams.buffer(level);
    if (stream.outbound.items.len == 0) return ApiError.NothingToRead;
    // PERF-018: Use toOwnedSlice to transfer ownership without copying.
    return stream.outbound.toOwnedSlice(allocator);   // <-- line 934
}
```

Zig 0.16 `std/array_list.zig` `toOwnedSlice` (the copy fallback path, line ~662):

```zig
const old_memory = self.allocatedSlice();
if (gpa.remap(old_memory, self.items.len)) |new_items| {
    self.* = .empty;
    return new_items;
}
const new_memory = try gpa.alignedAlloc(T, alignment, self.items.len);  // alloc sized to len A
@memcpy(new_memory, self.items);   // <-- panics: new_memory.len (A) != self.items.len (B)
self.clearAndFree(gpa);
return new_memory;
```

The `@memcpy` panic `source and destination arguments have non-equal lengths` fires only when
`new_memory.len != self.items.len` **at the moment of the copy**. `new_memory` was just
allocated with `self.items.len`. For the two to differ, `self.items.len` must change between
the `alignedAlloc(self.items.len)` and the `@memcpy(..., self.items)` — i.e. another thread
mutated `stream.outbound` concurrently. This is a textbook data race on the `ArrayList`.

## 4. Root cause — concurrent `pollCrypto` on one connection's TLS context

`src/transport/quic.zig:606-621` `pollOnce` calls the vendor poll directly with **no external
per-connection lock**, by design:

```zig
fn pollOnce(self: *QuicTransport, timeout_ms: u32) !api.PollStats {
    if (self.endpoint) |ep| {
        ...
        // QUIC library v0.1.10: poll() is internally thread-safe with
        // fine-grained per-phase locking. No external PollSync needed
        // for the poll call itself. ...
        const stats = try ep.pollWithStats(timeout_i32);
        ...
    }
}
```

`pollOnce` runs on the shared `thread_pool` (multiple workers — thread 40 and thread 32 both
crashed here across runs). Inside `pollWithStats` (`endpoint.zig:~1860`), per-connection
handshake output is produced via `sendHandshakePackets → pollCrypto`, which mutates and then
`toOwnedSlice`s `connection.tls_context.streams.buffer(level).outbound`.

The QUIC lib's "fine-grained per-phase locking" evidently does **not** guarantee that a single
connection's TLS `Context` is touched by only one worker at a time. Under handshake churn, the
same handshaking connection is processed by two poll workers concurrently → two `pollCrypto`
calls race on the same `outbound` ArrayList → `toOwnedSlice` length mismatch → panic.

This is the gap left by the A6f work (`8b4924e2 fix(distributed): per-connection mutex around
QUIC vendor library calls`): that mutex guards the **client/query** vendor calls, but the
**server poll path** (`pollOnce → pollWithStats → pollCrypto`) deliberately takes no external
lock, trusting the lib's internal locking — which does not cover per-connection TLS buffer
ownership transfer.

## 5. Implemented fixes

1. **Serialize per-connection TLS context access inside the QUIC endpoint.** The real invariant
   is "one connection's `tls_context` is mutated by at most one thread at a time." Upstream QUIC
   commit `292fb1aa2e7a1da80768c6d11bbf3354a7410a79` applies that invariant to the pending
   handshake retry path by taking the endpoint receive serialization mutex and setting the
   active connection before driving `sendHandshakePackets`. Two poll workers can no longer
   concurrently drain one connection's TLS `pollCrypto` output.

2. **Increase server receive fairness under request bursts.** Upstream QUIC commit
   `553975f8da04e079888e78f12dc43a68e2fb4d07` keeps the client one-batch receive budget, but lets
   servers drain four UDP batches per endpoint poll cycle. This avoids synchronized STREAM
   request bursts being left for PTO after thousands of clients become ready together.

3. **Pin every downstream consumer to the same QUIC revision.** Geode now pins its direct QUIC
   dependency and `geode_client_zig` to the same upstream commit so client and server code do not
   pull different QUIC module instances into the build.

4. **Reduce server STREAM ACK fanout in the upstream QUIC receive path.** Upstream QUIC commit
   `a68d36e06dc9a0815a7a02d5e18b9d8d06e9ad6b` defers the first server-side STREAM-only standalone
   Application ACK. Geode request/response packets can then use the library's existing ACK+STREAM
   piggyback path on the response packet, while ECN/control packets and every second STREAM packet
   still ACK immediately. A new `AppAckDelay` timer preserves the RFC 9000 max-ACK-delay fallback
   for quiet or upload-only peers.

5. **Reject and revert narrower short-header cadence experiments.** Upstream QUIC commit `da08ef4`
   bounded server short-header app receive to one UDP batch, but it regressed 1024x8 throughput
   and introduced 4096 setup retries. QUIC `9a35274`, `geode-client-zig` `5a6b65a`, and Geode
   pinned the revert. Follow-up QUIC commits `c2874fb` and `76b45ec` tried a short-header
   wall-clock yield; the first regressed setup retries, and the repaired full-batch variant
   regressed Geode's accepted 4096 single-op gate to `ok=1043/4096` with `3053`
   first-response timeouts. QUIC `108d06d`, `geode-client-zig` `2f1bfe0`, and Geode pinned
   that revert before the later upstream-main revert pin.

6. **Reject the slow-batch cadence experiment and pin the upstream-main revert.** Upstream QUIC
   commit `6224b28fc1654ccd20d1b5dc951e6502cb984aa7` kept the full four-batch server
   short-header receive budget, but yielded after at least one complete batch had consumed 500 ms.
   The accepted 4096 single-op Geode gate rejected that change with `ok=1026/4096` and `3070`
   first-response timeouts. QUIC `eeeb2161ccd94c60f7c6b645bcfd16e20202593a`,
   `geode-client-zig` `533cde8`, and Geode now pin the upstream-main revert.

The original defense-in-depth guidance still applies for future TLS work: ownership transfer
from TLS outbound buffers must stay inside a single-writer critical section, and debug-only owner
assertions would catch any future regression earlier than a downstream `@memcpy` panic.

## 6. What is NOT affected (scope)

- **#864 pollLoop-saturation deadlock: FIXED.** Reads (`two_hop`) sustained c=64 at 0 errors and
  only degraded to graceful latency timeouts at c=128 — no wedge. The new watchdog metrics are
  present and healthy: `quic_pending_stream_handlers` stays ~0, `quic_stream_admission_rejections_total=0`,
  `quic_leaked_connections_reaped_total=0`, `quic_poll_overrun_total=0`,
  `proto_reader_messages_delivered_total` advances monotonically (6745 → 20334 across the read ramp).
- **Seed path: clean.** Full divelife qaseed (130 users + 20 sites + 15 species + dives + posts +
  conversations + …) completed in **16s** — the exact workload that hung 49 min at ~12 users on
  0.5.19.
- **Low/steady concurrency: clean.** edge_create at a fixed c=8 ran 331 QPS / 0 errors with no crash.

The crash is narrowly the **concurrent-handshake-churn** case, which is unfortunately the
production shape (many browser/api sessions establishing connections in bursts).

## 7. Evidence appendix

- Healthy boot metrics (main): `quic_max_stream_handlers=1024`, watchdog/leak counters all zero.
- Read ramp final metrics: `proto_reader_messages_delivered_total=20334`, `quic_active_connections=1`,
  `quic_pending_stream_handlers=1`, `quic_stream_admission_rejections_total=0`,
  `quic_leaked_connections_reaped_total=0`, `quic_poll_overrun_total=0`.
- Crash: `docker logs geode-test` → `thread N panic: source and destination arguments have
  non-equal lengths` with the stack in §1.
- Downstream context: divelife-argo `docs/quic-deadlock.md` (the #864 investigation this build fixes).
