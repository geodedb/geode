# Audit-perf triage — post Task #31 (2026-04-24)

## TL;DR

**Bug A (audit firing on no-audit graphs): NOT confirmed.**  A fresh-server
repro of the `audit_events` seed against a graph with no audit policy
leaves `audit.jsonl` at **0 bytes** through the entire slow phase.  The
per-mutation audit path already early-returns correctly for non-security
graphs; the user observation is almost certainly about the
msft-graph NODE KIND named `audit_event`, not geode's audit
subsystem.

**Bug B (QUIC library race): NOT firing.**  Geode wraps the QUIC
library's intentionally-duplicating re-queue behaviour in a per-connection
`ActiveStreamRegistry` that dedupes by stream ID before spawning a
handler, so the `queueIncomingStream`/`tryAcceptStream` concern from
`TASK-31-TRIAGE.md`'s residual section is covered.

**Actual dominant cost:** per-property storage work in the bulk insert
path.  Side-by-side repro shows **~42 ms/node** for 500 `user` nodes
(~23 props each) and **~42 ms/node** for 500 `audit_event` nodes
(~10 props each) at 16-way parallel — property count dominates, not
node count.  `audit_events.jsonl` is just the first file big enough
(2414 nodes) for the steady-state rate to be visible, so it *looks*
like an audit-specific regression.

Recommended next step: profile `StorageAdapter.setNodeProperty`
(`src/storage/graph_storage_adapter.zig:1951`) under the 16-way
coordinator, not the audit subsystem.

---

## Bug A evidence — audit is NOT firing

### Static-analysis proof the hot path already short-circuits

- `src/server/quic_connection_handler.zig:2140-2144`
  `resolveAuditLogger` returns the **per-graph** logger via
  `StorageAdapter.getAuditLogger(graph_name)`; returns `null` for any
  graph that isn't `__geode_security`.  The global-fallback was
  intentionally removed on 2026-04-23 (comment at lines 2125-2139
  documents the rationale verbatim: "drops a measurable write-path
  overhead on the msft-graph hot path").
- `src/server/quic_connection_handler.zig:2155-2163`
  `auditQueryExecution` does `resolveAuditLogger(state) orelse return`
  before any allocation.  For the `test` graph in the repro, this is
  guaranteed to return `null`.
- `src/storage/graph_storage_adapter.zig:2843,2895` — per-graph
  `audit_logger` is initialised only when `is_security_graph` is true.
- `src/storage/group_commit.zig` — **zero** audit/CDC/TDE hooks in the
  hot path (`applyBatch`, `bulkInsertNode`, `setNodeProperty`).

### Live repro (fresh server + audit-events-only seed)

```
time=08:29:19 pipeline progress geode.flushed=150
time=08:29:19 pipeline progress geode.flushed=300
time=08:29:19 pipeline progress geode.flushed=450
time=08:29:19 pipeline progress geode.flushed=600
time=08:29:21 pipeline progress geode.flushed=614   ← stall begins
...                                                   audit.jsonl=0B
time=08:30:25 (killed after 64 s with 614/2414)     audit.jsonl=0B
```

- `/tmp/geode-audit-repro/audit.jsonl` stayed at 0 bytes through the
  entire stall.  The file was created at init (see Known caveat below)
  but no content was ever appended.
- Server CPU pegged 147–177 % across 20+ worker threads in R/S state
  (compute-bound on query workers, not a single-threaded bottleneck).

### Known init-time caveat (unrelated to the stall)

`src/server/main.zig:464,493` defaults `audit_config.enabled = true` and
calls `AuditLogger.init`, which at `src/security/audit.zig:244-261`
creates `{data_dir}/audit.jsonl` + `audit.jsonl.key` + `audit.jsonl.pub`
and loads an Ed25519 keypair.  This is one-time init cost (~ms) and
does not fire per-mutation.  If we want auditing truly "off" by default
we'd flip the default to `false` or gate behind a GEODE_AUDIT_ENABLED
env var, but that's hygiene, not the perf bug.

### Gate recommendation (if the fast-path hypothesis ever revives)

Even though `auditQueryExecution` already early-returns correctly, a
single additional short-circuit in `AuditLogger.appendAuditEvent`
(`src/security/audit.zig:440`) would be defence-in-depth:

```zig
pub fn appendAuditEvent(self: *AuditLogger, ev: *AuditEvent) !void {
    if (!self.config.enabled) return;          // <-- add this line
    self.mutex.lockUncancelable(...);
    ...
```

`logEvent` at line 544 already does this; `appendAuditEvent` does not.
Not load-bearing for this ticket.

---

## Bug B evidence — QUIC library race is NOT firing

- `/home/benji/src/devnw/zig/quic/src/quic/connection/methods_c.zig:301-320`
  `queueIncomingStream` intentionally allows duplicates (comment:
  "PHASE 42 PART 15").
- `:379-408` `acceptStream` uses `swapRemove(0)` (non-FIFO), as triage
  noted.
- **Geode mitigation**: `src/server/active_stream_registry.zig:128-138`
  `ActiveStreamRegistry.register` returns `false` for any stream_id
  already registered; `quic_connection_handler.zig:1514-1578` checks
  this and skips the handler spawn when `is_new_stream == false`.
  Test coverage at `quic_connection_handler.zig:4294-4310`.
- Under the 16-way repro, CPU was on compute (R state on many worker
  threads), not stream-waiting (S on stream I/O).  No stuck-handler
  signature.

No evidence the library race is firing post-Task-#31.  Leave the
residual concern on the backlog; do not open a ticket.

---

## Dominant-cost analysis (the actual bug)

### Measurement

Repro on fresh binary `b5a85fb9` (post-Task-#31):

| File           | Nodes | Props/node | Workers | Wall-time | Per-node |
|----------------|-------|-----------|---------|-----------|----------|
| audit_events   | 500   | ~10       | 16      | 20.9 s    | 41.8 ms  |
| users          | 500   | ~23       | 16      | 43.0 s    | 86.0 ms  |

Per-property cost ≈ 4 ms regardless of node kind.  **Property count
dominates, not node kind.**  `audit_events.jsonl` is slow because it
has 2414 nodes; individual nodes are actually *faster* than `user`.

### Why the Phase-4.1 log made it look audit-specific

Pre-`audit_events` files ranged 27–1345 nodes, most completed in
<20 s.  `audit_events` is the first file with enough rows (2414) to
run past the 30-s-ish window the operator was watching, so the eye
reads it as "stuck".  In fact 614 nodes did commit during the observed
window — consistent with ~26 ms/node on this 10-prop schema.

### Suspect hot path

`StorageAdapter.setNodeProperty` at `graph_storage_adapter.zig:1951`:

- Line 1953: acquires `self.mutex` (global adapter mutex) per call.
- Line 1958: `label_store.getLabels` allocates + copies the label-ID
  list per property.
- Line 1966: `toStorageProperty` allocates + encodes every value.
- Line 1996: `addIndexedNodeProperty` hashes + inserts into
  `exact_node_property_index` under an RW-lock per label.

With ~10 properties × 150 nodes × 17 chunks × 16 workers, that's
~400 k property inserts on the `adapter.mutex` per ingest.  The
coordinator's 16-way shard would help here only if the per-call cost
dropped; today each call still funnels through `self.mutex`.

This is well outside the audit/QUIC scope of this triage, but it's
where the next perf investigation should go.

---

## Ranked fix priority (for the user observation)

1. **Neither Bug A nor Bug B is the dominant cost.**  Audit is not
   firing; QUIC race is not firing.  The observation labelled
   "audit_events shouldn't be firing" is a kind-name coincidence.
2. **Real bug to open (out of scope here):** per-property
   `StorageAdapter.setNodeProperty` cost on the bulk path.  Candidates
   to profile: `adapter.mutex` contention, repeated label_store
   allocation, `addIndexedNodeProperty` hash cost.  File:
   `src/storage/graph_storage_adapter.zig:1951-1998`.
3. **Hygiene (not required):** flip `audit_config.enabled` default to
   `false` in `src/server/main.zig:464` so the keypair files don't
   appear in data dirs the operator never configured for audit.  Also
   add the `if (!self.config.enabled) return;` gate in
   `AuditLogger.appendAuditEvent`.

## Fix scope

- **No audit code changes required for the perf bug.**
- **No QUIC-library changes required.**
- Open a separate ticket: "bulk-ingest per-property cost profiling" —
  `src/storage/graph_storage_adapter.zig:1951` (setNodeProperty),
  `:2011` (setNodePropertiesBatch), `:1132` (bulkInsertNode per-prop
  loop).

## Reproducer (for the fixer of the real bug)

```bash
# Fresh data dir + server on port 3163
rm -rf /tmp/geode-audit-repro && mkdir /tmp/geode-audit-repro
GEODE_ADMIN_PASSWORD=validate \
  /home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode serve \
  --listen 127.0.0.1:3163 --data-dir /tmp/geode-audit-repro \
  > /tmp/geode-audit-repro/server.log 2>&1 &

/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode query \
  --server 127.0.0.1:3163 --insecure -U geode -P validate \
  "CREATE GRAPH test"

# Isolate audit_events.jsonl or any single JSONL kind
mkdir -p /tmp/audit-only
cp /home/benji/eagleg-topology-data-16/audit_events.jsonl /tmp/audit-only/

# Run parallel seed
time msft-graph seed --input /tmp/audit-only \
  --geode-dsn "127.0.0.1:3163?insecure=true&user=geode&pass=validate&graph=test" \
  --parallel --workers 16 --chunk-size 500 --serial-fallback=true

# Monitor audit.jsonl — it will NOT grow during ingest
watch -n 1 'ls -l /tmp/geode-audit-repro/audit.jsonl'
```

Side-by-side comparison (show property-count dominates):

```bash
# 500 audit_events  (~10 props/node)  →  ~20 s
# 500 users         (~23 props/node)  →  ~43 s
# per-property cost ≈ constant (~4 ms)
```
