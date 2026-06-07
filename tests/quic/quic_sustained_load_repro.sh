#!/usr/bin/env bash
# CPU-constrained QUIC sustained-load reproduction harness for
# docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md
#
# MANUAL diagnostic / Phase-2 validation gate — NOT a CI test (needs systemd-run
# user-scope CPU control; takes ~2 min). Pure load + measurement: it makes NO
# transport code changes.
#
# Hypothesis (confirmed 2026-06-07): under CPU pressure + N concurrent QUIC query
# streams, the coarse Endpoint.mu poll loop head-of-line-blocks on a single
# expensive packet/first-stream query, so the IN-BAND `RETURN 1` liveness probe
# stalls into multi-second territory and times out (→ k8s SIGKILL → 503), while
# the OUT-OF-BAND `/health` endpoint (its own thread) stays fast. This harness
# measures both side-by-side plus the QUIC poll metrics, so a future Phase-2
# Endpoint.mu fix can be validated by re-running and asserting the in-band probe
# latency drops with no regression in test-quic-high-concurrency-e2e.
#
# Confirmed baseline (CPUQuota=200%, N=16, 2000 nodes, ReleaseSafe):
#   in-band RETURN 1 : 2.7-3.4 s then TIMEOUTS (>8s)   <- the liveness-kill trigger
#   out-of-band /health: ~18 ms throughout            <- Phase 1 mitigation holds
#   quic_poll_cycle_max_ns ~3.3-4.0 s; first_stream_packet_process_max ~18.8 s
#   wedged-stream idle grows unbounded; slow-poll WARN fires (Phase 1 Task 1)
#
# Usage (from repo root, after `zig build`):
#   QUOTA=200% N=16 DURATION=60 SEED_NODES=2000 tests/quic/quic_sustained_load_repro.sh
set -u

GEODE="${GEODE:-./zig-out/bin/geode}"
QUOTA="${QUOTA:-200%}"        # CPU cap (k8s bug env was limits.cpu:4 == 400%); tighten to bite on a fast box
N="${N:-16}"                  # concurrent load streams
DURATION="${DURATION:-60}"    # seconds of sustained load
SEED_NODES="${SEED_NODES:-2000}"
PORT="${PORT:-43141}"
MPORT="${MPORT:-49091}"
PASS="reprotest123"
WORKDIR="${WORKDIR:-/tmp/quic-liveness-repro}"
DATA="$WORKDIR/data"
LOG="$WORKDIR/server.log"
OUT="$WORKDIR/out"
mkdir -p "$OUT"; rm -rf "$DATA"; mkdir -p "$DATA"; : > "$LOG"

if [ ! -x "$GEODE" ]; then echo "geode binary not found at $GEODE (run: zig build). SKIP."; exit 0; fi
command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run not available; cannot CPU-constrain. SKIP."; exit 0; }

q() { "$GEODE" query --server "127.0.0.1:$PORT" --insecure-tls-skip-verify -U geode -P "$PASS" --timeout "${1:-10}" "$2" 2>&1; }

echo "== starting CPU-constrained server (CPUQuota=$QUOTA) =="
SCOPE="quic-repro-$$"
systemd-run --user --scope --property=CPUQuota="$QUOTA" --unit="$SCOPE" \
  env GEODE_ADMIN_PASSWORD="$PASS" GEODE_METRICS_PORT="$MPORT" GEODE_METRICS_BIND=127.0.0.1 \
  "$GEODE" serve --listen "127.0.0.1:$PORT" --data-dir "$DATA" --log-level info \
  > "$LOG" 2>&1 &
SCOPE_PID=$!
for _ in $(seq 1 80); do grep -q "server ready" "$LOG" 2>/dev/null && break; sleep 0.25; done
grep -q "server ready" "$LOG" || { echo "SERVER DID NOT BECOME READY"; tail -20 "$LOG"; kill $SCOPE_PID 2>/dev/null; exit 1; }
echo "server ready. out-of-band liveness breadcrumb:"; grep -iE "out-of-band liveness|/health" "$LOG" | head -1 || echo "  (MISSING — breadcrumb regression!)"

echo "== seeding $SEED_NODES nodes (comma-CREATE batches; geode rejects UNWIND..CREATE) =="
B=0
while [ $B -lt "$SEED_NODES" ]; do
  pat=""; j=$B
  while [ $j -lt $((B+50)) ] && [ $j -lt "$SEED_NODES" ]; do
    [ -n "$pat" ] && pat="$pat,"
    pat="$pat(:Item {id:$j, val:$((j % 1000)), name:'item$j'})"
    j=$((j+1))
  done
  q 30 "CREATE $pat" >/dev/null
  B=$((B+50))
done
echo "seeded. count:"; q 15 "MATCH (n:Item) RETURN count(n) AS c" | grep -oE '"c":[0-9]+' | head -1

echo "== launching $N concurrent load streams for ${DURATION}s =="
END=$(( $(date +%s) + DURATION ))
LOADPIDS=()
for _ in $(seq 1 "$N"); do
  ( while [ "$(date +%s)" -lt "$END" ]; do
      q 20 "MATCH (n:Item) WHERE n.val > 100 RETURN n.id, n.name LIMIT 1500" >/dev/null 2>&1
    done ) &
  LOADPIDS+=($!)
done

echo "== probe (in-band RETURN 1) vs out-of-band /health + QUIC poll metrics, ~1/s =="
printf "%-6s %-10s %-10s %-12s %-18s %-12s %-8s\n" "t" "probe_ms" "health_ms" "poll_max_ms" "fst_pkt_proc_max_ms" "stream_idle_s" "active" | tee "$OUT/timeline.txt"
T0=$(date +%s)
maxprobe=0; probe_timeouts=0; maxpoll=0; maxpkt=0; maxidle=0
while [ "$(date +%s)" -lt "$END" ]; do
  ps=$(date +%s%3N)
  if q 8 "RETURN 1" >/dev/null 2>&1; then pe=$(date +%s%3N); probe_ms=$((pe-ps)); else probe_ms=-1; probe_timeouts=$((probe_timeouts+1)); fi
  hs=$(date +%s%3N); curl -s -m 8 "http://127.0.0.1:$MPORT/health" >/dev/null 2>&1; he=$(date +%s%3N); health_ms=$((he-hs))
  M=$(curl -s -m 5 "http://127.0.0.1:$MPORT/metrics" 2>/dev/null)
  pollns=$(echo "$M" | grep -E '^geode_runtime_quic_poll_cycle_max_ns' | awk '{print $2}' | head -1)
  pktns=$(echo "$M" | grep -E '^geode_runtime_quic_first_stream_packet_process_max_ns' | awk '{print $2}' | head -1)
  active=$(echo "$M" | grep -E '^geode_runtime_quic_active_connections' | awk '{print $2}' | head -1)
  idlens=$(echo "$M" | grep -E '^geode_runtime_quic_max_stream_idle_ns' | awk '{print $2}' | head -1)
  pollms=$(( ${pollns:-0} / 1000000 )); pktms=$(( ${pktns:-0} / 1000000 )); idles=$(( ${idlens:-0} / 1000000000 ))
  [ "${probe_ms:-0}" -gt "$maxprobe" ] 2>/dev/null && maxprobe=$probe_ms
  [ "$pollms" -gt "$maxpoll" ] 2>/dev/null && maxpoll=$pollms
  [ "$pktms" -gt "$maxpkt" ] 2>/dev/null && maxpkt=$pktms
  [ "$idles" -gt "$maxidle" ] 2>/dev/null && maxidle=$idles
  printf "%-6s %-10s %-10s %-12s %-18s %-12s %-8s\n" "$(( $(date +%s)-T0 ))" "$probe_ms" "$health_ms" "$pollms" "$pktms" "$idles" "${active:-?}" | tee -a "$OUT/timeline.txt"
  sleep 1
done

echo "== teardown (stop server FIRST so load clients fail fast, then reap) =="
systemctl --user stop "$SCOPE.scope" 2>/dev/null
kill $SCOPE_PID 2>/dev/null
for p in "${LOADPIDS[@]}"; do kill "$p" 2>/dev/null; done
sleep 2
for p in "${LOADPIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
wait "${LOADPIDS[@]}" 2>/dev/null
SLOWWARN=$(grep -c "poll cycle slow" "$LOG" 2>/dev/null || true)
STALLS=$(grep -c "proto_reader stall" "$LOG" 2>/dev/null || true)

echo
echo "================ REPRO SUMMARY ================"
echo "config: QUOTA=$QUOTA N=$N DURATION=${DURATION}s seed=$SEED_NODES"
echo "max in-band probe RETURN 1 latency : ${maxprobe} ms"
echo "in-band probe timeouts (>8s)       : ${probe_timeouts}"
echo "max quic_poll_cycle_max_ns         : ${maxpoll} ms"
echo "max first_stream_packet_process    : ${maxpkt} ms"
echo "max stream idle (wedged-stream)    : ${maxidle} s"
echo "slow-poll WARN lines (Phase 1)     : ${SLOWWARN:-0}"
echo "proto_reader stall lines           : ${STALLS:-0}"
echo "--- dominant poll sub-phase maxes (last server metrics line, ms) ---"
LASTM=$(grep "info: metrics:" "$LOG" 2>/dev/null | tail -1)
for f in quic_poll_recv_process_max_ns quic_poll_recv_short_header_max_ns quic_poll_timer_process_max_ns quic_poll_pto_dirty_max_ns; do
  v=$(echo "$LASTM" | grep -oE "${f}=[0-9]+" | head -1 | cut -d= -f2)
  printf "  %-40s %s ms\n" "$f" "$(( ${v:-0} / 1000000 ))"
done
echo "timeline: $OUT/timeline.txt   server log: $LOG"
echo "PASS criterion for a Phase-2 fix: in-band probe stays well under 8s (no timeouts)"
echo "  AND poll_cycle_max stays sub-second under this load, with /health unchanged."
echo "=============================================="
