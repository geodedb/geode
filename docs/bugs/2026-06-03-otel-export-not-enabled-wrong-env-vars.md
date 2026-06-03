# OTel export produced no geode telemetry — wrong env vars on the deployment

**Date:** 2026-06-03
**Status:** Root-caused. Primary fix is a deployment change (geode-argo-arda).
**geode-side DX recommendations 1 & 2 are now RESOLVED (2026-06-03)** — see
*Resolution (geode-side)* below; docs (3 & 4) were already present.
**Scope:** geode server (qa/prod on the arda cluster) OTLP export. Affects metrics
**and** traces. The OTel collector and geode-ui export were verified working.

---

## Resolution (geode-side DX)

The silent failure mode is now visible at startup. `src/monitoring/otel_metrics.zig`
`init()` emits an **unconditional** OTLP export-status line and a targeted warning
when a legacy `GEODE_OTEL_*` var is set (which geode ignores):

- **Disabled** (the bug state): `info: otel: OTLP/HTTP push DISABLED
  (OTEL_METRICS_EXPORTER/OTEL_TRACES_EXPORTER != otlp); metrics available via
  /metrics pull only. To enable: set OTEL_METRICS_EXPORTER=otlp … OTLP/HTTP on
  port 4318, NOT gRPC 4317`.
- **Legacy var set:** `warning: otel: env var GEODE_OTEL_ENDPOINT is set but geode
  IGNORES it — geode reads only the standard OTEL_* SDK vars, not GEODE_OTEL_*. …`
- **Enabled:** `info: otel: OTLP/HTTP push ENABLED (metrics=enabled traces=enabled)
  endpoint=… protocol=http/protobuf; /metrics pull also available`.

The decision logic is a pure, unit-tested classifier (`classifyExportStatus` /
`OtelExportStatus`), regression-covered by `tests/test_otel_export_status.zig`
(incl. the exact "GEODE_OTEL_* set, standard vars unset" misconfiguration). Recs
3 (env contract) and 4 (HTTP-only transport) were already documented in
`docs/OBSERVABILITY_ARCHITECTURE.md` §"Enabling OTLP export". The **deployment**
fix (replace `GEODE_OTEL_*` with the standard `OTEL_*` vars on the geode
StatefulSet) still must be applied in `geode-argo-arda`.

---

## TL;DR

We set up OpenTelemetry export from `geode-qa`, `geode-prod`, and `geode-ui` to
GitLab Observability via an in-cluster OTel Collector. **No geode-server traces or
metrics ever arrived.** Root cause: the geode StatefulSet was configured with
**`GEODE_OTEL_ENDPOINT` / `GEODE_OTEL_INSECURE`**, which **geode does not read**.
geode enables OTLP push only via the **standard OTel SDK env vars**
(`OTEL_METRICS_EXPORTER=otlp`, `OTEL_TRACES_EXPORTER=otlp`,
`OTEL_EXPORTER_OTLP_ENDPOINT=...`). With none of those set, geode's exporters were
never enabled, so it fell back to Prometheus pull / stdout-logged metrics and
pushed nothing. (geode-ui worked precisely because it was given the standard
`OTEL_EXPORTER_OTLP_ENDPOINT`.)

There is also a **protocol/port** detail: geode's OTLP transport is **OTLP/HTTP**
(`std.http.Client`), so the endpoint must be the collector's **HTTP** port (`4318`),
not the gRPC port (`4317`).

---

## What was attempted

Goal: traces + metrics from `geode-qa`, `geode-prod`, `geode-ui` → GitLab
Observability (`https://5333796.otel.gitlab-o11y.com:14318`).

Architecture (GitOps, `geode-argo-arda`):

```
geode-qa  ─┐
geode-prod ─┼─ OTLP ─▶ OTel Collector (ns: observability) ─ OTLP/HTTP ─▶ GitLab o11y
geode-ui  ─┘            (otlphttp/gitlab, Bearer token from Vault)
```

The geode StatefulSet (`manifests/base/geode.yaml`) was configured with:

```yaml
- name: GEODE_OTEL_ENDPOINT
  value: "http://otel-collector.observability.svc.cluster.local:4317"
- name: GEODE_OTEL_INSECURE
  value: "true"
```

## Symptom

geode-ui traces appeared end-to-end, but **no `geode-qa` / `geode-prod` telemetry**
(traces or metrics) ever reached the collector or GitLab. geode logged its metrics
to **stdout** (`info: metrics: …` dumps) instead of pushing them.

---

## Root cause (primary): OTLP export was never enabled

geode reads the **standard OpenTelemetry SDK environment variables**. Per
`docs/OBSERVABILITY_ARCHITECTURE.md`:

> Wiring: `src/monitoring/otel_metrics.zig` (facade), enabled at runtime by
> `OTEL_METRICS_EXPORTER=otlp` / `OTEL_TRACES_EXPORTER=otlp` +
> `OTEL_EXPORTER_OTLP_ENDPOINT`. The std.http.Client OTLP transport is …

Confirmed against the shipped binary — the only OTel-related env vars present are:

```
$ strings $(command -v geode) | grep -iE 'OTEL_|GEODE_OTEL'
OTEL_EXPORTER_OTLP_ENDPOINT
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
OTEL_METRICS_EXPORTER
OTEL_TRACES_EXPORTER
# (no GEODE_OTEL_ENDPOINT, no GEODE_OTEL_INSECURE — geode never reads them)
```

So `GEODE_OTEL_ENDPOINT` / `GEODE_OTEL_INSECURE` are **silently ignored**. Because
`OTEL_METRICS_EXPORTER` / `OTEL_TRACES_EXPORTER` were unset (default not `otlp`),
geode never constructed its OTLP exporters and never pushed anything — it ran
"pull-only" (the `/metrics` Prometheus endpoint from `src/monitoring/metrics_server.zig`)
plus the stdout metrics dump.

This was masked because:

- geode emits no error for "OTLP not enabled" — it just doesn't export.
- geode-ui (Go) was given the **correct** `OTEL_EXPORTER_OTLP_ENDPOINT`, so its
  traces flowed and looked like "OTel works," hiding that geode itself was silent.

## Root cause (secondary): wrong port for OTLP/HTTP

geode's OTLP transport is **OTLP/HTTP** (`std.http.Client`). The deployment pointed
at `:4317` — the collector's **gRPC** receiver. Even once the exporters are enabled,
the endpoint must be the collector's **HTTP** port:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318
```

(An `http://` scheme is plaintext, which is what we want for an in-cluster collector;
geode has no separate "insecure" flag — the scheme governs TLS.)

---

## What WAS verified working (so the fix is isolated to geode's env)

These were proven during debugging, so the collector and GitLab side are sound:

- **GitLab accepts OTLP** — a direct probe to `…:14318/v1/traces` returned
  `HTTP 200 {"partialSuccess":{}}` (both `Authorization: Bearer <token>` and
  `PRIVATE-TOKEN: <token>` accepted).
- **Collector → GitLab leg delivers** — collector self-metrics
  (`service.telemetry.metrics.level: detailed`):
  `otelcol_receiver_accepted_spans = 5` → `otelcol_exporter_sent_spans{exporter="otlphttp/gitlab"} = 5`
  → `otelcol_exporter_send_failed_spans = 0`.
- **geode-ui traces flow** — the only `service.name` the collector ever received
  was `geode-ui`; after a `:4318` fix + restart + 10 real geode-qa queries, **zero**
  geode spans/metrics arrived. This is consistent with the exporters being disabled.

---

## The fix (deployment — geode-argo-arda)

Replace the non-standard vars on the geode StatefulSet with the standard OTel SDK
vars:

```yaml
env:
  # enable the OTLP push exporters (was: not set -> exporters never built)
  - name: OTEL_METRICS_EXPORTER
    value: "otlp"
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
  # OTLP/HTTP to the collector's HTTP port (4318), http:// = plaintext
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.observability.svc.cluster.local:4318"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  # nice-to-have: distinguish qa/prod in the resource
  - name: OTEL_SERVICE_NAME
    value: "geode"            # set per-overlay if desired
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment.name=qa"   # or prod, per overlay
# REMOVE: GEODE_OTEL_ENDPOINT, GEODE_OTEL_INSECURE  (geode ignores them)
```

NetworkPolicy: geode egress must allow the collector namespace on **4318/TCP**
(the `observability` egress rule already allowed 4317+4318).

Note: geode traces are activity-driven — `geode.query.execute` SERVER spans fire per
statement (`docs/OBSERVABILITY_ARCHITECTURE.md` §Traces). Idle clusters produce no
spans; generate query traffic to see traces.

---

## Recommendations for geode-server (DX — optional)

The failure was silent and easy to misconfigure. Consider:

1. **Log OTLP export status at startup**, unconditionally and actionably, e.g.:
   - enabled: `otel: OTLP push enabled exporter=otlp endpoint=… protocol=http`
   - disabled: `otel: OTLP push disabled (OTEL_METRICS_EXPORTER/OTEL_TRACES_EXPORTER != otlp); metrics available via /metrics pull only`
   - failed: include the underlying error in the existing
     `OTLP/HTTP push wiring failed (…); falling back to pull-only` line (the
     parenthesised error was empty in our logs).
2. **Reject/ warn on `GEODE_OTEL_*`** — `GEODE_OTEL_ENDPOINT` is a natural guess
   (geode uses `GEODE_*` elsewhere) but is ignored. Either alias it to the standard
   var or emit a startup warning when a `GEODE_OTEL_*` var is set but the standard
   one is not.
3. **Document the canonical env contract prominently** (it lives in
   `OBSERVABILITY_ARCHITECTURE.md`, but a deployer reached for `GEODE_OTEL_*`).
   A short "Enabling OTLP export" section in `docs/TELEMETRY.md` or the deployment
   docs, naming `OTEL_METRICS_EXPORTER=otlp` + `OTEL_TRACES_EXPORTER=otlp` +
   `OTEL_EXPORTER_OTLP_ENDPOINT` (HTTP port) would prevent recurrence.
4. **Note the HTTP-only transport** — geode uses `std.http.Client` (OTLP/HTTP), so
   operators must use the collector's 4318 (HTTP), not 4317 (gRPC). Worth stating
   next to the endpoint var.

---

## Reproduction / verification

```bash
# 1) Confirm geode ignores GEODE_OTEL_* and reads OTEL_*:
strings $(command -v geode) | grep -iE 'OTEL_|GEODE_OTEL'

# 2) Confirm GitLab accepts OTLP (token from Vault codepros/geode-otel):
#    POST a minimal OTLP/HTTP JSON trace to …:14318/v1/traces -> expect HTTP 200.

# 3) On the collector, enable visibility to see arrivals:
#    service.telemetry.metrics.level: detailed  (exposes :8888)
#    + a `debug` exporter on the traces/metrics pipelines.
#    Then read otelcol_receiver_accepted_{spans,metric_points} and
#    otelcol_exporter_sent_* / send_failed_* — geode service.name should appear
#    only AFTER the env fix above.
```

## References

- `docs/OBSERVABILITY_ARCHITECTURE.md` — geode OTel scope, enablement env vars,
  metrics/traces inventory, `src/monitoring/otel_metrics.zig`.
- `docs/otel-updates.md` — geode OTel metrics spec v1.0 (names, resource attrs).
- `docs/otel-compose-baseline-2026-05-29.md` — working compose baseline.
- Deployment side: `geode-argo-arda` `manifests/base/geode.yaml` (env),
  `manifests/otel-collector/` (collector), Vault `codepros/geode-otel` (GitLab token).
- Companion arda note: `geode-argo-arda/docs/GEODE-CLUSTER-BUGS.md`.
