# Migration Guide - Grey Cardinal Compliance

## v0.1.0 (Current)

### Backup Encryption (`GEODE_TDE_KEY`)

**Breaking Change:** If encryption is enabled/implemented, a Transparent Data Encryption (TDE) key is now required for backup and restore operations.

**Action Required:**

- Set the `GEODE_TDE_KEY` environment variable before running the server or backup tools.
- The key must be a 64-character hexadecimal string.
- Example: `export GEODE_TDE_KEY=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f`

### Time-Series GQL Functions

New GQL functions are available for Time-Series data access.

**Available Now:**

- `timeseries.value(device_id: Int, metric: String, timestamp: Int) -> Int`
  - Retrieves the value of a metric for a specific device at a given timestamp.
  - Returns `NULL` if no data is found or the store is disconnected.
  - Fully wired through the server execution engine (GAP-0280).

**In Progress (unit-tested, not yet wired to server):**

The following functions are implemented in `src/timeseries/gql_functions.zig`
with full unit test coverage, but are not yet routed through the server
execution engine. They will be available in a future release:

- `last_value`, `value_at`, `sample_by`, `time_bucket`
- `interpolate` (linear, step, nearest methods)
- `moving_avg`, `rate`, `derivative`

### Graph Centrality

- **Deferred:** Advanced metrics (Temporal Centrality, Dominator Tree, Flow Cuts) are deferred to v0.18+.
- **Optimization:** Existing centrality metrics (PageRank, Betweenness) have been optimized for memory usage.
