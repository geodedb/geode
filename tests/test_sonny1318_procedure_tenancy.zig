// SONNY-1318 (GEO-UP-005) reproduction / regression: cross-tenant exposure via
// the `CALL algo.*` graph procedures and the LSP schema-introspection path.
//
// DEFECT: `src/execution/algo_dispatch.zig`, `src/execution/recursion_handler.zig`
// (BFS/DFS/Dijkstra) and `src/execution/centrality_algorithms.zig` contained NO
// tenant handling whatsoever (`grep -ci tenant` returned 0 for all three).  The
// traversal procedures walked `store.getOutgoingEdgeIds` / `getIncomingEdgeIds`
// and the centrality procedures iterated `store.nodes` directly, so a session
// bound to tenant A could read tenant B's node ids through
// `CALL algo.bfs.stream` / `algo.dfs.stream` / `algo.dijkstra.stream` and score
// every tenant's nodes through `CALL algo.degree.stream` & friends — even
// though the equivalent `MATCH` read is filtered by
// `match_operations.passesTenantFilterSlice`.  Capability row
// `graph_procedure_tenancy` is `false` for exactly this reason.
//
// Related: `src/execution/schema_introspection.zig` passed the RAW
// `ctx.tenant_id` to `listNodeLabels` / `listEdgeTypes` /
// `listPropertiesForLabel` instead of routing it through
// `tenancy.resolveTenantFilter` the way `meta_dispatch.zig` does, so the two
// metadata paths disagreed about strict mode (an unscoped session got the
// all-tenants label view from the LSP while `db.labels` refused it).
//
// FIX (fail closed, hierarchy-aware): ONE shared visibility helper,
// `src/execution/tenant_visibility.zig`, holding the hierarchy-aware
// `passesTenantFilterSlice` / `passesTenantFilterEdge` predicates that
// `match_operations.zig` already used (that file now delegates to it, so there
// is exactly one implementation).  `algo_dispatch` resolves the session scope
// ONCE per invocation via `tenancy.resolveTenantFilter(ctx.tenant_id)` —
// propagating `TenantScopeRequired` under strict tenancy — and threads it into
// every traversal and centrality entry point as a REQUIRED parameter, so a
// future procedure that forgets it is a compile error rather than a silent
// leak.
//
// FIXTURE (the brief's shape): two tenants in the SAME graph, A's subgraph
// joined to B's subgraph by ONE edge that is itself tagged tenant-A:
//
//     a1 --L--> a2 --L--> b1 --L--> b2
//     [   tenant-a    ]   [  tenant-b  ]
//                     ^bridge edge is tagged tenant-a
//
// The bridge edge is deliberately tagged tenant-A so it PASSES the edge-tag
// filter for A: the only thing that may stop the walk at `b1` is the
// destination-NODE visibility check.  A test whose bridge edge was tagged
// "default" would pass even with a node check missing.
//
// CANARY: REQ=REQ-SONNY-1318-PROCEDURE-TENANCY; FEATURE="GraphProcedureTenantScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1318_procedure_tenancy.zig; OWNER=security; UPDATED=2026-09-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const intro = @import("schema_introspection");

const execution = geode.execution;
const graph_store = geode.graph_store;
const tenancy = geode.tenancy;
const query_arena = geode.query_arena;
const user_management = geode.user_management;
const Value = geode.value_types.Value;

const tenant_a = "tenant-a";
const tenant_b = "tenant-b";
/// Registered in no hierarchy: it can satisfy neither the exact-match arm nor
/// `canAccessTenantSafe`, so it must see NOTHING. Any row at all proves the
/// filter was never consulted.
const tenant_ghost = "t-never-registered";

const label_a = "PA";
const label_b = "PB";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Server-shaped harness, same shape as `tests/test_sonny1229_strict_tenancy_read.zig`:
/// a persisted deployment, a live globally published expr-RLS engine whose
/// `HierarchyManager` holds the registered tenants (the seam
/// `CALL geode.tenant.create` drives), and the process-wide strict-tenancy flag.
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    engine: *rls.RLSEngine,
    ctx: execution.ExecutionContext,
    store: *graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator, strict: bool) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        tenancy.setStrictTenancy(strict);
        tenancy.resetWarnState();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        const engine = try allocator.create(rls.RLSEngine);
        errdefer allocator.destroy(engine);
        engine.* = try rls.RLSEngine.init(allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .engine = engine,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
            .store = store,
        };
    }

    pub fn deinit(self: *Harness) void {
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        tenancy.setStrictTenancy(false);
        tenancy.resetWarnState();
    }

    /// Same `HierarchyManager` seam `CALL geode.tenant.create(<id>[, <parent>])`
    /// drives (`src/execution/tenant_dispatch.zig`).
    fn createTenant(self: *Harness, tenant_id: []const u8, parent: ?[]const u8) !void {
        try self.engine.hierarchy_manager.addTenant(tenant_id, parent);
    }

    fn ctxForTenant(self: *const Harness, tenant_id: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant_id;
        return c;
    }

    /// Run a statement under `tenant`'s session context, exactly as a transport
    /// would after HELLO (active ExecutionContext + the per-thread FLE tenant).
    /// The result is copied out by the caller before `aa` dies.
    fn runAs(
        self: *Harness,
        aa: std.mem.Allocator,
        tenant: ?[]const u8,
        src: []const u8,
    ) !execution.ExecutionResult {
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        geode.fle_integration.setCurrentTenantId(tenant);
        defer geode.fle_integration.setCurrentTenantId(null);

        const ctx = self.ctxForTenant(tenant);
        const prev_ctx = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev_ctx);

        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn idByWho(self: *Harness, who: []const u8) !u64 {
        var it = self.store.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.properties.get("who")) |pv| {
                if (pv == .String and std.mem.eql(u8, pv.String, who)) return entry.key_ptr.*;
            }
        }
        return error.NodeNotFound;
    }

    fn tenantOfNode(self: *Harness, who: []const u8) ![]const u8 {
        const id = try self.idByWho(who);
        const n = self.store.nodes.get(id) orelse return error.NodeNotFound;
        return n.tenant_id;
    }
};

/// Node ids of the fixture.
const Fixture = struct { a1: u64, a2: u64, b1: u64, b2: u64 };

/// Build the brief's fixture: one connected subgraph per tenant in the SAME
/// graph, joined by a single tenant-A-tagged bridge edge.
///
/// Nodes and the intra-tenant edges go through the REAL CRUD path under each
/// tenant's session context, so their tenant tags are produced exactly the way
/// a wire CREATE produces them — and every tag is VERIFIED below, so no read
/// assertion can pass vacuously against mis-tagged rows.  The cross-tenant
/// bridge edge cannot be created through GQL at all under strict tenancy (a
/// tenant-A MATCH cannot see `b1`), which is the point: it models legacy or
/// admin-created linkage and is written with an explicit tenant tag.
fn seedFixture(h: *Harness, allocator: std.mem.Allocator) !Fixture {
    try h.createTenant(tenant_a, null);
    try h.createTenant(tenant_b, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var r1 = try h.runAs(aa, tenant_a, "CREATE (a1:" ++ label_a ++ " {who: 'a1'}), (a2:" ++ label_a ++ " {who: 'a2'}), (a1)-[:L]->(a2)");
    r1.deinit(aa);
    var r2 = try h.runAs(aa, tenant_b, "CREATE (b1:" ++ label_b ++ " {who: 'b1'}), (b2:" ++ label_b ++ " {who: 'b2'}), (b1)-[:L]->(b2)");
    r2.deinit(aa);

    const f = Fixture{
        .a1 = try h.idByWho("a1"),
        .a2 = try h.idByWho("a2"),
        .b1 = try h.idByWho("b1"),
        .b2 = try h.idByWho("b2"),
    };

    // Every node must really carry its tenant's tag, or every "A sees only A"
    // assertion below would be green for the wrong reason.
    if (!std.mem.eql(u8, try h.tenantOfNode("a1"), tenant_a)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("a2"), tenant_a)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("b1"), tenant_b)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("b2"), tenant_b)) return error.WriteDidNotCarryTenantTag;

    // The bridge, tagged tenant-A on purpose (see the file header).
    const bridge = try h.store.createEdgeWithGraphAndTenant(f.a2, f.b1, "L", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
    const bridge_edge = h.store.getEdgePtrHydrated(bridge) orelse return error.BridgeEdgeMissing;
    if (!std.mem.eql(u8, bridge_edge.tenant_id, tenant_a)) return error.BridgeDidNotCarryTenantTag;

    return f;
}

/// Collect every node id appearing in any `path` list cell of a traversal
/// result. Traversal rows are `{ .List = [ .Int, ... ] }`.
fn collectPathNodeIds(allocator: std.mem.Allocator, res: execution.ExecutionResult) !std.AutoHashMap(u64, void) {
    var seen = std.AutoHashMap(u64, void).init(allocator);
    errdefer seen.deinit();
    for (res.rows) |row| {
        if (row.len == 0) continue;
        switch (row[0]) {
            .List => |items| for (items) |cell| {
                if (cell == .Int and cell.Int >= 0) try seen.put(@intCast(cell.Int), {});
            },
            else => {},
        }
    }
    return seen;
}

/// Collect a two-column `(nodeId, score)` centrality result into id -> i64.
/// Only the id is asserted on; the score column is returned for degree checks.
fn collectIds(allocator: std.mem.Allocator, res: execution.ExecutionResult) !std.AutoHashMap(u64, i64) {
    var map = std.AutoHashMap(u64, i64).init(allocator);
    errdefer map.deinit();
    for (res.rows) |row| {
        if (row.len == 0) continue;
        const id: u64 = switch (row[0]) {
            .Int => |i| if (i < 0) return error.UnexpectedValueType else @intCast(i),
            else => return error.UnexpectedValueType,
        };
        const v: i64 = if (row.len > 1) switch (row[1]) {
            .Int => |i| i,
            else => 0,
        } else 0;
        try map.put(id, v);
    }
    return map;
}

// ---------------------------------------------------------------------------
// 1 — THE DEFECT: BFS as tenant A must never cross the bridge into tenant B.
// ---------------------------------------------------------------------------
test "SONNY-1318: algo.bfs.stream is tenant-scoped (A never reaches B's nodes)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try std.fmt.allocPrint(aa, "CALL algo.bfs.stream({d}, {{maxDepth: 5}})", .{f.a1});
    var res = try h.runAs(aa, tenant_a, q);
    defer res.deinit(aa);

    var seen = try collectPathNodeIds(allocator, res);
    defer seen.deinit();

    try testing.expect(seen.contains(f.a1));
    try testing.expect(seen.contains(f.a2));
    try testing.expect(!seen.contains(f.b1));
    try testing.expect(!seen.contains(f.b2));
}

// ---------------------------------------------------------------------------
// 2 — Same for DFS.
// ---------------------------------------------------------------------------
test "SONNY-1318: algo.dfs.stream is tenant-scoped (A never reaches B's nodes)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try std.fmt.allocPrint(aa, "CALL algo.dfs.stream({d}, {{maxDepth: 5}})", .{f.a1});
    var res = try h.runAs(aa, tenant_a, q);
    defer res.deinit(aa);

    var seen = try collectPathNodeIds(allocator, res);
    defer seen.deinit();

    try testing.expect(seen.contains(f.a1));
    try testing.expect(seen.contains(f.a2));
    try testing.expect(!seen.contains(f.b1));
    try testing.expect(!seen.contains(f.b2));
}

// ---------------------------------------------------------------------------
// 3 — Dijkstra from A's node to B's node must find NO path, while the
//     within-tenant shortest path still works (the fix must not be "break
//     Dijkstra").
// ---------------------------------------------------------------------------
test "SONNY-1318: algo.dijkstra.stream finds no cross-tenant path but keeps the in-tenant one" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A -> B: the bridge edge is tenant-A-tagged, so ONLY the destination-node
    // visibility check can stop this. No path may be returned.
    {
        const q = try std.fmt.allocPrint(aa, "CALL algo.dijkstra.stream({d}, {d})", .{ f.a1, f.b2 });
        var res = try h.runAs(aa, tenant_a, q);
        defer res.deinit(aa);

        var seen = try collectPathNodeIds(allocator, res);
        defer seen.deinit();
        try testing.expect(!seen.contains(f.b1));
        try testing.expect(!seen.contains(f.b2));
        // "no path" is the empty path list the executor emits for unreachable
        // targets — assert it explicitly rather than only asserting absence.
        for (res.rows) |row| {
            if (row.len == 0) continue;
            if (row[0] == .List) try testing.expectEqual(@as(usize, 0), row[0].List.len);
        }
    }

    // A -> A: positive control, the legitimate path is still found.
    {
        const q = try std.fmt.allocPrint(aa, "CALL algo.dijkstra.stream({d}, {d})", .{ f.a1, f.a2 });
        var res = try h.runAs(aa, tenant_a, q);
        defer res.deinit(aa);

        var seen = try collectPathNodeIds(allocator, res);
        defer seen.deinit();
        try testing.expect(seen.contains(f.a1));
        try testing.expect(seen.contains(f.a2));
        try testing.expectEqual(@as(u32, 2), seen.count());
    }
}

// ---------------------------------------------------------------------------
// 4 — Centrality: only A's nodes are scored, and the bridge edge does not
//     inflate a2's degree (the sharp assertion — a node-only filter that
//     forgot the edge would still report degree 2 for a2).
// ---------------------------------------------------------------------------
test "SONNY-1318: centrality procedures score only the session tenant's nodes" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var res = try h.runAs(aa, tenant_a, "CALL algo.degree.stream()");
        defer res.deinit(aa);
        var ids = try collectIds(allocator, res);
        defer ids.deinit();

        try testing.expectEqual(@as(u32, 2), ids.count());
        try testing.expect(ids.contains(f.a1));
        try testing.expect(ids.contains(f.a2));
        try testing.expect(!ids.contains(f.b1));
        try testing.expect(!ids.contains(f.b2));
        // a2 has TWO incident edges in the store (a1->a2 and the bridge
        // a2->b1); only the first is visible to tenant A.
        try testing.expectEqual(@as(i64, 1), ids.get(f.a1).?);
        try testing.expectEqual(@as(i64, 1), ids.get(f.a2).?);
    }

    // A second, structurally different centrality family (iterative, adjacency
    // driven) to prove the scope reaches past the degree fast path.
    {
        var res = try h.runAs(aa, tenant_a, "CALL algo.pagerank.stream()");
        defer res.deinit(aa);
        var ids = try collectIds(allocator, res);
        defer ids.deinit();
        try testing.expectEqual(@as(u32, 2), ids.count());
        try testing.expect(!ids.contains(f.b1));
        try testing.expect(!ids.contains(f.b2));
    }

    {
        var res = try h.runAs(aa, tenant_b, "CALL algo.degree.stream()");
        defer res.deinit(aa);
        var ids = try collectIds(allocator, res);
        defer ids.deinit();
        try testing.expectEqual(@as(u32, 2), ids.count());
        try testing.expect(ids.contains(f.b1));
        try testing.expect(ids.contains(f.b2));
        try testing.expect(!ids.contains(f.a1));
        try testing.expect(!ids.contains(f.a2));
    }
}

// ---------------------------------------------------------------------------
// 5 — Tenant B naming tenant A's start node id: not found, never A's data.
//     A start node the caller cannot see must read as absent, not as an error
//     that confirms the id exists.
// ---------------------------------------------------------------------------
test "SONNY-1318: a start node id the tenant cannot see reads as not found" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const shapes = [_][]const u8{ "algo.bfs.stream", "algo.dfs.stream" };
    for (shapes) |proc| {
        const q = try std.fmt.allocPrint(aa, "CALL {s}({d}, {{maxDepth: 5}})", .{ proc, f.a1 });
        var res = try h.runAs(aa, tenant_b, q);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    const dq = try std.fmt.allocPrint(aa, "CALL algo.dijkstra.stream({d}, {d})", .{ f.a1, f.a2 });
    var dres = try h.runAs(aa, tenant_b, dq);
    defer dres.deinit(aa);
    var seen = try collectPathNodeIds(allocator, dres);
    defer seen.deinit();
    try testing.expect(!seen.contains(f.a1));
    try testing.expect(!seen.contains(f.a2));
}

// ---------------------------------------------------------------------------
// 6 — An unregistered tenant reads NOTHING. It satisfies neither the
//     exact-match arm nor `canAccessTenantSafe`, so any row proves the filter
//     is not consulted at all.
// ---------------------------------------------------------------------------
test "SONNY-1318: an unregistered tenant reads nothing from any graph procedure" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        const q = try std.fmt.allocPrint(aa, "CALL algo.bfs.stream({d}, {{maxDepth: 5}})", .{f.a1});
        var res = try h.runAs(aa, tenant_ghost, q);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
    {
        var res = try h.runAs(aa, tenant_ghost, "CALL algo.degree.stream()");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
}

// ---------------------------------------------------------------------------
// 7 — Strict tenancy + NO scope: refused with TenantScopeRequired (the 42501
//     the driver sees), not silently widened to every tenant.
// ---------------------------------------------------------------------------
test "SONNY-1318: strict tenancy with no scope refuses graph procedures" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const bfs = try std.fmt.allocPrint(aa, "CALL algo.bfs.stream({d}, {{maxDepth: 5}})", .{f.a1});
    try testing.expectError(error.TenantScopeRequired, h.runAs(aa, null, bfs));

    const dij = try std.fmt.allocPrint(aa, "CALL algo.dijkstra.stream({d}, {d})", .{ f.a1, f.b2 });
    try testing.expectError(error.TenantScopeRequired, h.runAs(aa, null, dij));

    try testing.expectError(error.TenantScopeRequired, h.runAs(aa, null, "CALL algo.degree.stream()"));
    try testing.expectError(error.TenantScopeRequired, h.runAs(aa, "", "CALL algo.pagerank.stream()"));
}

// ---------------------------------------------------------------------------
// 8 — The anti-"just turn the procedures off" guard: strict OFF with no scope
//     keeps the legacy all-tenants behaviour, byte for byte.
// ---------------------------------------------------------------------------
test "SONNY-1318: non-strict deployment with no tenant scope is unchanged" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, false);
    defer h.deinit();
    const f = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var res = try h.runAs(aa, null, "CALL algo.degree.stream()");
        defer res.deinit(aa);
        var ids = try collectIds(allocator, res);
        defer ids.deinit();
        try testing.expectEqual(@as(u32, 4), ids.count());
        // a2 keeps its FULL degree (a1->a2 plus the bridge) when no filter applies.
        try testing.expectEqual(@as(i64, 2), ids.get(f.a2).?);
    }
    {
        const q = try std.fmt.allocPrint(aa, "CALL algo.bfs.stream({d}, {{maxDepth: 5}})", .{f.a1});
        var res = try h.runAs(aa, null, q);
        defer res.deinit(aa);
        var seen = try collectPathNodeIds(allocator, res);
        defer seen.deinit();
        // The walk still crosses the bridge into every tenant, as before.
        try testing.expect(seen.contains(f.b1));
        try testing.expect(seen.contains(f.b2));
    }
}

// ---------------------------------------------------------------------------
// 9 — schema_introspection must agree with meta_dispatch about strict mode.
// ---------------------------------------------------------------------------
test "SONNY-1318: schema introspection labels are tenant-scoped under strict mode" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    const ctxFor = struct {
        fn f(tid: ?[]const u8) intro.IntrospectionContext {
            return .{
                .user = "alice",
                .tenant_id = tid,
                .role = user_management.Role.ReadOnly,
                .graph_name = graph_store.DEFAULT_GRAPH_NAME,
            };
        }
    }.f;

    {
        const labels = try intro.listLabelsForUser(allocator, h.store, ctxFor(tenant_a));
        defer intro.freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expectEqualStrings(label_a, labels[0]);
    }
    {
        const labels = try intro.listLabelsForUser(allocator, h.store, ctxFor(tenant_b));
        defer intro.freeStringList(allocator, labels);
        try testing.expectEqual(@as(usize, 1), labels.len);
        try testing.expectEqualStrings(label_b, labels[0]);
    }
    // Strict + unscoped: refused, exactly as `db.labels` (meta_dispatch) is.
    try testing.expectError(error.TenantScopeRequired, intro.listLabelsForUser(allocator, h.store, ctxFor(null)));
    try testing.expectError(error.TenantScopeRequired, intro.listEdgeTypesForUser(allocator, h.store, ctxFor(null)));
    try testing.expectError(error.TenantScopeRequired, intro.listPropertiesForLabelForUser(allocator, h.store, ctxFor(null), label_a));
}

// ---------------------------------------------------------------------------
// 10 — REVIEW R1 (parallel degree path): `algo.degree.stream` scoped over MORE
//      than `parallel_wrapper.Thresholds.forEach` (32) visible nodes, so
//      `parallelForEach` really fans out onto worker threads rather than
//      running the inline fallback.
//
//      Two hazards this pins, both introduced by the first SONNY-1318 pass:
//        * `edgeIdTraversable` dereferenced a raw `*Edge` from
//          `getEdgePtrHydrated` OUTSIDE the shard lock (graph_store.zig
//          ~:3161-3175 documents that hazard and names `getEdgeHydrated` as the
//          safe by-value accessor). It now uses the by-value accessor.
//        * the mis-tagged-edge arm called `dupeNodeTenantForRead(store.allocator,
//          …)` — the SHARED store allocator, plus a possible storage-adapter
//          read — from inside a worker, contradicting the function's own
//          "pre-allocate all row arrays so parallel workers don't need the
//          allocator" invariant. Scoped degrees are now computed on the calling
//          thread and the workers only read the resulting array.
//
//      The fixture deliberately contains BOTH edge shapes the predicates
//      disagree about: cross-tenant edges (one tagged with the READER's own
//      tenant, so only the endpoint check can stop it) and an intra-tenant edge
//      mis-tagged "default". SONNY-2693 removed the endpoint-derived bridge
//      that used to count the mis-tagged edge: an edge counts only when its own
//      tag AND both endpoints are visible, so it no longer counts for tenant A
//      (`CALL geode.tenant.backfill_edge_tags()` re-tags such edges). Degrees
//      are asserted EXACTLY, per node.
// ---------------------------------------------------------------------------

/// Strictly greater than `parallel_wrapper.Thresholds.forEach` (32) so the
/// parallel section is taken, not the inline small-input fallback.
const parallel_a_nodes: usize = 40;

const ParallelFixture = struct {
    a: [parallel_a_nodes]u64,
    b0: u64,
    b1: u64,
};

fn seedParallelFixture(h: *Harness, allocator: std.mem.Allocator) !ParallelFixture {
    try h.createTenant(tenant_a, null);
    try h.createTenant(tenant_b, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Nodes go through the REAL CRUD path under each tenant's session context,
    // so their tenant tags are produced exactly as a wire CREATE produces them.
    var create_a = std.ArrayList(u8).empty;
    defer create_a.deinit(aa);
    try create_a.appendSlice(aa, "CREATE ");
    for (0..parallel_a_nodes) |i| {
        if (i > 0) try create_a.appendSlice(aa, ", ");
        const pattern = try std.fmt.allocPrint(aa, "(n{d}:" ++ label_a ++ " {{who: 'pa{d}'}})", .{ i, i });
        try create_a.appendSlice(aa, pattern);
    }
    var ra = try h.runAs(aa, tenant_a, create_a.items);
    ra.deinit(aa);

    var rb = try h.runAs(aa, tenant_b, "CREATE (m0:" ++ label_b ++ " {who: 'pb0'}), (m1:" ++ label_b ++ " {who: 'pb1'})");
    rb.deinit(aa);

    var f: ParallelFixture = undefined;
    for (0..parallel_a_nodes) |i| {
        const who = try std.fmt.allocPrint(aa, "pa{d}", .{i});
        f.a[i] = try h.idByWho(who);
        // No assertion below may pass because a row was mis-tagged at write time.
        if (!std.mem.eql(u8, try h.tenantOfNode(who), tenant_a)) return error.WriteDidNotCarryTenantTag;
    }
    f.b0 = try h.idByWho("pb0");
    f.b1 = try h.idByWho("pb1");
    if (!std.mem.eql(u8, try h.tenantOfNode("pb0"), tenant_b)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("pb1"), tenant_b)) return error.WriteDidNotCarryTenantTag;

    // Edges are written with EXPLICIT tenant tags (the same seam the base
    // fixture's bridge uses) because the mis-tagged and cross-tenant shapes
    // under test cannot be produced through GQL under strict tenancy at all.
    const expectTag = struct {
        fn check(hh: *Harness, edge_id: u64, want: []const u8) !void {
            const e = hh.store.getEdgeHydrated(edge_id) orelse return error.EdgeMissing;
            if (!std.mem.eql(u8, e.tenant_id, want)) return error.EdgeDidNotCarryTenantTag;
        }
    }.check;

    // (1) The tenant-A chain: a0 -> a1 -> … -> a39.
    for (0..parallel_a_nodes - 1) |i| {
        const eid = try h.store.createEdgeWithGraphAndTenant(f.a[i], f.a[i + 1], "L", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
        try expectTag(h, eid, tenant_a);
    }

    // (2) LEGACY MIS-TAG: an intra-tenant-A edge carrying the "default"
    //     sentinel. Its own tag fails tenant A's filter. It used to count
    //     through the endpoint-derived bridge (the arm that used to allocate
    //     inside a worker); SONNY-2693 removed the bridge, so it must NOT
    //     count, and a5/a7 keep their plain chain degree.
    const mistagged = try h.store.createEdgeWithGraphAndTenant(f.a[5], f.a[7], "L", graph_store.DEFAULT_GRAPH_NAME, graph_store.DEFAULT_TENANT_ID);
    try expectTag(h, mistagged, graph_store.DEFAULT_TENANT_ID);

    // (3) CROSS-TENANT, tagged with the READER's OWN tenant: only the
    //     destination-node check can stop this one, exactly like the base
    //     fixture's bridge.
    const bridge_a = try h.store.createEdgeWithGraphAndTenant(f.a[10], f.b0, "L", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
    try expectTag(h, bridge_a, tenant_a);

    // (4) CROSS-TENANT, tagged tenant-B, pointing INTO tenant A: invisible to
    //     both sides (each one's endpoint check fails).
    const bridge_b = try h.store.createEdgeWithGraphAndTenant(f.b1, f.a[20], "L", graph_store.DEFAULT_GRAPH_NAME, tenant_b);
    try expectTag(h, bridge_b, tenant_b);

    return f;
}

test "SONNY-1318: scoped algo.degree.stream over the parallel threshold reports exact degrees" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    const f = try seedParallelFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Exact expected degree per tenant-A node: the chain contributes one
    // incoming and/or one outgoing edge, and NOTHING else counts. The
    // mis-tagged a5->a7 edge carries "default", which fails tenant A's tag
    // check (SONNY-2693: no endpoint-derived bridge), and NEITHER cross-tenant
    // edge contributes anything (a10 and a20 keep their plain chain degree).
    var expected: [parallel_a_nodes]i64 = undefined;
    for (0..parallel_a_nodes) |i| {
        var d: i64 = 0;
        if (i + 1 < parallel_a_nodes) d += 1;
        if (i > 0) d += 1;
        expected[i] = d;
    }

    var res = try h.runAs(aa, tenant_a, "CALL algo.degree.stream()");
    defer res.deinit(aa);
    var ids = try collectIds(allocator, res);
    defer ids.deinit();

    // The parallel section is only taken above `Thresholds.forEach` (32); this
    // count IS that precondition, so assert it before the degrees.
    try testing.expectEqual(@as(u32, parallel_a_nodes), ids.count());
    try testing.expect(parallel_a_nodes > 32);

    for (0..parallel_a_nodes) |i| {
        const got = ids.get(f.a[i]) orelse return error.MissingNodeInResult;
        try testing.expectEqual(expected[i], got);
    }
    try testing.expect(!ids.contains(f.b0));
    try testing.expect(!ids.contains(f.b1));

    // Tenant B's own view: both cross-tenant edges are invisible from this side
    // too, so B's nodes have degree 0 — which also proves those edges really
    // exist (otherwise tenant A's degrees above would be green for free).
    var res_b = try h.runAs(aa, tenant_b, "CALL algo.degree.stream()");
    defer res_b.deinit(aa);
    var ids_b = try collectIds(allocator, res_b);
    defer ids_b.deinit();
    try testing.expectEqual(@as(u32, 2), ids_b.count());
    try testing.expectEqual(@as(i64, 0), ids_b.get(f.b0).?);
    try testing.expectEqual(@as(i64, 0), ids_b.get(f.b1).?);
}

test "SONNY-1318: unscoped algo.degree.stream over the parallel threshold is unchanged" {
    // The anti-"just make the scoped path serial" control: with no filter the
    // workers still compute every degree themselves (allocation-free raw
    // adjacency), and every edge — cross-tenant and mis-tagged alike — counts.
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, false);
    defer h.deinit();
    const f = try seedParallelFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var res = try h.runAs(aa, null, "CALL algo.degree.stream()");
    defer res.deinit(aa);
    var ids = try collectIds(allocator, res);
    defer ids.deinit();

    try testing.expectEqual(@as(u32, parallel_a_nodes + 2), ids.count());
    // a10 now counts its bridge to b0, a20 its bridge from b1, and b0/b1 each
    // count the cross-tenant edge the scoped view hid.
    try testing.expectEqual(@as(i64, 3), ids.get(f.a[10]).?);
    try testing.expectEqual(@as(i64, 3), ids.get(f.a[20]).?);
    try testing.expectEqual(@as(i64, 1), ids.get(f.b0).?);
    try testing.expectEqual(@as(i64, 1), ids.get(f.b1).?);
}
