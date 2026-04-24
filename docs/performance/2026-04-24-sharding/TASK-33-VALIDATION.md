# Task #33 validation — node-phase fix lands, edge phase still slow (2026-04-24)

## TL;DR

The `bulkInsertNode` → `setNodePropertiesBatch` switch + StatementTxn
join in `adapter.setNodePropertiesBatch` (commit `042b43ef`)
**eliminates the node-phase stall** under the msft-graph `workers=16`
ingest.  Node phase completes in ~6m55s with zero hangs.  Edge phase
hits a different, still-unresolved slowness at
`edges_app_role_assignment.jsonl` (400 edges) where 5 of 16 workers
stall on `conn.BeginTx → ReceiveProto`.

## Node phase — PASS

Server: `geode main @ 042b43ef` (Task #33 applied on top of #31, audit
hygiene, default group_commit).  Seed: msft-graph `main @ 5fc82ef`
(Phase 4.1 re-landed, plus integration test).

| File | Nodes | Duration | Cumulative |
|---|---|---|---|
| user | 621 | 23 s | 23 s |
| device | 73 | 9 s | 32 s |
| application | 156 | 8 s | 40 s |
| group | 328 | 22 s | 62 s |
| ip | 80 | 0.8 s | 63 s |
| location | 38 | 1.1 s | 64 s |
| site | 184 | 6 s | 70 s |
| drive | 230 | 12 s | 82 s |
| drive_item | 1345 | 57 s | 139 s |
| conditional_access_policy | 27 | 0.6 s | 140 s |
| **audit_event** | **2414** | **104 s** | **244 s** |
| compliance_policy | 6 | 0.3 s | 244 s |
| service_principal | 1075 | 50 s | 294 s |
| tenant_setting | 6 | 1.1 s | 295 s |
| directory_role | 35 | 1.7 s | 297 s |
| subscription | 29 | 0.6 s | 297 s |
| security_alert | 460 | 18 s | 315 s |
| role_definition | 909 | 25 s | 340 s |
| app_role | 1033 | 57 s | 397 s |
| + 6 small files | ~260 | ~15 s | 415 s |

**Node phase total: ~415 s (~6 m 55 s) for 9350+ nodes across 25 files.  Zero hangs, zero chunk failures, zero serial fallbacks.**

`audit_events.jsonl` (the prior blocker) completed cleanly in 104 s.
Pre-fix, this file never completed — seed was killed after 150 s with
no progress entries past file-start.

Comparison to R13 baseline (2026-04-23): whole seed 2 h 5 m 33 s,
48 chunk failures.  Node phase alone took ~12 min in R13 ingest.

## Edge phase — PARTIAL

After the node phase finishes, `edges_activated_role.jsonl` (65 edges)
completes in 0.4 s.  Then `edges_app_role_assignment.jsonl` (400
edges, 16 chunks × 25) stalls.  `SIGQUIT` on the seed at 2 m 18 s
shows 5 of 16 workers blocked in:

```
runtime.gopark
geodedb.com/geode.(*QUICTransport).ReceiveProto
    transport.go:259
main.batchExecTxOnConn
    geodeutil.go:308
main.batchExecPinned
    geodeutil.go:564
main.pipelineExec.func1
```

Same pattern as Task #31's original `BeginTx`-stuck signature, but
Task #31's thread-pool fix was proven end-to-end — node phase no
longer hangs.  So the edge path must exercise a different server-side
bottleneck.

Likely candidates:

1. **`bulk_match_create_edge` ApplyOp in the coordinator**
   (`src/storage/group_commit.zig:437-491`) — looks up src and dst
   endpoints via `lookupNodeByMergeKey`, then calls
   `bulkInsertEdgeWithIds`.  The lookup goes through
   `merge_prop_index` which is protected by `merge_prop_index_lock`.
   Under a batch of ~25 edges, each worker may contend on that lock.
2. **`bulkInsertEdgeWithIds` in the adapter** doesn't use the Task
   #33 `setNodePropertiesBatch` path — edge properties still go
   through per-property `setEdgeProperty` (if it exists) or inline
   writes.  Untouched by Task #33.
3. **Per-edge adjacency index updates** — adjacency maps (`outgoing_edges`,
   `incoming_edges`) are sharded by node-id but every edge insert
   touches both endpoints' adjacency shards; under 16-way
   concurrency, some shard pairs will collide.

## Commits landed this session

| SHA | Summary |
|---|---|
| `0a8cba80` | audit hygiene — default enabled=false + appendAuditEvent gate |
| `042b43ef` | perf(bulk): route bulkInsertNode properties through setNodePropertiesBatch |
| `b5a85fb9` | fix(transport): route submit() to default lane — Task #31 |
| `96403570` | test(transport): regression tests for QUIC stream multiplex hang |
| `b42b3524` | docs(perf): Task #31 fix report |
| `9e4eeda4` | docs(perf): Task #31 validation success |

(Plus earlier session work: Phase 2 sharding, group_commit, Phase 4.1
pinned conns etc. — see `docs/performance/2026-04-24-sharding/` for
the full progression.)

## Next ticket (Task #34)

**Bulk-edge ingest slowness.**  Profile the coordinator's
`bulk_match_create_edge` path.  Candidate fix: batch edge property
writes the same way Task #33 batched node property writes (add
`setEdgePropertiesBatch` + route through it from
`bulkInsertEdgeWithIds`).  May also need to reduce contention on
`merge_prop_index_lock` for the endpoint-resolution step.

Stack samples + full seed log:
`docs/performance/2026-04-24-sharding/phase4.1-validation/post-task33-w16-validation.log`.

## Artifacts

- `post-task33-w16-validation.log` — full seed trace with SIGQUIT
  goroutine dump (201 KB).
- `AUDIT-PERF-TRIAGE.md` — the triage that located the per-property
  bottleneck and ruled out audit + QUIC library concerns.
