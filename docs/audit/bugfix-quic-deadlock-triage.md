# QUIC Client Main-Thread Deadlock — Triage Report

**Issue:** GitLab #745. `geode query` hangs indefinitely after HELLO send; client times out.
**Date:** 2026-04-16.
**Scope:** Triage only (no fix). Follow-up to the UAF + cadence fixes landed under `devnw/zig/quic@6006c91` and `@51c1a03`.

## 1. Reproduction

Deterministic, reproduces every run:

```bash
cd /home/benji/src/devnw/codepros/geode/geode
./tests/test_quic_handshake_stall_regression.sh
# → FAIL: client exit=1 (expected 0). Pre-fix symptom: handshake stall.
```

Or manually:

```bash
./zig-out/bin/geode serve --data-dir /tmp/gtest --listen 127.0.0.1:58600 ... &
./zig-out/bin/geode query --server 127.0.0.1:58600 --insecure-tls-skip-verify -U geode -P ... "RETURN 1"
# → Error: query timed out after <N> seconds
```

Strace of the hung client reproduces the prior session's evidence exactly:

```
sendto 1200B Initial              (ClientHello)
sendto 1200B Initial               (echo)
sendto 1201B Handshake            (CRYPTO / Finished flight seed)
recvmmsg → 2 datagrams            (server ServerHello + Handshake)
sendto 1201B                       (client reply to Handshake)
futex(FUTEX_WAIT_PRIVATE, expect=2, NULL)  ← unbounded, never wakes
```

## 2. gdb Backtrace of the Hung Process

Three threads total: main, an idle `pool.Core.idle` worker (`park_cond.timedWait` 250 µs loop — by design, not the cause), and the CLI `deadlineWatchdog` nanosleep task.

Main thread:

```
#0  os.linux.x86_64.syscall4 (futex, addr=&conn->mu.state, op=FUTEX_WAIT_PRIVATE, val=contended, timeout=NULL)
#1  Io.Threaded.Thread.futexWaitInner(ptr, expect=2, uncancelable=true, timeout_ns=null)
#2  Io.Threaded.Thread.futexWaitUncancelable
#3  Io.Threaded.futexWaitUncancelable
#4  Io.futexWaitUncancelable__anon_12835 (expected=contended)
#5  Io.Mutex.lockUncancelable (m=&conn->mu)
#6  incoming.module_b.processHandshake  (/home/benji/src/devnw/zig/quic/src/quic/endpoint/incoming/module_b.zig:162)
#7  endpoint.Endpoint.processIncomingDatagram (/home/benji/src/devnw/zig/quic/src/quic/endpoint.zig:826, under self.mu held at :821)
#8  endpoint.Endpoint.pollWithStats (timeout_ms=100)
#9  api.poll → geode_client_v2.GeodeClient.connectQuic (/home/benji/src/devnw/codepros/geode/geode-client-zig/geode_client_v2.zig:289)
#10 cli.main.executeQuicQuery → cmdQuery → dispatch → main
```

The idle worker is in `sync.Condition.timedWait(250 µs)` inside `pool.Core.idle`. That is the by-design idle-park loop referenced in the task prompt — it has no connection state and is *not* the stall cause.

## 3. Observed Connection / Endpoint State (GDB)

Captured with `print conn->*`, `x/4wx &conn->mu.state`, on three independent hung-client runs. All three runs produced identical state, proving deterministic behavior rather than a race window:

| Field | Value | Meaning |
|---|---|---|
| `conn` | e.g. `0x7f78ac5ed000` | live client Connection |
| `conn->role` | `Client` | expected |
| `conn->closed` | `false` | live |
| `&conn->mu` | `conn + 0x1114c` | mu field is NOT at offset 0 despite being declared first — the compiler reordered, placing mu in the interior tail of the struct |
| **`*(u32*)&conn->mu.state`** | **`0x00000002` (== `State.contended`)** | **the smoking gun** — see §4 |
| `conn->initial_keys_dropped` | `true` | line 144-155 of `processHandshake` already executed this call |
| `conn->crypto_rx_off_handshake` | `0` | no Handshake CRYPTO bytes have been pushed yet — this is the **first** `processHandshake` call for this conn |
| `conn->handshake_packet_sent` | `false` | client has not sent any Handshake packet |
| `conn->pn_handshake_tx` | `0` | zero Handshake TX packets |
| `conn->crypto_rx_off_initial` | `90` | ServerHello was received and consumed |
| `conn->pn_initial_tx` | `4` | four client Initials transmitted |
| `conn->streams_rx.size` | `0` | no streams yet — nobody is in `pushStreamFrame` / `readStream` / `writeStream` |
| `self->mu` (Endpoint) | `locked_once` | legitimately held by main thread at `endpoint.zig:821` while processing the recvmmsg batch |
| `self->conns.size` | `2` | client conn registered twice (by DCID and by SCID), as expected by `createClientConnection` |

## 4. Root Cause

**`Connection.init()` at `/home/benji/src/devnw/zig/quic/src/quic/conn.zig:927` assigns every Connection field except `mu`.** The `Connection` struct declares:

```zig
pub const Connection = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,   // line 476
    id: u64,
    role: Role,
    ...
};
```

The default field initializer `= std.Io.Mutex.init` (which yields `State.unlocked` = `0`) is applied **only** when the struct is created via struct-literal syntax (`Connection{}` / `.{ ... }`). It is **not** applied when the struct is allocated via `allocator.create(Connection)` followed by per-field assignment, which is what `createClientConnection` does at `/home/benji/src/devnw/zig/quic/src/quic/endpoint/client.zig:106-107`:

```zig
const c = try allocator.*.create(conn_mod.Connection);   // uninitialized memory
c.init(allocator, .Client, sockToIsize(sock_fd), peer); // writes every field EXCEPT mu
```

`Connection.init` has explicit comments from a prior fix noting similar issues ("CRITICAL: Initialize cached Initial key fields to null / Without this, allocator.create() leaves them as undefined memory (0xAA pattern)"), but `mu` was missed. The compiler placed `mu` at offset `0x1114c` in the struct tail, which in our build path happens to contain the **non-zero** byte pattern `0x02` at the 4-byte state word.

### Why the wait never returns

`Io.Mutex.lockUncancelable` (zig stdlib `Io.zig:1623`):

```zig
const initial_state = cmpxchgStrong(unlocked → locked_once) orelse return;
if (initial_state == .contended) io.futexWaitUncancelable(&state, .contended);
while (state.swap(.contended, .acquire) != .unlocked) {
    io.futexWaitUncancelable(&state, .contended);
}
```

With `state` observed as `contended` (= 2):

1. `cmpxchg(unlocked → locked_once)` fails, returns `initial_state = .contended`.
2. Branch `if (initial_state == .contended)` is true → `futexWaitUncancelable(&state, contended)`.
3. Kernel futex check: `*addr == 2` and `expected == 2` → **block forever** (no timeout passed).
4. No holder of `conn->mu` exists. No other thread will ever `futexWake(&conn->mu.state, 1)`.

Classic lost-wake-up / stuck state — except here it is caused by garbage initial state rather than a missed wake.

## 5. Classification

| Dimension | Value |
|---|---|
| Defect type | **Configuration / Initialization bug** (uninitialized mutex) — not logic, not race, not dependency |
| Subtype | Default-field-initializer skipped when using `allocator.create()` + per-field `init()` |
| Reproduction | 100% deterministic on Zig 0.16.0 + Linux + Debug build |
| Surface | Client-side QUIC handshake; the server-side mu happens to land on a zero word in the same build, hence server-path tests pass |
| Security impact | None (no UAF, no OOB) |
| Data integrity impact | None |
| Blast radius | Every first-call acquisition of any `conn->mu`. The reason geode-harness specs that DO complete succeed is environmental luck: whether the allocator gives a page whose stale byte at offset `0x1114c+0` is `0x00` or `0x02`. That explains why this bug appears flaky in CI but reproduces hard on this host. |

## 6. Fix Site Prediction (narrowest-possible)

**Authoritative fix site:** `/home/benji/src/devnw/zig/quic/src/quic/conn.zig` — add `self.mu = std.Io.Mutex.init;` (or `self.mu = .{ .state = .init(.unlocked) };`) inside `Connection.init` at line 927, before the rest of the assignments.

One line, zero ambiguity. Per the user directive the edit must land upstream in `devnw/zig/quic`, not in `zig-pkg/`.

**Defensive companion (optional but recommended):** the same pattern bites `Endpoint.mu`, `Endpoint.timer_mu`, and `anti_replay.Cache.mu`. Audit every `struct { mu: std.Io.Mutex = std.Io.Mutex.init, ... }` and confirm either (a) all construction sites use struct-literal syntax, or (b) every explicit `init()` function assigns `self.mu`. Quick survey of the six matches in §7 below.

**Do NOT fix in geode or geode-client-zig.** The defect is 100% in upstream quic's Connection lifecycle. Fixing downstream would leave the bug latent for other consumers.

## 7. Related Sites (same pattern, same risk)

Every place a `std.Io.Mutex` field has a default initializer AND construction uses `allocator.create()`:

- `quic/conn.zig:476` `Connection.mu` — **confirmed broken**
- `quic/endpoint.zig:186` `Endpoint.mu` — appears OK at runtime (endpoint-mu observed as `locked_once` in GDB, meaning a previous lock-and-unlock cycle successfully happened). Still worth explicitly initializing.
- `quic/endpoint.zig:191` `Endpoint.timer_mu` — same caveat as above.
- `quic/transport.zig:70` — `Transport.mu`.
- `quic/anti_replay.zig:31` — `Cache.mu` (no default, field is required in struct-literal).

## 8. What to Verify Post-Fix

1. `./tests/test_quic_handshake_stall_regression.sh` passes, client exits 0 in < 2.5 s.
2. `crypto_rx_off_handshake` transitions 0 → ~N on the first successful `processHandshake`.
3. `geodetestlab` handshake specs regain green state (the ones documented as failing the same way on this host).
4. No regression in the prior-session fixes (`processExpiredTimers` UAF tests, 5 ms stream-receive cadence test).

## 9. Summary (under 800 words)

The client's main thread deadlocks on `conn->mu.lockUncancelable` at `module_b.zig:162` during the first ever Handshake packet processed on a fresh client connection. GDB inspection shows the mutex state is `contended` (raw `0x02`) despite no thread having ever locked it — only three threads exist in the process, and neither the idle `pool.Core.idle` worker nor the `deadlineWatchdog` nanosleep-er touches the mutex. The root cause is that `Connection.init` in `devnw/zig/quic/src/quic/conn.zig:927` writes every field of the struct **except `mu`**. The declared `= std.Io.Mutex.init` default is only applied under struct-literal construction; `createClientConnection` uses `allocator.create(Connection) + c.init(...)`, which leaves `mu` holding whatever bytes the allocator returned. In the current build those bytes happen to decode to `State.contended`, which causes `lockUncancelable` to enter `futexWait(expect=contended)` and block indefinitely, because no thread ever holds the mutex and therefore no thread ever calls `futexWake` on it. The fix is a single-line assignment inside `Connection.init`: `self.mu = std.Io.Mutex.init;`. The fix site is **upstream quic only** — geode and geode-client-zig require no changes. Adjacent mutex fields on `Endpoint` and `Transport` warrant the same audit even though they are not currently symptomatic, because the same pattern would be equally vulnerable to allocator byte-pattern variations.

## 10. Artifacts

- Reproduction script: `/home/benji/src/devnw/codepros/geode/geode/tests/test_quic_handshake_stall_regression.sh`
- GDB traces captured in transient `/tmp/srv*.log` + triage console output (pasted in §2–§3)
- Affected source file: `/home/benji/src/devnw/zig/quic/src/quic/conn.zig` (line 927)
- Caller that relies on default-init: `/home/benji/src/devnw/zig/quic/src/quic/endpoint/client.zig` (lines 106–107)
- Stdlib reference: `/home/benji/.local/share/mise/installs/zig/0.16.0/lib/std/Io.zig` (Mutex at line 1587, lockUncancelable at 1623)
- Prior (already landed) fixes to avoid regressing: `devnw/zig/quic@6006c91` (PtoHandshake UAF), `devnw/zig/quic@51c1a03` (5 ms receive cadence).
