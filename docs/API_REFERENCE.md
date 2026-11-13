# Geode API Reference

## Index Operations

### CREATE INDEX

Creates an index on node properties for improved query performance.

#### Syntax

```gql
CREATE INDEX [IF NOT EXISTS] index_name
ON label(property[, ...])
[USING {btree | hash | fulltext | spatial | vector}]
```

#### Parameters

- `CREATE UNIQUE INDEX` is refused with `0A000` (`UniqueIndexNotSupported`,
  SONNY-6281): it used to build a plain index and ignore `UNIQUE`. Declare
  uniqueness with `CREATE CONSTRAINT ... IS UNIQUE` (enforced; see
  Constraint Operations below)
- `IF NOT EXISTS`: Optional. Prevents error if index already exists
- `index_name`: Name of the index to create. A name is one index of a
  graph (SONNY-6294): a second `CREATE INDEX` with a name the graph already
  uses, on any label, is refused with 42P07 (`DuplicateIndex`), and with
  `IF NOT EXISTS` does nothing. Another graph may use the name, except for
  vector and the other advanced index types (`IndexNameInUseByOtherGraph`).
- `label`: Node label to index
- `property`: Property or properties to index
- `USING`: Optional. Specifies index type (default: btree)

#### Index Types

##### btree (Default)

B-tree index for range queries and sorted access.

```gql
CREATE INDEX person_age_idx ON Person(age) USING btree;
```

##### hash

Hash index for exact match lookups.

```gql
CREATE INDEX person_email_idx ON Person(email) USING hash;
```

##### fulltext

Full-text search index with tokenization and ranking.

```gql
CREATE INDEX article_content_idx ON Article(content) USING fulltext;
```

##### spatial

R-tree index for geographic and spatial data.

```gql
CREATE INDEX location_coords_idx ON Location(coordinates) USING spatial;
```

##### vector

HNSW index for vector similarity search.

```gql
CREATE INDEX embedding_idx ON Document(embedding) USING vector;
```

### DROP INDEX

Removes an existing index.

#### Syntax

```gql
DROP INDEX [IF EXISTS] index_name
```

#### Parameters

- `IF EXISTS`: Optional. Prevents error if index doesn't exist
- `index_name`: Name of the index to drop

#### Behaviour

- **Resolution:** the session graph's index of that name, else an
  engine-wide one (written by an older, engine-global catalog), else a
  fulltext index of the default graph. Another graph's index is not found.
- **Missing name:** refused with 42704 (`IndexNotFound`); with `IF EXISTS`
  the statement does nothing and succeeds.
- **One name on several labels** (only in a catalog written before index
  names were unique per graph): every row of the name in the resolved scope
  is dropped, and the result carries a note saying so (SONNY-6294).
- **Locking:** the server takes the session graph's write lock (SONNY-6294;
  it took the default graph's). A fulltext index lives in the default
  graph: from a session on another graph its DROP is refused (0A000); run
  `USE GRAPH default; DROP INDEX <name>`.

#### Example

```gql
DROP INDEX IF EXISTS person_age_idx;
```

## Constraint Operations

### CREATE CONSTRAINT

Records a constraint in the session graph's catalog. A name is one
constraint of a graph (SONNY-6294): a second `CREATE CONSTRAINT` with a
name the graph already uses, on any label, is refused with 42710
(`ConstraintAlreadyExists`), and with `IF NOT EXISTS` does nothing.

#### Syntax

```gql
CREATE CONSTRAINT [IF NOT EXISTS] name FOR (n:Label) REQUIRE n.prop IS UNIQUE
CREATE CONSTRAINT [IF NOT EXISTS] name FOR (n:Label) REQUIRE (n.a, n.b) IS NODE KEY
CREATE CONSTRAINT [IF NOT EXISTS] name ON :Label ASSERT prop IS UNIQUE
CREATE CONSTRAINT [IF NOT EXISTS] name ON :Label ASSERT (a, b) IS UNIQUE
CREATE CONSTRAINT [IF NOT EXISTS] name FOR (n:Label) REQUIRE n.prop IS NOT NULL
CREATE CONSTRAINT [IF NOT EXISTS] name ON :Label ASSERT EXISTS (prop)
```

#### UNIQUE enforcement

A `UNIQUE` constraint, and the uniqueness half of `NODE KEY`, is enforced
on every write (SONNY-2846):

- **When:** at the end of each statement, before its changes are kept (the
  SQL rule for a constraint that is not deferred). A statement that would
  leave two nodes with one key fails with SQLSTATE `23505`
  (`unique_violation`) and none of its changes are kept, also for a
  multi-element `CREATE`. A swap (`SET a.id = b.id, b.id = a.id`) is
  allowed. `CREATE`, `MERGE` (when it creates), `MERGE ... ON CREATE SET` /
  `ON MATCH SET`, `SET n.prop = ...`, `SET n:Label` and procedures are all
  checked; so are the server's bulk write fast paths, which hand such a
  write to the executor.
- **Scope:** per graph (the constraint's own; a row written by an older,
  engine-global catalog applies in every graph, each graph checked on its
  own) and per tenant tag: nodes of two tenants may hold the same value, so
  a refusal never tells one tenant what another holds. In a single-tenant
  deployment this is graph-wide.
- **NULL:** a missing or `NULL` property is never a conflict. A composite
  key conflicts only when every property is present and equal.
- **Equality:** the rule MERGE and inline property maps match by: numbers
  by exact value (`1` = `1.0`, `1.5` = `1.50`; a DOUBLE `0.1` is not the
  decimal `0.1`), strings by their Unicode NFC form (an NFC and an NFD
  spelling are one value, as the `=` operator compares them; SONNY-3055),
  `'1'` is not `1`.
- **Existing data:** `CREATE CONSTRAINT ... IS UNIQUE` (or `NODE KEY`) over
  nodes that already share a value is refused with `23505`, naming how many
  groups of nodes share one; remove the duplicates first.
- **Cost:** the other holder is found through the exact node-property index
  (one lookup per checked node) when it can answer: full index mode, the
  index built, and a number, string or boolean value. Otherwise (lean mode,
  `GEODE_INDEX_MERGE_KEYS_ONLY=1`; the index still rebuilding after a
  restart; an in-memory session; a list, temporal or other value) by a scan
  of the label's nodes, for each node the statement wrote under a
  constrained label.
- **Fast paths:** the server's simple-CREATE, bulk MERGE, `/*+BATCH*/` and
  `USE GRAPH g; MERGE` fast paths do not serve a graph that has a UNIQUE
  constraint; those writes run through the executor (slower). A fast-path
  write already past that check when the constraint is created is refused
  with `40001`; retry it.
- **Cluster mode:** constraint DDL is refused in cluster mode. A leader
  refuses (`40001`, `ClusterWriteNotReplicable`) a replicated write, other
  than a delete, on a graph a UNIQUE constraint applies in.

#### NOT NULL, EXISTS and NODE KEY enforcement

`REQUIRE n.prop IS NOT NULL`, the legacy `ASSERT EXISTS (prop)` and the
existence half of `NODE KEY` are enforced on every write (SONNY-6281):

- **Rule:** every node of the label in the constraint's graph holds each
  named property with a value that is not `NULL`. GQL treats a property
  whose value is null as absent, so a missing and a `NULL` property are the
  same violation.
- **When:** at the end of each statement, like UNIQUE. A statement that
  would leave such a node without the property fails with SQLSTATE `23502`
  (`not_null_violation`, `NotNullConstraintViolation`; the message names
  the constraint, never a value) and none of its changes are kept.
  `CREATE`, `MERGE` when it creates (unless `ON CREATE SET` supplies the
  property), `SET n.prop = NULL`, `SET n = {...}` without it, `REMOVE
  n.prop` and `SET n:Label` on a node without it are refused. A statement
  may create a node and set the property later in the same statement.
  `REMOVE n:Label` frees the node from the constraint.
- **Existing data:** `CREATE CONSTRAINT` of these kinds over nodes that
  lack the property is refused with `23502`, naming how many nodes lack
  it; set the property or remove those nodes first.
- **Fast paths and cluster mode:** as for UNIQUE: every enforced
  constraint, of any kind, sends the server's node-writing fast paths to
  the executor (`40001` for a write already past that check), and a leader
  refuses a replicated non-delete write on a graph a constraint applies in.
- **NODE KEY:** both halves: a missing key property is `23502`, a duplicate
  key `23505`.
- **Standard:** ISO/IEC 39075:2024 defines no `CREATE CONSTRAINT` (these
  statements are Geode extensions in the openCypher form); the rule follows
  its `NOT NULL` property value types.

#### Example

```gql
CREATE CONSTRAINT person_email FOR (p:Person) REQUIRE p.email IS UNIQUE;
CREATE (:Person {email: 'a@example.com'});
CREATE (:Person {email: 'a@example.com'});  -- 23505, nothing written
```

### DROP CONSTRAINT

Removes a constraint from the session graph's catalog (SONNY-6270).

#### Syntax

```gql
DROP CONSTRAINT [IF EXISTS] name
```

#### Behaviour

- **Resolution:** the session graph's constraint of that name, else an
  engine-wide one (written by an older, engine-global catalog). A
  constraint of another graph is not found. Constraints of one name on
  several labels of the graph (only in a catalog written before constraint
  names were unique per graph, SONNY-6294) are all dropped.
- **Missing name:** refused with 42704 (`ConstraintNotFound`), as DROP
  INDEX refuses a missing index (`IndexNotFound`); with `IF EXISTS` the
  statement does nothing and succeeds.
- **Engine-wide row:** dropped from any graph, it is gone for every graph.
- **Enforcement:** a UNIQUE or NODE KEY constraint stops being enforced as
  soon as the statement succeeds. When no UNIQUE constraint applies in the
  graph any more, the server's bulk write fast paths serve it again.
- **Durability:** the catalog is saved before the statement succeeds; a
  dropped constraint stays dropped after a restart. If the save fails the
  statement fails and the constraint stays, enforced.
- **Permissions:** as CREATE CONSTRAINT: schema on the session's graph and
  on the database; an engine-wide constraint also needs schema on
  `default`. Checked before the name is looked up.
- **Transactions:** DDL is not transactional. A ROLLBACK does not bring
  back a constraint dropped in the transaction; DROP CONSTRAINT is refused
  inside a `START TRANSACTION { ... }` body.
- **Cluster mode:** refused, as all constraint DDL is.

#### Example

```gql
DROP CONSTRAINT person_email;
DROP CONSTRAINT IF EXISTS person_email;  -- no error
```

## Backup and Restore

> **Status (GAP-0862, 2026-06-10): the GQL `BACKUP TO` / `RESTORE FROM`
> statement surface below is NOT executed.** The parser accepts these
> statements, but the query executor returns `NotImplemented`
> (SQLSTATE `0A000`, "feature not supported"); the `INCREMENTAL`,
> `METADATA ONLY`, `TIMESTAMP`, and `VERIFY ONLY` forms additionally fail to
> parse. The **implemented and supported** backup/restore surface is the CLI:
>
> ```bash
> geode backup create --output ./full.backup [--compress]   # full backup from the server (--server)
> geode backup create --output ./full.backup --local --data-dir /var/lib/geode  # from a local data directory
> geode restore ./full.backup --data-dir /var/lib/geode-restored --yes  # restore a backup file, offline
> geode backup list [--dir ./backups]                        # list local backups
> geode backup info ./full.backup                            # decode a backup's header
> geode backup cleanup --dir ./backups --older-than 30d [--yes]  # delete old backups (dry run without --yes)
> ```
>
> `geode backup info` decodes the header through the same range-checked
> function as restore and exits 1 with `error: <Name>` for a file that is
> not a geode backup or whose header is damaged or truncated (it does not
> verify the payload; restore does). `geode backup cleanup` (SONNY-6289)
> needs `--dir` and `--older-than <n>s|m|h|d|w`; without `--yes` it only
> lists what it would delete. It considers only regular files directly in
> `--dir` whose header decodes as a geode backup (never symlinks or
> subdirectories), ages them by the header's timestamp, never deletes the
> newest one, removes deleted backups from the directory's `metadata.json`,
> reports every file, and exits 1 if a deletion fails. (Until SONNY-6289
> cleanup printed "Backup cleanup completed" and deleted nothing, and
> `backup info` crashed on every header.)
>
> `geode restore <file>` writes the backup into `--data-dir` (or
> `GEODE_DATA_DIR`), which must not exist or be empty; no server is
> contacted. It verifies the whole backup first, writes into a staging
> directory beside the target, compares every restored file with the
> backup, opens the restored store, and only then moves it onto the target
> and prints `Restore completed successfully` with each graph's node and
> edge counts. Any failure exits non-zero with `error: <Name>` and leaves
> nothing at the target. Restoring from an `s3://` or `http(s)://` URI is
> not supported (geode has no object-storage path; a `backup create
> --output` URI is refused too); download the file first. (From 2026-03-28
> until SONNY-6280 this command wrote nothing and still reported success.)
> The checks that open the restored store (graph counts, the auth-chain
> check) run on a throwaway copy beside the target, so the committed
> directory holds exactly the backup's files plus the HMAC key file
> (SONNY-6348); the restore needs the backup's size again in free disk while
> it runs. `geode backup create` and `geode restore` refuse options they do
> not know (SONNY-6290).
>
> **Server restore (QUIC `restore`, gRPC `/geode.GeodeService/Restore`,
> `geode restore --server <addr>` with no file; SONNY-6288):** Admin only,
> audited (`SERVER_RESTORE`), refused in cluster mode, and needs
> `confirm`. The server restores its newest backup in its backup directory
> (and, for one release, the legacy `./server_backups/`; see below)
> taken at or before `target_time` (epoch milliseconds; empty means now;
> anything else is refused) into a **new** directory beside the data
> directory its storage engine has open, named
> `<data dir>.restored-<backup id>-<ms>`. It never writes into its data
> directory: a running server cannot swap its store under its open
> engines. The restore is written into a staging directory, compared file
> by file with the backup, opened as a store and counted per graph, and
> only then renamed into place. The response (`success`, `message`,
> `restore_dir`) names the directory and each graph's node and edge
> counts; the server keeps serving its current data until it is stopped
> and started with `--data-dir <restore_dir>`. A failed restore reports
> `Restore failed: <Name>` and leaves no new directory. (Until SONNY-6288
> the server restored into `GEODE_DATA_DIR` or `./data`, never its
> `--data-dir`, in place and without staging, and answered "Restore
> completed" while serving its old data.)
>
> If the server backup fails (unreachable, timeout, stalled transfer, server
> error), `backup create` exits 1, leaves no output file and does not fall
> back to a local backup. A local data-directory backup runs only with
> `--local`, which needs `--data-dir` or `GEODE_DATA_DIR`; it is written
> once, at `--output` (until SONNY-6323 it also left `full_<id>.backup` and
> `metadata.json` beside it). The CLI waits up to 300 s for the server's
> answer to a backup or a server restore; `--timeout <seconds>` changes
> that (SONNY-6300; it was a fixed 30 s). A server restore cannot replace a
> running server's live store: there is no in-place restore.
>
> The CLI is engine-backed by `BackupManager` (`src/storage/backup.zig`):
> full backup of the per-graph storage tree with CRC32 integrity verification
> on restore. **Supported compression codecs (GAP-0880, 2026-06-10): `none`
> and `gzip`.** `--compress` / the wire `compress` flag applies a real gzip
> (DEFLATE) encoder and the backup header/metadata record the codec actually
> applied; requesting `zstd`/`lz4` fails with `UnsupportedCompression`
> (decode-only zstd support is retained for old artifacts). Restore
> data-integrity (node/edge counts + property round-trip + checksum
> rejection) is regression-tested by `zig build test-gap0862`; the gzip
> round-trip + magic-byte verification by `zig build test-gap0880`. The GQL
> forms below are retained as a forward-looking grammar sketch; implementing
> any of them MUST also flip the `UNSUPPORTED` assertions in
> `tests/backup_restore_test.sh` / `tests/backup_restore_regression_test.sh`.
>
> **Backup upload (protocol, GAP-0880):** the QUIC/gRPC `upload_backup`
> message carries the complete backup artifact bytes (`payload`, field 4)
> plus declared `size_bytes` and the hex CRC32 `checksum` from the original
> `BackupResponse`. The server verifies size, checksum, and the artifact
> header (magic/version/payload-length/CRC32) BEFORE writing, persists the
> exact bytes into the server's backup directory, and durably registers the backup in
> the metadata log so it is restorable. Metadata-only uploads (no payload)
> are rejected — there is no "upload slot" placeholder path.
>
> **What a backup holds, and where server backups live (SONNY-6299;
> BREAKING, 2026-11):** a backup archives the data directory's graph data
> (`graph_registry.dat`, every per-graph directory, `timeseries/`) and
> never `.geode.lock` (the running process's lock), `.geode_hmac_key` (the
> key that seals the `__geode_security` auth chain), `.geode_admin_password`
> (the generated first-boot password), `server.key` or `server.crt` (the
> auto-generated TLS identity; a server regenerates the pair on first
> start), or the server's own backup directory. Backup files and
> `metadata.json` are mode 0600. A server writes its backups to
> `<data dir>/backups/` (created 0700) of the data directory its storage
> engine has open, whatever its working directory, or to `GEODE_BACKUP_DIR`
> (an absolute path outside the data directory; anything else refuses the
> backup with `InvalidBackupDir`). A server restore still reads the legacy
> `./server_backups/` of its working directory for one release and picks
> the newest backup in either; new backups are never written there, so move
> old ones into `<data dir>/backups/` before that release ends.
>
> **Restoring auth state needs the HMAC key.** Because the key is no longer
> in the backup, `geode restore <file>` of a backup holding
> `__geode_security` records needs the key it was sealed with:
> `--hmac-key-file <source data dir>/.geode_hmac_key` (written into the
> restored directory, mode 0600), or `GEODE_AUTH_HMAC_KEY` / `GEODE_TDE_KEY`
> set as the source server had it. The restore verifies the chain with that
> key before it moves the directory into place; without a key it fails with
> `error: HmacKeyRequired`, with the wrong one `error:
> AuthChainVerificationFailed`, and nothing is restored.
> `--hmac-key-file` cannot be combined with `GEODE_TDE_KEY` or
> `GEODE_AUTH_HMAC_KEY` (`error: HmacKeySourceConflict`, SONNY-6386): a
> server with `GEODE_TDE_KEY` set derives its HMAC key from it
> (`GEODE_AUTH_HMAC_KEY` takes precedence) and never reads `.geode_hmac_key`,
> so a key file would be ignored. An encrypted backup (taken with
> `GEODE_TDE_KEY` set) needs that key to decrypt, so it is always restored
> with the source server's `GEODE_TDE_KEY` (and its `GEODE_AUTH_HMAC_KEY`, if
> it set one), never `--hmac-key-file`. If the key is lost,
> `--unverified-auth` restores the records unverified: no server starts on
> them (`AuthChainTampered`) until an operator who has checked them accepts
> them with `geode auth reseal --data-dir <dir>`, which re-seals them under a
> new key. Keep the HMAC key with your other key material (as for
> `GEODE_TDE_KEY`), separate from the backups. A server restore copies the
> server's own `.geode_hmac_key` into the restored directory, so its own
> backups verify when a server starts there; a backup sealed under another
> key does not. A backup written by an older geode (keys inside) still
> restores: the key files are written mode 0600 with a warning, and its
> `.geode.lock` is never written.

### BACKUP TO

Creates a backup of the database.

#### Syntax

```gql
BACKUP TO 'file_path' [OPTIONS]
```

#### Parameters

- `file_path`: Path where backup file will be created

#### Options

- `COMPRESSED`: Enable gzip compression (NOT executed — see status note above;
  the implemented gzip surface is the CLI `--compress` flag / wire `compress`)
- `INCREMENTAL`: Create incremental backup (requires base backup)
- `METADATA ONLY`: Backup only schema and indexes, not data

#### Examples

```gql
-- Full backup
BACKUP TO '/backups/full_backup.bak';

-- Compressed backup
BACKUP TO '/backups/compressed.bak.gz' COMPRESSED;

-- Incremental backup
BACKUP TO '/backups/incremental.bak' INCREMENTAL FROM '/backups/full_backup.bak';
```

### RESTORE FROM

Restores database from a backup file.

#### Syntax

```gql
RESTORE FROM 'file_path' [TIMESTAMP timestamp] [VERIFY ONLY]
```

#### Parameters

- `file_path`: Path to backup file
- `TIMESTAMP`: Optional. Restore to specific point in time
- `VERIFY ONLY`: Optional. Verify backup integrity without restoring

#### Examples

```gql
-- Basic restore
RESTORE FROM '/backups/full_backup.bak';

-- Point-in-time restore
RESTORE FROM '/backups/full_backup.bak' TIMESTAMP '2024-01-15T10:30:00Z';

-- Verify backup
RESTORE FROM '/backups/full_backup.bak' VERIFY ONLY;
```

## Variable-Length Path Patterns

### Syntax

```gql
(start)-[relationship*min..max]->(end)
```

### Patterns

#### Any Length (*)

Matches paths of any length.

```gql
MATCH (a:Person)-[*]->(b:Company) RETURN b;
```

#### Exact Length (*n)

Matches paths of exactly n hops.

```gql
MATCH (a:Person)-[*2]->(b:Person) RETURN b;
```

#### Range (*min..max)

Matches paths between min and max hops.

```gql
MATCH (a:Person)-[*1..3]->(b:Person) RETURN b;
```

#### Up To (*..max)

Matches paths up to max hops.

```gql
MATCH (a:Person)-[*..5]->(b:Person) RETURN b;
```

#### At Least (*min..)

Matches paths of at least min hops.

```gql
MATCH (a:Person)-[*2..]->(b:Person) RETURN b;
```

### Functions

#### length(path)

Returns the length of a path.

```gql
MATCH path = (a)-[*]->(b) RETURN length(path);
```

#### nodes(path)

Returns all nodes in a path.

```gql
MATCH path = (a)-[*]->(b) RETURN nodes(path);
```

#### relationships(path)

Returns all relationships in a path.

```gql
MATCH path = (a)-[*]->(b) RETURN relationships(path);
```

#### shortestPath()

Finds the shortest path between nodes.

```gql
MATCH path = shortestPath((a:Person)-[*]->(b:Company))
RETURN path;
```

#### allShortestPaths()

Finds all shortest paths between nodes.

```gql
MATCH path = allShortestPaths((a:Person)-[*]->(b:Company))
RETURN path;
```

## Vector Operations

### Vector Search Functions

Both arguments of every function below accept a `VECTORF32`/`VECTORI32` value
(e.g. `vectorf32([1.0, 0.0])` or a stored vector property) **or** a plain
numeric GQL list literal such as `[0.1, 0.2, 0.3]`.

#### similarity(vector1, vector2 [, metric])

Calculates similarity between two vectors (higher is more similar). `metric`
defaults to `'cosine'`; `'dot'`/`'dot_product'` is also accepted. `'l2'` is a
distance, not a similarity, and is rejected — use `distance()` for it.

```gql
MATCH (d:Document)
WHERE similarity(d.embedding, [0.1, 0.2, 0.3]) > 0.8
RETURN d;
```

#### distance(vector1, vector2 [, metric])

Calculates distance between vectors using the specified metric (default `'l2'`).

```gql
MATCH (d:Document)
WHERE distance(d.embedding, [0.1, 0.2, 0.3], 'l2') < 0.5
RETURN d;
```

Supported metrics:

- `'l2'` (alias `'euclidean'`): Euclidean distance
- `'cosine'`: Cosine distance (1 - cosine similarity)
- `'dot'` (alias `'dot_product'`): Negative dot product

#### euclidean(vector1, vector2) / manhattan(vector1, vector2) / cosine(vector1, vector2)

Fixed-metric shorthands: L2 distance, L1 distance, and cosine similarity.

#### knn(property_name, query_vector, k, metric)

Returns the ids of the `k` nearest nodes/edges by a vector-valued property.
`knn` is an alias of `vector_knn`.

Note the FIRST argument is the property NAME as a string — not a vector
expression — because the function scans the graph (or the registered vector
index) for that property. `metric` is required and takes the same values as
`distance()`.

```gql
MATCH (d:Document)
RETURN knn('embedding', [0.1, 0.2, 0.3], 10, 'cosine') AS neighbor_ids;
```

## Spatial Operations

### Spatial Functions

#### point(x, y)

Creates a 2D point.

```gql
CREATE (l:Location {coordinates: point(40.7128, -74.0060)});
```

#### distance(point1, point2)

Calculates distance between two points.

```gql
MATCH (l:Location)
WHERE distance(l.coordinates, point(40.0, -74.0)) < 100
RETURN l;
```

#### within(geometry, boundary)

Tests if geometry is within boundary.

```gql
MATCH (l:Location)
WHERE within(l.coordinates, polygon(...))
RETURN l;
```

#### bbox(min_x, min_y, max_x, max_y)

Creates a bounding box for spatial queries.

```gql
MATCH (l:Location)
WHERE intersects(l.area, bbox(40.0, -75.0, 41.0, -73.0))
RETURN l;
```

## Full-Text Search

### Text Search Functions

#### CONTAINS

Searches for text within a property.

```gql
MATCH (a:Article)
WHERE a.content CONTAINS 'graph database'
RETURN a;
```

#### STARTS WITH

Matches text at the beginning of a property.

```gql
MATCH (p:Person)
WHERE p.name STARTS WITH 'John'
RETURN p;
```

#### ENDS WITH

Matches text at the end of a property.

```gql
MATCH (e:Email)
WHERE e.address ENDS WITH '@example.com'
RETURN e;
```

#### REGEX

Matches using regular expressions.

```gql
MATCH (p:Product)
WHERE p.code =~ '^SKU-[0-9]{4}$'
RETURN p;
```

#### score()

Returns relevance score for full-text search results.

```gql
MATCH (a:Article)
WHERE a.content CONTAINS 'machine learning'
RETURN a, score() AS relevance
ORDER BY relevance DESC;
```

### `CALL geode.fts.search` (BM25 procedure)

In addition to the `CONTAINS` / `STARTS WITH` predicates above, Geode provides a
dedicated BM25-ranked full-text index backed end-to-end by the external
**`fts-storage`** LSM library (durable on disk: WAL + segments + manifest),
surfaced as a native Geode GQL extension.

```gql
CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext;   -- backfills existing nodes
CALL geode.fts.search('doc_idx', 'quick brown');               -- returns node, score rows
DROP INDEX doc_idx;                                            -- server stays alive
```

`CALL geode.fts.search('<index>', '<query>'[, <max>])` returns one row per match
with `node` (the matching node id) and `score` (the BM25 relevance score); the
optional third argument caps the number of results. Results ride the generic GQL
Execute+rows protocol, so they are reachable over the QUIC wire with no client,
proto, or transport changes.

> **Geode extension.** Uses ISO GQL's `CALL` procedure (not a scalar function,
> and not Cypher's `UNWIND … YIELD`). See [FULLTEXT_SEARCH.md](FULLTEXT_SEARCH.md).

Notes:

- The index is maintained incrementally on node create / `SET` / delete,
  including nodes inserted after the index was created.
- Indexes are durable and survive a server restart (lazy re-open on first query).
- **Limitation:** the bulk-MERGE fast path does **not** auto-index its nodes; re-run
  `CREATE INDEX … USING fulltext` to backfill those nodes.

## Index Management

### SHOW INDEXES

Lists all indexes in the database.

```gql
SHOW INDEXES;
```

Returns:

- Index name
- Label
- Properties
- Type (btree, hash, fulltext, spatial, vector)
- Unique constraint
- Statistics (entries, size, last updated)

### ANALYZE INDEX

Updates index statistics for query optimization.

```gql
ANALYZE INDEX index_name;
```

### REBUILD INDEX

Rebuilds an index from scratch.

```gql
REBUILD INDEX index_name;
```

## Transaction Control

### BEGIN

Starts a new transaction.

```gql
BEGIN;
```

### COMMIT

Commits the current transaction.

```gql
COMMIT;
```

### ROLLBACK

Rolls back the current transaction.

```gql
ROLLBACK;
```

### SAVEPOINT

Creates a savepoint within a transaction.

```gql
SAVEPOINT my_savepoint;
```

### ROLLBACK TO

Rolls back to a specific savepoint.

```gql
ROLLBACK TO my_savepoint;
```

## System Functions

### db.info()

Returns database information.

```gql
RETURN db.info();
```

### db.indexes()

Returns index information.

```gql
RETURN db.indexes();
```

### db.stats()

Returns database statistics.

```gql
RETURN db.stats();
```

### db.constraints()

Returns constraint information.

```gql
RETURN db.constraints();
```

## Error Codes

Geode follows ISO/IEC SQL error code standards:

- `00000`: Success
- `0A000`: Feature not supported
- `22000`: Data exception
- `23000`: Integrity constraint violation
- `23505`: Unique violation (a UNIQUE constraint, see Constraint Operations)
- `42000`: Syntax error or access rule violation
- `42P01`: Undefined table
- `42P07`: Duplicate table/index
- `53000`: Insufficient resources
- `58000`: System error
- `XX000`: Internal error

## Performance Tips

### Index Usage

1. Create indexes on frequently queried properties
2. Use a UNIQUE constraint (not an index) for a property that must not repeat
3. Use hash indexes for exact match queries only
4. Use btree indexes for range queries and sorting
5. Use vector indexes for similarity search
6. Use spatial indexes for geographic queries

### Query Optimization

1. Use EXPLAIN to understand query plans
2. Limit result sets with LIMIT clause
3. Filter early in the query with WHERE clauses
4. Use index hints when necessary
5. Avoid cartesian products without filters

### Backup Best Practices

1. Schedule regular full backups
2. Use incremental backups between full backups
3. Enable compression for large databases
4. Verify backups regularly with VERIFY ONLY
5. Store backups in multiple locations
6. Test restore procedures periodically
