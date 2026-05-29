# OTel Phase A — docker-compose + collector + verification harness

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a self-contained docker-compose system that runs geode plus an OpenTelemetry collector, and a verification script that proves geode's metrics (and, later, spans) land in the collector — then capture an empirical baseline of what geode emits today.

**Architecture:** geode is built on the host (Zig 0.16) and packaged into `debian:bookworm-slim` via the existing `Dockerfile.prebuilt` (host glibc max-requirement is 2.36 = bookworm's glibc; libssl.so.3 = bookworm libssl3, so the prebuilt binary runs unmodified). A static `config/otel-collector.yaml` drives `otel/opentelemetry-collector-contrib:0.96.0` with OTLP http/grpc receivers fanning out to a `debug` exporter (verified via `docker compose logs`) and `file` exporters (richer offline capture on a named volume). `docker-compose.otel.yml` wires geode's `OTEL_*` env to push OTLP/HTTP to the collector over the compose network. No geode source changes in this phase.

**Tech Stack:** Docker Compose v5, opentelemetry-collector-contrib 0.96.0, geode (Zig 0.16), bash.

---

## File Structure

- Create: `config/otel-collector.yaml` — static collector pipeline config (receivers/processors/exporters/service).
- Create: `docker-compose.otel.yml` — collector + geode services on a shared network with OTEL_* wiring.
- Create: `scripts/otel-compose-verify.sh` — orchestrates up → generate telemetry → assert metrics+spans land → teardown.
- Create: `docs/otel-compose-baseline-2026-05-29.md` — captured baseline of what geode emits today.
- Modify: `Makefile` — add `otel-compose-up`, `otel-compose-verify`, `otel-compose-down` targets.
- Modify: `.gitignore` — ignore `otel-output/` host artifacts if any are written locally.

---

### Task 1: Confirm the tree builds after dead-code removal and produce a current release binary

**Files:**
- Build artifact: `zig-out/bin/geode`

- [ ] **Step 1: Build release on host**

Run:
```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
zig build -Doptimize=ReleaseSafe --summary all 2>&1 | tail -20
```
Expected: build completes; no error referencing the deleted `src/monitoring/tracing.zig`.

- [ ] **Step 2: Verify binary exists and is current**

Run:
```bash
test -f zig-out/bin/geode && ./zig-out/bin/geode --version 2>&1 | head -1 && ls -la zig-out/bin/geode
```
Expected: binary present, prints a version line.

- [ ] **Step 3: Commit (dead-code removal already staged via git rm)**

```bash
git add -A
git commit -m "chore(otel): remove dead homegrown tracer (src/monitoring/tracing.zig); start Phase A program docs"
```

---

### Task 2: Static collector config

**Files:**
- Create: `config/otel-collector.yaml`

- [ ] **Step 1: Write the collector config**

Create `config/otel-collector.yaml`:
```yaml
# OpenTelemetry Collector config for the geode docker-compose otel stack.
# Receives OTLP (http+grpc) from geode and fans out to:
#   - debug exporter  -> stdout (asserted by scripts/otel-compose-verify.sh via `docker compose logs`)
#   - file exporters  -> /var/log/otel/*.jsonl on the otel-output named volume (offline inspection / baseline capture)
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  batch:
    timeout: 1s

exporters:
  debug:
    verbosity: detailed
  file/traces:
    path: /var/log/otel/traces.jsonl
  file/metrics:
    path: /var/log/otel/metrics.jsonl
  file/logs:
    path: /var/log/otel/logs.jsonl

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file/traces]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file/metrics]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file/logs]
```

- [ ] **Step 2: Validate the config with the collector's own validator**

Run:
```bash
docker run --rm -v "$PWD/config/otel-collector.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  otel/opentelemetry-collector-contrib:0.96.0 validate --config /etc/otelcol-contrib/config.yaml
```
Expected: exit 0, no `Error:` lines. (If the image lacks `validate`, fall back to `docker run ... otelcol-contrib --config ... --dry-run` is NOT available — instead a short `up`/`down` smoke in Task 4 covers it.)

- [ ] **Step 3: Commit**

```bash
git add config/otel-collector.yaml
git commit -m "feat(otel): add static collector config for docker-compose otel stack"
```

---

### Task 3: docker-compose.otel.yml

**Files:**
- Create: `docker-compose.otel.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Write the compose file**

Create `docker-compose.otel.yml`:
```yaml
# Self-contained geode + OpenTelemetry collector stack.
#
# Usage:
#   zig build -Doptimize=ReleaseSafe          # produce zig-out/bin/geode on the host
#   docker compose -f docker-compose.otel.yml up --build -d
#   scripts/otel-compose-verify.sh            # generate telemetry + assert it lands
#   docker compose -f docker-compose.otel.yml down -v
#
# geode pushes OTLP/HTTP to the collector over the compose network (otel-collector:4318).
# The verify script execs into the geode container and runs queries against 127.0.0.1:3141,
# so no cross-container QUIC/UDP is required.
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.96.0
    container_name: geode-otel-collector
    command: ["--config", "/etc/otelcol-contrib/config.yaml"]
    volumes:
      - ./config/otel-collector.yaml:/etc/otelcol-contrib/config.yaml:ro
      - otel-output:/var/log/otel
    ports:
      - "4318:4318"   # OTLP/HTTP
      - "4317:4317"   # OTLP/gRPC
    healthcheck:
      # The contrib image has no curl; check the OTLP/HTTP port is open via the collector process.
      test: ["CMD", "/otelcol-contrib", "components"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 3s

  geode:
    build:
      context: .
      dockerfile: Dockerfile.prebuilt
    image: geode:otel-local
    container_name: geode-otel
    depends_on:
      otel-collector:
        condition: service_started
    environment:
      # --- OTel push to the in-compose collector ---
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
      OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"
      OTEL_METRICS_EXPORTER: "otlp"
      OTEL_TRACES_EXPORTER: "otlp"
      OTEL_TRACES_SAMPLER: "always_on"
      OTEL_METRIC_EXPORT_INTERVAL: "3000"
      OTEL_BSP_SCHEDULE_DELAY: "2000"
      OTEL_RESOURCE_ATTRIBUTES: "service.name=geode,service.namespace=codepros,deployment.environment.name=docker-compose"
      # --- geode runtime ---
      GEODE_ADMIN_PASSWORD: "geodeotel"
      GEODE_USERNAME: "geode"
      GEODE_PASSWORD: "geodeotel"
      GEODE_METRICS_BIND: "0.0.0.0:9091"
      LOG_LEVEL: "info"
    command: ["--data-dir", "/data", "--listen", "0.0.0.0:3141", "--log-level", "info"]
    ports:
      - "3141:3141/udp"   # QUIC
      - "9091:9091/tcp"   # Prometheus /metrics
    volumes:
      - geode-data:/data

volumes:
  otel-output:
  geode-data:
```

- [ ] **Step 2: Add gitignore entry for any local output dir**

Append to `.gitignore`:
```
# OTel docker-compose local artifacts
otel-output/
```

- [ ] **Step 3: Validate compose parses and merges**

Run:
```bash
docker compose -f docker-compose.otel.yml config >/dev/null && echo "compose OK"
```
Expected: prints `compose OK` (no YAML/schema errors).

- [ ] **Step 4: Commit**

```bash
git add docker-compose.otel.yml .gitignore
git commit -m "feat(otel): add self-contained geode + collector docker-compose stack"
```

---

### Task 4: Verification / orchestration script

**Files:**
- Create: `scripts/otel-compose-verify.sh`

- [ ] **Step 1: Write the verification script**

Create `scripts/otel-compose-verify.sh` (mode 0755):
```bash
#!/usr/bin/env bash
# Bring up the geode + collector stack, generate telemetry by running queries
# inside the geode container, then assert that metrics (and spans, once geode
# emits them) with service.name=geode reached the collector. Tears down on exit.
#
# Exit 0 = metrics landed. Exit 2 = no geode metrics seen. Spans are reported
# but NOT required to pass in Phase A (geode emits none yet); set REQUIRE_SPANS=1
# to make spans mandatory (used from Phase B onward).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
COMPOSE="docker compose -f docker-compose.otel.yml"
REQUIRE_SPANS="${REQUIRE_SPANS:-0}"
PW="geodeotel"

cleanup() { $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Building geode release binary on host"
zig build -Doptimize=ReleaseSafe >/dev/null

echo "==> Bringing up stack"
$COMPOSE up --build -d

echo "==> Waiting for geode to become healthy (max 90s)"
deadline=$(( $(date +%s) + 90 ))
until [ "$(docker inspect -f '{{.State.Health.Status}}' geode-otel 2>/dev/null || echo starting)" = "healthy" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: geode did not become healthy in time"; $COMPOSE logs geode | tail -40; exit 1
  fi
  sleep 3
done
echo "    geode healthy"

echo "==> Generating telemetry (queries inside the geode container)"
gq() { docker compose -f docker-compose.otel.yml exec -T geode \
        /usr/local/bin/geode query "$1" --server 127.0.0.1:3141 --insecure -U geode -P "$PW" 2>&1 | tail -2 || true; }
gq "RETURN 1 AS x"
gq "CREATE GRAPH otel_demo"
gq "USE otel_demo CREATE (:Person {name: 'a'})"
gq "USE otel_demo MATCH (n) RETURN count(n) AS c"
gq "USE otel_demo MATCH (n:Person) RETURN n.name AS name"

echo "==> Waiting for export interval flush (OTEL_METRIC_EXPORT_INTERVAL=3000ms)"
sleep 8

echo "==> Scanning collector output for service.name=geode"
LOGS="$($COMPOSE logs otel-collector 2>/dev/null)"

metric_hits=$(printf '%s' "$LOGS" | grep -cE 'service\.name.*geode|"service\.name":\s*"geode"' || true)
# Count distinct geode metric names observed in the debug exporter dump.
metric_names=$(printf '%s' "$LOGS" | grep -oE 'geode\.[a-z._]+' | sort -u || true)
span_lines=$(printf '%s' "$LOGS" | grep -cE 'Span #|"spanId"|InstrumentationScope com\.geodedb\.geode' || true)

echo "---- collector summary ----"
echo "service.name=geode references: $metric_hits"
echo "distinct geode.* metric names seen:"; echo "$metric_names" | sed 's/^/    /'
echo "span-indicator lines: $span_lines"
echo "---------------------------"

if [ "$metric_hits" -lt 1 ]; then
  echo "FAIL: no geode telemetry observed in collector"; $COMPOSE logs otel-collector | tail -60; exit 2
fi

if [ "$REQUIRE_SPANS" = "1" ] && [ "$span_lines" -lt 1 ]; then
  echo "FAIL: REQUIRE_SPANS=1 but no spans observed"; exit 3
fi

echo "PASS: geode metrics reached the collector (spans required=$REQUIRE_SPANS, seen=$span_lines)"
```

- [ ] **Step 2: Make executable**

Run:
```bash
chmod +x scripts/otel-compose-verify.sh
```

- [ ] **Step 3: Run the verification (Phase A: metrics required, spans optional)**

Run:
```bash
scripts/otel-compose-verify.sh
```
Expected: ends with `PASS: geode metrics reached the collector`. The summary lists several `geode.*` metric names (e.g. `geode.query.count`, `geode.transport.connection.opened`, `geode.wal.record.count`). `span-indicator lines: 0` is expected in Phase A.

- [ ] **Step 4: Commit**

```bash
git add scripts/otel-compose-verify.sh
git commit -m "feat(otel): add docker-compose telemetry verification script"
```

---

### Task 5: Capture the empirical baseline

**Files:**
- Create: `docs/otel-compose-baseline-2026-05-29.md`

- [ ] **Step 1: Capture metric names + a /metrics sample into the baseline doc**

Run (collects evidence; the script leaves the stack torn down, so bring it up briefly for the pull-endpoint sample):
```bash
docker compose -f docker-compose.otel.yml up --build -d
sleep 12
echo "### Prometheus /metrics (pull) sample" > /tmp/otel_baseline_evidence.txt
docker compose -f docker-compose.otel.yml exec -T geode sh -c 'command -v wget >/dev/null && wget -qO- http://127.0.0.1:9091/metrics || /usr/local/bin/geode query "RETURN 1" --server 127.0.0.1:3141 --insecure -U geode -P geodeotel' 2>&1 | head -60 >> /tmp/otel_baseline_evidence.txt
docker compose -f docker-compose.otel.yml exec -T otel-collector sh -c 'cat /var/log/otel/metrics.jsonl 2>/dev/null | head -3' >> /tmp/otel_baseline_evidence.txt 2>&1 || true
docker compose -f docker-compose.otel.yml down -v
cat /tmp/otel_baseline_evidence.txt | head -80
```
Expected: prints Prometheus exposition lines and/or OTLP JSONL records.

- [ ] **Step 2: Write the baseline doc**

Create `docs/otel-compose-baseline-2026-05-29.md` recording: (a) the exact `geode.*` metric names the verify script reported landing via OTLP push, (b) whether spans landed (expected: none — confirms the Phase B gap empirically), (c) a trimmed Prometheus `/metrics` sample, (d) the collector image/version and compose command used. Use the real captured output from Step 1 and the Task 4 run — do not invent values.

- [ ] **Step 3: Commit**

```bash
git add docs/otel-compose-baseline-2026-05-29.md
git commit -m "docs(otel): capture docker-compose telemetry baseline (metrics land, spans do not yet)"
```

---

### Task 6: Makefile ergonomics

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add targets**

Add to `Makefile` (place near other docker/test targets; keep tab indentation for recipes):
```makefile
## OTel docker-compose stack -------------------------------------------------
.PHONY: otel-compose-up otel-compose-verify otel-compose-down

otel-compose-up: ## Build geode + bring up the geode/collector otel stack
	zig build -Doptimize=ReleaseSafe
	docker compose -f docker-compose.otel.yml up --build -d

otel-compose-verify: ## Run the end-to-end telemetry verification
	scripts/otel-compose-verify.sh

otel-compose-down: ## Tear down the otel stack and volumes
	docker compose -f docker-compose.otel.yml down -v
```

- [ ] **Step 2: Verify the targets are recognized**

Run:
```bash
make -n otel-compose-verify
```
Expected: echoes `scripts/otel-compose-verify.sh` (no "No rule to make target" error).

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "chore(otel): add make targets for the docker-compose otel stack"
```

---

## Self-Review checklist (run before handing off)
- Spec coverage: collector config ✔ (Task 2), compose ✔ (Task 3), verification ✔ (Task 4), baseline ✔ (Task 5), ergonomics ✔ (Task 6), build sanity after dead-code removal ✔ (Task 1).
- Placeholder scan: all file contents are complete and inline; baseline doc (Task 5) is filled from real captured output, not invented.
- Consistency: env var names match geode's runtime reads (`OTEL_METRICS_EXPORTER`, `OTEL_TRACES_EXPORTER`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `GEODE_ADMIN_PASSWORD`, `GEODE_METRICS_BIND`); collector service name `otel-collector` matches the endpoint URL; `geode-otel` container name matches the `docker inspect` health probe in the verify script.

## Notes / risks
- **Admin username:** assumed `geode` (per loadtest DSN `user=geode`). If queries return an auth error, the verify script's `-U geode` is the only thing to adjust; the auto-generated password file is at `/data/.geode_admin_password` inside the container as a fallback.
- **Collector healthcheck:** uses `/otelcol-contrib components` (the binary is present in the contrib image) since the image has no curl. `depends_on: condition: service_started` is used (not `service_healthy`) to avoid blocking if the healthcheck shape differs across patch versions.
- **Spans:** Phase A expects zero spans; the verify script reports them but only enforces with `REQUIRE_SPANS=1` (used from Phase B).
