# Crash: TLS1.3 `pollCrypto` data race → SIGSEGV under concurrent connection churn

**Reported:** 2026-05-28
**Build:** geode `main` @ `935f197f` (`v0.6.4-63-g935f197f`), Zig 0.16.0, ReleaseSafe
**Deps:** `tls-0.1.7-mtEaLPZ…`, `quic-0.1.21-gBIqUYqB…` (the 2026-05-28 vendor pin), `thread_pool-0.2.4`
**Severity:** High — unrecoverable panic (exit 139 / SIGSEGV) takes down the whole server process.
**Status:** reproducible (3/3 on the write-ramp workload below; 0/1 on an isolated single-level run).

This is a **different** failure from the #864 pollLoop-saturation deadlock. #864 is fixed on
this build (see "What is NOT affected"). This crash is a concurrency/memory-safety bug in the
TLS handshake-output path.

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

## 5. Suggested fixes (in preference order)

1. **Serialize per-connection TLS context access inside the QUIC endpoint.** The real invariant
   is "one connection's `tls_context` is mutated by at most one thread at a time." Add a
   per-connection mutex (or an atomic "poll in progress" guard) in `endpoint.pollWithStats`
   around the per-connection handshake drive (the `sendHandshakePackets`/`pollCrypto` block at
   `endpoint.zig:~1860`), so two workers cannot drive the same connection's handshake
   concurrently. This is the correct fix and mirrors the A6f per-connection-mutex pattern,
   extended to the server poll path.

2. **Make `pollCrypto` ownership-transfer atomic w.r.t. appends.** If the TLS `Context` is meant
   to be single-writer, assert it (debug-only thread-id check) to catch the violation at its
   source rather than as a downstream memcpy panic. If it is meant to be concurrent, the
   `outbound` ArrayList itself needs a mutex covering both the producing append and the
   `toOwnedSlice` drain.

3. **Do not rely on `toOwnedSlice` under possible concurrency.** Even with a fix, prefer a
   snapshot under lock: take the mutex, read `items.len`, `alignedAlloc`, `@memcpy`, reset —
   all inside the critical section — so the length cannot change mid-copy.

Fix (1) is the root-cause fix; (2)/(3) are defense-in-depth. A debug `std.debug.assert` of a
per-context owner thread id would have surfaced this immediately and is cheap to add.

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
