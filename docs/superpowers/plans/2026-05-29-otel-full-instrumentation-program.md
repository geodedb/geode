# OTel Full-Instrumentation Program (2026-05-29)

**North star:** Fully instrument geode with OpenTelemetry *properly and sustainably*. Dependent
libraries (`~/src/devnw/zig/*`, `../geode-client-zig`) keep their otel **off** (zero runtime
overhead) while geode's **own** instrumentation measures the full performance landscape. Prove it
end-to-end in a docker-compose system with an OTel collector that captures every metric and span
geode can emit. Update the otel lib via `/gap:close` for genuinely missing implementation; fix bugs
via `/bug:fix`. Plan with `/writing-plans` and execute with `/subagent-driven-development`,
iteratively, one phase at a time.

This document is the program-level anchor. Each phase gets its own plan doc and execution pass.

---

## Evidence baseline (discovery 2026-05-29)

- **otel lib** `v0.1.5` @ `455ad2b8` (geode + geode-client-zig pins match local HEAD, zero drift).
  Production-ready for OTLP/HTTP push + Prometheus pull. Traces/metrics/logs API complete; W3C/B3/
  Jaeger propagators; samplers; `PeriodicExportingMetricReader`; comptime `otel_disabled` no-op flag.
  Remaining real gaps are gRPC-only (geode uses HTTP) plus **PR-4: new `std.http.Client` per export,
  no keepalive** (perf, relevant for sustained production push).
- **Cross-lib gating:** `-Dwith_otel` flag (default false) exists ecosystem-wide, but most libs
  **hardcode `enabled=false`** in `observability.zig` since 2026-05-02 to dodge a Zig 0.16
  module-dedup diamond bug; thread-pool dropped otel entirely; quic has no seam. So **lib otel is
  already off** — the perf half of the goal is de-facto satisfied; we make it explicit, tested,
  documented. `detect_diamond_deps.py` guards the dedup crash.
- **geode instrumentation:** Metrics comprehensive + wired via `@import("otel_metrics").recordX(...)`
  (`src/monitoring/otel_metrics.zig`, ~2788 lines). OTLP/HTTP push + Prometheus `/metrics` both work.
  Gaps:
  1. **geode emits ZERO spans of its own** — `tracer()` facade is real (otel_metrics.zig:499) but has
     no call sites. No distributed tracing.
  2. **Unwired P1 metrics:** planner/optimizer, auth/RLS decisions, distributed/raft, query/path
     cache, MVCC/deadlock, group-commit, vector/GPU, materialized views, shard-level.
  3. **Blind to lib internals** geode can't self-report: quic RTT/cwnd/loss, dns cache, raft
     election, thread-pool queue depth, page-cache hit rate.
  - `src/monitoring/tracing.zig` is a **dead homegrown tracer (zero usages)** — ignore/retire it.
- **Collector/docker:** harness has `scripts/otel-collector.sh` (collector `0.96.0`), but geode's 6
  docker-compose files have **no otel integration**. geode reads `OTEL_*` env at runtime
  (`OTEL_EXPORTER_OTLP_ENDPOINT` default `http://localhost:4318`, `OTEL_TRACES_EXPORTER`,
  `OTEL_METRICS_EXPORTER`, intervals, BSP, sampler, resource attrs); init is idempotent + non-fatal.
- **Toolchain:** Zig 0.16.0, Docker 29.5.2, Compose v5.1.4. Dockerfile + Dockerfile.prebuilt present.

Authoritative metric spec lives in `docs/otel-updates.md`; deferred P1 list in
`docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md`.

---

## Phases (each = one `/writing-plans` + `/subagent-driven-development` iteration)

### Phase A — docker-compose + collector + verification harness  **(START HERE)**
Self-contained `docker-compose.otel.yml` + `config/otel-collector.yaml` + a verification script that
asserts metrics **and** spans with `service.name=geode` land in the collector. Establish the
**empirical baseline**: what actually lands today (expected: P0 metrics yes, spans no). New files
only; no geode source changes. This is the feedback loop for every later phase.

### Phase B — geode-emitted tracing (the biggest gap)
Add a thin geode span facade over `otel_metrics.tracer()` and wire spans across the request
lifecycle: `transport.request` → `query.parse` → `query.plan` → `query.execute` → storage/wal, plus
transaction spans. Honor parent context from the client (`traceparent`). Cardinality-guarded
attributes (hash query text, no raw URIs). Verify spans land in Phase A's collector.

### Phase C — wire all trackable metrics + pull lib-internal stats
Wire the unwired P1 facade functions to real call sites (planner, auth/RLS, cache, MVCC/deadlock,
group-commit, vector/GPU, materialized views, shard, distributed/raft where active). Pull
lib-internal stats geode is blind to (quic RTT/cwnd/loss, dns cache, thread-pool queue depth,
page-cache hit rate) via public getters and emit as geode-scoped metrics. "All metrics that *can* be
tracked are tracked."

### Phase D — otel lib gaps + bugs (only where they block sustainable production)
Via `/gap:close`: **PR-4 HTTP keepalive** (avoid per-export TCP+TLS handshake on the push path).
Consider histogram binary-search (P0-7) if measurable. Via `/bug:fix`: any defect surfaced while
wiring/verifying. gRPC gaps are out of scope (geode uses HTTP).

### Phase E — disabled-lib contract hardening + sustainability
Verify `observability_disabled_test.zig` passes for every geode dep; confirm geode never enables a
lib seam; add/refresh CANARY markers; document the architecture (geode-owns-instrumentation,
libs-off); correct CLAUDE.md/docs overclaims about lib scopes firing.

### Phase F — full validation + overhead measurement + finalize
Run the suite under the docker-compose collector; confirm every metric family + span lands; measure
otel-on vs otel-off overhead against the loadtest baseline; finalize docs and commit/push per phase.

---

## Phase B prerequisite: the BSP span-reuse UAF (resolved 2026-05-29)

Discovery for Phase B surfaced a **hard blocker**: the otel `BatchSpanProcessor` has a span-reuse
UAF (`otel docs/BUG_BSP_SPAN_REUSE_UAF.md`) — a non-atomic `SpanState.ended` lets two threads ending
the same span both enqueue it → double-recycle → UAF (crashed geode under concurrent QUIC load;
this is why an earlier execute-span attempt was rolled back at `execution.zig:1074`).

- **Fixed in the otel lib** via `/bug:fix` (TDD, atomic end-claim) on branch `fix/bsp-span-reuse-uaf`
  (commit `9fa2e97af5f9ee527db20dcf09847a0589cdd6df`, pushed). Regression test
  `otel/test/bsp_span_reuse_race.zig`; full otel suite + TSan green.
- **NOT pinned into geode.** Bumping geode's otel pin forces a ~18-lib ecosystem convergence (every
  sibling lib declares `otel@455ad2b8` for its hardcoded-OFF observability seam — `detect_diamond_deps`
  flags the mismatch). That is ~36 cross-repo pushes for zero functional change.
- **Geode mitigation (Phase B):** geode's span facade enforces **exactly-once `end()`** per span (a
  per-span atomic guard in the geode wrapper). Since the UAF requires a concurrent *double-end* of the
  same span, exactly-once end() at the geode boundary means otel's `end()` is invoked once → single
  enqueue → `exportBatch` is sole owner → no double-recycle. This makes geode safe on the converged
  `455ad2b8` pin. Pin to `9fa2e97`+ at the next ecosystem-wide otel convergence (defense-in-depth).

## Guardrails
- **Never enable a dependent lib's otel** — it fights the Zig dedup bug and the perf goal.
- **No new perf overhead when telemetry is disabled** (`OTEL_*_EXPORTER` unset → noop tracer/pull-only).
- Cardinality discipline: no unbounded attributes (URIs, raw query text, user-supplied keys); hash where needed.
- Run `detect_diamond_deps.py` before bumping any pin; keep otel pin converged across geode + geode-client-zig.
- TDD per `/subagent-driven-development`; verify against the live collector, not just unit tests.
- Pull all dependent libs to latest before edits (done 2026-05-29).

## Status log
- 2026-05-29: Discovery complete; program doc created.
- 2026-05-29: **Phase A COMPLETE.** docker-compose.otel.yml + config/otel-collector.yaml +
  scripts/otel-compose-verify.sh + Makefile `otel-compose-*` + baseline doc. **Found & fixed a
  critical foundational bug via `/bug:fix` (commit `7ce6e0d9`):** geode discarded the
  `otel_use_devnw_tls` build option, so the otel lib's std.http.Client transport was compiled out
  and *every* OTLP export silently no-op'd (geode opened zero sockets). Now forwarded to the otel
  dep (default on). Proof: `/tmp/otel_repro.sh` 0→9 connections w/ `POST /v1/metrics`; compose verify
  PASSES (geode.* metrics in collector); Prometheus `/metrics` serves 150 lines. Regression guard
  `tests/test_otel_otlp_transport_delivery.zig`. Removed dead `src/monitoring/tracing.zig`. Review
  fixes: no committed secret (GEODE_OTEL_PASSWORD env), real collector readiness (health_check :13133).
  Baseline: `docs/otel-compose-baseline-2026-05-29.md`.
- 2026-05-29: **Phase B Increment 1 COMPLETE.** geode now emits a `geode.query.execute` SERVER span
  per statement via a thread-safe `GeodeSpan` facade (exactly-once `end()` atomic + `g_span_mu`
  guarding the non-thread-safe otel id-generator). Re-added the previously-rolled-back execute span
  (the producer race it feared, otel 0c34ce9, is already in pin 455ad2b8; the residual UAF is closed
  at the geode boundary). Added a geode-side **periodic span-flush loop** (the no-pool BSP has no
  timer). Verified: `REQUIRE_SPANS=1` collector verify PASSES (9 spans); 240-concurrent-query
  real-server smoke = no SIGABRT (the original crash scenario, now safe); unit concurrency test =
  4000 spans / 8 threads / exactly-once. Review fix: bounded `error.type` (specific error name is a
  documented follow-up — `errdefer |err|` won't compile vs the fn's inferred error set). Tests:
  `test-otel-span-facade`, `test-otel-span-concurrency`. **Note:** no otel pin bump (convergence
  cascade avoided); the otel BSP atomic-end fix stays on branch `fix/bsp-span-reuse-uaf` for the next
  ecosystem convergence.
  Next: Phase C (wire unwired P1 metrics + pull lib-internal stats — pure geode-side, no cascade) and
  Phase B Increment 2 (child spans). Phase D (otel-lib gaps like PR-4 keepalive) is deferred — it
  also needs a pin bump, and HTTP export already works.
