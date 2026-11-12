// SONNY-2685 regression: `CALL algo.*` applies the session's RLS policies,
// and its graph, to every node and edge it visits.
//
// SONNY-1318 gave the graph procedures the session's tenant scope and nothing
// else. BFS, DFS, Dijkstra, degree, every centrality, community and component
// procedure, and the graph statistics walked `store.nodes` and the raw
// adjacency: a node or an edge a label or expression policy hides took part
// in every path, distance, degree and score, and nodes of another graph were
// scored and returned too.
//
// Now each call builds an `AlgoScope` (the SONNY-2679 `HopScope`): a node is
// visible when it is in the session's graph, passes the tenant scope and the
// RLS policies of its labels; an edge when it is in the graph, passes the
// policies on its type, and both endpoints are visible. A hidden node or edge
// is neither visited nor returned.
//
// The check: every algorithm, run by a session whose policies hide some rows,
// returns what it returns when those rows are deleted and no policy applies.
// The fixture hides rows four ways, each making a shortcut or joining the two
// triangles of the visible graph:
//   - node x1 by a label-deny policy on :Secret;
//   - node x2 by an expression policy on :P (`row.cls <> 'secret'`);
//   - an edge by a label-deny policy on its type :HIDDEN;
//   - an edge by an expression policy on its type :LINK (`row.w <> 0`).
// A second graph's nodes must never appear.
//
// CANARY: REQ=REQ-SONNY-2685-ALGO-ROW-VISIBILITY; FEATURE="GraphProcedureRowVisibility"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2685_algo_rls.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const RLSEngine = rls.RLSEngine;
const session_user = "bob";

fn policyFor(id: u64, table: []const u8, expr: []const u8) RLSEngine.Policy {
    return .{
        .id = id,
        .name = "p",
        .description = "SONNY-2685",
        .graph = graph_store.DEFAULT_GRAPH_NAME,
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = expr, .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

/// SONNY-2773: the engine's deinit frees the code `createPolicy` compiled
/// (this used to free it by hand, working around the leak).
fn deinitEngine(engine: *RLSEngine) void {
    engine.deinit();
}

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    expr_engine: ?*RLSEngine = null,
    label_engine: ?*rls_types.RLSFilterEngine = null,

    fn init() !Session {
        const allocator = testing.allocator;
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn dropPolicies(self: *Session) void {
        if (self.expr_engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
            deinitEngine(engine);
            testing.allocator.destroy(engine);
            self.expr_engine = null;
        }
        if (self.label_engine) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
            self.label_engine = null;
        }
    }

    fn deinit(self: *Session) void {
        self.dropPolicies();
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn idOf(self: *Session, name: []const u8) !u64 {
        const q = try std.fmt.allocPrint(self.arena.allocator(), "MATCH (n) WHERE n.s = '{s}' RETURN id(n)", .{name});
        var r = try self.run(q);
        defer r.deinit(self.arena.allocator());
        if (r.rows.len != 1) return error.NodeNotFound;
        return @intCast(r.rows[0][0].Int);
    }

    fn installPolicies(self: *Session) !void {
        const engine = try testing.allocator.create(RLSEngine);
        engine.* = RLSEngine.init(testing.allocator) catch |err| {
            testing.allocator.destroy(engine);
            return err;
        };
        self.expr_engine = engine;
        try engine.createPolicy(policyFor(1, "P", "row.cls <> 'secret'"));
        try engine.createPolicy(policyFor(2, "LINK", "row.w <> 0"));
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));

        const labels = try testing.allocator.create(rls_types.RLSFilterEngine);
        labels.* = rls_types.RLSFilterEngine.init(testing.allocator);
        self.label_engine = labels;
        try labels.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Secret", session_user);
        try labels.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "HIDDEN", session_user);
        rls_types.setGlobalRLSFilterEngine(labels);
    }
};

fn link(s: *Session, a: []const u8, b: []const u8, w: i64) !void {
    const q = try std.fmt.allocPrint(s.arena.allocator(), "MATCH (a {{s: '{s}'}}), (b {{s: '{s}'}}) CREATE (a)-[:LINK {{w: {d}}}]->(b)", .{ a, b, w });
    try s.exec(q);
}

/// Two triangles (p1 p2 p3) and (p4 p5 p6) joined by p3-p4 (weight 5), so the
/// cheapest p1 to p6 path is p1 p3 p4 p6 (cost 7). Every hidden row makes a
/// shortcut or joins the triangles.
fn seed(s: *Session) ![2]u64 {
    const nodes = [_][]const u8{
        "CREATE (:P {s: 'p1', cls: 'public'})", "CREATE (:P {s: 'p2', cls: 'public'})",
        "CREATE (:P {s: 'p3', cls: 'public'})", "CREATE (:P {s: 'p4', cls: 'public'})",
        "CREATE (:P {s: 'p5', cls: 'public'})", "CREATE (:P {s: 'p6', cls: 'public'})",
        // Hidden by the label-deny policy on :Secret.
        "CREATE (:Secret {s: 'x1'})",
        // Hidden by the expression policy on :P.
                  "CREATE (:P {s: 'x2', cls: 'secret'})",
    };
    for (nodes) |q| try s.exec(q);
    try link(s, "p1", "p2", 1);
    try link(s, "p2", "p3", 1);
    try link(s, "p3", "p1", 1);
    try link(s, "p4", "p5", 1);
    try link(s, "p5", "p6", 1);
    try link(s, "p6", "p4", 1);
    try link(s, "p3", "p4", 5);
    // Through x1 (label policy): p1 x1 p6.
    try link(s, "p1", "x1", 1);
    try link(s, "x1", "p6", 1);
    // Through x2 (expression policy on the node): p2 x2 p5.
    try link(s, "p2", "x2", 1);
    try link(s, "x2", "p5", 1);
    // An edge hidden by its type's label policy: p1 -> p6.
    try s.exec("MATCH (a {s: 'p1'}), (b {s: 'p6'}) CREATE (a)-[:HIDDEN {w: 1}]->(b)");
    // An edge hidden by the expression policy on its type: p2 -> p6, w 0.
    try link(s, "p2", "p6", 0);

    // Another graph's nodes, which no call on `default` may score.
    const store = graph_store.getGlobalStore(testing.allocator);
    try store.createGraph("g2");
    const y1 = try store.createNodeWithGraph(@constCast(&[_][]const u8{"P"}), "g2");
    const y2 = try store.createNodeWithGraph(@constCast(&[_][]const u8{"P"}), "g2");
    try store.setNodeProperty(y1, "s", .{ .String = "y1" });
    try store.setNodeProperty(y2, "s", .{ .String = "y2" });
    return .{ y1, y2 };
}

/// Delete what the policies hide (as a session with no policy).
fn deleteHidden(s: *Session) !void {
    try s.exec("MATCH (x:Secret) DETACH DELETE x");
    try s.exec("MATCH (x:P {cls: 'secret'}) DETACH DELETE x");
    try s.exec("MATCH ()-[e:HIDDEN]->() DELETE e");
    try s.exec("MATCH ()-[e:LINK {w: 0}]->() DELETE e");
}

// ---------------------------------------------------------------------------
// A canonical form of an algorithm's result, comparable across the two runs.
// ---------------------------------------------------------------------------

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn renderCell(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |f| try std.fmt.allocPrint(aa, "{d:.4}", .{f}),
        .Real => |f| try std.fmt.allocPrint(aa, "{d:.4}", .{f}),
        .Decimal => |d| blk: {
            const div = std.math.pow(f64, 10.0, @floatFromInt(d.scale));
            break :blk try std.fmt.allocPrint(aa, "{d:.4}", .{@as(f64, @floatFromInt(d.coeff)) / div});
        },
        .Str, .Text => |t| t,
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .List => |items| blk: {
            var parts = try aa.alloc([]const u8, items.len);
            for (items, 0..) |item, i| parts[i] = try renderCell(aa, item);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// Columns whose values only name a group (a community, a component, a
/// label propagation label): the canonical form is the partition of nodes.
fn isGroupColumn(name: []const u8) bool {
    const groups = [_][]const u8{ "community", "label", "setId", "componentId" };
    for (groups) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

fn canonical(aa: std.mem.Allocator, result: execution.ExecutionResult) ![]const u8 {
    if (result.columns.len == 2 and std.mem.eql(u8, result.columns[0], "nodeId") and isGroupColumn(result.columns[1])) {
        // group value -> its node ids
        var groups = std.StringHashMap(std.ArrayList([]const u8)).init(aa);
        for (result.rows) |row| {
            const key = try renderCell(aa, row[1]);
            const gop = try groups.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(aa, try renderCell(aa, row[0]));
        }
        var parts: std.ArrayList([]const u8) = .empty;
        var it = groups.valueIterator();
        while (it.next()) |members| {
            std.mem.sort([]const u8, members.items, {}, lessThan);
            try parts.append(aa, try std.fmt.allocPrint(aa, "{{{s}}}", .{try std.mem.join(aa, ",", members.items)}));
        }
        std.mem.sort([]const u8, parts.items, {}, lessThan);
        return std.mem.join(aa, " ", parts.items);
    }
    var rows = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, 0..) |row, i| {
        var cells = try aa.alloc([]const u8, row.len);
        for (row, 0..) |cell, j| cells[j] = try renderCell(aa, cell);
        rows[i] = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, rows, {}, lessThan);
    return std.mem.join(aa, "; ", rows);
}

/// Does any cell of the result, at any depth, hold one of `ids`?
fn mentionsAny(result: execution.ExecutionResult, ids: []const u64) bool {
    for (result.rows) |row| {
        for (row) |cell| {
            if (cellMentions(cell, ids)) return true;
        }
    }
    return false;
}

fn cellMentions(v: Value, ids: []const u64) bool {
    switch (v) {
        .Int => |n| {
            for (ids) |id| {
                if (n >= 0 and @as(u64, @intCast(n)) == id) return true;
            }
        },
        .List => |items| for (items) |item| {
            if (cellMentions(item, ids)) return true;
        },
        else => {},
    }
    return false;
}

const procedures = [_][]const u8{
    "CALL algo.degree.stream()",
    "CALL algo.betweenness.stream()",
    "CALL algo.closeness.stream()",
    "CALL algo.eigenvector.stream()",
    "CALL algo.pagerank.stream()",
    "CALL algo.louvain.stream()",
    "CALL algo.labelpropagation.stream()",
    "CALL algo.unionfind.stream()",
    "CALL algo.scc.stream()",
    "CALL algo.harmonic.stream()",
    "CALL algo.bridgeleverage.stream()",
    "CALL algo.greycardinal.stream()",
    "CALL algo.leiden.stream()",
    "CALL algo.articulationpoints.stream()",
    "CALL algo.bridges.stream()",
    "CALL algo.biconnectedcomponents.stream()",
    "CALL algo.graphdensity()",
    "CALL algo.graphdiameter()",
    "CALL algo.meandistance()",
    "CALL algo.globalclustering()",
    "CALL algo.katz.stream()",
    "CALL algo.hits.stream()",
    "CALL algo.trianglecount()",
    "CALL algo.localclustering()",
    "CALL algo.kcore.stream()",
    "CALL algo.kshell.stream()",
    // {p1} and {p6} are filled in.
    "CALL algo.bfs.stream({p1}, {maxDepth: 3})",
    "CALL algo.dfs.stream({p1}, {maxDepth: 3})",
    "CALL algo.dijkstra.stream({p1}, {p6}, 'w')",
};

fn fill(aa: std.mem.Allocator, template: []const u8, p1: u64, p6: u64) ![]const u8 {
    const a = try std.mem.replaceOwned(u8, aa, template, "{p1}", try std.fmt.allocPrint(aa, "{d}", .{p1}));
    return std.mem.replaceOwned(u8, aa, a, "{p6}", try std.fmt.allocPrint(aa, "{d}", .{p6}));
}

test "SONNY-2685: every CALL algo.* returns, under RLS, what it returns with the hidden rows deleted" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const aa = s.arena.allocator();
    const g2 = try seed(&s);
    const p1 = try s.idOf("p1");
    const p6 = try s.idOf("p6");
    const hidden = [_]u64{ try s.idOf("x1"), try s.idOf("x2"), g2[0], g2[1] };

    // bob, with the policies.
    try s.installPolicies();
    s.ctx.user = session_user;
    var restricted: [procedures.len][]const u8 = undefined;
    var failures: usize = 0;
    for (procedures, 0..) |template, i| {
        const q = try fill(aa, template, p1, p6);
        var r = s.run(q) catch |err| {
            std.debug.print("{s} (with policies): error {s}\n", .{ q, @errorName(err) });
            failures += 1;
            restricted[i] = "";
            continue;
        };
        defer r.deinit(aa);
        if (mentionsAny(r, &hidden)) {
            std.debug.print("{s}: returned a hidden node or another graph's node: {s}\n", .{ q, try canonical(aa, r) });
            failures += 1;
        }
        restricted[i] = try canonical(aa, r);
    }

    // The same calls with the hidden rows deleted and no policy.
    s.dropPolicies();
    s.ctx.user = null;
    try deleteHidden(&s);
    s.ctx.user = session_user;
    for (procedures, 0..) |template, i| {
        const q = try fill(aa, template, p1, p6);
        var r = s.run(q) catch |err| {
            std.debug.print("{s} (hidden rows deleted): error {s}\n", .{ q, @errorName(err) });
            failures += 1;
            continue;
        };
        defer r.deinit(aa);
        const clean = try canonical(aa, r);
        if (!std.mem.eql(u8, restricted[i], clean)) {
            std.debug.print("{s}:\n  with policies:      {s}\n  hidden rows gone:   {s}\n", .{ q, restricted[i], clean });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-2685: a start node the session cannot see gives no rows, and nothing is reached through a hidden node" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const aa = s.arena.allocator();
    _ = try seed(&s);
    const x1 = try s.idOf("x1");
    const x2 = try s.idOf("x2");
    const p6 = try s.idOf("p6");
    try s.installPolicies();
    s.ctx.user = session_user;

    for ([_]u64{ x1, x2 }) |start| {
        inline for (.{ "CALL algo.bfs.stream({d}, {{maxDepth: 3}})", "CALL algo.dfs.stream({d}, {{maxDepth: 3}})" }) |fmt| {
            const q = try std.fmt.allocPrint(aa, fmt, .{start});
            var r = try s.run(q);
            defer r.deinit(aa);
            try testing.expectEqual(@as(usize, 0), r.rows.len);
        }
        const q = try std.fmt.allocPrint(aa, "CALL algo.dijkstra.stream({d}, {d}, 'w')", .{ start, p6 });
        var r = try s.run(q);
        defer r.deinit(aa);
        try testing.expectEqual(@as(usize, 0), r.rows.len);
    }
}
