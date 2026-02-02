# On-Disk Storage Design for a Production-Grade Multi-Graph Property Graph Database As of February 2, 2026

## Executive summary

Fact — The baseline engine constraints (page-based 8KB pages with slot directories, memory-mapped I/O, MVCC with version chains, physical WAL with before/after images, checkpoints, and multiple specialized index families) strongly favor a page-store design rather than a pure LSM KV engine. citeturn20view0turn6view0turn8view0turn9view0

Interpretation — For real-world GQL workloads, the dominant “graph hot path” is repeated neighbor expansion under filters (direction, relationship type, sometimes label/property predicates) plus frequent point-lookups by internal IDs (node/relationship fetch) and selective index seeks that seed traversals. Geode’s own executor sketches confirm that expansion is implemented as `relationshipIterator(source_node.id, direction, rel_type)` followed by `getNode(target_id)`, which makes adjacency access locality the primary latency lever. citeturn6view0turn7view0

Recommendation — The best overall on-disk structure (given the feature set and correctness requirements) is a **hybrid page-store** that keeps:
- **Traversal-optimized adjacency segments** (per node, per direction, optionally per relationship-type) stored as **sequential adjacency blocks** for fast scans, while
- Handling updates via a **delta adjacency layer** (append-only deltas + tombstones) merged by **background compaction**, and
- Keeping **node/relationship properties** in a **row-oriented record store** with overflow pages for large values, indexed by the existing B-tree/hash/full-text/spatial/vector families.

This is closest to “Adjacency-segment (CSR/CSC-inspired) with delta store” (Option 2) adapted into Geode’s page engine, because it hits the best point on the trade-off curve: **near-sequential adjacency scans** (good for expansions and variable-length paths) while still supporting **high-concurrency MVCC/SSI, WAL+PITR, and rich secondary indexing**. citeturn20view0turn12search9turn12search21turn12search15turn9view0

Why this wins (tell-it-like-it-is):
- Neo4j-style pointer chains are operationally clean and update-friendly, but pointer chasing is fundamentally hostile to modern storage hierarchies at scale unless you also implement aggressive collocation; even Neo4j’s newer “block” format explicitly emphasizes locality improvements because classic record-chain layouts suffer. citeturn12search0turn21search3turn21search7  
- LSM/KV layouts shine for write throughput, but compaction-driven write amplification is real and hard to budget, and multi-hop traversals can degrade due to repeated range scans across levels and caches (even when each adjacency list is stored contiguously by key prefix). citeturn14search0turn12search2turn12search18turn21search0  
- A CSR+delta pattern is one of the few designs that simultaneously targets **sequential adjacency scans** and **ongoing transactional updates**, which is exactly the hybrid requirement here (fast traversals + OLTP-grade semantics). citeturn12search9turn12search21turn20view0

## Geode baseline constraints and existing assumptions

Fact — Storage is a **page-based architecture** with **8KB pages**, **64-byte page headers**, a **slot directory**, and explicit page header fields including **Page ID, Page Type, LSN, and Checksum**. citeturn20view0

Fact — Documented page types include at least: `NodePage`, `RelationshipPage`, `PropertyPage` (overflow for large properties), `IndexPage`, and `FreelistPage`. citeturn20view0

Fact — The engine uses **memory-mapped files** for data access and a **buffer pool** with **LRU eviction**, explicitly calling out “zero-copy access” and leveraging the OS page cache. citeturn20view0turn7view2

Fact — MVCC is implemented via **version chains** and a snapshot visibility rule that rejects versions from transactions active at the snapshot and versions created after the snapshot transaction ID. citeturn20view0

Fact — WAL is **page/byte-range physical**: a WAL record includes **LSN, transaction ID, record type, page ID, offset, length, before image, after image, and checksum**, and recovery is described as **Analysis → Redo → Undo** with checkpoints narrowing the replay window. citeturn20view0turn9view0

Fact — Checkpointing and compaction are explicitly configurable; the documented compaction threshold example is **“compact when 50% of space is dead”**. citeturn20view0

Fact — Index storage is already architected as first-class: B-tree (with stated default fan-out 128), hash (extendible hashing), and HNSW vector index are referenced directly in the storage architecture docs; the Index Types reference additionally documents full-text (BM25), spatial (R-tree), and composite indexes. citeturn20view0turn8view0turn17search2

Fact — The query engine’s physical operators include `NodeScan`, `IndexSeek`, and a dedicated `ExpandRelationships` traversal operator; the executor pseudocode shows an **expand loop** that calls `relationshipIterator(source_node.id, direction, rel_type)` and for each relationship fetches the target via `getNode(relationship.target_id)`. citeturn6view0

Fact — Statistics used by the optimizer include node label cardinalities, relationship type counts, property value distributions, index selectivity, and an auto-update mechanism with configurable thresholds. citeturn6view0turn7view1

Fact — Multi-graph exists at the language/session level via `CREATE GRAPH` and `USE`, establishing a session “current graph” context; this implies on-disk namespacing or partitioning is not optional. citeturn5view0turn4view0

Fact — Operational observability includes a Prometheus-format metrics endpoint (`:8080/metrics`) and explicit metrics related to storage cache hits/misses and WAL bytes written—exactly the signals you need to validate any storage layout choice in production. citeturn19view0

Interpretation — These constraints strongly suggest you should **not** attempt to bolt on a completely different storage paradigm (e.g., full RocksDB-under-everything) unless you are also willing to re-derive MVCC/SSI, WAL/recovery semantics, and index integration in a new substrate. The baseline already “assumes” page IDs, page LSNs, and byte-range physical WAL, which naturally align with a page-store adjacency design. citeturn20view0turn9view0

## Access patterns and workload model

Fact — The optimizer reasons in terms of page I/O, `log(n)` index seeks, selectivity, join ordering, and explicitly pushes predicates toward scans/expands; this makes “how many pages do I touch per expansion step?” the core storage performance question. citeturn7view0turn7view1

Fact — The executor’s expand implementation pattern is: take bound source nodes → iterate relationships via a storage-layer iterator → for each relationship fetch target node → emit rows. citeturn6view0

Interpretation — The following operations are the “hot path” you optimize first:
- **Neighbor expansion**: `(n)-[t]->(m)` where `n` is bound; must approach sequential I/O for adjacency on disk and be cache-friendly in memory. citeturn6view0turn7view2  
- **Expand with type filter**: `-[ :TYPE ]->` should avoid scanning all relationship types for high-degree nodes (or at least allow fast skipping). citeturn6view0turn7view0  
- **Seed set lookup**: start nodes frequently come from an index seek (e.g., property equality or range) and then expand. citeturn7view1turn8view0  
- **Variable-length paths** (`*1..k`, shortest path, etc.): are expansions repeated many times; adjacency locality dominates CPU cost once predicate evaluation is cheap. citeturn6view0turn5view0

Interpretation — Realistic workload mixes divide into:
- **Interactive/OLTP-ish**: small fanout expansions, frequent point property reads, concurrent updates (create/update/delete), and strict isolation. This is well represented by the “interactive transactional” class of workloads used in graph benchmarking suites. citeturn22search0turn22search12turn22search8  
- **Hybrid traversal + search**: expansions mixed with full-text, spatial, or vector predicates (e.g., filter neighbors then vector-similarity re-rank), consistent with Geode’s explicit optimizer integration for BM25/HNSW. citeturn8view0turn17search2turn7view1  
- **Analytical traversals**: long-running BFS/DFS-like scans, higher-degree nodes, higher cache pressure, and higher importance of sequential reads. citeturn17search0turn12search21

Speculation — Operationally, you should assume a heavy-tailed degree distribution (few very high-degree nodes) because that’s common in social/knowledge graphs; this makes “single-node adjacency scan” a critical worst-case even if average degree is modest. (This is a modeling assumption; validate in benchmarks below.) citeturn22search0turn22search3

Hard requirements on complexity (pragmatic):
- Must be **O(1)**: internal ID → node record; internal ID → relationship record (if relationship is a first-class object); page lookup by page ID in buffer pool. citeturn20view0turn6view0  
- Must be **near O(deg(v)) with sequential access**: iterate neighbors for a bound node (with optional type filter). citeturn6view0turn12search21  
- Must be **O(log N)** or better: indexed property predicates; composite index seeks. citeturn8view0turn7view1  
- Acceptable to be scans (with guardrails): full label scans for large labels only if label index isn’t present; full graph scans only for admin/analytics with explicit intent. citeturn6view0turn7view1

## Physical layout options and decision matrix

### Option 1: Record-store with pointer chains (Neo4j-style)

Fact — entity["company","Neo4j","graph database vendor"] historically stores graph data as **linked lists of fixed-size records**: node records point to the first relationship record in a node’s relationship chain and the first property record; relationships reference endpoints and next/previous relationships for each endpoint; properties form linked lists with overflow for large values. citeturn12search0turn12search24turn12search36

Fact — Neo4j’s more recent “block format” is explicitly motivated by improving data locality via “inlining techniques” and “data collocation,” indicating that raw chain traversal without locality optimizations is insufficient at modern scale. citeturn21search3turn21search7turn21search11

Interpretation — Strengths:
- Very simple “index-free adjacency” semantics: node → first rel pointer then pointer chase; good for O(1) start of adjacency traversal. citeturn12search0turn12search24  
- Updates are straightforward (insert relationship record, splice pointers) and can be WAL-logged as small in-place modifications.

Interpretation — Weaknesses:
- Pointer-chasing produces random I/O and cache-miss amplification unless you implement collocation/packing/compaction heuristics; high-degree nodes suffer disproportionately. citeturn12search0turn21search7  
- MVCC on pointer chains gets tricky: either you version linkage fields (more writes) or you tolerate traversal seeing invisible versions and re-check visibility repeatedly (more reads).

### Option 2: Adjacency segments with delta store (CSR/CSC-inspired)

Fact — The entity["book","LLAMA","graph storage system paper 2015"] design uses CSR-like multiversioned arrays: a read-optimized base (CSR) plus a write-optimized delta structure that tracks inserted/deleted edges per modified vertex. citeturn12search9turn12search17

Fact — entity["book","LiveGraph","pvldb 2019 transactional graph storage"] targets a key pain point directly: making **adjacency list scans purely sequential even in the presence of concurrent transactions**, by using graph-aware storage structures rather than pointer chains. citeturn12search21

Interpretation — Strengths:
- Best-in-class traversal locality: base adjacency blocks can be read sequentially; cache-friendly for 1-hop and multi-hop expansions. citeturn12search21turn12search9  
- Delta layer isolates write churn, enabling high update throughput while preserving read locality most of the time. citeturn12search9  
- Compaction becomes explicit and controllable (merge deltas into base), which aligns with Geode’s stated compaction infrastructure. citeturn20view0

Interpretation — Weaknesses:
- Complexity: you must implement delta merge, tombstones, and “read across base+delta” semantics under MVCC/SSI without breaking correctness. citeturn12search21turn12search15  
- Space amplification depends on delta growth vs merge frequency; if merges lag, you pay in read-time merging and storage overhead.

### Option 3: Log-structured / LSM-based KV layout (edges/properties as sorted keys)

Fact — The entity["book","LSM-tree","O'Neil et al 1996"] design defers and batches index changes to achieve low-cost inserts and deletes, a foundation used in many modern KV stores. citeturn14search0

Fact — entity["company","RocksDB","facebook embedded kv store"] documents the core trade: leveled compaction reduces space amplification but increases write and read amplification; tiered compaction reduces write amplification but increases read and space amplification. citeturn12search2turn12search18

Fact — entity["organization","JanusGraph","open source graph db"] demonstrates a “KV row adjacency” approach: adjacency lists are stored as backend rows keyed by vertex ID, with edges/properties stored as cells, enabling efficient insertions/deletions. citeturn21search0turn21search28

Interpretation — Strengths:
- Excellent ingestion throughput and sequential write patterns (WAL + memtable flush + compaction). citeturn14search0turn12search18  
- Range scans can produce an adjacency list efficiently *if* your edge keys are prefix-grouped by `(graph_id, src_id, dir, type, …)`. citeturn21search0turn12search2

Interpretation — Weaknesses:
- Write amplification from compaction is intrinsic and can dominate cost under update-heavy workloads; budgeting it is hard in multi-tenant scenarios. citeturn12search2turn12search18  
- Traversal is “many small range scans”; multi-hop workloads can become cache-thrashy unless your block cache is extremely effective and your working set is small. citeturn12search2turn21search0  
- Rich secondary indexing (full-text, spatial, vector) becomes a system-of-systems problem: each index is its own LSM or its own store with independent compaction and WAL, increasing operational risk.

### Option 4: Hybrid adjacency + columnar properties

Fact — VLDB work on columnar storage for graph DBMS argues that column-oriented layouts plus list-based processing can benefit graph workloads, particularly when scanning/aggregating properties at scale, but it does not remove the need for adjacency-efficient storage. citeturn21search13

Interpretation — This is the best fit when you expect heavy analytical scans over properties (group-bys, aggregations, feature extraction) while still needing OLTP traversals.

### Decision matrix

Scoring scale: 1 (poor) to 5 (excellent). “Complexity/risk” is reversed: 5 = simplest/lowest risk.

| Candidate layout | Traversal latency | Point lookup latency | Write throughput | Space amplification | Write amplification | Crash recovery time | Complexity / risk |
|---|---:|---:|---:|---:|---:|---:|---:|
| Record-store + pointer chains | 3 | 5 | 4 | 3 | 3 | 4 | 4 |
| Adjacency segments + delta store | 5 | 4 | 4 | 3 | 3 | 4 | 2 |
| LSM/KV sorted keys | 3 | 3 | 5 | 2 | 2 | 3 | 3 |
| Hybrid adjacency + columnar props | 5 | 4 | 3 | 3 | 3 | 4 | 2 |

Interpretation (why these scores are defensible):
- Traversal: sequential adjacency scans are explicitly the design goal in LiveGraph and CSR+delta systems, hence 5; pointer chains are “index-free” but not inherently locality-preserving, hence 3. citeturn12search21turn12search9turn12search0turn21search7  
- Write throughput: LSM is optimized for sustained write throughput via log+compaction, hence 5; page stores and delta adjacency can be 4 with batching and group commit. citeturn14search0turn12search2turn20view0  
- Write amplification: LSM compaction trade-offs are documented and intrinsic; page-store physical WAL has unavoidable “double write” but typically less churn than repeated compaction rewrites. citeturn12search2turn13search1turn20view0  
- Complexity: CSR+delta and hybrid designs require careful correctness work (merge semantics + MVCC + index maintenance). citeturn12search21turn12search15turn20view0

Recommendation — Choose **Adjacency segments + delta store (Option 2)** as the core, optionally evolving toward the hybrid (Option 4) by introducing column groups for “hot” properties once the traversal core is stable. citeturn12search21turn21search13turn20view0

## Recommended on-disk design within Geode’s architecture constraints

### File layout diagram

Fact — The baseline already expects a data file, WAL, and index storage, with recovery driven by checkpoints and WAL replay. citeturn20view0turn9view0

Speculation — A practical production directory layout that supports multi-graph isolation, graph drop/clone, and operational tooling looks like:

```text
data_dir/
  catalog.meta               # global catalog + schema/versioning
  wal/
    wal-000001.log
    wal-000002.log
    archive/                 # PITR / WAL archiving targets
  graphs/
    g_<graph_id>/
      meta.pages             # per-graph roots, counters, free lists, checkpoints
      nodes.pages            # NodePage, PropertyPage pointers
      edges.pages            # Relationship/Edge records + edge-property pointers
      adj_out.pages          # Adjacency base blocks (OUT)
      adj_in.pages           # Adjacency base blocks (IN)
      adj_delta.pages        # Adjacency delta blocks (MVCC begin/end + tombstones)
      properties.pages       # overflow and large property payloads
      indexes/
        idx_<id>.btree.pages
        idx_<id>.hash.pages
        idx_<id>.rtree.pages
        idx_<id>.hnsw.pages
        idx_<id>.fts.pages
      stats.meta             # CBO stats, histograms, index stats
  checkpoints/
    checkpoint_<lsn>.meta    # checkpoint manifest (optional global)
```

Interpretation — Per-graph directories avoid a “graph_id in every record” tax and make `DROP GRAPH` nearly O(1) (delete directory + catalog entry), while still allowing a shared WAL for global durability ordering and PITR. This directly supports Geode’s session graph-context model (`USE graph`). citeturn5view0turn4view0turn9view0

### Page and record formats

Fact — Page headers include PageID, PageType, LSN, and checksum; WAL operates at `(page_id, offset, length)` granularity with before/after images. citeturn20view0turn9view0

Speculation — Add a new page type aligned with the existing model:

- `AdjacencyPage`: stores adjacency blocks (base or delta), optimized for sequential scans.

#### Node record

Speculation — Store node records as compact “headers” with pointers to adjacency and properties, while keeping large/uncommon fields in overflow:

```text
NodeRecord (variable-length record in NodePage)
  rid:            64b   # (graph-local) record id: {page_id, slot_id}
  label_set_ref:  64b   # pointer to label set (inline small bitset or overflow)
  prop_head:      64b   # pointer to first PropertyRecord (or inline mini-props)
  adj_out_root:   64b   # pointer to adjacency directory (OUT)
  adj_in_root:    64b   # pointer to adjacency directory (IN)
  mvcc_head:      64b   # pointer to newest Version (or 0 if single-version)
  flags:          16b   # deleted, has_overflow, etc.
```

Interpretation — This matches the executor’s requirement: once you have a node ID, expansion should quickly reach an adjacency iterator (out/in roots) and property reads should be cheap for common cases. citeturn6view0turn20view0

#### Relationship record

Speculation — Treat relationships as first-class objects for:
- edge property access,
- edge-ID stability,
- property indexing.

```text
EdgeRecord (variable-length record in RelationshipPage)
  rid:            64b
  src_rid:        64b
  dst_rid:        64b
  type_id:        32b
  prop_head:      64b
  mvcc_head:      64b
  flags:          16b
```

#### Adjacency storage: base blocks + delta blocks

Fact — Sequential adjacency scans under concurrency are an explicit goal in transactional graph storage research, and CSR+delta is a proven pattern for read locality plus mutable updates. citeturn12search21turn12search9

Speculation — Represent adjacency for each node as:
- **Base**: immutable adjacency blocks (per direction, optionally per type_id), containing `(dst_rid, edge_rid, type_id)` tuples in a compact, scan-friendly form.
- **Delta**: append-only delta blocks containing inserts and tombstones, each with MVCC metadata.

```text
AdjacencyBaseBlock (stored in AdjacencyPage)
  owner_node_rid: 64b
  dir:            8b    # OUT or IN
  type_id:        32b   # 0 means mixed-type
  entry_count:    16b
  next_block:     64b
  encoding:       8b    # delta-encoded dst ids, varint, etc.
  entries[]:             # repeat entry_count times
    dst_rid:      varint/64b
    edge_rid:     varint/64b
    # type omitted if block is per-type
```

```text
AdjacencyDeltaBlock (stored in AdjacencyPage)
  owner_node_rid: 64b
  dir:            8b
  type_id:        32b
  entry_count:    16b
  next_block:     64b
  entries[]:
    op:           8b    # INSERT or DELETE
    edge_rid:     varint/64b
    dst_rid:      varint/64b   # present for INSERT
    begin_txn:    64b          # creator txn id
    end_txn:      64b          # deleter txn id or 0
```

Interpretation — This keeps the hot traversal path mostly sequential (scan base blocks) and bounds MVCC overhead to the delta layer most of the time. It’s the same core idea as CSR+delta (LLAMA) but mapped onto a page-store with WAL. citeturn12search9turn20view0

### Multi-graph support on disk

Fact — Multi-graph is a first-class language concept (`CREATE GRAPH`, `USE`), and sessions operate in a current-graph context. citeturn5view0turn4view0

Interpretation — Disk namespacing must ensure:
- graph-local ID spaces,
- graph-local indexes and stats,
- graph drop/clone without scanning global files.

Speculation — Use a hybrid of:
- **Per-graph physical partitioning** (directory + per-graph file set), and
- A **global catalog** mapping graph_name → graph_id → root pointers and schema versioning.

This makes:
- `DROP GRAPH g`: delete `graphs/g_<id>/` after ensuring no active transactions are using it.
- `CLONE GRAPH g TO g2`: filesystem-level copy-on-write snapshot at the directory level (if the FS supports reflinks) or a logical copy process with shared base + new deltas.

### MVCC and serializable isolation integration

Fact — The baseline MVCC model uses version chains and snapshot visibility based on transaction IDs and an active transaction set. citeturn20view0

Fact — Serializable Snapshot Isolation (SSI) is a well-studied technique that detects “dangerous structures” of rw-conflicts to prevent anomalies while still running on snapshots; PostgreSQL’s SSI implementation and the underlying Cahill work are canonical references. citeturn12search15turn12search3turn12search23

Interpretation — You cannot treat SSI as “just MVCC with a stronger label.” To prevent phantoms, your engine must (a) detect rw-conflict patterns and (b) model predicate/range reads in a way that conflicts can be noticed.

Speculation — A workable design split:
- **Node/Edge/Property records**: keep Geode’s version-chain MVCC as-is (each update creates a new version, old versions retained until vacuum). citeturn20view0  
- **Adjacency**: use delta blocks with begin/end txns and compact into base; base is “committed history” and delta encodes changes. Snapshot reads merge base+delta and apply visibility via begin/end txns (cheap checks). citeturn12search9turn20view0  
- **SSI conflict tracking**:
  - Track rw-conflicts at the logical key level for indexed predicates (index range + equality bucket), similar in spirit to SSI predicate modeling. citeturn12search23turn12search15  
  - For adjacency traversal predicates like “neighbors via type_id=K”, model read-dependencies at `(node_rid, dir, type_id)` granularity (i.e., you read the adjacency list “predicate”). Writers that insert/delete edges into that list register conflicts.

This avoids having to “predicate lock” arbitrary graph patterns, while still capturing the key phantom surface: adjacency membership and index range membership.

### WAL, checkpoints, and recovery

Fact — WAL correctness requires that log records describing changes reach stable storage before the corresponding data pages are persisted (“write-ahead” rule). citeturn13search1turn20view0

Fact — ARIES-style recovery uses analysis, redo (repeat history), and undo, and logs undo actions to remain correct under repeated crashes. citeturn13search0turn9view0turn20view0

Fact — Memory-mapped I/O adds a sharp edge: if the OS flushes dirty pages before the WAL is durable, you can violate WAL ordering unless you explicitly control flush ordering. citeturn13search14turn20view0

Speculation — Implementation-level requirements for WAL + mmap:
- Maintain a **page-dirty table** with each page’s “first dirtied LSN” (recLSN concept) and only allow `msync` of dirty ranges after the WAL is flushed to at least that LSN.
- Make checkpointing a two-phase protocol:
  1) flush WAL up to checkpoint LSN,  
  2) flush eligible dirty pages with pageLSN ≤ flushed WAL LSN,  
  3) write checkpoint record/manifest. citeturn13search13turn9view0turn20view0

#### Crash timeline walkthrough

Fact — The documented recovery process is: load last checkpoint, scan WAL from checkpoint LSN, redo committed transactions, undo uncommitted ones. citeturn9view0turn20view0

Speculation — Example:
1) Txn 105 creates an edge:
   - Appends a delta adjacency INSERT entry to `adj_delta.pages`.
   - Inserts an `EdgeRecord` in `edges.pages`.
   - Updates a property index leaf page.
   These generate multiple physical WAL records (byte-range diffs), then a commit record.
2) Crash occurs after WAL flush but before all dirty pages `msync`.
3) Recovery:
   - Analysis finds Txn 105 committed.
   - Redo replays after-images for the changed pages (idempotent because pageLSN checks).
   - Undo rolls back any loser transactions by replaying before-images for their changes (or CLRs if implemented).
Result: adjacency delta, edge record, and index entries are brought back into a consistent committed state.

## Operational lifecycle and production table stakes

### Compaction and vacuum

Fact — Geode already exposes compaction configuration and a “dead space” threshold trigger. citeturn20view0

Interpretation — You need two separate background maintenance pipelines:
- **MVCC vacuum**: reclaims old versions in node/edge/property stores once no snapshot can see them.
- **Adjacency compaction**: merges delta blocks into base blocks, eliminating tombstones and restoring “mostly sequential scans.”

Speculation — A safe vacuum/compaction policy:
- Let `xmin = snapshot.min_active_txn` (the oldest active transaction ID) from MVCC. citeturn20view0  
- MVCC vacuum may reclaim any version whose end_txn < xmin.
- Adjacency compaction may fold delta entries where:
  - begin_txn and end_txn are both < xmin (i.e., history is stable), and
  - the resulting base block remains immutable.

### Checksums and corruption handling

Fact — Page headers include checksums; WAL records also include checksums; recovery tooling includes explicit verification and repair guidance. citeturn20view0turn9view0

Interpretation — With a graph store, silent corruption is brutal because it can surface as “wrong neighbors,” not just a failed lookup. Page-level checksums plus WAL-based repair are table stakes for correctness under real disks. citeturn9view0turn20view0

### Encryption at rest and key management

Fact — Geode’s overview explicitly states transparent data encryption (TDE) for disk and WAL using AES-256-GCM. citeturn18search1turn17search3

Interpretation — The storage layout should assume:
- data pages and index pages can be encrypted page-wise,
- WAL segments are encrypted independently for PITR archives,
- page checksums must be computed over ciphertext or include an authenticated mode tag (AES-GCM already provides integrity if used correctly). citeturn18search1turn20view0

### Backups and PITR

Fact — PITR is supported via WAL archiving + base backups; recovery procedures describe restoring a base backup and applying WAL to a target time. citeturn9view0turn17search3

Interpretation — The per-graph directory layout simplifies selective backup/restore (graph-scoped) *if* WAL includes graph identifiers or WAL replay can be constrained by file set.

### Schema evolution and online index build

Fact — Geode’s migration guidance includes explicit “schema evolution” patterns (adding properties/labels, then adding constraints) and operational guidance around index build timeouts and an index build status concept. citeturn11search1turn17search3

Fact — PostgreSQL documents a concrete blueprint for online (concurrent) index build: create an invalid index entry first, then multiple scans with waits for old transactions, finally mark valid. citeturn14search3

Speculation — For Geode:
- Implement online index build with a **shadow index** that receives new writes via the normal path while a background scan backfills old data.
- At cutover, validate by re-scanning deltas since the scan start LSN and then atomically flip the catalog pointer.

### Monitoring hooks and observability

Fact — Monitoring endpoints and key metrics are already documented: `/metrics`, `/health`, `/ready`, `/live`, with metrics for query latency, cache hits/misses, WAL bytes written, index lookups, disk usage, and backup health. citeturn19view0

Fact — Advanced telemetry includes distributed tracing configuration snippets (OTLP/Jaeger/Zipkin), structured logs, and log aggregation examples. citeturn19view0turn19view2

Interpretation — This is enough observability surface to run storage experiments safely: you can correlate cache hit ratio, WAL throughput, compaction activity, and query latency regressions without guessing. citeturn19view0turn20view0

## Benchmark plan and de-risk experiments

Fact — Geode publishes a benchmarking guide that explicitly distinguishes read-heavy, write-heavy, mixed OLTP, analytical, and graph traversal workloads, and emphasizes reproducibility and statistical rigor. citeturn17search0

### Microbenchmarks

Interpretation — You want microbenchmarks that isolate each storage-critical path with stable query shapes and controlled selectivity:

- **Adjacency expand (single-hop)**: choose random nodes by degree bucket; run `(n)-[:T]->(m)` and measure:
  - p50/p95/p99 latency,
  - storage cache hit ratio,
  - pages touched per expand.
  (This directly targets the executor’s expand loop.) citeturn6view0turn19view0

- **Adjacency expand + property predicate**:
  - seed nodes by indexed property (hash or btree),
  - expand 1-hop, apply a property filter on target nodes.
  This tests “index seek → expand → point lookups” end-to-end. citeturn7view1turn8view0turn6view0

- **Variable-length path**:
  - `*1..k` with k in {2,3,5},
  - measure scaling of pages touched per hop,
  - verify early termination behavior with selective predicates. citeturn5view0turn6view0

- **Write paths**:
  - edge insert bursts into high-degree nodes,
  - mixed inserts+deletes (to generate tombstones),
  - measure WAL bytes per logical mutation and compaction throughput. citeturn20view0turn19view0turn9view0

- **SSI stress**:
  - classic rw-conflict patterns and phantom-susceptible patterns; validate abort rates and ensure serializability. citeturn12search15turn12search3turn20view0

### Dataset suggestions and scaling plan

Fact — entity["organization","LDBC","linked data benchmark council"]’s Social Network Benchmark defines graph workloads with both interactive and BI components, intended to fairly test graph-like data management. citeturn22search0turn22search12turn22search8

Fact — entity["book","WatDiv","waterloo sparql diversity test suite"] provides a configurable generator and query/template generator designed to span a wide spectrum of structural query patterns and selectivity classes (RDF-oriented, but structurally valuable for property-graph pattern stress). citeturn22search5turn22search25

Fact — entity["organization","Stanford Large Network Dataset Collection","snap dataset repository"] provides many large real-world network datasets (social, citation, collaboration, road networks). citeturn22search3turn22search7

Fact — entity["organization","OpenStreetMap","open street map project"] road network datasets are used in shortest-path benchmarking and are a strong representative for sparse, path-heavy graphs. citeturn22search18turn22search2

Interpretation — Scaling plan (keep it simple, but meaningful):
- Scale graphs by node count and degree distribution separately:
  - many small graphs (10³–10⁵ nodes each),
  - one large graph (10⁷–10⁸ nodes),
  - mixed multi-tenant (100–10,000 graphs with skewed sizes).
- For each scale, run the same microbenchmarks and record:
  - p99 expand latency,
  - pages touched per hop,
  - WAL MB/s and checkpoint time,
  - compaction lag and space amplification.

### Open questions and minimal experiments

Open questions (highest risk first):
- How should adjacency deltas be merged to preserve sequential scans while minimizing stalls under write load?
- What is the best granularity for “adjacency predicate” conflict tracking for SSI to avoid excessive false-positive aborts?
- How should specialized indexes (HNSW, BM25) be versioned or validated under MVCC without turning commit into a bottleneck? citeturn8view0turn17search2turn12search3  
- What is the operational ceiling on number-of-graphs-per-database before file/directory management becomes a bottleneck (especially under heavy PITR retention)?

Minimal de-risk experiments:
- Implement only adjacency base+delta and a read-path merge; benchmark `relationshipIterator()` throughput vs pointer-chain baseline. citeturn6view0turn12search21  
- Prototype two compaction policies (size-tiered vs leveled-equivalent within adjacency deltas) and compare write amplification and read p99; use RocksDB’s compaction trade-offs as the conceptual guide. citeturn12search2turn12search18  
- Implement SSI adjacency conflict tracking at two granularities:
  - coarse `(node, dir, type)` and
  - finer `(node, dir, type, dst-range)` (if adjacency blocks are sorted),
  and compare abort rates on synthetic anomaly workloads. citeturn12search15turn12search23

## Search log and evidence map

### Search log

Date: 2026-02-02 (America/New_York)

Queries executed (representative):
- “site:geodedb.com Storage Engine Architecture”
- “site:geodedb.com Transactions MVCC SSI WAL recovery”
- “site:geodedb.com Index Types Reference”
- “site:geodedb.com GQL CREATE GRAPH USE graph context”
- “Neo4j data on disk linked list of fixed size records”
- “LLAMA Efficient graph analytics using Large Multiversioned Arrays pdf”
- “LiveGraph transactional graph storage purely sequential adjacency scans pdf”
- “LSM-tree O’Neil 1996 pdf” and “RocksDB compaction wiki”
- “PostgreSQL Serializable Snapshot Isolation Ports Grittner paper”
- “ARIES recovery method Mohan 1992 pdf”
- “LDBC SNB specification pdf” and “WatDiv benchmark University of Waterloo”
- “Geode monitoring Prometheus metrics endpoint :8080/metrics”

### Evidence map

```json
{
  "geode_baseline_storage_mvcc_wal": ["turn20view0", "turn9view0"],
  "geode_query_execution_optimizer_access_patterns": ["turn6view0", "turn7view0", "turn7view1"],
  "geode_index_families": ["turn8view0", "turn17search2", "turn20view0"],
  "geode_multi_graph_semantics": ["turn5view0", "turn4view0"],
  "geode_operations_monitoring_backup": ["turn19view0", "turn19view2", "turn9view0", "turn17search3"],
  "pointer_chain_record_store_reference": ["turn12search0", "turn12search24", "turn21search3", "turn21search7"],
  "adjacency_delta_csr_transactional_research": ["turn12search9", "turn12search21"],
  "lsm_kv_tradeoffs_compaction": ["turn14search0", "turn12search2", "turn12search18"],
  "kv_row_adjacency_graph_db_example": ["turn21search0", "turn21search28"],
  "ssi_foundations_and_practice": ["turn12search15", "turn12search3", "turn12search23"],
  "wal_recovery_foundations": ["turn13search0", "turn13search1", "turn13search14"],
  "benchmark_datasets": ["turn22search0", "turn22search8", "turn22search5", "turn22search3", "turn22search18"],
  "geode_benchmarking_guidance": ["turn17search0"]
}
```
