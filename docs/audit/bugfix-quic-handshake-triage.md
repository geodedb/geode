# QUIC Handshake Timeout — Triage Report

## Issues Restated

1. After the Zig 0.16.0 migration, `geode query` against a local `geode serve` times out at the client deadline (5 s) for every query; 205 of 213 harness specs (all that require a live connection) fail. The server's UDP socket is bound but the initial hypothesis that "the server never sees packets" is **wrong** — it receives them and replies. The real failure is on the client side.

## Build / Test / Lint Entry Points

| Action | Command | Config File |
|--------|---------|-------------|
| Build | `make build` (debug) / `make release` | `Makefile`, `build.zig` |
| Unit tests | `make test` / `zig build test` | `build.zig` |
| Harness | `cd ../geode-test-harness && make test` | `geode-test-harness/Makefile` |
| Format | `make fmt` | — |
| Pre-commit | `make pre-commit` | `.pre-commit-config.yaml` |

## Reproduction Results

Reproduction from the user's snippet reproduced deterministically (3/3 runs):

| Issue | Command | Exit | Observed |
|-------|---------|------|----------|
| Client timeout | `./zig-out/bin/geode query --server 127.0.0.1:58600 --insecure-tls-skip-verify --timeout 5 "RETURN 1"` | 1 | `Error: query timed out after 5 seconds` |

Wire-level evidence (strace), captured with the server running and a real client handshake attempt:

- **Client** (pid ≈ main thread 2477832): 4× `sendto`, 1× `recvmmsg` success (2 datagrams in batch), 2× `poll`, then **silent** — no more network syscalls for the remaining ~4.9 s of the 5 s deadline.
- **Client thread 2 (deadline watchdog)**: 3× futex, mostly `nanosleep(100 ms)` loop. Normal.
- **Client thread 3 (worker)**: **12548× `futex(FUTEX_WAIT_PRIVATE, …, {tv_nsec≈250 μs}) = -1 ETIMEDOUT`** on a single address (0x7fef98460ef4) over the 5 s wait. This is a condvar/mutex timed-wait hot-loop — ~2500 wakeups/second, all returning "timed out, no signal".
- **Server**: receives 3 datagrams (Initial + 2 Handshake), sends ≈22–24 datagrams back (ServerHello, Handshake CRYPTO, 1-RTT). In one trace the server additionally **SIGSEGV**'d inside `processExpiredTimers → setPtoExpiredHandshake` (see "Secondary defect" below); the crash was intermittent (1 of 4 runs) and happened after the client had already stopped responding, so it is a consequence of client idleness, not the cause of the hang.

UDP path sanity checks:

- `ss -lun sport = :58600` → socket bound 127.0.0.1:58600, `Recv-Q = 0` during hang.
- With server `SIGSTOP`'d, sending 3 packets bumps `Recv-Q` to 2880 bytes — kernel delivery works. `SIGCONT` drains it.
- `/proc/net/udp` shows no drop counters on the server's socket.

## Root Cause Analysis

### Primary (blocking) defect — client-side

The client's QUIC endpoint poll loop **does not run**. Evidence:

- After the initial handshake burst (2 polls, 4 sends, 1 recv), the main thread stops calling `poll`/`recvmmsg`. The send of a `HELLO` frame on the stream goes out, but no further polls drive the endpoint, so the server's 1-RTT reply (which it actually sends — 22 `sendto`s on the wire) never makes it into the client's QUIC connection state.
- Meanwhile, a worker thread is spinning in a `std.Io.Condition` simulated `timedWait` at roughly 250 μs granularity (12 548 futex ETIMEDOUTs in 5 s, all on the same futex address) — the classic shape of a **sleep-poll condvar** waiting on progress that only the main thread can drive.
- The client goes through `src/cli/main.zig:2307 raw_client.connect()` (`src/client/zig_quic_bridge.zig:59`) → `geode_client_zig.GeodeClient.connect` (`zig-pkg/geode_client_zig-0.2.1-.../geode_client_v2.zig:268 connectQuic`), whose handshake loop at `geode_client_v2.zig:284-289` calls `quic.poll(ep, min(remaining, 100))` + `isHandshakeConfirmed` — this part **does** execute (2 polls, 1 recv). It exits as soon as one reply arrives.
- After handshake returns, the query path is `executeQueryOnConnection` (`src/cli/main.zig:2413`) → `writeProtoMessageViaZigClient` (HELLO write) → `readProtoMessageViaZigClient` (`src/cli/main.zig:2363`) → `client.receiveRawFrame(allocator, timeout_secs * std.time.ms_per_s)` → `geode_client_v2.zig:433 receiveRawFrame` → `receiveFramedPayloadQuic` (line 508) → loop at line 530 calling `quic.readStream` / `self.poll(min(remaining, 100))`.
- That loop **should** produce a `poll` syscall every iteration. It doesn't. The most plausible explanation given the third-thread futex storm is that `quic.readStream` (or the stream's internal wait) is acquiring a mutex that the third thread holds in a `timedWait`/`nanosleep` spin — classic **lock-order inversion introduced by Zig 0.16's `std.Io.Condition` losing `timedWait`** and being hand-rolled as a `nanosleep + re-check` loop.

The hand-rolled pattern is already visible in this codebase:

- `zig-pkg/quic-0.1.11-.../src/quic/endpoint.zig:582-598` — `waitForAccepted` explicitly notes "Zig 0.16.0: Io.Condition has no timedWait. Simulate with a poll loop" (5 ms slice).
- `src/transport/quic.zig:119-132` — `PollSync.waitForPoll` same note, falls back to a raw `nanosleep`.

The 250 μs futex wait length doesn't match either of those call sites (they use 5 ms / whatever the caller passed), which means there is at least one more `timedWait`-substitute site in either the vendored QUIC dep or `geode_client_zig` that was ported by a different author and uses a sub-millisecond cadence. Finding it (grep didn't locate it by literal constant — it's computed) is the first fix step.

### Secondary defect — server-side use-after-free (intermittent)

`zig-pkg/quic-0.1.11-.../src/quic/endpoint.zig:1489` passes `t.conn` (a `*Connection` cached on the timer struct) to `c.setPtoExpiredHandshake()` at `connection/methods_a.zig:892`. When the client goes silent mid-handshake, the endpoint PTO timer fires after `processIncomingDatagram` has already torn down the server-side handshake connection in a prior poll cycle — timer was removed from `self.timers` but the raw `*Connection` pointer in the captured `Timer` struct is dangling. Upstream `/home/benji/src/devnw/zig/quic/src/quic/endpoint.zig:1489` is bit-identical to the vendored copy, so any fix must land upstream as well.

This is independent of the primary defect (it only triggered 1 of 4 reruns) but will need to be fixed to keep the server from crashing on genuine client disconnect.

## Classification

| Issue | Root Cause | Type | Affected Files | Fix Order |
|-------|-----------|------|----------------|-----------|
| Client timeout (primary) | Zig 0.16 removed `std.Io.Condition.timedWait`; a hand-rolled condvar-wait substitute in the client stream path spins at ~250 μs ETIMEDOUT without ever letting the endpoint poll loop drain incoming datagrams — the main thread sends HELLO then gets stuck waiting on a signal that only arrives if someone calls `ep.poll()` | **Platform/Dependency change (Zig 0.16 API breakage)** — *not* OOM, *not* thread_pool lane config, *not* a 0-length read | `zig-pkg/geode_client_zig-0.2.1-.../geode_client_v2.zig` (receive path), `zig-pkg/geode_client_zig-0.2.1-.../src/pool.zig` (contains a `timedWait` at line 365, likely unrelated but worth auditing), plus whichever internal condvar is being timed-waited at 250 μs cadence — not yet pinpointed | 1 |
| Server `setPtoExpiredHandshake` SIGSEGV | Timer captured `*Connection` pointer, connection freed before timer fires → use-after-free in `processExpiredTimers` | **Logic bug** (lifetime/ownership) | `zig-pkg/quic-0.1.11-.../src/quic/endpoint.zig:1440-1507` (+ mirror in `/home/benji/src/devnw/zig/quic/src/quic/endpoint.zig`) and `connection/methods_a.zig:891` | 2 |

Neither failure is the three already-fixed categories the user called out (`/proc/self/cmdline` panic, `cert_gen` failing allocator, `thread_pool` lane config / double-free in `submitInternal`). `cert_gen`'s switch to Threaded + `smp_allocator` is irrelevant here: TLS cert generation, endpoint init, and the first two polls all succeed. The ~500 call sites of `std.Io.Threaded.global_single_threaded.io()` across `src/` and `zig-pkg/quic/` are essentially all mutex/condvar handles (the `.failing` allocator is never reached on this path), so the "failing allocator silently returning error" hypothesis is not the cause.

## Dependencies Between Failures

- Primary client-side hang must be fixed first. Once the client drives its poll loop, the server will complete handshake normally and never trigger the PTO handshake timer that currently crashes it.
- The server SIGSEGV is dormant as long as clients don't disconnect mid-handshake — but any real-world packet loss or mis-behaving client reintroduces it. Fix second, independently.

## Security / Data Integrity Concerns

- Server UAF (`setPtoExpiredHandshake` on freed `*Connection`) is remotely triggerable: any client that sends a valid Initial and then goes silent will schedule a PTO Handshake timer whose backing connection may already be gone. Exploitability beyond DoS depends on allocator reuse semantics of the connection arena. **Should be treated as a security bug**, not just a stability one.
- No data integrity concerns: WAL/persistence paths are not entered before handshake completes.

## Recommended Fix Order

1. **Pinpoint the 250 μs futex-spin site** and either (a) replace the hand-rolled `timedWait` with `nanosleep + re-check` at a saner cadence (5 ms like `waitForAccepted`), or (b) invert so the waiter drops into the endpoint poll (`ep.poll(min(remaining, 100))`) instead of a bare condvar wait. Candidate starting points: `zig-pkg/geode_client_zig-0.2.1-8ysbV5ybCAAZPBZ_YKQkxdIP0eLIoMvqHrnMc7_lUBKx/geode_client_v2.zig` (`writeAll` / `receiveFramedPayloadQuic` / `receiveRawBytes` loops — line 366, 467, 530, 565, 571), and `zig-pkg/quic-0.1.11-gBIqUbJHNgD3-ySQkll1QgLs8rIDloK08d8TDFJqWrQc/src/quic/transport.zig:69-109` `PollSync`. Attach strace with `-e trace=futex -yy` and match the futex address back to a condvar field via `/proc/<pid>/maps` to confirm before patching. Verify fix with `./zig-out/bin/geode query ...` (should return `1` in <1 s) and rerun the 205 harness specs.
2. **Fix the UAF in `processExpiredTimers`**: either (a) validate `t.conn` against `self.conns` membership under `mu` before dereferencing, or (b) remove all timers belonging to a connection at teardown time so they can't fire with a dangling pointer. Files: `zig-pkg/quic-0.1.11-.../src/quic/endpoint.zig:1481-1498` and the identical `/home/benji/src/devnw/zig/quic/src/quic/endpoint.zig:1481-1498`. The change must land in the sibling upstream repo too (identical content confirmed via `diff -q`).

## Relevant Files (absolute paths)

- `/home/benji/src/devnw/codepros/geode/geode/src/cli/main.zig` (query command, lines 2307, 2363, 2413, 2457)
- `/home/benji/src/devnw/codepros/geode/geode/src/client/zig_quic_bridge.zig` (client factory)
- `/home/benji/src/devnw/codepros/geode/geode/zig-pkg/geode_client_zig-0.2.1-8ysbV5ybCAAZPBZ_YKQkxdIP0eLIoMvqHrnMc7_lUBKx/geode_client_v2.zig` (connect, read/write, lines 260-580)
- `/home/benji/src/devnw/codepros/geode/geode/zig-pkg/geode_client_zig-0.2.1-8ysbV5ybCAAZPBZ_YKQkxdIP0eLIoMvqHrnMc7_lUBKx/src/pool.zig` (timedWait audit)
- `/home/benji/src/devnw/codepros/geode/geode/src/transport/quic.zig` (server PollSync, lines 69-132, 389-404)
- `/home/benji/src/devnw/codepros/geode/geode/src/server/main.zig` (poll pool wiring, lines 195-238, 753-840)
- `/home/benji/src/devnw/codepros/geode/geode/zig-pkg/quic-0.1.11-gBIqUbJHNgD3-ySQkll1QgLs8rIDloK08d8TDFJqWrQc/src/quic/endpoint.zig` and mirror `/home/benji/src/devnw/zig/quic/src/quic/endpoint.zig` (UAF at 1489)
- `/home/benji/src/devnw/codepros/geode/geode/zig-pkg/quic-0.1.11-gBIqUbJHNgD3-ySQkll1QgLs8rIDloK08d8TDFJqWrQc/src/quic/connection/methods_a.zig` and upstream mirror (crash site at 892)
- `/home/benji/src/devnw/codepros/geode/geode/zig-pkg/quic-0.1.11-gBIqUbJHNgD3-ySQkll1QgLs8rIDloK08d8TDFJqWrQc/src/quic/endpoint/udp_transport.zig:289-427` (UDP recv/poll — verified correct, rule-out only)
