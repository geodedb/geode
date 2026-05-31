# B2 Design — Native GQL Timeseries Surface (`geode.ts.*` procedures)

Implementation-ready plan for surfacing **timeseries-storage** as a first-class
geode GQL extension, the exact analog of the FTS work (`CALL geode.fts.search(...)
YIELD …` via a `src/execution/fts_dispatch.zig` handler + a `geode.fts.` router
branch + a `procedure_access` read-only classification). This document is the
DESIGN for an implementer; it makes no edits and prescribes none beyond what is
quoted with file:line evidence.

> Sources (verbatim reads this session): `.migration/B-changemap.md` (timeseries
> recon), `.migration/GQL-INVENTORY.md` (CALL/YIELD router + FTS delta),
> `.migration/GQL-SPEC-VERIFIED.md` (ISO/IEC 39075 BNF), and the shipped
> `src/execution/fts_dispatch.zig` (read in full — the template). Where the result
> channel was stalled and I could not re-open `procedure_access.zig` /
> `discovery/02-timeseries-storage-api.md`, the load-bearing facts are the ones
> already quoted verbatim in GQL-INVENTORY §B.1 (router + `classifyProcedureName`
> contract) and B-changemap §1/§5 (Store signatures, value mapping, the two bugs).
> Any line numbers below tagged `[recon]` come from those verbatim recon quotes;
> tag `[fts]` = read directly from `fts_dispatch.zig` this session.

---

## 0. Decision summary (the headline answers)

| Question | Decision |
|---|---|
| **Surface shape** | **`CALL geode.ts.*` procedures** (NOT eval functions). Mirror FTS exactly. The B-changemap recommended eval-functions as primary with CALL-procedures as fallback; **this design promotes the CALL-procedure path to PRIMARY** because the GOAL is "native geode GQL extension exactly the way FTS was just done", and FTS is a procedure. ISO-GQL exposes a row set ONLY through `CALL … YIELD` (GQL-SPEC-VERIFIED Claim 2/3). |
| **Write surface** | `CALL geode.ts.insert(device_id, metric, ts, value)` and `CALL geode.ts.insert_many(device_id, metric, points)`. `requires_write = true` (mutating classification). |
| **Read surface** | `CALL geode.ts.range(device_id, metric, start_ts, end_ts) YIELD ts, value` (the row-returning analog of `fts.search`). Plus `geode.ts.last`, `geode.ts.bucket_avg`, `geode.ts.sample_by`. `requires_write = false`. The 13 existing scalar `timeseries.*` eval FUNCTIONS stay as-is (scalar aggregates remain functions; row-returning queries become procedures — the recommended split). |
| **Value type** | **i64 only in B2.** GQL `Int` maps to storage `i64` losslessly (identity). GQL `Double` is REJECTED with `error.TypeMismatch` (no silent bitcast/scale). PointF64 lane deferred — flagged as a follow-up product decision. |
| **Series identity** | `(device_id: Int, metric: String)` pair, mapped to the existing `SeriesKey{device_id, metric}` → `hashKey` u128 SeriesId. Reuses the existing wrapper mapping verbatim; no new identity scheme. |
| **B0 bug 1** | `Store.series_cache` is unsynchronized → data race once concurrent GQL writes land. Add `store_mutex: std.Thread.Mutex` to `Store` and guard cache access. `src/timeseries/timeseries.zig:35` (struct), `:145/:167/:190/:218/:241/:249` (methods). |
| **B0 bug 2** | `queryRange` end-bound: in-memory cache path is end-EXCLUSIVE (`p.ts < end_ts`, `timeseries.zig:232`) while the durable engine path is INCLUSIVE (`eng.queryPoints(…, start_ts, end_ts)`). Make in-memory path INCLUSIVE (`p.ts <= end_ts`) to match the lib. |

---

## 1. The geode TS Store API (write + read + resolver) — `src/timeseries/timeseries.zig`

### 1.1 WRITE method (the single write path)

```zig
pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void   // :145
```

- `key: SeriesKey` = `struct { device_id: <int>, metric: []const u8 }` (re-exported
  `ts_lib.store.SeriesKey`, B-changemap §1).
- `pts: []const Point` where `Point = struct { ts: i64, value: i64 }` (storage-lib
  `types.zig`, layout-identical; the `@ptrCast` at `:148` is an identity reinterpret).
- Always updates the in-memory `series_cache` (append + `std.mem.sort` by `(ts,
  value)`), and additionally `eng.appendPoints(sid, …)` when durable
  (`self.engine != null`). Single-point insert = `insertMany(key, &.{point})`.

There is no separate single-point write method — **`geode.ts.insert` builds a
1-element slice and calls `insertMany`.** This keeps one write path (cache + WAL).

### 1.2 READ methods (signatures + return types)

```zig
pub fn last(self: *Store, key: SeriesKey) ?Point                                            // :167
pub fn valueBefore(self: *Store, key: SeriesKey, ts: i64) ?Point                            // :190
pub fn queryRange(self: *Store, key: SeriesKey, start_ts: i64, end_ts: i64, allocator) ![]Point  // :218
pub fn timeBucketAvg(self, key, bucket_seconds: i64, start_ts: i64, end_ts: i64, allocator) ![]ts_lib.store.BucketAvgRow  // :275
pub fn sampleBy(self, key, interval_ms: i64, start_ts: i64, end_ts: i64, agg: ts_lib.store.Aggregation, allocator) ![]ts_lib.store.SampleRow  // :317
```

- `Point{ ts:i64, value:i64 }`. `BucketAvgRow` / `SampleRow` are `ts_lib.store`
  row structs (fields include bucket start ts + an aggregated value; the geode-side
  loop recomputes `sum:i128`/`min`/`max`/`@divTrunc` over decoded points,
  B-changemap §5).
- `ts_lib.store.Aggregation` is the agg enum (`avg/min/max/count/sum/first/last`
  per the existing `sampleBy` tests, B-changemap §6).

### 1.3 Per-graph Store resolver (quote)

The eval read path resolves the store via (B-changemap §2, eval.zig:3817-3826 VERBATIM):

```zig
fn resolveTimeseriesStore(env: Env, graph_name: ?[]const u8) ?*TimeseriesStore {
    if (env.timeseries_store) |ptr| return @constCast(ptr);   // (1) per-Env (CLI path)
    return getTimeseriesStoreForGraph(graph_name);            // (2) per-graph adapter, (3) global
}
```

and (eval.zig:91 VERBATIM):

```zig
pub fn getTimeseriesStoreForGraph(graph_name: ?[]const u8) ?*TimeseriesStore {
    if (graph_name) |name| {
        const adapter = graph_store.getGlobalAdapter() orelse return g_timeseries_store;
        if (adapter.getTimeseriesStore(name)) |store| return store;
    }
    return g_timeseries_store;
}
```

**The procedure handler does NOT have an `Env`** (the dispatch contract takes
`ExecutionContext`, not `Env` — see fts_dispatch). It must therefore resolve the
store the same way `getTimeseriesStoreForGraph` does, going straight through the
adapter / global pointer. Mirror exactly what `fts_dispatch` does for the FTS
facade ([fts] `fts_dispatch.zig:95-97`):

```zig
const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
const store = adapter.getTimeseriesStore(graph_store.DEFAULT_GRAPH_NAME) orelse return error.Unsupported;
```

Resolution priority for the handler: if `ExecutionContext` carries a graph name
(check the field the FTS path / other dispatchers read; FTS hardcodes
`DEFAULT_GRAPH_NAME`), use `adapter.getTimeseriesStore(graph)`; else fall back to
`eval.getGlobalTimeseriesStore()`. To match FTS precisely and avoid a new context
dependency in B2, **use `DEFAULT_GRAPH_NAME` and the global fallback**; per-graph
context plumbing is a follow-up (same posture FTS took, [fts] doc-comment :18-23).

> Implementer note: expose a tiny helper on the wrapper or reuse
> `eval.getTimeseriesStoreForGraph(graph_name)` (it is `pub`, eval.zig:91) so the
> dispatcher gets the identical (1)(2)(3) priority for free without an `Env`.
> Calling `eval.getTimeseriesStoreForGraph(null)` returns `g_timeseries_store`
> (the global), which is exactly the server-boot store. **Recommended: the handler
> calls `eval.getTimeseriesStoreForGraph(graph_name_or_null)`** — one call, reuses
> the existing resolver, no adapter knowledge duplicated in the dispatcher.

### 1.4 Value type confirmation + the exact lossless conversion

- Storage value is **i64** (`types.zig: Point{ts:i64,value:i64}`). geode's `Point`
  is layout-identical; `insertMany` `@ptrCast`s `{i64,i64}` → `{i64,i64}` (identity,
  sound). Round-trip is exact for any i64 (B-changemap §5).
- **GQL → storage:** a GQL `Value.Int` (which is i64 in geode's value union) maps
  to `Point.value` by **direct identity assignment** — `point.value = arg.Int;`.
  No cast, no scale, no bitcast. `ts` likewise: `point.ts = ts_arg.Int;`.
- **storage → GQL:** `Point.value` (i64) → `Value{ .Int = pt.value };`. `Point.ts`
  → `Value{ .Int = pt.ts };`. Exact.
- **Float decision (FLAGGED):** B2 **rejects** a `Value.Double` value argument with
  `error.TypeMismatch`. Rationale: the live store path is i64-only; there is no
  wired `PointF64` lane (B-changemap §5-flag-1). Accepting a Double would force a
  silent lossy choice (truncate? bitcast? scale?) — all of which are wrong without
  an end-to-end f64 lane. **Decision: Int-only ingest in B2; PointF64 lane is a
  separate, explicit follow-up** (would touch `Store`, the engine config, and the
  read converters end-to-end). The handler error message should say so:
  `"geode.ts.insert: value must be an integer (float timeseries values are not yet supported)"`.
- Convenience: accept a GQL `Value.Int` for `ts`. Reject `Double` for `ts` too
  (timestamps are i64 ms by convention). A whole-number `Double` (e.g. `100.0`)
  MAY be coerced to Int as a usability nicety, but the SAFE default is reject;
  recommend reject in B2 and document `100` not `100.0`.

---

## 2. Series identity over GQL

A series is `(device_id, metric) → u128 SeriesId` via the existing double-Wyhash
`hashKey` (B-changemap §1, `timeseries.zig:128-138`). The same u128 is both the
`series_cache` map key and the engine `SeriesId`.

**GQL arg shape (decided):** `(device_id: Int, metric: String)` as the first two
positional args of every `geode.ts.*` procedure. This exactly matches the existing
13 read FUNCTIONS' arg convention (`timeseries.last_value(device_id Int, metric Str,
…)`, B-changemap §2), so the procedure surface is consistent with the function
surface a caller already knows.

**Why a `(device, metric)` pair, not an opaque `series_key` string:** the wrapper's
`SeriesKey` is `{device_id, metric}` and `hashKey` consumes both fields separately
(`h.update(asBytes(&device_id)); h.update(metric)`). Passing a pre-joined string
would require either a new parse/split convention or a new identity hash — both
gratuitous. The pair maps **directly** to the existing `SeriesKey`:

```zig
const key = SeriesKey{ .device_id = @intCast(args[0].Int), .metric = args[1].String };
```

No new mapping code; reuse `hashKey` inside `insertMany`/the read methods unchanged.

> `device_id` type: it is whatever int width `SeriesKey.device_id` is (recon shows
> it `asBytes`'d, so a fixed-width int — implementer reads the field type at
> `ts_lib.store.SeriesKey` and `@intCast`s the GQL i64 to it; reject out-of-range).

---

## 3. The `geode.ts.*` procedure surface (mirror FTS)

All live in a new `src/execution/ts_dispatch.zig` (the analog of `fts_dispatch.zig`),
routed by a `geode.ts.` prefix branch in `procedure_registry.zig`, classified in
`procedure_access.zig`. **No `gql` grammar change, no re-pin** (runtime dotted-name
dispatch, exactly like `geode.fts.*` — GQL-INVENTORY §D).

### 3.1 WRITE procedures (`requires_write = true`)

#### `geode.ts.insert(device_id, metric, ts, value)`

- **Args:** `device_id` Int, `metric` String, `ts` Int, `value` Int.
- **YIELD columns:** `inserted` (Int, = 1). A write procedure returns a 1-row
  status table (see §4 for why a row, not "nothing").
- **requires_write:** true.
- **Resolution+call chain:**
  1. `args.len == 4` else `error.InvalidArgs`.
  2. `device_id = literalInt(args[0])`, `metric = literalString(args[1])`,
     `ts = literalInt(args[2])`, `value = literalInt(args[3])`
     (`literalInt` rejects `.Double` → `error.TypeMismatch`).
  3. `store = eval.getTimeseriesStoreForGraph(graph) orelse return error.Unsupported`.
  4. `const key = SeriesKey{ .device_id = @intCast(device_id), .metric = metric };`
  5. `const pt = Point{ .ts = ts, .value = value };`
  6. `store.insertMany(key, &.{pt}) catch return error.Unsupported;` (mutex-guarded
     after B0).
  7. Build `columns = {"inserted"}`, `rows = {{ Value{ .Int = 1 } }}`.
  8. Apply `filterYieldColumns` if `call_stmt.yield_items != null`.

#### `geode.ts.insert_many(device_id, metric, points)`

- **Args:** `device_id` Int, `metric` String, `points` List.
- **`points` shape:** a **list of 2-element `[ts, value]` lists** —
  `points = [[100, 72], [110, 73], …]`. Each inner element is a `Value.List` of two
  `Value.Int`. (Map form `[{ts:…, value:…}]` is a deferred nicety; list-of-list is
  the minimal, parser-supported form — geode's fork parses list literals as
  `Value.List`; nested list literals are supported, B-changemap §7-B2 notes
  `List<List<Int>>`.)
- **YIELD columns:** `inserted` (Int, = N points written).
- **requires_write:** true.
- **Resolution+call chain:** `args.len == 3`; resolve store; iterate
  `args[2].List`, for each inner `Value.List` of len 2 build a `Point{ts,value}`
  on a temp arena; one `store.insertMany(key, pts)` call with the full slice
  (single sort + single WAL append). Return `rows = {{ Value{ .Int = @intCast(N) } }}`.
- **Arg validation:** reject non-list `points`, reject inner elements that are not
  2-element Int lists (`error.InvalidArgs` / `error.TypeMismatch`).

> **CHECK before implementing the list form:** confirm geode's fork parser accepts
> a nested list literal `[[1,2],[3,4]]` inside a `CALL(...)` arg position and that
> it arrives at the dispatcher as `args[2].* == .List` with `.List[i].* == .List`.
> The FTS path only ever reads scalar `.String`/`.Int` args ([fts]
> `literalString`/`args[2].Int`), so list-arg extraction in a procedure handler is
> NEW. If nested-list args do NOT survive parse→dispatch as `Value.List`, fall back
> to: `geode.ts.insert` called N times by the caller (still correct, just chattier),
> OR a flat interleaved `geode.ts.insert_pairs(device, metric, ts1, val1, ts2, val2, …)`
> varargs form. Recommend verifying the nested-list path first; it is the cleanest.

### 3.2 READ procedures (`requires_write = false`)

#### `geode.ts.range(device_id, metric, start_ts, end_ts)` — the `fts.search` analog

- **Args:** `device_id` Int, `metric` String, `start_ts` Int, `end_ts` Int.
- **YIELD columns:** `ts` (Int), `value` (Int). One row per stored point in
  `[start_ts, end_ts]` (inclusive after B0 bug-2 fix).
- **requires_write:** false.
- **Resolution+call chain (mirrors `handleFtsSearch` precisely, [fts] :70-140):**
  1. arity + `literalInt`/`literalString` extraction.
  2. `store = eval.getTimeseriesStoreForGraph(graph) orelse return error.Unsupported`.
  3. `const pts = store.queryRange(key, start_ts, end_ts, allocator) catch return error.Unsupported;`
     (this returns `![]Point`; **OWNERSHIP**: it allocates with the `allocator`
     PASSED to `queryRange` — unlike the FTS facade which uses its own allocator.
     So `queryRange` results are owned by the request `allocator` and freed by the
     normal `ExecutionResult.deinit` path. Confirm: `queryRange(…, allocator)` takes
     the allocator as its last param, B-changemap §1 signature — so pass the handler
     `allocator` and the rows it builds share that lifetime. No cross-allocator free
     hazard here, in contrast to the FTS facade note at [fts] :100-108.)
  4. `columns = {"ts","value"}`; one row per point:
     `row[0] = Value{ .Int = pt.ts }; row[1] = Value{ .Int = pt.value };`.
  5. Apply `filterYieldColumns` if `yield_items != null`.

#### `geode.ts.last(device_id, metric)`

- **YIELD columns:** `ts` (Int), `value` (Int). 0 or 1 row.
- **requires_write:** false.
- **Call:** `if (store.last(key)) |pt| → one row {pt.ts, pt.value}` else **0 rows**
  (empty table — the spec-clean "no result" for a missing/empty series; see §4).

#### `geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)`

- **YIELD columns:** `bucket_ts` (Int), `avg` (Int|Null). One row per bucket.
- **requires_write:** false.
- **Call:** `store.timeBucketAvg(key, bucket_seconds, start_ts, end_ts, allocator)`
  → `[]BucketAvgRow`; map each row to `{bucket start ts, avg}` (avg may be Null for
  an empty bucket — the existing "null-avg" test case, B-changemap §6; emit
  `Value{ .Null = {} }` for those).

#### `geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)`

- **Args:** … `agg` String (one of `avg/min/max/count/sum/first/last`).
- **YIELD columns:** `bucket_ts` (Int), `value` (Int|Null).
- **requires_write:** false.
- **Call:** parse `agg` string → `ts_lib.store.Aggregation` enum (reuse whatever
  string→enum the existing `timeseries.sample_by` function uses, gql_functions.zig;
  reject unknown agg → `error.InvalidArgs`); `store.sampleBy(key, interval_ms,
  start_ts, end_ts, agg, allocator)` → `[]SampleRow`; one row per sample.

### 3.3 The split decision (procedures vs the existing functions)

- **Row-returning** operations (`range`, `last`, `bucket_avg`, `sample_by`) become
  **procedures** — they are the natural `CALL … YIELD` set-returners (ISO-GQL Claim
  2/3: a row set comes ONLY from a procedure). `geode.ts.range` is the direct analog
  of `geode.fts.search`.
- **Scalar** aggregates / per-point lookups (`timeseries.value`,
  `timeseries.last_value`, `timeseries.value_at`, `moving_avg`, `rate`,
  `derivative`, the DTW/cosine array fns, etc. — B-changemap §2) **stay as eval
  FUNCTIONS** (they return a scalar or a small List/Map and are used in value
  position). Do NOT duplicate them as procedures.
- **WRITE** has no function equivalent today (there is no GQL write path at all,
  B-changemap §3) → the new `geode.ts.insert*` procedures are the ONLY ingest
  surface. They are procedures because a mutating set-producer is a procedure, and
  because that is how the goal ("the way FTS was done") frames it.

---

## 4. ISO-GQL validity + how geode handles a write procedure / empty result

### 4.1 `CALL geode.ts.insert(...)` and `CALL geode.ts.range(...)` are valid GQL

- `CALL geode.ts.insert(1, 'temp', 100, 72)` is a `<call procedure statement>` →
  `[OPTIONAL] CALL <procedure call>` → `<named procedure call> ::= <procedure
  reference> ( [<procedure argument list>] ) [<yield clause>]`
  (GQL-SPEC-VERIFIED Claim 1, BNF L534/L550). **YIELD is OPTIONAL** (`[ <yield
  clause> ]`), so a write CALL with no YIELD is grammatically valid.
- `geode.ts.range` / `geode.ts.insert` are valid dotted `<procedure reference>`s:
  `geode` `.` `ts` `.` are `{ <object name> <period> }...` items, trailing
  `range`/`insert` is the `<procedure name>` (GQL-SPEC-VERIFIED Claim 4, BNF L1134).
- Procedure arguments are `<value expression>`s, comma-separated — so Int / String /
  List literal args are all valid (Claim 1, BNF L554-557).
- `CALL geode.ts.range(...) YIELD ts, value RETURN ts, value ORDER BY ts` is valid
  linear-query composition (Claim 5).

### 4.2 A write procedure that returns no rows — how geode handles it

geode's dispatch contract is `*_dispatch.execute(...) !?ExecutionResult` returning
an `ExecutionResult{ columns, rows }` (GQL-INVENTORY §B.1/§B.3, execution.zig:598).
An empty `rows` (0-length slice) with a `columns` header is perfectly valid — the
generic wire encoder serializes `{columns, rows}` per query with no per-procedure
knowledge (§B.3), so a 0-row or 1-row status table flows over QUIC/gRPC/in-process
identically to any RETURN result.

**Design choice:** the write procedures return a **1-row status table**
(`columns = {"inserted"}`, `rows = {{ Int }}`) rather than literally nothing.
Rationale:

- It gives the caller a confirmation count (`inserted = N`) — useful for
  `insert_many` and for the harness to `stdout_contains` assert.
- A `CALL … YIELD inserted RETURN inserted` then works; a bare `CALL geode.ts.insert(...)`
  with no YIELD also works (YIELD optional). Both are spec-valid.
- It avoids any ambiguity about whether a 0-row write "did nothing" — the existing
  mutating CALLs in geode (auth DDL `geode.auth.*`, GQL-INVENTORY §B.1 names them as
  a mutating dispatch family) likewise return a status/result table, not nothing.

> Evidence for "mutating CALL returns a table, executed unsnapshotted": GQL-INVENTORY
> §B.1 — `executeCallStatement` (call_operations.zig:74): *"if mutating → run
> unsnapshotted; else wrap in a `QueryReadSession` snapshot"*. So the executor
> already branches on mutating-vs-read via the `procedure_access` classification
> (§5 below), and mutating procedures (auth DDL) return ordinary
> `ExecutionResult`s. The TS write procedures follow that exact path: classified
> mutating → run unsnapshotted → return the `inserted` status table.

The `OPTIONAL` modifier and `FINISH` (a result statement that yields no binding
table, GQL-SPEC-VERIFIED Claim 5 BNF L477) confirm the standard also allows a
no-binding result, so even a truly row-less write CALL is conformant — but the
status-row form is friendlier and is what this design specifies.

---

## 5. Registry + procedure_access wiring (mirror the FTS branch)

### 5.1 `procedure_registry.zig` — add the `geode.ts.` branch (CONFIRMED shape)

In `executeCallProcedure` (procedure_registry.zig:99-210, read this session), the
`geode.fts.` branch is at lines 197-203 (verbatim):

```zig
// ---- geode.fts.* procedures (full-text search) ----
if (std.mem.startsWith(u8, proc_name, "geode.fts.")) {
    if (try fts_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
        return result;
    }
}
```

Note the FTS branch calls `fts_dispatch.execute(allocator, proc_name, call_stmt,
context)` — **it does NOT pass `store`** (the local `store =
graph_store.getGlobalStore(allocator)` at :132 is passed only to `meta_dispatch`
and `algo_dispatch`). So mirror exactly:

```zig
const ts_dispatch = @import("ts_dispatch.zig");   // top-of-file, beside `const fts_dispatch = @import("fts_dispatch.zig");` at registry line 40
…
// add directly after the geode.fts. branch (after line 203), before UnknownProcedure (:205):
// ---- geode.ts.* procedures (timeseries) ----
if (std.mem.startsWith(u8, proc_name, "geode.ts.")) {
    if (try ts_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
        return result;
    }
}
```

- `proc_name` is the ASCII-lowercased dotted name from `extractNormalizedProcName`
  (registry :89-97) — so the dispatcher matches `"geode.ts.insert"`,
  `"geode.ts.range"`, etc.
- The handler returns `!?ExecutionResult`; `null` = "not my procedure" (falls
  through to `ExecutionError.UnknownProcedure` at :209).
- **Use the exact FTS 4-arg signature** `execute(allocator, proc_name,
  call_stmt: ast.CallProcedure, context: ExecutionContext) !?ExecutionResult`
  ([fts] :45-50). TS resolves the TS store itself (§1.3), so it needs no graph
  `store` arg — same as FTS.

### 5.2 `procedure_access.zig` — classify the family (CONFIRMED shape)

`classifyProcedureName(proc_name: []const u8) ProcedureAccess`
(procedure_access.zig:128-133, read this session) is **a linear scan over a flat
`const read_only_procedure_names = [_][]const u8{ … }` array** (lines 20-112),
case-insensitive (`std.ascii.eqlIgnoreCase`), returning `.read_only` on a hit and
**`.mutating` by default** (the fail-closed default for everything unlisted). The
GPS gate (procedure_registry.zig:116-129) maps `.read_only → .read`,
`.mutating → .write`. `geode.fts.search` is already in the array (line 76, with its
CANARY). So:

- **Add the four TS read names to `read_only_procedure_names`** (exact strings,
  lowercased — the scan lowercases the proc name first via
  `extractNormalizedProcName`, and the array entries are matched case-insensitively):
  `"geode.ts.range"`, `"geode.ts.last"`, `"geode.ts.bucket_avg"`,
  `"geode.ts.sample_by"` — beside the `geode.fts.search` entry, with a parallel
  CANARY comment.
- **Do NOT add `geode.ts.insert` / `geode.ts.insert_many`** — leaving them out of
  the array makes `classifyProcedureName` return `.mutating` by default, which is
  exactly the write classification we want (GPS `.write` action; unsnapshotted run
  via `call_operations.zig:74`). This is the `requires_write = true` the task asks
  for, expressed through the existing fail-closed default — no new branch needed.
- There is **no prefix logic** in this classifier (it is an exact-name allow-list),
  so each TS read name must be listed explicitly; a typo means the read proc would
  be mis-classified `.mutating` and denied to read-only users. List all four.

### 5.3 `ts_dispatch.zig` handler skeleton (mirror `fts_dispatch.zig`)

```zig
//! Timeseries dispatch — the `geode.ts.*` procedure family. Analog of fts_dispatch.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");
const eval = @import("../eval.zig");                 // getTimeseriesStoreForGraph
const ts = @import("../timeseries/timeseries.zig");  // Store, Point, SeriesKey

const execution = @import("../execution.zig");
const execution_helpers = @import("execution_helpers.zig");
const filterYieldColumns = execution_helpers.filterYieldColumns;
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const Value = value_types.Value;

pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    _ = context;
    if (std.mem.eql(u8, proc_name, "geode.ts.insert"))      return try handleInsert(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.insert_many")) return try handleInsertMany(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.range"))       return try handleRange(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.last"))        return try handleLast(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.bucket_avg"))  return try handleBucketAvg(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.sample_by"))   return try handleSampleBy(allocator, call_stmt);
    return null;
}

fn args(call_stmt: ast.CallProcedure) ![]*const ast.Expr {  // mirror fts :74-77
    return switch (call_stmt.procedure) { .Call => |c| c.args, else => error.InvalidArgs };
}
fn literalInt(e: *const ast.Expr) !i64 {
    return switch (e.*) { .Int => |n| n, else => error.TypeMismatch };  // rejects .Double
}
fn literalString(e: *const ast.Expr) ![]const u8 {
    return switch (e.*) { .String => |s| s, else => error.TypeMismatch };  // copy fts :145-150
}
fn resolveStore() !*ts.Store {
    return eval.getTimeseriesStoreForGraph(null) orelse error.Unsupported;  // DEFAULT graph / global, §1.3
}
fn keyOf(a: []*const ast.Expr) !ts.SeriesKey {
    return .{ .device_id = @intCast(try literalInt(a[0])), .metric = try literalString(a[1]) };
}
fn maybeYield(allocator, result, call_stmt) !ExecutionResult {     // copy fts :136-138
    if (call_stmt.yield_items) |y| return try filterYieldColumns(allocator, result, y);
    return result;
}
```

`handleRange` (the FTS-search analog) in full:

```zig
fn handleRange(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 4) return error.InvalidArgs;
    const key = try keyOf(a);
    const start_ts = try literalInt(a[2]);
    const end_ts   = try literalInt(a[3]);
    const store = try resolveStore();
    const pts = store.queryRange(key, start_ts, end_ts, allocator) catch return error.Unsupported;
    // pts owned by `allocator` (queryRange takes it) → freed by ExecutionResult.deinit chain.
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "ts");
    columns[1] = try allocator.dupe(u8, "value");
    const rows = try allocator.alloc([]Value, pts.len);
    for (pts, 0..) |pt, i| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = pt.ts };
        row[1] = Value{ .Int = pt.value };
        rows[i] = row;
    }
    var result = ExecutionResult{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    return try maybeYield(allocator, result, call_stmt);
}
```

`handleInsert`:

```zig
fn handleInsert(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 4) return error.InvalidArgs;
    const key = try keyOf(a);
    const pt = ts.Point{ .ts = try literalInt(a[2]), .value = try literalInt(a[3]) };
    const store = try resolveStore();
    store.insertMany(key, &.{pt}) catch return error.Unsupported;   // mutex-guarded after B0
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "inserted");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 1);
    rows[0][0] = Value{ .Int = 1 };
    var result = ExecutionResult{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    return try maybeYield(allocator, result, call_stmt);
}
```

(`handleInsertMany`, `handleLast`, `handleBucketAvg`, `handleSampleBy` follow the
same shape; `insert_many` iterates `a[2].List`, builds a temp `[]Point`, one
`insertMany` call, returns `inserted = N`.)

> Confirm field names against the live source: `ExecutionResult` literal here uses
> `.flags = std.ArrayList([]const u8).empty` exactly as fts_dispatch does ([fts]
> :130) — copy that exact initializer (and any other optional fields the live
> struct requires; fts_dispatch is the authoritative current shape).

---

## 6. The two B0 bug fixes (file:line + the fix)

### B0 bug 1 — `series_cache` data race (concurrent ingest)

- **Where:** `src/timeseries/timeseries.zig`. `Store` struct (`:35-40`) has an
  unguarded `series_cache: std.AutoHashMap(u128, *Series)` and per-series
  `ArrayList`. `insertMany` (`:145`) mutates them with `std.mem.sort`, no lock.
  Reads (`getSeries :241`, `last :167`, `valueBefore :190`, `queryRange :218`,
  `getOrCreateSeries :249`) read the same map unguarded. The engine's
  `appendPoints` IS serialized internally, but the in-memory cache that ALL
  reads consult is not (B-changemap §4).
- **Fix:** add `store_mutex: std.Thread.Mutex = .{}` to the `Store` struct (`:35`).
  Take it at the top of `insertMany`, `getOrCreateSeries`, `getSeries`, `last`,
  `valueBefore`, `queryRange`, `timeBucketAvg`, `sampleBy` and `defer
  self.store_mutex.unlock();`. Because `insertMany`/the read methods call
  `getOrCreateSeries`/`getSeries`/`hashKey` internally, restructure so the public
  method locks once and calls a private `*Locked` helper (avoid re-entrant lock on
  the non-recursive `std.Thread.Mutex`) — i.e. split `getOrCreateSeries` into a
  locked public wrapper (unused) and an internal `getOrCreateSeriesUnlocked` that
  `insertMany` calls while holding the lock. Same for `getSeries`.
- **Lock ordering:** this is a NEW leaf-tier lock below everything in CLAUDE.md's
  Mutex Lock Ordering table (it touches no other geode lock). Document it as the
  new lowest tier in B6 (CLAUDE.md update).
- **Test:** spawn 2+ threads each doing `insertMany` on the same `Store`
  (different series and the same series), join, assert all points present and
  sorted — run under Zig's safety/race tooling (B3 case (f)).

### B0 bug 2 — `queryRange` end-bound inconsistency

- **Where:** `src/timeseries/timeseries.zig:218-240`. The in-memory cache path
  filters `p.ts < end_ts` (end-EXCLUSIVE, `:232`); the durable engine path
  delegates to `eng.queryPoints(…, start_ts, end_ts)` whose lib semantics are
  INCLUSIVE of `end_ts` (the `valueBefore` path even passes `ts - 1` to emulate
  exclusivity, `:196`). So the SAME query returns a boundary point in durable mode
  but drops it in in-memory mode (B-changemap §5-flag-3).
- **Fix:** make the in-memory branch INCLUSIVE to match the lib: change `:232`
  from `p.ts < end_ts` to `p.ts <= end_ts`. Pick INCLUSIVE as the canonical
  semantic (matches the lib's `queryPoints` and the durable path; documents
  `[start_ts, end_ts]`). Update the `:218` doc-comment from "end-exclusive" to
  "[start_ts, end_ts] inclusive (both paths)".
- **Test:** insert a point exactly at `end_ts`; assert `queryRange(start, end)`
  returns it in BOTH in-memory mode (engine null) AND durable mode (engine
  present), and that the two modes return identical slices (B3 case (e)).
- **Knock-on:** verify `sampleBy`/`timeBucketAvg` (which call `queryRange`
  internally, B-changemap §5) get the boundary point consistently after the fix;
  add the boundary point to their B3 tests.

---

## 7. Tests + bench + harness deliverables (B3 / B4 / B5)

### B3 — unit tests

New `tests/ts_ingest_roundtrip.zig` (wired in `build.zig` beside `e2e_ts_tests`
(build.zig:1981) and `ts_store_tests` (:1991), same imports: `timeseries_wrapper`,
`timeseries_lib`, `timeseries_storage_lib`, `thread_pool` — Appendix of
B-changemap). Drive through the **procedure dispatcher** (parse `CALL
geode.ts.insert(...)` → `executeStatementWithContext` → `ts_dispatch`), not just
the Store, so the GQL surface is what is tested. Cases:

- **(a) ingest+read:** `CALL geode.ts.insert(1,'temp',100,72)` then
  `CALL geode.ts.range(1,'temp',0,200) YIELD ts,value` returns `(100,72)`; also
  `CALL geode.ts.last(1,'temp')` returns `(100,72)`.
- **(b) restart round-trip:** durable `Store` (StoreConfig.data_dir set) →
  `geode.ts.insert` via the procedure → `Store.sync` → `deinit` → reopen → `last`
  returns the point (extends the existing `"ts: persist-restart-query"` test,
  B-changemap §6, through the GQL seam).
- **(c) value exactness:** insert i64 extremes (`maxInt(i64)`, `minInt(i64)`, 0,
  negatives) and read back unchanged via `range`.
- **(d) multi-series isolation:** two `(device_id, metric)` keys
  (`(1,'temp')`, `(2,'temp')`, `(1,'humidity')`) do not collide — validate the
  double-Wyhash u128 partitions them.
- **(e) range bounds (the bug-2 fix):** point at exactly `end_ts` is returned;
  in-memory and durable modes return identical slices; `sample_by`/`bucket_avg`
  include the boundary point.
- **(f) concurrent ingest (the bug-1 fix):** N threads × M inserts on one `Store`;
  assert total count and sortedness; run under race tooling.
- **(g) value rejection:** `CALL geode.ts.insert(1,'temp',100, 1.5)` →
  `error.TypeMismatch` (float value rejected); unknown `agg` string in
  `sample_by` → `error.InvalidArgs`; wrong arity → `error.InvalidArgs`.
- **(h) empty series read:** `geode.ts.range`/`geode.ts.last` on an unknown series
  returns 0 rows (not an error).

Also add a `ts_dispatch`-level test mirroring `tests/test_fts_e2e.zig` (the FTS
e2e test rewritten to `CALL geode.fts.search(...) YIELD …`, GQL-INVENTORY §C.3) so
the TS procedure is exercised through `execution.executeStatementWithContext` — the
same entry the QUIC/gRPC servers use (GQL-INVENTORY §B.2).

### B4 — bench parity (CI-aware latency gate)

- `src/benchmarks/bench_timeseries.zig` (wired build.zig:2021-2028, "ingestion +
  GQL eval benchmark"). Confirm/extend it to bench BOTH ingest
  (`Store.insertMany` / the `geode.ts.insert` dispatch) and query
  (`range`/`last`/`sample_by`/`bucket_avg`).
- Add a **CI-aware latency gate** using the shared bench-baselines module
  (build.zig:~1998, "shared by bench-timeseries and future bench exes that feed
  compare-bench"), matching the `gap0811` count-fastpath gate pattern — env-gated
  thresholds so CI noise doesn't flake (CLAUDE.md "Load Test Baseline Tracking";
  recent commit `fd744d17` "make gap0811 count-fastpath latency gate CI-aware").
  Gate on ingest throughput (points/sec) and `range` p50 latency; CI variance
  multiplier env-gated like gap0811.
- Verify the bench exe body once the build core frees up (it was running during
  this design pass — read-only constraint).

### B5 — harness spec `timeseries_basic.yml`

New `../geode-test-harness/geodetestlab-cli/specs/timeseries_basic.yml` (greenfield —
now possible because B2 gives the harness a GQL WRITE path). Shape (CALL over the
wire, asserting via `stdout_contains`), mirroring the FTS spec form:

```yaml
# timeseries_basic.yml — native geode.ts.* procedure surface over QUIC
steps:
  - name: insert one point
    query: "CALL geode.ts.insert(1, 'temp', 100, 72) YIELD inserted RETURN inserted"
    stdout_contains: ["inserted", "1"]
  - name: insert_many
    query: "CALL geode.ts.insert_many(1, 'temp', [[110, 73], [120, 74]]) YIELD inserted RETURN inserted"
    stdout_contains: ["inserted", "2"]
  - name: range read
    query: "CALL geode.ts.range(1, 'temp', 0, 200) YIELD ts, value RETURN ts, value ORDER BY ts"
    stdout_contains: ["100", "72", "110", "73", "120", "74"]
  - name: last
    query: "CALL geode.ts.last(1, 'temp') YIELD ts, value RETURN ts, value"
    stdout_contains: ["120", "74"]
  - name: sample_by avg
    query: "CALL geode.ts.sample_by(1, 'temp', 50, 0, 200, 'avg') YIELD bucket_ts, value RETURN bucket_ts, value ORDER BY bucket_ts"
    stdout_contains: ["bucket_ts", "value"]
  - name: multi-series isolation (device 2 empty after device 1 writes)
    query: "CALL geode.ts.range(2, 'temp', 0, 200) YIELD ts, value RETURN ts, value"
    stdout_contains: []   # 0 rows — empty series read returns no rows, no error
  - name: empty series last returns nothing
    query: "CALL geode.ts.last(99, 'nope') YIELD ts, value RETURN ts, value"
    stdout_contains: []
```

Run: `cd ../geode-test-harness && GEODE_BINARY=/…/zig-out/bin/geode make test-spec
SPEC=geodetestlab-cli/specs/timeseries_basic.yml`. (Confirm the exact YAML key
names — `query`/`stdout_contains`/`steps` — against
`.migration/discovery/07-harness-spec-format.md` and an existing spec before
authoring; the shape above is the FTS-spec analog.)

### B6 — docs (no client change, no gql bump)

- CLAUDE.md: (a) document `geode.ts.*` as Geode extension procedures next to
  `geode.fts.*`; (b) add the new TS `Store` leaf mutex to the Mutex Lock Ordering
  table; (c) note TS is non-transactional and i64-valued (float deferred).
- docs/TYPES_AND_FUNCTIONS (or a TS reference doc): list the six procedures with
  args/YIELD columns.
- **Do NOT** bump the `gql` pin or change geode-client-zig — TS rides generic GQL
  rows through the same encoder as FTS (GQL-INVENTORY §B.3, §D).

---

## 8. Ordered implementation checklist (hand to an implementer)

1. **B0** — `src/timeseries/timeseries.zig`: add `store_mutex` to `Store` (:35),
   guard `insertMany`/`getOrCreateSeries`/`getSeries`/`last`/`valueBefore`/
   `queryRange`/`timeBucketAvg`/`sampleBy` (split into `*Unlocked` internals to
   avoid re-entrant lock). Fix `queryRange` `:232` `<` → `<=` (inclusive). Add the
   concurrent-ingest test + the boundary-point test.
2. **B2a** — new `src/execution/ts_dispatch.zig` (§5.3 skeleton): six handlers
   (`insert`, `insert_many`, `range`, `last`, `bucket_avg`, `sample_by`). Resolve
   store via `eval.getTimeseriesStoreForGraph(null)`. i64-only; reject Double.
3. **B2b** — `procedure_registry.zig`: `const ts_dispatch = @import("ts_dispatch.zig");`
   (beside `:40`) + the `geode.ts.` prefix branch in the dispatch chain (beside
   `geode.fts.`).
4. **B2c** — `procedure_access.zig`: add the four read names (`"geode.ts.range"`,
   `"geode.ts.last"`, `"geode.ts.bucket_avg"`, `"geode.ts.sample_by"`) to the
   `read_only_procedure_names` array (beside `"geode.fts.search"`, line 76). Leave
   `geode.ts.insert` / `geode.ts.insert_many` OUT → they default to `.mutating`
   (the write classification). No code-path change, just two list edits.
5. **B3** — `tests/ts_ingest_roundtrip.zig` (cases a–h) wired in build.zig beside
   the existing TS test exes; plus a `ts_dispatch` e2e test through
   `executeStatementWithContext`.
6. **B4** — extend `src/benchmarks/bench_timeseries.zig` to cover the procedure
   ingest + range path; add the CI-aware latency gate (gap0811 pattern).
7. **B5** — `../geode-test-harness/geodetestlab-cli/specs/timeseries_basic.yml`.
8. **B6** — CLAUDE.md (extension procedures + mutex tier + i64 note) + docs; no
   gql bump, no client change.

## 9. Open items to verify against live source before/at implementation

(`procedure_access.zig` AND the registry router were re-read this session and are
now CONFIRMED in §5.1/§5.2 — `classifyProcedureName` is a flat allow-list scan,
the FTS branch is 4-arg with no `store`. The remaining items below are the only
ones not directly read this pass):

- **`ExecutionResult` literal fields** — copy fts_dispatch's exact initializer
  (`.columns`, `.rows`, `.flags = std.ArrayList([]const u8).empty`, [fts] :127-131)
  and add any other required field present in the live `execution.zig:598` struct.
- **Nested-list arg survival** — confirm `[[ts,val],…]` reaches the dispatcher as
  `Value.List`-of-`Value.List` (§3.1 CHECK). If not, use the per-call or
  flat-varargs fallback.
- **`SeriesKey.device_id` int width** — `@intCast` the GQL i64 to it; reject
  out-of-range.
- **`ts_lib.store.Aggregation` string mapping** — reuse the existing
  `timeseries.sample_by` function's agg-string→enum parse (gql_functions.zig).
- **Harness YAML keys** — confirm `query`/`stdout_contains`/`steps` against
  discovery/07 + an existing spec.
