# QUIC Handshake Stall — Reproduction Tests

Three failing reproduction tests for the primary and secondary defects
described in [bugfix-quic-handshake-triage.md](./bugfix-quic-handshake-triage.md).

All three tests must FAIL on the current tree (they do — evidence below) and
must PASS after the fix lands.

## Summary Table

| # | Test | File | Category | Scope | Pre-fix exit |
|---|------|------|----------|-------|--------------|
| 1 | `test_quic_handshake_stall_regression.sh` | `geode/tests/test_quic_handshake_stall_regression.sh` | End-to-end regression (real UDP, real QUIC, real TLS, real fork/exec of `geode serve` + `geode query`) | Primary defect (client-side hang) | `1` (2s budget trips) |
| 2 | `test_quic_condition_timedwait_cadence.zig` | `geode/tests/test_quic_condition_timedwait_cadence.zig` | Source-audit unit test (substring scan) | Primary defect (hand-rolled `timedWait` cadence) | `1` (error.SubMillisecondTimedWaitCadence) |
| 3 | `test_endpoint_pto_handshake_uaf_regression.zig` | `/home/benji/src/devnw/zig/quic/tests/test_endpoint_pto_handshake_uaf_regression.zig` | Unit regression (upstream quic repo — run via `zig build test -Dtest-filter=pto_handshake_uaf`) | Secondary defect (server UAF in `processExpiredTimers`) | `1` (2/2 SIGSEGV) |

## Evidence — All Three Tests FAIL Before Fix

### Test 1 — End-to-end handshake stall

```
$ bash tests/test_quic_handshake_stall_regression.sh
[handshake-stall] starting geode serve on 127.0.0.1:48943
[handshake-stall] server listening; running query with 2s budget
[handshake-stall] client exit=1 elapsed_ms=2065
[handshake-stall] client output:
  | Error: query timed out after 2 seconds
FAIL: client exit=1 (expected 0). Pre-fix symptom: handshake stall.
$ echo $?
1
```

**What the failure proves:** A real UDP handshake between `geode serve` and
`geode query` (no mocks, no in-process loopback) does not complete within a
2s budget because the client's worker thread spin-futexes in the sub-ms
`nanosleep + re-check` port at `zig-pkg/quic/.../src/quic/transport.zig:~788`
and starves the main thread of `ep.poll()` calls (exactly as described in
the triage primary-defect section).

### Test 2 — `timedWait` cadence audit

```
$ zig test tests/test_quic_condition_timedwait_cadence.zig
1/2 test_quic_condition_timedwait_cadence.test.quic condition timedWait ports use >=1ms cadence...
[cadence-audit] violations detected:
sub-millisecond nanosleep cadence found in
  zig-pkg/quic-0.1.11-gBIqUbJHNgD3-ySQkll1QgLs8rIDloK08d8TDFJqWrQc/src/quic/transport.zig:
  nanosleep(500 * std.time.ns_per_us)

[cadence-audit] fix: replace the sub-ms cadence with `5 * std.time.ns_per_ms`
so the hand-rolled timedWait port yields to the endpoint poll loop (matches
endpoint.zig:~582 and src/transport/quic.zig:~119).
FAIL (SubMillisecondTimedWaitCadence)
2/2 test_quic_condition_timedwait_cadence.test.quic converted timedWait sites
  keep their nanosleep+re-check shape...OK
1 passed; 0 skipped; 1 failed.
```

**What the failure proves:** The literal `nanosleep(500 * std.time.ns_per_us)`
pattern is still present in `zig-pkg/quic/.../src/quic/transport.zig`. The
"converted sites keep their shape" sibling test passes, confirming the two
already-ported call sites (`endpoint.zig:~582` `waitForAccepted`,
`src/transport/quic.zig:~119` `PollSync.waitForPoll`) still carry the 5 ms
cadence and the "Io.Condition has no timedWait" marker comment. The fix is to
replace `500 * std.time.ns_per_us` with `5 * std.time.ns_per_ms` at the
remaining site and the test will pass.

### Test 3 — Server-side UAF in `processExpiredTimers`

```
$ cd /home/benji/src/devnw/zig/quic
$ zig build test -Dtest-filter=pto_handshake_uaf
...
error: 'test_endpoint_pto_handshake_uaf_regression.test.processExpiredTimers
  does not UAF when PtoHandshake conn was freed' terminated with signal ABRT
  with stderr:
       Segmentation fault at address 0x7f886824818c
       src/quic/connection/methods_a.zig:882:22: setPtoExpiredHandshake
       src/quic/endpoint.zig:1489:43: processExpiredTimers
                           c.setPtoExpiredHandshake();
       src/quic/endpoint.zig:1522:34: forceExpireAllTimers
       tests/test_endpoint_pto_handshake_uaf_regression.zig:63: test body

error: 'test_endpoint_pto_handshake_uaf_regression.test.processExpiredTimers
  does not UAF when PtoInitial conn was freed' terminated with signal ABRT
  with stderr:
       Segmentation fault at address 0x7fc8bf44918c
       src/quic/connection/methods_a.zig:882:22: setPtoExpiredInitial
       src/quic/endpoint.zig:1482:43: processExpiredTimers
                           c.setPtoExpiredInitial();
       src/quic/endpoint.zig:1522:34: forceExpireAllTimers
       tests/test_endpoint_pto_handshake_uaf_regression.zig:92: test body

Build Summary: 3/5 steps succeeded (1 failed); 0/2 tests passed (2 crashed)
test transitive failure
+- run test 0 pass, 2 crash (2 total)
```

**What the failure proves:** Both `PtoHandshake` and `PtoInitial` arms of
`processExpiredTimers` dereference the `Timer`-captured `*Connection` pointer
after it has been freed. The SIGSEGV is deterministic under this test (2/2
crashes) because the test drives teardown and timer expiry on a single thread,
making the race into a certainty. This is the exact UAF described in the
triage secondary-defect section — a DoS surface where a client that sends a
valid Initial and then goes silent schedules a PTO Handshake timer whose
backing connection may already have been torn down.

The fix must either:

- Validate `t.conn` against `self.conns` membership under `mu` before
  dereferencing at `endpoint.zig:1481-1498`, or
- Remove all timers belonging to a connection at teardown time so they cannot
  fire with a dangling pointer.

## How to Run

```bash
# Test 1 (geode repo)
cd /home/benji/src/devnw/codepros/geode/geode
bash tests/test_quic_handshake_stall_regression.sh

# Test 2 (geode repo)
cd /home/benji/src/devnw/codepros/geode/geode
zig test tests/test_quic_condition_timedwait_cadence.zig

# Test 3 (upstream quic repo)
cd /home/benji/src/devnw/zig/quic
zig build test -Dtest-filter=pto_handshake_uaf
```

## Commit Locations

- `geode` repo (tests #1 and #2): both test files under
  `/home/benji/src/devnw/codepros/geode/geode/tests/`.
- Upstream `quic` repo (test #3): test file under
  `/home/benji/src/devnw/zig/quic/tests/` plus a small `build.zig` filter
  entry to wire it under `-Dtest-filter=pto_handshake_uaf`.
