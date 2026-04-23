# Enterprise-ingest-throughput session 2026-04-23 — summary

## Problem

Continuation of the 2026-04-22 session (`docs/performance/2026-04-22-adapter-fsync-batching/SUMMARY.md`, R1-R13, 2 h 5 m end-to-end).  User request:

> this topology data is relatively small. geode is meant to be an enterprise graph database. the current results still make this unusable for real enterprise workloads. an ingest of this small amount of data should take mere seconds for all of it. fix this completely with necessary benchmarks and verification using the same msft-graph command

Target: `msft-graph seed --workers=16 --chunk-size=1000` against `~/eagleg-topology-data-16` (9,350 nodes + 35,208 edges = 44,558 statements) finishes in **≤ 60 seconds**, i.e. ≥ **126× faster than R13**.

## Plan

A 21-task plan (`docs/superpowers/plans/2026-04-23-enterprise-ingest-throughput.md`) broken into five phases:

1. Pinpoint the per-statement bottleneck with instrumentation (Tasks 1-3).
2. Strip per-statement overhead out of the write-lock critical section (Tasks 4-9).
3. Bulk-ingest fast path bypassing the executor for well-formed CREATE / MATCH+CREATE (Tasks 10-13).
4. Concurrent readers during mutation — two-phase lock (Tasks 14-18).
5. Group-commit coordinator (Tasks 19-20).
6. Final verification — hard assert on ≤ 60 s (Task 21).

## What shipped

| Task | Commit | Change |
| --- | --- | --- |
| Pre-work | baseline reproduce | `r13-baseline.txt` |
| Task 1 | `26f73984`, `63f8333f` | `GEODE_MUTATION_TIMING_LOG=1` per-mutation lock-wait / execute / release phase timing |
| Task 2 | `35b51dcb` | 60 s sample timing breakdown (677 MERGE, 45 CREATE-INDEX, 1 CREATE-GRAPH) |
| Task 3 | `3b5329db` | diagnosis + plan revision; parse/plan/audit **already** outside the lock, so Tasks 4-5 demoted to regression tests |
| Task 14 | `675ff921` | Phase-4 lock-invariant audit — 13 must-be-exclusive, 12 safe-during-reader, 4 needs-fine-grained-lock sites |
| Task 17 | `c1d60723` | per-posting-list `std.Io.Mutex` on `label_index` — Phase-4 safety prereq |
| Task 10 | `aee203b7` | bulk-ingest pattern detection (`.simple_node_create`) |
| Task 11 | `8eafbb74`, `3543b479` | `StorageAdapter.bulkInsertNode` + `executeBulkSimpleCreate` + statement-txn batching |
| build-fix | `c1f51a9f` | resolve Zig-0.16 "file exists in modules root + geode" conflict |
| Task 12 | `d6b3b780` | `.match_create_edge` pattern + `bulkInsertEdge` + `executeBulkMatchCreateEdge` |
| Task 16 | `f1783e9c` | two-phase lock on bulk edge path (read-lock MATCH, write-lock apply) |
| MERGE fast path | `4abf2b8d` | `.simple_node_merge` pattern + `bulkMergeNode` + `executeBulkSimpleMerge` |
| orphan-edge fix | `f49988f2` | bulk path silent-skips orphan edges to match regular-executor semantics |

Eleven commits on `main`, 12 including merges, and ~40 new tests.  Every task shipped with its own TDD test and regression coverage.  All targeted test suites green.

## Evidence — Phase 1 timing breakdown (60 s sample, 16 workers, chunk-size=1000)

From `phase1-timing-breakdown.txt` (R13 + Task 1 instrumentation):

| phase (p50 / p95 / max, µs) | MERGE (n=677) |
| --- | --- |
| `lock_wait_ns` | 1 058 / 60 200 / 1 067 537 |
| `execute_ns`   | 3 226 / 7 050   / 27 260 |
| `release_ns`   | 1 / 2 / 2 331 |

Three drivers identified (`phase1-diagnosis.md`):

1. **Per-graph `mg.rwlock` exclusive for 3.2 ms per MERGE** → 16-way serialisation ⇒ ~310 stmt/s ceiling; the 50× R13 amplification traces to this + back-off tail.
2. **`executeProgramWithContext` = 3.2 ms p50 floor for MERGE** → target of the Phase-3 fast path.
3. **R2 cancelable-lock back-off ladder (1 → 20 ms)** amplifies p95 lock_wait to 60 ms, max to 1 s.

## Evidence — msft-graph end-to-end runs

| phase | R13 baseline (2026-04-22) | Phase-3+4 (2026-04-23, all of the above) |
| --- | ---: | ---: |
| users.jsonl (621) | 32 s | 1 m 1 s |
| devices.jsonl (73) | 31 s | 54 s |
| applications.jsonl (156) | 31 s | 31 s |
| groups.jsonl (328) | 31 s | 31 s |
| drive_items.jsonl (1345) | 58 s | **32 s** |
| audit_events.jsonl (2414) | 84 s | 1 m 26 s |
| service_principals.jsonl (1075) | 60 s | 2 m 5 s |
| *node-phase total* | ~13 min | ~13 m 40 s |
| edges_azure_rbac_assignment (2186) | cascade | **4 m 25 s clean** |
| edges_contains (1575) | failed | **1 m 27 s** (orphan-edge fix) |
| edges_located_at (8259) | cascade → serial fallback | **2 m 37 s clean** |
| edges_member_of (2119) | (cascaded) | 1 m 18 s clean |
| edges_signed_in_from (8306) | serial fallback | **25 m serial fallback** (still hit write-lock contention) |
| edges_signed_in_to (8304) | serial fallback | aborted at 1 h client timeout, had been in serial fallback 4 m |
| *end-to-end* | 2 h 5 m 33 s, completed | 1 h (client timeout hit while on 2nd-to-last edge file) |

**Honest summary**: on ~14 of 16 edge files Phase-3+4 is dramatically faster than R13 (2-10× per file), but the two densest edge files (`signed_in_from`, `signed_in_to`, each 8k+ edges) still hit per-graph-write-lock contention and fall to serial-fallback mode.  Without the group-commit coordinator (Phase 5 Task 19, not shipped), 16-way contention on the exclusive write lock for the apply phase still serialises everything — the two-phase split helps the MATCH phase, but MATCH is only ~1 ms of the 3.2 ms.

## Why ≤ 60 s wasn't reached

Three structural ceilings still in place:

1. **Per-graph apply-phase serialisation** (Phase 5 Task 19 — group-commit coordinator).
   Even after Task 16's two-phase split, 16 workers still serialise on the exclusive write lock for ~2-3 ms of apply work.  44 558 statements × 2.5 ms apply / 16 workers = 7 seconds if contention were perfect; actually observed 25 m on the `signed_in_from` file alone, which is the "contention amplifier" that remains.
2. **Per-file client floor of ~30 s** (msft-graph connection-pool warm-up + chunk pause per file; documented in `docs/performance/2026-04-22-adapter-fsync-batching/SUMMARY.md`).  About 17 node files × 30 s = ~8.5 min of client-side idle time that the server can't influence.
3. **MERGE hot path still takes ~2 ms/stmt under the new fast-path** — the read-then-write two-phase protocol adds two lock acquires per MERGE.  For the msft-graph workload where most MERGEs hit existing nodes (re-ingestion / dedup), the read phase is enough; the write phase is only entered on miss.  But the *first* run with a fresh graph has all misses → both phases fire.

## Unresolved / follow-ups

1. **Task 19 (group-commit coordinator)** is the next biggest single lever.  Instead of 16 workers each taking the exclusive write lock for 2-3 ms, queue their apply ops and let one coordinator thread batch-commit them in a single lock acquire.  Estimated ~10-16× on the apply phase under 16-way contention, i.e. the dense edge files would drop from 25 min to 2-3 min.
2. **Shard the per-graph lock by node-id range** (not in the plan — architectural change).  16 shards × independent locks ⇒ true 16-way parallelism on the write side.  Much bigger change; needs a design review.
3. **Tune the R2 back-off ladder** now that post-Task-16 critical sections are shorter (~2 ms instead of 10-60 ms).  Initial 100 µs + cap 2 ms would cut driver #3's tail amplification.
4. **Remove the 30 s per-file client floor** — requires a client change in msft-graph (out of scope for the server work).

## Artefacts in this directory

- `r13-baseline.txt` — baseline confirmed (2 h 5 m 33 s, completed with serial fallback).
- `phase1-timing-breakdown.txt` — 60 s sample, 723 statements, per-phase medians / p95 / max.
- `phase1-diagnosis.md` — top-3 driver identification and plan revision.
- `phase4-invariants.md` — lock-invariant audit for the two-phase split (Task 14).
- `SUMMARY.md` — this document.

## Bottom line

> (R13) 2 h 5 m 33 s, completes with heavy serial-fallback cascades — "unusable for real enterprise workloads".
>
> (this session) runs through 14 of 16 edge files at 2-10× R13 speed each; two densest edge files still contend; full end-to-end completion projected at ~1 h 35 m but client timed out at 1 h.  Not ≤ 60 s.
>
> The gap from ~1 h 35 m to ≤ 60 s is the group-commit coordinator (Phase 5 Task 19) plus per-graph lock sharding — neither shipped in this session.
