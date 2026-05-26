# Distributed Cluster Testing — Session Handoff (2026-05-25)

> **Resume protocol:** read this top-to-bottom, then `git log --oneline -10 feat/distributed-cluster-testing` to see the latest commits, then load the task list (`/tasks` or via TaskList tool). The plan at `docs/superpowers/plans/2026-05-25-geode-distributed-cluster-testing.md` is the long-form document; this is the executive summary + what's blocking.

## What landed this session

| Commit | Summary | Tasks |
|---|---|---|
| `3332be51` | feat(cli): add --cluster-port and --peers server flags | A1 |
| `92a84bc3` | feat(distributed): extend ClusterCoordinator.Config with cluster bootstrap fields | A3, A3b, A3c |
| `8a84c542` | feat(server): boot ClusterCoordinator from GEODE_CLUSTER_TOKEN | A2, A4 (init-only at the time) |
| `d4ed43f6` | docs: distributed cluster testing plan + session handoff | — |
| `e08bc896` | fix(distributed): RaftCommand oneof refactor unblocks coord.start() | A4b, A4c |
| `4050f120` | fix(distributed): heap-allocate RaftNode storage to fix UAF | A4d |
| `f493bc70` | test+fix(distributed): in-process 3-node leader election | A5 |
| `7f6cc672` | fix(distributed): drainReady dispatches Ready.messages via wrapper transport | A5b |
| `02f52c93` | test+fix(distributed): subprocess 3-node smoke + cluster QUIC infrastructure | A6 (test skipped — see below) |
| `af0db97a` | fix(distributed): unblock cluster raft transport (A6b partial) | A6b (auth-token panic + QUIC FIN flush) |

Net diff vs branch root: 15 files changed, **2816 insertions, 77 deletions**. Branch: `feat/distributed-cluster-testing`.

All six commits are green: `zig build test` exits 0. 1702/1703 tests pass (1 pre-existing skipped).
- 5/5 cli_args_cluster tests
- 4/4 cluster_coordinator_config tests
- 6/6 cluster_bootstrap tests
- 8/8 raft_command_refactor tests

**Manual smoke (single-node cluster mode):**
```bash
GEODE_CLUSTER_TOKEN=test GEODE_NODE_ID=1 GEODE_CLUSTER_PORT=14242 \
  ./zig-out/bin/geode serve --listen-quic 127.0.0.1:13141
```
- Logs `[startup] Cluster coordinator started node_id=1 cluster_port=14242 cluster_name=geode-cluster`
- Background loops run productively (raft advance + ready + tick all succeed)
- QUIC listens on both cluster port (14242) and client port (13141)
- Process exits cleanly on SIGTERM
- 0 "raft advance error" / "ReadyNotAdvanced" log lines

**This is the first time in the project history that geode actually runs cluster code.**

## The hard blocker (RESOLVED)

The protobuf union-as-submessage compile error described below was **fixed** in commit `e08bc896` (A4b). The follow-on storage UAF was **fixed** in `4050f120` (A4d). Single-node cluster mode now runs end-to-end.

The next blocker (multi-node, not single-node) is implementing peer dialing + leader election with peers — see "Next blocker" section below.

## Next blocker (after this session)

**Task A6c: persistent per-peer QUIC connection pool.** The subprocess 3-node test (A6 commit `02f52c93`, gated behind `RUN_SUBPROCESS_CLUSTER_TEST=1`) currently fails at leader election. A6b fixed the auth-token Invalid-free panic and added QUIC FIN/poll flush. Connections now form, raft enters candidate state, frames are sent — but the receiver hits `InvalidInput|WouldBlock` because every raft message opens a fresh TLS+QUIC handshake and tears it down ~10ms later, racing the receiver's `cluster_poll_pool` drain cycle.

Fix is structural: replace `raft_consensus.Transport.send`'s one-connection-per-RPC pattern with a persistent per-peer connection (long-lived QUIC connection per remote node_id, raft messages multiplexed as streams). This is how production raft systems work and will also eliminate the `connection_pool` semaphore pressure described at `cluster.zig:614`.

## Previous next-blocker (HISTORICAL — multi-node now demonstrably starts)

Multi-node mode (3+ processes forming a cluster) is no longer purely hypothetical:

1. **A5: in-process 3-node smoke** — spin up 3 ClusterCoordinator instances on loopback, verify leader election within 5s, verify writes replicate. This is now possible (Raft progresses) but requires the test to actually wire 3 coordinators with shared cluster_token and proper peer lists.
2. **A6: subprocess 3-node smoke** — spawn 3 `./zig-out/bin/geode serve` processes, verify cluster forms. May surface real bugs in peer dialing (`network_transport.zig` is heavy QUIC code that's never been exercised in practice).
3. **A3d: public proposeWrite API** — needed so tests can submit writes and observe replication.
4. **A3e: forwardToShard** — `cluster.zig:1446` still returns `Response{ .status = .OK }` without forwarding. Cross-shard reads silently no-op.
5. **A3f: auth_token validation** — config has cluster_token but accept() doesn't gate on it yet.

## The hard blocker (HISTORICAL — for context)

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
COMPLETED (8 tasks, 6 commits):
  #1  A1  Add --cluster-port and --peers CLI flags
  #3  A3  Extend ClusterCoordinator.Config
  #12 A3b Fix networkLoop hardcoded port
  #13 A3c Make initNetworkTransport honor Config
  #2  A2  Create src/server/cluster_bootstrap.zig
  #4  A4  Wire cluster_bootstrap into main.zig
  #18 A4b Resolve protobuf union-as-submessage compile error
  #19 A4c Call coord.start() from maybeStart
  #28 A4d Heap-allocate RaftNode storage to fix UAF

PENDING (multi-node + cross-cluster features):
  #5  A5  In-process 3-node replication smoke test
  #6  A6  Subprocess 3-node cluster smoke test
  #14 A3d Public proposeWrite/applyCommand API
  #15 A3e forwardToShard cross-node reads (currently no-op)
  #16 A3f auth_token validation on accept
  #7  A7  SHOW CLUSTER STATUS GQL surface
  #8  A8  Verify Raft apply → graph_store wiring
  #20 W1  Per-node WAL writes during Raft apply              (USER-ADDED)
  #21 W2  WAL replay → cluster catch-up                      (USER-ADDED)
  #22 W3  WAL HMAC chain across cluster nodes                (USER-ADDED)
  #23 S1  consistent_hash sharding distribution              (USER-ADDED)
  #24 S2  Cross-shard read forwarding                        (USER-ADDED)
  #25 S3  Shard rebalancing on node add/remove               (USER-ADDED)
  #26 S4  Sharding + replication_factor interaction          (USER-ADDED)
  #9  Phase B: Harness cluster orchestration (B1-B5)
  #10 Phase C: Multi-node correctness specs (C1-C17)
  #11 Phase D: Iterate /codepros:bug-fix to 100% pass
```

## Recommended next-session start

```
You are resuming the distributed cluster testing initiative on branch
feat/distributed-cluster-testing (6 commits ahead of main).

Single-node cluster mode now works end-to-end (commits 3332be51 → 4050f120).
The next milestone is multi-node — start with task #5 (A5: in-process 3-node
smoke). It's now unblocked because Raft makes real progress.

Read in order:
  1. docs/superpowers/plans/2026-05-25-cluster-testing-session-handoff.md (this file)
  2. docs/superpowers/plans/2026-05-25-geode-distributed-cluster-testing.md (full plan)
  3. Latest commit messages on the branch (each closes specific tasks)

The user-added W1-W3 (WAL cross-cluster) and S1-S4 (sharding cross-cluster)
work is best tackled AFTER A5/A6 prove multi-node actually works — those
tests will surface the real gaps in network_transport.zig peer dialing
and consistent_hash routing.
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
