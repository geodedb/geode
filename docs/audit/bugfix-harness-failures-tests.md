# Bug-fix Reproduction Tests — Harness Failures (results_full3.json)

Companion to `docs/audit/bugfix-harness-failures-triage.md`.

Scope of this session: **Bug A (#747) + Bug B (#748) only.** The Prometheus
metrics bug (triage issue #1) is deferred to its own dedicated session —
the HTTP listener rewrite is too large to fold into a test-writing sprint.

All tests below are written TDD-style: they are **red on current `main`**
(pre-fix) and are expected to flip green once the triage §7 fixes land.
Recorded output is captured from HEAD `35149ed9` (`main`, 2026-04-16).

---

## Test Plan

### Bug A — #747: QUIC `executeQueryOnConnection` missing `.on_progress` wiring

**Fix site:** `src/cli/main.zig:2411-2418` (call to `query_runner.collectQuery`
from inside the `QuicProtocolAdapter` path).  The gRPC path wires
`.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` at
`:1663/1723/1752/1771`; the QUIC path does not.  With no progress touches,
`last_progress_ns` stays pinned at the query start, and the watchdog at
`src/cli/query_deadline.zig:159-193` fires at `--timeout` seconds even while
the server is actively streaming frames back.

**Three harness tests cleared by this single fix:**

- `distributed_2pc_undo.yml::…-setup` + `…-pre`
- `gap_0183_0185_ci_distributed_traceability.yml::GAP-0183-003`
- `gap_0257_iso_conformance_verification.yml::ISO-EXPR-001`

#### A.1 Existing source-level pin (no change needed)

| Test | File | Status |
|------|------|--------|
| QUIC adapter wires `on_progress` | `tests/test_deadline_watchdog_quic_progress_followup.sh` | RED (pre-fix) — already in-repo |

Gate: `GEODE_RUN_FOLLOWUP=1` (defaults to SKIP in CI, intentionally).

Grep-based assertion: scans the `QuicProtocolAdapter` block in
`src/cli/main.zig` for the literal `on_progress`.  Flips green the moment
the fix lands; no build/run required.

Current (pre-fix) output:

```
$ GEODE_RUN_FOLLOWUP=1 ./tests/test_deadline_watchdog_quic_progress_followup.sh
FAIL: src/cli/main.zig: QuicProtocolAdapter block does NOT wire .on_progress.
      Secondary bug from #746 triage is still open.
exit=1
```

#### A.2 New runtime integration test

| Test | File | Status |
|------|------|--------|
| QUIC long-query does not false-timeout | `tests/test_quic_long_query_no_false_timeout.sh` | RED (pre-fix) — new |

**Rationale:** the source pin proves the hook is missing; this runtime
test proves the **user-visible consequence** (a real `geode` client
receives a false timeout error on a query the server is still actively
streaming).  Matches the #5 (distributed_2pc_undo / ISO-EXPR) failure mode
observed in the full-harness run.

**Setup:** start `geode serve` on a free port with
`GEODE_ADMIN_PASSWORD=GeodeTestPassword123!`.

**Baseline / smoke:** `RETURN 1 AS x --timeout 2` — must exit 0 with
`"status_class":"00000"`.  Serves as the "harness is sane" check; not
affected by the bug.

**Bug A assertion:** `RETURN range(1, 500000) AS r --timeout 5` — this
query takes ~7.4s end-to-end on the debug binary (measured 2026-04-16).
Server frames are arriving continuously throughout; post-fix the
watchdog is touched on every inbound byte and the idle-timeout never
fires.  Pre-fix the watchdog fires at exactly `--timeout` seconds with
`Error: query timed out after 5 seconds` on stderr.

**Why 500,000 not 1,000,000?** 1M reliably exceeds even a 30s timeout
and would make the outer `timeout 60s` safety net trip spuriously on
slower CI machines.  500k gives a natural ~7s wall-clock — comfortably
inside the 60s safety net but well beyond the 5s `--timeout`.

Current (pre-fix) output:

```
$ ./tests/test_quic_long_query_no_false_timeout.sh
[quic-long-query] starting geode serve on 127.0.0.1:48645
[quic-long-query] smoke: RETURN 1 AS x  --timeout 2
[quic-long-query] long: RETURN range(1, 500000) AS r  --timeout 5
[quic-long-query] long query exit=1 elapsed_ms=5078
FAIL: long query exit=1 (expected 0) after 5078ms — #747 watchdog false-timeout regression.
  stderr| Error: query timed out after 5 seconds
FAIL: long query stderr contains 'query timed out' — #747 watchdog false-timeout regression.
FAIL: long query stdout missing success marker — response was not completed.
exit=1
```

Notice `elapsed_ms=5078` — the watchdog tripped almost exactly at the
5-second `--timeout`, proving no progress touches ever happened.  Post-fix
this should report `elapsed_ms≈7500` (the natural server response time)
with exit 0.

---

### Bug B — #748: `audit verify` empty-file branch drops "records verified" phrase

**Fix site:** `src/cli/geode_audit_verify.zig:247-260`.  When `audit.jsonl`
exists but is 0 bytes, control flows past the FileNotFound branch (line 54
already emits `(0 records verified)`) and into the success-path formatter
that prints only:

```
OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100
```

The harness spec `gap_150_151_152_security_regression.yml::gap-0151-audit-verify-default-path`
asserts `stderr_contains: ["0 records verified"]`.

GitLab issue filed: **#748** (`gap, priority::low, type::bug, area::cli,
category::audit`).

| Test | File | Status |
|------|------|--------|
| `audit verify` on empty default-path file emits `records verified` | `tests/test_audit_verify_empty_file_phrase.sh` | RED (pre-fix) — new |

**Setup:** `mktemp -d` + `touch audit.jsonl` (0 bytes).  `cd` into that
dir so the default-path resolver picks up the empty file.  Invoke
`geode audit verify` (no `--file`, to exercise the default-path branch).

**Assertions:**

- `exit=0` (empty chain is not an error — the chain is trivially valid).
- stdout OR stderr contains the substring `"records verified"`.
- (Soft) the exact harness phrase `"0 records verified"` is present; emit
  a NOTE if missing but don't fail (flexibility for post-fix phrasing).

Current (pre-fix) output:

```
$ ./tests/test_audit_verify_empty_file_phrase.sh
[audit-verify-empty] invoking: /…/geode audit verify  (cwd=/tmp/geode-audit-verify-empty-HzvAn4)
[audit-verify-empty] exit=0
[audit-verify-empty] stdout:
[audit-verify-empty] stderr:
  | OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100
FAIL: output missing 'records verified' phrase — #748.
      The FNF branch at src/cli/geode_audit_verify.zig:54 emits
      '(0 records verified)'; the empty-file success branch at
      src/cli/geode_audit_verify.zig:247-260 must emit the same.
NOTE: output does not contain the exact harness-spec phrase '0 records verified'.
exit=1
```

Exit 0 is correct (so B1 passes), but the substring assertion (B2) fails
because the success formatter at `:247-260` produces `records=0` instead
of `records verified` text.

---

## Test Execution Matrix (before fix)

| Test | Kind | Status | Evidence |
|------|------|--------|----------|
| `tests/test_deadline_watchdog_quic_progress_followup.sh` (with `GEODE_RUN_FOLLOWUP=1`) | source-level grep pin | **FAIL** | `QuicProtocolAdapter block does NOT wire .on_progress` |
| `tests/test_quic_long_query_no_false_timeout.sh` | real-binary integration | **FAIL** | `Error: query timed out after 5 seconds` at 5078ms for a naturally 7.4s query |
| `tests/test_audit_verify_empty_file_phrase.sh` | real-binary integration | **FAIL** | `OK chain ✅  records=0 digests=0 …` — phrase `records verified` absent |

All three tests FAIL on current `main`.  All three flip GREEN under the
fixes proposed in `docs/audit/bugfix-harness-failures-triage.md` §7 steps
1 and 2:

1. Step 1 (audit-verify text, ≤5 min): add `(0 records verified)` or
   equivalent to the `:247-260` success formatter — flips B green.
2. Step 2 (#747 QUIC `.on_progress`, ≤30 min): add the `.hooks` field to
   the `collectQuery` call at `src/cli/main.zig:2411-2418` — flips both
   A.1 (grep) and A.2 (runtime) green; clears 3 harness failures in one
   edit (`distributed_2pc_undo` setup+pre, `gap_0183_0185` GAP-0183-003,
   `gap_0257` ISO-EXPR-001).

Prometheus (triage §7 step 3) is **out of scope** for this session and is
being tracked separately as a larger follow-up.

## Environment Notes

- Measurements taken on Linux 6.12.74+deb13+1-amd64, debug build
  (`make build`), 2026-04-16.
- `RETURN range(1, 500000) AS r` wall-clock may vary ±30% on slower CI
  machines.  If the natural query time exceeds ~10s on a given runner,
  retune `--timeout 5` → `--timeout 8` and the range endpoint accordingly
  — the assertion relies on `natural_time > timeout`, not on any
  specific number.
- All three tests use real `geode` binaries, real `geode serve` servers,
  real QUIC transport.  No mocks, no simulation — consistent with the
  project's NO MOCK DATA rule in `CLAUDE.md`.
