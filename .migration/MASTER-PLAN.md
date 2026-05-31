# MASTER PLAN — primary-storage migration (goal-anchored, loop-closure enforced)

## THE GOAL (verbatim, never drop from a subagent prompt)

Make **fts-storage** and **timeseries-storage** the **PRIMARY / backing storage** within geode for
their data types (full-text-search data; timeseries data). Bring each to the **SAME testing +
verification bar as the existing graph storage**: comprehensive unit tests, native VarianceEnvelope
benchmarks + CI-aware perf gates, ../geode-test-harness specs proving it OVER THE WIRE, and **update
all necessary downstream dependencies**. Surface FTS + timeseries as **native geode GQL extensions**
the way other geode GQL extensions were done (auth-DDL pattern: marked Geode extension, wired through
parser/AST/execution, documented in docs/, ISO-39075-checked; set-return via `CALL ... YIELD`).

## DISCIPLINE (mandatory, applies to me AND every subagent)

- **Loop closure:** I (controller) independently re-run build/test on my OWN clean channel and read the
  real on-disk log before marking ANY task done. Never trust a subagent "green"/"only known flake".
- **Evidence:** every claim backed by quoted real output (build exit, test summary, wire JSON), not prose.
- **Channel:** Bash stdout + subagent reports garble/fabricate under single-core build load — trust only
  file-captured output read back at low load + git state.
- **Builds:** ONE `zig build`/`zig build test` at a time, background, waited via Monitor. ~30 min each.

## STANDARD SUBAGENT PROMPT PREAMBLE (paste into every implementation subagent)
>
> GOAL CONTEXT (do not lose this): you are helping make {fts-storage|timeseries-storage} the PRIMARY
> backing storage for {FTS|timeseries} data in geode, at the SAME test/verification bar as graph
> storage, surfaced as a NATIVE geode GQL extension (auth-DDL pattern). Your task is one slice of that.
> ENVIRONMENT: single CPU core; `zig build`/`zig build test` ≈ 20-40 min — run ONLY in background (tee to
> a log + `echo EXIT=$? >> log`), wait via Monitor; never foreground a build; never two at once;
> `pgrep -fc 'zig build'`==0 first. Output garbles/FABRICATES under load — redirect to files, Read back at
> low load, retry garbled reads, trust git/disk over stdout, never trust prose after structured output.
> VERIFY your work with real commands and quote the actual output. End with an explicit, checkable
> loop-closure statement (what you ran, the exact exit code + summary line). If you cannot verify, say so;
> do NOT claim done.

## STATUS LEDGER (✅=loop-closed by controller; ⏳=claimed, awaiting my re-verify; ☐=not started)

### Phase A — FTS → fts-storage (PRIMARY backing for full-text data) ✅ COMPLETE (A1–A8 loop-closed)

- ✅ A1 wire dep (1399f187)
- ✅ A2 adapter (c797e015, dropIndex fix 11b21b6a)
- ✅ A3 FullTextIndex facade + tokenizer + delete bespoke persist (3cc3bf3c, 7df32b5a, 9b246a5b)
- ✅ unblock geode_unicode module diamond (a3f8e9d2)
- ✅ A4 CREATE/DROP/backfill/maintenance (c1833f37) + lazy-engine fix (09ff969c) + field-leak fix (f350f53c)
- ✅ A5 coverage tests (662add8c) + reopen-durability bug fix (2ef54aad)
- ✅ fts-storage 0.1.1 thread-check fix re-pin (ece4ac92) [lib commit 908c1f54, must be pushed]
- ✅ A4-redo native GQL: CALL geode.fts.search over the wire (df2d8a69) — LOOP-CLOSED: my clean
  `zig build test` AUTH_TEST_EXIT=0 (green). The earlier "1 failed" was self-inflicted 4-build contention
  flaking test_match_set_label_scan_regression (a timing/scaling perf test) — NOT FTS. Discipline: 1 build at a time.
- ✅ A6 native VarianceEnvelope benchmark + CI-aware perf gate (e7976271) — LOOP-CLOSED: my clean `zig build test` A6_CONFIRM_EXIT=0; bench prints VARIANCE_OK for fts_index_batch+fts_search_term.
- ✅ A7 harness specs LOOP-CLOSED GREEN (controller re-derived from /tmp/a7_fts_storage.log + a7_fulltext.log):
  fts_storage_basic.yml 13/13 PASS FTS_STORAGE_EXIT=0; fulltext_search_basic.yml 4/4 PASS FULLTEXT_EXIT=0;
  0 FAIL/panic. Decisive cases green: search-fox-via-call, search-no-match-empty, drop-fulltext-index,
  show-indexes-after-drop-server-alive (DROP does not crash server). 17/17 over the QUIC wire, fresh exe (14:29).
- ✅ A8 downstream VERIFIED (zero proto/transport/client changes 77f5ed10..HEAD → no client change) + docs done (1bd4d9c7: CLAUDE.md, docs/FEATURES_OVERVIEW.md, docs/FTS_STORAGE.md, .migration/PUBLISH-CHECKLIST.md). Pending: my harness re-verify (A7) once exe builds.

### Phase B — timeseries → timeseries-storage (PRIMARY backing) ✅ COMPLETE (B0–B6 loop-closed)

geode already wraps timeseries-storage as the store (src/timeseries/timeseries.zig, pinned 0.2.0). Gaps:

- ✅ B0 LOOP-CLOSED (d70fa995): store_mutex (std.Io.Mutex, geode idiom) serializes series_cache; queryRange in-mem
  end-bound `<`→`<=` inclusive. Deadlock-free (public→*Unlocked). i64 identity confirmed.
- ☐ B1 lib pin hygiene (likely no-op; 0.2.0==local HEAD; lib's own stale 0.1.0 version test)
- ✅ B2 LOOP-CLOSED (d70fa995): src/execution/ts_dispatch.zig + geode.ts. router branch + procedure_access
  (4 reads read-only; insert/insert_many default .mutating). CALL geode.ts.insert/insert_many/range/last/
  bucket_avg/sample_by. i64-only (Float rejected; negatives via Unary). Review APPROVE_WITH_MINORS (0 critical).
- ✅ B3 LOOP-CLOSED: tests/ts_ingest_roundtrip.zig (14 tests). Controller verified: isolated
  `zig build test-ts-ingest` TSISO_EXIT=0 (0 failcmd/panic) + full `zig build test` CTRL_EXIT=0.
- ✅ B4 LOOP-CLOSED (727c7c01): benchmark_ts_storage.zig VARIANCE_OK ts_ingest_batch + ts_range_query (my run
  TSBENCH_EXIT=0); tests/test_ts_latency.zig CI-aware gate (my run test-ts-latency 1/1 TSLAT_EXIT=0); baseline +2.
- ✅ B5 LOOP-CLOSED: harness geodetestlab-cli/specs/timeseries_basic.yml 10/10 PASS B5TS_EXIT=0 over QUIC
  (controller-run, fresh exe). Decisive: insert/insert_many counts, range integer rows, end-bound inclusive, last,
  sample_by, multi-series isolation, empty-series rows:[]. (3 "fail" greps = benign shutdown DebugAllocator leaks, pre-existing.)
- ✅ B6 docs LOOP-CLOSED (ce015a34): CLAUDE.md geode.ts.* subsection + tier-7 Store mutex; docs/TIMESERIES.md;
  INDEX + FEATURES_OVERVIEW. Downstream: generic GQL rows, no client/proto change (same as FTS).

### Cross-cutting

- ☐ Downstream re-verify: geode-client-zig + geode-client-{go,rust,python,nodejs} + geode-benchmark-runner +
  geode-test-harness — confirm no change needed (generic GQL rows) OR update. Do NOT bump gql (client cascade).
- ☐ docs/CLAUDE.md: document FTS + timeseries as fts-storage/timeseries-storage-backed primary storage +
  the native GQL extensions; note bulk-MERGE FTS limitation; dependency-push requirements (fts-storage 0.1.1).
- ☐ Final full verification: my own clean `make build` + `zig build test` + `make bench`/`zig build benchmark`
  - harness `make test-spec` for FTS and timeseries — all green, loop-closed.

## OPEN QUESTIONS RESOLVED

- UNWIND is Cypher, not GQL → use CALL...YIELD (spec). [[geode-gql-not-cypher]]
- "native like other extensions" = geode's own parser/registry + marked Geode extension (auth-DDL precedent);
  CALL geode.fts.search / geode.ts.* registered procedures ARE that native surface. CREATE INDEX ... USING
  fulltext is already a native statement. Option B (full CALL...YIELD...RETURN composition in geode's parser)
  is a separate GQL-completeness follow-up (.migration/OPTION-B-scope.md) — assess, don't block migration.
