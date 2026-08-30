# Index Maintenance and Bulk Ingest

*Last updated: 2026-08-25*

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

* Every node property write that touches an indexed `(label, property)` pair
  triggers `rebuildAdvancedIndexesForProperty`, and an advanced-index rebuild
  **drops and re-creates the index and then re-scans the whole label**. That is
  O(rows) work *per written row*, i.e. O(n²) over a load. There is no
  incremental insert path — see
  [Incremental maintenance is a gap](#incremental-maintenance-is-a-known-architectural-gap).
* A single `CREATE INDEX` at the end does exactly one full scan.

If you cannot drop the index (e.g. queries must keep running against it),
expect the load to be dramatically slower and plan accordingly.

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

**Still true, plan for it:**

* The **creating session** still waits for the backfill: the statement does not
  respond until the queued rebuild has been drained.
* The backfill takes a **shared** graph lock while it scans, so a writer on the
  **same graph** can still be delayed by lock hand-off. Writers on other graphs
  are unaffected.
* The backfill is not restartable or cancellable. A client disconnect does not
  stop it.
* There is no progress reporting. `SHOW INDEXES` lists the index as soon as the
  catalog row exists, which is **before** the backfill completes — presence in
  `SHOW INDEXES` is not a statement about the index being populated.

Operational advice: run `CREATE INDEX` on large labels during a maintenance
window, or on a graph that is not taking concurrent writes.

---

## Incremental maintenance is a known architectural gap

There is **no incremental insert** into an advanced index. Every path that
needs the index to reflect a new value performs a full **rebuild**:
`dropAdvancedIndex` → `createAdvanced…Index` → full scan
(`populateAdvancedIndex`).

Consequences you will observe:

* Sustained writes to an indexed `(label, property)` are quadratic.
* A `knn` query issued while a rebuild is in flight contends with the rebuild's
  per-vector write locks on the HNSW structure; long rebuilds can starve
  readers for the duration.
* `vector_knn` / `knn` fall back to a brute-force scan (`scanVectorKnn`) when no
  runtime index is registered for the property. Results stay correct, so a
  missing index is silent — measure, don't assume.
* Advanced indexes are **not rebuilt at startup**. No call site rebuilds them on
  catalog reload, so after a restart the catalog still lists the index and
  `knn` silently uses the brute-force fallback until something triggers a
  rebuild. (The vector *dimension guard* is re-armed on catalog reload —
  ENG-3912 — but that is the validator, not the index.)

Real incremental maintenance (insert/update/delete against the live HNSW
structure, plus a consistent view for readers during a backfill) is a design
change, not a patch. It is tracked as follow-up design work alongside
ENG-3914 / ENG-3915 and is deliberately **not** attempted piecemeal — a partial
implementation that leaves the index inconsistent with the store is worse than
the honest full rebuild.

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
