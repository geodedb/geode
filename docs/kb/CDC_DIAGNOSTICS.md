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
- Guardrail lifecycle epoch (`guardrail_epoch`) + remote reset via `CDC_CONTROL`.
- Engine uptime metric (`uptime_ms`).
- Backpressure telemetry: boolean `backpressure` + watermark echo `pending_backpressure_watermark`.

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
  "uptime_ms": 5234,
  "malformed_wal_records": 3,
  "total_wal_attempts": 57,
  "malformed_ratio": 0.0526,
  "guardrail_warn_triggered": false,
  "guardrail_abort_triggered": false,
  "guardrail_epoch": 2,
  "backpressure": false,
  "config": {
    "enabled": true,
    "warn_pct": 0.05,
    "abort_pct": 0.1,
    "snapshot_interval": 8,
    "hash_retain": 16,
    "adaptive_flush": true,
    "batch_size": 64,
    "pending_backpressure_watermark": 4096
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

| Field                                   | Type  | Description                                                               |
| --------------------------------------- | ----- | ------------------------------------------------------------------------- |
| `version`                               | int   | Schema version for diagnostics payload.                                   |
| `timestamp_ms`                          | int   | Epoch ms when snapshot generated.                                         |
| `uptime_ms`                             | int   | Engine uptime since initialization.                                       |
| `malformed_wal_records`                 | int   | Count of malformed WAL decode attempts.                                   |
| `total_wal_attempts`                    | int   | Total WAL decode attempts (good + malformed).                             |
| `malformed_ratio`                       | float | malformed / total (0 if total == 0).                                      |
| `guardrail_warn_triggered`              | bool  | Latched true once malformed ratio >= warn threshold.                      |
| `guardrail_abort_triggered`             | bool  | Latched true once malformed ratio >= abort threshold.                     |
| `first_warn_ts_ms`                      | int   | Epoch ms when warn threshold first triggered (0 if never).                |
| `first_abort_ts_ms`                     | int   | Epoch ms when abort threshold first triggered (0 if never).               |
| `guardrail_epoch`                       | int   | Incremented each time guardrails are reset (lifecycle epochs).            |
| `backpressure`                          | bool  | True when pending events exceed watermark and producer should slow/flush. |
| `config.enabled`                        | bool  | Whether CDC capture active.                                               |
| `config.warn_pct`                       | float | Guardrail warn threshold.                                                 |
| `config.abort_pct`                      | float | Guardrail abort threshold.                                                |
| `config.snapshot_interval`              | int   | Interval (events) for malformed snapshot capture.                         |
| `config.hash_retain`                    | int   | Max retained malformed prefix/hash pairs.                                 |
| `config.adaptive_flush`                 | bool  | Adaptive flush enabled.                                                   |
| `config.batch_size`                     | int   | Current static batch size (if adaptive off).                              |
| `config.pending_backpressure_watermark` | int   | Pending events threshold that sets `backpressure`.                        |
| `engine.pending_events`                 | int   | Events buffered but not flushed.                                          |
| `engine.peak_buffer`                    | int   | High water mark of buffered events.                                       |
| `engine.dynamic_batch_size`             | int   | Current adaptive batch size (if enabled).                                 |
| `engine.batch_adjustments`              | int   | Number of adaptive tuning adjustments.                                    |
| `malformed_snapshots[]`                 | array | Historical malformed counts with timestamps.                              |
| `malformed_prefix_hashes[]`             | array | Array of prefix/hash objects for retained malformed payloads.             |

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

### CDC_CONTROL Frame

Administrative control frames allow remote lifecycle operations.

#### Request (client → server)

```json
{ "type": "CDC_CONTROL", "action": "RESET_GUARDRAILS" }
```

Supported `action` values (v0.15.x):

| Action             | Effect                                                         |
| ------------------ | -------------------------------------------------------------- |
| `RESET_GUARDRAILS` | Invokes `resetGuardrailState()`, increments `guardrail_epoch`. |

#### Response (server → client)

```json
{
  "status_class": "00000",
  "result": {
    "type": "CDC_CONTROL",
    "action": "RESET_GUARDRAILS",
    "status": "OK",
    "guardrail_epoch": 3
  }
}
```

`status` values:

| Status        | Meaning                                      |
| ------------- | -------------------------------------------- |
| `OK`          | Action applied.                              |
| `UNSUPPORTED` | Action string recognized as invalid/unknown. |
| `NO_ENGINE`   | CDC engine disabled / not initialized.       |

Additional response examples:

Unsupported action example:

```json
{
  "status_class": "00000",
  "result": {
    "type": "CDC_CONTROL",
    "action": "FOO_BAR",
    "status": "UNSUPPORTED",
    "guardrail_epoch": 3
  }
}
```

Engine disabled example:

```json
{
  "status_class": "00000",
  "result": {
    "type": "CDC_CONTROL",
    "action": "RESET_GUARDRAILS",
    "status": "NO_ENGINE",
    "guardrail_epoch": 0
  }
}
```

Clients SHOULD follow with a `CDC_DIAGNOSTICS` request to observe the updated epoch and cleared guardrail latches.

Malformed / Missing Action Handling:

- If the `action` field is omitted, the server treats it as an empty string `""` and returns `status":"UNSUPPORTED"` (no epoch change).
- Non-string `action` values still produce a generic parse rejection (frame ignored) because the protocol parser enforces string typing.

CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCControlProtocolMalformed; STATUS=TESTED; TEST=protocol_CDC_CONTROL_malformed_missing_action; UPDATED=2025-09-20

### Guardrail Flag Semantics

`guardrail_warn_triggered` and `guardrail_abort_triggered` are **latched** booleans: once set to `true` they do not revert even if the malformed ratio later drops below the configured thresholds. This preserves an audit signal for transient spikes. They can only be cleared explicitly via the `resetGuardrailState()` engine API.

`first_warn_ts_ms` and `first_abort_ts_ms` capture the **first trigger time** (epoch ms) for each guardrail. They remain `0` until the respective threshold is crossed. These timestamps are also latched and only return to `0` when `resetGuardrailState()` is invoked; after reset, subsequent threshold crossings set new (monotonically increasing) timestamps. A monotonic relation holds when both thresholds fire: `first_warn_ts_ms <= first_abort_ts_ms`.

`guardrail_epoch` increments each time a reset occurs, allowing consumers to correlate post-reset diagnostics without losing cumulative malformed counts.

#### Guardrail Reset API

The method `CDCEngine.resetGuardrailState()` clears:

- `guardrail_warn_triggered`
- `guardrail_abort_triggered`
- `first_warn_ts_ms`
- `first_abort_ts_ms`

It does **not** modify underlying counters (`malformed_wal_records`, `total_wal_attempts`) so post-reset ratios still reflect full historical counts. This design allows distinguishing between _lifecycle epochs_ of guardrail monitoring while retaining forensic totals. Consumers performing periodic health checks can reset after remediation to re-arm alerting without losing aggregate history.

### Backpressure Semantics

The `backpressure` flag surfaces a **binary coarse signal** for producers.

Trigger condition:

```text
backpressure = (pending_events >= pending_backpressure_watermark)
```

Where:

- `pending_events` = buffered events not yet flushed to sink / file.
- `pending_backpressure_watermark` = configured integer threshold (see `config.pending_backpressure_watermark`).

Behavioral notes:

- Evaluation occurs at diagnostics export time; intermediate toggling between exports is not tracked.
- No hysteresis is implemented yet; crossing the threshold repeatedly may cause rapid flip-flop if the buffer hovers near the watermark. (Future: introduce separate high/low watermarks.)
- Flag is advisory only; application-level flow control or sink backpressure protocols are not yet integrated.
- When `backpressure` is `true`, a client **SHOULD** pause high-rate mutation operations or force a flush (future API) to reduce `pending_events`.
- The watermark value is echoed for transparency and capacity planning.

Troubleshooting:

| Symptom                          | Possible Cause                             | Mitigation                                             |
| -------------------------------- | ------------------------------------------ | ------------------------------------------------------ |
| `backpressure` stays true        | Flush throughput too low / watermark small | Increase batch size or watermark; optimize sink I/O.   |
| Frequent toggling near threshold | Lack of hysteresis                         | Raise watermark pending future dual threshold support. |
| Always false even under load     | Watermark very high or capture disabled    | Lower watermark or verify `GEODE_CDC_ENABLE` is set.   |

### Malformed Ring Buffer Behavior

The `malformed_snapshots` ring has a fixed capacity of 32 entries. After capacity is reached it overwrites the oldest entries in FIFO order. Snapshot capture occurs for the first malformed record and then every `malformed_snapshot_interval`-th malformed record. Overwrite means very early counts (e.g., `1`) may disappear once more than 32 snapshot points have been recorded.

_Document status: Draft (v0.15.x). Submit issues for clarifications / extension proposals._
