# Bug: full-text search returns **zero results** at runtime — `CALL geode.fts.search` always yields 0 rows (index never matches), no error

**Status:** **OPEN.** Reproduced on `geodedb/geode:0.6.17` (the published image; current release line is `v0.6.23`). The FTS GQL surface parses and executes successfully — `CREATE INDEX … USING fulltext` and `CALL geode.fts.search('idx','q')` both return `00000` — but the index **never returns any matching node**, for: (a) pre-existing nodes backfilled at `CREATE INDEX` time, (b) a node freshly `CREATE`d *after* the index exists (live write), and (c) a node touched via `SET` after index creation. The engine is wired at the surface but does not index/return results. Because it fails **silently** (success status, empty rows), every consumer of geode FTS gets empty search results with no signal that FTS is non-functional.

This blocks divelife-api from adopting geode FTS for content discovery; divelife falls back to `toLower(...) CONTAINS ?` substring search.

---

## 1. Symptom / reproduction

On a running `geodedb/geode:0.6.17` (single node, local docker), via the geode query CLI:

```
# 1) create a fulltext index on a fresh label  -> SUCCESS (00000)
CREATE INDEX IF NOT EXISTS ftsprobe FOR (n:FtsProbe) ON (n.text) USING fulltext;

# 2) insert a fresh node with a unique token   -> SUCCESS, 1 row
CREATE (n:FtsProbe {id:'p1', text:'nudibranch zebra octopus'}) RETURN n.id;

# 3) search the index for a token in that node -> SUCCESS, but ZERO rows
CALL geode.fts.search('ftsprobe','zebra');
#   -> {"status_class":"00000", columns:[{node},{score}], rows:[]}   (expected: 1 row = p1)
```

The same zero-result behavior holds for an index created over already-seeded `:Species` nodes (backfill path): searching `'shark'`/`'turtle'`/`'reef'`/`'whale'` against an index on `Species.common_name` (with seeded "Grey Reef Shark", "Green Sea Turtle", etc.) returns 0 rows. A `SET s.common_name=…` followed by a search also returns 0 rows.

So **none** of the three indexing paths (create-time backfill, live `CREATE`, live `SET`) surface a searchable document.

Notably, `CALL geode.fts.search('nonexistent_idx','x')` returns `0A000 Unsupported` (no adapter), which is the correct "no such index" signal — so the dispatch path works; it's the **indexing/search of a real index** that yields nothing.

## 2. Impact

- **Silent.** FTS returns `00000` success with an empty result set, not an error. A caller cannot distinguish "no matches" from "FTS engine not indexing". This is the worst failure mode for a search feature.
- **Feature is advertised but unusable.** The GQL surface (`USING fulltext`, `CALL geode.fts.search`) is documented (`docs/FULLTEXT_SEARCH.md`) and parses cleanly, so downstreams reasonably adopt it — then get empty results in production.
- **Blocks dependents.** divelife-api intended to back content discovery (species / sites / articles / videos / destinations) with `CALL geode.fts.search`; it cannot, and has reverted to `toLower(...) CONTAINS ?` substring scans.

## 3. Suspected root cause

The external `fts-storage` engine (v0.1.1, `build.zig.zon` `.fts_storage`) is linked and the adapter (`src/storage/fts_storage_adapter.zig`) registers per-graph engines, but the **index population path is not actually writing to / reading from the persisted engine** in the published build. Candidates to investigate:

1. **Create-time backfill not executing or not committing.** `src/execution/fts_index_ops.zig` is supposed to backfill existing matching nodes on `CREATE INDEX … USING fulltext`. If the backfill iterates zero nodes (label/property mismatch, or a no-op), the index stays empty.
2. **Live indexing not hooked into write commits.** `CREATE`/`SET` on an indexed property should enqueue a document into the FTS engine. If the mutation path doesn't notify the adapter (or notifies a different graph/engine instance than the one `CALL` reads), nothing is searchable.
3. **Memtable/segment visibility.** If writes land in an unflushed memtable that the search path doesn't consult (search reads only flushed segments), every recent write is invisible. A fresh insert returning 0 immediately points here — but the create-time backfill returning 0 too argues against pure flush-lag.
4. **Engine instance mismatch.** `single_writer_thread_check = false` is set so the engine is driven from the QUIC worker pool (`fts_storage_adapter.zig:188`); if writes and reads bind to different engine handles / graph adapters across worker threads, reads see an empty index.
5. **Stub path reached.** The investigation that surfaced this noted `src/fts/advanced.zig` is a stub over a synthetic corpus; confirm the `CALL geode.fts.search` dispatch (`src/execution/fts_dispatch.zig`) routes to the **persisted** `fts_storage` engine, not a stub/empty corpus.

## 4. Suggested fixes (geode side)

- **Add an end-to-end FTS test that asserts a match is returned** (not just that CALL/CREATE return `00000`): create index → insert a node → `CALL geode.fts.search` → assert ≥1 row with the inserted node id. The existing `tests/test_fts_e2e.zig` apparently does not catch the zero-result regression in the published build — strengthen it to assert row contents and run it against the release build.
- **Wire (and verify) both indexing paths to the persisted engine:** create-time backfill AND live `CREATE`/`SET`/`DELETE` mutation hooks, on the same adapter/engine instance the `CALL` reads.
- **Fail loud if FTS is not actually functional.** If the engine is intentionally disabled/stubbed in the published image, the GQL surface should return an explicit error (e.g. `0A000 Unsupported` or a clear "FTS engine unavailable") rather than a silent empty success — so consumers detect it immediately.
- Confirm the published Docker image (`geodedb/geode:<tag>`) is built from a commit where FTS indexing is actually functional (the v0.6.x image behavior diverges from what the `main` source + `git tag --contains` suggest).

## 5. Environment

- Image: `geodedb/geode:0.6.17` (single node), local docker-compose; reproduced via `geode query` CLI against `127.0.0.1:3141`.
- Latest release line: `v0.6.23`. FTS GQL surface present and parsing in this image.
- Date: 2026-06-07.

## 7. Resolution (2026-06-07)

Fixed on branch `bug/fts-search-zero-results` (plan:
`docs/superpowers/plans/2026-06-07-fts-search-zero-results.md`). Two distinct root causes were
found by a runtime diagnostic, both producing zero/silent results:

1. **Index-first ordering (create-time / backfill path).** `createFulltextIndex`
   (`src/execution/fts_index_ops.zig`) resolved the target graph with the find-only
   `lookupManagedGraph`, which returns `GraphNotFound` when `CREATE INDEX … USING fulltext` is the
   FIRST operation on a graph not yet lazily registered in the adapter's `engines` map. The error
   (`FulltextUnavailable`) was **silently swallowed** in `src/execution.zig`, so `CREATE INDEX`
   reported `00000` while no engine was created. **Fix:** use `getOrCreateGraph` (the same path
   every write uses, which also initialises the graph's `fts_adapter`). The silent swallow now
   emits a loud warning.

2. **Live CREATE/SET path (tombstone).** The node write-maintenance hook for `SET`
   (`src/execution/property_mutation.zig`) used `.update` = deleteNode-then-reindex. The fts-storage
   engine adds a doc_id to `all_tombstones` on `deleteDocument` and **never removes it on a later
   `indexDocument`** (the set is only rebuilt from segments on reopen/compaction; see
   `engine.zig:974` + `search.zig:183` in the pinned `fts_storage` lib), so the re-indexed document
   was filtered out by search. **Fix:** use `.create` (skip the tombstone) so a freshly written
   node is immediately searchable.

**Verification:** new index-first regression test in `tests/test_fts_e2e.zig` (FAILS before, PASSES
after); isolated `zig build test-fts-e2e` step added. Also fixed a pre-existing `index_type` leak in
the DROP INDEX catalog free path (`src/execution.zig`) that the new isolated leak-checked step
surfaced.

**Known residual (tracked):** a TRUE value change via `SET` on an already-indexed node leaves the
OLD value's postings in place (no tombstone), so the node remains findable by the stale old value
and repeated `SET`s append-grow the index. Search-for-current-value is correct (the reported bug is
resolved); reclaiming stale postings needs an engine-level un-tombstone-on-reindex or a compaction
trigger in the `fts_storage` library — a separate follow-up.

## 6. Cross-references

- `docs/FULLTEXT_SEARCH.md` — the documented FTS surface (works syntactically; doesn't return results).
- `docs/optimizing-fts-storage.md` — notes `src/fts/advanced.zig` phrase/proximity is a stub; confirm the basic BM25 search path is not also short-circuited.
- `src/execution/fts_dispatch.zig`, `src/execution/fts_index_ops.zig`, `src/storage/fts_storage_adapter.zig` — the create/backfill/search paths to audit.
- Related (separate) runtime issue: `2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md`.
