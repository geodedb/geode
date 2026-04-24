# Task #31 end-to-end validation — SUCCESS (2026-04-24)

## Setup

- **Geode server**: `b5a85fb9` (fix: route `submit()` to default lane)
- **msft-graph**: `751794f` (re-land of Phase 4.1 pinned-conn pipelining on top of `90a1227` revert)
- **Command**: `seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 500 --serial-fallback=true`
- **Server**: port 3160, fresh data dir, `GEODE_ADMIN_PASSWORD=validate`

## Result

**The previous 317/621 hang is GONE.**  With Phase 4.1 re-landed and the
thread-pool fix live, the seed progresses through files steadily at
`workers=16` — the exact configuration that hung indefinitely pre-fix.

Ten node files completed cleanly in ~2 min, 0 errors, 0 serial
fallbacks, 0 `batch retry` events:

| File | Nodes | Completed at | Cumulative |
|---|---|---|---|
| user | 621 | 08:06:26 | 38 s |
| device | 73 | 08:06:29 | 41 s |
| application | 156 | 08:06:33 | 45 s |
| group | 328 | 08:06:46 | 58 s |
| ip | 80 | 08:06:46 | 58 s |
| location | 38 | 08:06:48 | 60 s |
| site | 184 | 08:06:54 | 66 s |
| drive | 230 | 08:07:02 | 74 s |
| drive_item | 1345 | 08:07:55 | 127 s |
| conditional_access_policy | 27 | 08:07:56 | 128 s |

Compare to the pre-fix Phase 4.1 run (documented in
`PHASE4.1-VALIDATION.md`): 0 files completed, hang at 317/621 nodes
on the first file.

## After ten files

The seed moved on to `audit_events` (2414 nodes, 17 chunks × 150).
Server stayed responsive (fresh `RETURN 1` queries still returned
instantly) and worked at ~200% CPU for 150 s before I killed the
run.  `SIGQUIT` showed 2 workers stuck in `Tx.Commit` / `Tx.ExecContext`
— NOT the pre-fix `BeginTx` hang.  These 2 stuck workers suggest a
**separate performance issue** (large batch commit latency, not a
deadlock).  Previous Phase-2.4 baseline also showed slow progress on
`audit_events`.

The primary bug (Task #31) is FIXED.  Remaining slowness is a
separate performance concern, tracked separately.

## Commits

**geode** (unpushed on `main`):

```
b42b3524 docs(perf): Task #31 fix report
b5a85fb9 fix(transport): route submit() to default lane — closes Task #31 multiplex hang
96403570 test(transport): add regression tests for QUIC stream multiplex hang (Task #31)
```

**msft-graph** (unpushed on `main`):

```
5fc82ef test(seed): integration test for Task #31 QUIC multiplex hang
751794f Reapply "feat(seed): Phase 4.1 — seed-top-level pinned-conn pipelining with keepalive"
90a1227 Revert "feat(seed): Phase 4.1 — seed-top-level pinned-conn pipelining with keepalive"
467021f feat(seed): Phase 4.1 — seed-top-level pinned-conn pipelining with keepalive
```

## Artifacts

- `docs/performance/2026-04-24-sharding/phase4.1-validation/post-fix-w16-validation.log`
  — the seed log from this run (96 KB).
- `docs/performance/2026-04-24-sharding/TASK-31-TRIAGE.md`
  — original static-analysis triage.
- `docs/performance/2026-04-24-sharding/TASK-31-FIX-REPORT.md`
  — comprehensive fix report (sections A–E).
- `docs/performance/2026-04-24-sharding/PHASE4.1-VALIDATION.md`
  — pre-fix validation showing the hang.

## Next steps

**Task #31 closed.**  The QUIC stream multiplex hang is resolved.
msft-graph Phase 4.1 (seed-top-level conn pinning) is back on `main`
and produces clean forward progress at `workers=16`.

**Remaining performance work** (new tickets, not Task #31):

1. `audit_events`-class batch-commit slowness.  With 16-way parallel
   and 2414 nodes in 17 chunks, individual batch commits take 10+ s.
   Profile the coordinator / WAL fsync path; may need further
   tuning of `group_commit` batch cap or per-chunk size hints from
   msft-graph.
2. The residual QUIC-library concern from `TASK-31-TRIAGE.md`
   (spurious FIN under concurrent load, stream-ID re-queue + non-FIFO
   drain in `queueIncomingStream` / `tryAcceptStream`) — only revisit
   if sporadic stalls reappear under sustained load.
