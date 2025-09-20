# CDC Diagnostics & Roadmap

## Overview

The Change Data Capture (CDC) subsystem currently provides **in-process capture** of graph change events (insert/update/delete) and **diagnostics export** via the `CDC_DIAGNOSTICS` protocol request (or direct engine call in tests). It is **observability-focused**, not yet a durable or externally replicated change feed.

## Current Scope (v0.15.x)

- Event capture with monotonic sequence id.
- In-memory buffer + file sink (`cdc.log`).
- Guardrails on malformed WAL record parsing.
- Snapshots & prefix+hash retention for first N malformed payloads.
- Adaptive flush (experimental) for dynamic batch adjustment.
- Diagnostics JSON export containing counters, config echo, engine runtime state.

## Non-Goals (Phase 0)

- External streaming sinks (Kafka/Kinesis/Webhook/PubSub) beyond stubs.
- Exactly-once or at-least-once delivery semantics.
- Cross-node replication consistency guarantees.
- Backpressure negotiation with clients.

## Example Diagnostics Payload (abridged)

```json
{
  "version": 1,
  "timestamp_ms": 1736963250000,
  "malformed_wal_records": 3,
  "total_wal_attempts": 57,
  "malformed_ratio": 0.0526,
  "guardrail_warn_triggered": false,
  "guardrail_abort_triggered": false,
  "config": {
    "enabled": true,
    "warn_pct": 0.05,
    "abort_pct": 0.1,
    "snapshot_interval": 8,
    "hash_retain": 16,
    "adaptive_flush": true,
    "batch_size": 64
  },
  "engine": {
    "pending_events": 12,
    "peak_buffer": 128,
    "dynamic_batch_size": 64,
    "batch_adjustments": 2
  },
  "malformed_snapshots": [
    { "ts": 1736963245000, "count": 2 },
    { "ts": 1736963250000, "count": 3 }
  ],
  "malformed_prefix_hashes": [{ "prefix": "7B224944", "hash": "9f2c6b04" }]
}
```

Fields may omit optional keys if zero / empty (subject to stabilization).

## Field Reference

| Field                       | Type  | Description                                                   |
| --------------------------- | ----- | ------------------------------------------------------------- |
| `version`                   | int   | Schema version for diagnostics payload.                       |
| `timestamp_ms`              | int   | Epoch ms when snapshot generated.                             |
| `malformed_wal_records`     | int   | Count of malformed WAL decode attempts.                       |
| `total_wal_attempts`        | int   | Total WAL decode attempts (good + malformed).                 |
| `malformed_ratio`           | float | malformed / total (0 if total == 0).                          |
| `guardrail_warn_triggered`  | bool  | Latched true once malformed ratio >= warn threshold.          |
| `guardrail_abort_triggered` | bool  | Latched true once malformed ratio >= abort threshold.         |
| `config.enabled`            | bool  | Whether CDC capture active.                                   |
| `config.warn_pct`           | float | Guardrail warn threshold.                                     |
| `config.abort_pct`          | float | Guardrail abort threshold.                                    |
| `config.snapshot_interval`  | int   | Interval (events) for malformed snapshot capture.             |
| `config.hash_retain`        | int   | Max retained malformed prefix/hash pairs.                     |
| `config.adaptive_flush`     | bool  | Adaptive flush enabled.                                       |
| `config.batch_size`         | int   | Current static batch size (if adaptive off).                  |
| `engine.pending_events`     | int   | Events buffered but not flushed.                              |
| `engine.peak_buffer`        | int   | High water mark of buffered events.                           |
| `engine.dynamic_batch_size` | int   | Current adaptive batch size (if enabled).                     |
| `engine.batch_adjustments`  | int   | Number of adaptive tuning adjustments.                        |
| `malformed_snapshots[]`     | array | Historical malformed counts with timestamps.                  |
| `malformed_prefix_hashes[]` | array | Array of prefix/hash objects for retained malformed payloads. |

## Environment Variables

| Variable                                | Purpose                                         |
| --------------------------------------- | ----------------------------------------------- |
| `GEODE_CDC_ENABLE`                      | Enable CDC capture & diagnostics frame.         |
| `GEODE_MALFORMED_WAL_WARN_PCT`          | Override warn threshold (default impl-defined). |
| `GEODE_MALFORMED_WAL_ABORT_PCT`         | Override abort threshold (must exceed warn).    |
| `GEODE_MALFORMED_WAL_SNAPSHOT_INTERVAL` | Snapshot interval override.                     |
| `GEODE_WAL_COMPACT_INTERVAL`            | WAL compaction cadence (shared with storage).   |

## Roadmap (Proposed Phases)

### Phase 1: Hardening

- Deterministic payload ordering & optional suppression of zero-valued keys.
- Add `uptime_ms` & `last_flush_ms` metrics.
- Backpressure flag when pending exceeds configurable watermark.
- Guardrail outcome status integration (emit status codes when triggered).

### Phase 2: External Sink Integrations

- Kafka sink (idempotent producer + partition key = sequence range).
- Webhook sink with retry & exponential backoff.
- Pluggable sink registration via dynamic dispatch table.

### Phase 3: Delivery Semantics & Replay

- WAL-based durable capture cursor (LSN watermark).
- At-least-once delivery with offset persistence per sink.
- Replay API: `CDC_REPLAY { from_seq, to_seq? }` streaming frames.

### Phase 4: Distributed & Sharded Awareness

- Per-shard sequence namespaces + global ordering service (lexicographic merge on (term, shard_id, seq)).
- Raft-applied change broadcast to CDC aggregator.
- Consistency metadata: `applied_term`, `commit_index` in diagnostics.

### Phase 5: Advanced Processing

- Filtered subscriptions (predicate pushdown on label/property fields).
- Schema evolution markers in event stream (DDL shadow events).
- Compression (batch-level) with negotiated codec.

## Testing Strategy

| Layer        | Current                        | Planned Additions                           |
| ------------ | ------------------------------ | ------------------------------------------- |
| Unit         | Event capture, malformed ratio | Adaptive flush tuning, snapshot aging       |
| E2E (engine) | Diagnostics JSON keys presence | Guardrail threshold trigger paths           |
| Protocol     | (Pending) frame roundtrip      | Replay, external sinks handshake            |
| Performance  | Manual profiling               | Batch flush latency & throughput benchmarks |

## Open Questions

- Should malformed payload retention redact property values? (Privacy / security)
- Do we expose config diffs vs static echo for dynamic tuning?
- Is adaptive flush governed by percentile latency target or occupancy heuristic?

## Backward Compatibility Policy

- Increment `version` if: key removed, type change, or semantic change to existing field.
- Additive keys allowed without version bump if optional and zero/empty by default.
- Consumers should ignore unknown keys.

---

### Guardrail Flag Semantics

`guardrail_warn_triggered` and `guardrail_abort_triggered` are **latched** booleans: once set to `true` they do not revert even if the malformed ratio later drops below the configured thresholds. This preserves an audit signal for transient spikes.

### Malformed Ring Buffer Behavior

The `malformed_snapshots` ring has a fixed capacity of 32 entries. After capacity is reached it overwrites the oldest entries in FIFO order. Snapshot capture occurs for the first malformed record and then every `malformed_snapshot_interval`-th malformed record. Overwrite means very early counts (e.g., `1`) may disappear once more than 32 snapshot points have been recorded.

_Document status: Draft (v0.15.x). Submit issues for clarifications / extension proposals._
