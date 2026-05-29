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
