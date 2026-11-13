# Migration Guide - Grey Cardinal Compliance

## v0.1.0 (Current)

### Backup Encryption (`GEODE_TDE_KEY`)

**Breaking Change (SONNY-6355):** when `GEODE_TDE_KEY` is set, `geode backup
create` (local and server) and the server's QUIC/gRPC backups encrypt the
backup payload with AES-256-GCM under it, and restoring such a backup needs
the same key (`geode restore` and the server restore refuse it without the
key). A `GEODE_TDE_KEY` that is not 64 hex characters fails the backup rather
than writing it in plaintext. Without `GEODE_TDE_KEY`, backups are unencrypted.
Before this, every backup was written unencrypted, whatever the key.

**Action Required:**

- Set the `GEODE_TDE_KEY` environment variable before running the server or backup tools, and keep it to restore.
- The key must be a 64-character hexadecimal string.
- Example: `export GEODE_TDE_KEY=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f`

### Encrypted Stores Written by graph_storage 0.4.11 or Older

**Breaking Change (SONNY-6441, SONNY-6452):** with `GEODE_TDE_KEY` set,
builds pinning graph_storage 0.4.11 or older lost the last 16 bytes of every
encrypted store page (the AES-GCM tag overwrote them): at 8 KiB pages the
node in slot 169 of each node page lost its label count and deleted flag,
and the last two incoming-edge heads of each directory page were lost.
graph_storage 0.4.12 stops the loss and reads the old pages, but cannot
bring the bytes back, and a store it has written cannot be opened by an
older build (`DecryptionFailed`).

**Action Required:**

- Stop the old server cleanly and back up the data directory.
- Before the first start of the new build, run
  `geode storage verify --check tde-page-tail --data-dir <dir>` with
  `GEODE_TDE_KEY` set.
- If it reports damage, run
  `geode storage repair --tde-page-tail --i-have-a-backup --data-dir <dir>`,
  keep its output, and review the nodes it lists as `nodes_liveness_unknown`
  (deleted or not cannot be derived) and `nodes_lost`.
- To roll back, restore the backup; do not start an older build on the
  upgraded directory.

See [TDE File-Level Encryption](TDE_FILE_LEVEL_ENCRYPTION.md), "Upgrading
stores written before graph_storage 0.4.12".

### Cluster Data Written Before SONNY-2726 Stays Tagged `default`

**Known limitation (SONNY-6425 item 9):** before SONNY-2726 a cluster applied
every replicated write (create, batch, delete, MERGE, MATCH ... SET) on the
raft apply thread, which has no request context, so every node and edge a
tenant-scoped session wrote through raft was stored tagged `default`, on
every node, leader included. Since SONNY-2726 a write's raft entry names the
writing session's tenant and is applied under it, but the rows written before
are still tagged `default`: a tenant-scoped session does not see them, and
an unscoped (admin) session sees them as `default` rows.

Geode cannot re-tag them itself. The writer's tenant was never recorded: the
raft entries written before SONNY-2726 carry none, and the store holds only
the `default` tag, so no rule can recover which tenant wrote a row, and a
guessed re-tag would expose one tenant's rows to another. The edge backfill,
`CALL geode.tenant.backfill_edge_tags(...)`, does not help here: it is refused
in a cluster, and it derives an edge's tenant from its endpoints' tags, which
are `default` too. No replicated re-tag command exists.

**Action Required (cluster deployments that had tenant-scoped writers before
upgrading):** the repair is operator-driven, from the operator's own
knowledge of which rows belong to which tenant:

1. Upgrade every node first (SONNY-2726: a node on an older build cannot
   apply a tenant-enveloped entry).
2. As an unscoped admin session, read the affected rows out with their ids,
   for example `MATCH (n:Order) WHERE n.customer = 'acme' RETURN id(n), n`
   (with `geode query --format json`), and their relationships.
3. In a session bound to the right tenant (`HELLO` with that tenant, as the
   application connects), write them again (`CREATE` / `MERGE`, then the
   relationships). These writes replicate under the tenant.
4. Check them from that tenant's session, then, as the admin session, delete
   the old `default` copies by the ids read in step 2
   (`MATCH (n) WHERE id(n) IN [...] DETACH DELETE n`).

The rewritten rows get new node and edge ids. Single-node (non-cluster)
deployments are not affected: their writes were always tagged with the
writing session's tenant.

### Time-Series GQL Functions

New GQL functions are available for Time-Series data access.

**Available Now:**

- `timeseries.value(device_id: Int, metric: String, timestamp: Int) -> Int`
  - Retrieves the value of a metric for a specific device at a given timestamp.
  - Returns `NULL` if no data is found or the store is disconnected.
  - Fully wired through the server execution engine (GAP-0280).

**Available (wired through eval dispatch, GAP-0282):**

The following functions are implemented in `src/timeseries/gql_functions.zig`
with full unit test coverage and routed through the eval dispatch in
`src/eval.zig`. Call them as `timeseries.<function_name>(...)` in GQL:

- `timeseries.last_value(device_id, metric)` — most recent value
- `timeseries.value_at(device_id, metric, timestamp)` — value at specific time
- `timeseries.sample_by(device_id, metric, interval_ms, start_ts, end_ts, aggregation)` — downsampled aggregation
- `timeseries.time_bucket(device_id, metric, bucket_ms, start_ts, end_ts)` — time-bucketed averages
- `timeseries.interpolate(device_id, metric, timestamp, method)` — interpolated value (linear/step/nearest)
- `timeseries.moving_avg(device_id, metric, window_ms, step_ms, start_ts, end_ts)` — sliding window average
- `timeseries.rate(device_id, metric)` — rate of change
- `timeseries.derivative(device_id, metric, order)` — Nth-order derivative

### Graph Centrality

- **Deferred:** Advanced metrics (Temporal Centrality, Dominator Tree, Flow Cuts) are deferred to v0.18+.
- **Optimization:** Existing centrality metrics (PageRank, Betweenness) have been optimized for memory usage.
