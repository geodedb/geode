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
