# Geode Observability Architecture (2026-05-29)

How geode is instrumented with OpenTelemetry — the sustainable design and what is/isn't exported.

## Principle: geode owns all instrumentation; dependent libraries' otel is OFF

Every dependency in `~/src/devnw/zig/*` (and `geode-client-zig`) ships an `observability` seam that is
**hardcoded `pub const enabled = false`** (since 2026-05-02, to dodge a Zig 0.16 module-dedup diamond).
geode passes **no** `-Dwith_otel`/observability flag to any dependency — verified: the only `with_otel`
mentions in `build.zig` are removal comments. **Result: dependent-lib otel adds zero runtime overhead.**

This means lib-internal spans/metrics (wal, gql, dns, vulkan, thread_pool, repl seams) do **NOT** fire.
Instead, **geode emits its own metrics and spans**, and bridges the lib-internal runtime data it needs
out of the libraries via public getters into geode-scoped metrics. This is the perf-safe way to get the
full performance landscape without enabling per-lib otel.

> The otel lib's BatchSpanProcessor span-reuse UAF is fixed on branch `fix/bsp-span-reuse-uaf`
> (`9fa2e97`, atomic span end-claim) but **not pinned** — bumping otel forces an ~18-lib convergence
> cascade for seams that are off anyway. geode mitigates the UAF at its own boundary (exactly-once
> `end()` in the `GeodeSpan` facade). Pin `9fa2e97`+ at the next ecosystem-wide otel convergence.

## What geode exports (OTLP/HTTP → collector, + Prometheus `/metrics`)

Scope: `com.geodedb.geode` (schema `https://schemas.geodedb.com/otel/geode/metrics/1.0.0`).
Wiring: `src/monitoring/otel_metrics.zig` (facade), enabled at runtime by `OTEL_METRICS_EXPORTER=otlp`
/ `OTEL_TRACES_EXPORTER=otlp` + `OTEL_EXPORTER_OTLP_ENDPOINT`. The std.http.Client OTLP transport is
compiled in by default (`-Dotel_use_devnw_tls`, default true in geode/build.zig).

### Enabling OTLP export (operator quick-reference)

geode reads the **standard OTel SDK env vars** — confirmed in the binary:
`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_{METRICS,TRACES}_ENDPOINT`,
`OTEL_METRICS_EXPORTER`, `OTEL_TRACES_EXPORTER`. There is **no `GEODE_OTEL_*`**
variable — setting `GEODE_OTEL_ENDPOINT`/`GEODE_OTEL_INSECURE` does nothing and
leaves geode pull-only. Transport is **OTLP/HTTP** (`std.http.Client`), so the
endpoint must be the collector's **HTTP** port, not gRPC.

```bash
OTEL_METRICS_EXPORTER=otlp
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=http://<collector-host>:4318   # HTTP port; http:// = plaintext
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf                  # geode is HTTP-only
# optional: OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=<env>
```

The geode-test-harness's `make otel-*` targets / `GEODE_OTEL=1` source exactly
these `OTEL_*` vars (see `reports/.otel-env`). A 2026-06-03 arda deployment used
`GEODE_OTEL_*` instead and exported nothing — see
`docs/bugs/2026-06-03-otel-export-not-enabled-wrong-env-vars.md`.

### Metrics

- **Server / query / transport / storage / WAL / index / transactions** — `geode.server.*`,
  `geode.query.*` (count/active/execution.duration/parse.duration/rows.returned),
  `geode.transport.*` (connection/request.duration/inflight/bytes), `geode.storage.*`, `geode.wal.*`,
  `geode.index.*`, `geode.transaction.*`.
- **Security** — `geode.security.authorization.check.*` (RBAC), `geode.security.rls.evaluation.*`
  (when a compiled RLS policy is active), `geode.audit.*` (when an audit append routes through the
  security graph).
- **Runtime bridge (`geode.runtime.*`)** — 76 observable gauges bridging the process-global
  `runtime_metrics.Registry`: QUIC RTT/cwnd/bytes-in-flight, 20 poll-phase timings, 13 stream-write
  counters, 24 first-stream phase metrics, proto-reader, leaked-conn reaper. These are the
  "lib-internal" QUIC stats geode reads from the transport and republishes (the libs themselves stay
  off). Wired by `otel_metrics.registerRuntimeMetricsOtel` at startup.

### Traces

- `geode.query.execute` SERVER span per statement (bounded attrs: `db.operation.name`,
  `db.namespace`, `geode.query.is_mutation`, `geode.result.row_count`, `error.type`). Thread-safe
  `GeodeSpan` facade (exactly-once `end()` + `g_span_mu`-guarded id-gen). A geode-side periodic flush
  loop drains the BatchSpanProcessor (the no-pool BSP has no timer).
- Cross-process trace propagation (client `traceparent`) is deferred — the `ExecuteRequest` wire
  format has no trace-context field. geode roots a new trace per request for now.

## Not currently trackable (honest deferrals)

- **Transaction timeout / lock-wait** — single-tenant `manager.zig` has no txn-deadline logic and
  `acquireLock` is non-blocking (no wait duration to measure). No real detection point to instrument.
- **Query plan span/metric** — no separable plan-phase boundary in the current execution path.
- **TDE/KMS, resource-count gauges (node/edge/index/storage/wal)** — no clean call site / no-arg
  provider; deferred until those exist.
- **Distributed / cluster / CDC / analytics** — inactive in single-tenant default (`GEODE_CLUSTER_TOKEN`
  unset) or subsystem absent.
- **QUIC TLS handshake / per-timeout** — the vendored QUIC library exposes no callback.

## Verify locally

`make otel-compose-up && make otel-compose-verify` (or `REQUIRE_SPANS=1 scripts/otel-compose-verify.sh`)
brings up geode + an OpenTelemetry collector and asserts geode's metrics and spans land. Baseline +
captured metric inventory: `docs/otel-compose-baseline-2026-05-29.md`.
