// SONNY-1326 (GEO-UP-005) reproduction / regression: cross-tenant exposure via
// the EXPRESSION evaluation path in `src/execution/graph_algorithms.zig`.
//
// DEFECT: SONNY-1318 scoped the `CALL algo.*` procedures and the LSP schema
// introspection path, and its report (§8) named the surface it deliberately did
// NOT fix: `graph_algorithms.zig` applied NO tenant term at all. `grep -ci
// tenant src/execution/graph_algorithms.zig` returned 0. Three expression entry
// points read node/edge data with no scope:
//
//   * `findShortestPath` (:614)          <- `shortestPath(...)` in an expression
//                                           (`eval.zig:1860`) and
//                                           `match_operations.zig:3378`
//   * `countPatternMatches` (:324)       <- `COUNT { … }` (`eval.zig:1869`) and
//                                           `EXISTS { … }` (`eval.zig:1880`)
//   * `executePatternComprehension` (:853) <- `[(a)-[:R]->(b) | b.x]`
//                                           (`eval.zig:1929`)
//
// So under strict tenancy a scoped session still observed another tenant's
// nodes and edges through path length, counts and existence, even though
// `MATCH` and `CALL algo.*` were filtered. Capability row
// `graph_procedure_tenancy` was `false` for exactly this reason.
//
// FIX (fail closed, hierarchy-aware, same module): each of the three entry
// points resolves the session scope ONCE via
// `tenant_visibility.resolveScope(ctx.tenant_id)` — propagating
// `TenantScopeRequired` under strict tenancy BEFORE any graph read — and
// threads it into every helper as a REQUIRED parameter, so a future helper that
// forgets it is a compile error. The SHARED predicates from
// `src/execution/tenant_visibility.zig` (`passesTenantFilter`,
// `passesTenantFilterSlice`, `nodeIdVisible`, `edgeTraversable`) gate start
// nodes, every frontier node, every traversed edge (BOTH endpoints), path
// materialization and every counted/tested match.
//
// FIXTURE (same shape as `tests/test_sonny1318_procedure_tenancy.zig`): two
// tenants with connected subgraphs in the SAME graph, joined by one bridge edge
// that is itself tagged with the READER's (tenant-A's) id:
//
//     a1 --L--> a2 --L--> b1 --L--> b2
//     [   tenant-a    ]   [  tenant-b  ]
//                     ^bridge edge is tagged tenant-a
//
// The bridge is tenant-A-tagged on purpose: it PASSES the edge-tag filter for
// A, so the only thing that may stop the walk / the count at `b1` is the
// destination-NODE visibility check. A fixture whose bridge was tagged
// "default" would go green even with the node check missing.
//
// Every query below is RETURN-only wherever possible: a statement with no MATCH
// chain deliberately does NOT call `resolveTenantFilter` in
// `query_execution.zig` (:1651), so the expression path is the ONLY tenant gate
// under test and no assertion can pass because MATCH refused first.
//
// CANARY: REQ=REQ-SONNY-1326-EXPRESSION-TENANCY; FEATURE="ExpressionPathTenantScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1326_expression_tenancy.zig; OWNER=security; UPDATED=2026-09-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;
const tenancy = geode.tenancy;
const query_arena = geode.query_arena;
const Value = geode.value_types.Value;

const tenant_a = "tenant-a";
const tenant_b = "tenant-b";
/// Registered in no hierarchy: it satisfies neither the exact-match arm nor
/// `canAccessTenantSafe`, so it must see NOTHING. Any row at all proves the
/// filter was never consulted.
const tenant_ghost = "t-never-registered";

const label_a = "PA";
const label_b = "PB";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Server-shaped harness, same shape as
/// `tests/test_sonny1318_procedure_tenancy.zig`: a persisted deployment, a live
/// globally published expr-RLS engine whose `HierarchyManager` holds the
/// registered tenants, and the process-wide strict-tenancy flag.
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    engine: *rls.RLSEngine,
    ctx: execution.ExecutionContext,
    store: *graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator, strict: bool) !Harness {
        // The expression path reaches `graph_algorithms.zig` through the
        // evaluator-adapter callback vtable (`eval.zig:1860/1869/1880/1929`),
        // which the server installs at startup. Without this the very first
        // `shortestPath()` / `COUNT{}` panics instead of running the code under
        // test.
        execution.initEvaluator();
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

const Fixture = struct { a1: u64, a2: u64, b1: u64, b2: u64 };

/// Build the fixture: one connected subgraph per tenant in the SAME graph,
/// joined by a single tenant-A-tagged bridge edge. Nodes and the intra-tenant
/// edges go through the REAL CRUD path under each tenant's session context, and
/// every tag is VERIFIED, so no read assertion can pass vacuously.
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

    if (!std.mem.eql(u8, try h.tenantOfNode("a1"), tenant_a)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("a2"), tenant_a)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("b1"), tenant_b)) return error.WriteDidNotCarryTenantTag;
    if (!std.mem.eql(u8, try h.tenantOfNode("b2"), tenant_b)) return error.WriteDidNotCarryTenantTag;

    // The bridge, tagged tenant-A on purpose (see the file header).
    const bridge = try h.store.createEdgeWithGraphAndTenant(f.a2, f.b1, "L", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
    const bridge_edge = h.store.getEdgeHydrated(bridge) orelse return error.BridgeEdgeMissing;
    if (!std.mem.eql(u8, bridge_edge.tenant_id, tenant_a)) return error.BridgeDidNotCarryTenantTag;

    return f;
}

// --- small result readers -------------------------------------------------

fn firstCell(res: execution.ExecutionResult) !Value {
    if (res.rows.len == 0) return error.NoRows;
    if (res.rows[0].len == 0) return error.NoColumns;
    return res.rows[0][0];
}

fn scalarInt(res: execution.ExecutionResult) !i64 {
    const v = try firstCell(res);
    return switch (v) {
        .Int => |i| i,
        else => error.UnexpectedValueType,
    };
}

fn scalarBool(res: execution.ExecutionResult) !bool {
    const v = try firstCell(res);
    return switch (v) {
        .Bool => |b| b,
        else => error.UnexpectedValueType,
    };
}

/// Number of nodes in a `.Path` cell; `null` when the cell is `.Null`
/// ("no path"). Any other shape is an error, so a silently-changed
/// representation cannot make a "no path" assertion pass vacuously.
fn pathNodeCount(res: execution.ExecutionResult) !?usize {
    const v = try firstCell(res);
    return switch (v) {
        .Null => null,
        .Path => |p| p.nodes.len,
        .List => |items| if (items.len == 0) null else error.UnexpectedValueType,
        else => error.UnexpectedValueType,
    };
}

/// Collect the string cells of a `.List` result (pattern comprehension).
fn listStrings(allocator: std.mem.Allocator, res: execution.ExecutionResult) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    const v = try firstCell(res);
    switch (v) {
        .List => |items| for (items) |cell| {
            switch (cell) {
                .Str => |s| try out.append(allocator, s),
                .Text => |s| try out.append(allocator, s),
                else => return error.UnexpectedValueType,
            }
        },
        else => return error.UnexpectedValueType,
    }
    return out;
}

fn asStr(v: Value) ![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Text => |s| s,
        else => error.UnexpectedValueType,
    };
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

// The four expression shapes under test, as RETURN-only statements.
const q_path_cross = "RETURN shortestPath((a:" ++ label_a ++ " {who: 'a1'})-[*]-(b:" ++ label_b ++ " {who: 'b1'})) AS p";
const q_path_in_tenant = "RETURN shortestPath((a:" ++ label_a ++ " {who: 'a1'})-[*]-(b:" ++ label_a ++ " {who: 'a2'})) AS p";
const q_count_b = "RETURN COUNT { (n:" ++ label_b ++ ") } AS c";
const q_count_a = "RETURN COUNT { (n:" ++ label_a ++ ") } AS c";
const q_exists_b = "RETURN EXISTS { (n:" ++ label_b ++ ") } AS e";
const q_comp = "RETURN [(a:" ++ label_a ++ ")-[:L]->(b) | b.who] AS xs";

// ---------------------------------------------------------------------------
// 1 — THE DEFECT: shortestPath() as tenant A must not cross the bridge.
// ---------------------------------------------------------------------------
test "SONNY-1326: shortestPath() finds no cross-tenant path but keeps the in-tenant one" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A -> B: the bridge edge carries tenant-A's own tag, so ONLY the
    // destination-node visibility check can stop this.
    {
        var res = try h.runAs(aa, tenant_a, q_path_cross);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, null), try pathNodeCount(res));
    }

    // A -> A: positive control, the legitimate path is still found.
    {
        var res = try h.runAs(aa, tenant_a, q_path_in_tenant);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, 2), try pathNodeCount(res));
    }
}

// ---------------------------------------------------------------------------
// 2 — COUNT{} over a pattern spanning the bridge counts only A's matches.
// ---------------------------------------------------------------------------
test "SONNY-1326: COUNT{} counts only the session tenant's matches" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Bare node count of the OTHER tenant's label.
    {
        var res = try h.runAs(aa, tenant_a, q_count_b);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 0), try scalarInt(res));
    }
    {
        var res = try h.runAs(aa, tenant_a, q_count_a);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 2), try scalarInt(res));
    }
    {
        var res = try h.runAs(aa, tenant_b, q_count_b);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 2), try scalarInt(res));
    }

    // The SHARP one: a correlated single-hop count that spans the bridge.
    // `a2` has exactly one outgoing `:L` edge — the tenant-A-tagged bridge to
    // `b1` — so a count that forgot the destination-NODE check reports 1.
    {
        var res = try h.runAs(aa, tenant_a, "MATCH (a:" ++ label_a ++ ") RETURN a.who AS who, COUNT { (a)-[:L]->(x) } AS c");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
        for (res.rows) |row| {
            const who = try asStr(row[0]);
            const c = row[1].Int;
            if (std.mem.eql(u8, who, "a1")) {
                try testing.expectEqual(@as(i64, 1), c);
            } else {
                try testing.expectEqualStrings("a2", who);
                try testing.expectEqual(@as(i64, 0), c);
            }
        }
    }

    // Anonymous relationship shape.
    //
    // NOTE (pre-existing engine behaviour, NOT a SONNY-1326 regression):
    // `COUNT { ()-[:L]->() }` counts the LEFT NODE pattern, not the
    // relationship. `countPatternMatches` derives `node_pattern_opt` from
    // `chain.hops[0].left` whenever `chain.head` is null, and `hops[0].left` is
    // a non-optional `NodePattern`, so the relationship-counting arm (the
    // `store.allEdgeIds` loop) is unreachable from GQL. What this pins is
    // therefore the tenant scope on the bare-node loop for this shape: tenant A
    // sees its own two nodes, never all four.
    {
        var res = try h.runAs(aa, tenant_a, "RETURN COUNT { ()-[:L]->() } AS c");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 2), try scalarInt(res));
    }
}

// ---------------------------------------------------------------------------
// 3 — EXISTS{} for another tenant's node is false.
// ---------------------------------------------------------------------------
test "SONNY-1326: EXISTS{} is false for another tenant's node" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var res = try h.runAs(aa, tenant_a, q_exists_b);
        defer res.deinit(aa);
        try testing.expectEqual(false, try scalarBool(res));
    }
    // Positive control: B really is there, for the tenant that owns it.
    {
        var res = try h.runAs(aa, tenant_b, q_exists_b);
        defer res.deinit(aa);
        try testing.expectEqual(true, try scalarBool(res));
    }
}

// ---------------------------------------------------------------------------
// 4 — A pattern comprehension yields only A's elements.
// ---------------------------------------------------------------------------
test "SONNY-1326: a pattern comprehension yields only the session tenant's elements" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var res = try h.runAs(aa, tenant_a, q_comp);
    defer res.deinit(aa);
    var xs = try listStrings(allocator, res);
    defer xs.deinit(allocator);

    // a1 -> a2 is in scope; a2 -> b1 (the bridge) is not.
    try testing.expectEqual(@as(usize, 1), xs.items.len);
    try testing.expect(containsStr(xs.items, "a2"));
    try testing.expect(!containsStr(xs.items, "b1"));
}

// ---------------------------------------------------------------------------
// 5 — Tenant B naming tenant A's start node: nothing. A start node the caller
//     cannot see reads as absent, never as an error that confirms it exists.
// ---------------------------------------------------------------------------
test "SONNY-1326: a start node the tenant cannot see reads as not found" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var res = try h.runAs(aa, tenant_b, q_path_in_tenant);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, null), try pathNodeCount(res));
    }
    {
        var res = try h.runAs(aa, tenant_b, q_count_a);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 0), try scalarInt(res));
    }
    {
        var res = try h.runAs(aa, tenant_b, q_comp);
        defer res.deinit(aa);
        var xs = try listStrings(allocator, res);
        defer xs.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), xs.items.len);
    }
}

// ---------------------------------------------------------------------------
// 6 — An unregistered tenant reads NOTHING from any expression shape.
// ---------------------------------------------------------------------------
test "SONNY-1326: an unregistered tenant reads nothing from any expression shape" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var res = try h.runAs(aa, tenant_ghost, q_path_in_tenant);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, null), try pathNodeCount(res));
    }
    {
        var res = try h.runAs(aa, tenant_ghost, q_path_cross);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, null), try pathNodeCount(res));
    }
    {
        var res = try h.runAs(aa, tenant_ghost, q_count_a);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 0), try scalarInt(res));
    }
    {
        var res = try h.runAs(aa, tenant_ghost, q_count_b);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 0), try scalarInt(res));
    }
    {
        var res = try h.runAs(aa, tenant_ghost, q_exists_b);
        defer res.deinit(aa);
        try testing.expectEqual(false, try scalarBool(res));
    }
    {
        var res = try h.runAs(aa, tenant_ghost, q_comp);
        defer res.deinit(aa);
        var xs = try listStrings(allocator, res);
        defer xs.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), xs.items.len);
    }
}

// ---------------------------------------------------------------------------
// 7 — Strict tenancy + NO scope: refused with TenantScopeRequired (the 42501
//     the driver sees) BEFORE any graph read, not silently widened. Every
//     statement here is RETURN-only, so the MATCH path cannot refuse first.
// ---------------------------------------------------------------------------
test "SONNY-1326: strict tenancy with no scope refuses the expression path" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const shapes = [_][]const u8{ q_path_cross, q_path_in_tenant, q_count_a, q_count_b, q_exists_b, q_comp };
    for (shapes) |src| {
        try testing.expectError(error.TenantScopeRequired, h.runAs(aa, null, src));
        // The empty string and the "default" sentinel are the same refusal.
        try testing.expectError(error.TenantScopeRequired, h.runAs(aa, "", src));
        try testing.expectError(error.TenantScopeRequired, h.runAs(aa, graph_store.DEFAULT_TENANT_ID, src));
    }
}

// ---------------------------------------------------------------------------
// 8 — The anti-"just turn the feature off" control: strict OFF with no scope
//     keeps the legacy all-tenants behaviour, with the OPPOSITE assertions.
// ---------------------------------------------------------------------------
test "SONNY-1326: non-strict deployment with no tenant scope is unchanged" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, false);
    defer h.deinit();
    _ = try seedFixture(&h, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // shortestPath STILL crosses the bridge: a1 -> a2 -> b1.
    {
        var res = try h.runAs(aa, null, q_path_cross);
        defer res.deinit(aa);
        try testing.expectEqual(@as(?usize, 3), try pathNodeCount(res));
    }
    // COUNT{} STILL sees the other tenant.
    {
        var res = try h.runAs(aa, null, q_count_b);
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 2), try scalarInt(res));
    }
    // EXISTS{} is STILL true.
    {
        var res = try h.runAs(aa, null, q_exists_b);
        defer res.deinit(aa);
        try testing.expectEqual(true, try scalarBool(res));
    }
    // The correlated count STILL counts the bridge for a2.
    {
        var res = try h.runAs(aa, null, "MATCH (a:" ++ label_a ++ ") RETURN a.who AS who, COUNT { (a)-[:L]->(x) } AS c");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
        for (res.rows) |row| {
            try testing.expectEqual(@as(i64, 1), row[1].Int);
        }
    }
    // The anonymous shape STILL sees every tenant (see the note in test 2 on
    // what this shape actually counts).
    {
        var res = try h.runAs(aa, null, "RETURN COUNT { ()-[:L]->() } AS c");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 4), try scalarInt(res));
    }
    // The comprehension STILL yields the other tenant's element.
    {
        var res = try h.runAs(aa, null, q_comp);
        defer res.deinit(aa);
        var xs = try listStrings(allocator, res);
        defer xs.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), xs.items.len);
        try testing.expect(containsStr(xs.items, "a2"));
        try testing.expect(containsStr(xs.items, "b1"));
    }
}
