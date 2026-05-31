# A0 — FTS-Storage Migration Design Decisions

Status: RESOLVED (read-only discovery). All decisions are backed by file:line evidence
gathered without compiling. The already-wired `timeseries-storage` integration is the
cross-cutting reference pattern. (Terminal output was intermittently garbled under build
load; every cited line was re-read with a clean Read pass before being recorded.)

Libraries:

- fts-storage: `/data/home/benji/src/devnw/zig/fts-storage` — module name `fts_storage`.
  Public surface re-exported in `src/root.zig`: `engine` (53), `search` (54),
  `Engine = engine.Engine` (63), `TermPosting = engine.TermPosting` (66),
  `DocBatch = engine.DocBatch` (70), `TermIterator = search.TermIterator` (73).
- graph-storage: `/data/home/benji/src/devnw/zig/graph-storage`.

## Confirmed external API (`fts-storage`)

| Item | Signature / shape | file:line |
|------|-------------------|-----------|
| `Engine.init` | `init(io: std.Io, allocator: Allocator, base_dir: std.Io.Dir) !*Engine` | engine.zig:177 |
| `Engine.initWithConfig` | `initWithConfig(io, allocator, base_dir, config: EngineConfig) !*Engine` | engine.zig:185 |
| `EngineConfig` | `struct { hmac_key: ?[]const u8 = null, aead_key: ?[]const u8 = null }` | engine.zig:49 |
| `Engine.indexDocument` | `indexDocument(self, doc_id: u64, terms: []const TermPosting) !void` | engine.zig:703 |
| `Engine.indexDocumentExcluding` | `(self, doc_id, terms, excluded_fields: []const []const u8) !void` (FLE field guard) | engine.zig:686 |
| `Engine.indexDocumentBatch` | `(self, docs: []const DocBatch) !void` (1 fsync/batch) | engine.zig:834 |
| `Engine.deleteDocument` | `deleteDocument(self, doc_id: u64) !void` | engine.zig:935 |
| `Engine.flush` | `flush(self) !void` — **synchronous; no `io` arg** (uses stored `self.io`) | engine.zig:983 |
| `Engine.flushAsync` | `flushAsync(self) !void` — needs multi-threaded Io (**WE AVOID**) | engine.zig:1159 |
| `Engine.deinit` | `deinit(self) void` — **does NOT flush; caller must `flush()` first**; closes `wal/`+`segments/`, never `base_dir` | engine.zig:423 |
| `TermPosting` | `struct { term: []const u8, positions: []const u32, field: ?[]const u8 = null }` | engine.zig:14-22 |
| `DocBatch` | `struct { doc_id: u64, terms: []const TermPosting }` | engine.zig:41-44 |
| `TermIterator` (single-term) | `init(allocator, eng: *Engine, term) !TermIterator` + `next() !?Match` + `deinit()`; `initWithAuth(...)` adds an `AuthFilter` RLS/ABAC post-filter | search.zig:97 / 233 / 168 / 104 |
| `TermIterator.Match` (scored hit) | `struct { doc_id: u64, positions: []const u32, score: f32 }` (BM25; higher = more relevant) | search.zig:83-95 |
| `AuthFilter` | `*const fn (doc_id: u64, ctx: ?*anyopaque) bool` (RLS post-filter hook) | search.zig:27 |

**CRITICAL: there is NO `Engine.search` method.** Querying is done through `TermIterator`
(single term, `search.zig:97`/`233`) — the engine carries `io: std.Io` (engine.zig:66),
`dir/wal_dir/seg_dir: std.Io.Dir` (engine.zig:67,69,70), `wal_file: std.Io.File`
(engine.zig:99), `rw_lock: std.Io.RwLock` (engine.zig:123). The injected Io is captured at
`init` and reused by `flush`/`deinit`, so those take no `io` argument. Multi-term AND/OR
ranking is built by the caller by merging per-term `TermIterator` results on `doc_id` and
summing `Match.score` (the lib provides BM25 per (term,doc) via `TermIterator.next`).
Query text must be tokenized into terms first with geode's existing tokenizer.

---

## Decision 1 — std.Io source for the FTS adapter

### Evidence

**fts-storage REQUIRES a `std.Io`** as the first parameter of every constructor
(`engine.zig:177`, `engine.zig:185`) and as a struct field (`engine.zig:66`). The lib's
own tests/example use the single-threaded global Io
(`std.Io.Threaded.global_single_threaded.io()`, ~30 sites in `engine.zig`); `flushAsync`
(engine.zig:1159) is the only path needing a multi-threaded Io and we will not use it.

**timeseries-storage does NOT take a `std.Io`** — `Engine.init(allocator, engine_config,
pool_ptr)` (`src/timeseries/timeseries.zig:81`) takes a `*thread_pool.ThreadPool`
(`timeseries.zig:56-62`, owned by the `Store`, freed in `deinit`). So timeseries gives the
**ownership/lifetime pattern** (engine + resource owned by the wrapper Store, created in
init, torn down in deinit) but NOT the Io plumbing.

**graph-storage `ShardedGraphEngine.create(allocator, data_dir, graph_uuid, config)`**
(`graph_storage_adapter.zig:3935`) takes **no `std.Io`** either.

**geode already uses a single-threaded Io handle in storage code — including the FTS path
itself.** `graph_storage_adapter.zig:3896` already does
`std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), fts_dir)`.
Same handle in `src/wal.zig:184,186,645` and `src/fle_integration.zig:34,35,51,52,…`.

### DECISION 1

**BORROW the existing process-global single-threaded Io
`std.Io.Threaded.global_single_threaded.io()`** — the exact handle the FTS init path
already uses at `graph_storage_adapter.zig:3896`.

- `const io = std.Io.Threaded.global_single_threaded.io();`, store the resulting `std.Io`
  in the per-index FTS wrapper alongside the `*fts_storage.Engine`, pass it to
  `Engine.init(io, allocator, base_dir)`, and reuse for `flush`/`deinit`.
- **Single-threaded is correct** because we never call `flushAsync` (engine.zig:1159); the
  synchronous `flush` (engine.zig:983) works on the single-threaded global Io.
- **Lifetime/ownership:** `global_single_threaded` is a process-global with static lifetime;
  the `std.Io` interface value is copy-cheap and trivially outlives any per-graph engine.
  The wrapper borrows the interface — it does NOT own or destroy a backing executor and
  creates no threads. (If async flush is ever wanted, geode must stand up its own
  `std.Io.Threaded` with a thread pool and pass that Io — explicitly out of scope.)

---

## Decision 2 — Engine granularity, on-disk scheme, and doc_id ↔ node id identity

### Evidence

FTS doc identity is the node id as a `u64`:

- `src/index/fulltext.zig:243` `indexDocument(self, doc_id: u64, content: []const u8) !void`
- `src/index/fulltext.zig:97` `search(self, query: []const u8, max_results: usize) ![]SearchResult`; `SearchResult.doc_id: u64` (fulltext.zig:39)
- `src/index/fulltext.zig:341` `removeDocument(self, doc_id: u64)`
- node id IS the doc id: `graph_storage_adapter.zig:5800` `mg.fts_index.?.indexDocument(42, "…")` indexes by node id; accessor `getFulltextIndex(name) ?*fulltext.FullTextIndex` (`graph_storage_adapter.zig:1269`).

The on-disk FTS dir today is `{graph_dir}/fts` AND IS ALREADY PERSISTED:

- `graph_storage_adapter.zig:650-652` `fts_index: ?*fulltext.FullTextIndex`, comment "persisting to `{graph_dir}/fts/`"; owned `fts_dir: ?[]const u8` "for saveToDisk on close" (:653-654).
- `graph_storage_adapter.zig:3889` `fts_dir = allocPrint("{s}/fts", .{graph_dir})`, `createDirPath` (:3896); on `load_existing`, `FullTextIndex.loadFromDisk(allocator, fts_dir)` (:3908) else `.init` (:3919). Persisted on close via `ManagedGraph.deinit` → `fts.saveToDisk(dir)` (:769).

### DECISION 2

**One `fts_storage.Engine` per named fulltext index, on disk under
`{graph_dir}/fts/<index_name>/`:**

- **Granularity:** one Engine per named fulltext index (not one global, not one per
  property). Today there is a single per-graph `FullTextIndex` at `{graph_dir}/fts`; the new
  scheme nests each named index as `{graph_dir}/fts/<index_name>/` so a graph can host
  multiple fulltext indexes without collision. The adapter `createDirPath`s the subdir,
  opens it as a `std.Io.Dir` (`std.Io.Dir.cwd().openDir(io, path, .{})`), and passes that as
  `base_dir` to `Engine.init`. The adapter owns and closes that Dir (the Engine never closes
  `base_dir`, engine.zig:154-167).
- **doc_id == node id (u64), identity mapping.** No external id map:
  `engine.indexDocument(node_id, terms)` / `engine.deleteDocument(node_id)`; results carry
  `doc_id` values that ARE node ids, looked up directly in the graph store.
- **Multiple properties on one Engine via `TermPosting.field`:** tokenize each indexed
  property and tag every posting with the property name in `TermPosting.field`
  (engine.zig:14-22); one Engine holds all properties for that index, with per-field
  search/exclusion (`indexDocumentExcluding`, engine.zig:686) available without a second
  Engine. Node delete = one `deleteDocument(node_id)` regardless of property count.

---

## Decision 3 — Query surface: `fulltext_search(...)` GQL function dispatched in eval.zig

### Evidence — how the timeseries read-functions are name-dispatched in eval.zig

Two-stage dispatch keyed off a dotted function name:

1. **Gate + special-case:** dotted names enter the namespaced-builtin path; `timeseries.value`
   is special-cased inline at `eval.zig:889`
   (`std.ascii.eqlIgnoreCase(function_name, "timeseries.value")`).
2. **Suffix dispatcher:** at `eval.zig:921`,
   `if (try evalTimeseriesFunction(allocator, function_name, call.args, env)) |result| { break :blk_call result; }` — returning `null` means "not a TS function → fall through".
   The handler `fn evalTimeseriesFunction(allocator, function_name: []const u8, args: []*ast.Expr, env: Env) EvalError!?Value` (eval.zig:3825):
   - prefix guard `startsWithIgnoreCase(function_name, "timeseries.")` (eval.zig:3835), then `suffix = function_name["timeseries.".len..]` (:3836);
   - **name → handler:** a chain of `std.mem.eql(u8, suffix, "<name>")` branches (eval.zig:3866+); unknown ⇒ fall through;
   - **store resolution:** `fn resolveTimeseriesStore(env: Env, graph_name: ?[]const u8) ?*TimeseriesStore` (eval.zig:3811): priority (1) per-Env `env.timeseries_store` (:3816), (2) per-graph via `getTimeseriesStoreForGraph` → `graph_store.getGlobalAdapter()` → `adapter.getTimeseriesStore(name)` (:3817, :93-94), (3) process-global `g_timeseries_store` (:77, set at startup by `setGlobalTimeseriesStore`);
   - **`Env`** is `value_types.Env` (`pub const Env = value_types.Env;`, eval.zig:48); the adapter is reached via module-global `graph_store.getGlobalAdapter()` (eval.zig:93), NOT a struct field (server path has no per-Env store, eval.zig:4487 comment);
   - **args → values:** `evalExpr(allocator, args[i].*, env)` then `.Int`/`.Str` checks (eval.zig:3852-3855);
   - **results → rows:** each TS handler returns a scalar `Value` through the `?Value` channel; table-shaped results ride the same channel as `Value` lists/records.

The adapter exposes parallel accessors: `getTimeseriesStore(name) ?*ts_mod.Store`
(`graph_storage_adapter.zig:1258`) and `getFulltextIndex(name) ?*fulltext.FullTextIndex`
(`graph_storage_adapter.zig:1269`).

### Evidence — index_optimizer `QueryType.fulltext_search`

`QueryType.fulltext_search` already exists as a planner/cost concept (member of the
`QueryType` enum), consumed only for cost/selectivity: the index-supports-query-type switch
maps `.fulltext` indexes to `.fulltext_search` at `index_optimizer.zig:810/814/818/820-821`,
and BM25 cost estimation hangs off it (`:452-458, 684-697, 761`). None of this executes a
query — it only plans/cost-estimates, so the planner already has a slot and no new QueryType
is needed; the execution path is what's missing. (CREATE INDEX catalog rendering of the
`.fulltext` type is at `execution.zig:1452`.)

### DECISION 3

**Add a Geode-extension GQL function `fulltext_search(...)` dispatched in `eval.zig` beside
the TS family, returning a set of (node, score) rows. Do NOT reroute `CONTAINS`.**

- **Dispatch seam:** add — directly after the TS dispatch at eval.zig:921 — a sibling call
  `if (try evalFulltextFunction(allocator, function_name, call.args, env)) |result| { break :blk_call result; }`.
- **New handler** `fn evalFulltextFunction(allocator, function_name: []const u8, args: []*ast.Expr, env: Env) EvalError!?Value`, modeled on `evalTimeseriesFunction` (eval.zig:3825):
  - match name == `"fulltext_search"` (case-insensitive); return `null` otherwise;
  - resolve the engine via a new `resolveFulltextIndex(env, index_name)` mirroring
    `resolveTimeseriesStore` (eval.zig:3811): reach the adapter through
    `graph_store.getGlobalAdapter()` (as eval.zig:93 does) → `adapter.getFulltextIndex(index_name)`
    (accessor exists at `graph_storage_adapter.zig:1269`; post-migration it returns the
    `fts_storage.Engine` wrapper);
  - evaluate args (index name, query text, optional `max_results`), tokenize the query with
    geode's existing Unicode-normalizing tokenizer (`fulltext.zig` ~177/204 →
    `src/unicode/geode_unicode.zig`), then build per-term `TermIterator`s
    (`fts_storage.TermIterator.init(allocator, engine, term)`, search.zig:97), drain each with
    `next()` (search.zig:233), and merge on `doc_id` summing `Match.score` to produce ranked
    `(doc_id, score)` pairs bounded by `max_results`. **There is no `Engine.search` method** —
    use `TermIterator`. (RLS/ABAC can use `initWithAuth` + `AuthFilter`, search.zig:104/27.)
- **Row-set return:** the dispatch path yields a scalar `Value`, so emit each result as a
  record and return the set as a **`Value` list of records** with columns `node_id` (from
  `Match.doc_id`, which IS the node id) and `score` (from `Match.score`) — the same `?Value`
  table-shaping the TS read-functions use. Callers `UNWIND fulltext_search(...)` to expand
  rows, then re-`MATCH` nodes by id. (A dedicated table-function plan node could slot into the
  same handler later; not needed for this phase.)
- **Do NOT reroute `CONTAINS`:** it remains a plain substring predicate in the match loop, so
  ISO `CONTAINS` semantics are unchanged. The fulltext engine is reached only through the
  explicit `fulltext_search(...)` extension. The planner's existing `QueryType.fulltext_search`
  is reused for costing.

---

## Decision 4 — Persistence: delete-safety list for `fulltext_persist.zig`

### Evidence — every reference to fulltext_persist / saveToDisk / loadFromDisk

**CORRECTION to any assumption that this is dead code: it is LIVE.** `saveToDisk`/`loadFromDisk`
are actively called on the per-graph FTS path.

`fulltext_persist` references (`grep fulltext_persist src/ tests/ build.zig`):

- `src/index/fulltext_persist.zig` — definition + its own tests (:336, :381, :398).
- `src/index/fulltext.zig:329` — `@import("fulltext_persist.zig")` inside `saveToDisk`.
- `src/index/fulltext.zig:336` — `@import("fulltext_persist.zig")` inside `loadFromDisk`.
- `src/lib.zig:304` — `pub const fulltext_persist = @import("index/fulltext_persist.zig");` (public re-export).

`saveToDisk` / `loadFromDisk` call sites (FTS only — the `timeseries.zig`/`server/main.zig`
ones are the **timeseries** store's own method, unrelated, do not touch):

- `src/index/fulltext.zig:328` (`saveToDisk` def, wraps `persist.save`), `:335` (`loadFromDisk` def, wraps `persist.load`).
- `src/storage/graph_storage_adapter.zig:769` — `fts.saveToDisk(dir)` in `ManagedGraph.deinit` (persist on close).
- `src/storage/graph_storage_adapter.zig:3908` — `FullTextIndex.loadFromDisk(allocator, fts_dir)` in `initFtsForGraph`.
- `src/storage/graph_storage_adapter.zig:653, 5815` — comments referencing the saveToDisk-on-close contract.

### DECISION 4 — delete-safety list

**`src/index/fulltext_persist.zig` is SAFE TO DELETE, but ONLY as part of the same change
that cuts the in-tree FTS over to `fts_storage.Engine`** (which owns durability via its WAL +
segments + manifest, made durable by `Engine.flush`). It is NOT a standalone safe-delete today —
the references below would dangle. Every reference to remove/rewire:

| File:line | Reference | Action when deleting fulltext_persist.zig |
|---|---|---|
| `src/lib.zig:304` | `pub const fulltext_persist = @import("index/fulltext_persist.zig");` | Remove the line. |
| `src/index/fulltext.zig:328-330` | `saveToDisk` → `@import("fulltext_persist.zig").save` | Remove/replace — `FullTextIndex` is superseded by `fts_storage.Engine`; if `fulltext.zig` is deleted this goes with it; if kept transiently, drop the import + stub the method. |
| `src/index/fulltext.zig:335-337` | `loadFromDisk` → `@import("fulltext_persist.zig").load` | Same as above. |
| `src/storage/graph_storage_adapter.zig:769` | `fts.saveToDisk(dir)` in `ManagedGraph.deinit` | Replace with `engine.flush()` (durability) **then** `engine.deinit()` — note `deinit` does NOT auto-flush (engine.zig:423), so the explicit `flush()` before `deinit` is required. |
| `src/storage/graph_storage_adapter.zig:3908` | `FullTextIndex.loadFromDisk(allocator, fts_dir)` in `initFtsForGraph` | Replace with `fts_storage.Engine.init(io, allocator, base_dir)` (Engine replays its own WAL/segments on init — no separate load call). |
| `src/index/fulltext_persist.zig:336/381/398` | in-file tests | Deleted with the file. |

No other module imports `fulltext_persist` (the only non-self, non-`fulltext.zig` reference is
the `lib.zig:304` re-export). No `tests/` reference and no dedicated `build.zig` module entry
(it rides on `index/fulltext.zig`/`lib.zig`'s file set). After the edits above, deletion leaves
no dangling references.

---

## Decision 5 — adv_fts scope (`fts/advanced.zig` + `fts/bm25.zig`)

### Evidence

- Only importer of `src/fts/advanced.zig`: `src/lib.zig:473`
  `pub const fts_advanced_stub = @import("fts/advanced.zig");` — a stub re-export, not a live caller.
- `src/fts/advanced.zig:7` `const bm25 = @import("bm25.zig");` — `bm25.zig` is imported ONLY by `advanced.zig` (no other importer in `src/`).
- Feature-flag gated: `advanced.zig:18` `return &flags_mod.global().adv_fts;`, flag declared at `src/util/feature_flags.zig:51` `adv_fts: Flag = Flag.init("GEODE_ENABLE_ADVANCED_FTS")` (off unless the env var is set).
- Tests/benches only otherwise: `tests/e2e_fts_advanced.zig` + `tests/benchmark_fts_*` (dedicated test target, build.zig:3716-3718).
- The live CREATE INDEX path — `ast.IndexType.fulltext` → `execution.zig:1452` → `graph_storage_adapter.getFulltextIndex` (1269) / `initFtsForGraph` (3881) → `src/index/fulltext.zig` (imported at `graph_storage_adapter.zig:19`) — never touches `fts/advanced.zig` or `fts/bm25.zig`. The optimizer's "BM25-enhanced cost estimation" (index_optimizer.zig:452-458) is a cost heuristic, not a call into `fts/bm25.zig`.

### DECISION 5

**`src/fts/advanced.zig` and `src/fts/bm25.zig` are OUT of scope and can be left untouched.**
They are a flag-gated (`GEODE_ENABLE_ADVANCED_FTS`, off by default), self-contained
`AdvancedSearch`/BM25 subsystem reachable only through the `lib.zig:473 fts_advanced_stub`
re-export and their own test/bench targets — NOT through `CREATE INDEX … USING fulltext`, NOT
through `getFulltextIndex`/`initFtsForGraph`, NOT through the match loop. The migration touches
only the live `FullTextIndex` path; `adv_fts` is unaffected. (Note: `fts_storage` provides its
own BM25 scoring via `TermIterator.Match.score`, so these may become redundant later — out of
scope for A0.)

---

## A1 build-wiring — `timeseries_storage_lib` import sites & best place to add `fts_storage`

### Evidence — every `timeseries_storage_lib` reference in build.zig

Dependency + module handle:

- `build.zig:582` `const timeseries_storage_dep = b.dependency("timeseries_storage", .{ .target = target, .optimize = optimize });`
- `build.zig:583` `const timeseries_storage_ext_mod = timeseries_storage_dep.module("timeseries_storage");`

Per-target `<target>.addImport("timeseries_storage_lib", timeseries_storage_ext_mod)` — **11
explicit call sites** (every consumer wired INDIVIDUALLY; there is no byRoot fan-out for this lib):

| build.zig line | Target / module receiving the import |
|---|---|
| `746` | `root_mod` (the geode library root module — `src/lib.zig`) |
| `807` | `geode_exe.root_module` (main `geode` executable) |
| `964` | `gql_exe.root_module` (gql executable) |
| `1029` | `exe_unit_tests.root_module` (main unit tests) |
| `1036` | `gql_unit_tests.root_module` (gql unit tests) |
| `1522` | `graph_store_unit_tests.root_module` (graph-store unit tests) |
| `1935` | `ts_gql_mod` (timeseries gql_functions module) |
| `1939` | `timeseries_wrapper_mod` (the `src/timeseries/timeseries.zig` wrapper module) |
| `1948` | `e2e_ts_tests.root_module` (timeseries e2e tests) |
| `1956` | `ts_store_tests.root_module` (timeseries store tests) |
| `3078` | `merge_bench_gs_mod` (merge benchmark graph-store module) |

(`graph_storage` and `advanced_types` follow the same explicit per-target idiom, e.g.
`advanced_types_lib` at build.zig:742, 803, 1520, 3076.)

### `addImportToModulesByRoot` — what it covers

A real helper `fn addImportToModulesByRoot(...)` exists (build.zig:47-78; recursive inner
`addImportToModulesByRootInner` at :60 walks each owner module's import subtree with a `seen`
dedup `AutoHashMap(*std.Build.Module, void)` and calls `addImport` on every reachable module).
It is invoked **once**, at build.zig:361, for the shared/centralized module group — NOT for
`timeseries_storage_lib`. So there is **no single one-liner** that already fans the storage-module
group; timeseries_storage is deliberately the explicit-11-sites pattern, and fts must mirror it.

### A1 DECISION — how to add `fts_storage`

**Mirror `timeseries_storage` exactly (explicit per-target), not `addImportToModulesByRoot`.**

1. `build.zig.zon`: add the dependency next to `timeseries_storage` (build.zig.zon:396-399). The
   repo pins siblings by **git URL + hash**, NOT `.path`:

   ```zig
   .fts_storage = .{
       .url = "git+https://gitlab.com/devnw/zig/fts-storage.git#<commit-sha>",
       .hash = "<zig-fetch-computed-hash>",
   },
   ```

   Run `zig fetch --save=fts_storage git+https://.../fts-storage.git#<sha>` to populate the hash
   (the local checkout at `/data/home/benji/src/devnw/zig/fts-storage` is the source to
   publish/pin). A `.path` override is acceptable only for local dev; the committed form is the
   git URL like every sibling.
2. `build.zig` ~582-583, resolve once (mirroring timeseries):

   ```zig
   const fts_storage_dep = b.dependency("fts_storage", .{ .target = target, .optimize = optimize });
   const fts_storage_ext_mod = fts_storage_dep.module("fts_storage");
   ```

3. Add `<target>.addImport("fts_storage_lib", fts_storage_ext_mod);` at the SAME set of targets
   that get `timeseries_storage_lib` and will reach the FTS adapter — at minimum the ones
   compiling `src/storage/graph_storage_adapter.zig` and `src/eval.zig`: **`root_mod` (beside 746),
   `geode_exe.root_module` (807), `gql_exe.root_module` (964), `exe_unit_tests.root_module` (1029),
   `gql_unit_tests.root_module` (1036), `graph_store_unit_tests.root_module` (1522)**, plus any new
   FTS adapter test target. Use the import name consistently in the adapter's `@import` (the repo
   convention is the `_lib` suffix, e.g. `@import("timeseries_storage_lib")` at
   `src/timeseries/timeseries.zig:20`). The existing `e2e_fts_advanced` test target
   (build.zig:3716-3718) covers `src/fts/*` only and does not need it unless rewritten against
   `fts_storage`.

---

## Summary of decisions

1. **std.Io:** borrow the process-global `std.Io.Threaded.global_single_threaded.io()` (already
   used by the FTS path at `graph_storage_adapter.zig:3896`); single-threaded is fine because we
   use synchronous `flush`, never `flushAsync`. Static lifetime; wrapper borrows, never owns.
2. **Engine granularity / dir scheme:** one `fts_storage.Engine` per named index under
   `{graph_dir}/fts/<index_name>/` (refines today's single `{graph_dir}/fts`); `doc_id == node id`
   (u64 identity); multiple properties on one engine via `TermPosting.field` tags.
3. **eval.zig seam:** add `evalFulltextFunction(...)` directly after the timeseries dispatch at
   `eval.zig:921` (sibling of `evalTimeseriesFunction`, eval.zig:3825), resolving the engine via
   `graph_store.getGlobalAdapter().getFulltextIndex(index_name)` and querying via `TermIterator`
   (NO `Engine.search` exists); return a `Value` list of `{node_id, score}` records. Do not
   reroute `CONTAINS`.
4. **fulltext_persist.zig:** safe to delete, but only together with the cut-over to
   `fts_storage.Engine` — it is currently LIVE (called at `graph_storage_adapter.zig:769` and
   `:3908`, re-exported at `lib.zig:304`, imported at `fulltext.zig:329/336`). The 6-row
   delete-safety table above lists every reference to remove/rewire.
5. **adv_fts:** `src/fts/advanced.zig` + `src/fts/bm25.zig` are out of scope, left untouched
   (flag-gated stub + test/bench only, not on the live CREATE INDEX path).
