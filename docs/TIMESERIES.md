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
| Durability | ✅ | points survive restart |
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
- **Durability:** points persist via the `timeseries-storage` engine and survive
  a server restart.
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
- **Benchmark:** a native VarianceEnvelope benchmark (added in a parallel commit)
- **Latency gate:** a CI-aware latency gate (added in a parallel commit)
- **Harness spec:** `geodetestlab-cli/specs/timeseries_basic.yml` (greenfield, forthcoming)

---

## Related

- [FULLTEXT_SEARCH.md](FULLTEXT_SEARCH.md) — the FTS surface this mirrors (`CALL geode.fts.search`)
- [optimizing-ts-storage.md](optimizing-ts-storage.md) — design/tuning notes for `timeseries-storage` against Geode's access patterns
- [API_REFERENCE.md](API_REFERENCE.md) — API reference
