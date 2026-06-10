# Cluster Write-Routing Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every silent-divergence hole in cluster (Raft) mode: replicate `MATCH…CREATE` edge writes through Raft (the live bug), fail-close every other ungated durable write surface, and make follower FTS state converge with the leader.

**Architecture:** Geode's cluster write doctrine is fail-closed per statement-handler: `clusterWriteRole()` (`src/execution/crud_operations.zig:1780`) returns `.standalone` (no coordinator → local path), `error.ClusterNotLeader` (follower → reject), or `.leader` (must replicate via `coord.proposeWrite` + `waitForApplied`, or fail with `error.ClusterWriteNotReplicable`). Slice 1 mirrors the existing GUPD slice (`clusterReplicateMatchSet`, `crud_operations.zig:3443`) for MATCH…CREATE, reusing the GNC2 codec's `.absolute_id` endpoints (`src/distributed/cluster_replication.zig:280`) — **no new Raft tag needed**. Slice 2 adds a fail-closed gate helper for surfaces with no replication slice (timeseries ingest, auth/policy/tenant/index/graph DDL, TDE/CDC/FLE). Slice 3 fixes the apply-path asymmetry where followers never fire FTS live-maintenance.

**Tech Stack:** Zig 0.16, Raft via `src/distributed/` (cluster.zig coordinator, cluster_replication.zig codecs, raft_apply.zig dispatch), subprocess 3-node cluster tests in `tests/test_cluster_replicable_mutations.zig`, in-process codec tests in `tests/test_raft_apply.zig`.

**Branch/commit convention:** Work directly on `main` (repo convention — recent fixes commit straight to main). Every commit message ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Pre-push runs 4-shard tests, so failing tests may be committed locally but only push once green. `make fmt` before every commit. Every new implementation needs a CANARY marker (repo convention; copy the format of neighbors).

**Authoritative bug context:** `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md:971-1037` (the MATCH…CREATE hole, live-confirmed leader-only AND follower-only divergence).

---

## Verified code map (read before each task)

| What | Where |
|---|---|
| Ungated dispatch | `src/execution/query_execution.zig:1686-1689` — `MATCH+CREATE` → `executeMatchCreateQuery(allocator, q, param_names.items, param_values.items, create_graph)`, no gate, no `context` |
| Ungated handler | `src/execution/match_operations.zig:1377` `executeMatchCreateQuery`; local writes via `executeCreateForBatchWithTracking` at `:1593`; ungated DELETE sub-path `:1612-1648`; ungated REMOVE sub-path `:1650-1673`; mislabeled summary column `"nodes_created"` `:1709-1716` |
| Gate primitive | `src/execution/crud_operations.zig:1780` `fn clusterWriteRole() error{ClusterNotLeader}!ClusterWriteRole` |
| Pattern to mirror (dispatch wrapper) | `crud_operations.zig:3647` `executeClusterMatchUpdateIfNeeded` (standalone→null, leader→replicate) |
| Pattern to mirror (leader slice) | `crud_operations.zig:3443` `clusterReplicateMatchSet` — validates shape fail-closed, resolves candidates via `collectCandidateNodeIds` + `nodeMatchesPattern` + `evaluatePatternProps` + `tenantFilterFromContext`, binds matched node into `Env` for WHERE eval, serializes, `proposeWrite` (`error.NotLeader → error.ClusterNotLeader`), `waitForApplied(idx, 5000)` |
| Edge-create slice (standalone CREATE chain) | `crud_operations.zig:2019` `clusterReplicateEdgeCreate` + `buildEdgeCreateSpecs` `:1925` (positions only — all-new nodes) |
| GNC2 codec | `cluster_replication.zig:280` `Endpoint = union(enum){position: u32, absolute_id: u64}`; `NodeSpec`/`EdgeSpec` `:286-294`; `serializeMultiCreate` `:349` (accepts 0 nodes + N edges; caps `MAX_MULTI_NODES/EDGES = 32` `:255`); `applyMultiCreatePayload` `:421` already resolves `.absolute_id` and is restart-idempotent |
| Raft command shape | `raft_consensus.Command{ .graph_mutation = .{ .graph, .mutation_type = .create/.update/.delete, .data = payload, .txn_id = null } }` |
| Cluster e2e test harness | `tests/test_cluster_replicable_mutations.zig` — `startCluster` `:322`, `assertMutationReplicates` `:430` (runs mutation on leader, polls followers), `seedReplicableNode` `:511`, `runQuery(gpa, io, aa, ip, q)`; build step `test-cluster-replicable-mutations` (`build.zig:1467`) |
| In-process codec tests | `tests/test_raft_apply.zig` (GNC2 round-trips, apply-twice idempotency) — step `test-raft-apply` |
| Ungated CALL surfaces | `src/execution/ts_dispatch.zig:173` `handleInsert` / `:187` `handleInsertMany` (→ `store.insertMany`, durable WAL, never replicated); `src/execution/tenant_dispatch.zig:92/94/96`; TDE/CDC/FLE in `src/execution/storage_dispatch.zig` |
| Ungated DDL surfaces | auth DDL `src/execution/admin_ddl.zig:60/70/83/94/101/109/120` (+ `auth_dispatch.zig` grant/revoke `:1182`); policy DDL `src/execution/execution.zig:2049/2127/2192`; index DDL `execution.zig:1415` + DropIndex branch; graph DDL `execution.zig:1699/1770` (Raft deliberately disabled, comment `:1724`); constraints `execution.zig:1524+` |
| FTS apply asymmetry | executor fires `maintainFulltextOnWrite` (`src/execution/property_mutation.zig:326`) but apply paths (`cluster_replication.zig` applies, GUPD `:784+`, GMRG `:672`, GNC1/GNC2 creates) call `store.setNodeProperty`/`createNodeWithId` directly → follower FTS indexes silently stale. Snapshot install (`src/distributed/raft_snapshot_manager.zig:40-62`) wipes via `clearNodes` and never rebuilds FTS |

**Verified-latent (NOT holes, do not "fix"):** the MATCH…SET mutation sites at `match_operations.zig:5479/7221/8254` are reachable in cluster mode ONLY through the dispatch gate at `query_execution.zig:1770` (any `set_clauses`/`remove_clauses` is intercepted: follower → ClusterNotLeader, leader → replicate-or-fail-closed). Leave them; Task 14 documents this.

---

## Slice 1 — MATCH…CREATE edge replication (the live bug)

**Slice scope (fail-closed for everything else):** every MATCH chain is a simple head-only node pattern with a variable name (`chain.hops.len == 0`); each matched variable resolves to **exactly one** node (0 matches → no-op empty result; >1 → `error.ClusterWriteNotReplicable` — no Cartesian in v1); the CREATE pattern's endpoints are **pure references to matched variables** (no labels, no props on the endpoint patterns — a new node in the CREATE pattern is out of slice v1); no RETURN / WITH / FILTER / DELETE items / REMOVE clauses / SET clauses; edge props must evaluate to replicable scalars; ≤ 32 edges. This exactly covers the live repro `MATCH (a:MT {id:1}),(b:MT {id:2}) CREATE (a)-[:MTL]->(b)` — the everyday "link two existing nodes" shape.

### Task 1: In-process pin test — GNC2 absolute-id edge apply

**Files:**
- Modify: `tests/test_raft_apply.zig` (append tests at end, mirroring the existing GNC2 test style in that file)

- [ ] **Step 1: Read the existing GNC2 tests** in `tests/test_raft_apply.zig` (grep for `GNC2` / `serializeMultiCreate`) to copy their store-setup + apply-call conventions exactly (allocator, store init/deinit, how they call `applyMultiCreatePayload` or go through `raft_apply` dispatch).

- [ ] **Step 2: Write the pin test** — a GNC2 payload with **0 nodes + 1 edge** whose endpoints are `.absolute_id` references to two pre-created store nodes, applied twice (idempotency):

```zig
test "GNC2: zero-node payload with absolute_id endpoints creates edge between pre-existing nodes, idempotently" {
    // setup store per existing convention in this file, then:
    // pre-create two nodes with known ids (use the same store node-create helper the
    // other tests use; record their ids as src_id / dst_id)
    const edge_specs = [_]cluster_replication.EdgeSpec{.{
        .from = .{ .absolute_id = src_id },
        .to = .{ .absolute_id = dst_id },
        .edge_type = "MCL",
        .props = &.{},
    }};
    const payload = try cluster_replication.serializeMultiCreate(alloc, "default", &.{}, &edge_specs);
    defer alloc.free(payload);

    const n1 = try cluster_replication.applyMultiCreatePayload(alloc, store, payload, 4242);
    try std.testing.expect(n1 >= 1);
    // assert exactly one MCL edge exists from src_id to dst_id (use the store edge
    // accessor the sibling tests use)

    // re-apply (restart replay) must be a no-op: still exactly one edge
    _ = try cluster_replication.applyMultiCreatePayload(alloc, store, payload, 4242);
    // assert STILL exactly one MCL edge
}
```

- [ ] **Step 3: Run it.** `zig build test-raft-apply 2>&1 | tail -20`. Expected: PASS (the codec already supports this — this test pins the contract the leader slice depends on). If it FAILS, the apply path has a real gap: fix `applyMultiCreatePayload`'s absolute-id resolution minimally until green, and note it.

- [ ] **Step 4: Commit.**

```bash
git add tests/test_raft_apply.zig
git commit -m "test: pin GNC2 zero-node absolute-id edge apply (idempotent)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 2: Red cluster regression tests for MATCH…CREATE

**Files:**
- Modify: `tests/test_cluster_replicable_mutations.zig` (append two tests; copy the style of `test "cluster: edge CREATE replicates to followers"` at `:531` and the existing follower fail-closed test — grep `ClusterNotLeader` in the file for the follower-rejection assertion pattern)

- [ ] **Step 1: Write the replication test** (FAILS at HEAD — leader writes locally, returns 00000, followers never converge → `error.ReplicationIncomplete`):

```zig
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=ReplicateMatchCreateEdge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
test "cluster: MATCH…CREATE edge between existing nodes replicates to followers" {
    if (skipPreflight()) return error.SkipZigTest;
    // … standard arena/io/startCluster boilerplate copied from test at :531 …

    // Seed both endpoints through the (working) replicable CREATE path.
    try seedReplicableNode(&cluster, "McSrc", "CREATE (n:McSrc {id:1})");
    try seedReplicableNode(&cluster, "McDst", "CREATE (n:McDst {id:2})");

    // THE LIVE BUG: at HEAD this returns 00000 on the leader, writes the edge
    // leader-local only, and never proposes through Raft.
    try assertMutationReplicates(
        &cluster,
        "MatchCreateEdge",
        "MATCH (a:McSrc {id:1}), (b:McDst {id:2}) CREATE (a)-[:MCL]->(b)",
        "MATCH (:McSrc)-[r:MCL]->(:McDst) RETURN count(r) AS c",
        "\"c\":1",
    );
}
```

- [ ] **Step 2: Write the follower fail-closed test** — find the existing follower-rejection test in this file (grep `follower` / `ClusterNotLeader`), copy its mechanism (send `runQuery` to a non-leader `NODE_IPS[fi]`, assert the output contains `ClusterNotLeader`), with the mutation `MATCH (a:McSrc {id:1}), (b:McDst {id:2}) CREATE (a)-[:FOLLOWERMCL]->(b)` after seeding. At HEAD the follower returns success (the bug) → test FAILS. Also assert afterwards that `count(r)` for `FOLLOWERMCL` is `0` on that follower (nothing landed locally).

- [ ] **Step 3: Run to verify both FAIL.** `zig build test-cluster-replicable-mutations 2>&1 | tail -40` (slow: spawns 3-node subprocess clusters; if it skips due to environment, run the binary directly per the file's preflight notes — `zig build` first so `BINARY_PATH` exists). Expected: the two NEW tests fail (`ReplicationIncomplete` / follower-accepted-write assert), pre-existing tests still pass.

- [ ] **Step 4: Commit (failing tests; do NOT push).**

```bash
git add tests/test_cluster_replicable_mutations.zig
git commit -m "test: red regression for MATCH…CREATE edge cluster divergence

Reproduces the silent-divergence hole: MATCH (a),(b) CREATE (a)-[:R]->(b)
bypasses clusterWriteRole() on leader and follower.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 3: Leader slice — `clusterReplicateMatchCreate`

**Files:**
- Modify: `src/execution/crud_operations.zig` (add two functions next to `executeClusterMatchUpdateIfNeeded` at `:3647`)

- [ ] **Step 1: Re-read** `clusterReplicateMatchSet` (`crud_operations.zig:3443-3657`) and `clusterReplicateEdgeCreate` (`:2019-2091`) — the new function is their hybrid. Also check the exact type of `q.create_pattern` (grep `create_pattern` in `src/gql/ast.zig`) — it carries the CREATE chains; adapt the chain iteration below to its real shape (if it is a single pattern with `.chains`, iterate those; mirror how `executeCreateForBatchWithTracking` consumes it).

- [ ] **Step 2: Implement.** Add after `executeClusterMatchUpdateIfNeeded`:

```zig
/// Replicate an eligible `MATCH (a:L {p}),(b:M {q}) CREATE (a)-[:R {props}]->(b)`
/// through Raft as a GNC2 multi-create with ZERO new nodes and absolute_id
/// endpoints. Called ONLY on the cluster leader.
///
/// THE SILENT-DIVERGENCE FIX (2026-06-04 bug doc §MATCH…CREATE): at HEAD this
/// shape reached createEdgeWithGraph with no clusterWriteRole() gate on EVERY
/// node — leader-local and follower-local edges, never proposed through Raft.
/// Here the LEADER resolves each MATCH variable to exactly ONE stable node id
/// and ships explicit endpoint ids; followers never re-MATCH.
///
/// Scope (fail-closed for anything else):
///   * every MATCH chain: head-only (no hops), named variable,
///   * each variable resolves to EXACTLY one node (0 → no-op; >1 → fail closed),
///   * CREATE endpoints are pure var refs (no labels/props on endpoint patterns),
///   * no RETURN / WITH / FILTER / SET / REMOVE / DELETE attached,
///   * scalar edge props only; ≤ MAX_MULTI_EDGES edges.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=LeaderProposeMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
fn clusterReplicateMatchCreate(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // Attached clauses whose semantics this slice does not model → fail closed.
    if (q.ret.items.len > 0) return error.ClusterWriteNotReplicable;
    if (q.with_clause != null or q.filter_clause != null) return error.ClusterWriteNotReplicable;
    if (q.set_clauses.len > 0 or q.remove_clauses.len > 0) return error.ClusterWriteNotReplicable;
    if (q.delete_items.len > 0) return error.ClusterWriteNotReplicable;

    const read_store = graph_store.getWritableGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    const filter_tenant = try tenantFilterFromContext(context);

    // Resolve every MATCH variable to exactly one stable node id.
    var var_names = std.ArrayList([]const u8).empty;
    defer var_names.deinit(allocator);
    var var_nodes = std.ArrayList(Value).empty; // .Node values for WHERE/prop Env
    defer var_nodes.deinit(allocator);
    var var_ids = std.StringHashMap(u64).init(allocator);
    defer var_ids.deinit();

    for (q.match.chains) |chain| {
        if (chain.hops.len != 0) return error.ClusterWriteNotReplicable;
        const node_pattern = chain.head orelse return error.ClusterWriteNotReplicable;
        const match_var = node_pattern.name orelse return error.ClusterWriteNotReplicable;

        const evaluated_props = evaluatePatternProps(allocator, node_pattern.props, context) catch
            return error.ClusterWriteNotReplicable;
        defer freeEvaluatedPatternProps(allocator, evaluated_props);

        const candidate_ids = try collectCandidateNodeIds(
            allocator, read_store, filter_graph, filter_tenant,
            node_pattern.labels, evaluated_props,
        );
        defer allocator.free(candidate_ids);

        var resolved: ?u64 = null;
        for (candidate_ids) |node_id| {
            const node = read_store.nodes.getPtr(node_id) orelse continue;
            if (!nodeMatchesPattern(node, filter_graph, filter_tenant, node_pattern.labels, evaluated_props)) continue;
            if (resolved != null) return error.ClusterWriteNotReplicable; // ambiguous: >1 match
            resolved = node_id;
        }
        const rid = resolved orelse {
            // No match → semantically a no-op; short-circuit WITHOUT proposing.
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        };
        try var_names.append(allocator, match_var);
        try var_nodes.append(allocator, Value{ .Node = read_store.nodes.getPtr(rid).? });
        try var_ids.put(match_var, rid);
    }

    const env = Env{
        .allocator = allocator,
        .names = var_names.items,
        .values = var_nodes.items,
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };

    // WHERE evaluates on the leader with all matched vars bound.
    if (q.where_clause) |where_expr| {
        const where_result = eval.evalExpr(allocator, where_expr, env) catch
            return error.ClusterWriteNotReplicable;
        const keep = switch (where_result) {
            .Bool => |b| b,
            else => false,
        };
        if (!keep) return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Build edge specs from the CREATE pattern: endpoints must be pure refs to
    // matched vars (no labels, no props) → .absolute_id. Adapt the chain access
    // to the real ast shape of q.create_pattern (see Step 1).
    var edge_specs = std.ArrayList(cluster_replication.EdgeSpec).empty;
    defer edge_specs.deinit(allocator);

    const create_pattern = q.create_pattern.?;
    for (create_pattern.chains) |cchain| {
        if (cchain.hops.len == 0) return error.ClusterWriteNotReplicable; // bare node create out of slice
        for (cchain.hops) |hop| {
            if (hop.rel.min_len != null or hop.rel.max_len != null)
                return error.ClusterWriteNotReplicable;

            const EndpointOf = struct {
                fn run(np: ast.NodePattern, ids: *std.StringHashMap(u64)) error{ClusterWriteNotReplicable}!u64 {
                    const nm = np.name orelse return error.ClusterWriteNotReplicable;
                    if (np.labels.len != 0) return error.ClusterWriteNotReplicable;
                    if (np.props != null and np.props.?.len != 0) return error.ClusterWriteNotReplicable;
                    return ids.get(nm) orelse error.ClusterWriteNotReplicable;
                }
            };
            const left_id = try EndpointOf.run(hop.left, &var_ids);
            const right_id = try EndpointOf.run(hop.right, &var_ids);
            const from_id = if (hop.rel.dir == .left) right_id else left_id;
            const to_id = if (hop.rel.dir == .left) left_id else right_id;

            // Scalar edge props, evaluated on the leader (matched vars bound).
            var eprops: []cluster_replication.Prop = &.{};
            if (hop.rel.props) |plist| {
                const out = try allocator.alloc(cluster_replication.Prop, plist.len);
                for (plist, 0..) |p, i| {
                    const val = eval.evalExpr(allocator, p.value.*, env) catch
                        return error.ClusterWriteNotReplicable;
                    const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
                    out[i] = .{ .key = p.key, .value = pv };
                }
                eprops = out;
            }

            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            try edge_specs.append(allocator, .{
                .from = .{ .absolute_id = from_id },
                .to = .{ .absolute_id = to_id },
                .edge_type = rel_type,
                .props = eprops,
            });
            if (edge_specs.items.len > cluster_replication.MAX_MULTI_EDGES)
                return error.ClusterWriteNotReplicable;
        }
    }
    if (edge_specs.items.len == 0) return error.ClusterWriteNotReplicable;

    const payload = cluster_replication.serializeMultiCreate(
        allocator, filter_graph, &.{}, edge_specs.items,
    ) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType,
        cluster_replication.CodecError.CorruptPayload,
        => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload);

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = filter_graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    try coord.waitForApplied(idx, 5000);

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Cluster write routing for `MATCH … CREATE …`. Returns null in standalone
/// mode (unchanged local path). Follower → error.ClusterNotLeader. Leader →
/// replicate-or-fail-closed. CLOSES THE 2026-06-04 SILENT-DIVERGENCE HOLE.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=ExecutorRouteMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
pub fn executeClusterMatchCreateIfNeeded(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !?ExecutionResult {
    switch (try clusterWriteRole()) {
        .standalone => return null,
        .leader => return try clusterReplicateMatchCreate(allocator, q, current_graph, context),
    }
}
```

Memory-management note: follow `clusterReplicateMatchSet`'s ownership discipline exactly — if the per-statement allocator is NOT an arena, add the same `defer`/`errdefer` frees for the eprops slices (`:3509-3522` shows the convention). Check how `clusterReplicateEdgeCreate` handles its spec allocations (`:1922-1924` says arena-style off the per-statement allocator, serializer deep-copies) and match it.

- [ ] **Step 3: Compile.** `zig build 2>&1 | tail -20`. Expected: clean. Fix type mismatches against the real ast shapes (hop.rel field names, props optionality) by reading `src/gql/ast.zig` — `buildEdgeCreateSpecs` (`:1925-2006`) uses the identical accessors, so copy from there verbatim.

- [ ] **Step 4: Commit.**

```bash
git add src/execution/crud_operations.zig
git commit -m "feat(cluster): leader-side MATCH…CREATE edge replication slice (GNC2 absolute_id)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 4: Dispatch gate + green cluster tests

**Files:**
- Modify: `src/execution/query_execution.zig:1685-1689`

- [ ] **Step 1: Gate the dispatch.** Replace the MATCH+CREATE dispatch block:

```zig
    // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
    if (q.match.chains.len > 0 and q.create_pattern != null) {
        const create_graph = if (context.session_state) |session| session.graph else null;
        // Cluster write routing for MATCH…CREATE (edge attach between matched
        // nodes). At HEAD this reached createEdgeWithGraph with NO gate on every
        // node → permanent silent divergence (2026-06-04 bug doc). Follower →
        // error.ClusterNotLeader; leader resolves endpoints to stable ids and
        // replicates a zero-node GNC2; non-replicable shapes fail closed; the
        // ungated DELETE/REMOVE sub-paths of executeMatchCreateQuery are
        // unreachable in cluster mode (the slice rejects those clauses).
        // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=DispatchRouteMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
        {
            const crud = @import("crud_operations.zig");
            if (try crud.executeClusterMatchCreateIfNeeded(allocator, q, create_graph, context)) |cluster_result| {
                return cluster_result;
            }
        }
        return executeMatchCreateQuery(allocator, q, param_names.items, param_values.items, create_graph);
    }
```

- [ ] **Step 2: Build + run the in-process suites.** `zig build 2>&1 | tail -5 && zig build test-raft-apply 2>&1 | tail -5`. Expected: clean/PASS.

- [ ] **Step 3: Run the cluster regression.** `zig build test-cluster-replicable-mutations 2>&1 | tail -40`. Expected: the two Task-2 tests now PASS (replication converges; follower returns ClusterNotLeader), all pre-existing tests still PASS. Iterate here until green — this is the core red→green of the whole campaign.

- [ ] **Step 4: Check no standalone regression.** Run a quick standalone smoke: `zig build test-gap0336 2>&1 | tail -5` if that step exists (grep `gap0336` in build.zig; `executeMatchCreateQuery` is GAP-0336's feature), else run the match/create-related named steps found via `zig build -l | grep -i -E 'match|create'`. Expected: PASS (standalone path is untouched — gate returns null without a coordinator).

- [ ] **Step 5: Commit.**

```bash
git add src/execution/query_execution.zig
git commit -m "fix(cluster): gate MATCH…CREATE through Raft — closes silent edge-divergence hole

MATCH (a),(b) CREATE (a)-[:R]->(b) previously wrote the edge to the
receiving node's local store only (leader OR follower) and returned 00000.
Follower now fails closed (ClusterNotLeader); leader resolves endpoints to
stable ids and replicates a zero-node GNC2 payload; out-of-slice shapes
fail closed (ClusterWriteNotReplicable).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 5: Counter mislabel fix (`nodes_created` reporting relationships)

**Files:**
- Modify: `src/execution/crud_operations.zig:964` area (the tracking-result struct + its fill sites — grep `created_count` and the struct returned by `executeCreateForBatchWithTracking` at `:803`)
- Modify: `src/execution/match_operations.zig:1415-1421, 1593-1598, 1709-1716`

- [ ] **Step 1: Check harness expectations first.** `grep -rn "nodes_created" ../geode-test-harness/geodetestlab-cli/specs/ geodetestlab-cli/specs/ 2>/dev/null` and `grep -rn "nodes_created" tests/ docs/`. If any spec asserts `nodes_created` on a MATCH…CREATE edge query, the fix must keep that column present (with the now-correct value `0`) and ADD `relationships_created` — do not remove columns.

- [ ] **Step 2: Write the failing unit test.** Find the existing unit-test home for MATCH…CREATE behavior (grep `executeMatchCreateQuery` and `gap0336` under `tests/`); add a test that runs `CREATE` two nodes, then `MATCH (a {..}),(b {..}) CREATE (a)-[:R]->(b)` through the executor (standalone), and asserts the summary row reports `nodes_created = 0` and `relationships_created = 1`. Run it; expected FAIL (today it reports `nodes_created = 1`).

- [ ] **Step 3: Implement.** In the tracking result struct add separate `created_nodes_count: i64` and `created_relationships_count: i64` fields (the locals already exist at `crud_operations.zig:964` — expose them instead of only their sum). In `match_operations.zig` accumulate both, and replace the single-column summary (`:1709-1716`) with two columns:

```zig
    // Default: return summary row showing how many entities were created
    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "nodes_created");
    columns[1] = try allocator.dupe(u8, "relationships_created");

    var rows = try allocator.alloc([]Value, 1);
    var summary_row = try allocator.alloc(Value, 2);
    summary_row[0] = Value{ .Int = total_created_nodes };
    summary_row[1] = Value{ .Int = total_created_relationships };
    rows[0] = summary_row;
```

- [ ] **Step 4: Run the new test + neighbors green.** The Step-2 test passes; run the named steps touching create/match counters (from Step 1 grep results). Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add src/execution/crud_operations.zig src/execution/match_operations.zig tests/
git commit -m "fix: MATCH…CREATE summary mislabeled relationships as nodes_created

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Slice 2 — Fail-closed gates for ungated non-statement write surfaces

**Doctrine:** these surfaces have NO replication slice, so in cluster mode they must fail closed loudly instead of diverging silently: follower → `error.ClusterNotLeader`; leader → `error.ClusterWriteNotReplicable`; standalone → unchanged. This makes the features *unavailable in cluster mode* by design (documented residual; replication slices are follow-up work per surface). Surfaces: timeseries ingest, auth DDL + grant/revoke, policy DDL, tenant ops, index DDL, graph DDL, constraint DDL, TDE/CDC/FLE mutating procedures.

### Task 6: Gate helper + standalone unit test

**Files:**
- Modify: `src/distributed/cluster.zig` (add near `getGlobalClusterCoordinator`)
- Test: same file (inline `test` block, repo style) or the file's existing test home

- [ ] **Step 1: Implement the helper** in `src/distributed/cluster.zig`:

```zig
/// Fail-closed gate for durable write surfaces that have NO Raft replication
/// slice (timeseries ingest, auth/policy/tenant/index/graph/constraint DDL,
/// TDE/CDC/FLE). In cluster mode these writes would land on exactly one node
/// and silently diverge — so they are refused loudly instead. Standalone mode
/// is unaffected.
// CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateHelper; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
pub fn gateUnreplicatedWrite() error{ ClusterNotLeader, ClusterWriteNotReplicable }!void {
    const coord = getGlobalClusterCoordinator() orelse return; // standalone: allowed
    if (coord.role() != .leader) return error.ClusterNotLeader;
    return error.ClusterWriteNotReplicable;
}
```

- [ ] **Step 2: Unit test the standalone path** (no coordinator registered → returns ok). Add an inline test (or in the module's existing test file): `try gateUnreplicatedWrite();` with no global coordinator set. If the test binary environment registers a global coordinator elsewhere, isolate accordingly (check how existing cluster.zig inline tests handle the global).

- [ ] **Step 3: Run + commit.** `zig build test-… ` (find the step covering cluster.zig inline tests via `zig build -l | grep -i cluster`); expected PASS.

```bash
git add src/distributed/cluster.zig
git commit -m "feat(cluster): gateUnreplicatedWrite fail-closed helper for sliceless write surfaces

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 7: Red e2e test — unreplicated surfaces fail closed in cluster mode

**Files:**
- Modify: `tests/test_cluster_replicable_mutations.zig`

- [ ] **Step 1: Write one consolidated test** (single cluster startup, many assertions) that runs each surface against the LEADER expecting `ClusterWriteNotReplicable` in the output, and against a FOLLOWER expecting `ClusterNotLeader`:

```zig
// CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=E2EFailClosed; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
test "cluster: unreplicated write surfaces fail closed (no silent divergence)" {
    if (skipPreflight()) return error.SkipZigTest;
    // … standard startCluster boilerplate …

    const surfaces = [_][]const u8{
        "CALL geode.ts.insert(1, 'temp', 100, 42)",
        "CREATE USER fcuser PASSWORD 'Str0ng!Pass1'",
        "CREATE GRAPH fcgraph",
        // add: CREATE INDEX (fulltext), tenant create, policy DDL — use the exact
        // syntax from docs/GQL_AUTH_DDL.md, docs/TIMESERIES.md, docs/FULLTEXT_SEARCH.md
    };
    for (surfaces) |mq| {
        // leader: must refuse with ClusterWriteNotReplicable
        // follower: must refuse with ClusterNotLeader
        // (mirror the runQuery + indexOf assertion mechanics used by
        //  assertMutationReplicates; auth DDL may need the admin credentials the
        //  harness already uses in runQuery)
    }
}
```

At HEAD each surface SUCCEEDS on both leader and follower → test FAILS (red). Keep the surface list to what the cluster harness can actually express (e.g. drop a surface if the test connection lacks the privilege and note it).

- [ ] **Step 2: Run to verify FAIL.** `zig build test-cluster-replicable-mutations 2>&1 | tail -40`. Expected: new test fails listing which surfaces accepted the write.

- [ ] **Step 3: Commit (failing test, no push).**

```bash
git add tests/test_cluster_replicable_mutations.zig
git commit -m "test: red e2e — unreplicated write surfaces must fail closed in cluster mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 8: Gate timeseries ingest

**Files:**
- Modify: `src/execution/ts_dispatch.zig:173, 187`

- [ ] **Step 1: Add the gate** at the top of both `handleInsert` (`:173`) and `handleInsertMany` (`:187`):

```zig
    // Cluster fail-closed: ts points are durable (WAL) but have no Raft slice —
    // an ungated ingest lands on ONE node and silently diverges. See
    // docs/TIMESERIES.md (cluster limitation).
    // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateTsIngest; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
    try cluster_mod.gateUnreplicatedWrite();
```

Add `const cluster_mod = @import("../distributed/cluster.zig");` to the file's imports (match the import path style used by crud_operations.zig for cluster_mod).

- [ ] **Step 2: Check error surfacing.** Trace how `error.ClusterNotLeader` propagates from a CALL procedure to the wire (the GQL statement paths map it to status `58000` — grep `ClusterNotLeader` in `src/server/` / `quic_connection_handler.zig`). If the CALL dispatch swallows or remaps unknown errors, extend the error-to-status mapping so both gate errors surface with their names (the e2e test asserts on the names).

- [ ] **Step 3: Build + standalone regression.** `zig build 2>&1 | tail -5 && zig build test-ts-ingest 2>&1 | tail -5` (find the exact step name via `zig build -l | grep -i ts`; `tests/ts_ingest_roundtrip.zig` must still pass — it runs standalone, gate returns ok). Commit.

```bash
git add src/execution/ts_dispatch.zig
git commit -m "fix(cluster): fail-close geode.ts ingest in cluster mode (no Raft slice)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 9: Gate auth DDL + grant/revoke

**Files:**
- Modify: `src/execution/admin_ddl.zig` (mutating handlers at `:60/:70/:83/:94/:101/:109/:120` — CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT, REVOKE)
- Modify: `src/execution/auth_dispatch.zig` (the mutating `geode.auth.*` procedure dispatch — grant/revoke at `:1182` and the user/role mutation handlers; do NOT gate reads: SHOW USERS/ROLES/PERMISSIONS and `geode.auth.whoami`-style reads stay open)

- [ ] **Step 1: Identify the minimal choke points.** Read both files' dispatch structure. Prefer ONE gate per mutating entry point (e.g. at the top of each mutating `handle*` / the DDL execute switch arms) over scattering. admin_ddl.zig already imports cluster_mod (line ~20); auth_dispatch.zig needs the import added.

- [ ] **Step 2: Add `try cluster_mod.gateUnreplicatedWrite();`** at each mutating entry with a one-line comment + shared CANARY (`ASPECT=GateAuthDDL`). Auth state persists to `__geode_security` per-node; ungated DDL means users/roles/grants exist on one node only — a security-relevant divergence.

- [ ] **Step 3: Build + run auth unit suites.** `zig build -l | grep -i -E 'auth|user'` → run those steps; expected PASS (standalone unaffected). Commit.

```bash
git add src/execution/admin_ddl.zig src/execution/auth_dispatch.zig
git commit -m "fix(cluster): fail-close auth DDL and grant/revoke in cluster mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 10: Gate policy DDL, tenant ops, index/graph/constraint DDL, TDE/CDC/FLE

**Files:**
- Modify: `src/execution/execution.zig` (policy DDL `:2049/:2127/:2192`; index DDL `:1415` + DropIndex; graph DDL `:1699/:1770`; constraints `:1524+`)
- Modify: `src/execution/tenant_dispatch.zig` (`:92/:94/:96`)
- Modify: `src/execution/storage_dispatch.zig` (mutating TDE/CDC/FLE handlers — enumerate via grep for handler registration; gate only mutating ones, not status/read procedures)

- [ ] **Step 1:** For each site add `try cluster_mod.gateUnreplicatedWrite();` ahead of the first durable write, with a one-line comment + CANARY (`ASPECT=GatePolicyDDL` / `GateTenantOps` / `GateIndexDDL` / `GateGraphDDL` / `GateConstraintDDL` / `GateStorageProcs`). execution.zig already imports cluster_mod (line ~80); add the import to the dispatch files that lack it. For CREATE/DROP GRAPH note in the comment that the data-apply path auto-creates graphs (`GraphAlreadyExists` catch in GNC1/GNC2 apply), so replicated writes into a new graph still work; only the explicit DDL is refused pending a real slice.

- [ ] **Step 2: Build + run the touched suites.** `zig build 2>&1 | tail -5`, then named steps for index/tenant/policy/tde (find via `zig build -l | grep -i -E 'index|tenant|policy|tde|fle|cdc'`). Expected: PASS standalone. If a standalone unit test constructs a global coordinator and now trips the gate, that test IS exercising cluster mode — update it to expect the fail-closed error (that's the new contract), and say so in the commit message.

- [ ] **Step 3: Commit.**

```bash
git add src/execution/execution.zig src/execution/tenant_dispatch.zig src/execution/storage_dispatch.zig
git commit -m "fix(cluster): fail-close policy/tenant/index/graph/constraint/TDE/CDC/FLE writes in cluster mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 11: Green the slice-2 e2e + full local gate

- [ ] **Step 1:** `zig build test-cluster-replicable-mutations 2>&1 | tail -40`. Expected: Task-7 test PASSES (every surface refused on leader and follower), all other tests PASS. Iterate on gaps (most likely: error-name surfacing through the CALL wire path — fix the mapping, not the test).

- [ ] **Step 2: Full pre-push-equivalent sweep.** Run the 4-shard suite the pre-push hook runs (see `.pre-commit-config.yaml` for the exact shard commands) or `python3 scripts/test/extended_test_runner.py`. Expected: baseline 167/175 named steps preserved (KNOWN_TEST_ISSUES.md lists the pre-existing 8).

- [ ] **Step 3: Commit any residual fixes** (`fix(cluster): surface gate errors through CALL wire path` style).

---

## Slice 3 — FTS apply-path / snapshot symmetry

**Problem:** the executor maintains FTS on every write via `maintainFulltextOnWrite` (`src/execution/property_mutation.zig:326`), but follower applies (`cluster_replication.zig` GNC1/GNC2/GMRG/GUPD/GDEL) call store mutators directly → follower FTS search silently diverges. Snapshot install (`raft_snapshot_manager.zig:40-62`) wipes the store and never rebuilds FTS. **Seam constraint:** `src/distributed/` must not import `src/execution/` (check direction first!) — use a registered-callback seam, the same pattern as `g_grant_persist` (grep it in `auth_dispatch.zig`/server startup) and `setGlobalExprRLSEngine` (`src/server/main.zig:638`).

### Task 12: Red in-process test — follower apply misses FTS

**Files:**
- Create: `tests/test_fts_apply_symmetry.zig`
- Modify: `build.zig` (register `test-fts-apply-symmetry` step — copy the registration block of `test-raft-apply` or `test-fts-maintenance`, grep either name in build.zig)

- [ ] **Step 1: Read** `tests/test_fts_maintenance.zig` (how a store + fulltext index + search are wired in-process) and `tests/test_raft_apply.zig` (how payload apply is driven). The new test combines them:

```zig
// CANARY: REQ=REQ-DIST-CLUSTER-FTS-APPLY-SYMMETRY; FEATURE="DistributedCluster"; ASPECT=FtsApplySymmetry; STATUS=TESTED; TEST=tests/test_fts_apply_symmetry.zig; OWNER=distributed; UPDATED=2026-06-10
test "raft apply maintains fulltext index like the executor path" {
    // 1. store with a fulltext index on (:Doc).body  (per test_fts_maintenance.zig conventions)
    // 2. apply a GNC1/GNC2 payload creating a Doc node with body = "replicated raven"
    //    (per test_raft_apply.zig conventions; this simulates the FOLLOWER)
    // 3. FTS search "raven" → expect 1 hit            <-- FAILS at HEAD (0 hits)
    // 4. apply a GUPD payload setting body = "updated osprey" on that node
    // 5. search "osprey" → 1 hit; search "raven" → 0  <-- FAILS at HEAD
}
```

- [ ] **Step 2: Register the build step, run, verify FAIL** at the search assertions. `zig build test-fts-apply-symmetry 2>&1 | tail -20`.

- [ ] **Step 3: Commit (failing test, no push).**

```bash
git add tests/test_fts_apply_symmetry.zig build.zig
git commit -m "test: red — follower raft apply must maintain FTS like the executor path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 13: FTS apply hook (callback seam) + snapshot rebuild

**Files:**
- Modify: `src/distributed/cluster_replication.zig` (callback global + invocations)
- Modify: `src/server/main.zig` (registration at startup, near `setGlobalExprRLSEngine` `:638`)
- Modify: `src/distributed/raft_snapshot_manager.zig` (post-install rebuild)
- Modify: `tests/test_fts_apply_symmetry.zig` (register the hook in-test, mirroring server startup)

- [ ] **Step 1: Read** `property_mutation.zig:280-340` for the exact executor FTS-maintenance call (`maintainFulltextOnWrite` signature and what it needs: store, graph, node id/ptr, changed property). Define the seam in `cluster_replication.zig`:

```zig
/// FTS live-maintenance hook fired after an apply mutates a node (create /
/// property set / delete). Registered by the server at startup (the
/// distributed module cannot import execution/); null in bare unit tests.
pub const FtsApplyHook = *const fn (store: *GraphStore, graph: []const u8, node_id: u64) void;
var g_fts_apply_hook: ?FtsApplyHook = null;
pub fn setFtsApplyHook(hook: ?FtsApplyHook) void { g_fts_apply_hook = hook; }
fn fireFtsHook(store: *GraphStore, graph: []const u8, node_id: u64) void {
    if (g_fts_apply_hook) |h| h(store, graph, node_id);
}
```

Adapt the parameter list to what `maintainFulltextOnWrite` actually needs (it may want the node pointer or the property name; pass the minimum that lets the wrapper re-do what the executor does — node-level re-index is acceptable).

- [ ] **Step 2: Fire it from every apply that touches node content:** GNC1 node create, GNC2 node creates (per created node), GMRG set-props, GUPD set/remove props (per updated node), and node DELETE applies (FTS must drop postings — check how the executor delete path maintains FTS and mirror; if deletes need a different hook shape, add a `deleted: bool` arg).

- [ ] **Step 3: Register at server startup** (`src/server/main.zig` near `:638`): a thin wrapper calling the same function the executor uses. Then register the same wrapper in the Task-12 test setup.

- [ ] **Step 4: Snapshot rebuild:** in `raft_snapshot_manager.zig` after `installSnapshotData` completes, fire a registered rebuild callback (same seam pattern, e.g. `g_fts_snapshot_rebuild: ?*const fn (store: *GraphStore) void`) that the server wires to "re-backfill every catalog fulltext index" (the backfill machinery exists — `CREATE INDEX … USING fulltext` backfills; grep `backfill` in `src/storage/fts_storage_adapter.zig` / `src/execution/fts_index_ops.zig` for the callable). Extend the Task-12 test file with a snapshot install case if the snapshot manager is in-process testable (read its existing tests; if none exist in-process, document the gap in the test file header and rely on the netns phase in Task 14).

- [ ] **Step 5: Green.** `zig build test-fts-apply-symmetry 2>&1 | tail -10` → PASS. Run `zig build test-fts-maintenance test-raft-apply 2>&1 | tail -10` → PASS (no executor-path regression).

- [ ] **Step 6: Commit.**

```bash
git add src/distributed/cluster_replication.zig src/distributed/raft_snapshot_manager.zig src/server/main.zig tests/test_fts_apply_symmetry.zig
git commit -m "fix(cluster): fire FTS live-maintenance on raft apply + rebuild FTS after snapshot install

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Slice 4 — netns phase, docs, final verification

### Task 14: netns M8 phase + documentation

**Files:**
- Modify: `tests/cluster/netns_cluster_replication_test.sh` (add phase M8 per the bug doc's request: a MATCH-created edge stays EXACTLY 1 on all three nodes across an in-place restart — copy the structure of the existing M-phases)
- Modify: `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md` (closure note on the MATCH…CREATE section: fix commits, slice scope, residuals)
- Modify: `CLAUDE.md` Known Limitations (add: "Cluster mode fail-closed surfaces" — timeseries ingest, auth/policy/tenant/index/graph/constraint DDL, TDE/CDC/FLE refuse writes in cluster mode pending replication slices; MATCH…CREATE replicates within its documented slice)
- Modify: `docs/TIMESERIES.md` (cluster limitation note), `docs/GQL_AUTH_DDL.md` (cluster limitation note)

- [ ] **Step 1:** Add M8 to the netns script; run it if the environment allows (`make test-cluster-netns`, needs sudo — if unavailable, mark the phase verified-by `test-cluster-replicable-mutations` and say so in the commit).
- [ ] **Step 2:** Write the doc updates. Keep claims scoped: slice coverage is exactly the documented shapes; everything else fails closed loudly.
- [ ] **Step 3: Commit.**

```bash
git add tests/cluster/netns_cluster_replication_test.sh docs/ CLAUDE.md
git commit -m "docs(cluster): MATCH…CREATE closure notes, fail-closed surface limitations, netns M8

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 15: Final verification + push

- [ ] **Step 1:** `make fmt` → commit any formatting deltas.
- [ ] **Step 2:** Full local gate: the pre-push shard suite (or `python3 scripts/test/extended_test_runner.py`), plus `zig build test-cluster-replicable-mutations test-raft-apply test-fts-apply-symmetry`. Expected: baseline 167/175 named steps preserved + new steps green.
- [ ] **Step 3:** `git push origin main` (pre-push hooks run the shards; let them).
- [ ] **Step 4:** Produce the fix report: root causes, evidence (red→green outputs), commits, residuals (Cartesian MATCH…CREATE shapes, new-node-in-CREATE-pattern, replication slices for the fail-closed surfaces, advanced-index apply symmetry — explicitly deferred).

---

## Self-review notes

- **Spec coverage:** live bug (Tasks 1-4), counter (Task 5), systemic ungated surfaces from the audit (Tasks 6-11: ts, auth, policy, tenant, index, graph, constraints, TDE/CDC/FLE), FTS apply/snapshot asymmetry (Tasks 12-13), netns + docs (Task 14). Deferred and documented: advanced-index apply symmetry, waitForApplied-timeout false-negative UX, replication slices for fail-closed surfaces, MATCH…SET standalone-path latent sites (gated at dispatch; documented in Task 14).
- **Type consistency:** `executeClusterMatchCreateIfNeeded` matches `executeClusterMatchUpdateIfNeeded`'s shape; `gateUnreplicatedWrite` used uniformly in Tasks 8-10; EdgeSpec/Endpoint names match `cluster_replication.zig:280-294` verbatim.
- **Known adaptation points (implementer must read first, flagged in-task):** exact `ast` field names for `q.create_pattern` chains (Task 3 Step 1), CALL-path error-to-wire mapping (Task 8 Step 2), `maintainFulltextOnWrite` signature (Task 13 Step 1), import-path style for cluster_mod (Tasks 8-10).
