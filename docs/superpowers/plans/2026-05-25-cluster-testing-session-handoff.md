# Distributed Cluster Testing — Session Handoff (2026-05-25)

> **Resume protocol:** read this top-to-bottom, then `git log --oneline -10 feat/distributed-cluster-testing` to see the latest commits, then load the task list (`/tasks` or via TaskList tool). The plan at `docs/superpowers/plans/2026-05-25-geode-distributed-cluster-testing.md` is the long-form document; this is the executive summary + what's blocking.

## What landed this session

| Commit | Summary | Tasks |
|---|---|---|
| `3332be51` | feat(cli): add --cluster-port and --peers server flags | A1 |
| `92a84bc3` | feat(distributed): extend ClusterCoordinator.Config with cluster bootstrap fields | A3, A3b, A3c |
| `8a84c542` | feat(server): boot ClusterCoordinator from GEODE_CLUSTER_TOKEN | A2, A4 (init-only — see blocker) |

Net diff vs branch root: 9 files changed, ~700 insertions. Branch: `feat/distributed-cluster-testing`.

All three commits are green: `zig build test` exits 0, 6/6 cluster_bootstrap tests pass, 4/4 cluster_coordinator_config tests pass, 5/5 cli_args_cluster tests pass.

## The hard blocker

**`maybeStart` in `src/server/cluster_bootstrap.zig` calls `coord.init()` only, NOT `coord.start()`.**

Calling `start()` forces Zig to analyze the full background-loop call chain (raftLoop / networkLoop / healthLoop / replicationLoop), which reaches `src/proto/raft_schema.zig::RaftCommand` — a `union(enum)` used as a protobuf submessage in `RaftLogEntry.command`. The in-tree protobuf-0.1.3 library hits `@compileError` at `protobuf.zig:713` and `wire.zig:704` because it rejects `union(enum)` as a submessage type. There is no escape hatch in the library.

**Consequence:** `GEODE_CLUSTER_TOKEN=t GEODE_NODE_ID=1 ./zig-out/bin/geode serve` currently logs `[startup] Cluster coordinator started node_id=1 cluster_port=14242` but the coordinator is dormant — no Raft, no peer comm, no replication. Every subsequent test (multi-node smoke, WAL distribution, sharding routing, leader failover) is blocked on this.

### Fix options for A4b (task #18)

| Option | Effort | Risk |
|---|---|---|
| **(a) Refactor `RaftCommand` from `union(enum)` to struct with discriminator tag** | ~2-4 hr | Touches raft_schema.zig, raft_consensus.zig, raft_apply.zig, cluster.zig consumers. Test-driven, surgical. **Recommended.** |
| (b) Patch protobuf library to accept union submessages | ~1 day | Touches vendored dep; affects every project using it; possibly rejected upstream. |
| (c) Replace protobuf library with one that supports unions | ~2-3 days | Massive blast radius. |

**Recommendation:** start with (a). Audit `RaftCommand` consumers first, then design a struct shape that preserves wire compatibility (oneof-style: one bool tag + one optional payload per variant).

## Task status at session end

```
COMPLETED:
  #1  A1: Add --cluster-port and --peers CLI flags
  #3  A3: Extend ClusterCoordinator.Config
  #12 A3b: Fix networkLoop hardcoded port
  #13 A3c: Make initNetworkTransport honor Config
  #2  A2: Create src/server/cluster_bootstrap.zig
  #4  A4: Wire cluster_bootstrap into main.zig (INIT-ONLY)

BLOCKED ON #18:
  #18 A4b: Resolve protobuf union-as-submessage compile error  ← UNBLOCK FIRST
  #19 A4c: Call coord.start() from maybeStart
  #5  A5: In-process 3-node replication smoke test
  #6  A6: Subprocess 3-node cluster smoke test
  #14 A3d: Public proposeWrite/applyCommand API
  #15 A3e: forwardToShard cross-node reads
  #16 A3f: auth_token validation on accept
  #7  A7: SHOW CLUSTER STATUS GQL surface
  #8  A8: Verify Raft apply → graph_store wiring
  #20 W1: Per-node WAL writes during Raft apply               (NEW from user ask)
  #21 W2: WAL replay → cluster catch-up                       (NEW)
  #22 W3: WAL HMAC chain across cluster nodes                 (NEW)
  #23 S1: consistent_hash sharding distribution               (NEW)
  #24 S2: Cross-shard read forwarding                         (NEW)
  #25 S3: Shard rebalancing on node add/remove                (NEW)
  #26 S4: Sharding + replication_factor interaction           (NEW)
  #9  Phase B: Harness cluster orchestration (B1-B5)
  #10 Phase C: Multi-node correctness specs (C1-C17)
  #11 Phase D: Iterate /codepros:bug-fix to 100% pass
```

## User-added scope (this session)

> "make sure the cross-cluster WAL and sharding are working properly as well and ensure there are full unit tests and integration tests to verify"

Added as tasks W1–W3 (WAL) and S1–S4 (sharding). All are blocked on A4b.

## Realistic effort estimate

- **A4b** alone: 2-4 hours of focused Zig work + multiple build/test cycles
- **Remaining Phase A (A4c, A3d-f, A5-A8)**: 2-3 days of subagent dispatches with reviews
- **W1-W3, S1-S4**: 3-5 days (heavily depends on whether sharding actually routes today or just stores everywhere)
- **Phase B (harness)**: 1 day
- **Phase C (17 multi-node specs)**: 2-3 days
- **Phase D (bug-fix loop until 100%)**: indeterminate — likely 5-15 days depending on how many real distributed bugs exist

**Total: 2-4 weeks of focused work to satisfy the "100% pass on 1/3/5/10 nodes with cross-cluster WAL + sharding" goal.**

This is not achievable in a single Claude Code session. Plan for incremental delivery with PRs grouped by phase.

## Suggested next session opening

```
You are resuming the distributed cluster testing initiative.
Branch: feat/distributed-cluster-testing  (3 commits ahead of main)
Read: docs/superpowers/plans/2026-05-25-cluster-testing-session-handoff.md
Plan: docs/superpowers/plans/2026-05-25-geode-distributed-cluster-testing.md
The blocker is task #18 (A4b: protobuf union-as-submessage).
Use the protobuf compile error in src/proto/raft_schema.zig::RaftCommand as
the entry point. Recommended approach: refactor RaftCommand from union(enum)
to a struct with explicit discriminator (oneof-style).
```

## Pre-existing state notes (already in auto-memory)

- `systemd user@1000 LimitNOFILESoft=1024` — multi-node testing on this host needs `ulimit -n 65536` or geode's self-raise (commit `1a7ab7e3`) to handle 3+ nodes × 16 shards × 11 FDs/graph.
- The harness already has `cluster.py` orchestration scaffolding — it works to spawn N processes but readiness is just "QUIC listens" today.
- CLAUDE.md notes single-tenant production readiness only. Multi-node was always known to be partial; the GAP-0514 entry tracks this.
