# OTel docker-compose telemetry baseline (2026-05-29)

Empirical baseline of what geode emits through the self-contained docker-compose otel stack
(`docker-compose.otel.yml` + `config/otel-collector.yaml`), captured after fixing the OTLP/HTTP
transport (commit `7ce6e0d9`). This is the Phase A acceptance evidence and the reference point for
Phases B–F.

## Stack under test

- Collector: `otel/opentelemetry-collector-contrib:0.96.0`, OTLP http(4318)+grpc(4317) →
  `debug` (stdout) + `file` exporters (`/var/log/otel/{traces,metrics,logs}.jsonl`).
- geode: built on host (`zig build -Doptimize=ReleaseSafe`, otel transport now compiled in by
  default), packaged via `Dockerfile.prebuilt` into `debian:bookworm-slim`.
- geode otel env: `OTEL_METRICS_EXPORTER=otlp`, `OTEL_TRACES_EXPORTER=otlp`,
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`,
  `OTEL_METRIC_EXPORT_INTERVAL=3000`, `OTEL_TRACES_SAMPLER=always_on`.
- Prometheus pull: `GEODE_METRICS_PORT=9091` + `GEODE_METRICS_BIND=0.0.0.0` → `host:9091/metrics`.
- Run: `scripts/otel-compose-verify.sh` (queries run inside the geode container; QUIC published on
  host 13141 to coexist with a host `geode.service`).

## Result: PASS (metrics), spans absent (expected pre-Phase-B)

`scripts/otel-compose-verify.sh` → `PASS: geode metrics reached the collector (spans required=0, seen=0)`.

### OTLP push → collector: metric families observed (debug exporter, `service.name=geode`)

| Metric | Kind | Notes |
|---|---|---|
| `geode.server.uptime` | gauge | observable |
| `geode.server.health` | gauge | per `geode.component` |
| `geode.query.count` | counter | per `geode.result.outcome`, `geode.query.type` |
| `geode.query.active` | up-down counter | |
| `geode.query.execution.duration` | histogram | seconds |
| `geode.transport.connection.opened` | counter | per `geode.transport.protocol` (quic) |
| `geode.transport.connection.closed` | counter | per `geode.close.reason` |
| `geode.transport.connection.count` | gauge | observable, per protocol |
| `geode.transport.request.duration` | histogram | per `db.operation.name`, `geode.result.outcome` |
| `geode.transport.request.inflight` | up-down counter | |
| `geode.transport.bytes` | counter | transmit/receive |
| `geode.node.role` (resource attr) | — | standalone |

(Resource attributes confirmed: `service.name=geode`, `service.namespace=codepros`,
`deployment.environment.name=docker-compose`.)

### Prometheus pull → `host:9091/metrics`

`HTTP/1.1 200 OK`, `Content-Type: text/plain; version=0.0.4`, ~15.8 KB, **150 non-comment metric
lines**. Sample:

```
# TYPE geode_server_uptime gauge
geode_server_uptime 9.004769387
# TYPE geode_transport_connection_opened counter
geode_transport_connection_opened{geode_transport_protocol="quic"} 5
# TYPE geode_transport_request_duration histogram
geode_transport_request_duration_count{db_operation_name="QUERY",geode_result_outcome="success"} 5
geode_transport_request_duration_bucket{...,le="0.0005"} 3
...
```

### Traces: NONE (Phase A) → `geode.query.execute` spans land (Phase B)

**Phase A baseline:** `traces.jsonl` empty; `span-indicator lines: 0` — geode emitted no spans.

**Phase B update (2026-05-29):** geode now emits a `geode.query.execute` SERVER span per statement
(scope `com.geodedb.geode`), via a thread-safe `GeodeSpan` facade (exactly-once `end()` + a facade
mutex around the non-thread-safe id-generator). `REQUIRE_SPANS=1 scripts/otel-compose-verify.sh`
PASSES (`span-indicator lines: 9`). A geode-side periodic flush loop drains the BatchSpanProcessor
on the BSP schedule cadence (the no-pool BSP has no timer of its own). Concurrent-load smoke: 240
concurrent queries → geode `running exitcode=0`, no SIGABRT/panic/UAF, spans keep flowing — the
prior concurrent-span crash is resolved at the geode boundary. Bounded attributes only
(`db.operation.name`, `db.namespace`, `geode.query.is_mutation`, `geode.result.row_count`,
`error.type`). Child spans (parse/plan/storage/wal) + cross-process propagation are Phase B
Increment 2 / later.

### Phase C1 update (2026-05-29): runtime-metrics registry → OTLP (`geode.runtime.*`)

The rich runtime counters that were previously **log-only / Prometheus-only** (gap #2 below) now
reach the collector via OTLP. `otel_metrics.registerRuntimeMetricsOtel(registry)` bridges every entry
of the process-global `runtime_metrics.Registry` into a `geode.runtime.<original_name>` OTel
observable gauge, wired at server startup right after the registry is fully populated
(`src/server/main.zig`, after `quic_response_metrics.registerAll`). Each gauge is backed by a heap
`RuntimeBridge` that reads the source atomic / registry callback at OTel collection time. No
per-connection/user labels (cardinality-safe).

`scripts/otel-compose-verify.sh` → `PASS: geode metrics reached the collector (spans required=0,
seen=9)`. **76 distinct `geode.runtime.*` metric names** landed in the collector debug exporter
(`service.name=geode`). Captured families and sample names:

| Family | Count | Sample names |
|---|---|---|
| `geode.runtime.proto_reader_*` | 5 | `proto_reader_idle_ns`, `proto_reader_messages_delivered_total`, `proto_reader_bytes_read_total`, `proto_reader_eof_total`, `proto_reader_would_block_loop_iterations_total` |
| `geode.runtime.quic_*` connection/cwnd/RTT | — | `quic_active_connections`, `quic_total_bytes_in_flight`, `quic_total_cwnd_bytes`, `quic_min_smoothed_rtt_ns`, `quic_max_smoothed_rtt_ns`, `quic_min_flow_control_headroom` |
| `geode.runtime.quic_poll_*` poll-phase ns | 20 | `quic_poll_cycle_max_ns`, `quic_poll_transport_max_ns`, `quic_poll_recv_process_max_ns`, `quic_poll_recv_short_*_max_ns`, `quic_poll_timer_process_max_ns`, `quic_poll_pto_dirty_max_ns`, `quic_poll_overrun_total` |
| `geode.runtime.quic_stream_write_*` | 13 | `quic_stream_write_calls_total`, `quic_stream_write_success_total`, `quic_stream_write_bytes_written_total`, `quic_stream_write_elapsed_max_ns`, `quic_stream_write_would_block_total`, `quic_stream_write_flow_blocked_total` |
| `geode.runtime.quic_first_stream_*` | 24 | `quic_first_stream_query_execute_ns_total`, `quic_first_stream_ready_queue_wait_max_ns`, `quic_first_stream_response_send_ns_total`, `quic_first_stream_packets_completed_total` |
| `geode.runtime.quic_response_*` | 5 | `quic_response_messages_completed_total`, `quic_response_batches_completed_total`, `quic_response_encode_bytes_total` |
| `geode.runtime.quic_leaked_connections_*` / stream-handler / idle | — | `quic_leaked_connections_pending`, `quic_leaked_connections_reaped_total`, `quic_pending_stream_handlers`, `quic_max_stream_handlers`, `quic_stream_admission_rejections_total`, `quic_max_stream_idle_ns` |

Sample raw emit (from the geode `info: metrics:` line that backs these gauges, one collection):
`quic_response_messages_completed_total=3 quic_stream_write_calls_total=3 quic_stream_write_bytes_written_total=159 quic_poll_cycle_max_ns=17485912 quic_total_cwnd_bytes=0 quic_min_smoothed_rtt_ns=0 quic_max_stream_handlers=1024 proto_reader_idle_ns=14885451447`.

Bridge ctxs + name strings are process-lifetime (allocated on the provider allocator, tracked in
`g_runtime_bridges`, freed only in `shutdown()` after the provider is torn down). Regression cover:
`tests/test_otel_runtime_bridge.zig` (`zig build test-otel-runtime-bridge`) asserts a counter=7 and a
gauge=42 surface as `geode_runtime_*` with those values through the real Prometheus collect path, plus
a no-op-when-inactive case. This closes gap #2 below for the QUIC/proto-reader runtime counter set.

## Known gaps surfaced (feed later phases)

1. **No geode-emitted spans (Phase B).** Tracing pipeline live but unused; add lifecycle spans
   (transport.request → query.parse/plan/execute → storage/wal, transactions).
2. ~~**Rich runtime counters are log-only / Prometheus-only, not in OTLP (Phase C).**~~ **CLOSED by
   Phase C1 (2026-05-29)** — see the Phase C1 update above. The full `quic_* proto_reader_*` registry
   (cwnd, RTT, poll-phase ns, stream-write stats, flow control; 76 series) now exports via OTLP as
   `geode.runtime.*` observable gauges.
3. **Unwired P1 facade metrics (Phase C).** planner/optimizer, auth/RLS decisions, query/path cache,
   MVCC/deadlock, group-commit, vector/GPU, materialized views, shard-level, distributed/raft.

## How the foundational bug was found

Phase A's verify was initially BLOCKED: geode logged "OTLP/HTTP push enabled" but delivered nothing.
Root cause: the otel lib gates the real `std.http.Client` transport behind `build_options.use_devnw_tls`
(`otel/src/exporters/otlp_http/transport.zig:139`), and geode discarded the `otel_use_devnw_tls`
build option instead of forwarding it. Fixed (commit `7ce6e0d9`) by forwarding the flag (default on)
to the otel dependency. Proof: `/tmp/otel_repro.sh` went from `total_connections=0` to `total_connections=9`
with `POST /v1/metrics`. Regression guard: `tests/test_otel_otlp_transport_delivery.zig`
(`zig build test-otel-otlp-transport`).
