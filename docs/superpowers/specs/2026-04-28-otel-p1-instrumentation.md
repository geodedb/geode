# OTel P1 Instrumentation Follow-up

**Goal:** Cover the P1 metrics from `docs/otel-updates.md` §4 that were deferred from the P0 plan landed on 2026-04-28.

**Status:** Spec stub — implementation deferred until the P0 surface is exercised in production for at least one release cycle.

## Scope by subsystem

### §4.1 Server lifecycle

- ✅ Done in P0: `geode.server.config.reload.count`, `geode.server.shutdown.count`.
- (No P1 items in this section.)

### §4.2 Transport

- `geode.transport.stream.count` — UpDownCounter `{stream}` per `geode.stream.state`.
- `geode.transport.messages` — Counter `{message}`.
- `geode.transport.retry.count` — Counter `{retry}`.
- `geode.transport.queue.depth` — UpDownCounter `{item}`.

### §4.3 Query

- `geode.query.optimize.duration` — Histogram `s`.
- `geode.query.rows.scanned` — Histogram `{row}`.
- `geode.query.result.bytes` — Histogram `By`.
- `geode.query.memory.peak` — Histogram `By`.
- `geode.query.cancelled.count` — Counter `{query}`.
- `geode.query.execution.operator.duration` / `.rows` / `.count`.
- `geode.query.cache.lookup` / `.entries` / `.size`.

### §4.4 Graph

- `geode.graph.property.count`, `label.count`, `relationship_type.count` (UpDownCounters per `db.namespace`).
- `geode.graph.property.operation.count` — Counter `{operation}`.
- `geode.graph.pattern.match.duration` / `pattern.matches`.
- `geode.graph.path.expansion.duration` / `path.length`.
- `geode.graph.path_cache.lookup` / `path_cache.entries`.

### §4.5 Storage + WAL

- `geode.storage.page.cache.entries`, `cache.size`, `cache.eviction.count`.
- `geode.storage.mmap.operation.duration`, `mmap.page_fault.count`.
- `geode.wal.segment.count`, `wal.pending.bytes`.

### §4.6 Transactions

- `geode.transaction.rollback.duration`.
- `geode.transaction.phantom_conflict.count`.
- `geode.transaction.deadlock.detection.duration`.
- `geode.transaction.lock.count`, `predicate_lock.count`.
- `geode.mvcc.version.count`, `mvcc.gc.duration`, `mvcc.gc.version.removed`.

### §4.7 Indexes

- `geode.index.entries`, `index.size`, `index.scan.duration`, `index.build.duration`, `index.selection.count`, `index.maintenance.queue.depth`.
- `geode.index.vector.hnsw.candidate.count`, `index.vector.distance.calculation.count`.
- `geode.index.fts.query.duration`, `index.spatial.query.duration`.

### §4.8 Security

- `geode.security.authentication.duration` (Task 15 facade has `recordAuthDuration`; wire production call sites).
- `geode.security.session.duration`.
- `geode.security.rls.filtered_rows`, `rls.policy.compile.duration`.
- `geode.audit.flush.duration`.
- `geode.kms.request.duration`, `kms.request.count`, `kms.cache.lookup`.

### §4.9 Distributed

- `geode.shard.size`.
- `geode.distributed.query.scatter.duration`, `gather.duration`, `merge.duration`.
- `geode.distributed.query.retry.count`, `distributed.query.cache.lookup`.
- `geode.raft.term`, `raft.election.count` / `.duration`, `raft.log.index`, `raft.replication.lag`, `raft.append_entries.duration`.

### §4.10 CDC + analytics

- `geode.cdc.batch.size`, `cdc.batch.duration`, `cdc.sink.delivery.duration`.
- `geode.analytics.pattern.detected.count`, `analytics.anomaly.detected.count`.

### §4.11 ML + graph algorithms (entire subsystem deferred)

- `geode.ml.embedding.count` / `.dimension` / `.update.duration`.
- `geode.ml.training.run.count` / `.duration` / `.epoch.count`.
- `geode.ml.similarity.search.duration` / `.result.count`.
- `geode.graph.algorithm.run.count` / `.duration` / `.node.processed` / `.edge.processed` / `.iteration.count`.

### §4.12 Backup

- `geode.backup.compression.ratio`.
- `geode.backup.upload.duration`.
- `geode.migration.applied.count` / `migration.duration`.

## P2 (deferred separately)

GPU metrics from §4.11, `geode.graph.degree`, `geode.index.vector.dimension`, `analytics.pattern.confidence`, `analytics.anomaly.score`, `geode.ml.training.loss`, `geode.ml.training.convergence.epoch`.

## Architecture

All P1 work goes through the existing facade in `src/monitoring/otel_metrics.zig`. No new infrastructure. Each metric follows the established pattern: enum types for low-cardinality attributes, `ensureSubsystem() !*Metrics` lazy-init, `recordX` public functions with attribute slices built from `otel.internal.attributes.Entry` literals.
