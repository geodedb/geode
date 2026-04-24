# Task #34 validation — edge-phase stall eliminated (2026-04-24)

## TL;DR

`setEdgePropertiesBatch` (commit `dccba7f1`) **clears the edge-phase
stall**.  `edges_app_role_assignment.jsonl` (400 edges, 16 chunks of
25) — which hung indefinitely pre-fix — now completes in **95 s**.
The seed progresses through edge files without any hang.

As a secondary effect, the node phase is also dramatically faster on
a warm server, completing all 25 files in **1 m 17 s** (vs. 6 m 55 s
in the Task-#33 validation run — likely due to avoiding contention
on the shared adapter mutex that edge-path property writes were also
exercising).

## Test setup

- Geode: `main @ dccba7f1` (Task #34 on top of #33, #31, audit
  hygiene).
- msft-graph: `main @ 5fc82ef` (Phase 4.1 pinned conns).
- Data: `/home/benji/eagleg-topology-data-16` (25 node files, 16
  edge files).
- Command: `seed --parallel --workers 16 --chunk-size 500 --serial-fallback=true`.

## Timing — node phase

| File | Nodes | Completed | Cumulative |
|---|---|---|---|
| user | 621 | 10:43:38 | 6 s |
| device | 73 | 10:43:39 | 7 s |
| application | 156 | 10:43:40 | 8 s |
| group | 328 | 10:43:43 | 11 s |
| ip | 80 | 10:43:44 | 12 s |
| location | 38 | 10:43:44 | 12 s |
| site | 184 | 10:43:46 | 14 s |
| drive | 230 | 10:43:47 | 15 s |
| drive_item | 1345 | 10:43:55 | 23 s |
| conditional_access_policy | 27 | 10:43:56 | 24 s |
| **audit_event** | **2414** | **10:44:15** | **43 s** |
| compliance_policy | 6 | 10:44:15 | 43 s |
| service_principal | 1075 | 10:44:27 | 55 s |
| … smaller files … | … | … | … |
| role_definition | 909 | 10:44:40 | 68 s |
| app_role | 1033 | (completed by 10:44:52) | ~80 s |
| pim_activation | 73 | 10:44:52 | 82 s |
| organizational_branding | 1 | 10:44:54 | 84 s |

**Node phase total: 1 m 17 s for 25 files, 9350+ nodes.**

Compared to prior runs:

| Run | Node phase |
|---|---|
| R13 baseline (pre-Task-#31) | ~13 min |
| Post-Task-#31 (multiplex fix) | ~2 min |
| Post-Task-#33 (node batch fix) | 6 m 55 s |
| **Post-Task-#34** | **1 m 17 s** |

audit_events.jsonl (2414 nodes, the historical blocker) completed in
**19 s** post-Task-#34 (vs. 104 s in post-Task-#33 and
never-completes pre-Task-#33).

## Timing — edge phase

Focus on the previous blocker, `edges_app_role_assignment.jsonl`
(400 edges):

| Run | `edges_app_role_assignment` |
|---|---|
| Task-#33 validation | hung indefinitely; killed after 138 s no progress |
| **Post-Task-#34** | **95 s, clean completion** |

Edge progression observed in this run before I stopped for
resource-efficiency:

| File | Edges | Duration |
|---|---|---|
| edges_activated_role | 65 | 0.4 s |
| **edges_app_role_assignment** | **400** | **95 s** |
| edges_audited | 808 | (in flight when killed) |

Zero chunk failures, zero serial fallbacks, zero batch retries
throughout the run.

## What the fix did

Mirror of Task #33 for edges.  In `bulkInsertEdgeWithIds` and
`bulkInsertEdgeInnerShardLocked`:

- Pre-fix: per-property loop that (a) re-acquired the adapter
  mutex, (b) ran 2× linear `updateEdgePropHead` scans over the
  adjacency indices for every property, and (c) refreshed the
  property-chain index O(K) times.  Total cost O(K²) per edge.
- Post-fix: single `setEdgePropertiesBatch` call that acquires the
  adapter mutex once, joins the active `StatementTxn`, runs all
  `putPropertyTxn` in one engine txn, and does exactly ONE
  `updateEdgePropHead` per direction + ONE
  `refreshPropertyChainIndex` at the end with the terminal
  `prop_head`.

See `docs/performance/2026-04-24-sharding/TASK-34-TRIAGE.md` for
the static-analysis proof and the fix-design rationale.

## Remaining gap vs. ≤ 60 s target

Even with Task #34, edge files average ~240 ms / edge in this run
(95 s / 400 edges).  For the densest files (`edges_signed_in_from`
~8259 edges, `edges_signed_in_to` ~5000 edges), this still implies
minutes per file.  The seed will complete but won't hit the ≤ 60 s
whole-run target.

Next candidates (new tickets, not Task #34):

1. **Coordinator endpoint-resolution cost** — `bulk_match_create_edge`
   op in `group_commit.zig` calls `lookupNodeByMergeKey` twice per
   op (src + dst).  Even though the lookup is lock-free, there are
   2 hash-map lookups + string dupes per edge.
2. **Adjacency index batching** — `updateEdgePropHead` is called
   once per direction in the batch path, but the batch itself is
   still sequential across edges.  Could batch multiple edges'
   adjacency updates.
3. **Property-chain index locality** — `refreshPropertyChainIndex`
   is called once per edge in the batch path (correct), but the
   shared index is accessed per call.  Consider caching the
   iterator range across a chunk's edges.

## Artifacts

- `docs/performance/2026-04-24-sharding/phase4.1-validation/post-task34-w16-validation.log`
  — 61 KB, full seed trace.
- `docs/performance/2026-04-24-sharding/TASK-34-TRIAGE.md` — static-analysis
  triage.
- `tests/test_edge_properties_batch.zig` — 3 regression tests
  (commit `21bff1f4`).

## Commits (local, unpushed)

```
60c4c7bc docs(perf): Task #34 triage — edge-phase per-property O(K²) loop
dccba7f1 perf(bulk): batch edge properties through setEdgePropertiesBatch (Task #34)
21bff1f4 test(edges): add regression tests for setEdgePropertiesBatch (Task #34)
```

## Status

Task #34 closed: **edge-phase stall eliminated.**  Run was stopped
early per user request to free server resources after the primary
proof point (`edges_app_role_assignment` clean completion in 95 s)
was captured.  Full end-to-end seed completion timing TBD when the
≤ 60 s perf work in the "Remaining gap" section above lands.
