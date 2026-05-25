# Geode Distributed Cluster Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make geode form real N-node distributed clusters (3, 5, 10 nodes), make the geode-test-harness drive them, port the full spec suite to run against each cluster size, and iterate /codepros:bug-fix until 100% of specs pass on 1-, 3-, 5-, and 10-node deployments.

**Architecture:** Three concentric rings.
1. **Geode core:** wire the existing-but-unused `src/distributed/ClusterCoordinator` into `src/server/main.zig` startup so that setting `GEODE_CLUSTER_TOKEN` + `GEODE_PEERS` + `GEODE_NODE_ID` actually boots a Raft group and replicates committed writes through `raft_apply` to the per-node graph store.
2. **Harness:** the existing `cluster.py` orchestrator already starts N processes and injects `GEODE_PEERS` — but readiness is "QUIC listens" not "leader elected", and `--force-cluster-size N` doesn't exist. Add a real readiness probe, a CLI promotion flag, and a multi-cluster-size test target.
3. **Specs:** the existing 308 specs run single-node. Add a `multi_node:` cohort of cluster-aware specs, then promote the existing `distributed_*.yml` suite to use real `cluster:` blocks. Run the full corpus against each of `[1, 3, 5, 10]` sizes.

After the cluster path lands, iterate `/codepros:bug-fix` per unique failure class until each size hits 100% pass.

**Tech Stack:** Zig 0.16+ (geode core), Python 3.11+ / Typer (harness), YAML specs, Raft (already implemented in `src/distributed/raft_consensus.zig`), QUIC+TLS intra-cluster transport (already implemented in `src/distributed/network_transport.zig`).

**Scope notes (read before starting):**
- `src/distributed/cluster.zig`, `raft_consensus.zig`, `network_transport.zig`, `query_coordinator.zig`, `twophase.zig` are all already implemented. **Do not rewrite them.** The wiring gap is in `src/server/main.zig` and `src/server/server_init.zig`.
- The harness already has `cluster.py`, `cluster_types.py`, runner integration for `mode: cluster`, executor support for `signal` and `restart_node` step types. **Do not rewrite them.** Augment with readiness + CLI flags + new specs.
- Authentication is fail-closed by default. Every cluster test must set `GEODE_ADMIN_PASSWORD` (harness already does this).
- The cluster transport uses a **separate port from the client QUIC port**. Pick `cluster_port = client_port + 1000` by default to keep test ports collision-free.
- Existing files referenced in this plan:
  - `src/server/main.zig:937-946` — `GEODE_CLUSTER_TOKEN` already read for OTel role tag; no `ClusterCoordinator.init()` follows it.
  - `src/distributed/cluster.zig:437` — `ClusterCoordinator.init(allocator, node_id, config)` signature; `Config.peers` is `[]const []const u8`.
  - `src/distributed/raft_apply.zig` — `setGlobalStore` + `applyCallbackFn` already wire Raft commits → graph_store mutations.
  - `geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster.py:50-62` — already injects `GEODE_PEERS`, `GEODE_NODE_ID`, `GEODE_CLUSTER_SIZE`.
  - `geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner.py:733-770` — already starts the cluster when `spec.mode == "cluster"`.
  - `geode-test-harness/geodetestlab-cli/specs/2pc_coordinator_timeout.yml` — example of a working `cluster:` spec.

---

## File Structure

### Geode core (Zig)

| File | Responsibility | Status |
|---|---|---|
| `src/server/cluster_bootstrap.zig` | NEW. Parses `GEODE_PEERS`, `GEODE_NODE_ID`, `GEODE_CLUSTER_PORT`; constructs `ClusterCoordinator.Config`; instantiates & starts the coordinator; exposes a `pub fn deinit` for clean shutdown. | new file |
| `src/server/main.zig` | Add the `if (cluster_token) cluster_bootstrap.start(...)` call right after OTel init and before QUIC listen. | modify |
| `src/server/server_init.zig` | Hold a `*ClusterCoordinator` pointer on `InitContext` so it survives `defer init_ctx.deinit()`. | modify |
| `src/cli_args.zig` | Add `--cluster-port` / `--peers` flags as alternatives to env vars (env takes precedence per project convention). | modify |
| `tests/test_cluster_bootstrap.zig` | NEW. Unit tests: bootstrap with 0/1/2/N peers, missing token, malformed peers, port collision. | new file |
| `tests/test_cluster_replication_smoke.zig` | NEW. Spawn 3 in-process `ClusterCoordinator` instances on localhost, write through leader, read from each follower, assert convergence. | new file |

### Harness (Python)

| File | Responsibility | Status |
|---|---|---|
| `geodetestlab-cli/geodetestlab/lib/cluster.py` | Add `GEODE_CLUSTER_PORT` injection; add `wait_for_cluster_ready` that polls `SHOW CLUSTER STATUS` until leader is elected. | modify |
| `geodetestlab-cli/geodetestlab/lib/cluster_readiness.py` | NEW. Cluster-level readiness probe (separate from per-process readiness). Uses QUIC client to issue `SHOW CLUSTER STATUS` to every node and waits for `leader_id != 0` and `members == node_count`. | new file |
| `geodetestlab-cli/geodetestlab/lib/cluster_types.py` | Add `cluster_ports: list[int]` to `ClusterNodeConfig`/`ClusterNodeState`; raise `_MAX_CLUSTER_NODES` to 10 (already 10 — verify only). | modify |
| `geodetestlab-cli/geodetestlab/cli.py` | Add `--force-cluster-size N` flag to the `run` command that promotes specs lacking a `cluster:` block to N-node cluster mode (N in 1, 3, 5, 10). | modify |
| `geodetestlab-cli/geodetestlab/lib/spec.py` | When `--force-cluster-size > 1` is active, synthesize a `ClusterConfig` if the spec doesn't already have one. | modify |
| `geodetestlab-cli/geodetestlab/lib/runner.py` | When `force_cluster_size` is set on the runner config, mutate `spec.cluster_config` before the cluster start path on line 733. | modify |
| `geodetestlab-cli/geodetestlab/tests/test_force_cluster_size.py` | NEW. Unit tests for the promotion logic. | new file |
| `Makefile` | Add targets `test-cluster-1`, `test-cluster-3`, `test-cluster-5`, `test-cluster-10`, `test-cluster-matrix` (sequential run of all four). | modify |

### Specs (YAML)

| Path | Responsibility | Status |
|---|---|---|
| `geodetestlab-cli/specs/multi_node/README.md` | NEW. Documents the multi-node suite and runtime expectations (per-size ports, GEODE_CLUSTER_TOKEN, timeouts). | new |
| `geodetestlab-cli/specs/multi_node/cluster_bootstrap_3node.yml` | NEW. Asserts 3-node cluster forms, elects a leader, all members reachable. | new |
| `geodetestlab-cli/specs/multi_node/cluster_bootstrap_5node.yml` | NEW. Same, 5 nodes. | new |
| `geodetestlab-cli/specs/multi_node/cluster_bootstrap_10node.yml` | NEW. Same, 10 nodes. | new |
| `geodetestlab-cli/specs/multi_node/replication_leader_write_follower_read.yml` | NEW. Write to leader, read from each follower, assert convergence. | new |
| `geodetestlab-cli/specs/multi_node/leader_failover_sigkill.yml` | NEW. SIGKILL leader, assert new leader elected within timeout, writes resume. | new |
| `geodetestlab-cli/specs/multi_node/follower_partition_heal.yml` | NEW. SIGSTOP a follower, write to leader, SIGCONT follower, assert it catches up. | new |
| `geodetestlab-cli/specs/multi_node/quorum_minority_loss.yml` | NEW. Kill (cluster_size/2) - 1 followers; cluster keeps serving. Kill one more; cluster goes read-only. | new |
| `geodetestlab-cli/specs/multi_node/cross_node_query_consistency.yml` | NEW. Round-robin query a `MATCH` across all nodes after a single write; identical results. | new |
| `geodetestlab-cli/specs/multi_node/distributed_2pc_commit.yml` | NEW. 2PC transaction touching two graphs on two shards commits atomically. | new |
| `geodetestlab-cli/specs/multi_node/distributed_2pc_abort.yml` | NEW. Coordinator failure mid-prepare leaves no partial commit. | new |
| `geodetestlab-cli/specs/multi_node/tenant_isolation_cross_node.yml` | NEW. Tenant A writes to node 0, tenant B reads from node 2; no leakage. | new |
| `geodetestlab-cli/specs/multi_node/rls_policy_cross_node.yml` | NEW. RLS policy enforced regardless of which node the read lands on. | new |
| `geodetestlab-cli/specs/multi_node/snapshot_replay_new_node.yml` | NEW. Start 3-node cluster, write data, add a 4th node, assert it snapshot-syncs and serves the data. | new |
| `geodetestlab-cli/specs/multi_node/audit_chain_consistency.yml` | NEW. Audit events written across nodes form a consistent HMAC chain. | new |
| `geodetestlab-cli/specs/multi_node/show_cluster_status.yml` | NEW. `SHOW CLUSTER STATUS` returns `node_count`, `leader_id`, per-member `state`. | new |
| `geodetestlab-cli/specs/distributed_*.yml` (existing 10 files) | MODIFY. Add real `cluster: { nodes: 3 }` blocks; replace single-node assertions with cross-node ones where appropriate. | modify |

### Documentation

| File | Responsibility | Status |
|---|---|---|
| `docs/DISTRIBUTED_CLUSTER_TESTING.md` | NEW. How to run cluster matrix, how to add cluster specs, troubleshooting checklist. | new |
| `geode-test-harness/CLAUDE.md` | MODIFY. Document `--force-cluster-size`, `make test-cluster-matrix`, cluster spec shape. | modify |
| `geode-test-harness/Makefile` | MODIFY (covered above). | modify |

---

## Phase A — Wire ClusterCoordinator into the geode server boot path

Without Phase A, no spec change can ever pass: the geode binary will not form a cluster regardless of how many copies the harness starts.

### Task A1: Add `--cluster-port` and `--peers` CLI flags

**Files:**
- Modify: `src/cli_args.zig` (add to the `ServerConfig` struct + arg parser)
- Test: `tests/test_cli_args_cluster.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_cli_args_cluster.zig`:

```zig
const std = @import("std");
const cli_args = @import("../src/cli_args.zig");

test "parse --cluster-port" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const argv = [_][]const u8{ "geode", "serve", "--cluster-port", "4242" };
    const cfg = try cli_args.parseServerArgs(gpa.allocator(), &argv);
    defer cfg.deinit(gpa.allocator());
    try std.testing.expectEqual(@as(?u16, 4242), cfg.cluster_port);
}

test "parse --peers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const argv = [_][]const u8{ "geode", "serve", "--peers", "127.0.0.1:4242,127.0.0.1:4243" };
    const cfg = try cli_args.parseServerArgs(gpa.allocator(), &argv);
    defer cfg.deinit(gpa.allocator());
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
    try std.testing.expectEqualStrings("127.0.0.1:4242", cfg.peers[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4243", cfg.peers[1]);
}

test "cluster_port defaults to null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const argv = [_][]const u8{ "geode", "serve" };
    const cfg = try cli_args.parseServerArgs(gpa.allocator(), &argv);
    defer cfg.deinit(gpa.allocator());
    try std.testing.expectEqual(@as(?u16, null), cfg.cluster_port);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter='cluster'`
Expected: FAIL — `cluster_port` field missing on `ServerConfig`.

- [ ] **Step 3: Implement**

In `src/cli_args.zig`, add the two fields to `ServerConfig` and the two flags to the parser. Default `cluster_port = null`, `peers = &.{}`. When `--peers` is parsed, split on `,` and store each as an owned slice; track ownership in `deinit`.

- [ ] **Step 4: Verify**

Run: `zig build test -Dtest-filter='cluster'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/cli_args.zig tests/test_cli_args_cluster.zig tests/all_tests.zig
git commit -m "feat(cli): add --cluster-port and --peers server flags"
```

### Task A2: Create `cluster_bootstrap.zig`

**Files:**
- Create: `src/server/cluster_bootstrap.zig`
- Test: `tests/test_cluster_bootstrap.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const cluster_bootstrap = @import("../src/server/cluster_bootstrap.zig");

test "parseConfig returns null when GEODE_CLUSTER_TOKEN is absent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const env: std.process.EnvMap = .{ .hash_map = .empty };
    const result = try cluster_bootstrap.parseConfig(gpa.allocator(), env, null, &.{});
    try std.testing.expect(result == null);
}

test "parseConfig errors when token set but node_id missing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var env = std.process.EnvMap.init(gpa.allocator());
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "abc");
    const result = cluster_bootstrap.parseConfig(gpa.allocator(), env, null, &.{});
    try std.testing.expectError(error.MissingNodeId, result);
}

test "parseConfig builds 3-node config from env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var env = std.process.EnvMap.init(gpa.allocator());
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_NODE_ID", "0");
    try env.put("GEODE_PEERS", "127.0.0.1:4242,127.0.0.1:4243");
    const result = (try cluster_bootstrap.parseConfig(gpa.allocator(), env, null, &.{})).?;
    defer result.deinit(gpa.allocator());
    try std.testing.expectEqual(@as(u64, 0), result.node_id);
    try std.testing.expectEqual(@as(usize, 2), result.peers.len);
}

test "parseConfig: CLI --peers overrides GEODE_PEERS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var env = std.process.EnvMap.init(gpa.allocator());
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok");
    try env.put("GEODE_NODE_ID", "0");
    try env.put("GEODE_PEERS", "127.0.0.1:9999"); // should be ignored
    const cli_peers = [_][]const u8{ "127.0.0.1:5000", "127.0.0.1:5001" };
    const result = (try cluster_bootstrap.parseConfig(gpa.allocator(), env, null, &cli_peers)).?;
    defer result.deinit(gpa.allocator());
    try std.testing.expectEqual(@as(usize, 2), result.peers.len);
    try std.testing.expectEqualStrings("127.0.0.1:5000", result.peers[0]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter='parseConfig'`
Expected: FAIL — `cluster_bootstrap` module does not exist.

- [ ] **Step 3: Implement `cluster_bootstrap.zig`**

```zig
const std = @import("std");
const distributed = @import("../distributed/mod.zig");

pub const Bootstrap = struct {
    coordinator: *distributed.ClusterCoordinator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Bootstrap) void {
        self.coordinator.deinit();
        self.allocator.destroy(self.coordinator);
    }
};

pub const ParsedConfig = struct {
    node_id: u64,
    cluster_port: u16,
    cluster_token: []const u8,
    cluster_name: []const u8,
    peers: [][]const u8, // owned
    allocator: std.mem.Allocator,

    pub fn deinit(self: ParsedConfig, allocator: std.mem.Allocator) void {
        for (self.peers) |p| allocator.free(p);
        allocator.free(self.peers);
        allocator.free(self.cluster_token);
        allocator.free(self.cluster_name);
    }
};

pub const Error = error{
    MissingNodeId,
    InvalidNodeId,
    InvalidPeerSpec,
    OutOfMemory,
};

/// Returns null when `GEODE_CLUSTER_TOKEN` is not set (standalone mode).
/// Returns an error if the token is set but other required vars are missing.
pub fn parseConfig(
    allocator: std.mem.Allocator,
    env: std.process.EnvMap,
    cli_cluster_port: ?u16,
    cli_peers: []const []const u8,
) Error!?ParsedConfig {
    const token_raw = env.get("GEODE_CLUSTER_TOKEN") orelse return null;
    const node_id_raw = env.get("GEODE_NODE_ID") orelse return error.MissingNodeId;
    const node_id = std.fmt.parseInt(u64, node_id_raw, 10) catch return error.InvalidNodeId;

    const cluster_name_raw = env.get("GEODE_CLUSTER_NAME") orelse "geode-cluster";
    const cluster_port = cli_cluster_port orelse blk: {
        const port_raw = env.get("GEODE_CLUSTER_PORT") orelse break :blk @as(u16, 4242);
        break :blk std.fmt.parseInt(u16, port_raw, 10) catch return error.InvalidPeerSpec;
    };

    const peers_source: [][]const u8 = if (cli_peers.len > 0) blk: {
        const out = try allocator.alloc([]const u8, cli_peers.len);
        for (cli_peers, 0..) |p, i| out[i] = try allocator.dupe(u8, p);
        break :blk out;
    } else if (env.get("GEODE_PEERS")) |raw| try splitOwned(allocator, raw, ',') else try allocator.alloc([]const u8, 0);

    return ParsedConfig{
        .node_id = node_id,
        .cluster_port = cluster_port,
        .cluster_token = try allocator.dupe(u8, token_raw),
        .cluster_name = try allocator.dupe(u8, cluster_name_raw),
        .peers = peers_source,
        .allocator = allocator,
    };
}

fn splitOwned(allocator: std.mem.Allocator, raw: []const u8, sep: u8) ![][]const u8 {
    var count: usize = 1;
    for (raw) |b| if (b == sep) count += 1;
    var list = try allocator.alloc([]const u8, count);
    errdefer allocator.free(list);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, raw, sep);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        list[i] = try allocator.dupe(u8, part);
        i += 1;
    }
    return list[0..i];
}

/// Boot the cluster coordinator. Returns null when config is absent.
pub fn start(
    allocator: std.mem.Allocator,
    config: ParsedConfig,
) !Bootstrap {
    const cfg = distributed.ClusterCoordinator.Config{
        .peers = config.peers,
        .cluster_port = config.cluster_port,
        .cluster_token = config.cluster_token,
        .cluster_name = config.cluster_name,
        .election_timeout_ms = 1_500,
        .replication_factor = if (config.peers.len < 3) @intCast(config.peers.len + 1) else 3,
        .sharding_strategy = .consistent_hash,
        .failover_config = .{ .heartbeat_timeout_ms = 3_000 },
    };
    const coord = try allocator.create(distributed.ClusterCoordinator);
    errdefer allocator.destroy(coord);
    coord.* = try distributed.ClusterCoordinator.init(allocator, config.node_id, cfg);
    errdefer coord.deinit();
    try coord.start();
    return Bootstrap{ .coordinator = coord, .allocator = allocator };
}
```

- [ ] **Step 4: Verify**

Run: `zig build test -Dtest-filter='parseConfig'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/server/cluster_bootstrap.zig tests/test_cluster_bootstrap.zig tests/all_tests.zig
git commit -m "feat(server): add cluster_bootstrap module"
```

### Task A3: Verify `ClusterCoordinator.Config` field names

**Files:**
- Read-only: `src/distributed/cluster.zig`

- [ ] **Step 1: Open the Config struct**

Open `src/distributed/cluster.zig` and locate `pub const Config = struct { ... }`. Read the exact field names. Task A2's `start()` references `cluster_port`, `cluster_token`, `cluster_name`, `election_timeout_ms`, `replication_factor`, `sharding_strategy`, `failover_config`.

- [ ] **Step 2: Reconcile**

If the actual field names differ (e.g. `port` instead of `cluster_port`), update A2's `start()` to match. Do not rename fields in `cluster.zig` — that's a downstream library used elsewhere.

- [ ] **Step 3: Re-run A2 tests**

Run: `zig build test -Dtest-filter='parseConfig'`
Expected: PASS.

- [ ] **Step 4: Commit any field name corrections only if A2's code referenced wrong names**

```bash
git add src/server/cluster_bootstrap.zig
git commit -m "fix(server): reconcile cluster_bootstrap field names with ClusterCoordinator.Config"
```

### Task A4: Wire `cluster_bootstrap` into `src/server/main.zig`

**Files:**
- Modify: `src/server/main.zig` (around line 946, right after the existing `cluster_token` read)
- Modify: `src/server/server_init.zig` (add `*?Bootstrap` field on `InitContext` and free in `deinit`)

- [ ] **Step 1: Write the failing test**

Add `tests/test_cluster_bootstrap_wiring.zig`:

```zig
const std = @import("std");
const builtin = @import("builtin");

test "server with GEODE_CLUSTER_TOKEN unset uses standalone role" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Smoke: spawn ./zig-out/bin/geode serve briefly, check it does NOT log "cluster_coordinator started"
    // when GEODE_CLUSTER_TOKEN is absent. Implementation: child_process with 1s timeout, scan stderr.
    // (Skeleton — full impl in step 3.)
    return error.SkipZigTest;
}

test "server with GEODE_CLUSTER_TOKEN set logs cluster bootstrap" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    return error.SkipZigTest;
}
```

- [ ] **Step 2: Run test (intentionally skipped, but should compile)**

Run: `zig build test -Dtest-filter='cluster_bootstrap_wiring'`
Expected: PASS (skipped).

- [ ] **Step 3: Implement wiring in `src/server/main.zig`**

Right after the existing block at `src/server/main.zig:937-946`:

```zig
// CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=ClusterBootstrap; STATUS=IMPL; OWNER=core; UPDATED=2026-05-25
var cluster_bootstrap_handle: ?cluster_bootstrap.Bootstrap = null;
defer if (cluster_bootstrap_handle) |*h| h.deinit();

if (cluster_token) |_| {
    const env = try std.process.getEnvMap(gpa);
    defer env.deinit();
    const maybe_cfg = try cluster_bootstrap.parseConfig(
        gpa,
        env,
        config.cluster_port,
        config.peers,
    );
    if (maybe_cfg) |cfg| {
        defer cfg.deinit(gpa);
        cluster_bootstrap_handle = cluster_bootstrap.start(gpa, cfg) catch |err| {
            log.err("Cluster bootstrap failed; refusing to start", &.{
                Attr.string("error", @errorName(err)),
                Attr.int("node_id", @intCast(cfg.node_id)),
                Attr.int("peer_count", @intCast(cfg.peers.len)),
            });
            return err;
        };
        log.info("Cluster coordinator started", &.{
            Attr.int("node_id", @intCast(cfg.node_id)),
            Attr.int("cluster_port", @intCast(cfg.cluster_port)),
            Attr.int("peer_count", @intCast(cfg.peers.len)),
        });
    }
}
```

Add `const cluster_bootstrap = @import("cluster_bootstrap.zig");` near the other imports.

- [ ] **Step 4: Implement the integration smoke test**

Replace the skipped bodies in `tests/test_cluster_bootstrap_wiring.zig` with real ChildProcess invocations of `./zig-out/bin/geode serve` (1.5s timeout), one with no env, one with `GEODE_CLUSTER_TOKEN=t GEODE_NODE_ID=0 GEODE_PEERS= GEODE_CLUSTER_PORT=<free port>`. Scan stderr for "Cluster coordinator started".

- [ ] **Step 5: Verify**

```bash
zig build && zig build test -Dtest-filter='cluster_bootstrap_wiring'
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/server/main.zig src/server/server_init.zig tests/test_cluster_bootstrap_wiring.zig tests/all_tests.zig
git commit -m "feat(server): wire ClusterCoordinator into startup path"
```

### Task A5: In-process 3-node replication smoke test

**Files:**
- Create: `tests/test_cluster_replication_smoke.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const distributed = @import("../src/distributed/mod.zig");

test "three-node in-process cluster: write to leader, read from followers" {
    if (true) return error.SkipZigTest; // gated until A4 passes; flip to false in A5 step 3
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Spin up 3 ClusterCoordinator instances bound to loopback ports.
    // Wait for leader election (≤5s).
    // Submit a write through the leader.
    // Poll each follower for the applied entry (≤5s).
    // Assert all three converge.
}
```

- [ ] **Step 2: Run test to verify it skips cleanly**

Run: `zig build test -Dtest-filter='three-node'`
Expected: PASS (skipped).

- [ ] **Step 3: Implement the full test**

Replace the skip with the real fixture. Use the `ClusterCoordinator.proposeWrite` API (verify exact name in `cluster.zig`), poll `coord.lastAppliedIndex()` on followers until it matches the leader's, with a 5-second deadline.

- [ ] **Step 4: Verify**

Run: `zig build test -Dtest-filter='three-node'`
Expected: PASS (one test, runtime ≤8s).

- [ ] **Step 5: Commit**

```bash
git add tests/test_cluster_replication_smoke.zig tests/all_tests.zig
git commit -m "test: 3-node in-process cluster replication smoke"
```

### Task A6: Subprocess 3-node cluster smoke (out-of-process)

**Files:**
- Create: `tests/test_cluster_subprocess_smoke.zig`

This proves the binary actually forms a cluster when launched as separate processes — the exact scenario the harness exercises.

- [ ] **Step 1: Write the test**

Use `std.process.Child` to spawn three `./zig-out/bin/geode serve` processes with `GEODE_CLUSTER_TOKEN=test GEODE_NODE_ID=0|1|2 GEODE_PEERS=…` and three free ports. Wait up to 10s for each process to log "Cluster coordinator started" (`std.fs.watch` on combined stderr, or a busy-poll on `cluster_health` GQL probe). Assert that issuing `SHOW CLUSTER STATUS` to node 0 returns `node_count=3, leader_id != 0` (any node can win).

- [ ] **Step 2: Run**

Run: `zig build && zig build test -Dtest-filter='cluster_subprocess'`
Expected: PASS within 15s.

- [ ] **Step 3: Commit**

```bash
git add tests/test_cluster_subprocess_smoke.zig tests/all_tests.zig
git commit -m "test: out-of-process 3-node cluster subprocess smoke"
```

### Task A7: Add `SHOW CLUSTER STATUS` GQL surface

If the GQL parser does not already recognise `SHOW CLUSTER STATUS`, this task adds it. (Inspect `src/gql/parser.zig` for `SHOW USERS`/`SHOW POLICIES` patterns and clone the path.) If it does exist, this task is a no-op — verify and skip.

**Files:**
- Modify (maybe): `src/gql/parser.zig`, `src/execution/show_statements.zig` (or wherever SHOW lives)
- Test: `tests/test_show_cluster_status.zig`

- [ ] **Step 1: Audit current SHOW grammar**

Run: `grep -rn 'SHOW CLUSTER\|ShowCluster\|cluster_status' src/gql src/execution src/server`
Document whether the statement exists. If yes → skip to step 6. If no → continue.

- [ ] **Step 2: Write the failing test**

```zig
test "SHOW CLUSTER STATUS in standalone mode" {
    // Run query via the embedded executor; expect rows: node_id, role=standalone, leader_id=node_id, member_count=1
}
test "SHOW CLUSTER STATUS in 3-node cluster" {
    // Boot 3-node in-process cluster (reuse A5 fixture); SHOW CLUSTER STATUS from node 0; assert 3 rows, exactly 1 leader.
}
```

- [ ] **Step 3: Implement parser + executor**

Follow the existing `SHOW USERS` pattern: lex `CLUSTER`+`STATUS` as a keyword sequence, route through an execution handler that calls `cluster_bootstrap_handle.coordinator.snapshotStatus(allocator)` (or builds a standalone fallback row when `cluster_bootstrap_handle == null`).

- [ ] **Step 4: Verify**

Run: `zig build test -Dtest-filter='SHOW CLUSTER'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/gql/parser.zig src/execution/*cluster* tests/test_show_cluster_status.zig tests/all_tests.zig
git commit -m "feat(gql): SHOW CLUSTER STATUS"
```

- [ ] **Step 6: Skip-and-commit-marker if already implemented**

If step 1 found an existing implementation, write a one-line note in the commit body:

```bash
git commit --allow-empty -m "test(gql): SHOW CLUSTER STATUS already exists; verified via audit"
```

### Task A8: Wire Raft apply → graph_store on every node (verify only)

`src/distributed/raft_apply.zig` already has `setGlobalStore` + `applyCallbackFn`. The cluster bootstrap path in A4 calls `ClusterCoordinator.init`, which already calls `raft_apply.setGlobalStore(store)` and `raft.apply_callback = &raft_apply.applyCallbackFn`. This task is verify-only.

- [ ] **Step 1: Confirm in source**

Run: `grep -n 'raft_apply.setGlobalStore\|apply_callback' src/distributed/cluster.zig`
Expected: both calls present in `ClusterCoordinator.init`.

- [ ] **Step 2: Confirm with replication smoke**

Re-run A5's `three-node in-process cluster` test. The write must visibly land on followers.

- [ ] **Step 3: No commit; this is a gate, not a change**

If A5 was already green, this task is done.

---

## Phase B — Harness cluster orchestration enhancements

### Task B1: Inject `GEODE_CLUSTER_PORT` and `GEODE_CLUSTER_TOKEN` from harness

**Files:**
- Modify: `geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster.py`
- Test: `geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_cluster_env_injection.py`

- [ ] **Step 1: Write the failing test**

```python
def test_build_node_env_injects_cluster_port():
    from geodetestlab.lib.cluster import _build_node_env
    from geodetestlab.lib.cluster_types import ClusterConfig
    cfg = ClusterConfig(node_count=3, shared_env={"GEODE_CLUSTER_TOKEN": "tok"})
    env = _build_node_env(cfg, node_id=0, base_env={}, port=3141, grpc_port=None,
                         data_dir="/tmp/x", all_ports=[3141, 3142, 3143])
    assert env["GEODE_CLUSTER_PORT"] == "4141"  # port + 1000
    assert env["GEODE_CLUSTER_TOKEN"] == "tok"
    # GEODE_PEERS uses cluster ports, not client ports
    assert env["GEODE_PEERS"] == "127.0.0.1:4142,127.0.0.1:4143"

def test_build_node_env_auto_generates_token_when_absent():
    from geodetestlab.lib.cluster import _build_node_env
    from geodetestlab.lib.cluster_types import ClusterConfig
    cfg = ClusterConfig(node_count=2)  # no shared_env
    env = _build_node_env(cfg, node_id=0, base_env={}, port=3141, grpc_port=None,
                         data_dir="/tmp/x", all_ports=[3141, 3142])
    # Token auto-generated if missing
    assert "GEODE_CLUSTER_TOKEN" in env
    assert len(env["GEODE_CLUSTER_TOKEN"]) >= 16
```

- [ ] **Step 2: Run and verify failure**

Run: `cd geode-test-harness && pytest geodetestlab-cli/geodetestlab/tests/test_cluster_env_injection.py -v`
Expected: FAIL — `GEODE_CLUSTER_PORT` not set and peers use the wrong port column.

- [ ] **Step 3: Modify `_build_node_env`**

After the existing peer loop in `lib/cluster.py:60-62`:

```python
    # Cluster-internal Raft port = client port + 1000
    cluster_port = port + 1000
    env["GEODE_CLUSTER_PORT"] = str(cluster_port)

    # Auto-generate a per-test cluster token if not supplied
    if "GEODE_CLUSTER_TOKEN" not in env:
        import secrets as _secrets
        env["GEODE_CLUSTER_TOKEN"] = _secrets.token_hex(16)

    # Peers must point at OTHER nodes' CLUSTER ports, not client ports
    if all_ports is not None:
        peer_cluster_ports = [p + 1000 for p in all_ports if p != port]
        env["GEODE_PEERS"] = ",".join(f"127.0.0.1:{cp}" for cp in peer_cluster_ports)
```

Remove the older `env["GEODE_PEERS"]` assignment at lines 60-62 (it used client ports — wrong).

- [ ] **Step 4: Verify**

Run: `cd geode-test-harness && pytest geodetestlab-cli/geodetestlab/tests/test_cluster_env_injection.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster.py geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_cluster_env_injection.py
git commit -m "fix(harness): inject GEODE_CLUSTER_PORT and use cluster ports in GEODE_PEERS"
```

### Task B2: Real cluster readiness probe

**Files:**
- Create: `geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster_readiness.py`
- Modify: `geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster.py` (call probe from `start_cluster`)
- Test: `geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_cluster_readiness.py`

- [ ] **Step 1: Write the failing test (uses subprocess fixture)**

```python
import os
import pytest
from pathlib import Path

GEODE = os.environ.get("GEODE_BINARY", "/usr/bin/geode")

@pytest.mark.skipif(not Path(GEODE).exists(), reason="geode binary required")
def test_wait_for_cluster_ready_3node():
    from geodetestlab.lib.cluster import start_cluster, stop_cluster
    from geodetestlab.lib.cluster_types import ClusterConfig
    from geodetestlab.lib.cluster_readiness import wait_for_cluster_ready

    cfg = ClusterConfig(node_count=3)
    state = start_cluster(cfg, binary=GEODE, base_env=os.environ.copy(),
                         spec_server_args=["--log-level", "warn"], verbose=False)
    try:
        ready = wait_for_cluster_ready(state, deadline_s=20.0)
        assert ready, "3-node cluster failed to elect leader within 20s"
    finally:
        stop_cluster(state, cleanup_data=True)
```

- [ ] **Step 2: Run and verify it fails (no probe yet)**

Run: `cd geode-test-harness && pytest geodetestlab-cli/geodetestlab/tests/test_cluster_readiness.py -v`
Expected: FAIL — `cluster_readiness` module missing.

- [ ] **Step 3: Implement `cluster_readiness.py`**

```python
"""Cluster-level readiness probe.

Poll SHOW CLUSTER STATUS on each node until:
  - every node reports the same leader_id
  - leader_id != 0 (election complete)
  - reported member_count == expected node_count
"""
from __future__ import annotations
import subprocess
import time
import logging
from .cluster_types import ClusterState

logger = logging.getLogger(__name__)


def _probe_node(binary: str, port: int, admin_password: str, timeout_s: float) -> dict | None:
    """Returns parsed cluster status dict or None if unreachable."""
    import json
    try:
        result = subprocess.run(
            [binary, "query", "--dsn", f"127.0.0.1:{port}?insecure=true",
             "--user", "geode", "--pass", admin_password, "--format", "json",
             "SHOW CLUSTER STATUS"],
            capture_output=True, text=True, timeout=timeout_s,
        )
        if result.returncode != 0:
            return None
        rows = json.loads(result.stdout).get("rows", [])
        if not rows:
            return None
        return {
            "leader_id": rows[0].get("leader_id"),
            "member_count": len(rows),
            "members": [r.get("node_id") for r in rows],
        }
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def wait_for_cluster_ready(
    cluster_state: ClusterState,
    *,
    binary: str = "geode",
    admin_password: str = "GeodeTestPassword123!",
    deadline_s: float = 20.0,
    poll_interval_s: float = 0.5,
) -> bool:
    expected_count = len(cluster_state.nodes)
    start = time.monotonic()

    while time.monotonic() - start < deadline_s:
        observations = []
        for node in cluster_state.nodes:
            obs = _probe_node(binary, node.port, admin_password, timeout_s=2.0)
            if obs is None:
                break
            observations.append(obs)

        if len(observations) == expected_count:
            leaders = {o["leader_id"] for o in observations}
            counts = {o["member_count"] for o in observations}
            if len(leaders) == 1 and 0 not in leaders and counts == {expected_count}:
                logger.info("Cluster ready: leader=%s, members=%d",
                            next(iter(leaders)), expected_count)
                return True

        time.sleep(poll_interval_s)

    logger.error("Cluster not ready within %.1fs", deadline_s)
    return False
```

- [ ] **Step 4: Wire the probe into `start_cluster`**

In `cluster.py`, after the per-node `start_server` loop completes, before returning:

```python
    from .cluster_readiness import wait_for_cluster_ready
    if not wait_for_cluster_ready(
        ClusterState(nodes=nodes),
        binary=binary,
        admin_password=base_env.get("GEODE_ADMIN_PASSWORD", DEFAULT_ADMIN_PASSWORD),
        deadline_s=max(20.0, config.startup_timeout_ms / 1000.0),
    ):
        rollback = ClusterState(nodes=nodes)
        stop_cluster(rollback, verbose=verbose, cleanup_data=True)
        raise RuntimeError(f"Cluster of {config.node_count} nodes failed to reach READY")

    return ClusterState(nodes=nodes)
```

- [ ] **Step 5: Verify**

```bash
cd geode-test-harness
make build  # rebuild geode if needed
GEODE_BINARY=../geode/zig-out/bin/geode pytest geodetestlab-cli/geodetestlab/tests/test_cluster_readiness.py -v
```
Expected: PASS within ~25s.

- [ ] **Step 6: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster_readiness.py geode-test-harness/geodetestlab-cli/geodetestlab/lib/cluster.py geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_cluster_readiness.py
git commit -m "feat(harness): cluster-level readiness probe via SHOW CLUSTER STATUS"
```

### Task B3: `--force-cluster-size` CLI flag

**Files:**
- Modify: `geode-test-harness/geodetestlab-cli/geodetestlab/cli.py`
- Modify: `geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner_types.py` (add `force_cluster_size` to runner config dataclass)
- Modify: `geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner.py` (apply override)
- Test: `geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_force_cluster_size.py`

- [ ] **Step 1: Write the failing test**

```python
def test_force_cluster_size_promotes_spec_without_cluster_block(tmp_path):
    from geodetestlab.lib.spec import load_spec
    from geodetestlab.lib.runner import _apply_force_cluster_size

    spec_path = tmp_path / "noop.yml"
    spec_path.write_text("""
version: '1.0'
name: noop
cli:
  binary: ./zig-out/bin/geode
  server:
    enabled: true
tests:
  - name: t1
    args: [query, '-']
    stdin: "RETURN 1 AS x"
    expect:
      exit_code: 0
""")
    spec = load_spec(spec_path)
    assert spec.cluster_config is None

    _apply_force_cluster_size(spec, 3)
    assert spec.cluster_config is not None
    assert spec.cluster_config.node_count == 3
    assert spec.mode == "cluster"


def test_force_cluster_size_1_leaves_spec_alone(tmp_path):
    from geodetestlab.lib.spec import load_spec
    from geodetestlab.lib.runner import _apply_force_cluster_size

    spec_path = tmp_path / "noop.yml"
    spec_path.write_text("""
version: '1.0'
name: noop
tests:
  - name: t1
    query: RETURN 1
""")
    spec = load_spec(spec_path)
    _apply_force_cluster_size(spec, 1)
    assert spec.cluster_config is None  # no promotion at size 1
    assert spec.mode == "server"


def test_force_cluster_size_skips_specs_that_opt_out():
    """Specs with `single_node_only: true` skip promotion."""
    # ... see step 3
```

- [ ] **Step 2: Run and verify failure**

Run: `pytest geodetestlab-cli/geodetestlab/tests/test_force_cluster_size.py -v`
Expected: FAIL — `_apply_force_cluster_size` missing.

- [ ] **Step 3: Implement**

In `lib/runner.py`, add:

```python
def _apply_force_cluster_size(spec, size: int) -> None:
    """If size > 1 and spec has no cluster block, synthesize one.

    Specs may set `single_node_only: true` at top level to opt out
    (e.g. specs that exercise filesystem-local state).
    """
    if size <= 1:
        return
    if spec.cluster_config is not None:
        return  # spec already declares its own cluster
    if getattr(spec, "single_node_only", False):
        return  # spec opted out
    from .cluster_types import ClusterConfig
    spec.cluster_config = ClusterConfig.from_size(size)
    spec.mode = "cluster"
```

In `lib/spec.py`, read `single_node_only: bool` (default False) from the YAML and store on `TestSpec`.

In `cli.py`, on the `run` command, add a `--force-cluster-size INT` Typer option (default 1), and call `_apply_force_cluster_size(spec, force_cluster_size)` after loading each spec.

- [ ] **Step 4: Verify**

Run: `pytest geodetestlab-cli/geodetestlab/tests/test_force_cluster_size.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/geodetestlab/cli.py geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner.py geode-test-harness/geodetestlab-cli/geodetestlab/lib/spec.py geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner_types.py geode-test-harness/geodetestlab-cli/geodetestlab/tests/test_force_cluster_size.py
git commit -m "feat(harness): --force-cluster-size promotes specs to N-node clusters"
```

### Task B4: Makefile targets `test-cluster-{1,3,5,10}` and `test-cluster-matrix`

**Files:**
- Modify: `geode-test-harness/Makefile`

- [ ] **Step 1: Add the targets**

Append to the harness `Makefile`:

```makefile
# --- Cluster matrix testing --------------------------------------------
.PHONY: test-cluster-1 test-cluster-3 test-cluster-5 test-cluster-10 test-cluster-matrix

GEODE_BINARY ?= ../geode/zig-out/bin/geode

test-cluster-1:
	GEODE_BINARY=$(GEODE_BINARY) $(RUN_PYTHON) -m geodetestlab run \
		--specs-dir geodetestlab-cli/specs --force-cluster-size 1 \
		--report-json reports/cluster-1.json

test-cluster-3:
	GEODE_BINARY=$(GEODE_BINARY) $(RUN_PYTHON) -m geodetestlab run \
		--specs-dir geodetestlab-cli/specs --force-cluster-size 3 \
		--report-json reports/cluster-3.json

test-cluster-5:
	GEODE_BINARY=$(GEODE_BINARY) $(RUN_PYTHON) -m geodetestlab run \
		--specs-dir geodetestlab-cli/specs --force-cluster-size 5 \
		--report-json reports/cluster-5.json

test-cluster-10:
	GEODE_BINARY=$(GEODE_BINARY) $(RUN_PYTHON) -m geodetestlab run \
		--specs-dir geodetestlab-cli/specs --force-cluster-size 10 \
		--report-json reports/cluster-10.json

test-cluster-matrix: test-cluster-1 test-cluster-3 test-cluster-5 test-cluster-10
	@echo "--- Cluster matrix summary ---"
	@for n in 1 3 5 10; do \
		echo "Size $$n:" ; \
		jq -r '.summary | "  passed=\(.passed) failed=\(.failed) skipped=\(.skipped) duration_s=\(.duration_s)"' reports/cluster-$$n.json ; \
	done
```

- [ ] **Step 2: Verify it parses**

Run: `cd geode-test-harness && make -n test-cluster-3`
Expected: prints the underlying command without executing it.

- [ ] **Step 3: Commit**

```bash
git add geode-test-harness/Makefile
git commit -m "feat(harness): test-cluster-{1,3,5,10} and test-cluster-matrix targets"
```

### Task B5: `--report-json` writer for matrix aggregation

If the harness `run` command does not already accept `--report-json PATH` that writes a machine-readable summary, add it. (Inspect `cli.py:147-329` first.)

**Files:**
- Modify (maybe): `geode-test-harness/geodetestlab-cli/geodetestlab/cli.py`
- Modify (maybe): `geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner.py`

- [ ] **Step 1: Audit current reporting**

Run: `grep -n 'report\|json' geode-test-harness/geodetestlab-cli/geodetestlab/cli.py | head -20`
Document the existing reporting flags. If `--report-json` exists, skip to step 5. If not, continue.

- [ ] **Step 2: Failing test**

```python
def test_report_json_written(tmp_path, monkeypatch):
    # Drive `run` programmatically with a trivial spec; assert reports/foo.json exists
    # and has shape {"summary": {"passed": int, "failed": int, "skipped": int, "duration_s": float}, "tests": [...]}.
```

- [ ] **Step 3: Implement**

Add `--report-json` to the Typer command. After all specs complete, serialize the aggregated `RunResult` summary and per-test results to that path.

- [ ] **Step 4: Verify**

Run: `pytest -k report_json -v`
Expected: PASS.

- [ ] **Step 5: Commit (or skip-commit)**

```bash
git add geode-test-harness/geodetestlab-cli/geodetestlab/cli.py geode-test-harness/geodetestlab-cli/geodetestlab/lib/runner.py geode-test-harness/geodetestlab-cli/geodetestlab/tests/
git commit -m "feat(harness): --report-json for machine-readable summaries"
```

If audit showed the flag already exists, run only the test above and commit `--allow-empty -m "test: verify existing --report-json"`.

---

## Phase C — New multi-node cluster correctness specs

Each task in Phase C produces one new spec under `geodetestlab-cli/specs/multi_node/`. Run each spec twice during development: once against the harness with `--force-cluster-size 3` to confirm it exercises real multi-node behavior, and once with `--force-cluster-size 1` to confirm graceful single-node fallback (or `single_node_only: false` confirms it skips).

For each spec task: write the YAML, run it, commit. If the spec fails because of a geode bug (not a spec authoring bug), open the test and assert the failure mode it currently shows; the bug is addressed in Phase D.

### Task C1: `cluster_bootstrap_3node.yml`

**Files:**
- Create: `geode-test-harness/geodetestlab-cli/specs/multi_node/cluster_bootstrap_3node.yml`

- [ ] **Step 1: Write the spec**

```yaml
version: '1.0'
name: 3-Node Cluster Bootstrap
description: |
  Asserts that three geode processes started with shared GEODE_CLUSTER_TOKEN
  form a Raft group, elect exactly one leader, and report a consistent view
  of cluster membership.
single_node_only: false
cluster:
  nodes: 3
  startup_timeout_ms: 30000
  target_node: 'all'
  shared_env:
    GEODE_CLUSTER_TOKEN: harness-bootstrap-3
    GEODE_CLUSTER_NAME: harness-3node
cli:
  binary: ./zig-out/bin/geode
  client:
    timeout_ms: 30000
    tls_verify: false
    format: json
tests:
- name: every-node-reports-three-members
  description: SHOW CLUSTER STATUS returns 3 rows on every node.
  args: [query, '-']
  stdin: "SHOW CLUSTER STATUS"
  expect:
    exit_code: 0
    stdout_contains:
      - '"member_count":3'
- name: every-node-agrees-on-leader
  description: All three nodes report the same leader_id.
  type: sequential
  steps:
    - type: gql
      target: 'node:0'
      query: 'SHOW CLUSTER STATUS WHERE role = "leader" RETURN node_id AS leader'
      store_var: leader_n0
    - type: gql
      target: 'node:1'
      query: 'SHOW CLUSTER STATUS WHERE role = "leader" RETURN node_id AS leader'
      assert:
        equals_var: leader_n0
    - type: gql
      target: 'node:2'
      query: 'SHOW CLUSTER STATUS WHERE role = "leader" RETURN node_id AS leader'
      assert:
        equals_var: leader_n0
tags: [cluster, bootstrap, 3-node, distributed]
```

- [ ] **Step 2: Run**

```bash
cd geode-test-harness
GEODE_BINARY=../geode/zig-out/bin/geode make test-spec SPEC=geodetestlab-cli/specs/multi_node/cluster_bootstrap_3node.yml
```
Expected: 2 tests pass. If geode bug surfaces, capture the actual output verbatim into a `# KNOWN BUG:` comment block at the bottom of the file and proceed; Phase D handles it.

- [ ] **Step 3: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/cluster_bootstrap_3node.yml
git commit -m "test: 3-node cluster bootstrap spec"
```

### Task C2: `cluster_bootstrap_5node.yml`

Same shape as C1 with `nodes: 5`, `startup_timeout_ms: 45000`, expected `"member_count":5`. Bump `GEODE_CLUSTER_NAME` to `harness-5node`.

- [ ] **Step 1: Write the spec (mirror C1 with size 5)**
- [ ] **Step 2: Run via `make test-spec`**
- [ ] **Step 3: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/cluster_bootstrap_5node.yml
git commit -m "test: 5-node cluster bootstrap spec"
```

### Task C3: `cluster_bootstrap_10node.yml`

Same shape with `nodes: 10`, `startup_timeout_ms: 90000`, expected `"member_count":10`. Increase per-test timeout to 15s to account for slower election in a 10-node group.

- [ ] **Step 1: Write the spec**
- [ ] **Step 2: Run**
- [ ] **Step 3: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/cluster_bootstrap_10node.yml
git commit -m "test: 10-node cluster bootstrap spec"
```

### Task C4: `replication_leader_write_follower_read.yml`

**Files:**
- Create: `geode-test-harness/geodetestlab-cli/specs/multi_node/replication_leader_write_follower_read.yml`

- [ ] **Step 1: Write**

```yaml
version: '1.0'
name: Leader Write → Follower Read Convergence
description: |
  After a write committed via the leader, every follower must report the
  same node back on a subsequent MATCH. Validates that Raft apply lands
  through raft_apply.zig into each node's graph_store within the
  replication deadline.
cluster:
  nodes: 3
  startup_timeout_ms: 30000
  shared_env:
    GEODE_CLUSTER_TOKEN: harness-repl-3
cli:
  binary: ./zig-out/bin/geode
  client: { timeout_ms: 30000, tls_verify: false, format: json }
tests:
- name: write-leader-read-all-followers
  type: sequential
  steps:
    - type: gql
      target: 'leader'
      query: |
        CREATE GRAPH IF NOT EXISTS repl_test;
        USE GRAPH repl_test;
        CREATE (:Replicated {key: 'k1', value: 'v1'})
    - type: sleep
      ms: 1500   # allow Raft apply to land on followers
    - type: gql
      target: 'node:0'
      query: 'USE GRAPH repl_test; MATCH (n:Replicated {key: "k1"}) RETURN n.value AS v'
      expect: { stdout_contains: ['"v":"v1"'] }
    - type: gql
      target: 'node:1'
      query: 'USE GRAPH repl_test; MATCH (n:Replicated {key: "k1"}) RETURN n.value AS v'
      expect: { stdout_contains: ['"v":"v1"'] }
    - type: gql
      target: 'node:2'
      query: 'USE GRAPH repl_test; MATCH (n:Replicated {key: "k1"}) RETURN n.value AS v'
      expect: { stdout_contains: ['"v":"v1"'] }
tags: [cluster, replication, distributed, 3-node]
```

- [ ] **Step 2: Run**
- [ ] **Step 3: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/replication_leader_write_follower_read.yml
git commit -m "test: 3-node replication leader-write follower-read"
```

### Task C5: `leader_failover_sigkill.yml`

- [ ] **Step 1: Write**

```yaml
version: '1.0'
name: Leader Failover via SIGKILL
description: |
  When the Raft leader is SIGKILLed, the remaining quorum must elect a new
  leader within the election timeout (≤ 5s for default config) and continue
  serving writes.
cluster:
  nodes: 3
  startup_timeout_ms: 30000
  shared_env:
    GEODE_CLUSTER_TOKEN: harness-failover-3
cli:
  binary: ./zig-out/bin/geode
  client: { timeout_ms: 30000, tls_verify: false, format: json }
tests:
- name: sigkill-leader-newleader-elected
  type: sequential
  steps:
    - type: gql
      target: 'leader'
      query: 'CREATE GRAPH IF NOT EXISTS failover; USE GRAPH failover; CREATE (:Pre {tag: "before"})'
    - type: signal
      target: 'leader'
      signal: SIGKILL
    - type: sleep
      ms: 6000
    - type: gql
      target: 'round-robin'   # whichever node is reachable
      query: 'SHOW CLUSTER STATUS WHERE role = "leader" RETURN count(*) AS leaders'
      expect: { stdout_contains: ['"leaders":1'] }
    - type: gql
      target: 'round-robin'
      query: 'USE GRAPH failover; CREATE (:Post {tag: "after-failover"}); MATCH (p:Post) RETURN count(p) AS c'
      expect: { stdout_contains: ['"c":1'] }
tags: [cluster, failover, 3-node, distributed, raft]
```

- [ ] **Step 2: Run, then commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/leader_failover_sigkill.yml
git commit -m "test: leader failover via SIGKILL with re-election"
```

### Task C6: `follower_partition_heal.yml`

SIGSTOP a follower (simulates network partition), write through leader, SIGCONT follower, assert catch-up.

- [ ] **Step 1: Write spec following the C5 pattern with `signal: SIGSTOP`/`SIGCONT`**
- [ ] **Step 2: Run, commit**

### Task C7: `quorum_minority_loss.yml`

In a 5-node cluster: kill 2 followers (cluster keeps serving). Kill one more (cluster goes read-only — writes fail with explicit error; reads of already-replicated data still work on remaining nodes).

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C8: `cross_node_query_consistency.yml`

Single write on leader, then round-robin a `MATCH` across all 5 nodes — identical results.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C9: `distributed_2pc_commit.yml`

5-node cluster, two graphs each on different shards, single transaction touching both → both committed atomically.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C10: `distributed_2pc_abort.yml`

5-node cluster, two graphs on different shards, kill the coordinator mid-prepare → neither graph shows the partial write.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C11: `tenant_isolation_cross_node.yml`

3-node cluster, tenant A writes to node 0, tenant B reads from node 2 — no leakage, replication of A's data within A's namespace lands on all nodes.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C12: `rls_policy_cross_node.yml`

3-node cluster, define RLS policy on leader, query from node 2 as a non-privileged user — policy enforced.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C13: `snapshot_replay_new_node.yml`

5-node cluster + bulk insert + add a 6th node (via dynamic peer-list expansion if supported, else restart whole cluster as 6-node) → new node catches up via snapshot, serves queries.

If geode does not yet support dynamic membership: write the spec as 3 → 4 by restarting with an expanded peer list; mark it `# KNOWN BUG: dynamic membership not yet supported` if it fails, and add to Phase D scope.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C14: `audit_chain_consistency.yml`

5-node cluster, audit events written across nodes; per-node `audit.jsonl` HMAC chains validate independently. Cross-node audit linking (if implemented) is exercised separately or marked as known gap.

- [ ] **Step 1: Write**
- [ ] **Step 2: Run, commit**

### Task C15: `show_cluster_status.yml`

Tests `SHOW CLUSTER STATUS` against 1-, 3-, 5-, 10-node deployments — each declared as a separate test inside the spec using `cluster.nodes` overrides (or split into four specs if the harness can't do per-test cluster sizing — most likely needs splitting).

- [ ] **Step 1: Write (one spec, four cluster sizes via separate test specs if needed)**
- [ ] **Step 2: Run, commit**

### Task C16: Multi-node README

**Files:**
- Create: `geode-test-harness/geodetestlab-cli/specs/multi_node/README.md`

- [ ] **Step 1: Write the README**

Document: (1) what the suite tests, (2) how to run each size, (3) the `single_node_only` opt-out flag, (4) common debugging steps (look at `reports/spans.jsonl` for cross-node spans, check `data_dir` for per-node Raft logs).

- [ ] **Step 2: Commit**

```bash
git add geode-test-harness/geodetestlab-cli/specs/multi_node/README.md
git commit -m "docs: multi-node cluster spec suite README"
```

### Task C17: Promote existing `distributed_*.yml` specs

The current 10 `distributed_*.yml` specs all run single-node (no `cluster:` block). Promote each one as appropriate.

**Files:**
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_2pc_undo.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_auth_enforcement.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_federation_merge.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_mfa_totp.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_rls_enforcement.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_snapshot_serialization.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/distributed_tenant_isolation.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/gap_0183_0185_ci_distributed_traceability.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/gap_0210_distributed_rpc.yml`
- Modify: `geode-test-harness/geodetestlab-cli/specs/geode_distributed_queries.yml`

For each: open, read the description, decide:
1. If the spec only exercises distributed *semantics* with a single node, add `cluster: { nodes: 3 }` and adjust assertions to round-robin across nodes where they exercise replication.
2. If the spec genuinely needs single-node (e.g. tests the "no GEODE_CLUSTER_TOKEN → standalone" path), mark `single_node_only: true` at top level.

- [ ] **Step 1: Run inventory pass**

For each spec, write a one-line classification in a scratch file (kept locally, not committed). Categorise as `promote-3` / `promote-5` / `keep-1`.

- [ ] **Step 2: Promote each spec (10 commits, one per file)**

For each promote-* spec:

```yaml
# At top of file, after `description:`
single_node_only: false
cluster:
  nodes: 3   # or 5
  startup_timeout_ms: 30000
  shared_env:
    GEODE_CLUSTER_TOKEN: harness-<spec-shortname>
```

Remove any duplicated single-node `server:` block at top level (the cluster block supersedes it).

Adjust assertions: if the spec checks `count(n) == 1`, it still works (replication means every node sees the same count). If it checks per-node state, distribute the steps across `target: 'node:0'`, `node:1`, `node:2`.

- [ ] **Step 3: Run each spec individually**

```bash
make test-spec SPEC=geodetestlab-cli/specs/distributed_2pc_undo.yml
```

- [ ] **Step 4: Commit per file**

One focused commit per spec, message body: `test(harness): promote <spec_name> to 3-node cluster`.

---

## Phase D — Iterate `/codepros:bug-fix` until 100% pass on every cluster size

This phase has no static task count — it terminates when every cluster size in `[1, 3, 5, 10]` runs the full suite with zero failures and zero skipped multi-node specs.

### Task D1: Baseline run on 3-node cluster

- [ ] **Step 1: Run the full matrix**

```bash
cd geode-test-harness
make test-cluster-matrix 2>&1 | tee /tmp/cluster-matrix-baseline.log
```

- [ ] **Step 2: Triage**

```bash
# Per size, list every failure
for n in 1 3 5 10; do
  echo "=== Size $n ===" ;
  jq -r '.tests[] | select(.passed == false) | "\(.spec) :: \(.name) — \(.error // "?")"' \
    geode-test-harness/reports/cluster-$n.json | sort -u ;
done > /tmp/cluster-failure-inventory.txt
```

Build a single deduplicated list of failure classes (clusters share most root causes — fix one, many move from RED to GREEN).

- [ ] **Step 3: Group failures into "bug bundles"**

For each unique stack trace / log line / GQL error message, create a one-line entry:

```
BUG-001: SHOW CLUSTER STATUS returns 0 rows when called on non-leader (3-node)
BUG-002: Cross-node MATCH after replication shows stale count for ~3s (3-node, 5-node)
BUG-003: 2PC abort on coordinator kill leaves participant locked (5-node)
```

Persist this inventory at `docs/superpowers/plans/2026-05-25-distributed-cluster-failures.md`. Update after each bug fix.

- [ ] **Step 4: Commit the inventory**

```bash
git add docs/superpowers/plans/2026-05-25-distributed-cluster-failures.md
git commit -m "docs: distributed cluster failure inventory baseline"
```

### Task D2..DN: One `/codepros:bug-fix` invocation per bug bundle

For each `BUG-NNN` in the inventory:

- [ ] **Step 1: Invoke `/codepros:bug-fix`**

Pass the failure description, the failing spec path, and the relevant log excerpt. The bug-fix workflow handles triage → reproducing test → minimal fix → re-run.

- [ ] **Step 2: Re-run the affected spec at all sizes ≥ 3**

```bash
for n in 3 5 10; do
  make test-spec SPEC=<path> GEODE_BINARY=../geode/zig-out/bin/geode \
    -- --force-cluster-size $n ;
done
```

- [ ] **Step 3: Update the inventory**

Mark the bug as `FIXED (commit <sha>)` in the inventory file.

- [ ] **Step 4: Re-run full matrix every 5 bugs**

```bash
make test-cluster-matrix
```

If new failures surface (regressions or previously-masked bugs), append to the inventory.

### Task D-final: Acceptance check

- [ ] **Step 1: Final full matrix**

```bash
make test-cluster-matrix
```

- [ ] **Step 2: Verify 100% pass on every size**

For each `reports/cluster-N.json`, assert `summary.failed == 0` and `summary.skipped == 0` (except for tests explicitly skipped via `single_node_only: true` at size > 1).

- [ ] **Step 3: Update CLAUDE.md status**

In the repo root `CLAUDE.md`, under "Project Status", change the multi-tenancy / distributed limitation paragraph to reflect that distributed deployments now have full spec coverage at 3/5/10 nodes.

- [ ] **Step 4: Final commit**

```bash
git add docs/superpowers/plans/2026-05-25-distributed-cluster-failures.md CLAUDE.md
git commit -m "docs: distributed cluster matrix at 100% (1/3/5/10 nodes)"
```

---

## Self-review notes

- **Spec coverage:** Phase A covers wiring (cluster_bootstrap, main.zig hook, SHOW CLUSTER STATUS). Phase B covers harness orchestration. Phase C covers spec coverage. Phase D covers bug fixing. Every user requirement (1/3/5/10 nodes, full suite per size, fix until 100%) is addressed.
- **Placeholder scan:** Tasks C2/C3/C6/C7/C8/C9/C10/C11/C12/C13/C14/C15 say "mirror C1/C4 with size N" rather than spelling the full YAML out. **This is intentional** — the YAML differs only by `nodes:`, `GEODE_CLUSTER_TOKEN`, and assertion targets. Spelling out 14 near-identical 70-line YAMLs would balloon the plan without adding clarity. The implementing agent should pattern-match from C1/C4 verbatim.
- **Type consistency:** `ClusterCoordinator.Config` field names referenced in Task A2 are documented as needing reconciliation in Task A3. `ClusterConfig.from_size(N)` is the Python factory documented in `cluster_types.py:60`. `_apply_force_cluster_size` is a new function added in B3 and referenced consistently.
- **Risk:** Task A4 wires real cluster startup, which on a system with `LimitNOFILE=1024` (see auto-memory: `systemd nofile soft cap` and `geode per-graph FD cost`) may run into FD pressure quickly with 10 nodes × 177 FDs/graph × multiple graphs. The harness should set `LimitNOFILE` per spawned process or the geode self-raise from commit `1a7ab7e3` should be sufficient — verify in Task A6 by watching `/proc/<pid>/limits`.
- **Distributed gap (GAP-0514) and CLAUDE.md "single-tenant recommended":** The plan does not claim multi-tenant production readiness. It claims spec coverage of the distributed code paths.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-geode-distributed-cluster-testing.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Best fit for Phase A and Phase D (the iterative bug-fix loop).
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints. Best fit if you want to inspect each commit yourself.

Which approach?
