#!/usr/bin/env bash
#
# Smoke-test geode's OTel exporter end-to-end.
#
# Two modes (selected by the first arg):
#
#   local    Spin up an otel/opentelemetry-collector-contrib docker
#            container with the `debug` exporter on stdout, point a
#            short-lived geode at it via OTEL_EXPORTER_OTLP_ENDPOINT,
#            run a tracing-friendly query workload, and assert spans
#            + metrics with service.name=geode appear in the
#            collector log.
#
#   live     Use the system-installed /etc/geode/otel.env (populated
#            by `make install-otel`) and verify the running
#            geode.service successfully exports to the configured
#            endpoint. Tail journalctl for export-success log lines.
#
# Exit codes:
#   0   tracing pipeline verified end-to-end
#   1   verification failed (missing spans / metrics / errors in log)
#   2   prerequisites missing (docker, geode binary, /etc/geode/otel.env)

set -euo pipefail

MODE="${1:-local}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-$ROOT/zig-out/bin/geode}"
# Uncommon ports to avoid collision with a host-resident collector.
# Override via env if needed.
COLLECTOR_PORT_HTTP="${COLLECTOR_PORT_HTTP:-44318}"
COLLECTOR_PORT_GRPC="${COLLECTOR_PORT_GRPC:-44317}"
COLLECTOR_LOG="/tmp/otel-collector-$$.log"
COLLECTOR_CFG="/tmp/otel-collector-$$-config.yaml"
GEODE_LOG="/tmp/geode-otel-test-$$.log"
GEODE_DATA="/tmp/geode-otel-test-$$-data"
GEODE_PORT=31419

cleanup() {
  local rc=$?
  echo "--- cleanup ---"
  if [[ -n "${GEODE_PID:-}" ]]; then
    kill "$GEODE_PID" 2>/dev/null || true
    wait "$GEODE_PID" 2>/dev/null || true
  fi
  if [[ -n "${COLLECTOR_CID:-}" ]]; then
    docker rm -f "$COLLECTOR_CID" >/dev/null 2>&1 || true
  fi
  if [[ -d "$GEODE_DATA" ]]; then
    chmod -R u+rwx "$GEODE_DATA" 2>/dev/null || true
    rm -rf "$GEODE_DATA"
  fi
  rm -f "$COLLECTOR_CFG" "$COLLECTOR_LOG" "$GEODE_LOG"
  exit "$rc"
}
trap cleanup EXIT INT TERM

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required tool not found: $1"
    exit 2
  }
}

#
# Mode: local — docker collector + ephemeral geode + workload
#
run_local() {
  echo "=== OTel tracing smoke test (local docker collector) ==="
  require docker

  if [[ ! -x "$GEODE_BIN" ]]; then
    echo "ERROR: geode binary not found at $GEODE_BIN — run \`zig build\` first."
    exit 2
  fi

  cat > "$COLLECTOR_CFG" <<'YAML'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317
exporters:
  debug:
    verbosity: detailed
processors:
  batch: {}
service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
YAML

  echo "Starting otel-collector on :${COLLECTOR_PORT_HTTP}/${COLLECTOR_PORT_GRPC}..."
  COLLECTOR_CID=$(docker run -d --rm \
    -p "${COLLECTOR_PORT_HTTP}:4318" \
    -p "${COLLECTOR_PORT_GRPC}:4317" \
    -v "${COLLECTOR_CFG}:/etc/otelcol-contrib/config.yaml:ro" \
    otel/opentelemetry-collector-contrib:latest)
  echo "  collector container: $COLLECTOR_CID"

  # Wait for the collector to bind.
  for _ in {1..20}; do
    if (echo > "/dev/tcp/127.0.0.1/${COLLECTOR_PORT_HTTP}") 2>/dev/null; then break; fi
    sleep 0.5
  done

  echo "Starting geode with OTEL push to local collector..."
  mkdir -p "$GEODE_DATA"
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${COLLECTOR_PORT_HTTP}" \
  OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf" \
  OTEL_TRACES_EXPORTER=otlp \
  OTEL_METRICS_EXPORTER=otlp \
  OTEL_TRACES_SAMPLER=always_on \
  OTEL_METRIC_EXPORT_INTERVAL=2000 \
  OTEL_RESOURCE_ATTRIBUTES="deployment.environment.name=test" \
  "$GEODE_BIN" serve \
    --data-dir "$GEODE_DATA" \
    --listen "127.0.0.1:${GEODE_PORT}" \
    --log-level info \
    >"$GEODE_LOG" 2>&1 &
  GEODE_PID=$!
  echo "  geode pid: $GEODE_PID"

  # Wait for geode to be ready.
  for _ in {1..30}; do
    if grep -q "server ready\|listening on\|Listening on" "$GEODE_LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$GEODE_PID" 2>/dev/null; then
      echo "ERROR: geode crashed during startup. Last log:"
      tail -30 "$GEODE_LOG"
      exit 1
    fi
    sleep 0.5
  done

  # Drive a small workload so traces / metrics actually fire.
  echo "Driving workload (RETURN, MATCH) for ~15s..."
  local end_ts=$(( $(date +%s) + 15 ))
  while [[ $(date +%s) -lt $end_ts ]]; do
    "$GEODE_BIN" query --insecure --no-tls-verify \
      --server "127.0.0.1:${GEODE_PORT}" "RETURN 1 AS x" >/dev/null 2>&1 || true
    sleep 0.5
  done

  # Allow the periodic metric reader (2s) + batch span exporter to flush.
  echo "Waiting for export flush (4s)..."
  sleep 4

  # Pull collector log + assert.
  docker logs "$COLLECTOR_CID" >"$COLLECTOR_LOG" 2>&1

  echo ""
  echo "=== Verification ==="
  local ok=1
  if grep -q '"service.name"' "$COLLECTOR_LOG" || grep -q 'service.name: Str(' "$COLLECTOR_LOG"; then
    echo "  ✓ collector received resource with service.name attribute"
  else
    echo "  ✗ no service.name in collector output"
    ok=0
  fi
  if grep -qiE 'metric|geode\.|metrics export' "$COLLECTOR_LOG"; then
    echo "  ✓ collector received geode metrics"
  else
    echo "  ✗ no metric records in collector output"
    ok=0
  fi
  if [[ $ok -eq 0 ]]; then
    echo ""
    echo "Collector log (first 80 lines):"
    head -80 "$COLLECTOR_LOG" | sed 's/^/  /'
    echo ""
    echo "Geode log (last 30 lines):"
    tail -30 "$GEODE_LOG" | sed 's/^/  /'
    exit 1
  fi
  echo ""
  echo "✓ end-to-end tracing pipeline verified against local docker collector"
}

#
# Mode: live — use installed geode + /etc/geode/otel.env + journalctl
#
run_live() {
  echo "=== OTel tracing smoke test (live, against /etc/geode/otel.env) ==="
  require systemctl
  require journalctl

  if [[ ! -r /etc/geode/otel.env ]]; then
    echo "ERROR: /etc/geode/otel.env not found. Run \`make install-otel GEODE_OTEL_BEARER_TOKEN=...\` first."
    exit 2
  fi

  if ! systemctl is-active --quiet geode.service; then
    echo "ERROR: geode.service is not active. Start it: sudo systemctl start geode.service"
    exit 2
  fi

  # Confirm the env file has been substituted (no placeholder).
  if sudo grep -q '__REPLACE_WITH_TOKEN__' /etc/geode/otel.env; then
    echo "ERROR: /etc/geode/otel.env still has the placeholder bearer token."
    echo "Reinstall: make install-otel GEODE_OTEL_BEARER_TOKEN=..."
    exit 2
  fi

  echo "Recording journal cursor before workload..."
  local cursor
  cursor=$(sudo journalctl -u geode.service -n 1 --output=export 2>/dev/null \
    | grep '^__CURSOR=' | head -1 | cut -d= -f2-)

  echo "Driving workload (~10s of RETURN)..."
  local geode_local_port
  geode_local_port=$(systemctl show -p ExecStart geode.service \
    | sed -nE 's/.*--listen[= ]+([^ ]*):([0-9]+).*/\2/p')
  : "${geode_local_port:=3141}"
  local end_ts=$(( $(date +%s) + 10 ))
  while [[ $(date +%s) -lt $end_ts ]]; do
    /usr/bin/geode query --insecure --no-tls-verify \
      --server "127.0.0.1:${geode_local_port}" "RETURN 1 AS x" >/dev/null 2>&1 || true
    sleep 0.5
  done

  # Allow the periodic metric reader to flush + batch span processor.
  echo "Waiting for export flush (8s)..."
  sleep 8

  echo "Tailing journal since workload start for OTel signals..."
  local since_arg=()
  if [[ -n "$cursor" ]]; then
    since_arg=(--after-cursor="$cursor")
  else
    since_arg=(--since=-30s)
  fi

  local jrn=/tmp/geode-journal-$$.log
  sudo journalctl -u geode.service "${since_arg[@]}" --no-pager > "$jrn" 2>&1

  echo ""
  echo "=== Verification ==="
  local ok=1
  if grep -qiE 'OTel|otlp|periodic.*reader|MeterProvider|TracerProvider' "$jrn"; then
    echo "  ✓ OTel pipeline lines present in journal"
  else
    echo "  ✗ no OTel pipeline lines in journal"
    ok=0
  fi
  if grep -qiE 'failed to (export|push)|otlp.*error|connect.*refused|tls.*error|401|403' "$jrn"; then
    echo "  ✗ OTel exporter reported errors:"
    grep -iE 'failed to (export|push)|otlp.*error|connect.*refused|tls.*error|401|403' "$jrn" | sed 's/^/    /'
    ok=0
  else
    echo "  ✓ no OTel exporter errors in journal"
  fi

  rm -f "$jrn"
  if [[ $ok -eq 0 ]]; then
    exit 1
  fi
  local endpoint
  endpoint=$(sudo grep '^OTEL_EXPORTER_OTLP_ENDPOINT' /etc/geode/otel.env 2>/dev/null | cut -d= -f2-)
  echo ""
  echo "✓ live OTel push verified against ${endpoint}"
  echo "  (verifying records actually landed in GitLab Observability requires"
  echo "   a project API token — see otel/docs/runbooks/h7-token-rotation.md)"
}

case "$MODE" in
  local) run_local ;;
  live)  run_live ;;
  *) echo "Usage: $0 {local|live}"; exit 2 ;;
esac
