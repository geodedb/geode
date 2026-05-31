# A3 Change-Map — Integrate geode FTS with `fts_storage_adapter`

READ-ONLY analysis. No code edited. Goal of A3: make geode's full-text search
use `src/storage/fts_storage_adapter.zig` (the `FtsStorageAdapter` registry of
per-named-index `fts_storage.Engine`s) for durability, **keeping geode's
tokenizer**, and **deleting the now-redundant bespoke persistence**
(`src/index/fulltext_persist.zig` + the in-memory inverted index in
`fulltext.zig`). `fts_storage` owns WAL + segments + manifest.

Repo: `/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode`

---

## 1. `src/index/fulltext.zig` full anatomy (375 lines)

Top of file:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
```

Single public type: `pub const FullTextIndex = struct { ... }` (line 5).

### Fields (lines 6-9)

```zig
allocator: Allocator,
documents: std.AutoHashMap(u64, Document),
inverted_index: std.StringHashMap(PostingList),
stopwords: std.StringHashMap(void),
```

### Nested struct definitions (all `pub`)

- **`Document`** (11-16): `{ id: u64, content: []const u8, tokens: []Token, vector: ?[]f32 }`
- **`Token`** (18-23): `{ text: []const u8, position: usize, offset: usize, length: usize }`
- **`PostingList`** (25-29): `{ term: []const u8, documents: []PostingEntry, idf: f32 }`
- **`PostingEntry`** (31-36): `{ doc_id: u64, positions: []usize, tf: f32, tf_idf: f32 }`
- **`SearchResult`** (38-42): `{ doc_id: u64, score: f32, highlights: []Highlight }`
- **`Highlight`** (44-48): `{ offset: usize, length: usize, term: []const u8 }` — **never populated**; `search` always emits `.highlights = &[_]Highlight{}` (line 160).

### `init` / `deinit`

```zig
pub fn init(allocator: Allocator) !FullTextIndex   // line 50
```

**Takes allocator ONLY — no dir, no `std.Io`.** Builds the three hash maps and
seeds a 24-word English stopword set (lines 59-63):
`a an and are as at be by for from has he in is it its of on that the to was will with`.

```zig
pub fn deinit(self: *FullTextIndex) void           // line 72
```

Frees each document's `content`, `tokens`, `vector`; frees each posting list's
`term`, per-entry `positions`, `documents`; deinits all three maps.

### Tokenizer (THE PIECE TO PRESERVE/EXTRACT)

```zig
fn tokenize(self: *FullTextIndex, text: []const u8) ![]Token   // line 177  (PRIVATE)
```

Pure-ASCII word splitter. Skips `std.ascii.isWhitespace`; collects runs of
`std.ascii.isAlphanumeric(c) or c == '_'`. Emits a `Token{ text=slice-into-input,
position=running index, offset=start byte, length }` per word. Caller owns slice
(`toOwnedSlice`). **`text` slices point INTO the input buffer** — they are NOT
copies (relevant for lifetime when feeding the adapter).

```zig
fn normalize(self: *FullTextIndex, text: []const u8) ![]u8     // line 204  (PRIVATE)
```

Quoted in full:

```zig
fn normalize(self: *FullTextIndex, text: []const u8) ![]u8 {
    // Unicode-aware normalization: NFC then case fold (minimal subset implementation)
    // CANARY: REQ=REQ-GQL-UNICODE-007; ...
    const unicode = @import("../unicode/geode_unicode.zig");
    const nfc = try unicode.nfcNormalize(self.allocator, text);
    defer self.allocator.free(nfc);
    const folded = try unicode.foldCase(self.allocator, nfc);
    return folded; // caller owns
}
```

The only external dependency of the tokenizer/normalizer is
`../unicode/geode_unicode.zig` (`nfcNormalize`, `foldCase`). Stopword test
uses the RAW token text (`self.stopwords.contains(token.text)`) — i.e. stopword
filtering happens BEFORE normalization in both `indexDocument` and `search`.
Neither `tokenize` nor `normalize` touches `documents`/`inverted_index`, so both
are mechanically liftable into a standalone module that takes only an allocator.

### `indexDocument`

```zig
pub fn indexDocument(self: *FullTextIndex, doc_id: u64, content: []const u8) !void  // line 243
```

Tokenizes `content`; stores a `Document` (dupes `content`, owns `tokens`).
Builds `term_positions: StringHashMap(ArrayList(usize))` skipping stopwords,
normalizing each token (NFC+fold). For each term: computes `tf = positions.len /
tokens.len`, appends a `PostingEntry` to that term's `PostingList` (grow-by-one
realloc), keyed by an owned dupe of the term. Finally `updateIdfScores()`.
**This is exactly the per-document term/positions aggregation the adapter needs**
— it already produces `(normalized term -> []position)` which maps 1:1 to
`fts.TermPosting{ term, positions, field=null }` (positions are `usize` here vs
`u32` in `TermPosting` — a cast is required).

### `search`

```zig
pub fn search(self: *FullTextIndex, query: []const u8, max_results: usize) ![]SearchResult  // line 97
```

Tokenizes query, drops stopwords, normalizes, builds per-query-term frequency
map, then BM25(+k3 query-term saturation; k1=1.2, b=0.75, k3=7.0) over the
in-memory inverted index. Returns `[]SearchResult` sorted by score desc, top
`max_results`. `highlights` always empty.
**NOTE:** returns a slice into the internal `results.items` ArrayList (line 173
`return results.items[0..n];`) — the backing ArrayList is leaked / caller cannot
free cleanly (test at gsa:5829 comments on this leak). The adapter's `search`
returns owned `[]Hit{node_id,score}` the caller frees — cleaner contract.

### `removeDocument`

```zig
pub fn removeDocument(self: *FullTextIndex, doc_id: u64) !void   // line 341
```

Removes the doc; rebuilds every posting list filtering out `doc_id` (frees its
positions); `updateIdfScores()`. Maps to adapter `deleteNode(name, doc_id)`.

### Private helpers

- `updateIdfScores(self) !void` (214) — recompute idf + tf_idf across all posting lists.
- `getAverageDocumentLength(self) !f32` (229) — avg `tokens.len`.

### Persistence delegation

```zig
pub fn saveToDisk(self: *const FullTextIndex, dir_path: []const u8) !void   // line 328
    -> @import("fulltext_persist.zig").save(self, dir_path)   // writes {dir_path}/fulltext.idx
pub fn loadFromDisk(allocator: Allocator, dir_path: []const u8) !FullTextIndex  // line 335
    -> @import("fulltext_persist.zig").load(allocator, dir_path) // reads {dir_path}/fulltext.idx, fresh index if missing
```

### Complete `pub` surface

`FullTextIndex` (type) + nested types `Document, Token, PostingList,
PostingEntry, SearchResult, Highlight` + methods `init, deinit, search,
indexDocument, saveToDisk, loadFromDisk, removeDocument`. (`tokenize, normalize,
updateIdfScores, getAverageDocumentLength` are private.)

---

## 2. `src/unicode/geode_unicode.zig` import weight (183 lines)

**Only `@import` in the entire file: `const std = @import("std");` (line 1).**
No geode internals, no `strings`, no `advanced_types`, no `lib.zig`. Public API:

- `DecompEntry` (struct), `generated.decomp` (comptime table, 2 entries)
- `simpleDecompose(cp, *std.ArrayList(u32)) !void`
- `nfcNormalize(alloc, []const u8) ![]u8`  ← used by tokenizer
- `foldCase(alloc, []const u8) ![]u8`        ← used by tokenizer
- `utf8ToUtf16Alloc`, `utf16ToUtf8Alloc`, `wtf8LossyToUtf8Alloc` (std.unicode bridges)

**VERDICT: CHEAP-EXTRACTABLE.** The tokenizer + normalizer depend only on
`std` + this std-only `geode_unicode.zig`. A new `src/index/fts_tokenizer.zig`
importing just `std` and `../unicode/geode_unicode.zig` can be compiled & tested
by a small dedicated build step (the same cheap-isolation pattern A2 used for
`test-fts-storage-adapter`), with **no** need to ride the full 30-min geode
build to validate tokenizer correctness.

---

## 3. `src/storage/graph_storage_adapter.zig` FTS call sites

Module-level import (line 19): `const fulltext = @import("../index/fulltext.zig");`

### `ManagedGraph` FTS fields (650-654)

```zig
    /// Per-graph full-text search index persisting to `{graph_dir}/fts/`.
    /// May be null if FTS init failed (soft failure — graph still usable).
    fts_index: ?*fulltext.FullTextIndex = null,
    /// Owned path to the FTS subdirectory (needed for saveToDisk on close).
    fts_dir: ?[]const u8 = null,
```

### `ManagedGraph.deinit` FTS teardown (766-780)

```zig
    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        if (self.fts_index) |fts| {
            if (self.fts_dir) |dir| {
                fts.saveToDisk(dir) catch |err| {
                    log.warn("failed to persist per-graph FTS index: {}", .{err});
                };
            }
            fts.deinit();
            allocator.destroy(fts);
            self.fts_index = null;
        }
        if (self.fts_dir) |dir| {
            allocator.free(dir);
            self.fts_dir = null;
        }
        // ... ts_store, audit_logger teardown follows ...
    }
```

### `getFulltextIndex` (1269-1275)

```zig
    pub fn getFulltextIndex(self: *StorageAdapter, name: []const u8) ?*fulltext.FullTextIndex {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return if (mg) |m| m.fts_index else null;
    }
```

### `FtsInitResult` + `initFtsForGraph` (3874-3927)

```zig
    const FtsInitResult = struct {
        index: *fulltext.FullTextIndex,
        dir: []const u8,
    };

    fn initFtsForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, load_existing: bool) ?FtsInitResult {
        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch ... return null;
        defer allocator.free(graph_dir);
        const fts_dir = std.fmt.allocPrint(allocator, "{s}/fts", .{graph_dir}) catch ... return null;
        errdefer allocator.free(fts_dir);
        // Ensure the FTS subdirectory exists.  *** confirms io source ***
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), fts_dir) catch ... return null;   // line 3896
        const idx = allocator.create(fulltext.FullTextIndex) catch ... return null;
        errdefer allocator.destroy(idx);
        if (load_existing) {
            idx.* = fulltext.FullTextIndex.loadFromDisk(allocator, fts_dir) catch |err| {
                // fall back to fresh index
                idx.* = fulltext.FullTextIndex.init(allocator) catch ... { allocator.destroy(idx); return null; };
                return .{ .index = idx, .dir = fts_dir };
            };
        } else {
            idx.* = fulltext.FullTextIndex.init(allocator) catch ... { allocator.destroy(idx); return null; };
        }
        return .{ .index = idx, .dir = fts_dir };
    }
```

**Confirmed:** `initFtsForGraph` already obtains its `std.Io` via
`std.Io.Threaded.global_single_threaded.io()` (line 3896) and builds the dir as
`{graph_dir}/fts` (line 3889) — **exactly the `base_path`/`base_dir` the
adapter's `init(allocator, io, base_dir, base_path)` expects.** `getFulltextIndex`
(1270) and every other `StorageAdapter` method use the same `io()` accessor.

### Callers of `initFtsForGraph` (assign to `mg.fts_index` / `mg.fts_dir`)

- `createGraphLocked` (3976-3979): `if (initFtsForGraph(..., false)) |r| { mg.fts_index = r.index; mg.fts_dir = r.dir; }`
- `loadGraphLocked` (4059-4062): `if (initFtsForGraph(..., true)) |r| { mg.fts_index = r.index; mg.fts_dir = r.dir; }`

### In-file tests touching FTS internals (5780-5935)

- 5791-5792: `mg.fts_index != null`, `mg.fts_dir != null`
- 5795-5797: `adapter.getFulltextIndex("fts_graph")` == `mg.fts_index.?`
- 5800: `mg.fts_index.?.indexDocument(42, "...")`
- 5806-5809: rebuilds `{graph_dir}/fts` path, opens it via `std.Io.Threaded.global_single_threaded.io()`
- 5825-5830: `mg.fts_index != null`, comments on `FullTextIndex.search()` ArrayList leak, `mg.fts_index.?.documents.count() > 0`
- 5904: `mg.fts_index != null`
- 5935: `adapter.getFulltextIndex("__geode_security") == null`

These in-file tests must be updated by A3 (they reach into `.documents.count()`
and call `.indexDocument` directly).

---

## 4. Every caller of the FullTextIndex public API / fulltext_persist

| File | Lines | Reference | Action for A3 |
|---|---|---|---|
| `src/index/fulltext.zig` | 328-338 | `saveToDisk`/`loadFromDisk` delegate to `fulltext_persist` | Persistence removed (durability moves to adapter). |
| `src/index/fulltext_persist.zig` | whole file (417 ln) | `save`/`load` + GFTS format + 3 tests | **DELETE** entirely. |
| `src/storage/graph_storage_adapter.zig` | 19, 650-654, 766-780, 1269-1275, 3874-3927, 3976-3979, 4059-4062, 5780-5935 | full FTS lifecycle + tests | Rewire (see §6). |
| `src/lib.zig` | 42 | `pub const fulltext = @import("index/fulltext.zig");` | Keep re-export (path stays valid under Option Y). |
| `tests/test_fulltext_bm25.zig` | 4,7,16,17,20 | `FullTextIndex.init`, `.indexDocument`, `.search` | Keep working under Option Y (public API preserved). |
| `tests/test_fulltext_bm25_integration.zig` | 4,7,17,22,26 | same | Keep working under Option Y. |
| `tests/canary_unicode_fts.zig` | comments only (3,5) | simulates the normalize pipeline; does NOT call `FullTextIndex` | None — but verify the normalize behavior it asserts still matches the extracted tokenizer. |
| **`src/index/index_manager.zig`** | 41,67,118,207,268-272,399,497-507,848,1136 | **REAL caller**: stores `fulltext_indexes: StringHashMap(fulltext.FullTextIndex)` (BY VALUE, not pointer), `createFullTextIndex` does `FullTextIndex.init(self.allocator)` + `.put(name, ft_index)`, deinits each, and `index.*.indexDocument(...)` at 1136 | **MUST update under Option Y too.** The by-VALUE `StringHashMap(FullTextIndex)` storage (line 67/207) breaks if the facade holds a `*FtsStorageAdapter` + open `std.Io.Dir` (non-trivially copyable / each needs its own dir). See §6 note. |
| `tests/integration/test_large_social_network.zig` | 60 | `index_mgr.createFullTextIndex("post_content_idx", "Post", &.{"content"})` | Works as long as `IndexManager.createFullTextIndex` still compiles after the facade change. |
| `src/server/index_optimizer.zig` | many (344,452,…2371) | uses an **`IndexType.fulltext` enum + BM25 cost model only**; NEVER touches `FullTextIndex` the type | None — pure cost-estimation, no FTS index handle. |

**`src/lib.zig` line 304** also re-exports `fulltext_persist`
(`pub const fulltext_persist = @import("index/fulltext_persist.zig");`). When
A3 deletes `fulltext_persist.zig`, **this line MUST be removed** or the build
breaks. (Line 303 `pub const fulltext = ...` stays.)

**`saveToDisk`/`loadFromDisk` disambiguation:**

- **FTS** ones live in `src/index/fulltext.zig` (328/335) → routed to `fulltext_persist.zig`.
- **Timeseries** `saveToDisk`/`loadFromDisk` live in `src/timeseries/timeseries.zig` (+ a call in `src/server/main.zig`) — **UNRELATED, do not touch.**
- `graph_storage_adapter.zig`'s only `saveToDisk` call is the FTS one at deinit:769.

No external code calls `fulltext_persist` directly except `fulltext.zig` itself
(and the persist file's own tests). Safe to delete with `fulltext_persist`.

---

## 5. build.zig — module ownership & `fts_storage_lib` availability

`build.zig` (5610 ln). The external dep + module are resolved once:

```zig
const fts_storage_dep = b.dependency("fts_storage", ...);            // line 584
const fts_storage_ext_mod = fts_storage_dep.module("fts_storage");   // line 585
```

**There is NO `fts_storage_module_targets` array.** A1 wired the import via
~14 explicit `addImport("fts_storage_lib", fts_storage_ext_mod)` calls, one per
module/test target. The geode-source-graph ones that matter for A3:

| build.zig line | Target module | Compiles fulltext.zig + graph_storage_adapter.zig? |
|---|---|---|
| **774** | `root_mod` (`src/lib.zig`) | **YES** — this is the geode library module; both files live in its source graph (lib.zig:42 imports `index/fulltext.zig`; lib.zig also reaches `storage/graph_storage_adapter.zig`). |
| 836 | `geode_exe.root_module` (`src/unified_entry.zig`, imports `root_mod` as `geode`) | YES (transitively via `geode`) |
| 994 | `gql_exe.root_module` | YES (via `geode`) |
| 1060 | `exe_unit_tests.root_module` | YES |
| 1068 | `gql_unit_tests.root_module` | YES |
| 1555 | `graph_store_unit_tests.root_module` | YES |
| 591 / 605-607 | `fts_smoke_tests` / `fts_adapter_*` | isolation steps for the adapter |
| 1969-1993, 3116 | timeseries / bench modules | (A1 also attached here) |

Note: `root_mod` does NOT have a `.target`-array attach; it gets the import
directly at **build.zig:774** (`root_mod.addImport("fts_storage_lib",
fts_storage_ext_mod);`). The generic recursive helper
`addImportToModulesByRoot` (lines 47-82) exists for QUIC's serial-path wiring
(used once at 361) — it is NOT used for fts_storage, but it confirms the pattern
that an import added to a module propagates to every file in that module's
source tree.

**CONFIRMED: A3 needs NO new `build.zig` `addImport` for the adapter.** Because
`src/storage/fts_storage_adapter.zig` does `@import("fts_storage_lib")` and
compiles **as part of** whatever module `@import`s it (i.e.
`graph_storage_adapter.zig`'s module = `root_mod` and its consumers), and
`root_mod` already carries `fts_storage_lib` from A1 (line 774), the adapter is
reachable the moment `graph_storage_adapter.zig` adds
`const fts_adapter = @import("fts_storage_adapter.zig");`. Same for `fulltext.zig`
importing the adapter under Option Y — it is in `root_mod` too, which has the
import. The fulltext.zig facade additionally needs nothing new: `geode_unicode`
is reached via relative `@import` (std-only, no module registration needed).

The only build.zig consideration: if A3 adds a NEW cheap test step for
`src/index/fts_tokenizer.zig`, that step's module needs only `std` +
`../unicode/geode_unicode.zig` (relative import, no registration) — it does
**not** need `fts_storage_lib` (the tokenizer doesn't touch the adapter). So
even that optional test step is free of the external dep.

---

## 6. RECOMMENDED A3 EDIT PLAN — **Option Y (facade), with adapter-backed internals**

### Recommendation: **OPTION Y — keep `FullTextIndex` as a thin facade** that

internally owns an `FtsStorageAdapter` + extracted tokenizer, preserving its
public method surface; delete only `fulltext_persist.zig`.

### Rationale

1. **Least call-site churn.** `graph_storage_adapter.zig` keeps
   `fts_index: ?*fulltext.FullTextIndex`, `getFulltextIndex` returns the same
   type, `initFtsForGraph` keeps its `FtsInitResult{index,dir}` shape, the two
   `mg.fts_index = ...` assignments are untouched, and `lib.zig:42` +
   **all four `tests/test_fulltext_*` / `canary_unicode_fts` tests stay green
   without edits** (they call `init(allocator)`, `indexDocument`, `search`).
   Option X would force rewriting every one of those call sites and tests to a
   new `?*FtsStorageAdapter` + `[]Hit` shape — large churn for no functional win
   at the A3 stage.
2. **Durability correctly migrates.** The facade's `init` opens a per-instance
   `FtsStorageAdapter` over `{graph_dir}/fts` (the dir already built at
   gsa:3889/3896) with a single internal index name (e.g. `"_default"`).
   `indexDocument` tokenizes (extracted tokenizer) → `[]fts.TermPosting` →
   `adapter.indexNode`. `search` → `adapter.search` → map `[]Hit` to
   `[]SearchResult` (score carried; `highlights` empty as today). `removeDocument`
   → `adapter.deleteNode`. `saveToDisk` becomes `adapter.flush(name)`;
   `loadFromDisk` becomes "open adapter + `openIndex`/`createIndex`" (WAL replay
   is automatic in the engine). `fulltext_persist.zig` is deleted — the GFTS file
   format is fully superseded by the engine's WAL+segments+manifest.
3. **A4 (CREATE INDEX → multiple named indexes per graph) is still cleanly
   reachable.** The adapter registry natively supports multiple named indexes.
   Option Y can expose the underlying adapter for A4 either by (a) a new
   `pub fn adapter(self) *FtsStorageAdapter` accessor on the facade, or (b) A4
   promoting `ManagedGraph` to hold the `*FtsStorageAdapter` directly while the
   facade remains for the single legacy default index. Either way A3 does not
   block A4 — and A3 avoids the premature, churny type-swap that Option X front-
   loads before CREATE INDEX dispatch even exists.

   (If the team prefers to do the type-swap once rather than twice, Option X is
   the long-term shape — but A3's stated goal is *minimal call-site churn* and
   *delete the bespoke persistence*, both of which Option Y satisfies while
   leaving the A4 registry exposure as a tiny additive accessor.)

### Exact edit list

**CREATE**

1. `src/index/fts_tokenizer.zig` (new, std + `../unicode/geode_unicode.zig` only):
   - Move `tokenize`/`normalize` logic here as free functions, e.g.
     `pub fn tokenize(alloc, text) ![]Token` and
     `pub fn normalize(alloc, text) ![]u8`, plus the 24-word `stopwords` set
     and a `pub fn isStopword(word) bool` (or expose the set). Keep the
     stopword-before-normalize ordering. Add a
     `pub fn termPostings(alloc, content) ![]fts.TermPosting` convenience that
     produces normalized-term → `[]u32` positions (cast `usize`→`u32`) ready for
     `adapter.indexNode` — this is the single seam fulltext.zig and A4 reuse.
   - Add a cheap dedicated build/test step for it (no `fts_storage_lib` needed;
     only the std-only `geode_unicode`). Mirrors A2's `test-fts-storage-adapter`
     isolation pattern.

**MODIFY**
1b. `src/index/index_manager.zig` — the by-VALUE `StringHashMap(FullTextIndex)`
   (lines 67, 207) is the one real wrinkle for Option Y. A facade holding a
   `*FtsStorageAdapter` + an open `std.Io.Dir` is NOT safely stored by value in
   a HashMap (the map may move entries; the adapter holds self-pointers /
   per-index dirs). Two clean fixes, both small:

- (preferred) change the map to `StringHashMap(*fulltext.FullTextIndex)` and
     heap-allocate each facade in `createFullTextIndex` (line 506-507), updating
     the deinit loop (268-272) and the `index.*.indexDocument` call (1136)
     accordingly; OR
- keep the facade pointer-free by having `init(allocator)` lazily own a
     process-tmp adapter dir, and make the struct trivially movable (store
     `?*FtsStorageAdapter` + an owned path; open the dir inside the adapter, not
     in the facade). The first option is cleaner and matches gsa's
     `?*FullTextIndex` pointer convention.
   This is in-scope for A3 because `index_manager` is a live `FullTextIndex`
   consumer; it cannot be skipped even though gsa is the headline call site.

2. `src/index/fulltext.zig` — convert `FullTextIndex` to a facade:
   - Replace fields `documents`/`inverted_index`/`stopwords` with
     `adapter: *@import("../storage/fts_storage_adapter.zig").FtsStorageAdapter`,
     a held `base_dir: std.Io.Dir`, an owned `index_name` (e.g. `"_default"`),
     and the `io`.
   - Keep nested types `SearchResult`/`Highlight` for the public return shape.
     `Document`/`Token`/`PostingList`/`PostingEntry` are now only needed by
     deleted persistence — drop or keep `Token` re-export from the tokenizer if
     `canary_unicode_fts.zig` references it (it references `FullTextIndex` +
     `unicode`, not `Token`, so they can be dropped).
   - `init(allocator)` — **signature must change** to also receive `io` + the
     `{graph_dir}/fts` dir/path so it can build the adapter, OR keep
     `init(allocator)` for the standalone tests by lazily opening a temp/owned
     dir. **Decision:** add `initInDir(allocator, io, base_dir, base_path)` for
     gsa, and keep a convenience `init(allocator)` for the unit tests that opens
     a process-tmp dir (so `tests/test_fulltext_bm25*.zig` keep their
     `FullTextIndex.init(allocator)` calls). This is the only API addition.
   - `indexDocument` → `fts_tokenizer.termPostings(...)` then
     `self.adapter.indexNode(self.index_name, doc_id, postings)`.
   - `search(query, max_results)` → tokenize/normalize query terms via tokenizer,
     call `self.adapter.search(self.index_name, alloc, term, max_results)` per
     term, merge by node_id summing scores, sort desc, map to `[]SearchResult`
     (owned; fixes the current ArrayList-leak in §1).
   - `removeDocument` → `self.adapter.deleteNode(self.index_name, doc_id)`.
   - `saveToDisk(dir)` → `self.adapter.flush(self.index_name)` (ignore `dir` or
     assert it matches base_path).
   - `loadFromDisk(allocator, dir)` → open adapter + `openIndex` (fallback
     `createIndex`); WAL replay automatic.
   - Delete `tokenize`/`normalize`/`updateIdfScores`/`getAverageDocumentLength`
     (moved/obsolete).

3. `src/storage/graph_storage_adapter.zig`:
   - Add `const fts_adapter = @import("fts_storage_adapter.zig");` near line 19
     (sibling import; module already has `fts_storage_lib` — see §5).
   - `initFtsForGraph` (3881-3927): replace the `loadFromDisk`/`init` create-vs-
     load branch with `FullTextIndex.initInDir(allocator, io, base_dir,
     base_path)` where `base_dir` is the opened `{graph_dir}/fts` and
     `io = std.Io.Threaded.global_single_threaded.io()` (already used at 3896).
     Keep the soft-failure `return null` semantics and the `FtsInitResult{index,
     dir}` shape. NOTE: adapter requires an **open `std.Io.Dir`** for base_dir —
     replace bare `createDirPath` with `createDirPathOpen` (or `createDirPath` +
     `openDir`) so the facade can own/close it; store the open dir on the facade,
     keep `fts_dir` (the path string) for diagnostics + free.
   - `ManagedGraph.deinit` (766-780): `fts.saveToDisk(dir)` → keep (now flush);
     `fts.deinit()` (facade closes adapter, which flushes + closes per-index
     dirs; the facade must close `base_dir` AFTER `adapter.deinit` per the
     adapter contract at fts_storage_adapter.zig:103-104). `allocator.free(dir)`
     unchanged.
   - `getFulltextIndex` (1269-1275): unchanged (still returns
     `?*fulltext.FullTextIndex`).
   - `createGraphLocked` (3976-3979) / `loadGraphLocked` (4059-4062): unchanged.
   - In-file tests (5780-5935): `mg.fts_index.?.documents.count()` (5830) no
     longer exists — replace with a `search`-based assertion (e.g.
     `mg.fts_index.?.search("fox", 10)` returns ≥1 hit). The direct
     `indexDocument` (5800) call stays valid. Add `try mg.fts_index.?.flush()`
     (or saveToDisk) before reopening if a restart-roundtrip is asserted.

**DELETE**
4. `src/index/fulltext_persist.zig` (whole file, 417 ln) — its GFTS on-disk
   format and 3 tests are fully superseded by the engine WAL/segments. Confirm
   no remaining `@import("fulltext_persist.zig")` after fulltext.zig edits
   (currently only fulltext.zig:329/336 reference it).

**build.zig**
5. No `addImport` change required for the adapter (§5). Optionally register the
   new `fts_tokenizer.zig` cheap test step (std + geode_unicode only).

### Net call-site churn (Option Y)

- gsa: ~3 functions touched (`initFtsForGraph` body, `deinit` flush/close
  ordering, in-file test assertions @ 5830) + 1 import line.
- fulltext.zig: internal rewrite, public surface preserved (one additive
  `initInDir`; existing `init(allocator)` kept for the unit tests by lazily
  owning a tmp adapter dir).
- index_manager.zig: small — switch `StringHashMap(FullTextIndex)` →
  `StringHashMap(*FullTextIndex)` (5 line touches: 67, 207, 268-272, 506-507,
  1136) so the facade is stored by pointer.
- lib.zig: delete line 304 (`fulltext_persist` re-export).
- 1 file deleted (`fulltext_persist.zig`, 417 ln incl. its 3 tests).
- 0 changes to `test_fulltext_bm25.zig` (calls `init(allocator)`/`indexDocument`/
  `search`/`removeDocument` — all preserved), `test_fulltext_bm25_integration.zig`
  (uses its own self-contained `FullTextIndexSimulator`, no geode FTS dep),
  `canary_unicode_fts.zig` (comments only), `index_optimizer.zig` (enum/cost
  model only), `test_large_social_network.zig` (rides `createFullTextIndex`).

vs Option X which additionally rewrites `getFulltextIndex` return type, both
`mg.fts_index` assignment sites, every in-file gsa test, AND `index_manager`'s
entire FullTextIndex usage to the `*FtsStorageAdapter`/`[]Hit` shape — strictly
more churn for the same A3 deliverable.

### Open question for A3 implementer (init signature)

`FullTextIndex.init(allocator)` (today's signature) cannot build a
`FtsStorageAdapter` without an `io` + an open `std.Io.Dir`. Two resolutions:
(a) keep `init(allocator)` working for unit tests by having it open a unique
process-tmp dir via `std.Io.Threaded.global_single_threaded.io()` (same io gsa
uses) and own/close it in `deinit`; (b) add `initInDir(allocator, io, base_dir,
base_path)` for gsa/index_manager and have `init(allocator)` delegate to it
with a tmp dir. Either keeps the 11 `test_fulltext_bm25.zig` call sites green.
