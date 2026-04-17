# QUIC Client Main-Thread Deadlock — Reproduction Tests (Red State)

**Bug:** uninitialized `Connection.mu: std.Io.Mutex` — `Connection.init` at
`/home/benji/src/devnw/zig/quic/src/quic/conn.zig:927` omits
`self.mu = std.Io.Mutex.init;`, so the struct-literal default is bypassed by
the `allocator.create(Connection) + c.init()` pattern used by
`createClientConnection` (endpoint/client.zig:106-107). The mutex state word
retains allocator-returned bytes that decode to `State.contended` (raw 0x02),
sending the first `lockUncancelable` into `futexWait(expect=contended)` with
no thread ever posting a wake.

**Triage:** [bugfix-quic-deadlock-triage.md](bugfix-quic-deadlock-triage.md)
**Fix site (upstream only):** `/home/benji/src/devnw/zig/quic/src/quic/conn.zig:927`
**Commit adding reproduction tests:** `devnw/zig/quic@2a51ab2`
**Date captured:** 2026-04-16

---

## Tests Added

### 1. Unit test (new)

- **File:** `/home/benji/src/devnw/zig/quic/tests/test_conn_init_mutex.zig`
- **Build wiring:** `/home/benji/src/devnw/zig/quic/build.zig` filter arm
  `-Dtest-filter=conn_init_mutex`
- **Deterministic:** Yes. Pre-fills Connection backing bytes with `0x02`
  before calling `Connection.init` to reproduce the exact byte pattern GDB
  observed on the hung client.
- **Safe under CI:** Yes. Deadline on the watchdog subtest is 500 ms; no
  subtest can hang the runner.

Subtests:

1. `test.Connection.init zeroes mu.state even when backing bytes start as contended (0x02)`
   Asserts `@atomicLoad(u32, &conn.mu.state.raw, .monotonic) == 0` after init.
2. `test.Connection.init produces a mutex that can actually be locked and unlocked within 500ms`
   Spawns a worker that calls `mu.lockUncancelable(io)` then `mu.unlock(io)`;
   main thread polls a done-flag with a 500 ms deadline; detaches the stuck
   thread on timeout (rather than joining it) so the test process exits
   cleanly with FAIL status.

### 2. End-to-end regression (pre-existing, left unchanged per task scope)

- **File:** `/home/benji/src/devnw/codepros/geode/geode/tests/test_quic_handshake_stall_regression.sh`
- Committed in a prior session (handshake-stall regression). Reused here as
  the cross-layer proof that the unit-test bug actually reaches end-to-end
  handshake failure.

---

## Red-State Execution (pre-fix, 2026-04-16)

### Unit test (quic repo, `zig build test -Dtest-filter=conn_init_mutex`)

```text
test
+- run test 0 pass, 2 fail (2 total)
error: 'test_conn_init_mutex.test.Connection.init zeroes mu.state even when backing bytes start as contended (0x02)' failed:
         FAIL: Connection.mu.state.raw = 0x02020202 after init (expected 0x00000000)
         This means Connection.init did not initialize the mutex — the default
         `mu: std.Io.Mutex = std.Io.Mutex.init` is bypassed by allocator.create()
         + per-field init().
       expected 0, found 33686018
error: 'test_conn_init_mutex.test.Connection.init produces a mutex that can actually be locked and unlocked within 500ms' failed:
         FAIL: lock/unlock round-trip did not complete within 500ms.
         Connection.mu.state.raw = 0x00000002 — the mutex is stuck in
         futexWait(expect=contended) because Connection.init never
         reset it to .unlocked. The worker thread is blocked forever.
Build Summary: 2/4 steps succeeded (1 failed); 0/2 tests passed (2 failed)
```

- **Shell exit code:** `1`
- **Wall-clock to failure:** < 600 ms (both subtests enforce their own
  timeouts; no process hang possible)
- **Why it fails now:** `Connection.init` never assigns `self.mu`. The
  bytes we stamped into the buffer survive the init call.
- **Why it will pass post-fix:** Adding
  `self.mu = std.Io.Mutex.init;` at the top of `Connection.init` zeroes
  the state word, so `lock()` sees `.unlocked` and the `cmpxchgStrong(
  .unlocked → .locked_once)` fast path succeeds.

### End-to-end regression (geode repo, `./tests/test_quic_handshake_stall_regression.sh`)

```text
[handshake-stall] starting geode serve on 127.0.0.1:45859
[handshake-stall] server listening; running query with 2s budget
[handshake-stall] client exit=1 elapsed_ms=2064
[handshake-stall] client output:
  | Error: query timed out after 2 seconds
FAIL: client exit=1 (expected 0). Pre-fix symptom: handshake stall.
```

- **Shell exit code:** `1`
- **Client elapsed:** `2064 ms` (exceeded the 2 s internal budget, tripped
  the wall-clock deadline in cmdQuery)
- **Why it fails now:** The client's `Endpoint.processIncomingDatagram`
  path at `endpoint.zig:826` reaches
  `incoming/module_b.zig:162` → `conn.mu.lockUncancelable(io)` on the
  first Handshake packet. The mutex's uninitialized state word is
  `.contended` so the main thread enters `futexWait(expect=contended)`
  and never returns. The CLI's deadlineWatchdog fires the 2 s timeout
  and the client exits 1.

---

## Commit Trail

- `devnw/zig/quic@2a51ab2` — `test: add reproduction for uninitialized Connection.mu`
  (tests/test_conn_init_mutex.zig + build.zig filter arm)

The end-to-end script was committed on the geode side in the prior session
— this step did not duplicate it.

## Next Step

The fix itself (`self.mu = std.Io.Mutex.init;` inside `Connection.init`
body at conn.zig:927) is deliberately withheld in this step. After the
fix lands upstream we will re-run both tests and expect:

- Unit test: 2/2 pass in < 50 ms
- End-to-end: client exits 0 in < 500 ms, `elapsed_ms < 2500`
