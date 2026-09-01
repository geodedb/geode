# Index Maintenance and Bulk Ingest

*Last updated: 2026-09-01*

This page is the operator-facing truth about how Geode's **advanced indexes**
(HNSW vector, spatial, network, signature, interval, JSONB, domain-trie) are
built and maintained, what `CREATE INDEX` costs you while it runs, and how to
load a large dataset without paying that cost on every row.

It is deliberately blunt about the gaps. Where a behaviour is a known
architectural limitation rather than a bug, it says so and names the ticket.

---

## TL;DR for bulk loading

**Drop the index, load, then create the index.**

```gql
DROP INDEX my_vec_idx;

-- … bulk load here (CSV import, client batch inserts, MERGE loops, …) …

CREATE INDEX my_vec_idx ON Doc (embedding) USING vector WITH (metric = 'cosine');
```

Why this and not "just load with the index in place":

* A **vector** index takes an incremental HNSW insert for a first-time write of
  an id (geode#875), so a plain append load is no longer quadratic. But an
  **overwrite** of an already-indexed vector, and **every** write to a
  non-vector advanced index, still triggers `rebuildAdvancedIndexesForProperty`
  — which **drops and re-creates the index and then re-scans the whole label**.
  That is O(rows) work *per written row*, i.e. O(n²) over such a load. See
  [Incremental maintenance](#incremental-maintenance-partly-closed-partly-still-a-gap).
* Even on the incremental path, a single `CREATE INDEX` at the end does exactly
  one full scan and builds the graph in one batch, which is cheaper than N
  individual inserts.

If you cannot drop the index (e.g. queries must keep running against it),
a first-time-write vector load is now viable; a re-embedding (overwrite) load or
a non-vector advanced index will still be dramatically slower — plan
accordingly.

### Vector dimensions and bulk loads

The vector dimension guard establishes the dimension from the first vector
**committed** under a `(label, property)` and refuses any later vector of a
different dimension (SQLSTATE 22000, `VectorDimensionMismatch`).

* **An index is not required (ENG-3922, 2026-08-29).** Mixed dimensions under
  one `(label, property)` are a data-integrity defect in their own right —
  `vector_cosine` over a dim-4/dim-3 pair yields NULL and a knn scan silently
  drops the non-conforming rows, index or no index — so the guard covers an
  **unindexed** property too.
* A **refused** statement does not establish anything — a rejected mixed-
  dimension `CREATE` leaves the property unpinned (ENG-3912).
* `DROP INDEX` **does not release** the pin (policy change, ENG-3922; it used
  to). The pin belongs to the `(graph, label, property)`, not to the index, and
  it is derived from committed data. To change a property's dimension, delete
  the rows that establish it — dropping the index is not enough, and never was
  the guarantee it looked like.
* After a restart the pin is re-derived from the first vector already stored
  under that `(label, property)`; it is not persisted in the catalog.
* **Scope depends on whether an index exists.**
  * An **indexed** pin is **process-wide, not per graph**: a dimension
    established in graph A is enforced for the same `(label, property)` in
    graph B. That is correct as the engine stands, because the HNSW index
    itself is a process-global object — index population selects nodes by
    label + property with **no graph filter**, so graph B's vectors land in
    graph A's index. Making vector indexes graph-scoped (the way fulltext
    indexes already are, one engine per graph directory) is design work; the
    pin should be scoped in the same change.
  * An **unindexed** pin is **per graph**: with no shared index object behind
    it, the same label + property in another graph is a separate property with
    its own dimension. `DROP GRAPH` releases that graph's pins.
* The pin is cached process state. Deleting every row that establishes a
  dimension does **not** release the pin until the process restarts (or the
  graph is dropped) — re-deriving it from data on every write would cost a
  label scan per vector write. Known residual, not a defect.
* The **bulk/batch MERGE fast paths** enforce the same guard. They bypass the
  regular property-write chokepoint, and a vector *can* reach them as a bound
  wire parameter, so the check runs there too — before any op is submitted, so
  a refusal leaves the whole batch unapplied.

A vector literal above **65535 dimensions** is a separate refusal: SQLSTATE
54000 (`program_limit_exceeded`, `VectorTooLarge`), because the stored `dim` is
a `u16`. Both the string form (`vectorf32('[…]')`) and the array-literal form
(`vectorf32([…])`) enforce it; before ENG-3922 the array form had no check at
all and panicked the server.

---

## What `CREATE INDEX` blocks

`CREATE INDEX` is a mutating statement, so the transport handler holds the
**per-graph exclusive write lock** for its duration.

**Fixed (2026-08-25):** the index *backfill* — the full label scan that
populates the new index — no longer runs inside that exclusive lock. It is
queued onto the same `pending_index_rebuilds` path the incremental rebuilds
use, which both the QUIC and gRPC handlers drain **after** releasing the
exclusive lock, under a shared lock. Before this, a `CREATE INDEX` over a large
label blocked *every* write in the database — any label, any session — for the
whole scan (measured at >150 s).

**Fixed (geode#875 RC-2b, 2026-09-01):** moving the scan out of the *exclusive*
lock did not stop it pinning a *shared* one for the whole build, and
`StorageAdapter.acquireGraphWriteLock` spins until readers drain — so an
unrelated `EXCLUSIVE` writer still stalled for the entire backfill (measured
~49 s against a 3 000 x 256-dim build). A **vector**-index backfill now runs as
a *shadow* build (`IndexManager.rebuildAdvancedVectorIndexNonBlocking`,
mirroring the `fts-storage` rebuild window):

1. arm a rebuild window for the index (a second concurrent rebuild of the same
   index is refused with `error.RebuildInProgress`),
2. take the shared graph lock only long enough to **copy out** every
   `(entity id, vector)` pair — a hydrating scan plus an `N x dim` memcpy — and
   release it,
3. build a **shadow** `VectorIndexWrapper` from the copies with **no graph lock
   held** (`Hnsw.batchInsert` takes the HNSW write lock once for the batch),
4. swap the shadow in under `rebuild_mutex`, and
5. disarm the window and re-apply the writes it captured, skipping ids the
   shadow already carries.

Two consequences worth knowing: readers keep seeing the **old, fully populated**
index right up to the swap (it is no longer dropped-then-empty for the whole
build), and writes that land mid-build are queued into the window instead of
being lost against the pre-write snapshot.

**Still true, plan for it:**

* The **creating session** still waits for the backfill: the statement does not
  respond until the queued rebuild has been drained.
* Only **vector** indexes take the shadow path. The other advanced index types
  (spatial, network, interval, jsonb, domain) keep the in-place rebuild under
  the shared graph lock — they are cheap to build, but a very large one will
  still hold that lock for its scan.
* The snapshot pass itself still takes the shared graph lock, so a writer on the
  **same graph** can be delayed by that pass. It is a scan plus a memcpy, not an
  HNSW build.
* The backfill is not restartable or cancellable. A client disconnect does not
  stop it.
* Swapping the shadow in deinits the old wrapper while a concurrent `knn` reader
  may still hold a pointer to it. This hazard is **unchanged** from the previous
  drop-and-recreate shape (readers and the rebuild both hold the graph lock
  SHARED, which does not exclude them from each other); closing it needs
  refcounted index handles, as `fts_storage_adapter` has.
* There is no progress reporting. `SHOW INDEXES` lists the index as soon as the
  catalog row exists, which is **before** the backfill completes — presence in
  `SHOW INDEXES` is not a statement about the index being populated.

Operational advice: run `CREATE INDEX` on large labels during a maintenance
window, or on a graph that is not taking concurrent writes.

---

## Incremental maintenance: partly closed, partly still a gap

**Fixed (geode#875 RC-1 / RC-1b):** an ordinary node write into a **vector**-
indexed `(label, property)` is now an **incremental HNSW insert** of the one
changed node (`IndexManager.tryIncrementalInsertForProperty`, reached from the
single write chokepoint `execution/property_mutation.zig`
`setNodePropertyFromValue`), not a full drop-and-rescan.

RC-1b is the part that matters operationally: the deferral guard
(`advancedIndexRebuildIsDeferred`) used to short-circuit on the mere **presence**
of the transport's per-statement `pending_index_rebuilds` map — which the QUIC
and gRPC handlers install for *every* statement — so the incremental path was
unreachable on any real connection and every single write queued a full `O(N)`
rebuild (measured 100 s for ONE write at 3 000 x 256 dims, versus 1 s for the
same write on an unindexed label). The guard now defers only when the map
actually holds a rebuild for an index covering *this* `(label, property)`.

**Still a full rebuild, by design or by gap:**

* An **overwrite** of an already-indexed id. HNSW has no un-insert, so a second
  insert would leave a stale duplicate; the write falls back to the honest full
  rebuild. Sustained *re-embedding* of the same nodes is therefore still
  quadratic. A first insert for an id — the ingest case — is not.
* An open **transaction undo log**. The deferred rebuild is the only
  rollback-safe path, for the same un-insert reason.
* **Deletes.** There is no removal path; a deleted node's vector stays in the
  index until something triggers a rebuild.
* Every **non-vector** advanced index type (spatial, network, interval, jsonb,
  domain). Those still do `dropAdvancedIndex` → `createAdvanced…Index` → full
  scan (`populateAdvancedIndex`) per write.

Consequences you will observe:

* A `knn` query issued while a rebuild is in flight contends with the rebuild's
  write locks on the HNSW structure; long rebuilds can starve readers for the
  duration. (A *backfill* no longer does this to unrelated writers — see the
  shadow-build section above.)
* `vector_knn` / `knn` fall back to a brute-force scan (`scanVectorKnn`) when no
  runtime index is registered for the property. Results stay correct, so a
  missing index is silent — measure, don't assume.
* Advanced indexes are **not rebuilt at startup**. No call site rebuilds them on
  catalog reload, so after a restart the catalog still lists the index and
  `knn` silently uses the brute-force fallback until something triggers a
  rebuild. (The vector *dimension guard* is re-armed on catalog reload —
  ENG-3912 — but that is the validator, not the index.)

Insert is closed (geode#875 RC-1/RC-1b) and readers now keep a consistent view
across a backfill (RC-2b's shadow swap). **Update and delete against the live
HNSW structure remain open** — they need an un-insert the library does not have,
so they stay a design change rather than a patch, tracked as follow-up work
alongside ENG-3914 / ENG-3915 and deliberately **not** attempted piecemeal: a
partial implementation that leaves the index inconsistent with the store is
worse than the honest full rebuild.

---

## Choosing an index type

| GQL spelling | Runtime index | Notes |
|---|---|---|
| `USING vector` | HNSW | Same runtime index as `vector_f32`. |
| `USING HNSW` | HNSW | Alias of `USING vector`. |
| `USING vector_f32` | HNSW | Explicit spelling; identical behaviour. |
| `USING fulltext` | fts-storage engine | Per-graph, on-disk, incrementally maintained. Not covered by this page — see [FULLTEXT_SEARCH.md](FULLTEXT_SEARCH.md). |

All three vector spellings honour `WITH (metric = …)`; supported metrics are
`l2` / `euclidean`, `cosine`, and `dot` / `dot_product` / `inner_product`. An
unknown metric is refused at DDL time (SQLSTATE 42704). Omitting the metric
selects `l2`.

> Historical note: `USING vector` and `USING HNSW` used to record a catalog row
> and build **no index at all**, and the validated metric was discarded in
> favour of a hardcoded `l2`. Both were fixed on 2026-08-25. If you have an
> index created before that date, `DROP` and re-`CREATE` it to get a real index
> built with the metric you asked for.

---

## Documentation follow-up

The same guidance belongs on geodedb.com (bulk-ingest guide + vector search
page): drop-index/load/create-index, the `CREATE INDEX` blocking envelope, and
the incremental-maintenance gap. Tracked as a docs follow-up.
