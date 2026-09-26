# Changelog

## [Unreleased] - Time-Series Audit and Gap Closure

### Added

- **CANARY Governance Tokens:** 24 CANARY markers added across timeseries source files (GAP-0281)
- **Legacy GAP ID Mapping:** Documented mapping from Grey Cardinal GAP-004/005/006 to GAP-0279+ numbering (GAP-0288)
- **Time-Series Audit Report:** `docs/TIMESERIES_AUDIT_REPORT.md` tracking all timeseries gap status

### Fixed

- **Documentation Accuracy:** Updated MIGRATION_GUIDE.md to reflect partial server wiring status and list in-progress functions (GAP-0291)
- **SUM/FIRST/LAST Aggregations:** Added test coverage for missing aggregation types (GAP-0284)
- **valueAt/timeBucketAvg Edge Cases:** Added boundary and empty-input tests (GAP-0285)
- **Step/Nearest Interpolation:** Added tests for step and nearest interpolation methods (GAP-0286)

---

## [v0.8.23] - Unreleased

### Security

- **QUIC listener certificate auto-generation fails closed in production
  (SONNY-2394):** this covers `QuicTransport.listen`'s own auto-generation
  only. That path serves the listeners whose certificate is not prepared at
  startup: the intra-cluster (cluster and Raft) QUIC listeners and the
  remote-KMS server. Such a listener self-signs a missing certificate only in
  dev posture (Debug build, `GEODE_ENV` not `production`) or when explicitly
  enabled (`GEODE_TLS_AUTOGENERATE_CERT=1`, or the per-listener
  `cert_auto_generate = .always` transport config). In production posture
  (release build or `GEODE_ENV=production`) it refuses to start instead.
  Server startup is unchanged: `geode serve` without `--cert`/`--key` still
  generates a self-signed certificate at startup when none exists (in its data
  or certificate directory, or `/tmp` when that is not writable), in every
  posture.
- **A float or a decimal narrowed to an integer no longer aborts the server
  (SONNY-2739):** a read-only query aborted a Debug or ReleaseSafe server
  wherever a float or a decimal was narrowed to an integer without a range
  check. This covers:
  - a GROUP BY or DISTINCT key of 2^63
    (`RETURN count(DISTINCT 9223372036854775808.0)`);
  - the power operator (`2 ^ 63`, `10 ^ 40`, `10 ^ 400`, `0 ^ -1`);
  - `toFloat`, `CAST(... AS FLOAT/DOUBLE/REAL)`, `degrees` and `radians`;
  - `ceil`, `floor`, `round` and `toInteger` over a decimal, and `sum()` and
    `avg()` of a list;
  - a JSON number, a typed ARRAY parameter, and a decimal literal with more
    than 255 fraction digits;
  - the geography and geometry functions (`st_x(st_point(1e35, 0))`,
    `altitude(latlonalt('0,0,1e300'))`);
  - weighted path costs, vector index scores, centrality scores, time-series
    interpolation and the distributed merge of a summed column.

  NaN produced a garbage value instead (`toFloat('nan')`,
  `latitude(latlon('nan,0'))`). Every such conversion is now checked: a value
  that does not fit is refused with SQLSTATE 22003, and zero to a negative
  power is 22012. An integer power is now exact (`3 ^ 39`), a JSON number
  past the decimal comes back as a double, `latlon()` refuses a NaN
  coordinate, and the TDE and audit benchmark procedures saturate their
  measurements. `round()` at an effective scale of 38
  (`round(0.99999999999999999999999999999999999999)`) no longer aborts
  either (a regression in the first fix).
- **A duplicate CREATE CONSTRAINT no longer aborts the server
  (SONNY-2809):** creating a constraint whose name already exists freed the
  catalog's key for it twice, which corrupted the allocator and aborted the
  server (a segfault in a release build) for any user allowed to run DDL. A
  duplicate name is now refused with 42710 (duplicate object), and
  `CREATE CONSTRAINT IF NOT EXISTS` is a no-op; the refusal used to return a
  result whose one column and one row were uninitialized memory. When saving
  the catalog fails, CREATE CONSTRAINT, CREATE SCHEMA and a new graph no
  longer leave the map holding a name already freed.
- **Integer overflow and narrowing no longer abort the server
  (SONNY-2769):** integer overflow, a narrowing cast that does not fit, and
  minInt divided by -1 abort a Debug or ReleaseSafe server. A read-only query
  reached them through:
  - decimal `*` (the coefficient and the scale), `/`, `+` and `-`, and
    `CAST(... AS DECIMAL(p, s))`;
  - `-minInt`, `abs(minInt)`, `minInt / -1`, `minInt % -1` and
    `mod(minInt, -1)` (the last two a hardware division trap), and
    `true + maxInt`;
  - date +/- interval past the day range (`+ duration('P2147483647D')`);
  - any timestamp before 1970 and any date before year 0 in a result (the
    response encoder);
  - `range()` at the edge of i64, `char()`/`varchar()` lengths, `decimal()`
    scales and 39-digit strings, `vectori32` elements, int4 range bounds,
    `ip_netmask` prefixes, DTW windows, `indegree(-1)`, `interval_contains`,
    and `knn()` with a k past u32 over a vector index;
  - procedure arguments (`tde.configure_mock_kms`, `tde.configure_rotation`,
    `audit.configure`, `algo.bfs.stream` depth), a SMALLINT parameter, a
    typed DECIMAL parameter's scale, and a TIME literal with 256 fraction
    digits;
  - a decimal past scale 38, wherever 10^scale was computed in i128: CAST
    to STRING, VARCHAR or TEXT, string concatenation (`'a' || <it>`), an
    inline property map (`MATCH (n:T {x: <it>})` on the legacy executor,
    MERGE on every session), the legacy `WITH ... ORDER BY`, a map
    property's stored JSONB text, and the ORDER BY keys the server prints
    for a paged result (`ORDER BY x + <it>`).

  A value that does not fit is refused with 22003 (a procedure argument
  with InvalidArgs), or kept exactly where the answer is defined: `x % -1` is
  0, a pre-1970 timestamp and a negative year are formatted, a CAST string's
  fraction digits past the target scale are truncated, and a `knn()` k past
  u32 is clamped (more neighbours than the index holds is all of them).
  `CAST('-1.5' AS DECIMAL)` keeps its sign (it was -0.5). A decimal's text
  is exact at any scale: `CAST(-0.5 AS STRING)` is '-0.5' (it was '0.5'),
  a map property of -0.5 is stored as -0.5 (it was 0.5), and a decimal of
  more than 32 digits casts to its text (it was NULL). `toString()` of a
  decimal is exact too (it went through a double: `toString(1.50)` was
  '1.5', and 38 digits kept 17), and `'a' || <decimal>` takes its text at
  any length (past 64 characters it failed with 0A000). **Behaviour
  change:** an inline property map and MERGE compare two numbers by their
  exact value, as GROUP BY does: `MERGE (n:T {x: 1.0})` matches a node
  whose x is the integer 1 (it created a second node). `=` does not always
  agree: it compares a DOUBLE with an exact number approximately, in a
  double, so `DOUBLE 0.1 = 0.1` is true while `{x: 0.1}` does not match a
  stored DOUBLE 0.1 (SONNY-2807).

### Fixed

- **An inline property map and MERGE match a stored value by its value on
  every path (SONNY-2806):** `MATCH (n:T {x: v})` and `MERGE` compare the
  stored property with `v` by value on the planned read and the streaming
  node scan of a persisted session, as the legacy executor does:
  - numbers by their exact value, as GROUP BY keys them: `{x: 1.50}`
    matches a stored 1.5, `{x: 1.0}` a stored 1, `{x: 1}` a stored 1.0,
    and `{x: $d}` a node created from the same DOUBLE `$d`. None of these
    matched on a persisted session; a DOUBLE and every extended value never
    matched there, and relationships (`[r:R {w: 1.0}]`) likewise;
  - durations by their months and day-to-second length (`{v: PT24H}`
    matches a stored P1D), and zoned times by their UTC time of day. The
    legacy executor compared both by representation, so MERGE also created
    a second node for them.
  - **Behaviour change (fixes a round-5 regression):** MERGE's property
    index keys a number by its exact value. `MERGE (n:U {x: 1})` created a
    second node beside a stored 1.0 on every session, while
    `MERGE (n:T {x: 1.0})` matched a stored 1.

  A DOUBLE and a decimal are equal only when their values are exactly
  equal (`{x: 0.1}` does not match a stored DOUBLE 0.1), which is how
  GROUP BY treats them. `=` compares them in a double instead (SONNY-2807).

  **Upgrade note:** the adapter's exact node-property index (`prop_exact.idx`
  and `prop_rev.idx`) and the merge-index hydration snapshot hash a number
  by its value now. A file written by an earlier version is stale, and the
  first open of each graph after the upgrade rebuilds the index with a scan.

- **Grouped queries report their errors (SONNY-2675):**
  - **Behaviour change:** a HAVING name that is no column, binding or
    parameter is refused with 42703; it was NULL.
  - **Behaviour change:** a grouping error (an ungrouped input column in a
    grouped HAVING or RETURN, a nested aggregate, an aggregate in a row
    filter) reaches the client as 42803; it was 42000.
  - An error that belongs to the query, not to one row, now fails a grouped
    query: an unknown function, a missing positional parameter, strict
    tenancy, an encrypted field searched without permission (42501), the read
    and write budgets, a cancel. Each was a skipped row, so the aggregate ran
    over the other rows.
  - `sum()` and `avg()` refuse every non-numeric input with a type error;
    they skipped a date, a list or an interval. A SmallInt or a BigInt is
    summed (it was skipped), and an integer sum past i64 continues as a
    double.

    **Known deviation:** ISO/IEC 39075 (following SQL's exact-numeric rules)
    implies an integer SUM past i64 should raise 22003. The shared
    projection continues it as a double (the value's magnitude is kept, its
    last digits are not), matching the GROUP BY fast path, until both paths
    converge on 22003.
- **Group and DISTINCT keys keep their type (SONNY-2675, SONNY-2735):** a
  GROUP BY, `count(DISTINCT)`, RETURN DISTINCT and WITH DISTINCT key keeps
  its type and value. Doubles, dates, decimals, texts, UUIDs and lists group
  by value; 1, '1', 'null' and NULL are four groups; a `|` inside a string no
  longer moves a key boundary. Keys were text, with "?" or "Other" for most
  types, so DISTINCT over doubles or dates returned one row whenever the
  streaming fast path declined (with ORDER BY, say). Keys now agree with the
  value order: numbers by their exact value (DECIMAL 0.5 equals DOUBLE 0.5,
  DECIMAL 0.1 does not equal DOUBLE 0.1), every NaN is one value, and a time
  with a time zone keys by its UTC time of day.

  **Behaviour change:** durations follow the standard's two kinds
  (ISO/IEC 39075 keeps year-to-month and day-to-second durations apart):
  - a month is not 30 days: 1 month and 30 days are two groups, and
    `duration('P1M') = duration('P30D')` is false (it was true);
  - a day is 24 hours: P1D and PT24H are one group, and equal;
  - ORDER BY, min and max order intervals by months, then by their
    day-to-second length;
  - `<`, `<=`, `>` and `>=` in WHERE and HAVING are defined when the months
    or the day-to-second lengths of the two sides are equal
    (`P1M < P2M`, `P1D < PT25H`); a year-to-month duration against a
    day-to-second one (`P1M < P30D`) raises 22G04 (values not comparable).
    They used to count a month as 30 days. The rule is conservative: it asks
    for one equal part, so `P1M1D < P2M` raises 22G04 although it holds for
    any month length.
  - A time with a time zone compares by its UTC time of day, the UTC time
    modulo 24 hours, in `=`, `<`, `>`, ORDER BY and the groups:
    `10:00+01:00 = 09:00+00:00`, and `01:00+14:00 = 11:00+00:00` (it was
    -13:00 UTC and sorted first). `=` compared the local time and the
    offset, and `<` and `>` were a type mismatch; a zoned datetime's `<` and
    `>` compare its UTC instant, as ORDER BY does.
  - **Behaviour change:** `x IN [a, b]` is `x = a OR x = b`, for a literal
    list, a list expression (`x IN $list`) and a subquery
    (`x IN (MATCH ... RETURN v)`, its first column) alike. (Geode reads
    parentheses after IN as a subquery; a list is written in brackets.) An
    item is in the list when `=` calls it equal, whatever its type
    (`1.50 IN [1.5]`, `1 IN [1.0]` and a DOUBLE 1.5 in `[1.5]` are true;
    they were false, and `1.5 IN (<a subquery returning 1.5>)` was false
    too, so NOT IN kept that row). The result is NULL when no item is equal
    and some comparison is NULL (`2 IN $list` with `$list = [1, NULL]` was
    false), and FALSE for an empty list or subquery, even for a NULL value
    (`NULL IN (<no rows>)` was NULL). `=`, `<` and `>` compare INT,
    SMALLINT, BIGINT and DECIMAL values by their exact value at any scale:
    `1 = <a scale-40 decimal>` is false (it failed with 0A000), and a
    SMALLINT or BIGINT parameter compares with an INT (a type mismatch).
  - IN evaluates `x = item` left to right and stops at the first item that
    is equal, as the OR it stands for does. An item `=` cannot compare with
    the value raises the error `=` raises, but only if IN reaches it:
    `'a' IN ['a', 1.5]` is true, while `'a' IN [1.5, 'a']` is a type
    mismatch, as `'a' = 1.5` is. (It was false.)
  - **Known divergence:** a WHERE predicate that raises for some rows, such
    as a property holding a string on one node and a number on another
    against `IN [1.5]`, fails the query on a legacy session (in memory,
    RLS or tenant-scoped), while the planned read of a persisted session
    counts an error as no match and returns the other rows (SONNY-2811).
- **min, max and ORDER BY order every value type (SONNY-2675):** min and max
  compared only integers and strings, so over doubles, decimals, dates or
  mixed numbers the first value won, and ORDER BY ranked doubles, temporal
  values and node or edge ids as equal. They now share one value order:
  numbers by exact value with NaN last, strings by bytes, dates, times,
  timestamps and intervals by their own order, booleans, then ids. The GROUP
  BY fast paths fold min and max exactly, a decimal included, so an ungrouped
  min or max over decimals or dates on a tenant-scoped session no longer
  answers NULL.

  **Upgrade note:** distributed merges use the new order too. During a
  rolling upgrade, a mixed-version cluster can merge distributed results out
  of order, because nodes still on the old order rank doubles, temporal
  values and ids as equal.

### Changed

- **More GROUP BY shapes materialize every row (SONNY-2675):** a GROUP BY on
  a text, a list or a document key, and a min or max over a string, an enum
  or a document, no longer stream on the GROUP BY fast path. The shared
  projection computes them, which materializes every input row and can reach
  the read budget (`GEODE_READ_EXECUTOR_BUDGET_MB`) on a large input.

---

## [v0.8.22] - September 19, 2026

Concurrency memory-safety fix in the graph-storage adjacency read path.

### Fixed

- **Borrowed-slice torn read on concurrent edge append (SONNY-1797):** the
  adjacency-list accessors now take an acquire-ordered (ptr,len) snapshot that
  pairs with the appender release publish, eliminating a torn
  one-past-the-old-buffer out-of-bounds read (UAF-class) reachable by any
  concurrent reader during edge append. The `test_edge_torn_read_stress`
  regression is un-quarantined and back in the sharded `test` suite.

---

## [v0.8.21] - September 19, 2026

grpc-zig fixes propagated through the devnw/zig dependency diamond, plus
Prometheus exposition naming (SONNY).

### Fixed

- **grpc-zig RST_STREAM handled as a stream error (SONNY-1838):** re-pinned
  onto grpc-zig v0.1.12, which handles an inbound RST_STREAM as an HTTP/2
  §5.4.2 stream error — failing only that stream's RPC and continuing to read
  the connection — instead of tearing the whole connection down and dropping
  every other in-flight RPC. GOAWAY and real connection loss still tear down.
- **grpc-zig FIPS dependency resolvable (SONNY-1852):** grpc-zig v0.1.12 pins
  `.fips` to the published git dependency (the spine's v0.1.1 content hash)
  rather than a machine-local `.path`, so `-Dfips=true` and the FIPS CI job
  resolve.
- **Prometheus naming conventions on /metrics (SONNY-1807):** the OTel →
  Prometheus responder now applies Prometheus/OpenMetrics naming — `_total`
  for monotonic counters and base-unit suffixes (`_seconds`, `_bytes`) — so
  scrapers and dashboards work without manual renaming.

### Changed

- **Dependency diamond re-pinned onto grpc-zig v0.1.12:** the `zig-tool
  sync-diamond` cascade re-released the ~18 intermediate devnw/zig libraries
  (otel v0.1.24, quic v0.1.44, geode-client-zig v0.3.12, graph-storage v0.4.6,
  …) so a single grpc-zig version converges across the dependency tree.

---

## [v0.8.20] - September 18, 2026

QUIC stream semantics: sibling-stream binding, idle-stream reclamation, and
statement cancellation on the wire (SONNY).

### Fixed

- **Unbound sibling QUIC streams (SONNY-1835):** a sibling stream opened without
  its own HELLO inherited no tenant/graph identity and silently returned zero
  rows. Such an unbound sibling is now refused with a typed error (GQLSTATE
  08003) instead of running unbound. Clients that send a per-stream HELLO,
  including the Go driver, are unaffected.
- **Statement cancellation on the QUIC wire (SONNY-1841):** there was no way to
  cancel an in-flight statement, so an abandoned mutation ran to completion
  holding the per-graph write lock to its ~120s deadline and blocking the next
  writer on another connection. A per-stream CANCEL message (proto oneof tag
  15, backward-compatible — old clients simply never send it) and a QUIC stream
  reset now abort the statement; the write path polls the cancellation and
  releases the write lock promptly (SQLSTATE 57014).

### Changed

- **Idle-open sibling stream reclamation (SONNY-1837):** idle-open sibling QUIC
  streams can now be reaped on an independent, tighter deadline via
  `GEODE_QUIC_STREAM_IDLE_REAP_MS` (default 0 = opt-in; the existing ~300s
  connection-deadline reclamation and the admission rejection on slot
  exhaustion are unchanged), letting operators reclaim stream-pool slots faster
  under handshake pressure.

---

## [v0.8.19] - September 18, 2026

Engine metrics correctness and QUIC teardown safety, plus CI/test-suite
hardening. Cut to unblock the sonny-upstream integration work (SONNY).

### Fixed

- **Cluster node health metric (SONNY-1803):** `geode.cluster.node.health`
  was a monotonic Counter and could never represent a return to healthy. It is
  now a Gauge (0 = unhealthy, 1 = healthy) observable in both directions.
- **QUIC stream-teardown use-after-free read (SONNY-1794):** teardown proved
  stream liveness by reading `tracking_index` on a wrapper that could already
  be freed. Membership is now decided by a pointer-only scan of the tracked
  list under `streams_mu`, so a freed wrapper is never dereferenced.
- **Accept-reactor inbox churn (SONNY-1796):** the stream accept reactor's
  `drainPending` discarded and reallocated the pending inbox on every
  non-quiet pass; it now reuses the backing capacity across passes.
- **Resident node-cache use-after-move (SONNY-1979):** `getNodePtrForScan`
  returned a live `*Node` into a shard's `AutoHashMap` value storage; a
  concurrent hydration insert that grew that shard rehash-moved the value,
  dangling the pointer (CWE-362, use-after-move). Resident hits are now
  snapshotted into a grace-lifetime detached box under the shared shard lock
  (matching the existing scan-miss path), so the returned pointer is stable
  across a concurrent shard grow.

### Changed

- **Bounded metric cardinality (SONNY-1805):** `db.namespace` on graph
  mutation metrics no longer emits the raw, unbounded (tenant-revealing) graph
  name; it emits a bounded id.
- **Closed metric label sets (SONNY-1806):** the reason/strategy attributes on
  the transport-close, query-plan, audit-drop, and CDC-drop metrics are now
  closed enums instead of open `[]const u8` strings.

### CI / Tests

- **Serialized k8s test shards (SONNY-1798):** the two 8-way test-stage
  matrices now carry a per-shard `resource_group`, capping concurrent pods.
- **Load-independent pre-push assertions (SONNY-1799):** the startup
  lazy-hydrate and gap0813 timing assertions no longer flake under host load;
  the gap0813 latency budget scales under CI.
- **Quarantined intermittent torn-read stress (SONNY-1797):**
  `test-edge-torn-read-stress` removed from the aggregate `test` step (still
  standalone-runnable), tracked in `docs/KNOWN_TEST_ISSUES.md`.
- **Verified SONNY-1795:** the `close_app_error` double-latch was confirmed
  already resolved — it is latched only in the disjoint `close()` and
  `requestShutdown()` paths.
- **Join spawned workers on all paths (SONNY-1982):** the lazy-hydrate
  concurrency tests could let a spawned worker outlive its test body on an
  error path (a `try` between spawn and join), which SIGSEGV'd under Zig's
  `--listen` test runner in the x4-sharded pre-push. Each worker is now joined
  on every exit path (guarded `defer`, release-then-join before captured state
  dies), fixing a pre-existing pre-push flake.

---

## [v0.8.18] - September 16, 2026

CI-only re-cut of v0.8.17. No engine code changes.

### Fixed

- **Cross-build shards (CI):** the v0.8.17 tag pipeline lost both aarch64
  cross-build shards to an out-of-memory kill inside `zig build` on the k8s
  cluster runner, so `build-release` never ran. `test-cross-build` now runs on
  the dedicated docker-executor fleet with `zig build -j2`. The v0.8.17 tag
  remains but never produced an image or packages.

---

## [v0.8.17] - September 16, 2026

CI-only re-cut of v0.8.16. No engine code changes.

### Fixed

- **Cross-build OpenSSL prefix (CI):** Debian removed openssl `3.5.6-1~deb13u2`
  from the trixie pool on 2026-09-16, so `scripts/ci/fetch-openssl-prefix.sh`
  404'd and the v0.8.16 tag pipeline's `aarch64-linux-gnu` cross-build failed
  before `build-release` could run. The Debian pins are refreshed to
  `3.5.7-1~deb13u2` with digests cross-checked against the trixie Packages
  index. The v0.8.16 tag remains but never produced an image or packages.

---

## [v0.8.16] - September 15, 2026

Engine release. Re-pins the whole `devnw/zig` dependency spine onto
grpc-zig v0.1.10 (SONNY-1568 per-connection reader threads) via the
`zig-tool sync-diamond` cascade, and ships the reviewed server/execution
/storage/transport fixes.

### Fixed

- **Tenant scope on engine-direct reads (SONNY-1229):** engine-direct reads now
  apply the caller's tenant scope instead of bypassing it.
- **Node-scan fast path (SONNY-1218):** the fast path is declined when no
  storage adapter is present rather than silently returning unscoped rows.
- **Tenant visibility in graph execution (SONNY-1318):** scoped degree workers
  hardened, FTS fails closed under strict tenancy, union-find edges are read by
  value, and the thread-safety audit was corrected.
- **Tenant scope in path and subquery operators (SONNY-1326):** `shortestPath`,
  `COUNT{}`, `EXISTS{}` and pattern comprehensions apply tenant scope;
  `graph_procedure_tenancy` is advertised as a capability.
- **UNION read-only gate (SONNY-1330):** the gate walks CTE bodies and
  expression subqueries, and parallel UNION arms no longer mutate shared state.
- **Exact-index persistence accounting (SONNY-1574):** a skipped or unattempted
  exact-index persist is never reported as done; it counts only for a FULL
  checkpoint the engine accepted, a timed-out worker wait fails, and the persist
  is spawned outside the build mutex.
- **gRPC flow control (SONNY-1560):** a pushed gRPC result no longer holds the
  session mutex across a page write; a stalled, abandoned or superseded stream
  releases the session cursor deterministically; an unsatisfiable peer
  flow-control window is classified `RESOURCE_EXHAUSTED` instead of being waited
  out; the library's RST ends an exhausted stream and the flow-control seam is
  pinned.
- **QUIC connection lifecycle (SONNY-1219):** every server-initiated connection
  close is named, the five try-escapes out of `handleQuicConnection` are named,
  stream wrappers are no longer double-freed, stream release is idempotent, and
  the accept reactor's OOM teardown runs outside `shard.mu`.

### Changed

- Re-pinned `grpc_zig` to v0.1.10 and cascaded the 18 intermediate libraries
  that sit between it and the engine (see the release report for the full tag
  list).

### Known limitations

- **Server-initiated close codes are named on the SENDING side only.** The
  connection-close codes introduced by SONNY-1219 are set when the server
  closes, but a peer cannot read them: the vendored quic layer discards the
  close code on receive. Until that is fixed the codes are useful for
  server-side logging and tests only, not for client-side behavior. Tracked as
  **T-8**.

---

## [v0.18.1] - January 28, 2026

### Added

- **TDE File-Level Encryption:** Extended TDE to all persistent storage files:
  - Index persistence: R-tree, HNSW, Patricia trie, Domain trie, JSONB inverted, Interval tree
  - Schema catalogs: Main catalog and FLE catalog
  - Distributed state: Raft consensus state, snapshots, and log files
  - All files encrypted with AES-256-GCM when `GEODE_TDE_KEY` is set
  - CANARY markers added: REQ-TDE-FILELEVEL-001

### Documentation

- Added [TDE_FILE_LEVEL_ENCRYPTION.md](TDE_FILE_LEVEL_ENCRYPTION.md)
- Updated SECURITY_PROGRESS.md with file-level encryption status
- Added geodetestlab spec: `tde_filelevel_encryption.yml`

---

## [v0.1.0] - Grey Cardinal Compliance

### Added

- **Backup Encryption:** Implemented AES-256-GCM encryption for backup files (GAP-005). Requires `GEODE_TDE_KEY`.
- **Time-Series Integration:** Added `timeseries.value()` GQL function to access in-memory time-series data (GAP-004).
- **WAL Replay:** Implemented WAL replay logic for incremental backup recovery (GAP-002).
- **Benchmarks:** Added Time-Series benchmarks (`src/benchmarks/bench_timeseries.zig`) (GAP-006).

### Fixed

- **Backup Compression:** Fixed shim implementation to use real ZStandard compression (GAP-001).
- **Graph Centrality:** Cleaned up unused headers; deferred advanced metrics to v0.18 (GAP-003).

### Security

- **TDE:** Transparent Data Encryption for backups.

---
Add OpenCL integration into GPUAccelerator: compile kernels via clCreateProgramWithSource/clBuildProgram/clCreateKernel, and store program/kernel/queue in KernelCompiledOpenCL; prepared Launch/Copy paths will be implemented later.
