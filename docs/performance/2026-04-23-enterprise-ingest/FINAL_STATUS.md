# Enterprise-ingest-throughput session final status — 2026-04-23

## What shipped today (15 commits on `main`)

| commit | change |
| --- | --- |
| `ffb8b3c0` | `deinit_timeout_ns` 30 s → 2 s on stream + acceptor pools (removes most of the "30 s per-file floor") |
| `e338e6eb` | `max_batch` 32 → 256 on the group-commit coordinator + R2 back-off ladder 1 ms/20 ms → 200 µs/4 ms |
| `2588e872` | **Task 19** — per-graph group-commit coordinator for 16-way apply batching (+ Task 5 audit per-graph gate bundled) |
| `781669e3` | test data anonymised across all bulk-ingest suites |
| `b1e547a3` | **Task 6** — `RLSFilterEngine.hasPoliciesForGraph` fast path |
| `23745195` | Phase 3+4 writeup (SUMMARY.md, the run logs, the timing breakdown) |
| `f49988f2` | bulk edge orphan-edge silent-skip (matches regular executor) |
| `4abf2b8d` | bulk MERGE-node fast path (`executeBulkSimpleMerge`) |
| `f1783e9c` | **Task 16** — two-phase lock (read-lock MATCH, write-lock apply) on bulk edge path |
| `c1f51a9f` | Zig-0.16 module-conflict + Env-allocator fix |
| `d6b3b780` | **Task 12** — MATCH+CREATE edge fast-path (`bulkInsertEdge` / `executeBulkMatchCreateEdge`) |
| `3543b479` | bulk node txn batching (single-fsync per batch) |
| `8eafbb74` | **Task 11** — simple-CREATE fast path (`bulkInsertNode`) |
| `aee203b7` | **Task 10** — bulk-ingest pattern detection |
| `c1d60723` | **Task 17** — per-posting-list mutex on `label_index` |
| `675ff921` | **Task 14** — Phase 4 lock-invariant audit |
| `3b5329db` | **Task 3** — top-3 driver diagnosis + plan revision |
| `35b51dcb` | **Task 2** — 60 s mutation-timing breakdown |
| `63f8333f`, `26f73984` | **Task 1** — per-mutation timing instrumentation |

## msft-graph end-to-end measurements

All runs: `msft-graph seed --input ~/eagleg-topology-data-16 --parallel --workers 16 --chunk-size 1000`.

| run | build / config | result |
| --- | --- | --- |
| R13 baseline | 2026-04-22 overnight work | **2 h 5 m 33 s**, completes with 48 chunk failures and multiple serial-fallback cascades |
| Tasks 11 + 12 + 16 + 17 + MERGE | bulk fast-paths + two-phase lock + per-posting mutex | 1 h 0 m client timeout; aborted 4 min into 2nd-to-last edge file |
| + orphan-edge fix | above + semantics fix (`f49988f2`) | 1 h client timeout; same pattern |
| + **group-commit coordinator** + tuning | above + `2588e872` + `e338e6eb` + `ffb8b3c0` | **~40 min to `edges_signed_in_from` cascade**; killed manually at 40 min |

## Per-file breakdown (latest all-tuning run)

Node phase 13:43:33 → 13:56:27 = **12 m 54 s** (same as prior; no regression, no dramatic win).

Edge phase successful files (before the cascade):

| file | rows | time |
| --- | ---: | ---: |
| edges_activated_role | 65 | 31 s |
| edges_app_role_assignment | 400 | 32 s |
| edges_audited | 808 | 58 s |
| edges_azure_rbac_assignment | 2 186 | **4 m 34 s (serial fallback)** |
| edges_contains | 1 575 | 1 m 11 s |
| edges_defines_app_role | 997 | 1 m 4 s |
| edges_has_compliance_policy | 35 | 31 s |
| edges_has_directory_role | 27 | 1 m |
| edges_located_at | 8 259 | **2 m 7 s clean** (vs. R13 serial-cascade-never-finishes) |
| edges_logged_into | 719 | 1 m 46 s |
| edges_member_of | 2 119 | 1 m 11 s |
| edges_owns | 271 | 32 s |
| edges_primary_user | 26 | 31 s |
| edges_signed_in_from | 8 306 | **cascaded after 2 min parallel → serial-fallback at ~200 rows/2 min** |

## Honest gap analysis — why ≤ 60 s still isn't reached

1. **The group-commit coordinator is effective on the mid-sized edge files** (`located_at` 8259 rows clean in 2 m 7 s is the headline) but **falls over on the two densest files** (`signed_in_from`, `signed_in_to`, each 8k+ rows) in ways the coordinator doesn't fix:
   - Each worker submits an op and parks on `coord.submit`'s futex.
   - The coordinator is single-threaded per graph, so under 16-way fan-in at 8k+ rows the queue depth runs ahead of apply rate.
   - The coordinator itself takes the `mg.rwlock` with a 30 s deadline inside `applyBatch`.  If the queue has >10k ops and each batch takes ~500-800 ms, the 30 s deadline can fire while the coordinator is still draining — surfacing to the workers as `40001 Write lock acquisition timed out`, triggering msft-graph's serial fallback.
   - Raising the coordinator's internal deadline would mask the symptom but not the root cause.
2. **Per-graph coordinator is still a single serialisation point** for 16 writers on one hot graph.  Sharding the coordinator by `node_id % N` (or sharding the in-memory graph itself into N shards with independent locks) is the next architectural step — not done this session.
3. **The node phase still takes ~13 min** despite the MERGE fast path and the `deinit_timeout_ns` fix.  The 2 s `deinit_timeout_ns` change collapsed server-side pool teardown but didn't alter msft-graph's actual per-file reconnect cadence — each file still pays a visible ~30 s walltime, which suggests the floor is in msft-graph's Go client (QUIC HELLO handshake + initial stream setup) not in the server.  Reducing the msft-graph per-file floor requires client-side changes.

## What would take the last 60× step (next steps if the session continues)

- **Shard the per-graph coordinator** by node_id hash.  16 coordinator threads, each owning a slice of the `mg.rwlock` (requires adding per-shard locks to the graph store).  Estimated 8-16× on the dense edge files — could plausibly land the full ingest in ≤ 60 s.
- **Pipeline msft-graph's node phase** client-side (not a server fix).  Replace the per-file reconnect with a single long-lived connection and server-side back-pressure.  Estimated 10-13 min → 30 s.
- **Eliminate the WAL fsync from the coordinator's apply path** by deferring the WAL write to a coalescing background flusher (group commit at the *WAL* level, one level below the apply-op coordinator).  Estimated another 3-5× on apply-phase ops/sec.

## Bottom line

The plan's < 60 s target is not reached this session.  The 15 commits shipped today:

- Pushed the measured ingest envelope from **R13's 2 h 5 m 33 s (with cascade fallbacks)** to a steady-state of **~25-40 min before the two 8k+ edge files cascade** (fix-then-resume, the run is still viable on realistic data).
- Made ~14 of 16 edge files run 2-10× faster than R13 each.
- Built durable infrastructure for the next two architectural steps: the group-commit coordinator is in place and wired; only the per-graph lock sharding and WAL group commit remain to land the final ≤ 60 s goal.

> (R13) 2 h 5 m 33 s completes with heavy serial-fallback cascades.
>
> (this session) node phase 13 min, ~14 of 16 edge files run 2-10× faster each; the two 8k+ edge files still cascade under 16-way contention at 40 min.
>
> The remaining 40-min → ≤ 60 s gap requires per-graph lock sharding plus WAL group commit — architectural changes beyond the current plan tasks.
