# Time-Series (timeseries-storage-backed)

> **Geode extension.** The time-series GQL surface (`CALL geode.ts.insert(…)`,
> `CALL geode.ts.range(…)`, …) is a native Geode extension. It is
> ISO-GQL-compliant in form: it uses ISO GQL's `CALL` procedure (not a scalar
> function, and not Cypher's `UNWIND … YIELD`). This is the direct analog of the
> full-text-search surface (`CALL geode.fts.search(…)`).

**Status:** Implemented — backed by the external **`timeseries-storage`** LSM library
**Dependency:** `.timeseries_storage` in `build.zig.zon`
**Modules:**

- `src/timeseries/timeseries.zig` — geode's `Store` wrapper around the `timeseries-storage` engine
- `src/execution/ts_dispatch.zig` — the `geode.ts.*` procedure dispatcher (the analog of `fts_dispatch.zig`)

The `timeseries-storage` library was already the store layer for geode's
time-series data; what is **new** is the native GQL surface to **write** and
richly **query** that store over the wire. Before this family there was no GQL
way to write or range-query time-series over the wire — only scalar read
functions existed.

---

## Overview

A time-series is identified by a `(device_id, metric)` pair, where `device_id`
is an integer and `metric` is a string. Each series is an append-friendly
sequence of `(ts, value)` points. Points are durable (the engine persists them)
and survive a server restart.

The row-returning queries (`range`, `last`, `bucket_avg`, `sample_by`) and the
ingest verbs (`insert`, `insert_many`) are exposed as **procedures** because ISO
GQL surfaces a row set only through `CALL … YIELD`. `YIELD` is optional — a bare
`CALL geode.ts.range(…)` auto-projects its result columns as rows (the same
behavior as `CALL geode.fts.search`).

### Key Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| LSM-backed store | ✅ | external `timeseries-storage` engine (durable) |
| Ingest over the wire | ✅ | `CALL geode.ts.insert` / `insert_many` (mutating) |
| Range / last queries | ✅ | `CALL geode.ts.range` / `last` (read-only) |
| Downsampling | ✅ | `CALL geode.ts.bucket_avg` / `sample_by` (read-only) |
| Durability | ✅ | WAL-first writes; survives restart AND hard kill; fail-closed open on corruption (GAP-0865) |
| Retention | ✅ | opt-in `GEODE_TS_RETENTION_DAYS`; expired segments deleted from disk (GAP-0865c) |
| TDE at rest | ✅ | opt-in `GEODE_TS_TDE=1` + `GEODE_TDE_KEY`; AES-256-GCM over WAL/segments/manifest (GAP-0865e) |
| Backup/restore | ✅ | timeseries trees included in backup artifacts; round-trip verified (GAP-0865d) |
| Inclusive range | ✅ | `range` is inclusive `[start_ts, end_ts]` in both in-memory and durable paths |
| Concurrent ingest | ✅ | Store is mutex-guarded for the QUIC worker pool (leaf-tier lock) |
| Value type | ⚠️ | **integer (`i64`) only** this release — float/decimal values are rejected |
| Wire protocol | ✅ | rides the generic GQL Execute+rows path — no client/proto change |

---

## Quick Start

```gql
-- Ingest a single point: device 1, metric 'cpu.load', ts 1000, value 72
CALL geode.ts.insert(1, 'cpu.load', 1000, 72);

-- Read every point in [0, 2000] (inclusive) — rows of (ts, value)
CALL geode.ts.range(1, 'cpu.load', 0, 2000);
```

Note the integer literals: `value` is `72`, **not** `72.0` (see
[Value Type](#value-type) below).

---

## GQL Surface

> `device_id` is an integer, `metric` is a string, and **all `ts` and `value`
> arguments are integers (`i64`)**. `YIELD` is optional on every procedure.

### Write (mutating)

A read-only user **cannot** run these — they are classified as mutating, so they
require write privilege.

```gql
-- One point → YIELD inserted (count of points written)
CALL geode.ts.insert(device_id, metric, ts, value) YIELD inserted;

-- Many points in one batch (one sort + one durable append) → YIELD inserted
CALL geode.ts.insert_many(device_id, metric, [[ts1, value1], [ts2, value2], ...]) YIELD inserted;
```

Example:

```gql
CALL geode.ts.insert(1, 'cpu.load', 1000, 72);
CALL geode.ts.insert_many(1, 'cpu.load', [[1010, 73], [1020, 71], [1030, 75]]);
```

### Read (read-only)

These classify read-only — a read-only user can query but not ingest.

```gql
-- All points in [start_ts, end_ts] (inclusive) → rows of (ts, value)
CALL geode.ts.range(device_id, metric, start_ts, end_ts) YIELD ts, value;

-- The most recent point → 0 or 1 row of (ts, value)
CALL geode.ts.last(device_id, metric) YIELD ts, value;

-- Average per fixed-width bucket → rows of (bucket_ts, avg)
CALL geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds) YIELD bucket_ts, avg;

-- Downsample by interval with an aggregation → rows of (bucket_ts, value)
-- agg ∈ avg | sum | min | max | count | first | last
CALL geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg) YIELD bucket_ts, value;
```

Example:

```gql
CALL geode.ts.range(1, 'cpu.load', 0, 2000);                          -- rows of (ts, value)
CALL geode.ts.last(1, 'cpu.load');                                    -- newest (ts, value)
CALL geode.ts.bucket_avg(1, 'cpu.load', 0, 3600, 60);                -- 60s buckets
CALL geode.ts.sample_by(1, 'cpu.load', 60000, 0, 3600000, 'max');    -- per-minute max
```

`last` on an empty/missing series returns 0 rows (not an error). For
`bucket_avg` / `sample_by`, an empty bucket yields a `NULL` value.

---

## Value Type

**Integer (`i64`) only in this release.** Both `ts` and `value` arguments are
integers. A GQL float/decimal literal (e.g. `100.0`) for a `ts` or `value`
argument is **rejected with a clear error** — there is no wired float lane
through the Store, and accepting a Double would force a silent lossy choice. Use
`100`, not `100.0`.

A float (`f64`) value lane is a deferred, explicit follow-up.

---

## Concurrency & Durability

- **Concurrency:** the timeseries `Store` is mutex-guarded (`store_mutex`, a
  `std.Io.Mutex` in `src/timeseries/timeseries.zig`) so concurrent ingest from
  the QUIC worker pool is safe. It is a **leaf-tier lock** — it touches no other
  geode lock and is never held while acquiring another lock. See the Mutex Lock
  Ordering table in [CLAUDE.md](../CLAUDE.md).
- **Durability (GAP-0865):** points persist via the `timeseries-storage` LSM
  engine (WAL-first writes, immutable segments, double-slot manifest) and
  survive both a clean restart **and a hard kill** — `appendPoints` writes
  the CRC32C-checksummed WAL record through to the file before the in-memory
  insert, and WAL replay on open recovers un-flushed points. Regression:
  `zig build test-ts-durability` (`tests/ts_durability.zig`).
- **Fail-closed open (GAP-0865a):** a corrupt or unreadable timeseries
  directory (bad WAL checksum, corrupt/missing segment, wrong TDE key) FAILS
  the open — graph open / server start surfaces the error instead of silently
  continuing with an empty store. Opt back into the legacy degrade-to-memory
  behaviour with `GEODE_TS_DURABILITY=best_effort`.
- **fsync cadence:** the engine runs in `batch` durability mode with a
  background WAL syncer (started by geode's wrapper; fsync every ~100 ms).
  Accepted writes survive a process crash immediately (write-through); the
  power-loss window is bounded by the syncer interval.
- **Retention (GAP-0865c):** opt-in via `GEODE_TS_RETENTION_DAYS=<N>` (whole
  days, > 0). Expired data is ACTUALLY deleted: whole segments whose
  `max_ts` falls outside the window are removed from the manifest and
  unlinked from disk (engine `pruneExpired`). Passes run opportunistically on
  the ingest path (throttled to once/minute) and explicitly via
  `Store.runRetention()`. Granularity is whole segments — a segment that
  straddles the cutoff is kept until it fully expires. Default: retention
  disabled (nothing is ever deleted implicitly).
- **TDE (GAP-0865e):** opt-in via `GEODE_TS_TDE=1` + `GEODE_TDE_KEY` (the
  same 64-hex-char key the rest of geode's TDE uses). The engine encrypts
  every on-disk artefact with AES-256-GCM: WAL records, segment blocks
  (TSSEG003), and the manifest (TSMNF002), with per-context AAD domain
  separation. Reopening with a wrong or missing key fails closed.
  **Limitation:** there is no in-place migration — enabling TDE over an
  existing plaintext timeseries directory fails closed
  (`error.UnexpectedPlaintextSegment`); start from a fresh directory or
  restore through backup. Setting `GEODE_TS_TDE=1` without a valid key is an
  error (never silently plaintext).
- **Backup/restore (GAP-0865d):** the backup engine archives every top-level
  entry under the data dir recursively, which includes the server-wide
  `{data_dir}/timeseries/` tree and every per-graph
  `{graph_dir}/timeseries/` tree (WAL + segments + manifest + identity).
  Restore round-trips time-series points (verified by
  `tests/ts_durability.zig`). Residual: a backup taken during heavy live
  ingest copies the WAL file without quiescing the engine, equivalent to a
  crash snapshot at copy time — points accepted after the copy point are not
  in that artifact.
- **Inclusive range:** `range` returns points in `[start_ts, end_ts]` inclusive
  of **both** bounds, in both the in-memory and durable paths.

---

## Cluster Mode (2026-06-10)

Time-series ingest **fails closed in cluster mode** (`GEODE_CLUSTER_TOKEN` set):
there is no Raft replication slice for time-series points yet, so
`CALL geode.ts.insert` / `geode.ts.insert_many` are refused via
`cluster.gateUnreplicatedWrite()` — a follower returns `ClusterNotLeader`, the
leader returns `ClusterWriteNotReplicable` — rather than silently writing
node-local, never-replicated data. Standalone mode is unaffected.

The read procedures (`range`, `last`, `bucket_avg`, `sample_by`) are **not
gated**, but they serve **node-local** data only. Since cluster-mode ingest is
refused, in practice a cluster node can only return points that were ingested
before cluster mode was enabled (or placed in its data-dir via restore). A
replication slice for time-series ingest is follow-up work.

---

## Wire Protocol

Time-series ingest and queries are reachable over the QUIC wire protocol via the
`CALL geode.ts.*` procedures. Results ride the **generic GQL Execute+rows
protocol**, so **no client, proto, or transport changes** are needed to consume
them — any GQL client that can read result rows works.

---

## Verification

Time-series is held to graph-storage parity:

- **Unit tests:** `tests/ts_ingest_roundtrip.zig` (ingest / read / restart / exactness / multi-series / bounds / concurrency / float-rejection)
- **Durability suite:** `tests/ts_durability.zig` (`zig build test-ts-durability`) — fail-closed open on corruption, best_effort opt-out, hard-kill WAL crash recovery, retention prune (disk + queries), backup→wipe→restore round-trip, TDE key round-trip + fail-closed wrong-key (GAP-0865)
- **Benchmark:** a native VarianceEnvelope benchmark (added in a parallel commit)
- **Latency gate:** a CI-aware latency gate (added in a parallel commit)
- **Harness spec:** `geodetestlab-cli/specs/timeseries_basic.yml` (greenfield, forthcoming)

---

## Related

- [FULLTEXT_SEARCH.md](FULLTEXT_SEARCH.md) — the FTS surface this mirrors (`CALL geode.fts.search`)
- [optimizing-ts-storage.md](optimizing-ts-storage.md) — design/tuning notes for `timeseries-storage` against Geode's access patterns
- [API_REFERENCE.md](API_REFERENCE.md) — API reference
