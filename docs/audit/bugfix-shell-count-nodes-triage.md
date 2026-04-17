# Bug-fix Triage — `shell_comprehensive_tests.yml::count-nodes` timeout

**Last harness run:** 4150/4151 pass (99.98%) — `results_full4.json`.
**Only failure:** `count-nodes` — timed out at 30082.6 ms.
**Affected spec:** `geode-test-harness/geodetestlab-cli/specs/shell_comprehensive_tests.yml:633-644`.

## 1. Issues Restated

A single test (`count-nodes`) exits the harness with `"Test timed out after 30000ms"` in an otherwise fully-green run. The user's hypothesis that this is a **shell-transport** `on_progress` wiring gap analogous to `#747` needs to be tested — but the first evidence below shows the spec name is misleading and the hypothesis does not fit.

## 2. Reproduction

| What | Result |
|------|--------|
| **Spec file** `shell_comprehensive_tests.yml` — every `args:` block is `[query, --insecure, -]`. Tests invoke **`geode query`**, not `geode shell`. | → User's "shell transport" hypothesis does **not** apply. |
| Local `geodetestlab run --spec shell_comprehensive_tests.yml` 3× in isolation | 91/91 PASS each run. `count-nodes` 767–870 ms. |
| `count-nodes` duration across reports | `full2` 870ms ✓  •  `full3` 768ms ✓  •  `full4` 30082ms ✗ |
| Immediate neighbours in full4 (tests 44–50) | `create-company-nodes`→867ms ✓, `count-nodes`→30082ms ✗, `create-knows-relationships`→863ms ✓. |
| `count-aggregation` (`MATCH (p:Person) RETURN count(p)`, test 65) | full4 869ms ✓. **Labeled** `MATCH (p:Person)`. |
| Systemic full4 per-test drift | Most tests +100ms vs full3. Only `count-nodes` +29314ms (outlier). |
| Harness kill mechanism | `executor.py:597-604` — `subprocess.run(..., timeout=30)`. Python SIGKILL on the CLI at exactly 30s. Watchdog timer would have said `"Error: query timed out after 30 seconds"` in stderr; report shows harness's own wording, so the CLI child was alive-but-silent when killed. |

## 3. Root Cause Analysis

**Not `#747`-analogue.** `src/cli/main.zig:2385-2418` already wires `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` (landed in commit `eb267a68`). Both `sendClientMessage` and `readServerMessage` call `notifyProgress()`. No shell-specific transport exists — `shell_comprehensive_tests.yml` is a misnomer; it drives `geode query`.

**Actual mechanical difference** between `count-nodes` and every other MATCH-aggregation that passes:

| Test | Query | MATCH path | Runs |
|------|-------|-----------|------|
| `count-nodes` (47) | `MATCH (n) RETURN count(n)` — **no label** | `match_operations.zig:1736-1754` full-scan fallback (`store.nodes.iterator()`) → emits diagnostic `g_full_scan_count.fetchAdd` + `match_log.warn("simple node-pattern MATCH full node scan: no labels specified")` | hung 30s once in 4 runs |
| `count-relationships` (50) | `MATCH ()-[r]->() RETURN count(r)` | Edge-iteration path (different dispatch) | 665ms ✓ |
| `count-aggregation` (65) | `MATCH (p:Person) RETURN count(p)` — **labeled** | `match_operations.zig:1726-1735` label-index fast path (`store.getNodesByLabels(...)`) | 869ms ✓ |

The only time `count-nodes` breaks is the single unlabeled-fallback site at `match_operations.zig:1738-1753`. This matches the learned instinct in `memory/project_match_label_index_gap.md` which explicitly notes the fallback survives "as a safety net for 'no labels at all' queries".

**But 5 nodes cannot cause a 30s stall by themselves.** The geodetestlab `server.cleanup: true, data_dir: null` contract starts a fresh tmpdir per spec, so at test #47 the store has 5 `Person`+`Company` nodes only. The stall is not volume-driven.

**Best hypothesis (best-case evidence, flake class):** the full-scan loop at line 1740 iterates `store.nodes` while holding a read path on `store_mutex` (Tier 1). Concurrent WAL-checkpoint/audit-writer threads that want write access can park the iterator. When `count-nodes` is the first MATCH in the spec to exercise the unlabeled full-scan branch, it's also the first to take whatever non-RLS/non-tenant lock the iterator wraps. If any Tier-1 writer (e.g. WAL checkpoint, a background commit for the preceding two `create-*-nodes` statements, or the GAP-0509 tenant-filter residual at `aggregation_evaluation.zig` dead-code comment warns about) holds the lock beyond 30s, the full-scan reader hangs. Three known non-determinism sources in the server overlap this window:

1. **WAL checkpoint cadence** — first checkpoint after node creation typically lands at ~100ms; if it coincides with the full-scan acquire, it serializes behind it.
2. **Audit-log sink flush** — Tier 6 mutex, safe.
3. **Store-level `graph_handles_mutex` (Tier 0)** during `getPtr(node_id)` in the unlabeled loop — line 1731-1735 calls `store.nodes.getPtr(node_id)`; the labeled path does the same inside `getNodesByLabels` which pre-acquires ordered.

Secondary possibility: `materializeNode` is called per row (see `planned_read_runtime.zig:614` path). My local `count-nodes` run showed debug-allocator leak reports from `materializeNode/fromStorageProperty` even though the test **passed** — there's a latent memory-lifetime quirk on this exact path, and if a down-stream arena free or metadata lookup blocks on a mutex, the query can stall in the aggregator before returning. These are CLI-process leaks on happy-path exit, not a fatal defect, but they indicate the full-scan + count path is the least-covered aggregation shape.

| Issue | Root cause candidate | Type | File:line | Fix order |
|-------|----------------------|------|-----------|-----------|
| count-nodes timeout | Unlabeled `MATCH (n)` forced into full-scan fallback whose store-lock ordering vs WAL/checkpoint writer is not a guaranteed fast path | (a) logic / race — **flake class** | `src/execution/match_operations.zig:1736-1754` (primary); `src/execution/planned_read_runtime.zig:520-530,614,962` (secondary) | 1 (only one candidate) |

## 4. Dependencies Between Failures

- None — this is the last remaining failure.
- **Not** tied to `#747`: QUIC `on_progress` wiring is already present and is exercised by 4150 other passing tests.
- **Not** tied to `shell` subsystem: the spec file name mentions "shell" but zero of its tests invoke `geode shell`.

## 5. Security / Data Integrity Concerns

None. The failure is a client-side 30s timeout; no data corruption. The harness SIGKILLs the CLI only; the server continues and its `cleanup: true` hook tears down the tmp data-dir at spec end. No audit, RLS, or TDE surface is affected.

## 6. Classification

| Axis | Value |
|------|-------|
| Class | **(a) logic / race — flake** (1 hit in 4 runs locally + user's 1 hit in 1 CI run) |
| Reproducible? | **No** — 3 clean local runs in sequence post-#747 all pass `count-nodes` at 767-870ms. |
| Deterministic server bug? | **Unlikely** — all other `MATCH (n) RETURN count(n)` occurrences across 27 specs pass. |
| Single-shot flake? | **Likely** — 29s outlier against a +100ms systemic drift. |

## 7. Fix-Site Prediction (narrowest location)

**Primary candidate:** `src/execution/match_operations.zig:1736-1754` — the unlabeled-full-scan branch. A defensive **LIMIT-1 short-circuit** is not safe here (aggregation needs full scan). The correct patch direction is one of:

1. **Bypass the full node-pattern iteration entirely for `MATCH (n) RETURN count(n)`-shaped queries.** Add a "count-only pushdown" that returns `store.countNodesForGraph(filter_graph, filter_tenant)` without materializing bindings. Zero node-iteration when the aggregate only needs cardinality.
2. **Audit the store lock held during `store.nodes.iterator()` loop** at line 1740. Confirm it's strictly Tier-1 read; verify no writer holds it across WAL checkpoint + transaction commit. If a long-holder exists, narrow its critical section.

Secondary candidate: `src/execution/planned_read_runtime.zig:518-530, 614, 662, 962` — the materialization path that runs after binding. If the planner routes `count(n)` through `materializeNodeOnlyRow`, it duplicates all node properties per row, then throws them away to do `count`. Non-functional (leaks on debug allocator in my 3 local passing runs are evidence of unfinished plumbing on this exact shape).

**Practical fix-priority order** for the fixer session:

1. **Add `tests/test_match_count_unlabeled.zig`** — a deterministic regression test that creates N nodes (5, 500, 5000) and runs `MATCH (n) RETURN count(n)` under `std.time.Timer`, asserting <1s at N=5000. Prove the issue is not volume-driven in a controlled env, or catch it if it is.
2. **Implement count-only pushdown in the planner** so unlabeled `MATCH (n) RETURN count(*)` / `count(n)` skips the iteration entirely. This eliminates the flaky full-scan path for the specific query-shape that hit us.
3. **Relax the spec timeout** as a bandaid: bump `timeout_ms: 45000` on this one test case (spec line 633-644) — low confidence fix, keeps flake latent. Prefer #2 unless #2 is out of scope.

## Files / Line References (all absolute)

- `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/shell_comprehensive_tests.yml:633-644` — failing test.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/geodetestlab/lib/executor.py:590-616` — harness subprocess-kill-at-30s semantics.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/reports/results_full4.json` — failing report.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/reports/results_full3.json` — passing report (comparison).
- `/home/benji/src/devnw/codepros/geode/geode/src/execution/match_operations.zig:1736-1754` — **primary fix site** (unlabeled full-scan fallback).
- `/home/benji/src/devnw/codepros/geode/geode/src/execution/match_operations.zig:1726-1735` — the working label-index fast path (reference shape).
- `/home/benji/src/devnw/codepros/geode/geode/src/execution/planned_read_runtime.zig:518-530, 614, 662-673, 962-970` — secondary path (materialize-then-aggregate) with known debug-allocator leaks on this query shape.
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/main.zig:2385-2418` — `#747` QUIC `on_progress` wiring (already present; **not** the bug here).
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/query_deadline.zig:103-193` — watchdog (not firing; harness-kill beats it).
- `/home/benji/.claude/projects/-home-benji-src-devnw-codepros-geode-geode/memory/project_match_label_index_gap.md` — 2026-04-11 instinct that anticipated this fallback as residual risk.
