# B-Review — `feat(ts)` commit `d70fa995` (native `geode.ts.*` GQL timeseries surface)

Read-only spec-compliance + code-quality review against `.migration/B2-design.md`
(the authoritative spec) and `src/execution/fts_dispatch.zig` (the template).
HEAD == `d70fa995`; all files read from working tree + `git show`.

Files reviewed:

- `src/execution/ts_dispatch.zig` (NEW, 371 lines)
- `src/timeseries/timeseries.zig` (B0 locking + end-bound)
- `src/execution/procedure_registry.zig` (router branch)
- `src/execution/procedure_access.zig` (read-only classification)
- `tests/ts_ingest_roundtrip.zig` (NEW, 522 lines)
- `build.zig` (test wiring)
- `docs/status.csv` (CANARY rows — not separately diffed; +2 rows per `--stat`)

---

## SPEC COMPLIANCE

### 1. Procedures present & named exactly + YIELD column names — ✅

`ts_dispatch.zig:66-72` dispatches exactly the six spec names:
`geode.ts.insert`, `geode.ts.insert_many`, `geode.ts.range`, `geode.ts.last`,
`geode.ts.bucket_avg`, `geode.ts.sample_by`. YIELD columns match the spec
(§3.1/§3.2) verbatim:

- writes → `inserted` (`ts_dispatch.zig:156` `insertedTable` dupes `"inserted"`).
- `range` → `ts`,`value` (`:237-238`).
- `last` → `ts`,`value` (`:265-266`).
- `bucket_avg` → `bucket_ts`,`avg` (`:301-302`).
- `sample_by` → `bucket_ts`,`value` (`:339-340`).

Arg order matches spec: `bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)`
(`:290-294`) and `sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)`
(`:326-331`). Both confirmed against the harness spec shape in B2-design §5 and
against the test queries (`tests/ts_ingest_roundtrip.zig:499`, `:512`).

### 2. Value type i64-only; Double rejected; negatives accepted — ✅

`literalInt` (`ts_dispatch.zig:93-106`) returns the i64 for `.Int`, recurses into
`.Unary` for `.Neg`/`.Pos`, and falls through to `error.TypeMismatch` for every
other node — so a float literal is rejected, never coerced/bitcast. Negative ints
are handled via the `.Unary{.Neg}` branch using `std.math.negate(inner) catch
return error.IntegerOverflow` (`:97-100`), which correctly rejects `negate(minInt)`
overflow instead of panicking. Test coverage: float rejected
(`tests/...:419`), i64 extremes incl. `minInt(i64)+1` and `-1` round-trip
(`:143-167`). ✅ This is BETTER than the spec skeleton (§5.3 `literalInt`), which
did NOT handle unary negation at all — the implementer correctly noticed `-1`
parses as `Unary{.Neg, Int}` and handled it.

> Note (calibrated): the exact AST tag for a float literal is matched only by the
> `else` arm, so this is robust regardless of whether geode names it
> `.DoubleLit`/`.RealLit`/`.Decimal` (the doc comment lists all three). The
> `.Int`/`.Unary`/`.String`/`.List`/`.ArrayLit` tag names are taken on faith from
> the FTS template (`fts_dispatch.zig` uses `.String`, `.Int`, `call.args`,
> `call_stmt.procedure`); ts_dispatch mirrors those exactly, so if FTS compiles,
> these do too. The only NEW tags are `.Unary`/`.List`/`.ArrayLit` — see CQ
> Important #1.

### 3. Series mapping (device_id i64, metric string) → SeriesKey via hashKey — ✅

`keyOf` (`ts_dispatch.zig:136-140`) builds `ts.SeriesKey{ .device_id =
@intCast(device_i64), .metric = ... }` and rejects negative device_id with
`error.InvalidArgs` (`:138`). No new identity scheme; `hashKey` is reused inside
the Store unchanged. The `@intCast` is guarded by the `< 0` check, so the
`i64 → u64` narrowing cannot panic. ✅ (See CQ Minor #1 on the device_id width
assumption.)

### 4. Write classification — ✅

`procedure_access.zig:74-81` adds ONLY the four read names
(`geode.ts.range/last/bucket_avg/sample_by`) to `read_only_procedure_names`, with
an explicit comment that `insert`/`insert_many` are deliberately omitted so they
default to `.mutating` (fail-closed → GPS `.write`). Matches spec §5.2 exactly.

### 5. Router — ✅

`procedure_registry.zig:40` imports `ts_dispatch`; `:206-211` adds the
`geode.ts.` `startsWith` branch immediately after the `geode.fts.` branch with the
identical call shape `ts_dispatch.execute(allocator, proc_name, call_stmt,
context)` and `null`-falls-through to UnknownProcedure. Matches spec §5.1. CANARY
present (`:204`).

### 6. B0 bug-1 (race) — ✅ (no self-deadlock found)

`store_mutex` added (`timeseries.zig:54`). Every public method that touches
`series_cache` locks via `lockHere()`/`defer unlockHere()` and delegates to a
private `*Unlocked` internal:

- `insertMany` (`:156`) locks, then calls `getOrCreateSeriesUnlocked` (`:170`) — NOT
  the locking `getOrCreateSeries`. ✅
- `last` (`:191`) → `lastUnlocked`. ✅
- `valueBefore` (`:220`) → `valueBeforeUnlocked`. ✅
- `queryRange` (`:253`) → `queryRangeUnlocked` (`:262`). ✅
- `getSeries` (`:290`) locks, then calls `getOrCreateSeriesUnlocked` (not the
  public locking one). ✅
- `getOrCreateSeries` (`:301`) is a public locking wrapper → `getOrCreateSeriesUnlocked`.
- `timeBucketAvg` (`:342`) locks, then calls `queryRangeUnlocked` (NOT `queryRange`). ✅
- `sampleBy` (`:388`) locks, then calls `queryRangeUnlocked`. ✅

**Full re-entrancy trace:** I traced every public method that holds the lock to
confirm it never calls another *locking* method while held. The only internal
fan-out is to `*Unlocked` siblings and to `hashKey` (pure, lock-free) and to
`series.points.append*` (operates on the cache entry, no lock). The durable
branches inside `lastUnlocked`/`valueBeforeUnlocked`/`queryRangeUnlocked` call the
engine (`eng.queryPoints` etc.) while holding `store_mutex` — that is correct
(serializes engine + cache together) and the engine has its own internal
serialization, a different lock, so no ordering inversion. **No self-deadlock path
exists.** CANARY/comment documents the leaf-tier ordering (`:41-53`).

### 7. B0 bug-2 (end-bound) — ✅

`timeseries.zig:283` (in-memory branch of `queryRangeUnlocked`) changed
`p.ts < end_ts` → `p.ts <= end_ts`. Doc-comment updated to "[start_ts, end_ts]
inclusive (both paths)" (`:253-259` region). Durable path already inclusive.
Tested in BOTH modes by `"ts store: queryRange in-memory == durable (boundary
inclusive)"` (`tests/...:243-299`), which inserts a point at exactly `end_ts=200`
and asserts mem and durable slices are identical and length 3.

---

## CODE QUALITY

### CRITICAL — none found

I specifically traced the two highest-risk classes the task called out:

**(A) Allocator/ownership (the FTS-crash class) — CLEAN, and notably SAFER than FTS.**
The spec (§3.2 step 3) keys on the fact that `Store.queryRange(key, s, e,
allocator)` takes the *request* allocator, so the returned `[]Point` is
request-owned — unlike the FTS facade whose slice is facade-owned and must be
freed with `facade.allocator`. The implementer did NOT blindly copy the FTS
ownership model. Instead, in every read handler it:

1. calls the Store method with the handler `allocator`,
2. copies only scalar i64s out of the returned slice into the result `Value` rows
   (by value), and
3. frees the intermediate slice with the SAME allocator via `defer allocator.free(...)`:
   - `handleRange`: `defer allocator.free(pts)` (`ts_dispatch.zig:234`).
   - `handleBucketAvg`: `defer allocator.free(out)` (`:298`).
   - `handleSampleBy`: `defer allocator.free(out)` (`:336`).

This is single-allocator throughout — there is NO cross-allocator free anywhere in
ts_dispatch, so the exact wire-crash that hit FTS cannot occur here. The result
rows hold only `Value{.Int}`/`Value{.Null}` scalars (no owned heap), and the
column names are `allocator.dupe`'d (`:155`, `:237-238`, `:265-266`, `:301-302`,
`:339-340`), so `ExecutionResult.deinit(allocator)` frees columns+rows exactly
once with the right allocator. The `insert`/`insert_many` paths allocate only the
1-row `inserted` table on `allocator` (`insertedTable` `:154-165`) — owned by the
result, freed once. `handleInsertMany` builds the point slice on a local
`ArenaAllocator` (`:197-199`) that is `defer arena.deinit()`'d after the single
`insertMany` — those points are copied into the cache by `appendSlice`, so the
arena free is correct and there is no use-after-free.

> One subtle correctness check I verified: `handleRange` does `defer
> allocator.free(pts)` AND copies `pt.ts`/`pt.value` into freshly-allocated rows
> BEFORE the defer runs (defer runs at function return, after `maybeYield`). Since
> the rows hold i64 *by value* (not pointers into `pts`), freeing `pts` after the
> copy is safe. ✅ No dangling.

> `maybeYield` (`:145-151`) takes `result` by value, reassigns via
> `filterYieldColumns`, and returns. This mirrors fts_dispatch `:136-138`. If
> `filterYieldColumns` frees the old columns/rows it replaces and returns a new
> owned result (as it does for FTS), ownership is consistent. (Calibrated: I did
> not re-read `filterYieldColumns` this pass — it is the identical call FTS makes,
> and FTS is the shipped, wire-tested reference, so the contract holds.)

**(B) Lock hygiene — CLEAN.** Every lock site uses `self.lockHere(); defer
self.unlockHere();` (`timeseries.zig:157-158`, `:192-193`, `:221-222`, `:254-255`,
`:291-292`, `:302-303`, `:343-344`, `:389-390`) — no early-return-before-unlock
path. The `std.Io.Mutex` + `global_single_threaded.io()` idiom matches the
commit's stated graph_store/schema_provider pattern (claim is plausible and
consistent with the Zig-0.16 `std.Io.Mutex` migration; the `lockUncancelable` +
`unlock` pair is the correct uncancelable acquire/release).

### IMPORTANT

**I-1. Nested-list arg survival is asserted by a test but is the one NEW,
parser-dependent path — confirm it actually parses (it does, per the test).**
`asExprList` (`ts_dispatch.zig:119-125`) accepts BOTH `.List` and `.ArrayLit`
variants, which is the right hedge given B2-design §3.1's explicit "CHECK before
implementing the list form" caveat. `handleInsertMany` (`:187-213`) validates each
inner element is a 2-element list (`:204` `if (inner.len != 2) return
error.InvalidArgs`) and that each element is an int (via `literalInt` `:205`), and
fails cleanly (`error.TypeMismatch`/`error.InvalidArgs`) on malformed input rather
than UB. The `"ts gql: insert_many nested list then range"` test (`tests/...:111`)
proves `[[100,72],[110,73],[120,74]]` survives parse→dispatch as
`Value.List`-of-`Value.List`, so the fallback path in the spec was not needed.
This is correct — flagging it only because it's the single behavior that depends on
geode's fork parser and would silently break the whole write-batch surface if a
future parser change altered nested-literal node types. No action needed now;
the test guards it.

**I-2. `insert_many` with an empty list returns `inserted = 0` and silently
no-ops — acceptable but untested.** `points_list.len == 0` flows through:
`aa.alloc(Point, 0)` → `insertMany(key, &.{})` which early-returns on
`pts.len == 0` (`timeseries.zig:156`) → `insertedTable(0)`. No crash, clean. There
is no test for the empty-batch case. Minor robustness gap; consider one assert.

**I-3. `handleInsertMany` does not reject a non-list `points` arg with a
*distinct* error — it returns `error.TypeMismatch` via `asExprList` (`:194`).**
That's correct and clean (spec §3.1 says reject non-list `points`), but the spec
suggested `error.InvalidArgs`. Cosmetic mismatch only; both are clean errors, not
crashes. No fix required.

### MINOR

**M-1. `device_id` width is assumed `u64` by the `keyOf` comment (`:135`) and the
`@intCast` (`:139`).** B2-design §2 flagged "read the field type at
`ts_lib.store.SeriesKey` and `@intCast` to it; reject out-of-range." The code
rejects negatives (good) but assumes the target is wide enough that any
non-negative i64 fits. If `SeriesKey.device_id` were ever narrower than u64
(e.g. u32), a large positive device_id would panic on the `@intCast`. The test
`"ts gql: negative device_id rejected"` covers the negative side but not an
out-of-range-positive side. Calibrated: I could not re-read `ts_lib.store.SeriesKey`
this pass (channel saturation), but the test `SeriesKey{ .device_id = 9999, ... }`
and `.device_id = 42` compile in the direct-Store tests, and the wrapper
re-exports `ts_lib.SeriesKey`, so u64 is the overwhelmingly likely width and the
identity `i64(non-neg) → u64` cast is sound. Low risk; a single large-device_id
test would close it.

**M-2. `bucket_avg`/`sample_by` Null-avg emission.** `:308` emits
`Value{ .Null = {} }` when `bucket.avg` is null, and `:346` likewise for
`sample.value`. This matches spec §3.2 (avg/value may be Null for an empty
bucket). The `sample_by`/`bucket_avg` test (`tests/...:486-521`) only asserts
non-null buckets — the Null path is implemented but NOT asserted by a test. Minor
coverage gap. (Calibrated: row field names `bucket.ts`/`bucket.avg`/`sample.ts`/
`sample.value` are taken from the handler code; they must match the wrapper's own
`timeBucketAvg`/`sampleBy` row construction — which predates this commit and is
unchanged — so they are correct by construction.)

**M-3. Doc-comment on `ts_dispatch.execute` says it ignores `context` (`_ =
context;` `:65`).** Like FTS, store resolution hardcodes the DEFAULT graph via
`eval.getTimeseriesStoreForGraph(null)` (`:130`). This is the spec-sanctioned B2
posture (§1.3 "use DEFAULT_GRAPH_NAME and the global fallback; per-graph context
plumbing is a follow-up"). Not a defect; noted for the follow-up backlog —
per-graph timeseries over the wire is not yet reachable.

**M-4. CANARY consistency — present and correct.** New CANARY markers on the
router branch (`procedure_registry.zig:204`), the read-only classification
(`procedure_access.zig:75`), and (per `--stat`) +2 rows in `docs/status.csv`.
ts_dispatch.zig itself carries a thorough module doc-comment but no inline
`CANARY:` line on each handler — FTS's `fts_dispatch.zig` also has no per-function
CANARY (its CANARY lives on the registry/access entries), so this is consistent
with the template. No action.

### Test quality assessment — STRONG, with two real-coverage notes

The tests are meaningful, not smoke-only:

- They assert concrete row VALUES, counts, and column indices (e.g. `:92-93`
  `(100,72)`; `:162-166` i64 extremes; `:505-508` computed avg `15`/`30`).
- Error-type assertions use `expectError(error.TypeMismatch, ...)` /
  `expectError(error.InvalidArgs, ...)` for float value, unknown agg, wrong arity,
  negative device_id (`:412-457`) — these would FAIL if the feature silently
  coerced or panicked, so they genuinely guard the rejection contract.
- The concurrent test (`:353-406`) is REAL: 4 threads × 250 inserts on ONE shared
  `*Store`, each thread writing both its own series and a shared series, then
  joins and asserts the shared series has exactly `n*per_thread = 1000` points AND
  is sorted. Without the `store_mutex` fix this races and would either crash
  (AutoHashMap concurrent resize) or lose points — so it actually exercises bug-1.
- The end-bound test (`:243-299`) checks the boundary point at `end_ts` in BOTH
  in-memory and durable modes and asserts the slices are identical — directly
  validating bug-2 in both paths, as the spec's case (e) required.
- Restart round-trip through the GQL seam (`:305-347`) proves durability via the
  real `executeStatementWithContext` entry, not just the Store.

Coverage gaps (none would let a broken feature pass, but worth noting):

- The Null-avg / Null-sample emission path is implemented but unasserted (M-2).
- Empty `insert_many` list (I-2) unasserted.
- The spec's case (e) "knock-on": `sample_by`/`bucket_avg` *including the boundary
  point* is implied by the shared `queryRangeUnlocked` fix but not asserted with a
  point exactly at the aggregate window's `end_ts`. The `queryRange` boundary test
  covers the shared code path, so this is low-risk.
- No test drives the `ts_dispatch` path with a durable engine for `range`
  specifically through GQL (the durable boundary test drives the Store directly,
  not the dispatcher). The dispatcher is allocator-identical for mem vs durable,
  so low-risk.

No test was found that would pass even if the feature were broken — every test
binds an assertion to a value/error the implementation must produce.

### Build wiring — correct

`build.zig:1480-1493` adds the `ts_ingest_tests` artifact (imports `geode`,
`link_libc`), a dedicated `test-ts-ingest` step, and `:2364` wires it into the
sharded `test_step`. Mirrors the FTS e2e/latency wiring exactly.

---

## OVERALL VERDICT: APPROVE_WITH_MINORS

The commit faithfully implements B2-design: all six procedures with exact
names/YIELD columns, i64-only with float rejection and correct unary-negation
handling, single-allocator ownership (no cross-allocator free — the exact FTS
wire-crash class is avoided, and the implementer correctly diverged from the FTS
ownership model because `queryRange` takes the request allocator), a deadlock-free
`*Unlocked`-internal locking scheme that I traced end-to-end, and the inclusive
end-bound fix tested in both engine modes. Tests are substantive and actually
guard both B0 fixes.

No must-fix (Critical) items. Recommended (non-blocking) follow-ups:

1. (M-1) Add one large-positive-`device_id` test (or assert `SeriesKey.device_id`
   is u64) to close the `@intCast` width assumption.
2. (M-2) Add a Null-avg / Null-sample assertion for an empty bucket.
3. (I-2) Add an empty-`insert_many`-list assertion (`inserted = 0`, no crash).
4. (I-1) Keep the `.List`/`.ArrayLit` dual-accept; it is the right hedge — no
   change, just don't regress it.

Calibration note: a small number of compile-level facts (exact AST tag names for
float literals, `BucketAvgRow`/`SampleRow` field names, `filterYieldColumns`
internal ownership) were verified indirectly — via the FTS template that ts_dispatch
mirrors, the unchanged pre-commit wrapper row-builders, and the tests that exercise
them — rather than by a fresh direct read this pass (the build saturated the result
channel during review). None of these are load-bearing for the allocator/deadlock
conclusions, which were traced directly from the committed source.
