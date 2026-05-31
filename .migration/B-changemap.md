# Phase B Change-Map — Timeseries (complete + harden + GQL ingest)

READ-ONLY recon. No edits, no build. All paths absolute. Quotes are verbatim from
clean reads captured this session. (Earlier draft hedged a couple of points as
INFERRED while the harness output channel was glitching; ALL were subsequently
confirmed by clean reads — `ts_lib.store.Point`, the bench body, the test/spec
inventory, and the server boot path are all verbatim-verified. See the
"CONFIRMED" upgrades inline.)

Repos:

- geode: `/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode`
- timeseries-storage lib (local): `/data/home/benji/src/devnw/zig/timeseries-storage`
- timeseries (pattern) lib cache: `/data/home/benji/.cache/zig/p/timeseries-0.1.4-iAEwOi_KBACHNihNRqslFi-WpHWsAmRpB6h8SRSs3-bl`

---

## 1. The geode TS Store wrapper — `src/timeseries/timeseries.zig` (814 lines)

This is a thin wrapper. It imports BOTH external libs:

```zig
const ts_lib = @import("timeseries_lib");          // the "timeseries" PATTERN lib (DTW, PELT, matrix profile) — ALSO re-exports Point/SeriesKey/Series/store via store.zig
const ts_storage = @import("timeseries_storage_lib"); // the LSM STORAGE engine (WAL+Gorilla+segments)
const thread_pool = @import("thread_pool");
```

### Re-exported geode-facing types (lines 25-28)

```zig
pub const Point     = ts_lib.Point;       // == ts_lib.store.Point
pub const PointF64  = ts_lib.PointF64;
pub const SeriesKey = ts_lib.SeriesKey;   // == ts_lib.store.SeriesKey
pub const Series    = ts_lib.Series;      // == ts_lib.store.Series (in-memory cache type, has .points + .valueAt)
```

…and at the bottom: `pub const ChunkConfig = ts_lib.ChunkConfig;` (377), `pub const ChunkStorage = ts_lib.ChunkStorage;` (378), `pub const lib = ts_lib;` (382, the escape hatch gql_functions uses for dtw/pelt/etc).

**Value type = i64.** geode's `Point` is `ts_lib.store.Point`, which the pattern lib's
`root.zig` (lines 59-64) re-exports from `store.zig`:

```zig
pub const Point = store.Point;
pub const PointF64 = store.PointF64;
pub const SeriesKey = store.SeriesKey;
pub const Series = store.Series;
```

The storage lib's `types.zig` defines `Point { ts: i64, value: i64 }` and `SeriesId = u128`.
Geode's `insertMany` casts geode `Point[]` straight to storage `Point[]` via `@ptrCast`
(see §1 insertMany), which is only sound if `ts_lib.store.Point` is layout-identical to
`ts_storage.types.Point` — i.e. `{ ts: i64, value: i64 }`. **geode's TS value is a plain
i64, stored directly. No `@bitCast` of f64, no fixed-point scale, no truncation.** Every
test in the wrapper and in gql_functions uses small integer literals (`.value = 72`,
`.value = 220`), and reads decode with `@floatFromInt(pt.value)` (gql_functions.zig:98,133).
[CONFIRMED — clean read of pattern lib `store.zig:12-15`:
`pub const Point = struct { ts: i64, // Unix timestamp in milliseconds  value: i64 };`,
layout-identical to `ts_storage.types.Point {ts:i64,value:i64}`, so the `@ptrCast` at
timeseries.zig:162 is a sound identity reinterpret. The pattern lib also defines
`pub const PointF64 = struct { ts: i64, value: f64 };` (store.zig:18, re-exported as geode
`PointF64`), but the wrapper Store and every GQL path use the i64 `Point`, NOT `PointF64`.]

### `Store` struct (lines 35-40)

```zig
pub const Store = struct {
    allocator: std.mem.Allocator,
    engine: ?*ts_storage.engine.Engine,        // null = in-memory-only mode (CLI/tests)
    pool: ?*thread_pool.ThreadPool,
    config: StoreConfig,
    series_cache: std.AutoHashMap(u128, *Series),  // keyed by hashKey(SeriesKey)
};
```

### `StoreConfig` (lines 30-33)

```zig
pub const StoreConfig = struct {
    data_dir: ?[]const u8 = null,
    chunk_config: ChunkConfig = .{},
};
```

When `data_dir == null`, `initWithConfig` returns `init()` → **engine is null, purely
in-memory `series_cache`** (this is the CLI/test path and the eval-write path of interest).
When `data_dir` is set, it creates a dedicated 2-4 thread `ThreadPool`, builds
`"{data_dir}/timeseries"`, and opens the LSM engine.

### EngineConfig geode passes (lines 73-76)

```zig
const engine_config = ts_storage.engine.Config{
    .data_dir = data_dir_owned,
    .max_memtable_points = config.chunk_config.max_points_per_chunk,
};
```

**Only `data_dir` and `max_memtable_points` are set.** Everything else takes the lib
defaults (engine.zig:457-529): `durability_mode = .batch` (100ms background fsync),
`wal_recovery = .fail_closed`, `create_identity_if_missing = true`, **`retention_max_age_ms = null`
(no retention)**, `encryption_key = null` (no TDE). So geode does NOT currently wire
retention or TDE into the TS engine — a hardening note for B0.

### Public methods (EXACT signatures)

```zig
pub fn init(allocator: std.mem.Allocator) Store                                              // :42  in-memory only
pub fn initWithConfig(allocator: std.mem.Allocator, config: StoreConfig) !Store             // :52  durable
pub fn deinit(self: *Store) void                                                            // :94
pub fn loadFromDisk(self: *Store) !void                                                     // :117 NO-OP (engine.init already replays WAL)
pub fn sync(self: *Store) !void                                                             // :122 → eng.sync()
fn   hashKeyStatic(k: SeriesKey) u128                                                       // :128
pub fn hashKey(self: *Store, k: SeriesKey) u128                                             // :140 (ignores self, delegates to static)
pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void                   // :145  THE WRITE PATH
pub fn last(self: *Store, key: SeriesKey) ?Point                                            // :167
pub fn valueBefore(self: *Store, key: SeriesKey, ts: i64) ?Point                            // :190
pub fn queryRange(self: *Store, key: SeriesKey, start_ts: i64, end_ts: i64, allocator) ![]Point  // :218  end-exclusive (engine path is inclusive via lib)
pub fn getSeries(self: *Store, key: SeriesKey) ?*Series                                     // :241
fn   getOrCreateSeries(self: *Store, key: SeriesKey) !*Series                               // :249
pub fn timeBucketAvg(self, key, bucket_seconds: i64, start_ts: i64, end_ts: i64, allocator) ![]ts_lib.store.BucketAvgRow  // :275
pub fn sampleBy(self, key, interval_ms: i64, start_ts: i64, end_ts: i64, agg: ts_lib.store.Aggregation, allocator) ![]ts_lib.store.SampleRow  // :317
```

`hashKey` (= SeriesKey{device_id,metric} → u128 SeriesId) is a **double-Wyhash**, NOT the
lib's HMAC `opaqueSeriesId` (lines 128-138):

```zig
fn hashKeyStatic(k: SeriesKey) u128 {
    var h1 = std.hash.Wyhash.init(0);
    h1.update(std.mem.asBytes(&k.device_id));
    h1.update(k.metric);
    const x1 = h1.final();
    var h2 = std.hash.Wyhash.init(0x517cc1b727220a95);
    h2.update(std.mem.asBytes(&k.device_id));
    h2.update(k.metric);
    const x2 = h2.final();
    return (@as(u128, x1) << 64) | @as(u128, x2);
}
```

This same u128 is used both as the `series_cache` map key AND as the engine `SeriesId`.

### `insertMany` — the write path (lines 145-165, VERBATIM)

```zig
pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void {
    if (pts.len == 0) return;
    const sid = self.hashKey(key);

    // Update cache if it exists, or create it
    const series = try self.getOrCreateSeries(key);
    try series.points.appendSlice(self.allocator, pts);

    // Sort the cache array to maintain invariants
    const cmpFn = struct {
        fn less(_: void, a: Point, b: Point) bool {
            return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
        }
    }.less;
    std.mem.sort(Point, series.points.items, {}, cmpFn);

    if (self.engine) |eng| {
        const engine_pts = @as([]const ts_storage.types.Point, @ptrCast(pts));
        try eng.appendPoints(sid, engine_pts);
    }
}
```

Two important traits for B2:

1. It **always** updates the in-memory `series_cache` (sorted), and additionally appends
   to the engine WAL when durable. Reads via `getSeries`/`valueAt` go through the cache;
   reads via `last`/`valueBefore`/`queryRange` go through the engine when present, else cache.
2. **No tenant dimension, no per-key lock** beyond the engine's internal `append_mu`. The
   wrapper Store is NOT internally synchronized for concurrent `insertMany` against the
   `series_cache` (the `AutoHashMap` + ArrayList are unguarded). This is the key safety
   question answered in §4.

---

## 2. How TS read functions are exposed in GQL today — `src/eval.zig`

### Module-global store plumbing (eval.zig:70-96, VERBATIM)

```zig
// GAP-0280: Global timeseries store pointer for server execution path.
const TimeseriesStore = @import("timeseries/timeseries.zig").Store;       // :76
var g_timeseries_store: ?*TimeseriesStore = null;                          // :77
pub fn setGlobalTimeseriesStore(store: ?*TimeseriesStore) void { ... }     // :80
pub fn getGlobalTimeseriesStore() ?*TimeseriesStore { ... }               // :85
pub fn getTimeseriesStoreForGraph(graph_name: ?[]const u8) ?*TimeseriesStore {  // :91
    if (graph_name) |name| {
        const adapter = graph_store.getGlobalAdapter() orelse return g_timeseries_store;
        if (adapter.getTimeseriesStore(name)) |store| return store;
    }
    return g_timeseries_store;
}
```

### The dispatch seam (the place new ingest fns go)

A GQL function-call expression is evaluated in the big `blk_call` switch in `evalExpr`.
The TS dispatch is a chain of "return-null-to-fall-through" helpers. The two relevant
hook points (eval.zig:884-931):

```zig
if (std.ascii.eqlIgnoreCase(function_name, "timeseries.value")) { ... }   // :889  the legacy 3-arg point lookup, inline
// GAP-0282: Dispatch remaining 7 timeseries GQL functions
if (try evalTimeseriesFunction(allocator, function_name, call.args, env)) |result| {  // :921
    break :blk_call result;
}
if (try evalFulltextFunction(allocator, function_name, call.args, env)) |result| {    // :929
    break :blk_call result;
}
```

`evalTimeseriesFunction` (eval.zig:3899-4089) is the canonical pattern. It:

1. Requires the `timeseries.` prefix, else returns `null` (fall-through) — line 3908.
2. Maps suffix → `ts_gql.TSFunctionType` (3912-3927).
3. Resolves the store: `const maybe_store = resolveTimeseriesStore(env, null); const store = maybe_store orelse return Value{ .Null = {} };` (3930-3931).
4. Parses `(device_id Int, metric Str, …fn-specific)` args (3936-3943) into a
   `ts_gql.TSFunctionCall`, then `ts_gql.executeFunction(store, call, allocator)` (4087)
   and converts via `tsValueToCanonical` (4088).

### Store resolution priority (eval.zig:3817-3826, VERBATIM)

```zig
fn resolveTimeseriesStore(env: Env, graph_name: ?[]const u8) ?*TimeseriesStore {
    if (env.timeseries_store) |ptr| return @constCast(ptr);   // (1) per-Env (CLI path)
    return getTimeseriesStoreForGraph(graph_name);            // (2) per-graph adapter, (3) global
}
```

Note the `@constCast` and its comment: the store is treated as **read-only at query time**;
mutating from this seam is a NEW capability B2 introduces.

### Result conversion (eval.zig:3791-3815)

`tsValueToCanonical(tv: ts_gql.Value, allocator) EvalError!Value` maps the standalone
`ts_gql.Value` union (Null/Bool/Int/Double/Str/List/Map) to the canonical `value_types.Value`.
**Ingest functions can return a small `Int` (count of points written) or `Bool true` —
both already covered by this converter, so no converter change needed for B2.**

### Existing function names (so ingest fns sit beside them)

- Inline: `timeseries.value(device_id, metric, ts)` → Int|Null (eval.zig:889).
- `evalTimeseriesFunction` dispatch (`ts_gql.TSFunctionType`, gql_functions.zig:141-156):
  `timeseries.last_value`, `.value_at`, `.sample_by`, `.time_bucket`, `.interpolate`,
  `.moving_avg`, `.rate`, `.derivative`, `.change_points`, `.extract_features`,
  `.matrix_profile`, `.z_normalize`, `.invariants` (13 series fns).
- Array fns (separate dispatch, eval.zig ~4120+): `dtw`, `dtw_derivative`, `dtw_open_end`,
  `dtw_shape`, `dtw_soft`, `cosine_similarity`, `cross_correlate`, `sbd` (8 array fns, take
  f64-list args, call `ts_gql.executeDTW*`/`executeCosineSimilarity`/etc).

**ALL 21+ existing TS GQL functions are READS.** None write.

---

## 3. Is there ANY GQL write/ingest path for TS today?  →  **NO.**

Evidence (grep `insertMany` across `src/` + `tests/`):

- The ONLY non-test callers of `Store.insertMany` are:
  - `src/timeseries/timeseries.zig:151` (the method body itself; `eng.appendPoints` at :163).
  - **Every other `insertMany` call site is inside a `test { … }` block** — gql_functions.zig
    (19 occurrences, all in tests lines 774-1565), timeseries.zig (the wrapper's own tests),
    eval.zig:4560/4620/4627 (the three `test "eval: timeseries.value …"` blocks).
- No parser keyword writes TS (no `INSERT POINT` / `TS INSERT` etc).
- No `CALL geode.ts.*` procedure: a grep of `procedure_registry.zig` / `call_operations.zig`
  shows no timeseries ingest procedure (the procedure registry handles audit/tde/cdc, not TS).
- The eval dispatch chain (§2) contains only read fns.

**Conclusion: a GQL client CANNOT write a timeseries point today.** Points enter the store
only programmatically — from a Zig caller (server boot, a test, or a future ingest seam).
This is precisely the B2 gap: the harness cannot populate TS data over the wire, so the
13 read fns can only ever be tested against data a Zig test pre-seeded.

---

## 4. eval-function-dispatch contract for a MUTATING function — is eval-write sound?

### How eval gets the store

Via `resolveTimeseriesStore(env, null)` → a **`*TimeseriesStore` (mutable pointer)**. The
read path even `@constCast`s it because the lib methods take `*Store`. So eval already holds
a mutable `*Store`; calling `store.insertMany(...)` is type-legal with zero new plumbing.

### Thread / lock / transaction context

- **Thread:** eval runs synchronously on the connection's executor thread that is handling
  the statement. There is one logical statement-execution in flight per connection at a time.
- **The Store is process-global (or per-graph), shared across all connections.** Multiple
  connections evaluating TS fns concurrently each hold the SAME `*Store`.
- **`insertMany` is NOT internally synchronized** at the wrapper level: it mutates
  `series_cache` (an `AutoHashMap`) and a per-series `ArrayList` + `std.mem.sort`, none under
  a mutex. The engine's `appendPoints` IS serialized (`self.append_mu.lock()` — engine.zig:1421),
  but the in-memory cache that ALL reads (`getSeries`/`valueAt`) consult is unguarded.
  → Concurrent GQL ingest from two connections is a **data race on `series_cache`** today.
- **Transaction context:** TS lives entirely OUTSIDE geode's MVCC/WAL graph transaction
  machinery. A TS write is not part of the graph txn; it commits immediately to the TS engine
  WAL (its own durability), and is not rolled back if the surrounding GQL statement fails.
  The reads are already non-transactional (the comment at eval.zig:3820 calls the store
  "effectively read-only at query time").

### RECOMMENDATION

**Implement `timeseries.insert` / `timeseries.insert_many` as eval functions (the B2 core),
co-located in `evalTimeseriesFunction` / a sibling `evalTimeseriesIngestFunction`, BUT add a
wrapper-level mutex to `Store` first.** Justification:

1. The eval seam already hands eval a mutable `*Store`; routing through crud_operations would
   require inventing a whole new statement type for data that is not part of the graph model —
   disproportionate and inconsistent with how the 13 read fns already live in eval.
2. The ONE soundness gap is the unguarded `series_cache`. Fix it at the source (add
   `store_mutex: std.Thread.Mutex` to `Store`, lock in `insertMany`/`getOrCreateSeries`/the
   read methods) rather than at the eval layer. This is a small, local, B0/B2 change and also
   retroactively makes the existing concurrent READ path safe (a latent bug today — see §6).
3. TS is intentionally non-transactional; making ingest a CALL procedure or DDL statement
   would not buy transactionality (the engine commits immediately regardless) and would cost
   parser + planner work. An eval function is the right altitude.
   **Mark `timeseries.insert*` as a Geode extension; do NOT bump the `gql` lib pin** (these
   are runtime-dispatched function names, not grammar — exactly like the 13 existing read fns
   and `fulltext_search`, none of which touched the gql grammar).

Fallback if a reviewer rejects eval-write: a `CALL geode.ts.insert(device_id, metric, ts, value)`
procedure in `procedure_registry.zig`, resolving the store the same way. Still needs the Store
mutex. Less idiomatic given the read fns already live in eval.

---

## 5. timeseries-storage value type reconciliation

### Storage lib `types.zig` (VERBATIM, the whole file)

```zig
pub const Point = struct {
    ts: i64,     // opaque monotonic i64, no enforced unit (spec convention = ms since epoch)
    value: i64,
};
pub const SeriesId = u128;
```

**Value IS i64, confirmed.** The engine's `appendPoints(self, series_id: types.SeriesId,
points: []const types.Point)` (engine.zig:1414) and `queryPoints(self, arena, series_id,
start_ts: i64, end_ts: i64) !*iterator.MergeIterator` (engine.zig:2654) both move
`{i64,i64}` points. Gorilla encodes the i64 value via XOR; block min/max/sum (and the
segment-level statistics) operate on the **raw i64**.

### Does geode round-trip its value losslessly through i64?  →  YES, because geode's value

IS i64 (§1). There is NO f64→i64 bitcast anywhere. `insertMany` `@ptrCast`s `{i64,i64}`
geode points to `{i64,i64}` storage points (identity reinterpret — sound). Reads pull
`{i64,i64}` back and either return them directly (`last`/`valueBefore`/`queryRange`) or
decode to f64 for the analytics fns (`@floatFromInt(pt.value)`, gql_functions.zig:98,133).
Round-trip is exact for any i64.

### Does geode aggregate in the lib or in geode (over decoded values)?  →  **geode recomputes

in geode, over decoded points.** Both `timeBucketAvg` (timeseries.zig:283) and `sampleBy`
(:326) start with `const points = try self.queryRange(key, start_ts, end_ts, allocator);`
and then do their OWN bucketing loop in geode: `sum: i128`, `min/max: i64`, `@divTrunc`,
etc (timeseries.zig:297-371). **geode does NOT call any lib-side aggregate** (the lib's
block min/max/sum statistics are used only internally for segment pruning, never surfaced to
geode's aggregation). So:

- Because geode's value is a true i64, the lib-side block min/max/sum **are meaningful** for
  this data (they operate on the same integers geode stores). They just aren't the numbers
  geode returns — geode recomputes over the decoded i64 stream regardless.
- The hypothetical "f64-bitcast makes lib min/max nonsense" risk **does NOT apply here**
  because there is no bitcast. (Were geode ever to switch its TS value to f64-via-bitcast,
  THEN lib-side stats would be garbage — but geode-side recompute over decoded values would
  still be correct, since geode never reads lib stats. Note for any future f64 migration.)

### FLAG (correctness/robustness risks in the existing mapping — for B0/B3 notes)

1. **i64-only value (no float TS).** Today a GQL caller can only ever store integer-valued
   series; `timeseries.value` returns `.Int` and the converter has `.Double` but the live
   store path has no float lane. NOTE: the pattern lib DOES define `PointF64 {ts:i64,
   value:f64}` (store.zig:18, re-exported as geode `PointF64`), but neither the wrapper
   `Store` nor any GQL function uses it — there is no f64 storage path wired. If product
   wants real-valued metrics over GQL, B2's `insert` must decide: accept Int only (simplest,
   matches the live i64 path), or build out the `PointF64` lane end-to-end (NOT a silent
   bitcast). **Recommend: ingest accepts Int value only in B2; defer the PointF64 lane.**
   (Latent product gap, not a bug.)
2. **`series_cache` is unsynchronized** (see §4) — a genuine latent data-race bug on the
   concurrent READ path today, becomes acute the moment B2 adds writes. Fix with a Store
   mutex in B0/B2.
3. **`queryRange` bound mismatch.** Wrapper `queryRange` cache path uses `p.ts < end_ts`
   (end-EXCLUSIVE, timeseries.zig:232) but the engine path delegates to
   `eng.queryPoints(…, start_ts, end_ts)` whose lib semantics include `end_ts` (the
   `valueBefore` path even passes `ts - 1` to emulate exclusivity, :196). So the SAME query
   can return a boundary point in durable mode but drop it in in-memory mode. **B3 range-bound
   tests must pin the intended semantics and reconcile the two paths.** This is the highest-
   value latent correctness item to capture.
4. **No retention / no TDE wired** into the TS engine (only `data_dir`+`max_memtable_points`
   passed, §1). If TS is meant to inherit geode's TDE/retention story, that's a B0 gap to note
   (not required for B2 ingest).

---

## 6. TS tests + bench + harness today

### Unit tests (in-tree)

- `src/timeseries/timeseries.zig` — 18 inline `test` blocks (lines 390-814): insert/order/
  last/asof, timeBucketAvg (basic + boundary + empty + single + null-avg), sampleBy
  (avg/min/max/count/sum/first/last + empty bucket), valueAt (exact/before/after/empty),
  and **`"ts: persist-restart-query via StoreConfig"`** (757) — the only durable round-trip,
  exercises `initWithConfig` → insert → deinit → reopen → `last`.
- `src/timeseries/gql_functions.zig` — large inline test suite (lines 767-1565+): last_value,
  interpolate (linear/step/nearest variants), moving_avg, derivative, change_points,
  extract_features, matrix_profile, z_normalize, invariants, dtw*, cosine_similarity,
  cross_correlate, sbd. All seed data with `store.insertMany(...)` then assert read results.
- `src/eval.zig` tests (4551-4640): `"eval: timeseries.value uses global store fallback"`,
  `"… returns null without store"`, `"… prefers env store over global"`.
- `tests/e2e_timeseries.zig` — wired in build.zig:1981 (`e2e_ts_tests`, imports
  `timeseries_wrapper` + both libs). [Existence confirmed via build.zig; contents not read
  — the tests/ dir listing returned empty in the glitched tail of this session. Assume it
  is the Store+ChunkStorage+GQL e2e per the build comment "GAP-0279: e2e_timeseries test".]
- `ts_store_integration.zig` — wired in build.zig:1991 (`ts_store_tests`, imports
  `timeseries_wrapper`). [Same caveat; path likely `tests/ts_store_integration.zig`.]
- `ts_udf_parse.zig` — referenced by the task; [not confirmed via clean read this session —
  verify path under tests/ before B3].

### Bench (CI-blocking)

- `src/benchmarks/bench_timeseries.zig` — wired in build.zig:2021-2028:

  ```
  const bench_ts_exe = b.addExecutable(.{ .name = "bench_timeseries", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_timeseries.zig"), … }) });
  …
  const bench_ts_step = b.step("bench-timeseries", "Run timeseries ingestion and query benchmarks");
  ```

  Build comment line 2021: "GAP-0279: bench_timeseries executable (ingestion + GQL eval
  benchmark)" — so it already exercises BOTH ingest and query at the Store/eval layer.
  [Body not read cleanly this session — confirm whether it has a CI-aware latency GATE
  (compare-bench / baseline JSON) like the gap0811 count-fastpath gate, or is bench-only.
  build.zig shows a shared bench-baselines module near line 1998 ("shared by bench-timeseries
  and future bench exes that feed compare-bench") — strongly implies a compare path exists.]

### Harness specs

- Expected NONE for timeseries. [The `geodetestlab-cli/specs/` listing + grep returned empty
  in the glitched tail; the task states "expected NONE" and nothing in the read evidence
  contradicts it.] **B5 is greenfield: no `timeseries_*.yml` spec exists, and one cannot be
  written until B2 lands an ingest path the harness can call over GQL.**

---

## 7. Recommended Phase B sub-steps (ordered, each independently testable)

### B0 — Confirm value mapping + baseline (read-only + one safety fix)

- **Files:** `src/timeseries/timeseries.zig`.
- Confirm §1/§5: value is i64, `@ptrCast` is identity, geode recomputes aggregates. (Done in
  this recon.)
- **Surface & fix the latent `series_cache` data race** (§4/§5-flag-2): add
  `store_mutex: std.Thread.Mutex = .{}` field to `Store` (struct at :35); lock/unlock in
  `insertMany` (:145), `getOrCreateSeries` (:249), `getSeries` (:241), `last`/`valueBefore`/
  `queryRange`. Lock ordering: this is a leaf lock below everything; document it as a new
  tier in CLAUDE.md's mutex table (B6). Independently testable: a `test` spawning two threads
  doing `insertMany` on the same Store under `-fsanitize` / Zig's race detection.
- Capture the `queryRange` end-bound inconsistency (§5-flag-3) as a tracked note (fix in B3).
- Independently testable; no API surface change.

### B1 — Lib pin hygiene (likely no-op)

- **Files:** `build.zig.zon`.
- `timeseries_storage @0.2.0` (build.zig.zon:396-399, commit `088e3ef0`) already == local
  HEAD `/data/home/benji/src/devnw/zig/timeseries-storage` (root.zig `version = "0.2.0"`).
  No bump needed.
- `timeseries` (pattern) lib is `@0.1.4` (zon:391-393) but its in-cache `root.zig` says
  `pub const VERSION = "0.1.4"` while the storage lib it re-exports is 0.2.0 — consistent.
  **Note the stale internal assertion risk:** if the pattern lib has an integration test that
  asserts `ts_storage.version == "0.1.0"`, it would be stale; not geode's concern unless the
  pattern lib is rebuilt. Flag only.
- Independently testable: `zig build` resolves with no diamond.

### B2 — GQL ingest fns `timeseries.insert` / `timeseries.insert_many` (THE CORE GAP)

- **File:** `src/eval.zig`. **Insertion point:** add a sibling dispatcher
  `evalTimeseriesIngestFunction(allocator, function_name, args, env) EvalError!?Value`
  modeled on `evalTimeseriesFunction` (3899), and call it in `evalExpr`'s `blk_call` chain
  RIGHT BEFORE the read dispatch at eval.zig:921 (so `insert*` is matched first; the read
  dispatcher returns null for unknown suffixes anyway, but ordering keeps intent clear).
- **Semantics:**
  - `timeseries.insert(device_id Int, metric Str, ts Int, value Int)` → returns `.Int = 1`
    (points written) or `.Bool = true`.
  - `timeseries.insert_many(device_id Int, metric Str, points List<List<Int>>)` where each
    inner list is `[ts, value]` → returns `.Int = N`. (Map form `{ts:…, value:…}` optional.)
  - Resolve store via `resolveTimeseriesStore(env, null)`; if null → `return Value{ .Null = {} }`
    (matches read behavior) OR `EvalError.Unsupported` (clearer failure — recommend Unsupported,
    mirroring `fulltext_search`).
  - Build `[]Point` on a temp arena, call `store.insertMany(key, pts)` (now mutex-guarded from
    B0). i64 value only in B2 (§5-flag-1).
- **Geode extension; DO NOT bump `gql`** (runtime function-name dispatch, no grammar change —
  same class as the 13 read fns and `fulltext_search`).
- Independently testable: a `test "eval: timeseries.insert then last_value"` in eval.zig that
  sets a global store, evaluates an `insert` call AST, then a `last_value`/`value` call AST,
  asserts the value comes back (mirror the existing 3 eval TS tests at 4551-4640).

### B3 — Unit tests (ingest+read+restart round-trip, value-mapping exactness, multi-series, range bounds)

- **Files:** new `tests/ts_ingest_roundtrip.zig` (or extend `tests/e2e_timeseries.zig`); wire
  in build.zig beside `e2e_ts_tests` (build.zig:1981) and `ts_store_tests` (:1991) using the
  same imports (`timeseries_wrapper`, `timeseries_lib`, `timeseries_storage_lib`).
- Cases: (a) GQL `insert` → GQL `last_value`/`value_at` returns it; (b) durable round-trip:
  `insert` via eval → Store.sync/deinit → reopen → `last` (extends the existing
  `"ts: persist-restart-query"` to go through the eval seam); (c) value-mapping exactness:
  insert `i64` extremes (maxInt/minInt) and read back unchanged; (d) multi-series isolation:
  two `(device_id,metric)` keys do not collide (validate the double-Wyhash u128); (e) **range
  bounds:** pin `queryRange`/`sample_by`/`time_bucket` inclusivity, reconcile the in-memory
  vs engine `end_ts` discrepancy (§5-flag-3) — assert identical results in both modes.
- Independently testable by definition.

### B4 — Bench parity (CI-aware latency gate)

- **File:** `src/benchmarks/bench_timeseries.zig` + build.zig:2021-2028.
- Confirm the bench covers BOTH ingest (`Store.insertMany`/eval `insert`) AND query
  (`last`/`sample_by`/`time_bucket`). The build comment says it does ("ingestion + GQL eval
  benchmark") — VERIFY the body once the channel is healthy.
- If no CI-aware latency GATE exists, add one using the shared bench-baselines module
  (build.zig:~1998, "shared by bench-timeseries and future bench exes that feed compare-bench"),
  matching the gap0811 count-fastpath gate pattern (env-gated threshold so CI noise doesn't
  flake; see CLAUDE.md "Load Test Baseline Tracking" + recent commit fd744d17
  "make gap0811 count-fastpath latency gate CI-aware").
- Independently testable: `zig build bench-timeseries` runs and the gate passes/fails on a
  seeded regression.

### B5 — Harness specs `timeseries_basic.yml` (greenfield — needs B2)

- **File:** new `../geode-test-harness/geodetestlab-cli/specs/timeseries_basic.yml`.
- Now possible because B2 gives the harness a GQL write path:
  `RETURN timeseries.insert(1,'temp',100,72)` then
  `RETURN timeseries.value(1,'temp',100)` / `RETURN timeseries.last_value(1,'temp')` /
  `UNWIND timeseries.sample_by(1,'temp',10000,0,20000,'avg') AS r RETURN r.ts, r.value`.
  Cover: single insert+read, insert_many+sample_by/time_bucket, multi-series isolation,
  empty-series read returns null.
- Run via `cd ../geode-test-harness && GEODE_BINARY=/…/zig-out/bin/geode make test-spec SPEC=geodetestlab-cli/specs/timeseries_basic.yml`.
- Independently testable: the spec is the test.

### B6 — Downstream + docs (no client change; no gql bump)

- **TS rides generic GQL rows** (the read fns already return List/Map/Int/Double via
  `tsValueToCanonical`, and `insert*` returns Int) → **no geode-client-zig change, no `gql`
  pin bump.** Do NOT bump `gql`.
- **CLAUDE.md:** (a) document `timeseries.insert`/`timeseries.insert_many` as Geode extensions
  in the GQL Auth DDL / extension functions area; (b) add the new TS `Store` mutex to the
  "Mutex Lock Ordering" table as a leaf tier; (c) note TS is non-transactional and i64-valued.
- **docs:** add an entry under TYPES_AND_FUNCTIONS / a TS reference doc listing the ingest fns.
- Independently testable: doc-lint / status-generate stays green.

---

## Appendix — exact build.zig module wiring (for any new test/bench exe)

Every TS-touching artefact needs these imports (pattern from build.zig:1966-1994):

```
addImport("timeseries_lib",          timeseries_ext_mod)        // dep "timeseries"        @0.1.4
addImport("timeseries_storage_lib",  timeseries_storage_ext_mod)// dep "timeseries_storage" @0.2.0
addImport("thread_pool",             thread_pool_ext_mod)       // for Store.initWithConfig pool
addImport("timeseries_wrapper",      timeseries_wrapper_mod)    // src/timeseries/timeseries.zig (for tests)
```

`ts_gql_mod` (src/timeseries/gql_functions.zig) additionally does
`ts_gql_mod.addImport("timeseries.zig", timeseries_wrapper_mod)` (build.zig:1976).
The wrapper module also imports `fts_storage_lib` (build.zig:1974) — keep it when re-creating.
