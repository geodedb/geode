# QUIC Client Main-Thread Deadlock — Fix Report

**Issue:** [gitlab.com/devnw/codepros/geode/geode#745](https://gitlab.com/devnw/codepros/geode/geode/-/issues/745)
**Date:** 2026-04-16
**Scope:** Upstream `devnw/zig/quic` — `Connection.mu` initialization. Dep bump in `geode_client_zig` and `geode`.

---

## A) Summary

`Connection.init()` in `devnw/zig/quic/src/quic/conn.zig` never assigned `self.mu`, so the struct-literal default (`= std.Io.Mutex.init`) was bypassed by the `allocator.create(Connection) + c.init(...)` path in `createClientConnection`; the first `lockUncancelable` on that mutex saw allocator-returned bytes decoding to `.contended` (`0x02`) and entered an unbounded `futexWait` — fixed by explicitly assigning `self.mu = std.Io.Mutex.init;` at the top of `Connection.init` (upstream commit `4ddabaa`), and picked up downstream via dep bumps in `geode_client_zig@487dc81` and `geode@5f6c50ae`.

## B) Evidence

All commands executed from `/home/benji/src/devnw/codepros/geode/geode` on 2026-04-16.

| Check | Command | Result |
|-------|---------|--------|
| Build | `zig build` | **PASS** (exit 0) |
| Tests (geode) | `zig build test` | **PASS** (1059/1059) |
| Tests (upstream quic) | `(cd ../../../zig/quic && zig build test)` | **PASS** (107/113 pass, 6 skip — baseline unchanged) |
| Format | `zig fmt --check src/ tests/ tools/ benchmarks/ scripts/ build.zig` | **PASS** (exit 0) |
| Pre-commit | `pre-commit run --all-files` | **PASS** |
| Unit regression (quic) | `zig build test -Dtest-filter=conn_init_mutex` (upstream) | **PASS** 2/2 (was 0/2) |
| Condition cadence | `zig build test -Dtest-filter='timedwait cadence'` | **PASS** 2/2 (baseline, unchanged) |
| E2E regression | `./tests/test_quic_handshake_stall_regression.sh` | **Red** — core bug fixed (response `{"x":1}` in ~760 ms on stdout), but pins a second-order `deadlineWatchdog` stderr-noise bug for follow-up (see §D) |

## C) Tests Red→Green

| Test | Pre-fix | Post-fix |
|---|---|---|
| `conn_init_mutex` subtest 1 — state zero after init | **FAIL** (`0x02020202` retained) | **PASS** |
| `conn_init_mutex` subtest 2 — lock/unlock completes < 500 ms | **FAIL** (futex stalls > 500 ms deadline) | **PASS** |
| `zig build test` (upstream quic) | 105/113 pass (2 UAF crashes) → 107/113 after earlier session | 107/113 pass, 6 skip (unchanged) |
| `zig build test` (geode) | 1059/1059 | 1059/1059 |
| `test_quic_condition_timedwait_cadence.zig` | — | 2/2 **PASS** |
| `tests/test_quic_handshake_stall_regression.sh` | **FAIL** futex deadlock, elapsed 2064 ms, no response bytes | **Red** (~800 ms — *different bug*: handshake completes, `{"status_class":"00000","rows":[{"x":1}]}` printed on stdout; spurious `deadlineWatchdog` "query timed out after 2 seconds" emitted on stderr *after* success) |

## D) Risks

- **Core `#745` fix:** None. Single-line assignment, fully covered by the new `conn_init_mutex` unit test. No ABI change, no behavior change for any code path that was already correctly going through struct-literal construction.
- **Adjacent mutexes:** Triage §7 identified `Endpoint.mu`, `Endpoint.timer_mu`, `Transport.mu`, `anti_replay.Cache.mu` as carrying the same "default-initializer-bypassed" pattern. They were observed as *benign* under the current byte pattern but remain latent — tracked for defensive cleanup in a separate sweep (not blocking).
- **Follow-up bug exposed:** `src/cli/main.zig`'s `deadlineWatchdog` writes `Error: query timed out after 2 seconds` to stderr **after** the query has already returned a correct response. Root cause: `last_progress_ns` / `touchActiveQueryDeadlineWatchdog` is not `.touch()`-ed during the query round-trip, so the watchdog's `now - last_progress_ns >= 2s` check fires based on stale progress state. Wall-clock elapsed is always < 800 ms; the response is correct. Filed separately; the regression script stays red on this bug as pinned coverage. **Not caused by this change.**

## E) Git

**Three-repo state (all remotes == local HEAD after push):**

| Repo | Commit | Message |
|---|---|---|
| `devnw/zig/quic` | `2a51ab2` | `test: add reproduction for uninitialized Connection.mu` |
| `devnw/zig/quic` | `4ddabaa` | `fix: initialize Connection.mu in Connection.init (fixes #745 handshake deadlock)` |
| `devnw/codepros/geode/geode-client-zig` | `487dc81` | `fix: bump quic dep to include Connection.mu init fix (closes #745)` |
| `devnw/codepros/geode/geode` | `5f6c50ae` | `fix: bump quic dep to include Connection.mu init fix (closes #745)` |
| `devnw/codepros/geode/geode` | (this report commit) | `chore: add QUIC deadlock fix report + follow-up issue ref` |

**Pushed refs (verified `git fetch && git rev-parse origin/main` == local `HEAD`):**

- `devnw/zig/quic@origin/main == 4ddabaa`
- `devnw/codepros/geode/geode-client-zig@origin/main == 487dc81`
- `devnw/codepros/geode/geode@origin/main == 5f6c50ae` (verified via `git fetch --quiet origin && git rev-parse origin/main HEAD` — both equal)

**Issue state:**

- #745 — **Closed** 2026-04-16 via `glab issue close` with closure comment referencing upstream `4ddabaa` and geode `5f6c50ae`.
- #746 — **Opened** 2026-04-16 for the follow-up `deadlineWatchdog` stderr-noise bug.

**Follow-up issues filed:**

- **#746** — `QUIC client deadlineWatchdog emits 'query timed out' after successful response (stderr noise)` (labels: `gap`, `priority::medium`, `type::bug`, `area::cli`). Linked to #745 for trace walkability. URL: <https://gitlab.com/devnw/codepros/geode/geode/-/issues/746>.

**Blockers:** None.
