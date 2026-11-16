# Full-Text Search (fts-storage-backed)

> **Geode extension.** The full-text-search GQL surface (`CREATE INDEX … USING
> fulltext`, `CALL geode.fts.search(…)`) is a native Geode extension. It is
> ISO-GQL-compliant in form: it uses ISO GQL's `CALL` procedure (not a scalar
> function, and not Cypher's `UNWIND … YIELD`).

**Status:** Implemented — backed by the external **`fts-storage`** LSM library (PRIMARY backing store)
**Dependency:** `.fts_storage` v0.1.1 in `build.zig.zon` (commit `908c1f54`)
**Modules:**

- `src/storage/fts_storage_adapter.zig` — per-graph registry of `fts_storage.Engine`s
- `src/index/fulltext.zig` — `FullTextIndex` facade (delegates to the adapter)
- `src/index/fts_tokenizer.zig` — tokenizer

Geode provides production-grade, BM25-ranked full-text search over node
properties. Indexes are **durable on disk** and surfaced as a native GQL
extension.

---

## Overview

Each fulltext index is its own `fts_storage.Engine` — an LSM store with its own
WAL, on-disk segments, and manifest — living under
`{graph_dir}/fts/<index_name>/`. The `FtsStorageAdapter` keeps a per-graph
registry mapping index name → engine. The `FullTextIndex` type in
`src/index/fulltext.zig` is now a thin facade that delegates all add / search /
remove / drop operations to the adapter.

The legacy in-memory inverted index and the bespoke `fulltext_persist.zig`
snapshot layer were **removed** — durability is now the `fts-storage` library's
responsibility (WAL + segments + manifest).

### Key Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| LSM-backed index | ✅ | `fts-storage` Engine per index (WAL + segments + manifest) |
| BM25 ranking | ✅ | `score` column on search results |
| Tokenization | ✅ | `src/index/fts_tokenizer.zig` |
| Durability | ✅ | Survives restart via lazy re-open of on-disk indexes |
| Live maintenance | ✅ | Node create / `SET` / delete keep the index current |
| Backfill | ✅ | `CREATE INDEX … USING fulltext` indexes existing matching nodes |
| Wire protocol | ✅ | `CALL geode.fts.search(…)` rides the generic GQL Execute+rows path over QUIC |
| Phrase search | ✅ | `CALL geode.fts.phrase(…)` — positional adjacency over the persisted postings (GAP-0869) |
| Proximity search | ✅ | `CALL geode.fts.proximity(…)` — NEAR window over persisted token positions (GAP-0869) |
| Highlighting | ✅ (API) | `FullTextIndex.highlight` — byte-accurate offsets against caller-supplied authorized content; no GQL surface yet (see below) |
| Bulk-MERGE auto-index | ✅ | Bulk-MERGE fast path (single-statement and `/*+BATCH*/`) is live-maintained on the connection thread (Task 4, 2026-08-28) — see [Live Maintenance](#live-maintenance) |
| Rebuild / recovery | ✅ | `CALL geode.fts.rebuild(index)` — see [Recovery](#recovery-call-geodeftsrebuild) |

---

## Quick Start

```gql
-- Create a fulltext index on the `body` property of `:Doc` nodes
-- (backfills any existing matching nodes)
CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext;

-- Search the index — returns rows of (node, score)
CALL geode.fts.search('doc_idx', 'quick brown');   -- node id + BM25 score

-- Drop the index when no longer needed (server stays alive)
DROP INDEX doc_idx;
```

You may index multiple properties on a single index: `ON (d.title, d.body)`.

---

## GQL Surface

### `CREATE INDEX … USING fulltext`

```text
CREATE INDEX <name> FOR (n:Label) ON (n.prop[, n.prop2]) USING fulltext;
```

Creates a fulltext index over the named string properties of `:Label` nodes and
**backfills** all existing matching nodes into the index.

### `CALL geode.fts.search`

```text
CALL geode.fts.search('<index>', '<query>'[, <max>]);
```

Returns one row per match with two columns:

- `node` — the matching node's id
- `score` — the BM25 relevance score

The optional third argument caps the number of results. The call is reachable
over the QUIC wire because results ride the generic GQL Execute+rows protocol —
**no client, proto, or transport changes are required** to consume them.

### `CALL geode.fts.phrase` (GAP-0869)

```text
CALL geode.fts.phrase('<index>', '<phrase>'[, <max>]);
```

Exact-adjacency phrase search over the **persisted positional postings**: the
engine stores token-positions per `(term, doc)` (fts-storage `TermPosting`
contract), and a document matches only when the phrase terms occur at
consecutive raw-token ordinals. Stopword gaps are preserved on BOTH sides —
the tokenizer assigns ordinals before stopword removal, so the phrase
`'quick and brown'` matches a document indexed from `quick and brown` even
though `and` is never indexed, while `'quick brown'` does NOT match that
document (the gap is real). Returns `(node, score)` rows; `score` is the sum
of the constituent terms' BM25 scores.

### `CALL geode.fts.proximity` (GAP-0869)

```text
CALL geode.fts.proximity('<index>', '<terms>', <distance>[, <max>]);
```

Order-insensitive NEAR search: a document matches when one occurrence of every
distinct query term can be chosen with `max(pos) - min(pos) <= distance`
(inclusive, in token ordinals), verified against the persisted positions.
Requires at least 2 distinct non-stopword terms (`InvalidArgs` otherwise) and a
non-negative integer `distance`. Returns `(node, score)` rows.

### Highlighting (FTS-layer API; GQL surface is future work)

`FullTextIndex.highlight(allocator, content, query)` in
`src/index/fulltext.zig` maps query-term matches to **byte-accurate**
`{offset, length, term}` ranges inside `content`, using the same index-time
tokenizer pipeline on both sides (this is the host half of the fts-storage
positional highlight contract). It takes the document text as a parameter by
design: **snippet/highlight generation must run AFTER row-level authorization**
(RLS/FLE) — the caller passes only content it was already cleared to read; the
function never fetches document content itself.

There is intentionally NO `CALL geode.fts.highlight(...)` procedure yet: the
procedure dispatcher has no authorized node-content fetch path, so a GQL
highlight surface is deferred until one exists. Consumers retrieve the node by
id (from `geode.fts.search/phrase/proximity`) under their own authorization and
call the API (embedders) or highlight client-side.

**Case-folding caveat (pre-existing pipeline behavior):** term normalization
uses `geode_unicode.foldCase`, a documented minimal subset (see
`tests/test_fts_tokenizer.zig` Case 3) — full Unicode/ASCII case-insensitivity
is not guaranteed for all letters. This applies equally to `search`, `phrase`,
`proximity`, and `highlight`.

### `DROP INDEX`

```text
DROP INDEX <name>;
```

Drops the fulltext index, from a session on the default graph (from
another graph: `USE GRAPH default; DROP INDEX <name>`; a bare `DROP INDEX`
there is refused with 0A000, SONNY-6294). The server stays alive during the
drop: the
`fts-storage` 0.1.1 single-writer thread-check fix
(`EngineConfig.single_writer_thread_check`) makes a cross-worker-thread `DROP`
safe.

---

## Architecture

### Storage Model

```
graph dir
└── fts/
    ├── doc_idx/      ← fts_storage.Engine (WAL + segments + manifest)
    └── other_idx/    ← fts_storage.Engine
```

### Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `FtsStorageAdapter` | `src/storage/fts_storage_adapter.zig` | Per-graph registry of `fts_storage.Engine`s; create / search / drop / live-maintenance |
| `FullTextIndex` | `src/index/fulltext.zig` | Facade — delegates to the adapter |
| `Tokenizer` | `src/index/fts_tokenizer.zig` | Text → terms |
| `fts-storage` (external) | `build.zig.zon` `.fts_storage` v0.1.1 | LSM engine: BM25 ranking, WAL, segments, manifest, durability |

---

## Live Maintenance

After an index exists, ordinary write paths keep it current automatically:

- **Node create** — newly created nodes matching the index label/property are tokenized and indexed (including nodes inserted *after* the index was created). This includes the QUIC write fast path for a single-statement `CREATE (n:L {k: v})` with no RETURN (`executeBulkSimpleCreate`), which indexed nothing before SONNY-6591.
- **`SET`** — updating an indexed property re-indexes the node. A `SET`
  that replaces a non-empty indexed string (with another value, a
  non-string, or by `SET n = {map}` dropping or changing it) queues every
  covering index for a rebuild at the end of the statement, as `REMOVE
  n.prop` does, so the node is no longer found by the old words
  (SONNY-6421). Cost: one O(nodes of the label) rebuild per index per
  statement that replaces indexed text.
- **`SET n:L`** — a node given a label joins the label's fulltext (and
  vector) indexes with the properties it holds (SONNY-6368).
- **`REMOVE n.prop`** — removing an indexed text property rebuilds every
  fulltext index covering it from the store at the end of the statement
  (once per index, however many rows the statement removed from): the
  engine cannot take one property's postings out of a document, and a
  tombstone would hide the node for good (SONNY-6368). Cost: an O(nodes of
  the label) rebuild per statement that removes indexed text.
- **`REMOVE n:L`** — a node that leaves a label leaves the label's
  fulltext and vector indexes: a fulltext index holding text of the node is
  rebuilt at the end of the statement and the vector indexes on the label
  are rebuilt (SONNY-6421). Search, phrase and proximity answer only nodes
  that carry the index's label, so a label removed by a path that does no
  index maintenance (an undo of `SET n:L`, a replicated apply) does not
  surface the node either.
- **Delete** — deleting a node removes it from the index.
- **Bulk-MERGE fast path** — `MERGE` statements shaped for the connection-thread
  fast path (`executeBulkSimpleMerge` in `quic_connection_handler.zig`, and its
  concurrent `/*+BATCH*/` sibling `executeBatchSimpleMerge`) are also
  live-maintained (Task 4, 2026-08-28). The maintenance call runs right after
  the apply completes and every graph lock is released, on the connection
  thread — never a group-commit worker thread — satisfying the fts engine's
  single-writer-thread contract. Bulk-MERGE'd nodes are searchable
  **immediately**, no rebuild required.
- **After a restart** — the hooks find an index through a label -> index
  registry held in memory. The first hook on a graph after a restart fills
  it from the catalog's fulltext rows (written by CREATE INDEX, removed by
  DROP INDEX) and opens their engines, so every path above keeps working
  after a clean restart or a crash (SONNY-6591). Before that fix the
  registry stayed empty after any restart: search answered what was
  indexed before it, and no later write reached the index until
  `CALL geode.fts.rebuild`.

Regression for every path above, over QUIC and gRPC, with and without TDE,
right after the write and after SIGKILL and SIGTERM restarts:
`zig build test-sonny6591-fts-write-paths`.

> **Graph scope:** `CALL geode.fts.*` operates on the default graph — a node
> bulk-MERGE'd into a non-default graph is maintained into *that* graph's own
> fulltext index, which `geode.fts.search`/`phrase`/`proximity`/`rebuild`
> cannot currently query.
>
> By design, `CREATE INDEX ... USING fulltext` and every `CALL geode.fts.*`
> run on the default graph, whatever the session's graph (SONNY-2790). The
> server takes the default graph's lock for them. A request that also
> changes another graph is refused (0A000); send it on its own. `DROP INDEX`
> runs on the session's graph and takes its lock (SONNY-6294), so a
> fulltext index is dropped from the default graph:
> `USE GRAPH default; DROP INDEX <name>`.

### Recovery: `CALL geode.fts.rebuild`

`CALL geode.fts.rebuild('<index>')` drops, recreates, and re-backfills a
fulltext index from current store contents, YIELDing `index` / `nodes_indexed`.
It is a first-class recovery/backfill path — reach for it after restoring a
graph from a backup that predates an index, or to reconcile an index written
by an older binary before the Task 4 bulk-MERGE fix landed. It is **not**
required for ordinary bulk-MERGE ingestion on a current binary: live
maintenance already covers that path.

**Concurrent writes during rebuild (2026-08-29):** the fulltext engine is
briefly absent between the internal drop and re-create, and the backfill that
follows reads a point-in-time snapshot of the label's nodes. A live write
(CREATE/SET/DELETE, or a raft-follower apply) landing in that window is
**queued** rather than erroring on the missing engine or double-appending
past the backfill snapshot: `fts_storage_adapter.zig` tracks a per-index
rebuilding flag plus a pending node-id set (`beginRebuild`/
`noteWriteDuringRebuild`/`endRebuild`), and `rebuildFulltextIndex` drains the
queue after backfill, re-indexing every pending id the snapshot did not
already cover. Deletes are queued the same way as creates/updates and a node
deleted mid-window whose id was NOT already backfilled is handled correctly
by the drain — it re-reads current store state and naturally skips a node
that no longer exists. The drain never deletes-then-reindexes (fts-storage
tombstones are permanent per doc_id). Two accepted residuals remain, same
class as the front-edge TOCTOU window documented above (see
`rebuildFulltextIndex` in `fts_index_ops.zig` for the full comment): (1) a
node deleted mid-window whose id WAS already covered by the backfill
snapshot is queued but the drain skips it (the snapshot already "owns" that
id), so no tombstone is written and the index keeps a stale posting for the
gone node until the next rebuild; (2) a write landing after `endRebuild`
clears the rebuilding flag but before the drain loop reaches that id can
double-append a posting, also cleared by the next rebuild. Neither residual
is visible to callers — search-hit resolution drops any hit whose node
cannot be resolved against the live store — so correctness at query time is
preserved. A second `CALL geode.fts.rebuild` on the SAME index while one is
already in flight is refused (`RebuildInProgress`) rather than racing two
drop→create sequences. Regression: `tests/test_fts_rebuild.zig` (`zig build
test-fts-rebuild`). An undo repair or a statement-end rebuild after a REMOVE
(below) that finds a rebuild of the index running is not refused: that
rebuild runs again from the store after its pass
(`FtsStorageAdapter.requestRebuildAgain`, SONNY-6368).

**Undo rebuilds the indexes it touched (SONNY-3381):** a statement that fails
and a `ROLLBACK` (or rollback to a savepoint) undo their changes through the
graph store, which the fulltext engine cannot follow: it is append-only, a
SET's old postings stay, and a tombstoned document is never searchable again.
After such an undo every fulltext index (and every vector or other advanced
index) covering a property, label or node it reverted is rebuilt from the
store as the undo left it (`execution/undo_index_repair.zig`, through
`rebuildFulltextIndex` above), so a search no longer finds a node by a word
an undone SET wrote, and finds a node whose DELETE was undone. The rebuild is
O(nodes of the label) and runs only for such an undo. If a rebuild of the
same index is already running (its backfill may have read the undone value),
that rebuild runs again after its pass instead of the repair being dropped
(SONNY-6368). Regression: `zig build test-sonny3381-undo-index-entries`,
`zig build test-sonny6368-index-maintenance`.

**Ingestion invariant:** after any bulk-ingestion run, verify FTS visibility
with a canary query (`CALL geode.fts.search(index, term)` for a term known to
be present) before marking ingestion ready — cheap insurance, and the primary
signal that recovery via `CALL geode.fts.rebuild` is needed. Use a term from a
node written LAST, and after the server's latest restart: a term written
earlier says nothing about later writes. Data written by a binary without the
SONNY-6591 fix needs one `CALL geode.fts.rebuild` per index if it was written
by a single-statement QUIC `CREATE` or after a restart.

### Cluster Mode (2026-06-10)

- **Raft apply + snapshot install now maintain FTS.** The raft apply path
  (GNC1/GNC2/GMRG/GUPD/GDEL) fires the same FTS live-maintenance hook on
  followers via a callback seam, and snapshot install rebuilds FTS indexes from
  the installed graph data (seam-level — production `reportSnapshot` wiring is
  pending). Test: `tests/test_fts_apply_symmetry.zig`.
- **`SET` / `REMOVE` on a follower:** applying a replicated SET that
  replaces indexed text, a REMOVE of it, or a MERGE's ON MATCH SET queues
  the covering indexes for a rebuild at the end of the applied entry, as
  the leader's statement does (SONNY-6421 executor, SONNY-6433 apply), so a
  follower stops answering for the old words. The rebuild runs on the apply
  thread, a follower's only writer.
- **`CREATE INDEX` / `DROP INDEX` are refused in cluster mode** (fail-closed
  DDL — no Raft replication slice for index DDL yet): follower →
  `ClusterNotLeader`, leader → `ClusterWriteNotReplicable`. Standalone mode is
  unaffected.

---

## Durability

Indexes are durable on disk. Each index's `fts_storage.Engine` persists via its
own WAL, on-disk segments, and manifest under `{graph_dir}/fts/<index_name>/`.
After a server restart, on-disk fts indexes are **lazily re-opened on the first
query** against them — no explicit reload step is required, and there is no
in-memory snapshot to rebuild.

---

## BM25 Ranking

`fts-storage` computes BM25 relevance scores. `CALL geode.fts.search(…)` returns
each match's `score` column directly.

---

## Wire Protocol

Full-text search is reachable over the QUIC wire protocol via the
`CALL geode.fts.search(…)` procedure. Results ride the **generic GQL
Execute+rows protocol**, so **no client, proto, or transport changes** are
needed to consume them — any GQL client that can read result rows works.

---

## Verification

FTS is held to graph-storage parity:

- **Unit tests:** `tests/test_fts_storage_adapter.zig`, `tests/test_fts_tokenizer.zig`, `tests/test_fts_e2e.zig`, `tests/test_fts_apply_symmetry.zig` (raft-apply/snapshot maintenance). NOTE (2026-06-10): `tests/test_fts_coverage.zig` and `tests/test_fts_maintenance.zig` are DEAD code (they call a nonexistent `initGlobalStoreWithDataDir` and are never analyzed by the compiler) — do not cite them as live coverage.
- **Advanced FTS (GAP-0869):** `tests/e2e_fts_advanced.zig` (facade-level phrase/proximity/highlight over a real engine) + `tests/test_gap0869_fts_advanced.zig` (GQL path: `CALL geode.fts.phrase` / `geode.fts.proximity`), both under `zig build test-gap0869`
- **Benchmark:** `benchmarks/benchmark_fts_storage.zig` (native VarianceEnvelope benchmark, in the `bench` / `benchmark` aggregates)
- **Latency gate:** `tests/test_fts_latency.zig` (CI-aware)
- **Harness specs:** `geodetestlab-cli/specs/fts_storage_basic.yml`, `geodetestlab-cli/specs/fulltext_search_basic.yml`

---

## Related

- [API_REFERENCE.md](API_REFERENCE.md) — API reference
- [optimizing-fts-storage.md](optimizing-fts-storage.md) — design/tuning notes for `fts-storage` against Geode's access patterns
- [BM25_INDEX_OPTIMIZER_INTEGRATION.md](BM25_INDEX_OPTIMIZER_INTEGRATION.md) — status note: no index optimizer integration exists
- [rag/RAG_INTEGRATION_GUIDE.md](rag/RAG_INTEGRATION_GUIDE.md) — operational notes for using `geode.fts.*` as a RAG orchestrator's full-text channel (row visibility, bulk-MERGE live maintenance, `geode.fts.rebuild` recovery, canary-query habit)
- [rag/GEODE_RAG_ORCHESTRATOR_PROMPT.md](rag/GEODE_RAG_ORCHESTRATOR_PROMPT.md) — production RAG orchestrator system prompt
