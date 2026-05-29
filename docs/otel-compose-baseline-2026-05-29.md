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

## Known gaps surfaced (feed later phases)

1. **No geode-emitted spans (Phase B).** Tracing pipeline live but unused; add lifecycle spans
   (transport.request → query.parse/plan/execute → storage/wal, transactions).
2. **Rich runtime counters are log-only / Prometheus-only, not in OTLP (Phase C).** geode logs a
   large `info: metrics: quic_* proto_reader_* ...` set (cwnd, RTT, poll-phase ns, stream-write
   stats, flow control). These are NOT exported via the OTLP facade. Phase C should wire the
   decision-useful subset into geode-scoped OTLP metrics (covers the "lib internals geode is blind
   to" — QUIC RTT/cwnd/loss in particular).
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
