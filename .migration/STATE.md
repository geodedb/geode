# FTS + Timeseries storage-library migration — STATE

Goal: migrate geode to back full-text-search with `fts-storage` and timeseries with
`timeseries-storage` (both `~/src/devnw/zig/`). Cut straight over. Match graph-storage
perf bar; full unit tests, native benchmarks, `../geode-test-harness` specs. /writing-plans
per phase, /subagent-driven-development for impl, /bug:fix for bugs. Update downstream
(`~/src/devnw/zig/*`, `../geode-client-zig`) as needed.

## CORRECTED scope (from discovery docs 01-08, 2026-05-30)

### Timeseries: ALREADY INTEGRATED (not greenfield)

- geode ALREADY depends on timeseries-storage: build.zig.zon `.timeseries_storage` @088e3ef/0.2.0
  (== local HEAD, so geode is already on latest). build.zig wires it as module
  `timeseries_storage_lib` at ~14 sites (582-583 + addImport 746,807,964,1029,1036,1522,1935,1939,1948,1956,3078).
- `src/timeseries/timeseries.zig:20` does `@import("timeseries_storage_lib")` — REAL consumer.
  Store wrapper: insertMany/last/valueBefore/queryRange/timeBucketAvg/sampleBy. Per-graph
  store at {graph_dir}/timeseries/. GQL TS functions name-dispatched in eval.zig (13 series + 8 array).
- bench exists: `src/benchmarks/bench_timeseries.zig` (step bench-timeseries, BLOCKING CI job).
- tests exist: tests/e2e_timeseries.zig, ts_store_integration.zig, ts_udf_parse.zig.
- GAPS for timeseries: (a) NO GQL/QUIC ingest verb — data only enters via Store.insertMany
  programmatically; harness specs (GQL-only) can't write TS data without an ingest path.
  (b) NO geode-test-harness specs for timeseries (greenfield there).
  → Timeseries work = verify build+tests green on current pin; add GQL ingest surface if needed
    for e2e; add harness specs; confirm bench matches graph-storage bar. Possibly modest.

### FTS: REPLACEMENT + NET-NEW WIRING (the big one)

- fts-storage is NOT a geode dep yet. geode FTS today = in-tree `src/index/fulltext.zig`
  (FullTextIndex: init/deinit/indexDocument/search/removeDocument/saveToDisk/loadFromDisk),
  `src/index/fulltext_persist.zig`, `src/fts/{bm25,advanced}.zig`.
- CRITICAL: FTS is NOT wired end-to-end. `CREATE INDEX … USING fulltext` (parser ok,
  ast.IndexType.fulltext) only does catalog.addIndex (execution.zig:1405 else-branch); builds
  NO inverted index. indexDocument/search have ZERO production callers (only tests). No node
  write→index hook, no query operator/CONTAINS routing reaches search(). Per-graph
  ManagedGraph.fts_index allocated at graph init (graph_storage_adapter.zig:3881) but never populated.
- fts-storage API (doc 01, VERIFIED): module `fts_storage`; `Engine.init(io: std.Io, allocator,
  base_dir: std.Io.Dir) !*Engine` (+initWithConfig{hmac_key,aead_key}); indexDocument(doc_id:u64,
  []const TermPosting); indexDocumentBatch([]DocBatch); deleteDocument(u64); flush/compact;
  TermIterator(+initWithAuth)/PhraseIterator → Match{doc_id:u64,positions:[]u32,score:f32}.
  CALLER supplies tokens (TermPosting{term,positions,field?}); geode keeps its tokenizer.
  BM25 k1=1.2/b=0.75. LSM: WAL+segments+manifest. Zero external deps. Single-writer/multi-reader.
- FTS work = add dep+module wiring (mirror timeseries: addImportToModulesByRoot), create
  src/storage/fts_storage_adapter.zig (mirror graph_storage_adapter.zig), rewire FullTextIndex
  to delegate to fts_storage.Engine keeping tokenizer + public API, DELETE fulltext_persist
  (lib owns durability), ADD the missing create/populate-on-write/query wiring, unit tests,
  benchmark, perf gate, harness specs.

## Build/integration facts (doc 03, 06, 08)

- Seam = adapter pattern. graph_storage_adapter.zig (5937L) is the template:
  ManagedGraph wraps engine + per-shard rwlocks; StorageAdapter registry; process-global in
  graph_store.zig (global_adapter, initGlobalAdapter/getGlobalAdapter). GAP-0278 mutex tiers.
- build.zig helper `addImportToModulesByRoot`. Mirror the ~14 timeseries addImport sites for fts.
- Bench: benchmarks/benchmark_<name>.zig pub fn main() emitting VarianceEnvelope JSON +
  VARIANCE_OK token; register 6-line addExecutable→bench_step.dependOn near build.zig:1004;
  CI gate `zig build benchmark` greps VARIANCE_FAIL (BLOCKING, GAP-0244). Storage template:
  benchmarks/benchmark_tde_encrypt_pages.zig. Also bench_schema.zig for compare-bench JSON.
- Perf gate (Layer C): CI-aware unit test idiom from tests/test_gap0811_aggregation_fastpath.zig:
  Harness{arena,TmpDir,data_dir,ExecutionContext}; compat_nanoTimestamp; warmup+1 timed run;
  always assert correctness; THEN `if (std.c.getenv("CI")==null) try testing.expect(elapsed_ns<BUDGET);`.
- Load test (Layer D): benchmarks/loadtest/baseline.jsonl + compare.py (advisory).

## Harness specs (doc 07)

- Dir: ../geode-test-harness/geodetestlab-cli/specs/ (root). New: fts_*.yml, timeseries_*.yml.
- ONLY enforced expect keys: exit_code, status, stdout_contains/contains, result_contains,
  stdout_regex, *_not_contains,*_exact, error_contains. row_count/values/columns/geode_query
  are IGNORED — assert via stdout_contains on JSON output. cli: block format. Run:
  `make test-spec SPEC=fts_x.yml` (set GEODE_ADMIN_PASSWORD).
- Existing FTS specs: fulltext_search_basic.yml + legacy/geode_fulltext_bm25_*.yml (may be weak
  since FTS isn't wired). No timeseries spec exists.

## Environment (VERIFIED)

- NO network git (SSH+HTTPS to gitlab fail). Build from pre-populated zig cache (~/.cache/zig/p/).
  graph_storage + timeseries_storage already cached at geode-pinned hashes. zig 0.16.0-dev.708.
- `zig fetch <local-dir>` works offline → hashes+populates cache. Use it to add fts-storage offline.
  (fts-storage commit 3f080a14; regenerate the hash via `zig fetch` — do NOT trust a hand-copied hash.)
- I CANNOT push to gitlab (no auth). fts-storage commit must be pushed by user for CI; local
  builds work offline via cache + zig fetch. Flag this in the final report.
- Only ONE geode-client-zig: ../geode-client-zig (canonical). Wire protocol is generic
  (Execute+GQL rows) → clients need NO change unless a new result encoding/RPC is added. Keep
  FTS/TS results as ordinary GQL rows. gql bump would cascade to client (it pins gql) — avoid.

## Channel hazard

- Foreground tool-output channel intermittently drops large multi-line output under load.
  Mitigation: route heavy read/build/test through background bash (file logs) + subagents/workflows
  (own channels); keep foreground reads small; never re-read the big discovery docs in foreground.

## Progress

### 2026-05-30

- ✅ Discovery (8 docs) + env feasibility verified. Corrected scope above.
- 🔄 NEXT: (0) feasibility — build geode + both libs standalone, capture baseline (background).
        (1) /writing-plans PHASE-A (FTS) + PHASE-B (timeseries completion).
        (2) /subagent-driven-development execution. (3) /bug:fix failures. (4) downstream + report.

### 2026-05-30 (cont.) — Phase A core GREEN

- A1 1399f187, A2 c797e015(+11b21b6a dropIndex fix), A3a tokenizer 3cc3bf3c, A3 facade 7df32b5a(+9b246a5b leak fix),
  unblock a3f8e9d2 (geode_unicode diamond resolved: fts_tokenizer path-imports ../unicode/geode_unicode.zig;
  isolated test-fts-tokenizer step dropped; tokenizer test re-homed into main suite via lib.zig re-exports
  `pub const fts_tokenizer`/`pub const fts_storage`).
- VERIFIED on-disk: `zig build` BUILD_EXIT=0, `zig build test` TEST_EXIT=0 (FULL suite green), binary @20:30.
  FullTextIndex now delegates to fts-storage adapter; durable; tests green incl. C1 leak-guard.
- Two-stage reviews run on A2 (caught dropIndex bug→fixed) and A3 (caught build blocker→fixed via unblock).
- NEXT: A4 end-to-end wiring (CREATE INDEX named+backfill, DROP, named getFulltextIndex, fulltext_search query fn,
  write-maintenance hook). Change-map: .migration/A4-changemap.md. Split A4a (DDL+query fn) then A4b (DML hook).

### 2026-05-31 — A4a done + REGRESSION found

- A4a DONE (commit c1833f37): CREATE/DROP fulltext index + backfill + `fulltext_search(idx,query[,max])` GQL fn
  (eval.zig evalFulltextFunction), named registry ManagedGraph.fts_facades + getFulltextIndexNamed, new
  src/execution/fts_index_ops.zig, e2e test tests/test_fts_e2e.zig. `zig build` GREEN.
- REGRESSION (A3-introduced, MINE to fix via /bug:fix): `initFtsForGraph` (graph_storage_adapter.zig:4094/4179)
  EAGERLY creates an fts-storage Engine ("default" index) for EVERY graph on create/load — but fts-storage
  Engine is single-writer with an owning-thread assert; flush()/deinit() assert caller==creating thread.
  Concurrent tests (test_simple_merge_fastpath concurrent MERGE) create/tear-down graphs across threads →
  trip the assert in adapter.deinit→engine.flush. Pre-A3 in-mem index had no such assert. ALSO wasteful
  (discovery flagged eager empty-index alloc for every graph).
  FIX (planned): make FTS engine LAZY — initFtsForGraph stops creating the "default" index+facade+Engine;
  create the adapter index only on CREATE INDEX ... USING fulltext (A4a path already does adapter.createIndex).
  The adapter (cheap registry+dir) can stay eager OR also lazy; the ENGINE (the asserting part) must not be
  created until first real FTS use. Update inline tests at gsa:5913+ (they assert mg.fts_index!=null right
  after init) to create an index first. getFulltextIndex(graph) legacy default → return null when no default
  index; fulltext_search uses getFulltextIndexNamed already.
  NOTE deeper concurrency: even lazy, a CREATE INDEX on thread A + graph teardown on thread B would still
  assert — but that's a narrow real contract; lazy fix removes it for the 99% (non-FTS) graphs incl. all
  concurrent-MERGE tests. If it persists for FTS graphs, consider adapter flushing on the owning thread or
  relaxing the engine's owning-thread capture (coordinate w/ fts-storage lib).
- Independent full `zig build test` running (b8ce3vy5b) on c1833f37 to confirm the exact failure set before fixing.
MILESTONE 2026-05-31: A4a + lazy-engine fix CONFIRMED — independent zig build test on 09ff969c = CONFIRM_EXIT=0, zero crashes. FTS reachable end-to-end via fulltext_search, durable, backfilled on CREATE INDEX, no per-graph eager engine. A4b next: DML write-maintenance hook (inline on connection thread; bulk MERGE path = post-bulk reindex, NOT per-row, to avoid fts owning-thread assert).

### 2026-05-31 — A4b committed (cfa687b9), confirm build running

- A4b: live FTS maintenance hook. graph_storage_adapter.zig +fts_label_index (label→[FtsIndexSpec]) + helpers;
  fts_index_ops.zig +maintainFulltextOnWrite(create/update/delete); hooked at crud_operations executeBatchCreateHomogeneous
  (create) + executeDelete (delete) + property_mutation.setNodePropertyFromValue (update, covers all 23 SET sites).
  update = delete-then-index (fts append-only). bulkMergeNode (worker threads) NOT hooked — uses store.setNodeProperty,
  not the hooked setNodePropertyFromValue, so owning-thread assert safe. e2e tests/test_fts_maintenance.zig (3 tests:
  create-after-index, SET delete-then-index, DELETE drops) registered in all_tests.zig.
  Agent reported TEST7_EXIT=0; my independent confirm (zig build test on cfa687b9 → /tmp/a4b_confirm.log marker
  A4B_CONFIRM_EXIT=) running. Concern flagged by agent: dedicated build.zig test-fts-maintenance step was lost in a
  stash/amend cycle (harmless — test runs via all_tests.zig). Combined A4 spec+quality review agent running.
- WHEN A4B_CONFIRM_EXIT=0 + review clean: Phase A code (A1-A4) DONE. Remaining: A5 unit-test depth, A6 bench+perf-gate,
  A7 harness specs, A8 downstream+CLAUDE.md. Then Phase B (timeseries, mostly done; add GQL ingest).

### 2026-05-31 — A4 COMPLETE (Phase A core done)

- A4 fully done + independently confirmed (A4B_CONFIRM_EXIT=0): FTS end-to-end via fts-storage —
  CREATE/DROP INDEX + backfill (fts_index_ops.zig), live maintenance on create/SET/delete
  (maintainFulltextOnWrite, label→index registry), fulltext_search(idx,query[,max]) GQL fn, lazy per-graph
  engine, leak-free. Commits: c1833f37, 09ff969c, cfa687b9, f350f53c. Combined spec+quality review done.
- TRACKED LIMITATION (for A8 CLAUDE.md + possible follow-up, NOT a blocker): bulk-MERGE fast path
  (adapter.bulkMergeNode, worker threads) does NOT FTS-index its nodes — the promised post-bulk
  connection-thread reindex is commented but unimplemented. Bulk-MERGE'd nodes won't appear in fulltext_search
  until re-indexed (e.g. DROP+CREATE INDEX, which backfills). Out of A4 scope (single-writer owning-thread
  contract). Document as a known limitation; consider a post-bulk reindex hook in a follow-up.
- Phase A remaining: A5 unit-test depth, A6 native bench (VarianceEnvelope)+CI perf gate, A7 harness specs,
  A8 downstream verify + CLAUDE.md. Then Phase B (timeseries: mostly cut over; add GQL ingest).
- All work on branch feat/storage-lib-migration; nothing pushed (no auth). fts-storage commit 3f080a1b must be
  pushed by user for CI.

### 2026-05-31 — SPEC VERIFIED + FTS query-surface decision (Option A)

- ISO PDF found at docs/kb/gql/ISO_IEC_39075_2024(en).pdf (prior agent's find missed it). VERIFIED against the
  real spec: CALL...YIELD = clause 16.2/16.3; YIELD is OPTIONAL (`<named procedure call> ::= <procedure reference>
  [<arg list>] [<yield clause>]`); NO UNWIND in GQL (keyword list 21.x); row sets MUST be a PROCEDURE not a value
  function. See .migration/GQL-SPEC-VERIFIED.md + GQL-SPEC-set-return.md + GQL-INVENTORY.md.
- KEY FINDING: geode uses its OWN parser src/gql/parser.zig (NOT the gql lib's parser) on the server/exec path.
  geode's parser accepts `CALL ns.proc(args)` (auto-projects all columns → rows, e.g. `CALL geode.schema.indexes()`
  works over the wire) but does NOT accept `CALL ... YIELD ... RETURN ...` (42601). So "update the gql library"
  does NOT fix it — the YIELD gap is in geode's parser. BUT `CALL proc(args)` WITHOUT YIELD is spec-valid (YIELD
  optional) AND already works in geode.
- DECISION (mine, per user "determine best path forward" + autonomous): OPTION A now — surface FTS as
  `CALL geode.fts.search('index','query'[, max])` returning node,score columns directly (no YIELD), matching
  geode's existing working procedure mechanism. Spec-valid (optional-YIELD form). Unblocks FTS over the wire
  immediately, low risk. OPTION B (implement `CALL...YIELD...RETURN` projection in geode's src/gql/parser.zig
  for the fuller spec form) = a separate GQL-completeness follow-up; assess its scope but do NOT block the
  migration on it.
- Handler ALREADY written (uncommitted): src/execution/fts_procedure.zig (handleFtsSearch) + registration in
  procedure_registry.zig (geode.fts.search, min2/max3, ProcedureResult{columns={node,score}, rows}; node = real
  Node Value by doc_id, fallback Int). `zig build` BUILD_EXIT=0 (compiles). Just needs: confirm A query form
  works over wire, migrate tests + harness spec from `RETURN fulltext_search(...)` to `CALL geode.fts.search(...)`,
  build+test green, commit. Then retire scalar evalFulltextFunction (eval.zig:3841) since A supersedes it.

### 2026-05-31 — USER FEEDBACK: refocus on goal + enforce loop closure

- GOAL (do not drift): fts-storage + timeseries-storage = PRIMARY storage for their types in geode, with
  SAME test+verification bar as graph storage, downstream deps updated, surfaced as NATIVE geode GQL
  extensions (auth-DDL pattern). Subagents kept losing this → bake it into every prompt + VERIFY + close loops.
- DISCIPLINE: controller independently re-verifies every "done" (re-run build/test on own clean channel, read
  real log) — do NOT trust subagent "green". Evidence-or-it-didn't-happen.
- LOOP-CLOSURE CHECK on HEAD df2d8a69 (FTS CALL geode.fts.search committed): my independent `zig build test`
  = CONFIRM_TEST_EXIT=1, Build Summary "1759/1761 passed (1 skipped, 1 FAILED)" + a shard "174 pass, 1 CRASH".
  `two_phase_edge_lock` appears 0× in my log → the subagent's claim "only the known timing flake" is FALSE/
  unverified. There is a real 1-failed + 1-crash to identify. Channel too garbled under load to parse the old
  log. Launching ONE clean authoritative `zig build test` that self-writes a parsed failure list to
  /tmp/auth_fail.txt. Until that's identified + fixed, FTS is NOT confirmed done.
- DELIVERED so far (FTS, pending the above confirmation): fts-storage primary backing (FullTextIndex facade),
  CREATE/DROP/backfill/maintenance, CALL geode.fts.search over the wire (13/13 harness per agent — re-verify),
  fts-storage 0.1.1 thread-check fix, reopen durability. STILL OWED for FTS parity: native bench+perf gate (A6,
  NOT done), confirm harness green on MY channel, downstream (client/docs). Then Phase B timeseries in full.

### 2026-05-31 — FTS df2d8a69 LOOP-CLOSED GREEN (controller-verified)

- My OWN clean `zig build test` on df2d8a69 = AUTH_TEST_EXIT=0 (no failures/crashes). FTS via CALL
  geode.fts.search over the wire is solid through A5 + reopen + 0.1.1 DROP fix.
- ROOT of the earlier false "1 failed": I overlapped 4 concurrent zig builds (load 12.3) → the
  timing-sensitive scaling test test_match_set_label_scan_regression flaked. NOT an FTS bug. RULE REINFORCED:
  exactly ONE zig build at a time, always (pgrep gate before launch).
- NEXT (one build at a time): A6 native FTS bench + CI-aware perf gate → A8 downstream+docs → Phase B (B0-B6,
  native GQL timeseries ingest/query extension + tests/bench/specs). Then cross-cutting downstream + final verify.

### 2026-05-31 — A6 verified on disk; confirm build in flight

- A6 (e7976271): benchmark_fts_storage.zig (2 scenarios, VARIANCE_OK, in bench+benchmark aggregates),
  baseline.jsonl +2 lines, tests/test_fts_latency.zig (CALL geode.fts.search timed; CI-skip `if
  std.c.getenv("CI")==null` line 158; always-on correctness asserts). All verified present + correct on disk.
- IN FLIGHT: my independent `zig build test` confirm at e7976271 → /tmp/a6_confirm.log (A6_CONFIRM_EXIT=).
  GATE LESSON: `pgrep -fc 'zig build'` FALSE-matches its own cmdline + monitor loops → ALWAYS gate real builds
  with `ps -eo args | grep -E '(^|/)zig (build|test)' | grep -v grep | wc -l` instead.
- Harness re-verify agent hit turn limit (no final) — RE-RUN after the confirm build frees the binary.
- After A6 confirm green: A7 harness re-verify (mine) → A8 downstream+docs → Phase B (timeseries native GQL
  ingest extension + tests/bench/specs). MASTER-PLAN.md has the full ledger.

### 2026-05-31 — A8 downstream evidence (controller-verified, read-only)

- `git diff --name-only 77f5ed10..HEAD` (branch base→HEAD), non-.migration files: ALL FTS-related
  (eval.zig, fts_dispatch, fts_tokenizer, fulltext, fts_storage_adapter, graph_storage_adapter,
  procedure_registry, procedure_access, crud_operations, property_mutation, index_manager, lib.zig,
  build.zig/.zon, benchmarks, tests). ZERO changes to *.proto / src/proto / src/transport / src/protocol.zig
  / any client. → CONFIRMED: FTS rides the generic GQL Execute+rows wire protocol; geode-client-zig +
  geode-client-{go,rust,python,nodejs} need NO change. gql NOT bumped (geode parser is geode's own fork;
  CALL geode.fts.search uses existing CALL machinery). No client cascade.
- A8 remaining: (1) update CLAUDE.md/docs — FTS backed by fts-storage end-to-end via CALL geode.fts.search +
  CREATE INDEX..USING fulltext; note bulk-MERGE-not-auto-indexed limitation; (2) flag deps to push: fts-storage
  0.1.1 branch feat/optional-single-writer-thread-check (commit 908c1f54) + the geode branch itself. (3) harness
  re-verify needs the SERVER exe (zig build test only builds test bins; ./zig-out/bin/geode was stale 12:55 <
  14:09 commit) → building exe now (/tmp/exe_build.log EXE_EXIT=), then run fts_storage_basic.yml +
  fulltext_search_basic.yml on MY channel.

### 2026-05-31 — A8 docs done; Phase B2 designed; awaiting exe build for A7 harness re-verify

- A8 docs committed (1bd4d9c7): CLAUDE.md FTS section + Known-Limitations bulk-MERGE note, docs/FEATURES_OVERVIEW.md,
  new docs/FTS_STORAGE.md, .migration/PUBLISH-CHECKLIST.md. A8 downstream = no client/proto change (verified).
- Phase B2 design DONE (.migration/B2-design.md): native geode.ts.* procedures mirroring FTS —
  geode.ts.insert(device,metric,ts,value) + insert_many (write, requires_write=true, {inserted} row);
  geode.ts.range/last/bucket_avg (read, YIELD rows). Store.insertMany/queryRange + resolveTimeseriesStore
  (eval.zig:3855 → getGlobalAdapter().getTimeseriesStore). Value lane i64; accept GQL Int, REJECT Float
  (live Store i64-only; PointF64 unwired) — DESIGN DECISION flagged for user. B0 fixes: (1) add cache_mu mutex
  to Store (series_cache unsynchronized, timeseries.zig:38 ~150-220); (2) queryRange in-mem end-bound `< end`
  → `<= end` inclusive to match lib (timeseries.zig:236). B3 tests, B4 latency gate, B5 harness spec.
- IN FLIGHT: geode SERVER exe build (/tmp/exe_build.log EXE_EXIT=) — needed for A7 harness re-verify (zig build
  test only built test bins; ./zig-out/bin/geode was stale). When done: run fts_storage_basic.yml +
  fulltext_search_basic.yml on MY channel + direct wire smoke of CALL geode.fts.search.
- DECISION NEEDED from user (non-blocking, will proceed with Int-only + ask): timeseries GQL value type —
  Int-only (safe, matches live Store) vs add Float lane (needs PointF64 wiring in geode + lib). Defaulting to
  Int-only; will surface.

### 2026-05-31 ~14:35 — A7 dispatched (FTS harness over-the-wire verify)

- Fresh server exe confirmed: zig-out/bin/geode mtime 14:29 > HEAD cd8118ed; `geode version` runs clean.
- Harness target: `make test-spec SPEC=<name> GEODE_BINARY=<abs>` → go test -run TestSpecs/<basename>.
  Runner spawns geode itself; pass GEODE_ADMIN_PASSWORD='GeodeTestPassword123!'.
- A7 agent running fts_storage_basic.yml + fulltext_search_basic.yml + a direct QUIC wire smoke
  (fox→2 rows, elephant→0, DROP INDEX keeps server alive, post-DROP search graceful). Report pending.
- Phase B fully designed (.migration/B2-design.md, 693 lines): geode.ts.insert/insert_many (write) +
  range/last/bucket_avg/sample_by (read) procedures mirroring fts_dispatch; value lane i64 (reject Float,
  flagged for user); B0 fixes = Store cache mutex + queryRange end-bound `<`→`<=`. Ready to drive B0→B5
  via subagent-driven-development as soon as A7 loop-closes (one build at a time — won't start a zig build
  while A7's go-test server is live).

### 2026-05-31 ~15:27 — A7 LOOP-CLOSED GREEN → PHASE A COMPLETE

- Controller re-derived from on-disk logs (NOT subagent prose):
  - /tmp/a7_fts_storage.log: 13 [PASS], `{"summary":{"total":13,"passed":13,"failed":0}}`, FTS_STORAGE_EXIT=0, 0 FAIL/panic.
  - /tmp/a7_fulltext.log: 4 [PASS], `{"summary":{"total":4,"passed":4,"failed":0}}`, FULLTEXT_EXIT=0, 0 FAIL/panic.
  - Decisive cases: fts-storage-search-fox-via-call, fts-storage-search-no-match-empty,
    fts-storage-drop-fulltext-index, fts-storage-show-indexes-after-drop-server-alive (DROP no crash). 17/17 over QUIC.
- Direct manual smoke = inconclusive (sandbox job-control SIGTTOU/PID churn, server never crashed); harness is the
  authoritative migration-bar evidence and covers the identical assertions. Acceptable.
- PHASE A (FTS→fts-storage) DONE: A1 dep, A2 adapter, A3 facade/tokenizer, A4 CREATE/DROP/backfill/maintenance,
  A5 coverage+reopen, A6 bench+latency gate, A7 harness over-the-wire, A8 downstream(no client change)+docs. All loop-closed.
- NEXT: Phase B (timeseries native GQL) via subagent-driven-development off .migration/B2-design.md, order
  B0(bugfixes+mutex) → B2(ts_dispatch+registry+access) → B3(tests) → B4(bench+gate) → B5(harness spec) → B6(docs).
  One zig build/test at a time; controller loop-closes each.

### 2026-05-31 ~17:18 — Phase B B0+B2+B3 committed (d70fa995); controller VERIFYING (build log was ambiguous)

- Commit d70fa995: ts_dispatch.zig (370L), timeseries.zig (+80 B0 locking + end-bound), procedure_registry/access
  wiring, tests/ts_ingest_roundtrip.zig (521L, 14 tests), build.zig. Pre-commit hooks passed.
- CONTROLLER FINDINGS (git over prose):
  - Implementer PROSE claimed a "CAS spinlock"; ACTUAL committed code uses `std.Io.Mutex` +
    `lockUncancelable(std.Io.Threaded.global_single_threaded.io())` — the correct geode idiom (matches
    graph_store.zig/fts_storage_adapter.zig). Lock structure deadlock-free: public methods lock then call
    `*Unlocked` internals (insertMany→getOrCreateSeriesUnlocked, queryRange→queryRangeUnlocked,
    timeBucketAvg/sampleBy→queryRangeUnlocked, getSeries→getOrCreateSeriesUnlocked). No double-lock path.
  - end-bound fix confirmed in diff: in-mem `p.ts < end_ts` → `p.ts <= end_ts`.
  - ⚠️ Implementer's /tmp/bts_phaseB.log tail shows `failed command: .../test --seed=...` THEN `EXIT=0` —
    contradictory; almost certainly a tee-pipe masking zig's real exit ($?=tee not zig). NOT accepted as green.
- ACTION: controller running OWN clean `zig build test > /tmp/bts_ctrl.log 2>&1; echo CTRL_EXIT=$?` (no pipe →
  real exit). Monitor armed. Plus a read-only spec+quality review (.migration/B-review.md) in flight.
- If CTRL_EXIT!=0 → capture failing test → /bug:fix. If 0 + review clean → loop-close B0+B2+B3, proceed B4/B5/B6.

### 2026-05-31 ~17:33 — B0+B2+B3 LOOP-CLOSED GREEN (controller-verified)

- Isolated `zig build test-ts-ingest` TSISO_EXIT=0 (0 failcmd, 0 panic) — the 14 geode.ts.* tests pass clean.
- Full `zig build test` CTRL_EXIT=0 (no pipe). The 19 "failed command:" lines = benign full-suite diagnostics
  (interleaved with passing output: OK chain ✅, compression stats, GAP perf rows, raft startup); isolated ts run = 0.
- Review (.migration/B-review.md): APPROVE_WITH_MINORS, 0 Critical/3 Important/4 Minor. Allocator ownership clean
  (queryRange uses request allocator, no cross-alloc free), lock deadlock-free, both B0 fixes confirmed+tested.
- Committed std.Io.Mutex idiom (NOT the spinlock the prose claimed — git over prose). HEAD d70fa995.
- NOTE: ./zig-out/bin/geode exe is STALE (14:29 < d70fa995 17:05) — B5 harness needs a fresh `zig build` exe.
- NEXT: B4 bench parity + CI-aware ts latency gate (mirror A6: benchmark_*.zig VarianceEnvelope + test_ts_latency.zig);
  B6 docs (parallel, no build); then refresh exe; B5 harness spec timeseries_basic.yml over the wire; final full verify.

### 2026-05-31 ~17:35 — B4 (bench+gate) + B6 (docs) dispatched in parallel

- B4: native VarianceEnvelope bench (benchmark_ts_storage.zig: ts_ingest_batch + ts_range_query) + CI-aware
  tests/test_ts_latency.zig (mirror A6 FTS) + baseline.jsonl lines + build.zig wiring. Owns the build slot; commits
  its own files (explicit paths). Mirrors benchmark_fts_storage.zig / test_fts_latency.zig.
- B6: docs (CLAUDE.md geode.ts.* subsection + new Store mutex leaf tier in lock-ordering table + i64 note;
  docs/ timeseries surface). WRITES ONLY, does NOT commit (avoids git-index race with B4); controller commits after B4.
- REMAINING after B4/B6: commit B6 docs → refresh ./zig-out/bin/geode (zig build, d70fa995>exe) → B5 harness spec
  timeseries_basic.yml over the wire → final full verify (zig build test + bench + harness FTS&ts) → downstream
  re-verify (generic rows, no client change) → flag deps to push (fts-storage 0.1.1 + branches, PUBLISH-CHECKLIST).

### 2026-05-31 ~18:17 — B4+B5+B6 LOOP-CLOSED → PHASE B COMPLETE

- B4: controller TSBENCH_EXIT=0 (VARIANCE_OK ts_ingest_batch mean=442ns cv=0.043 + ts_range_query mean=468us cv=0.099),
  test-ts-latency 1/1 TSLAT_EXIT=0. Commit 727c7c01.
- B5: timeseries_basic.yml 10/10 PASS B5TS_EXIT=0 over QUIC (fresh exe 18:14, server boots global ts store via
  setGlobalTimeseriesStore main.zig:1616 GAP-0280 → no error.Unsupported). Committed to harness repo. The 3 "fail"
  greps were benign shutdown DebugAllocator leak warnings (cli_args log_level dup + proto_reader_registry) — pre-existing,
  appear in FTS runs too, NOT test failures.
- B6: docs committed ce015a34 (geode repo).
- PHASE B DONE. REMAINING (cross-cutting): B1 pin hygiene (timeseries 0.2.0 — verify pin points at a pushed commit);
  downstream re-verify (no client/proto change — generic rows); update PUBLISH-CHECKLIST for any ts dep push; final full
  verify (one clean zig build test + both harness specs); final report to user (incl. fts-storage 0.1.1 push requirement).

### 2026-05-31 ~18:20 — B1 pin hygiene VERIFIED

- timeseries-storage pin 088e3ef0670a: PUSHED on origin/main (git branch -r --contains confirms) → CI resolves it,
  NO user action needed. (0.2.0, already integrated.)
- fts-storage pin 908c1f54 (branch feat/optional-single-writer-thread-check): NOT on any remote → USER MUST PUSH
  for CI. Already flagged in .migration/PUBLISH-CHECKLIST.md + CLAUDE.md. Local builds resolve via zig cache.
- B1 = effectively no-op for timeseries (pin clean+pushed). The only outstanding dep-push is the FTS 0.1.1 one.

### 2026-05-31 ~18:30 — FINAL full `zig build test` FINAL_EXIT=1 → FLAKE (not a regression)

- Single failure: test_two_phase_edge_lock.zig:373 "two-phase lock: 16 threads beat single-thread by >= 4x".
  Build Summary: 1775/1777 passed (1 skipped, 1 failed), panic=0.
- DIAGNOSIS = load-induced timing flake, NOT a migration regression:
  - The test is a CI-gated TIMING assertion (`if (!in_ci) expect(2*parallel <= 3*baseline)`, line 372-373) —
    parallel-within-1.5x-of-baseline. Top-of-test comment: "Only enforced off shared runners."
  - It is migration-UNTOUCHED: `git diff 77f5ed10..HEAD` = 0 lines; last change e1219da4 2026-05-24 (pre-migration).
  - I caused it: ran the build at LOAD 72 (stacked git/sentinel background tasks onto it — my "one thing at a
    time" discipline failure; load 12 already flaked a timing test earlier this project).
  - My EARLIER full `zig build test` at d70fa995 was CTRL_EXIT=0; only docs+bench/test files added since.
- RE-VERIFIED in isolation at low load (0.93, nothing else running): `zig build test-two-phase-edge-lock`
  EDGE_EXIT=0, speedup=2.67x (parallel=327ms baseline=873ms, well within 1.5x). FLAKE CONFIRMED RESOLVED.
- Authoritative state: build green (the 1 "failure" is a load flake of a pre-existing perf test), all
  migration tests pass (ts_ingest, ts_latency, fts suite), bench VARIANCE_OK, harness FTS 17/17 + ts 10/10.
- LESSON (reinforce [[fts-ts-migration-env]]): NEVER run other tasks during a build; the timing perf tests
  (test_two_phase_edge_lock, test_match_set_label_scan_regression) flake above ~load 4 on this single-core box.
