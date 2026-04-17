# Bug Fix Report — QUIC Handshake Stall + processExpiredTimers UAF

**Date:** 2026-04-17
**Scope:** `geode`, `geode-client-zig`, upstream `devnw/zig/quic`
**Status:** 2 of 3 bugs fixed and shipped. 1 newly surfaced (client main-thread deadlock) filed as follow-up.

## A) Summary

Triage targeted a hung `geode query ... RETURN 1` against a live `geode serve` (2s timeout reproducible). Root-cause analysis uncovered three independent defects. Two are closed; the third surfaced only after the first two were fixed and is tracked as a follow-up GitLab issue.

**Fixed and shipped:**

1. **Server-side UAF in `processExpiredTimers`** (upstream `devnw/zig/quic` 6006c91). Timers captured a `*Connection` pointer; when the connection was destroyed before the timer fired (PtoInitial/PtoHandshake/PtoApp/Pmtud/paced), the timer deref SIGSEGV'd the server. Exploitable as an **unauthenticated remote DoS**: a client sends Initial, drops, and the resulting PTO timer kills the process. Fixed by adding an `Endpoint.isConnectionLive` guard in front of every `*Connection` deref captured in a timer closure.

2. **Sub-millisecond `nanosleep` cadence in `QuicStream.readLine`** (upstream 51c1a03). The hand-rolled `std.Io.Condition.timedWait` port polled at 500 µs instead of the 5 ms cadence used at the two already-converted sites (`endpoint.zig:~582`, `src/transport/quic.zig:~119`). Produced pathological scheduler pressure under contention. Fixed by bumping to 5 ms and matching the sibling markers.

**Surfaced, not fixed (follow-up):**

1. **Client main-thread deadlock after HELLO.** Post-fix strace shows the client parked on `futex(addr, FUTEX_WAIT_PRIVATE, 2, NULL)` — an **unbounded** mutex acquire inside `std.Io.Mutex.lockUncancelable`, not a sub-ms spin. This is a distinct defect that was previously masked by the cadence defect and is now the gating red on `test_quic_handshake_stall_regression.sh`. Per bug-fix methodology we reported rather than patched.

## B) Evidence

| Check | Command | Result |
|-------|---------|--------|
| Build | `zig build` | PASS |
| Tests (full) | `zig build test` (via pre-push hook) | PASS |
| Cadence regression | `zig test tests/test_quic_condition_timedwait_cadence.zig` | PASS (2/2) |
| Upstream UAF regression | `zig build test -Dtest-filter=pto_handshake_uaf` (in `/home/benji/src/devnw/zig/quic`) | PASS (2/2), pre-fix crashed 2/2 |
| Handshake-stall E2E | `bash tests/test_quic_handshake_stall_regression.sh` | **STILL RED** — gating red on follow-up issue |
| Format | `zig fmt --check src/ tests/ tools/ benchmarks/ scripts/ build.zig` | PASS |
| Pre-commit | `pre-commit run --all-files` | PASS |
| Pre-push | `git push origin main` (hooks: cross-compile, full test, CANARY verify, MATCH ops campaign, status.csv sync) | PASS |

## C) Tests Red → Green

| Test | File | Pre-fix | Post-fix | Covers |
|------|------|---------|----------|--------|
| `test_endpoint_pto_handshake_uaf_regression` (PtoInitial) | upstream `quic/tests/` | CRASH (SIGSEGV) | PASS | Remote DoS via PTO timer UAF |
| `test_endpoint_pto_handshake_uaf_regression` (PtoHandshake) | upstream `quic/tests/` | CRASH (SIGSEGV) | PASS | Remote DoS via PTO timer UAF |
| `test_quic_condition_timedwait_cadence` (sub-ms scan) | `tests/test_quic_condition_timedwait_cadence.zig` | FAIL | PASS | Prevents re-introduction of sub-ms nanosleep in vendored QUIC |
| `test_quic_condition_timedwait_cadence` (shape check) | `tests/test_quic_condition_timedwait_cadence.zig` | PASS | PASS | Keeps 5ms cadence marker + re-check shape on converted sites |
| `test_quic_handshake_stall_regression.sh` | `tests/test_quic_handshake_stall_regression.sh` | FAIL (2065ms timeout) | **STILL FAIL (2084ms timeout)** | Pins the unresolved client deadlock — intentionally left red until follow-up lands |

`test_quic_handshake_stall_regression.sh` is intentionally **not** being edited to pass. Its job is to keep pressure on the client-side deadlock until it is closed.

## D) Risk Notes

- **Ship-worthy even without stall fix.** The UAF alone closes an unauthenticated remote DoS primitive in QUIC (attacker sends Initial, drops, server segfaults). That is independent remediation value and worth landing on its own.
- **Scheduler pressure relief.** The 5 ms cadence fix removes a hot sub-ms polling loop that was visible under strace. Benefit is latent until the client deadlock is resolved, but it removes a footgun for any caller of `QuicStream.readLine`.
- **Remaining risk — client deadlock.** `geode query` against `geode serve` still hangs past a 2 s budget after HELLO. Interactive shell and any bounded-latency caller are affected. Tracked in the follow-up issue; regression test stays red.
- **No user-facing API or wire-format changes.** Pure defect remediation.
- **No CANARY marker changes.** CANARY governance unchanged; `status.csv sync check` green.

## E) Git

### Commits (three repos)

**Upstream `/home/benji/src/devnw/zig/quic`** (origin: already pushed prior to this step):

| SHA | Type | Message |
|-----|------|---------|
| `6006c91` | fix | prevent UAF in processExpiredTimers PtoHandshake/PtoInitial |
| `51c1a03` | fix | stream-receive timedWait polls at 5ms cadence |

Remote ref: `origin/main` @ `51c1a03` (verified `git log origin/main -5`).

**Sibling `/home/benji/src/devnw/codepros/geode/geode-client-zig`** (origin: already pushed prior to this step):

| SHA | Type | Message |
|-----|------|---------|
| `c4d678c` | fix | bump quic dep to pick up handshake stall + UAF fixes |

Remote ref: `origin/main` @ `c4d678c` (verified `git log origin/main -3`).

**Geode `/home/benji/src/devnw/codepros/geode/geode`** (pushed this step):

| SHA | Type | Message |
|-----|------|---------|
| `016fe883` | test | add reproduction tests for QUIC client handshake stall |
| `02bb4756` | fix | bump quic dep to include handshake-stall + processExpiredTimers UAF fixes |

Tests-first order preserved (016f before 02bb). Remote ref: `origin/main` @ `02bb4756` (verified `git fetch && git rev-parse origin/main`).

### Branch

- **Branch:** `main` (no feature branch per repo convention for small, well-bounded fixes landing with full CI green).
- **Pushed ref:** `origin/main` @ `02bb4756`
- **Verification:** `git rev-parse HEAD` == `git rev-parse origin/main` == `02bb475652fd0bcc6ae3bd989edc1e65edcdcda5`.

### Blockers

None. All three repos pushed. Pre-push hooks (including full `zig build test`, cross-compile, CANARY verify, MATCH ops campaign) green. No `--no-verify`, no force-push, no amend.

### Follow-up issue

Filed as GitLab **issue #745**: [QUIC client main-thread deadlocks after HELLO send (unbounded futex wait)](https://gitlab.com/devnw/codepros/geode/geode/-/work_items/745). Labels: `gap`, `priority::high`, `type::bug`, `area::transport`, `category::quic`. Cites strace evidence and pins `test_quic_handshake_stall_regression.sh` as the gating regression.
