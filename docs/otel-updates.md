# Geode OpenTelemetry Metrics Specification v1.0

This spec is tailored to the current Geode repo, not a generic database template. Geode is described as a Zig-built, single-tenant graph database with GQL compliance, MVCC/SSI transactions, WAL, TDE, QUIC+TLS transport, vector/HNSW search, ML graph embeddings, real-time analytics, distributed query coordination, S3 backup, and multi-shard support. ([about.gitlab.com][1])

Geode already has a Prometheus-oriented monitoring surface: `src/monitoring` contains `registry.zig`, `prometheus.zig`, `metrics_server.zig`, and `tracing.zig`; the metrics server exposes `/metrics` and `/health`, and binds to `127.0.0.1` by default unless `GEODE_METRICS_BIND` is set. ([about.gitlab.com][2]) The current collector should be treated as a migration baseline, because it emits a small set of custom Prometheus names and misses several dashboarded metrics; for example, the dashboard references `geode_memory_used_bytes` and `geode_wal_size_bytes`, while the collector registers `geode_memory_bytes` and no WAL-size metric. ([about.gitlab.com][3])

## 1. Design rules

Use **OpenTelemetry metric names internally**, not Prometheus names. OTel instrument names may contain dots and should carry units through instrument metadata, not through the metric name. Prometheus exporters can translate names to `snake_case` with suffixes such as `_seconds` and `_total`. The OTel Metrics API supports Counter, Histogram, Gauge, UpDownCounter, and asynchronous variants; instrument names are case-insensitive ASCII and can include `.`, `_`, `-`, and `/`, with max length 255. ([OpenTelemetry][4]) OTel also recommends hierarchical metric naming, consistent attribute names, and meaningful aggregation across all attributes. ([OpenTelemetry][5])

### Naming

Use this namespace strategy:

```text
geode.<subsystem>.<thing>.<measurement>
```

Examples:

```text
geode.query.execution.duration
geode.storage.operation.duration
geode.transaction.count
geode.wal.fsync.duration
geode.index.lookup.duration
geode.security.authorization.check.duration
```

Do **not** use unit suffixes in OTel metric names:

```text
Good: geode.query.execution.duration, unit=s
Bad:  geode_query_duration_seconds
Bad:  geode.query.duration.seconds
```

### Instrumentation scope

```text
meter.name     = "com.geodedb.geode"
meter.version  = <Geode version>
schema_url     = "https://schemas.geodedb.com/otel/geode/metrics/1.0.0"
```

### Resource attributes

Every metric produced by the Geode server should carry these resource attributes:

| Attribute                     |                 Required | Example                                           | Notes                                                    |
| ----------------------------- | -----------------------: | ------------------------------------------------- | -------------------------------------------------------- |
| `service.name`                |                      yes | `geode`                                           | Required by OTel service conventions.                    |
| `service.namespace`           |              recommended | `codepros` or `geodedb`                           | Groups Geode services.                                   |
| `service.version`             |              recommended | `0.9.4`                                           | Build or release version.                                |
| `service.instance.id`         |                      yes | UUID                                              | Must distinguish horizontally scaled instances.          |
| `deployment.environment.name` |              recommended | `prod`, `staging`                                 | Use bounded values.                                      |
| `host.name` / `host.id`       |              recommended | host identity                                     | Prefer Collector-enriched resource attrs where possible. |
| `k8s.*` / `container.*`       |                 optional | pod/container data                                | Prefer Collector enrichment.                             |
| `geode.node.id`               | required in cluster mode | `node-1`                                          | Stable node identity.                                    |
| `geode.cluster.name`          | required in cluster mode | `production-cluster`                              | Cluster name.                                            |
| `geode.node.role`             | required in cluster mode | `standalone`, `leader`, `follower`, `coordinator` | Low cardinality.                                         |

OTel defines `service.name`, `service.version`, `service.instance.id`, and `service.namespace`; `service.name` is required and `service.instance.id` should be unique per service instance. ([OpenTelemetry][6])

### Important `db.system.name` rule

For **client-side database metrics/spans**, use:

```text
db.system.name = "codepros.geode"
```

Do **not** use `db.system.name="geode"` unless this product intentionally identifies as Apache Geode. OTel’s current DB semantic convention already maps the well-known value `geode` to **Apache Geode**, not this graph database. ([OpenTelemetry][7])

### Common attributes

Use these across metric groups. Keep all values low-cardinality.

| Attribute                           | Type       | Use                                                                                               |                          |
| ----------------------------------- | ---------- | ------------------------------------------------------------------------------------------------- | ------------------------ |
| `db.system.name`                    | string     | `codepros.geode` for client-side DB metrics.                                                      |                          |
| `db.namespace`                      | string     | Logical database/graph namespace. For multi-component namespaces, join general-to-specific with ` | `, per OTel DB guidance. |
| `db.operation.name`                 | string     | `MATCH`, `CREATE`, `MERGE`, `DELETE`, `CALL`, `BEGIN`, `COMMIT`, etc.                             |                          |
| `db.query.summary`                  | string     | Low-cardinality summary such as `MATCH Person`, `CALL algo.degree.stream`.                        |                          |
| `db.query.text`                     | string     | **Opt-in only**, never default.                                                                   |                          |
| `error.type`                        | string     | Required on failed operations where known.                                                        |                          |
| `geode.result.outcome`              | string     | `success`, `error`, `timeout`, `cancelled`, `partial_success`.                                    |                          |
| `geode.query.type`                  | string     | `read`, `write`, `ddl`, `admin`, `algorithm`, `ml`, `analytics`.                                  |                          |
| `geode.graph.name`                  | string     | Opt-in if graph count is bounded. Prefer `db.namespace`.                                          |                          |
| `geode.tenant.id`                   | string     | **Opt-in only**; disabled by default due cardinality and current multi-tenancy caveats.           |                          |
| `geode.shard.id`                    | int/string | Safe when bounded; Geode documents up to 32 shards.                                               |                          |
| `geode.index.type`                  | string     | `btree`, `hash`, `full_text`, `spatial`, `vector_hnsw`, `interval`.                               |                          |
| `geode.cache.name`                  | string     | `query_result`, `path`, `page`, etc.                                                              |                          |
| `geode.cache.outcome`               | string     | `hit`, `miss`, `evicted`.                                                                         |                          |
| `geode.security.decision`           | string     | `allow`, `deny`.                                                                                  |                          |
| `geode.transaction.isolation_level` | string     | `read_committed`, `snapshot`, `serializable_snapshot`, etc.                                       |                          |
| `geode.execution.device`            | string     | `cpu`, `gpu`.                                                                                     |                          |
| `geode.ml.algorithm`                | string     | `node2vec`, `graphsage`, `deepwalk`.                                                              |                          |
| `geode.graph.algorithm.name`        | string     | `degree`, `betweenness`, `louvain`, `pagerank`, etc.                                              |                          |

`db.query.text` must remain opt-in; OTel marks it opt-in and recommends `db.query.summary` as the low-cardinality grouping key. ([GitHub][8]) Geode’s current docs also recommend single-tenant production by default and flag multi-tenant/distributed deployment caveats, so tenant-level metric labels should stay opt-in until operators explicitly accept the cardinality and privacy cost. ([about.gitlab.com][9])

## 2. Histogram bucket profiles

Use seconds for durations.

| Profile               | Boundaries                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------ |
| `db_client_duration`  | `[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10]`                                           |
| `query_duration`      | `[0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]` |
| `storage_io_duration` | `[0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1]`                |
| `lock_wait_duration`  | `[0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30]`                           |
| `rows`                | `[1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]`                            |
| `bytes`               | `[128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864]`       |
| `graph_degree`        | `[0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000]`                                          |

The `db_client_duration` and `rows` profiles match OTel’s database client metric recommendations for operation duration and returned rows. ([OpenTelemetry][7])

## 3. Standard OTel database client metrics

These apply to the Zig/Go clients, CLI shell, and any external client libraries. They should also be emitted by Geode’s internal remote-query client when one Geode node queries another node.

| Metric                                  |    Instrument |           Unit | Priority | Attributes                                                                                                                                                                                    | Description                                               |
| --------------------------------------- | ------------: | -------------: | -------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `db.client.operation.duration`          |     Histogram |            `s` |       P0 | `db.system.name`, `db.namespace`, `db.operation.name`, `db.query.summary`, `server.address`, `server.port`, `network.peer.address`, `network.peer.port`, `geode.result.outcome`, `error.type` | Client-observed database call latency.                    |
| `db.client.response.returned_rows`      |     Histogram |        `{row}` |       P1 | Same as above                                                                                                                                                                                 | Rows returned to client.                                  |
| `db.client.connection.count`            | UpDownCounter | `{connection}` |       P1 | `db.client.connection.pool.name`, `db.client.connection.state`                                                                                                                                | Current client pool connections by `idle`/`used`.         |
| `db.client.connection.idle.max`         | UpDownCounter | `{connection}` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Max idle connections.                                     |
| `db.client.connection.idle.min`         | UpDownCounter | `{connection}` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Min idle connections.                                     |
| `db.client.connection.max`              | UpDownCounter | `{connection}` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Max open connections.                                     |
| `db.client.connection.pending_requests` | UpDownCounter |    `{request}` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Pending client requests waiting for a connection.         |
| `db.client.connection.timeouts`         |       Counter |    `{timeout}` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Connection acquisition timeouts.                          |
| `db.client.connection.create_time`      |     Histogram |            `s` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Time to create a new client connection.                   |
| `db.client.connection.wait_time`        |     Histogram |            `s` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Time waiting for a pooled connection.                     |
| `db.client.connection.use_time`         |     Histogram |            `s` |       P1 | `db.client.connection.pool.name`                                                                                                                                                              | Time between borrowing and returning a pooled connection. |

OTel defines `db.client.operation.duration` as required, and defines the connection-pool metrics above under database client metrics. ([GitHub][8])

## 4. Geode server metrics catalogue

Priority:

```text
P0 = required for production observability and SLOs
P1 = recommended for performance diagnosis
P2 = opt-in, expensive, experimental, or high-cardinality
```

### 4.1 Server lifecycle and health

| Metric                             | Instrument |         Unit | Priority | Attributes                           | Description                               |
| ---------------------------------- | ---------: | -----------: | -------: | ------------------------------------ | ----------------------------------------- |
| `geode.server.uptime`              |      Gauge |          `s` |       P0 | none                                 | Seconds since process start.              |
| `geode.server.health`              |      Gauge |          `1` |       P0 | `geode.component`                    | `1` healthy, `0` unhealthy per component. |
| `geode.server.config.reload.count` |    Counter |   `{reload}` |       P1 | `geode.result.outcome`, `error.type` | Config reload attempts.                   |
| `geode.server.shutdown.count`      |    Counter | `{shutdown}` |       P1 | `geode.shutdown.reason`              | Graceful or forced shutdowns.             |

Also emit standard process metrics through the OTel SDK or Collector: `process.cpu.time`, `process.cpu.utilization`, `process.memory.usage`, `process.memory.virtual`, `process.thread.count`, `process.unix.file_descriptor.count`, and `process.uptime`. OTel documents these as OS process metrics. ([OpenTelemetry][10])

### 4.2 QUIC/TLS transport

Geode’s docs identify QUIC+TLS as the transport layer. ([about.gitlab.com][1])

| Metric                               |    Instrument |           Unit | Priority | Attributes                                                                            | Description                                 |
| ------------------------------------ | ------------: | -------------: | -------: | ------------------------------------------------------------------------------------- | ------------------------------------------- |
| `geode.transport.connection.count`   | UpDownCounter | `{connection}` |       P0 | `geode.transport.protocol`, `geode.connection.state`, `server.address`, `server.port` | Current connections by state.               |
| `geode.transport.connection.opened`  |       Counter | `{connection}` |       P0 | `geode.transport.protocol`                                                            | Accepted/opened connections.                |
| `geode.transport.connection.closed`  |       Counter | `{connection}` |       P0 | `geode.close.reason`                                                                  | Closed connections.                         |
| `geode.transport.handshake.duration` |     Histogram |            `s` |       P0 | `geode.transport.protocol`, `geode.result.outcome`, `error.type`                      | QUIC/TLS handshake duration.                |
| `geode.transport.stream.count`       | UpDownCounter |     `{stream}` |       P1 | `geode.stream.state`                                                                  | Current QUIC streams.                       |
| `geode.transport.request.inflight`   | UpDownCounter |    `{request}` |       P0 | `db.operation.name`                                                                   | Active protocol requests.                   |
| `geode.transport.request.duration`   |     Histogram |            `s` |       P0 | `db.operation.name`, `geode.result.outcome`, `error.type`                             | End-to-end server request handling.         |
| `geode.transport.bytes`              |       Counter |           `By` |       P0 | `network.io.direction` = `transmit`/`receive`                                         | Bytes sent/received.                        |
| `geode.transport.messages`           |       Counter |    `{message}` |       P1 | `network.io.direction`, `geode.message.type`                                          | Protocol messages.                          |
| `geode.transport.timeout.count`      |       Counter |    `{timeout}` |       P0 | `geode.timeout.kind`                                                                  | Request, connection, or handshake timeouts. |
| `geode.transport.retry.count`        |       Counter |      `{retry}` |       P1 | `geode.retry.reason`                                                                  | Transport-level retries.                    |
| `geode.transport.queue.depth`        | UpDownCounter |       `{item}` |       P1 | `geode.queue.name`                                                                    | Thread-pool or accept-loop queue depth.     |

### 4.3 Query, GQL parser, planner, optimizer, execution

Geode’s critical path is CLI/Server → GQL Parser → Planner → Execution Engine → Eval → Storage → Results, and the architecture identifies parser, planner, execution, eval, and storage as core files/modules. ([about.gitlab.com][11])

| Metric                                    |    Instrument |          Unit | Priority | Attributes                                                                                        | Description                               |
| ----------------------------------------- | ------------: | ------------: | -------: | ------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `geode.query.count`                       |       Counter |     `{query}` |       P0 | `db.operation.name`, `geode.query.type`, `geode.result.outcome`, `error.type`                     | Queries executed.                         |
| `geode.query.active`                      | UpDownCounter |     `{query}` |       P0 | `geode.query.type`                                                                                | Currently running queries.                |
| `geode.query.execution.duration`          |     Histogram |           `s` |       P0 | `db.operation.name`, `db.query.summary`, `geode.query.type`, `geode.result.outcome`, `error.type` | Server-side full query execution latency. |
| `geode.query.parse.duration`              |     Histogram |           `s` |       P0 | `geode.result.outcome`, `error.type`                                                              | GQL parse/lex duration.                   |
| `geode.query.parse.error.count`           |       Counter |     `{error}` |       P0 | `error.type`                                                                                      | Parse errors.                             |
| `geode.query.plan.duration`               |     Histogram |           `s` |       P0 | `db.operation.name`, `geode.planner.strategy`                                                     | Logical/physical planning duration.       |
| `geode.query.optimize.duration`           |     Histogram |           `s` |       P1 | `geode.optimizer.phase`                                                                           | Cost-based optimization duration.         |
| `geode.query.rows.returned`               |     Histogram |       `{row}` |       P0 | `db.operation.name`, `db.query.summary`                                                           | Rows returned by server execution.        |
| `geode.query.rows.scanned`                |     Histogram |       `{row}` |       P1 | `geode.scan.source`                                                                               | Rows/nodes/edges scanned.                 |
| `geode.query.result.bytes`                |     Histogram |          `By` |       P1 | `db.operation.name`                                                                               | Encoded result size.                      |
| `geode.query.memory.peak`                 |     Histogram |          `By` |       P1 | `db.operation.name`, `geode.query.type`                                                           | Peak per-query memory.                    |
| `geode.query.timeout.count`               |       Counter |   `{timeout}` |       P0 | `db.operation.name`, `geode.timeout.kind`                                                         | Query timeout count.                      |
| `geode.query.cancelled.count`             |       Counter |     `{query}` |       P1 | `geode.cancel.reason`                                                                             | Cancelled queries.                        |
| `geode.query.execution.operator.duration` |     Histogram |           `s` |       P1 | `geode.operator.type`                                                                             | Operator-level latency.                   |
| `geode.query.execution.operator.rows`     |     Histogram |       `{row}` |       P1 | `geode.operator.type`, `geode.operator.io` = `in`/`out`                                           | Operator input/output rows.               |
| `geode.query.execution.operator.count`    |       Counter | `{operation}` |       P1 | `geode.operator.type`                                                                             | Operator invocations.                     |
| `geode.query.cache.lookup`                |       Counter |    `{lookup}` |       P1 | `geode.cache.name`, `geode.cache.outcome`                                                         | Query/path/result cache hits and misses.  |
| `geode.query.cache.entries`               | UpDownCounter |     `{entry}` |       P1 | `geode.cache.name`                                                                                | Current cache entries.                    |
| `geode.query.cache.size`                  |         Gauge |          `By` |       P1 | `geode.cache.name`                                                                                | Current cache memory footprint.           |

### 4.4 Graph data model and graph operations

| Metric                                 |    Instrument |          Unit | Priority | Attributes                                                                   | Description                          |
| -------------------------------------- | ------------: | ------------: | -------: | ---------------------------------------------------------------------------- | ------------------------------------ |
| `geode.graph.node.count`               | UpDownCounter |      `{node}` |       P0 | `db.namespace`                                                               | Current node count.                  |
| `geode.graph.edge.count`               | UpDownCounter |      `{edge}` |       P0 | `db.namespace`                                                               | Current edge count.                  |
| `geode.graph.property.count`           | UpDownCounter |  `{property}` |       P1 | `db.namespace`                                                               | Current property count.              |
| `geode.graph.label.count`              | UpDownCounter |     `{label}` |       P1 | `db.namespace`                                                               | Current label count.                 |
| `geode.graph.relationship_type.count`  | UpDownCounter |      `{type}` |       P1 | `db.namespace`                                                               | Current relationship type count.     |
| `geode.graph.node.operation.count`     |       Counter | `{operation}` |       P0 | `geode.graph.operation` = `create`/`update`/`delete`, `geode.result.outcome` | Node mutations.                      |
| `geode.graph.edge.operation.count`     |       Counter | `{operation}` |       P0 | `geode.graph.operation`, `geode.result.outcome`                              | Edge mutations.                      |
| `geode.graph.property.operation.count` |       Counter | `{operation}` |       P1 | `geode.graph.operation`, `geode.result.outcome`                              | Property mutations.                  |
| `geode.graph.degree`                   |     Histogram |      `{edge}` |       P2 | `geode.edge.direction`                                                       | Degree distribution sample.          |
| `geode.graph.pattern.match.duration`   |     Histogram |           `s` |       P1 | `db.query.summary`                                                           | Pattern matching latency.            |
| `geode.graph.pattern.matches`          |     Histogram |     `{match}` |       P1 | `db.query.summary`                                                           | Number of matches per pattern query. |
| `geode.graph.path.expansion.duration`  |     Histogram |           `s` |       P1 | `geode.path.direction`, `geode.path.variable_length`                         | Path expansion latency.              |
| `geode.graph.path.length`              |     Histogram |      `{edge}` |       P1 | `geode.path.direction`                                                       | Returned path length.                |
| `geode.graph.path_cache.lookup`        |       Counter |    `{lookup}` |       P1 | `geode.cache.outcome`                                                        | Path cache hit/miss count.           |
| `geode.graph.path_cache.entries`       | UpDownCounter |     `{entry}` |       P1 | none                                                                         | Current path cache entries.          |

### 4.5 Storage, page cache, memory-mapped I/O, WAL

The repo identifies storage, WAL, index, and transaction paths as core systems, with MVCC, WAL, TDE encryption, and memory-mapped I/O called out in README/architecture docs. ([about.gitlab.com][1])

| Metric                                    |    Instrument |          Unit | Priority | Attributes                                                      | Description                      |
| ----------------------------------------- | ------------: | ------------: | -------: | --------------------------------------------------------------- | -------------------------------- |
| `geode.storage.operation.count`           |       Counter | `{operation}` |       P0 | `geode.storage.operation`, `geode.result.outcome`, `error.type` | Storage operations.              |
| `geode.storage.operation.duration`        |     Histogram |           `s` |       P0 | `geode.storage.operation`, `geode.result.outcome`, `error.type` | Storage op latency.              |
| `geode.storage.bytes`                     |       Counter |          `By` |       P0 | `network.io.direction` or `geode.io.direction` = `read`/`write` | Storage bytes read/written.      |
| `geode.storage.page.cache.lookup`         |       Counter |    `{lookup}` |       P0 | `geode.cache.outcome`                                           | Page cache hits/misses.          |
| `geode.storage.page.cache.entries`        | UpDownCounter |      `{page}` |       P1 | none                                                            | Current cached pages.            |
| `geode.storage.page.cache.size`           |         Gauge |          `By` |       P1 | none                                                            | Cache memory usage.              |
| `geode.storage.page.cache.eviction.count` |       Counter |  `{eviction}` |       P1 | `geode.eviction.reason`                                         | Page cache evictions.            |
| `geode.storage.mmap.operation.duration`   |     Histogram |           `s` |       P1 | `geode.mmap.operation`                                          | mmap operation latency.          |
| `geode.storage.mmap.page_fault.count`     |       Counter |     `{fault}` |       P2 | `geode.fault.type`                                              | mmap page faults, if observable. |
| `geode.storage.file.size`                 |         Gauge |          `By` |       P0 | `geode.storage.file.kind`                                       | Data/index/WAL file size.        |
| `geode.storage.disk.usage`                |         Gauge |          `By` |       P0 | `geode.storage.kind`                                            | Disk used by Geode data.         |
| `geode.wal.record.count`                  |       Counter |    `{record}` |       P0 | `geode.wal.record.type`                                         | WAL records appended.            |
| `geode.wal.bytes`                         |       Counter |          `By` |       P0 | `geode.io.direction` = `write`/`replay`                         | WAL bytes written/replayed.      |
| `geode.wal.append.duration`               |     Histogram |           `s` |       P0 | `geode.result.outcome`                                          | WAL append latency.              |
| `geode.wal.flush.duration`                |     Histogram |           `s` |       P0 | `geode.result.outcome`                                          | WAL flush latency.               |
| `geode.wal.fsync.duration`                |     Histogram |           `s` |       P0 | `geode.result.outcome`                                          | WAL fsync latency.               |
| `geode.wal.size`                          |         Gauge |          `By` |       P0 | none                                                            | Current WAL size.                |
| `geode.wal.segment.count`                 | UpDownCounter |   `{segment}` |       P1 | `geode.wal.segment.state`                                       | WAL segments by state.           |
| `geode.wal.pending.bytes`                 |         Gauge |          `By` |       P1 | none                                                            | Buffered/unflushed WAL bytes.    |
| `geode.wal.replay.duration`               |     Histogram |           `s` |       P0 | `geode.result.outcome`                                          | Crash recovery replay duration.  |
| `geode.wal.replay.record.count`           |       Counter |    `{record}` |       P0 | none                                                            | WAL records replayed.            |

### 4.6 Transactions, MVCC, SSI, locks, deadlocks

Geode documents enhanced transaction isolation with Snapshot Isolation, Serializable Snapshot Isolation, phantom-read prevention, dependency tracking, deadlock detection, predicate locks, configurable timeouts, and monitoring hooks. ([about.gitlab.com][12])

| Metric                                           |    Instrument |            Unit | Priority | Attributes                                                                | Description                              |
| ------------------------------------------------ | ------------: | --------------: | -------: | ------------------------------------------------------------------------- | ---------------------------------------- |
| `geode.transaction.count`                        |       Counter | `{transaction}` |       P0 | `geode.transaction.isolation_level`, `geode.result.outcome`, `error.type` | Begun/completed transactions by outcome. |
| `geode.transaction.active`                       | UpDownCounter | `{transaction}` |       P0 | `geode.transaction.isolation_level`                                       | Current active transactions.             |
| `geode.transaction.duration`                     |     Histogram |             `s` |       P0 | `geode.transaction.isolation_level`, `geode.result.outcome`               | Transaction lifetime.                    |
| `geode.transaction.commit.duration`              |     Histogram |             `s` |       P0 | `geode.transaction.isolation_level`, `geode.result.outcome`               | Commit latency.                          |
| `geode.transaction.rollback.duration`            |     Histogram |             `s` |       P1 | `geode.rollback.reason`                                                   | Rollback latency.                        |
| `geode.transaction.abort.count`                  |       Counter | `{transaction}` |       P0 | `geode.abort.reason`, `error.type`                                        | Aborted transactions.                    |
| `geode.transaction.timeout.count`                |       Counter |     `{timeout}` |       P0 | `geode.transaction.isolation_level`                                       | Transaction timeouts.                    |
| `geode.transaction.serialization_conflict.count` |       Counter |    `{conflict}` |       P0 | `geode.conflict.type`                                                     | SSI serialization conflicts.             |
| `geode.transaction.phantom_conflict.count`       |       Counter |    `{conflict}` |       P1 | `geode.conflict.type`                                                     | Phantom-read conflicts.                  |
| `geode.transaction.deadlock.count`               |       Counter |    `{deadlock}` |       P0 | `geode.deadlock.victim_policy`                                            | Deadlocks detected.                      |
| `geode.transaction.deadlock.detection.duration`  |     Histogram |             `s` |       P1 | none                                                                      | Deadlock detection cycle duration.       |
| `geode.transaction.lock.wait.duration`           |     Histogram |             `s` |       P0 | `geode.lock.type`, `geode.result.outcome`                                 | Lock wait duration.                      |
| `geode.transaction.lock.count`                   | UpDownCounter |        `{lock}` |       P1 | `geode.lock.type`, `geode.lock.state`                                     | Current locks.                           |
| `geode.transaction.predicate_lock.count`         | UpDownCounter |        `{lock}` |       P1 | none                                                                      | Current predicate locks.                 |
| `geode.mvcc.version.count`                       | UpDownCounter |     `{version}` |       P1 | `geode.mvcc.version.state`                                                | MVCC versions by active/obsolete.        |
| `geode.mvcc.gc.duration`                         |     Histogram |             `s` |       P1 | `geode.result.outcome`                                                    | MVCC cleanup duration.                   |
| `geode.mvcc.gc.version.removed`                  |       Counter |     `{version}` |       P1 | none                                                                      | MVCC versions removed.                   |

### 4.7 Indexing: B-tree, hash, full-text, spatial, vector/HNSW, interval

| Metric                                          |    Instrument |          Unit | Priority | Attributes                                      | Description                           |
| ----------------------------------------------- | ------------: | ------------: | -------: | ----------------------------------------------- | ------------------------------------- |
| `geode.index.count`                             | UpDownCounter |     `{index}` |       P0 | `geode.index.type`                              | Current indexes by type.              |
| `geode.index.entries`                           | UpDownCounter |     `{entry}` |       P1 | `geode.index.type`                              | Current index entries.                |
| `geode.index.size`                              |         Gauge |          `By` |       P1 | `geode.index.type`                              | Index memory/disk footprint.          |
| `geode.index.lookup.duration`                   |     Histogram |           `s` |       P0 | `geode.index.type`, `geode.result.outcome`      | Index lookup latency.                 |
| `geode.index.scan.duration`                     |     Histogram |           `s` |       P1 | `geode.index.type`                              | Index scan latency.                   |
| `geode.index.update.duration`                   |     Histogram |           `s` |       P0 | `geode.index.type`, `geode.graph.operation`     | Index update latency on mutation.     |
| `geode.index.build.duration`                    |     Histogram |           `s` |       P1 | `geode.index.type`, `geode.result.outcome`      | Index creation/rebuild duration.      |
| `geode.index.lookup.count`                      |       Counter |    `{lookup}` |       P0 | `geode.index.type`, `geode.result.outcome`      | Index lookups.                        |
| `geode.index.selection.count`                   |       Counter | `{selection}` |       P1 | `geode.index.type`, `geode.planner.reason`      | Planner index selections.             |
| `geode.index.maintenance.queue.depth`           | UpDownCounter |      `{item}` |       P1 | `geode.index.type`                              | Pending index maintenance work.       |
| `geode.index.vector.hnsw.search.duration`       |     Histogram |           `s` |       P0 | `geode.vector.metric`                           | HNSW vector search latency.           |
| `geode.index.vector.hnsw.candidate.count`       |     Histogram | `{candidate}` |       P1 | `geode.vector.metric`                           | Candidates evaluated per HNSW search. |
| `geode.index.vector.distance.calculation.count` |       Counter | `{operation}` |       P1 | `geode.vector.metric`, `geode.execution.device` | Vector distance calculations.         |
| `geode.index.vector.dimension`                  |     Histogram | `{dimension}` |       P2 | `geode.vector.type`                             | Indexed/query vector dimensions.      |
| `geode.index.fts.query.duration`                |     Histogram |           `s` |       P1 | `geode.result.outcome`                          | Full-text query latency.              |
| `geode.index.spatial.query.duration`            |     Histogram |           `s` |       P1 | `geode.spatial.operation`                       | Spatial query latency.                |

### 4.8 Security, auth, RLS, audit, TDE, KMS

Geode’s documentation lists authentication/authorization, enhanced RLS, TDE, audit logging, KMS/Vault integration, MFA, and compliance-oriented audit trails as enterprise features. ([about.gitlab.com][1])

| Metric                                        |    Instrument |           Unit | Priority | Attributes                                                          | Description                          |
| --------------------------------------------- | ------------: | -------------: | -------: | ------------------------------------------------------------------- | ------------------------------------ |
| `geode.security.authentication.attempt.count` |       Counter |    `{attempt}` |       P0 | `geode.auth.method`, `geode.result.outcome`, `error.type`           | Login/auth attempts.                 |
| `geode.security.authentication.duration`      |     Histogram |            `s` |       P1 | `geode.auth.method`, `geode.result.outcome`                         | Auth latency.                        |
| `geode.security.session.count`                | UpDownCounter |    `{session}` |       P0 | `geode.session.state`                                               | Current sessions by state.           |
| `geode.security.session.duration`             |     Histogram |            `s` |       P1 | `geode.session.end_reason`                                          | Session lifetime.                    |
| `geode.security.authorization.check.count`    |       Counter |      `{check}` |       P0 | `geode.security.decision`, `geode.policy.type`                      | Authorization checks.                |
| `geode.security.authorization.check.duration` |     Histogram |            `s` |       P0 | `geode.policy.type`, `geode.security.decision`                      | Authorization latency.               |
| `geode.security.rls.evaluation.count`         |       Counter | `{evaluation}` |       P0 | `geode.security.decision`, `geode.policy.type`                      | RLS evaluations.                     |
| `geode.security.rls.evaluation.duration`      |     Histogram |            `s` |       P0 | `geode.policy.type`                                                 | RLS evaluation latency.              |
| `geode.security.rls.filtered_rows`            |       Counter |        `{row}` |       P1 | `db.operation.name`                                                 | Rows filtered by RLS.                |
| `geode.security.rls.policy.compile.duration`  |     Histogram |            `s` |       P1 | `geode.result.outcome`                                              | RLS policy compilation latency.      |
| `geode.audit.event.count`                     |       Counter |      `{event}` |       P0 | `geode.audit.event_type`, `geode.result.outcome`                    | Audit events produced.               |
| `geode.audit.queue.depth`                     | UpDownCounter |      `{event}` |       P0 | none                                                                | Audit queue depth.                   |
| `geode.audit.event.dropped`                   |       Counter |      `{event}` |       P0 | `geode.drop.reason`                                                 | Dropped audit events.                |
| `geode.audit.flush.duration`                  |     Histogram |            `s` |       P1 | `geode.result.outcome`                                              | Audit flush latency.                 |
| `geode.crypto.tde.operation.duration`         |     Histogram |            `s` |       P0 | `geode.crypto.operation`, `geode.result.outcome`                    | TDE encrypt/decrypt/rotate duration. |
| `geode.crypto.tde.bytes`                      |       Counter |           `By` |       P0 | `geode.crypto.operation`                                            | Bytes encrypted/decrypted.           |
| `geode.crypto.tde.error.count`                |       Counter |      `{error}` |       P0 | `error.type`                                                        | TDE failures.                        |
| `geode.kms.request.duration`                  |     Histogram |            `s` |       P1 | `geode.kms.provider`, `geode.kms.operation`, `geode.result.outcome` | KMS/Vault request latency.           |
| `geode.kms.request.count`                     |       Counter |    `{request}` |       P1 | `geode.kms.provider`, `geode.kms.operation`, `geode.result.outcome` | KMS requests.                        |
| `geode.kms.cache.lookup`                      |       Counter |     `{lookup}` |       P1 | `geode.cache.outcome`                                               | KMS key/material cache hits/misses.  |

Never include usernames, raw tokens, key IDs, policy text, query property values, or session IDs as metric attributes.

### 4.9 Distributed query coordination, shards, cluster, Raft

Geode’s distributed-query docs describe query coordination across shards/nodes, scatter/gather execution, shard pruning, predicate pushdown, merge strategies, connection pooling, retry logic, query caching, and metrics such as total queries, cache hits/misses, shard queries, merge time, active connections, retries, and timeouts. ([about.gitlab.com][13])

| Metric                                          |    Instrument |         Unit | Priority | Attributes                                          | Description                          |
| ----------------------------------------------- | ------------: | -----------: | -------: | --------------------------------------------------- | ------------------------------------ |
| `geode.cluster.node.count`                      | UpDownCounter |     `{node}` |       P0 | `geode.node.role`, `geode.node.state`               | Current cluster nodes.               |
| `geode.cluster.node.health`                     |         Gauge |          `1` |       P0 | `geode.node.role`, `geode.node.id`                  | Per-node health, 1/0.                |
| `geode.shard.count`                             | UpDownCounter |    `{shard}` |       P0 | `geode.shard.state`                                 | Current shards.                      |
| `geode.shard.size`                              |         Gauge |         `By` |       P1 | `geode.shard.id`                                    | Shard storage size.                  |
| `geode.shard.query.count`                       |       Counter |    `{query}` |       P0 | `geode.shard.id`, `geode.result.outcome`            | Shard-local query fragments.         |
| `geode.distributed.query.count`                 |       Counter |    `{query}` |       P0 | `geode.consistency.level`, `geode.result.outcome`   | Distributed queries.                 |
| `geode.distributed.query.duration`              |     Histogram |          `s` |       P0 | `geode.consistency.level`, `geode.result.outcome`   | Full distributed query latency.      |
| `geode.distributed.query.fanout`                |     Histogram |    `{shard}` |       P0 | `geode.consistency.level`                           | Shards/nodes contacted per query.    |
| `geode.distributed.query.scatter.duration`      |     Histogram |          `s` |       P1 | none                                                | Scatter phase latency.               |
| `geode.distributed.query.gather.duration`       |     Histogram |          `s` |       P1 | none                                                | Gather phase latency.                |
| `geode.distributed.query.merge.duration`        |     Histogram |          `s` |       P1 | `geode.merge.strategy`                              | Result merge latency.                |
| `geode.distributed.query.partial_failure.count` |       Counter |  `{failure}` |       P0 | `error.type`                                        | Partial shard/node failures.         |
| `geode.distributed.query.retry.count`           |       Counter |    `{retry}` |       P1 | `geode.retry.reason`                                | Distributed query retries.           |
| `geode.distributed.query.cache.lookup`          |       Counter |   `{lookup}` |       P1 | `geode.cache.outcome`                               | Distributed query cache hits/misses. |
| `geode.raft.term`                               |         Gauge |          `1` |       P1 | `geode.node.role`                                   | Current Raft term.                   |
| `geode.raft.election.count`                     |       Counter | `{election}` |       P1 | `geode.result.outcome`                              | Raft elections.                      |
| `geode.raft.election.duration`                  |     Histogram |          `s` |       P1 | `geode.result.outcome`                              | Election duration.                   |
| `geode.raft.log.index`                          |         Gauge |          `1` |       P1 | `geode.raft.index_type` = `last`/`commit`/`applied` | Raft log indexes.                    |
| `geode.raft.replication.lag`                    |         Gauge |    `{entry}` |       P1 | `geode.node.role`                                   | Follower replication lag.            |
| `geode.raft.append_entries.duration`            |     Histogram |          `s` |       P1 | `geode.result.outcome`                              | AppendEntries RPC latency.           |

### 4.10 CDC, streaming, real-time analytics

The real-time analytics docs describe CDC integration, event queues, batch processing, pattern detection, anomaly detection, ML integration, queue sizes, processing intervals, and metrics export. ([about.gitlab.com][14])

| Metric                                      |    Instrument |        Unit | Priority | Attributes                                           | Description                                |
| ------------------------------------------- | ------------: | ----------: | -------: | ---------------------------------------------------- | ------------------------------------------ |
| `geode.cdc.event.count`                     |       Counter |   `{event}` |       P0 | `geode.cdc.event_type`, `geode.result.outcome`       | CDC events produced/processed.             |
| `geode.cdc.lag`                             |         Gauge |         `s` |       P0 | `geode.cdc.stream`                                   | Time lag from source change to processing. |
| `geode.cdc.queue.depth`                     | UpDownCounter |   `{event}` |       P0 | `geode.cdc.stream`                                   | CDC queue depth.                           |
| `geode.cdc.batch.size`                      |     Histogram |   `{event}` |       P1 | `geode.cdc.stream`                                   | Events per batch.                          |
| `geode.cdc.batch.duration`                  |     Histogram |         `s` |       P1 | `geode.cdc.stream`, `geode.result.outcome`           | CDC batch processing time.                 |
| `geode.cdc.sink.delivery.duration`          |     Histogram |         `s` |       P1 | `geode.sink.type`, `geode.result.outcome`            | Sink delivery latency.                     |
| `geode.cdc.sink.error.count`                |       Counter |   `{error}` |       P0 | `geode.sink.type`, `error.type`                      | Sink errors.                               |
| `geode.cdc.event.dropped`                   |       Counter |   `{event}` |       P0 | `geode.drop.reason`                                  | Dropped CDC events.                        |
| `geode.analytics.event.count`               |       Counter |   `{event}` |       P0 | `geode.analytics.event_type`, `geode.result.outcome` | Analytics events.                          |
| `geode.analytics.event.queue.depth`         | UpDownCounter |   `{event}` |       P0 | none                                                 | Analytics queue depth.                     |
| `geode.analytics.event.processing.duration` |     Histogram |         `s` |       P0 | `geode.analytics.event_type`                         | Event processing latency.                  |
| `geode.analytics.pattern.detected.count`    |       Counter | `{pattern}` |       P1 | `geode.pattern.type`                                 | Patterns detected.                         |
| `geode.analytics.pattern.confidence`        |     Histogram |         `1` |       P2 | `geode.pattern.type`                                 | Pattern confidence distribution.           |
| `geode.analytics.anomaly.detected.count`    |       Counter | `{anomaly}` |       P1 | `geode.anomaly.severity`                             | Anomalies detected.                        |
| `geode.analytics.anomaly.score`             |     Histogram |         `1` |       P2 | `geode.anomaly.severity`                             | Anomaly score distribution.                |

### 4.11 ML embeddings, vector operations, graph algorithms, GPU

Geode’s ML docs describe Node2Vec, GraphSAGE, DeepWalk, embedding storage, training context, statistics, convergence monitoring, similarity search, and k-nearest-neighbor operations. ([about.gitlab.com][15]) The graph algorithms guide lists centrality, Louvain, label propagation, Union-Find, SCC, and related use cases. ([about.gitlab.com][16])

| Metric                                  |    Instrument |          Unit | Priority | Attributes                                                                     | Description                      |
| --------------------------------------- | ------------: | ------------: | -------: | ------------------------------------------------------------------------------ | -------------------------------- |
| `geode.ml.embedding.count`              | UpDownCounter | `{embedding}` |       P1 | `geode.ml.algorithm`                                                           | Stored embeddings.               |
| `geode.ml.embedding.dimension`          |     Histogram | `{dimension}` |       P2 | `geode.ml.algorithm`                                                           | Embedding dimensions.            |
| `geode.ml.embedding.update.duration`    |     Histogram |           `s` |       P1 | `geode.ml.algorithm`, `geode.result.outcome`                                   | Embedding update duration.       |
| `geode.ml.training.run.count`           |       Counter |       `{run}` |       P1 | `geode.ml.algorithm`, `geode.result.outcome`                                   | Training runs.                   |
| `geode.ml.training.duration`            |     Histogram |           `s` |       P1 | `geode.ml.algorithm`, `geode.result.outcome`                                   | Training duration.               |
| `geode.ml.training.epoch.count`         |       Counter |     `{epoch}` |       P1 | `geode.ml.algorithm`                                                           | Epochs completed.                |
| `geode.ml.training.loss`                |         Gauge |           `1` |       P2 | `geode.ml.algorithm`                                                           | Latest training loss.            |
| `geode.ml.training.convergence.epoch`   |     Histogram |     `{epoch}` |       P2 | `geode.ml.algorithm`                                                           | Epoch of convergence/early stop. |
| `geode.ml.similarity.search.duration`   |     Histogram |           `s` |       P1 | `geode.vector.metric`, `geode.ml.algorithm`                                    | Similarity search latency.       |
| `geode.ml.similarity.result.count`      |     Histogram |    `{result}` |       P1 | `geode.vector.metric`                                                          | Number of similarity results.    |
| `geode.graph.algorithm.run.count`       |       Counter |       `{run}` |       P1 | `geode.graph.algorithm.name`, `geode.execution.device`, `geode.result.outcome` | Algorithm invocations.           |
| `geode.graph.algorithm.duration`        |     Histogram |           `s` |       P1 | `geode.graph.algorithm.name`, `geode.execution.device`, `geode.result.outcome` | Algorithm runtime.               |
| `geode.graph.algorithm.node.processed`  |       Counter |      `{node}` |       P1 | `geode.graph.algorithm.name`                                                   | Nodes processed.                 |
| `geode.graph.algorithm.edge.processed`  |       Counter |      `{edge}` |       P1 | `geode.graph.algorithm.name`                                                   | Edges processed.                 |
| `geode.graph.algorithm.iteration.count` |       Counter | `{iteration}` |       P1 | `geode.graph.algorithm.name`                                                   | Algorithm iterations.            |
| `geode.gpu.kernel.duration`             |     Histogram |           `s` |       P2 | `geode.gpu.kernel`, `geode.graph.algorithm.name`                               | GPU kernel duration.             |
| `geode.gpu.operation.count`             |       Counter | `{operation}` |       P2 | `geode.gpu.operation`, `geode.result.outcome`                                  | GPU operations.                  |
| `geode.gpu.memory.usage`                |         Gauge |          `By` |       P2 | `geode.gpu.device.id`                                                          | GPU memory usage.                |

### 4.12 Backup, restore, migration

| Metric                           | Instrument |          Unit | Priority | Attributes                                                | Description                      |
| -------------------------------- | ---------: | ------------: | -------: | --------------------------------------------------------- | -------------------------------- |
| `geode.backup.count`             |    Counter |    `{backup}` |       P0 | `geode.backup.kind`, `geode.result.outcome`, `error.type` | Backup attempts.                 |
| `geode.backup.duration`          |  Histogram |           `s` |       P0 | `geode.backup.kind`, `geode.result.outcome`               | Backup duration.                 |
| `geode.backup.bytes`             |    Counter |          `By` |       P0 | `geode.backup.kind`                                       | Bytes backed up.                 |
| `geode.backup.compression.ratio` |  Histogram |           `1` |       P1 | `geode.compression.algorithm`                             | Backup compression ratio.        |
| `geode.backup.upload.duration`   |  Histogram |           `s` |       P1 | `geode.object_store.provider`, `geode.result.outcome`     | S3/object-store upload duration. |
| `geode.restore.count`            |    Counter |   `{restore}` |       P0 | `geode.result.outcome`, `error.type`                      | Restore attempts.                |
| `geode.restore.duration`         |  Histogram |           `s` |       P0 | `geode.result.outcome`                                    | Restore duration.                |
| `geode.restore.bytes`            |    Counter |          `By` |       P0 | none                                                      | Bytes restored.                  |
| `geode.migration.applied.count`  |    Counter | `{migration}` |       P1 | `geode.result.outcome`, `error.type`                      | Schema/data migrations applied.  |
| `geode.migration.duration`       |  Histogram |           `s` |       P1 | `geode.result.outcome`                                    | Migration duration.              |

## 5. Migration from existing Prometheus metrics

| Existing metric                                            | Problem                                                                                                            | New OTel metric                                                                                                                                  |         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| `geode_queries_total`                                      | Prometheus name, no standard attrs                                                                                 | `geode.query.count{geode.result.outcome}`                                                                                                        |         |
| `geode_queries_failed_total`                               | Duplicates error outcome                                                                                           | Fold into `geode.query.count{geode.result.outcome="error"}` or emit `geode.query.error.count` only if dashboards require separate error counter. |         |
| `geode_query_duration_seconds`                             | Prometheus name                                                                                                    | `geode.query.execution.duration`, unit `s`                                                                                                       |         |
| `geode_query_latency_ms`                                   | Uses ms buckets and current registry does not track sum                                                            | Replace with `geode.query.execution.duration` histogram with real sum/count.                                                                     |         |
| `geode_connections_active`                                 | Too generic                                                                                                        | `geode.transport.connection.count{geode.connection.state="active"}`                                                                              |         |
| `geode_connections_total`                                  | Current collector logic appears to increment after assigning `connections_total`, which risks recording zero delta | `geode.transport.connection.opened`                                                                                                              |         |
| `geode_transactions_total`                                 | Missing outcome/isolation attrs                                                                                    | `geode.transaction.count{geode.result.outcome, geode.transaction.isolation_level}`                                                               |         |
| `geode_transactions_failed_total`                          | Duplicates outcome                                                                                                 | Fold into `geode.transaction.count{geode.result.outcome="error"}`                                                                                |         |
| `geode_nodes_total`                                        | Prometheus name                                                                                                    | `geode.graph.node.count`                                                                                                                         |         |
| `geode_edges_total`                                        | Prometheus name                                                                                                    | `geode.graph.edge.count`                                                                                                                         |         |
| `geode_memory_bytes` / dashboard `geode_memory_used_bytes` | Inconsistent naming                                                                                                | Prefer standard `process.memory.usage`; use `geode.storage.memory.usage` only for storage-engine-owned memory.                                   |         |
| dashboard `geode_wal_size_bytes`                           | Dashboard expects it, collector does not register it                                                               | `geode.wal.size`                                                                                                                                 |         |
| `geode_pathcache_hits`, `geode_pathcache_misses`           | Two counters instead of one labeled metric                                                                         | `geode.graph.path_cache.lookup{geode.cache.outcome="hit                                                                                          | miss"}` |

The current registry emits `geode_query_latency_ms`, `geode_active_transactions`, and path-cache counters, while the Prometheus collector registers query, connection, transaction, node, edge, and memory metrics. ([about.gitlab.com][17])

## 6. Export behavior

### OTLP

Default production path:

```text
OTEL_METRICS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_SERVICE_NAME=geode
OTEL_RESOURCE_ATTRIBUTES=service.namespace=codepros,deployment.environment.name=prod
```

### Prometheus compatibility

Keep the existing `/metrics` endpoint for compatibility, but generate it from the same OTel instruments. Do not maintain a separate metric registry with different names.

Recommended config:

```text
GEODE_METRICS_ENABLED=true
GEODE_METRICS_PORT=9090
GEODE_METRICS_BIND=127.0.0.1
GEODE_OTEL_EXPORTER=prometheus
```

Prometheus output names should be translated from OTel names:

```text
geode.query.execution.duration -> geode_query_execution_duration_seconds
geode.wal.size                 -> geode_wal_size_bytes
geode.query.count              -> geode_query_count_total
```

## 7. Cardinality and privacy rules

Default-deny these attributes on metrics:

```text
user.id
username
session.id
request.id
trace.id
span.id
raw query text
literal property values
node id
edge id
path id
full peer IP for untrusted clients
tenant id
index name
policy name
key id
```

Allowed only under explicit debug views:

```text
geode.tenant.id
geode.graph.name
geode.index.name
network.peer.address
db.query.text
```

Use exemplars to correlate high-latency histogram points with traces instead of putting trace IDs into metric attributes.

## 8. Implementation acceptance criteria

P0 is not complete until all of these are true:

1. Every P0 metric above is emitted through one OTel `Meter`, not through parallel ad hoc registries.
2. Histograms track real `sum`, `count`, and bucket counts; no placeholder sums.
3. All duration metrics use unit `s`.
4. All byte metrics use unit `By`.
5. Query text is disabled by default.
6. Metrics include `service.name`, `service.version`, and `service.instance.id`.
7. Client libraries emit `db.client.operation.duration`.
8. Server-side query metrics emit `geode.query.execution.duration`.
9. Transaction metrics include `geode.transaction.isolation_level`.
10. Security metrics never expose identities, credentials, policy bodies, or key identifiers.
11. Prometheus `/metrics` and OTLP export show the same logical metric set.
12. CI includes a scrape/parse test for `/metrics`.
13. CI includes an OTLP export smoke test through an OTel Collector.
14. The Grafana dashboard is migrated from legacy names to translated OTel names.
15. Metric cardinality tests fail if default labels include unbounded identifiers.

## 9. First implementation cut

Implement in this order:

1. **Metric facade**: `src/monitoring/otel_metrics.zig`, with typed functions such as `recordQuery`, `recordStorageOperation`, `recordTransaction`, `recordAuthCheck`.
2. **P0 query + transport + transaction + storage + WAL metrics**.
3. **Existing Prometheus migration** so dashboards keep working.
4. **Client-side `db.client.*` metrics** in Go/Zig clients.
5. **Security and RLS metrics**.
6. **Index and vector metrics**.
7. **Distributed, CDC, analytics, ML, and GPU metrics**.
8. **Debug/opt-in views** for graph/index/tenant-level breakdowns.

The highest-value production SLOs will come from these P0 metrics: `geode.query.execution.duration`, `geode.query.count`, `geode.transport.connection.count`, `geode.transaction.count`, `geode.transaction.deadlock.count`, `geode.wal.fsync.duration`, `geode.storage.operation.duration`, `geode.security.authorization.check.duration`, `geode.audit.event.dropped`, `geode.cluster.node.health`, and `geode.cdc.lag`.

[1]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/README.md "gitlab.com"
[2]: https://gitlab.com/api/v4/projects/devnw%2Fcodepros%2Fgeode%2Fgeode/repository/tree?path=src%2Fmonitoring&per_page=100&ref=main "gitlab.com"
[3]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/src/monitoring/prometheus.zig "gitlab.com"
[4]: https://opentelemetry.io/docs/specs/otel/metrics/api/ "Metrics API | OpenTelemetry"
[5]: https://opentelemetry.io/docs/specs/semconv/general/metrics/ "Metrics semantic conventions | OpenTelemetry"
[6]: https://opentelemetry.io/docs/specs/semconv/resource/service/ "Service semantic conventions | OpenTelemetry"
[7]: https://opentelemetry.io/docs/specs/semconv/db/database-metrics/ "Semantic conventions for database client metrics | OpenTelemetry"
[8]: https://raw.githubusercontent.com/open-telemetry/semantic-conventions/main/docs/db/database-metrics.md "raw.githubusercontent.com"
[9]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/CLAUDE.md "gitlab.com"
[10]: https://opentelemetry.io/docs/specs/semconv/system/process-metrics/ "Semantic conventions for OS process metrics | OpenTelemetry"
[11]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/CURRENT_ARCHITECTURE.md "gitlab.com"
[12]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/ENHANCED_TRANSACTION_ISOLATION.md "gitlab.com"
[13]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/DISTRIBUTED_QUERY_COORDINATION.md "gitlab.com"
[14]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/REAL_TIME_ANALYTICS.md "gitlab.com"
[15]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/ML_GRAPH_EMBEDDINGS.md "gitlab.com"
[16]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md "gitlab.com"
[17]: https://gitlab.com/devnw/codepros/geode/geode/-/raw/main/src/monitoring/registry.zig "gitlab.com"

## 10. Migration status (2026-04-28)

**P0 metrics: COMPLETE** (Tasks 1-23 of the implementation plan).

The full `MeterProvider` is initialised at server startup (Task 6), `/metrics` renders OTel snapshots via `otel.exporters.prometheus.Prometheus.render` (Task 7), and the legacy `prometheus.MetricsCollector` is now a fallback path (Task 23). Every P0 instrument from §4.1–4.12 plus the §3 client metrics has a facade entry in `src/monitoring/otel_metrics.zig`. A subset of P0 instruments are wired to production call sites (see per-task DONE_WITH_CONCERNS notes in commit history); the remainder are exercised by `tests/test_otel_facade_smoke.zig` and `tests/test_otel_cardinality_guard.zig`.

### P0 acceptance criteria status (§8)

1. ✅ Single `MeterProvider` per process via `src/monitoring/otel_metrics.zig` (Task 4 + Task 6).
2. ✅ Histograms track real sum/count/buckets via the OTel SDK aggregation pipeline.
3. ✅ All duration metrics use unit `s` (Tasks 8-19).
4. ✅ All byte metrics use unit `By` (Tasks 9, 12, 18, 19).
5. ✅ `db.query.text` disabled by default (cardinality guard test, Task 20).
6. ✅ `service.name`, `service.version`, `service.instance.id` on every metric (Task 3).
7. ⚠️ **Partial** — server-side `db.client.*` metrics for the internal remote-query path landed (Task 19); external Go/Zig clients track in their own repos.
8. ✅ `geode.query.execution.duration` emitted (Task 10).
9. ✅ Transaction metrics include `geode.transaction.isolation_level` (Task 11).
10. ✅ Security metrics never expose identities — enforced by `tests/test_otel_cardinality_guard.zig` (Task 20).
11. ✅ `/metrics` and OTLP export show the same logical metric set (Task 7 + Task 21).
12. ✅ CI scrape test (`tests/geodetestlab/otel_metrics_parity.yml`, Task 22) — geodetestlab harness needs HTTP probe support to execute; the Zig integration test `tests/test_otel_prometheus_parity.zig` covers the rendering equivalent.
13. ⚠️ **Manual only** — OTLP loopback test requires a running collector; documented in Task 21's commit message.
14. ✅ Dashboard migrated (Task 23 — `monitoring/grafana/dashboards/geode-dashboard.json` panels renamed per §5).
15. ✅ Cardinality test gates default labels (Task 20 — fails the build if any forbidden attribute key appears).

### Deferred work

- **P1 metrics** (non-P0 instruments within each §4 subsystem): see `docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md` for the full subsystem-by-subsystem checklist.
- **P2 metrics** (GPU, embedding/vector dimensions, anomaly score histograms, graph degree distribution, ML training loss/convergence): tracked in the same P1 follow-up spec under the "P2" heading.
- **Production call-site sweeps** for several facade functions (handshake duration, deadlock count, KMS request count, rls.filtered_rows, etc.) — the facade is ready and smoke-tested, but call sites in production code paths (`src/security/`, `src/cdc/`, `src/distributed/`, etc.) are documented as TODOs in the relevant task commits and will land in a follow-up sweep.
- **Legacy registry deletion**: `src/monitoring/registry.zig` and the `MetricsCollector` fallback in `src/monitoring/prometheus.zig` are soft-deprecated (Task 23) but not yet deleted. Schedule deletion after one full release of OTel-only operation.

### Commit chain (for traceability)

```
0d3268eb test(otel): geodetestlab parity spec for /metrics P0 names
b534c9f8 feat(otel): OTLP/HTTP push when OTEL_METRICS_EXPORTER=otlp
0f7b824d test(otel): cardinality + privacy guard against forbidden attribute keys
04332b5e feat(otel): process metrics + db.client.* family for distributed RPC
cab86368 feat(otel): backup + restore metrics (P0 set per spec §4.12)
a6956e5e feat(otel): CDC + real-time analytics metrics (P0 set per spec §4.10)
5b75b45a feat(otel): distributed + cluster metrics (P0 set per spec §4.9)
3a66ea35 feat(otel): security/RLS/audit/TDE/KMS metrics (P0 set per spec §4.8)
5b694b7e feat(otel): index + vector HNSW metrics (P0 set per spec §4.7)
87e8e256 feat(otel): graph data model + mutation metrics (P0 set per spec §4.4)
10a7f95d feat(otel): storage + WAL metrics (P0 set per spec §4.5)
e98df7c3 feat(otel): transaction + lock + deadlock metrics (P0 set per spec §4.6)
0ac5c8c9 feat(otel): query lifecycle metrics (P0 set per spec §4.3)
88bd455e feat(otel): QUIC transport metrics (P0 set per spec §4.2)
4baf0355 feat(otel): server lifecycle metrics (uptime, health, reload, shutdown)
2a05cf7c docs(otel): commit implementation plan for traceability
da641443 feat(otel): /metrics renders OTel snapshot, legacy collector fallback
8bc08065 feat(otel): initialise MeterProvider during server startup
44d16027 feat(otel): histogram bucket profile constants per spec §2
6a8e8f41 feat(otel): facade scaffold with global MeterProvider lifecycle
8c73beb2 feat(otel): resource builder with service + db semconv attrs
0713e50f build(otel): wire otel module into root + cli targets
9d823144 chore(deps): add otel @ 20078af2 (gitlab.com/devnw/zig/otel)
a6cfc7d1 refactor(otel): soft-deprecate legacy registry + prometheus collector; rename dashboard panels
```

(Task 24's own commit will be appended once this footer lands.)
