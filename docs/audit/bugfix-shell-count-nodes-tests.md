# Unlabeled MATCH(n) count-pushdown — Reproduction Tests

Failing reproduction tests for the `shell_comprehensive_tests.yml::count-nodes`
30-second flake triaged in [bugfix-shell-count-nodes-triage.md](./bugfix-shell-count-nodes-triage.md).

All three tests must FAIL on the current tree (evidence below) and must PASS
once `src/execution/match_operations.zig:1736-1754` gains a count-only
planner pushdown that delegates to `store.countNodesForGraph(filter_graph,
filter_tenant)` without iterating the node map.

## Summary Table

| # | Test | File | Category | Scope | Pre-fix outcome |
|---|------|------|----------|-------|-----------------|
| 1 | `test_count_nodes_pushdown_perf.zig` | `tests/test_count_nodes_pushdown_perf.zig` | Unit regression + perf (real `GraphStore` + `execution.executeStatementWithContext`, 20k nodes) | Primary — wall-clock floor and labeled/unlabeled ratio | **2 of 2 tests FAIL**: unlabeled took 5182.6 ms (want <50 ms); ratio 5164.9/3425.9 ms labeled (want <=5x, also hit 50 ms floor first) |
| 2 | `test_count_nodes_pushdown_audit.sh` | `tests/test_count_nodes_pushdown_audit.sh` | Source audit (grep for pushdown marker) | Pin the fix shape in `match_operations.zig` | FAIL, exit 1: no `countNodesFastPath` / `COUNT_PUSHDOWN` / `.countNodesForGraph(` marker present |
| 3 | `test_count_nodes_no_flake.sh` | `tests/test_count_nodes_no_flake.sh` | End-to-end flake pin (real `geode serve` + `geode query`, 10x hammer, optional concurrent load) | Statistical reproduction of the geodetestlab 30s flake | Quiet mode: 10/10 PASS at 764-875 ms (flake class is load-dependent, matches triage 1-in-4). `BACKGROUND_LOAD=1`: **10/10 FAIL at --timeout 5 boundary** (5062-5085 ms, RC=1) |

## Pre-fix Extraction Notes

### Why test 1 uses a wall-clock bar instead of a full-scan-counter check

`src/execution/match_operations.zig:7-10` already exposes a public diagnostic
counter `getFullScanCount()` that increments every time the unlabeled
full-scan fallback runs (line 1738). The ideal regression signal would be
"assert the counter delta is zero after the count query".

However, that symbol is not re-exported through `src/execution.zig` or
`src/lib.zig`, so the `geode` test module can't reach it. Importing
`match_operations.zig` as a second module in `build.zig` would duplicate its
file-scope atomic state (each instantiation gets its own `var g_full_scan_count`),
producing a counter that always reads zero regardless of the primary path.

The workaround — re-exporting `getFullScanCount` from `execution.zig` — is
a non-test code change, and the triage constraints for this step are
"tests only, do not fix". So test 1 substitutes a **wall-clock floor**
(50 ms against 20k nodes) plus a **labeled/unlabeled ratio** (<=5x) to get
a deterministic red-pre-fix signal from the behaviour alone. The source-shape
audit in test 2 then pins WHERE the fix must live so the fixer doesn't just
make the timing pass via an unrelated optimisation.

### Why test 3 needs BACKGROUND_LOAD to reliably go red

The triage observes the 30-second stall is a **1-in-4 flake** that only
fires when a concurrent WAL checkpoint or commit writer parks the
full-scan reader on the store mutex. A quiet localhost server running just
this one query finishes in 767-870 ms (as the triage records and as my
local runs reproduce exactly).

To make the flake reliably reproducible, `BACKGROUND_LOAD=1` spawns 8
concurrent `CREATE (:Load ...)` writers and pre-seeds 2000 bulk nodes
so the unlabeled full-scan has real work to do on each invocation. Under
that load, every single count-query trips `--timeout 5` (5062-5085 ms,
10/10 runs).

On a quiet box without `BACKGROUND_LOAD`, this test **may pass pre-fix** —
and that is the correct behaviour for a flake-pin test. A 10/10 quiet
pass doesn't disprove the bug; only a `BACKGROUND_LOAD=1` run can.
Post-fix, **both modes must stay 10/10 green** because the count-only
pushdown skips the store-mutex-held iterator entirely, so there is no
contention window for a WAL writer to park.

## Evidence — All Three Tests FAIL Before Fix

### Test 1 — Zig unit perf regression

```
$ zig build test-count-pushdown
test-count-pushdown
+- run test 0 pass, 2 fail (2 total)
error: 'test_count_nodes_pushdown_perf.test.REGRESSION: MATCH (n) RETURN count(n) completes in <50ms against 10k nodes' failed:
       count-pushdown regression: unlabeled MATCH (n) RETURN count(n) took 5257.1 ms against 20000 nodes. Expected <50 ms from O(1) pushdown to store.countNodesForGraph; full-scan fallback at match_operations.zig:1736-1754 is still being used.
error: 'test_count_nodes_pushdown_perf.test.PERF: unlabeled count MUST NOT be slower than labeled count' failed:
       count-pushdown perf regression: unlabeled MATCH (n) RETURN count(n) took 5188.6 ms (expected <50 ms from O(1) pushdown). Labeled baseline: 3447.0 ms.
Build Summary: 12/14 steps succeeded (1 failed); 0/2 tests passed (2 failed)
$ echo $?
1
```

**What the failure proves:** the unlabeled `MATCH (n) RETURN count(n)` path
allocates 20 000 `MatchBinding` structures and 20 000 hash-map entries
before the aggregator reduces them to a single `count()` and discards
them. Debug build with `std.testing.allocator` bookkeeping lands at
5182.6 ms — 100x over the 50 ms budget an O(1) pushdown should hit.
The labeled baseline (3425.9 ms) shares most of that cost because the
label-indexed path also builds a binding per node — both paths will
benefit from count-only pushdown, but the unlabeled path is the primary
flake source because it ALSO takes the store_mutex for a long-hold
iterator walk where the labeled path walks the posting list.

### Test 2 — Source-audit grep

```
$ bash tests/test_count_nodes_pushdown_audit.sh
[count-pushdown-audit] inspecting /home/benji/src/devnw/codepros/geode/geode/src/execution/match_operations.zig
FAIL: no count-pushdown marker found in match_operations.zig.
      The fix must live near the labeled fast-path at :1726-1735
      and be discoverable via one of:
        - a function named countNodesFastPath (or countNodeFastPath)
        - a comment containing COUNT_PUSHDOWN / 'count pushdown' / 'count-only pushdown'
        - a call to store.countNodesForGraph(...)
      Triage: docs/audit/bugfix-shell-count-nodes-triage.md
$ echo $?
1
```

**What the failure proves:** no pushdown helper, comment marker, or
`countNodesForGraph` call exists in `match_operations.zig`. Locks the fix
shape so a purely-timing-based patch in a different file can't silently
satisfy test 1 without also committing to the maintainable site next to
the labeled fast-path.

### Test 3 — End-to-end flake pin (with load)

```
$ BACKGROUND_LOAD=1 bash tests/test_count_nodes_no_flake.sh
[count-nodes-flake-pin] starting geode serve on 127.0.0.1:36349
[count-nodes-flake-pin] server listening; issuing a fresh auth/seed
[count-nodes-flake-pin] BACKGROUND_LOAD=1: spawning 8 concurrent writers
[count-nodes-flake-pin] bulk-seeding 2000 nodes to simulate cumulative harness state
[count-nodes-flake-pin] seeded 5 nodes; hammering count query 10x
[count-nodes-flake-pin] run 1/10: 5067ms RC=1 SLOW(5067ms>3000ms)
[count-nodes-flake-pin] run 2/10: 5071ms RC=1 SLOW(5071ms>3000ms)
[count-nodes-flake-pin] run 3/10: 5070ms RC=1 SLOW(5070ms>3000ms)
[count-nodes-flake-pin] run 4/10: 5062ms RC=1 SLOW(5062ms>3000ms)
[count-nodes-flake-pin] run 5/10: 5069ms RC=1 SLOW(5069ms>3000ms)
[count-nodes-flake-pin] run 6/10: 5085ms RC=1 SLOW(5085ms>3000ms)
[count-nodes-flake-pin] run 7/10: 5076ms RC=1 SLOW(5076ms>3000ms)
[count-nodes-flake-pin] run 8/10: 5066ms RC=1 SLOW(5066ms>3000ms)
[count-nodes-flake-pin] run 9/10: 5066ms RC=1 SLOW(5066ms>3000ms)
[count-nodes-flake-pin] run 10/10: 5067ms RC=1 SLOW(5067ms>3000ms)
[count-nodes-flake-pin] summary: min=5062ms max=5085ms across 10 runs
FAIL: at least one of 10 consecutive count(n) runs exceeded 3000ms or errored.
$ echo $?
1
```

**What the failure proves:** under WAL/writer contention every single
unlabeled `MATCH (n) RETURN count(n)` exceeds the client's `--timeout 5`
budget and returns RC=1, because the full-scan iterator at
`match_operations.zig:1740` is held behind concurrent writers. This is the
exact flake class that produces the geodetestlab 30s SIGKILL on the
`count-nodes` test — just reproduced on a 5s budget for test speed.

Quiet-mode reference (no background load): 10/10 PASS at 764-875 ms. The
flake IS load-dependent, which matches the triage's 1-in-4 observation.

## Build Wiring

`build.zig` gained one new module wired into `test_step`:

```zig
// Unlabeled MATCH(n) count-pushdown regression.
const count_pushdown_test_mod = b.createModule(...);
count_pushdown_test_mod.addImport("geode", root_mod);
const count_pushdown_tests = b.addTest(...);
const run_count_pushdown_tests = b.addRunArtifact(count_pushdown_tests);
test_step.dependOn(&run_count_pushdown_tests.step);
const count_pushdown_step = b.step("test-count-pushdown", "...");
count_pushdown_step.dependOn(&run_count_pushdown_tests.step);
```

Shell tests 2 and 3 are stand-alone `bash` scripts run via `make` targets
or direct invocation; they do not plug into `zig build test` so they
don't block CI-on-every-commit.

## Files (absolute paths)

- `/home/benji/src/devnw/codepros/geode/geode/tests/test_count_nodes_pushdown_perf.zig` — Zig unit regression + perf (test 1).
- `/home/benji/src/devnw/codepros/geode/geode/tests/test_count_nodes_pushdown_audit.sh` — source-shape audit (test 2).
- `/home/benji/src/devnw/codepros/geode/geode/tests/test_count_nodes_no_flake.sh` — end-to-end flake pin (test 3).
- `/home/benji/src/devnw/codepros/geode/geode/build.zig:2692-2698` — `test-count-pushdown` step wiring.
- `/home/benji/src/devnw/codepros/geode/geode/docs/audit/bugfix-shell-count-nodes-triage.md` — triage report.
