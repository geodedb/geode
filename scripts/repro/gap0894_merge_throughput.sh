#!/usr/bin/env bash
# GAP-0894 reproduction / verification probe.
#
# Surfaced by the divelife 14.27M-node bulk seed: single-property MERGE
# pegged at ~50 nodes/sec with mg_rwlock_exclusive_wait_ns climbing while
# mg_merge_tuple_lock_acquired_total stayed 0 — i.e. every MERGE serialized
# on the per-graph EXCLUSIVE write lock and the 8 client connections got zero
# parallelism.
#
# Two distinct causes, both fixed on the GAP-0894 branch:
#   1. The single-property MERGE adapter path took the graph-global
#      `merge_prop_index_lock` EXCLUSIVE instead of the striped
#      `merge_tuple_locks` table (fixed: bulkMergeNodeWithReservedIdForTenant).
#   2. A pooled database/sql driver prepends a graph selector
#      (`USE GRAPH <g>`) to EVERY statement for connection-pool safety, so the
#      MERGE arrived as a 2-statement program and never reached the striped
#      fast path — it fell to the regular executor's whole-graph EXCLUSIVE
#      lock (fixed: matchGraphSelectorThenMerge + the dispatch gate).
#
# This probe drives both the bare single-statement MERGE and the
# graph-selector-prefixed 2-statement MERGE and asserts the striped
# fast path is engaged (mg_merge_tuple_lock_acquired_total > 0) with the
# per-graph EXCLUSIVE wait bounded (mg_rwlock_exclusive_wait_ns_total small).
#
# Run from repo root after `make build`. Note: `geode query` opens a fresh
# connection per statement, so absolute throughput here is subprocess-bound
# and NOT the persistent-connection rate — the SIGNAL is the lock counters,
# not nodes/sec. The full divelife reproduction uses the pooled Go ingest
# client (`data-ingest ingest --from-dump ~/divelife-dump --workers 8`).
set -euo pipefail

BIN="${GEODE_BIN:-./zig-out/bin/geode}"
PORT="${GEODE_PORT:-3197}"
PW="${GEODE_ADMIN_PASSWORD:-Gap Merge Throughput Probe Passphrase}"
N="${N:-80}"
DATA="$(mktemp -d)"
LOG="$(mktemp)"

export GEODE_ADMIN_PASSWORD="$PW"
# Surface the full per-interval metrics line (incl. the mg_* graph counters)
# so we can read mg_merge_tuple_lock_acquired_total / mg_rwlock_exclusive_wait.
export GEODE_METRICS_LOG_FULL=1

"$BIN" serve --listen "127.0.0.1:${PORT}" --data-dir "$DATA" --log-level info >"$LOG" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; rm -rf "$DATA"; }
trap cleanup EXIT

Q() { "$BIN" query --server "127.0.0.1:${PORT}" --insecure-tls-skip-verify -U geode -P "$PW" "$@" 2>/dev/null; }

for _ in $(seq 1 40); do Q "RETURN 1" >/dev/null && break; sleep 0.5; done

mtl() { grep -oE "mg_merge_tuple_lock_acquired_total=[0-9]+" "$LOG" | tail -1 | cut -d= -f2; }
rxw() { grep -oE "mg_rwlock_exclusive_wait_ns_total=[0-9]+" "$LOG" | tail -1 | cut -d= -f2; }

echo "== Case 1: bare single-statement MERGE (default graph) =="
for i in $(seq 1 "$N"); do Q "MERGE (n:Taxon {taxon_id: $i}) SET n.rank='species'" >/dev/null 2>&1; done
sleep 6
echo "   mg_merge_tuple_lock_acquired_total=$(mtl)  mg_rwlock_exclusive_wait_ns_total=$(rxw)"

echo "== Case 2: graph-selector-prefixed MERGE (USE GRAPH default; MERGE) =="
for i in $(seq $((N + 1)) $((2 * N))); do
  Q -g default "MERGE (n:Taxon {taxon_id: $i}) SET n.rank='species'" >/dev/null 2>&1
done
sleep 6
echo "   mg_merge_tuple_lock_acquired_total=$(mtl)  mg_rwlock_exclusive_wait_ns_total=$(rxw)"

echo "== Expectation (post-fix): tuple_lock_acquired grows across BOTH cases;"
echo "   rwlock_exclusive_wait_ns stays ~0 (no whole-graph EXCLUSIVE serialization)."
count="$(Q "MATCH (n:Taxon) RETURN count(n) AS c" 2>/dev/null | grep -oE '"c":[0-9]+' | cut -d: -f2 || true)"
echo "   nodes merged: ${count:-?} (expect $((2 * N)))"
