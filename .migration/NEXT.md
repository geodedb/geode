# NEXT ACTIONS (resume point)

Branch feat/storage-lib-migration @ c1833f37. geode `zig build` GREEN.

## WAITING ON

- Authoritative `zig build test` (background, summary → /tmp/auth_test_summary.txt, marker TEST_EXIT=).
  Launched clean on c1833f37 with nothing else running. Earlier b8ce3vy5b run was RACY (ran while A4a
  agent mid-edited build.zig → bogus 'fts_smoke_tests' graph error) — DISREGARD /tmp/a4a_fulltest.log.
- When it completes + load drops: read /tmp/auth_test_summary.txt (small, clean) for the EXACT failing set.

## CHANNEL HAZARD (active)

Under high load (full build on 1 core) the tool-output channel GARBLES and FABRICATES plausible prose
appended to command output. Do NOT trust Bash stdout or even Read output while a build runs. Only act on
output captured to a file AND read back when load < ~2. Prefer the Read tool on small files when idle.

## IMMEDIATE NEXT: /bug:fix the FTS eager-init regression (A3-introduced)

ROOT CAUSE (confirmed by reading graph_storage_adapter.zig): `initFtsForGraph` (called at :4094 create,
:4179 load) EAGERLY builds an fts-storage Engine ("default" index) for EVERY graph. fts-storage Engine is
single-writer with an owning-thread assert captured at init; flush()/deinit() assert caller==owning thread.
Concurrent tests (test_simple_merge_fastpath "concurrent MERGE") create/tear-down graphs across threads →
trip the assert in ManagedGraph.deinit → fts_adapter.deinit → engine.flush. Pre-A3 in-mem index had no assert.
FIX: make the fts-storage ENGINE lazy. initFtsForGraph should NOT create the "default" index/facade/Engine.
Options:
 (A) Don't create the adapter at all until first CREATE INDEX; ManagedGraph.fts_adapter stays null; CREATE
     INDEX path lazily builds the adapter+dir then the named index. getFulltextIndex(graph) returns null when
     no default. Update inline tests gsa:5913+ to CREATE an index first.
 (B) Keep the adapter (cheap registry+dir, no Engine) eager but defer Engine creation to createIndex/openIndex.
     Check fts_storage_adapter: does FtsStorageAdapter.init create any Engine? (No — only createIndex/openIndex
     do.) If adapter.init is Engine-free, the regression is ONLY the eager createIndex("default") at gsa:4022-4039.
     Then the minimal fix = STOP creating the default index+facade in initFtsForGraph; keep adapter+base_dir.
     This is the smallest change. VERIFY adapter.init is Engine-free before choosing.
DEEPER (may still bite FTS graphs under cross-thread create/teardown): the owning-thread assert is in
fts-storage engine.zig (flush/deinit). If lazy-init doesn't fully clear it for FTS-using concurrent graphs,
options: ensure adapter create+deinit happen on one thread, OR relax fts-storage's owning-thread capture
(downstream lib edit — user authorized). Read fts-storage src/engine.zig assertOwner/flush/deinit when idle.
PROCESS: use /bug:fix (triage→repro test→fix→verify) on this. Repro = a test that creates a graph on one
thread and deinits via the registry on another, or just run test_simple_merge_fastpath.

## THEN: A4b — node write-maintenance hook (DML)

Per .migration/A4-changemap.md: hook executeCreate / setNodeProperty / executeDelete in
src/execution/crud_operations.zig. On node create/update/delete, if any fulltext index covers the node's
label+property, tokenize new value → adapter.indexNode (UPDATE must deleteNode-then-indexNode: fts indexDocument
is append-only, NOT replace) or deleteNode (delete). CHEAP guard: O(1) "does any fulltext index cover this
label" check (per-graph label-keyed set; the index_manager records / catalog are name-keyed — may need a
label→indexname map). Then e2e test: create index, THEN insert nodes (not backfill), search finds them; update
a node, search reflects; delete, search drops it.

## THEN: A5 unit tests, A6 bench+perf-gate, A7 harness specs, A8 downstream+CLAUDE.md

## THEN: Phase B (timeseries) — B0..B6 per .migration/plans/PHASE-B-timeseries.md (mostly done; add GQL ingest)

## Commits so far (Phase A): 1399f187 A1, c797e015+11b21b6a A2, 3cc3bf3c A3a, 7df32b5a+9b246a5b A3

## a3f8e9d2 unblock(geode_unicode diamond), c1833f37 A4a

## 2026-05-31 — FTS lazy fix committed (09ff969c); awaiting independent confirm

- Fix landed: initFtsForGraph builds only the engine-free adapter+base_dir; FtsInitResult.index now ?*; no eager
  "default" index/engine; default_fts_index_name removed (0 refs); inline tests create index explicitly.
- Fixer's own final run /tmp/ft2.log = DONE_TEST_EXIT=0 (clean). /tmp/bugfix_test.log is a STALE earlier run
  (2 fails = its own pre-fix inline asserts) — DISREGARD. My independent confirm: background bxjc6qo8r →
  /tmp/confirm_test.log marker CONFIRM_EXIT=, monitor bfhf7sn8l. Trust ONLY confirm_test.log.
- When CONFIRM_EXIT=0 + concurrent-MERGE passes + no FTS regression: A4a+regression COMPLETE. Then:

## REMAINING PHASE A

- A4b: node write-maintenance hook (DML). crud_operations.zig executeCreate(~1691)/setNodeProperty/executeDelete(~2545).
  On create/update/delete, if a fulltext index covers node's label+prop → tokenize→adapter.indexNode (UPDATE =
  deleteNode THEN indexNode, fts is append-only) / deleteNode. CHEAP O(1) guard "does any fulltext index cover
  this label": need a per-graph label→[index] map (catalog/index_manager records are name-keyed; build a small
  label-keyed lookup populated on CREATE/DROP INDEX). e2e: create index, INSERT nodes after, search finds; update
  reflects; delete drops. NOTE: A4b writes happen on the connection thread; CREATE INDEX (engine create) also on
  connection thread → owning-thread consistent for normal serving. Watch concurrent-bulk paths (the merge fastpath
  uses worker threads for graph data, but FTS indexNode would run from the executor thread — verify which thread
  calls indexNode under bulk MERGE before declaring safe; if bulk path calls FTS maintenance from a worker, the
  owning-thread assert returns — may need the adapter to (a) be created lazily on the SAME thread that first writes,
  or (b) coordinate. Defer worrying until A4b repro.)
- A5: comprehensive FTS unit tests (ranking, phrase, delete, reopen-durability, multi-index, multi-property,
  edge cases, backfill). A6: benchmarks/benchmark_fts_storage.zig (VarianceEnvelope + VARIANCE_OK token, register
  near build.zig:1004 in `bench` aggregate; add baseline.jsonl line) + CI-aware latency gate (gap0811 idiom,
  tests/test_fts_latency.zig, `if (std.c.getenv("CI")==null) try testing.expect(elapsed_ns<BUDGET);`). A7:
  ../geode-test-harness/geodetestlab-cli/specs/fts_*.yml (cli: block; stdout_contains asserts; GEODE_ADMIN_PASSWORD).
  A8: downstream (confirm no client/wire change; FTS rides generic GQL rows; do NOT bump gql) + CLAUDE.md.

## PHASE B (timeseries) — mostly cut over already; see .migration/plans/PHASE-B-timeseries.md

- B0 confirm value i64-vs-f64 mapping + baseline; B2 GQL ingest fn ts_insert/ts_insert_many (eval.zig beside the
  13 read fns); B3 tests; B4 bench parity; B5 harness specs; B6 downstream+CLAUDE.md. timeseries-storage already
  pinned 0.2.0==local HEAD, wired via timeseries_storage_lib, consumed src/timeseries/timeseries.zig.

## DOWNSTREAM PUSH (user action, I can't push): fts-storage commit 3f080a1b must be pushed to gitlab for CI

   geode build.zig.zon .fts_storage url pins it; local builds work offline via cache. Flag in final report.
