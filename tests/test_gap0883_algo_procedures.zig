// GAP-0883: server-level coverage for the documented `CALL algo.*` graph
// algorithm procedures, driven through the REAL parse → dispatch → executor
// path (`src/execution/algo_dispatch.zig` → `src/execution/
// centrality_algorithms.zig`) over a real GraphStore — no local-struct
// theater, no mocks.
//
// Two fixtures:
//   1. Two directed 3-cycles ("triangles") joined by a single bridge edge —
//      the canonical community-detection fixture (mirrors
//      tests/e2e_graph_algos_new.zig, which covers the library level).
//      a→b→c→a   d→e→f→d   bridge c→d
//   2. The 8-person social network published in
//      docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md — every expected output printed
//      in that guide is verified here against the actual executors.
//
// Procedure surface under test (exactly the set documented in the guide):
//   algo.degree.stream, algo.betweenness.stream, algo.closeness.stream,
//   algo.eigenvector.stream, algo.louvain.stream, algo.labelPropagation.stream,
//   algo.unionFind.stream, algo.scc.stream
//
// CANARY: REQ=REQ-GQL-068; FEATURE="ExposedAlgorithms"; ASPECT=CallProcedureE2E; STATUS=TESTED; TEST=tests/test_gap0883_algo_procedures.zig; OWNER=graph; UPDATED=2026-06-11
// CANARY: REQ=REQ-GRAPH-LOUVAIN-001; FEATURE="LouvainCommunityDetection"; ASPECT=CallProcedureE2E; STATUS=TESTED; TEST=tests/test_gap0883_algo_procedures.zig; OWNER=graph; UPDATED=2026-06-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors tests/test_fts_e2e.zig: real store + real parser + real
/// executor, isolated per-test data dir.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    store: *graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
            .store = store,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Resolve a node's internal id by its string `name` property.
    pub fn idByName(self: *Harness, name: []const u8) !u64 {
        var it = self.store.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.properties.get("name")) |pv| {
                if (pv == .String and std.mem.eql(u8, pv.String, name)) {
                    return entry.key_ptr.*;
                }
            }
        }
        return error.NodeNotFound;
    }
};

/// Convert an executor result Value (Int for ids/degrees, Decimal scale-6 for
/// centrality scores) to f64 for comparisons.
fn valToF64(v: Value) !f64 {
    return switch (v) {
        .Int => |i| @floatFromInt(i),
        .BigInt => |i| @floatFromInt(i),
        .SmallInt => |i| @floatFromInt(i),
        .Double => |d| d,
        .Real => |r| r,
        .Decimal => |d| blk: {
            var denom: f64 = 1;
            var s: u8 = 0;
            while (s < d.scale) : (s += 1) denom *= 10;
            break :blk @as(f64, @floatFromInt(@as(i64, @intCast(d.coeff)))) / denom;
        },
        else => error.UnexpectedValueType,
    };
}

fn valToU64(v: Value) !u64 {
    return switch (v) {
        .Int => |i| if (i < 0) error.UnexpectedValueType else @intCast(i),
        else => error.UnexpectedValueType,
    };
}

/// Collect a two-column (nodeId, value) result into an id → f64 map.
fn collectScores(allocator: std.mem.Allocator, res: execution.ExecutionResult) !std.AutoHashMap(u64, f64) {
    var map = std.AutoHashMap(u64, f64).init(allocator);
    errdefer map.deinit();
    for (res.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        try map.put(try valToU64(row[0]), try valToF64(row[1]));
    }
    return map;
}

/// Collect a two-column (nodeId, groupId) result into an id → u64 map.
fn collectGroups(allocator: std.mem.Allocator, res: execution.ExecutionResult) !std.AutoHashMap(u64, u64) {
    var map = std.AutoHashMap(u64, u64).init(allocator);
    errdefer map.deinit();
    for (res.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        try map.put(try valToU64(row[0]), try valToU64(row[1]));
    }
    return map;
}

fn countDistinct(allocator: std.mem.Allocator, map: *std.AutoHashMap(u64, u64)) !usize {
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var it = map.valueIterator();
    while (it.next()) |v| try seen.put(v.*, {});
    return seen.count();
}

/// Two directed triangles joined by one bridge edge:
///   a→b→c→a (triangle A), d→e→f→d (triangle B), c→d (bridge).
const two_triangle_fixture =
    "CREATE (a:P {name: 'a'}), (b:P {name: 'b'}), (c:P {name: 'c'}), " ++
    "(d:P {name: 'd'}), (e:P {name: 'e'}), (f:P {name: 'f'}), " ++
    "(a)-[:L]->(b), (b)-[:L]->(c), (c)-[:L]->(a), " ++
    "(d)-[:L]->(e), (e)-[:L]->(f), (f)-[:L]->(d), " ++
    "(c)-[:L]->(d)";

const NodeIds = struct { a: u64, b: u64, c: u64, d: u64, e: u64, f: u64 };

fn seedTwoTriangles(h: *Harness) !NodeIds {
    const aa = h.arena.allocator();
    var r = try h.runQuery(two_triangle_fixture);
    r.deinit(aa);
    return .{
        .a = try h.idByName("a"),
        .b = try h.idByName("b"),
        .c = try h.idByName("c"),
        .d = try h.idByName("d"),
        .e = try h.idByName("e"),
        .f = try h.idByName("f"),
    };
}

test "GAP-0883: every documented algo.* procedure dispatches through CALL (doc casing)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    _ = try seedTwoTriangles(&h);

    // Exactly the procedure set documented in docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md,
    // invoked with the doc's casing (dispatch normalizes to lowercase per RQ-0022).
    const documented = [_][]const u8{
        "CALL algo.degree.stream()",
        "CALL algo.betweenness.stream()",
        "CALL algo.closeness.stream()",
        "CALL algo.eigenvector.stream()",
        "CALL algo.louvain.stream()",
        "CALL algo.labelPropagation.stream()",
        "CALL algo.unionFind.stream()",
        "CALL algo.scc.stream()",
    };
    for (documented) |q| {
        var res = try h.runQuery(q);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 6), res.rows.len);
        try testing.expectEqual(@as(usize, 2), res.columns.len);
    }
}

test "GAP-0883: algo.degree.stream returns real degrees (bridge endpoints have degree 3)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.degree.stream()");
    defer res.deinit(aa);
    var deg = try collectScores(testing.allocator, res);
    defer deg.deinit();

    try testing.expectEqual(@as(f64, 2), deg.get(ids.a).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.b).?);
    try testing.expectEqual(@as(f64, 3), deg.get(ids.c).?); // bridge endpoint
    try testing.expectEqual(@as(f64, 3), deg.get(ids.d).?); // bridge endpoint
    try testing.expectEqual(@as(f64, 2), deg.get(ids.e).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.f).?);
}

test "GAP-0883: algo.betweenness.stream ranks the bridge endpoints strictly highest" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.betweenness.stream()");
    defer res.deinit(aa);
    var bc = try collectScores(testing.allocator, res);
    defer bc.deinit();

    const others = [_]u64{ ids.a, ids.b, ids.e, ids.f };
    for ([_]u64{ ids.c, ids.d }) |bridge_end| {
        for (others) |o| {
            try testing.expect(bc.get(bridge_end).? > bc.get(o).?);
        }
    }
}

test "GAP-0883: algo.closeness.stream ranks the bridge endpoints highest" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.closeness.stream()");
    defer res.deinit(aa);
    var cc = try collectScores(testing.allocator, res);
    defer cc.deinit();

    const others = [_]u64{ ids.a, ids.b, ids.e, ids.f };
    for ([_]u64{ ids.c, ids.d }) |bridge_end| {
        for (others) |o| {
            try testing.expect(cc.get(bridge_end).? > cc.get(o).?);
        }
    }
}

test "GAP-0883: algo.eigenvector.stream returns finite non-negative scores" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    _ = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.eigenvector.stream()");
    defer res.deinit(aa);
    var ev = try collectScores(testing.allocator, res);
    defer ev.deinit();

    try testing.expectEqual(@as(usize, 6), ev.count());
    var any_positive = false;
    var it = ev.valueIterator();
    while (it.next()) |score| {
        try testing.expect(std.math.isFinite(score.*));
        try testing.expect(score.* >= 0);
        if (score.* > 0) any_positive = true;
    }
    try testing.expect(any_positive);
}

test "GAP-0883: algo.louvain.stream detects the two triangle communities (non-degenerate)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.louvain.stream()");
    defer res.deinit(aa);
    var comm = try collectGroups(testing.allocator, res);
    defer comm.deinit();

    // Each triangle collapses into a single community...
    try testing.expectEqual(comm.get(ids.a).?, comm.get(ids.b).?);
    try testing.expectEqual(comm.get(ids.b).?, comm.get(ids.c).?);
    try testing.expectEqual(comm.get(ids.d).?, comm.get(ids.e).?);
    try testing.expectEqual(comm.get(ids.e).?, comm.get(ids.f).?);
    // ...the bridge does NOT merge them...
    try testing.expect(comm.get(ids.a).? != comm.get(ids.d).?);
    // ...and the result is NOT the one-community-per-node degenerate output.
    try testing.expectEqual(@as(usize, 2), try countDistinct(testing.allocator, &comm));
}

test "GAP-0883: algo.labelPropagation.stream converges to a non-singleton partition" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.labelPropagation.stream()");
    defer res.deinit(aa);
    var labels = try collectGroups(testing.allocator, res);
    defer labels.deinit();

    try testing.expectEqual(@as(usize, 6), labels.count());
    // Propagation must actually have propagated: strictly fewer labels than
    // nodes (the degenerate one-label-per-node output is a failure)...
    const distinct = try countDistinct(testing.allocator, &labels);
    try testing.expect(distinct < 6);
    try testing.expect(distinct >= 1);
    // ...and every node must share its label with at least one neighbor
    // (label propagation's local-consistency invariant at convergence).
    const adjacency = [_][2]u64{
        .{ ids.a, ids.b }, .{ ids.b, ids.c }, .{ ids.c, ids.a },
        .{ ids.d, ids.e }, .{ ids.e, ids.f }, .{ ids.f, ids.d },
        .{ ids.c, ids.d },
    };
    for ([_]u64{ ids.a, ids.b, ids.c, ids.d, ids.e, ids.f }) |node| {
        var shares = false;
        for (adjacency) |edge| {
            const neighbor: ?u64 = if (edge[0] == node) edge[1] else if (edge[1] == node) edge[0] else null;
            if (neighbor) |n| {
                if (labels.get(node).? == labels.get(n).?) shares = true;
            }
        }
        try testing.expect(shares);
    }
}

test "GAP-0883: algo.unionFind.stream — one component, then two after an isolated pair" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    {
        var res = try h.runQuery("CALL algo.unionFind.stream()");
        defer res.deinit(aa);
        var comp = try collectGroups(testing.allocator, res);
        defer comp.deinit();
        try testing.expectEqual(@as(usize, 6), comp.count());
        try testing.expectEqual(@as(usize, 1), try countDistinct(testing.allocator, &comp));
    }

    // Add an isolated pair (mirrors the usage-guide "With Isolation" example).
    {
        var r = try h.runQuery("CREATE (g:P {name: 'g'}), (i:P {name: 'i'}), (g)-[:L]->(i)");
        r.deinit(aa);
    }
    {
        var res = try h.runQuery("CALL algo.unionFind.stream()");
        defer res.deinit(aa);
        var comp = try collectGroups(testing.allocator, res);
        defer comp.deinit();
        try testing.expectEqual(@as(usize, 8), comp.count());
        try testing.expectEqual(@as(usize, 2), try countDistinct(testing.allocator, &comp));
        const g_id = try h.idByName("g");
        const i_id = try h.idByName("i");
        try testing.expectEqual(comp.get(g_id).?, comp.get(i_id).?);
        try testing.expect(comp.get(g_id).? != comp.get(ids.a).?);
    }
}

test "GAP-0883: algo.scc.stream finds the two directed 3-cycles as separate SCCs" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedTwoTriangles(&h);

    var res = try h.runQuery("CALL algo.scc.stream()");
    defer res.deinit(aa);
    var scc = try collectGroups(testing.allocator, res);
    defer scc.deinit();

    // Each directed triangle is one SCC; the one-way bridge c→d does not merge them.
    try testing.expectEqual(scc.get(ids.a).?, scc.get(ids.b).?);
    try testing.expectEqual(scc.get(ids.b).?, scc.get(ids.c).?);
    try testing.expectEqual(scc.get(ids.d).?, scc.get(ids.e).?);
    try testing.expectEqual(scc.get(ids.e).?, scc.get(ids.f).?);
    try testing.expect(scc.get(ids.a).? != scc.get(ids.d).?);
    try testing.expectEqual(@as(usize, 2), try countDistinct(testing.allocator, &scc));
}

// ---------------------------------------------------------------------------
// docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md social-network fixture — verifies the
// published example outputs against the actual executors.
// ---------------------------------------------------------------------------

/// The guide's 8-person network as a single CREATE statement:
///   Alice-Bob, Alice-Charlie, Alice-Diana, Bob-Diana, Charlie-Diana,
///   Diana-Eve, Eve-Frank, Frank-Grace, Grace-Henry.
const social_fixture =
    "CREATE (alice:Person {name: 'Alice', age: 30}), " ++
    "(bob:Person {name: 'Bob', age: 25}), " ++
    "(charlie:Person {name: 'Charlie', age: 35}), " ++
    "(diana:Person {name: 'Diana', age: 28}), " ++
    "(eve:Person {name: 'Eve', age: 32}), " ++
    "(frank:Person {name: 'Frank', age: 27}), " ++
    "(grace:Person {name: 'Grace', age: 29}), " ++
    "(henry:Person {name: 'Henry', age: 31}), " ++
    "(alice)-[:FRIENDS_WITH {since: 2020}]->(bob), " ++
    "(alice)-[:FRIENDS_WITH {since: 2019}]->(charlie), " ++
    "(alice)-[:FRIENDS_WITH {since: 2021}]->(diana), " ++
    "(bob)-[:FRIENDS_WITH {since: 2021}]->(diana), " ++
    "(charlie)-[:FRIENDS_WITH {since: 2020}]->(diana), " ++
    "(diana)-[:FRIENDS_WITH {since: 2022}]->(eve), " ++
    "(eve)-[:FRIENDS_WITH {since: 2021}]->(frank), " ++
    "(frank)-[:FRIENDS_WITH {since: 2020}]->(grace), " ++
    "(grace)-[:FRIENDS_WITH {since: 2019}]->(henry)";

const SocialIds = struct {
    alice: u64,
    bob: u64,
    charlie: u64,
    diana: u64,
    eve: u64,
    frank: u64,
    grace: u64,
    henry: u64,
};

fn seedSocial(h: *Harness) !SocialIds {
    const aa = h.arena.allocator();
    var r = try h.runQuery(social_fixture);
    r.deinit(aa);
    return .{
        .alice = try h.idByName("Alice"),
        .bob = try h.idByName("Bob"),
        .charlie = try h.idByName("Charlie"),
        .diana = try h.idByName("Diana"),
        .eve = try h.idByName("Eve"),
        .frank = try h.idByName("Frank"),
        .grace = try h.idByName("Grace"),
        .henry = try h.idByName("Henry"),
    };
}

test "GAP-0883 usage-guide fixture: degree matches the published table" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.degree.stream()");
    defer res.deinit(aa);
    var deg = try collectScores(testing.allocator, res);
    defer deg.deinit();

    try testing.expectEqual(@as(f64, 4), deg.get(ids.diana).?); // most connected
    try testing.expectEqual(@as(f64, 3), deg.get(ids.alice).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.bob).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.charlie).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.eve).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.frank).?);
    try testing.expectEqual(@as(f64, 2), deg.get(ids.grace).?);
    try testing.expectEqual(@as(f64, 1), deg.get(ids.henry).?);
}

test "GAP-0883 usage-guide fixture: betweenness ranks Diana > Eve > others" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.betweenness.stream()");
    defer res.deinit(aa);
    var bc = try collectScores(testing.allocator, res);
    defer bc.deinit();

    // Diana bridges the Alice cluster to the Eve-Frank-Grace-Henry chain.
    // Verified raw Brandes pair counts (the executor does NOT normalize):
    //   Diana 25 > Eve 24 > Frank 20 > Grace 12 > Alice 1 > Bob/Charlie/Henry 0.
    try testing.expectEqual(@as(f64, 25), bc.get(ids.diana).?);
    try testing.expectEqual(@as(f64, 24), bc.get(ids.eve).?);
    try testing.expectEqual(@as(f64, 20), bc.get(ids.frank).?);
    try testing.expectEqual(@as(f64, 12), bc.get(ids.grace).?);
    try testing.expectEqual(@as(f64, 1), bc.get(ids.alice).?);
    try testing.expectEqual(@as(f64, 0), bc.get(ids.bob).?);
    try testing.expectEqual(@as(f64, 0), bc.get(ids.charlie).?);
    // Leaf node Henry has zero betweenness.
    try testing.expectEqual(@as(f64, 0), bc.get(ids.henry).?);
}

test "GAP-0883 usage-guide fixture: closeness — Diana and Eve are joint-highest" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.closeness.stream()");
    defer res.deinit(aa);
    var cc = try collectScores(testing.allocator, res);
    defer cc.deinit();

    // Verified: Diana and Eve tie at the top (both 7/13 ≈ 0.538461), then
    // Frank ≈ 0.466666, Alice ≈ 0.411764; Henry is lowest (0.28).
    const diana = cc.get(ids.diana).?;
    const eve = cc.get(ids.eve).?;
    try testing.expectApproxEqAbs(@as(f64, 0.538461), diana, 0.00001);
    try testing.expectApproxEqAbs(diana, eve, 0.00001);
    for ([_]u64{ ids.alice, ids.bob, ids.charlie, ids.frank, ids.grace, ids.henry }) |o| {
        try testing.expect(diana > cc.get(o).?);
    }
    const henry = cc.get(ids.henry).?;
    for ([_]u64{ ids.alice, ids.bob, ids.charlie, ids.diana, ids.eve, ids.frank, ids.grace }) |o| {
        try testing.expect(cc.get(o).? > henry);
    }
}

test "GAP-0883 usage-guide fixture: eigenvector — Diana then Alice lead; scores decay down the chain" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.eigenvector.stream()");
    defer res.deinit(aa);
    var ev = try collectScores(testing.allocator, res);
    defer ev.deinit();

    // Verified ordering: Diana > Alice > Bob = Charlie > Eve > Frank > Grace > Henry.
    try testing.expect(ev.get(ids.diana).? > ev.get(ids.alice).?);
    try testing.expect(ev.get(ids.alice).? > ev.get(ids.bob).?);
    try testing.expectApproxEqAbs(ev.get(ids.bob).?, ev.get(ids.charlie).?, 0.00001);
    try testing.expect(ev.get(ids.bob).? > ev.get(ids.eve).?);
    try testing.expect(ev.get(ids.eve).? > ev.get(ids.frank).?);
    try testing.expect(ev.get(ids.frank).? > ev.get(ids.grace).?);
    try testing.expect(ev.get(ids.grace).? > ev.get(ids.henry).?);
}

test "GAP-0883 usage-guide fixture: labelPropagation converges (non-singleton, locally consistent)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.labelPropagation.stream()");
    defer res.deinit(aa);
    var labels = try collectGroups(testing.allocator, res);
    defer labels.deinit();

    // Label propagation's tie-breaking depends on store iteration order, so
    // the exact split is NOT deterministic across runs (observed outcomes on
    // this fixture range from one community to a few). What IS guaranteed at
    // convergence — and what the guide now documents instead of the
    // previously published (never-produced) [1..4]/[5..8] table:
    //   (a) propagation happened: strictly fewer labels than nodes;
    //   (b) local consistency: every node shares its label with >= 1 neighbor.
    try testing.expectEqual(@as(usize, 8), labels.count());
    const distinct = try countDistinct(testing.allocator, &labels);
    try testing.expect(distinct >= 1 and distinct < 8);

    const adjacency = [_][2]u64{
        .{ ids.alice, ids.bob }, .{ ids.alice, ids.charlie }, .{ ids.alice, ids.diana },
        .{ ids.bob, ids.diana }, .{ ids.charlie, ids.diana }, .{ ids.diana, ids.eve },
        .{ ids.eve, ids.frank }, .{ ids.frank, ids.grace },   .{ ids.grace, ids.henry },
    };
    const all = [_]u64{ ids.alice, ids.bob, ids.charlie, ids.diana, ids.eve, ids.frank, ids.grace, ids.henry };
    for (all) |node| {
        var shares = false;
        for (adjacency) |edge| {
            const neighbor: ?u64 = if (edge[0] == node) edge[1] else if (edge[1] == node) edge[0] else null;
            if (neighbor) |n| {
                if (labels.get(node).? == labels.get(n).?) shares = true;
            }
        }
        try testing.expect(shares);
    }
}

test "GAP-0883 usage-guide fixture: scc — directed friendship edges yield 8 singleton SCCs" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    _ = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.scc.stream()");
    defer res.deinit(aa);
    var scc = try collectGroups(testing.allocator, res);
    defer scc.deinit();

    // Verified: SCC is a DIRECTED algorithm. The guide's fixture has no
    // directed cycle, so every node is its own strongly connected component.
    // (The previously published table claimed one 8-node SCC "treating as
    // undirected"; the real executor uses outgoing edges only.)
    try testing.expectEqual(@as(usize, 8), scc.count());
    try testing.expectEqual(@as(usize, 8), try countDistinct(testing.allocator, &scc));
}

test "GAP-0883 usage-guide fixture: louvain groups the Alice cluster apart from the chain tail" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const ids = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.louvain.stream()");
    defer res.deinit(aa);
    var comm = try collectGroups(testing.allocator, res);
    defer comm.deinit();

    // Stable invariants across runs (the Eve→Frank→Grace→Henry chain has
    // near-tied modularity optima, so its exact split — typically the pairs
    // {Eve, Frank} + {Grace, Henry}, sometimes a different chain grouping —
    // is tie-break-order dependent; do NOT pin it):
    //   (a) the densely connected core {Alice, Bob, Charlie, Diana} always
    //       lands in ONE community;
    //   (b) the chain tail (Henry) is never merged into the core;
    //   (c) the result is non-degenerate: 2-3 communities, never
    //       one-per-node and never all-in-one.
    // (The previously published guide table claimed [1..5] + [6..8]; that
    // output was never produced by the real executor and the guide is
    // corrected to the behavior pinned here.)
    try testing.expectEqual(comm.get(ids.alice).?, comm.get(ids.bob).?);
    try testing.expectEqual(comm.get(ids.bob).?, comm.get(ids.charlie).?);
    try testing.expectEqual(comm.get(ids.charlie).?, comm.get(ids.diana).?);
    try testing.expect(comm.get(ids.henry).? != comm.get(ids.alice).?);
    const distinct = try countDistinct(testing.allocator, &comm);
    try testing.expect(distinct >= 2 and distinct <= 3);
}

test "GAP-0883 usage-guide fixture: unionFind reports a single connected component" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    _ = try seedSocial(&h);

    var res = try h.runQuery("CALL algo.unionFind.stream()");
    defer res.deinit(aa);
    var comp = try collectGroups(testing.allocator, res);
    defer comp.deinit();

    try testing.expectEqual(@as(usize, 8), comp.count());
    try testing.expectEqual(@as(usize, 1), try countDistinct(testing.allocator, &comp));
}

// GAP-0514 P3 (REQ-GQL-GRAPH-STATS-001): the graph-statistics procedures
// (density / diameter / mean distance / triangle count / global clustering)
// dispatch through CALL and return real values for the two-triangle fixture.
test "GAP-0514 P3: graph statistics procedures return real values through CALL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    _ = try seedTwoTriangles(&h);

    // Density: 7 directed edges over 6*(6-1) ordered pairs = 7/30.
    var dres = try h.runQuery("CALL algo.density()");
    defer dres.deinit(aa);
    try testing.expectEqual(@as(usize, 1), dres.rows.len);
    const density = try valToF64(dres.rows[0][0]);
    try testing.expectApproxEqAbs(@as(f64, 7.0 / 30.0), density, 0.001);

    // Diameter: longest shortest path is finite and at least the bridge span.
    var dia = try h.runQuery("CALL algo.diameter()");
    defer dia.deinit(aa);
    try testing.expectEqual(@as(usize, 1), dia.rows.len);
    const diameter = try valToF64(dia.rows[0][0]);
    try testing.expect(std.math.isFinite(diameter));
    try testing.expect(diameter >= 1);

    // Mean distance: positive and no larger than the diameter.
    var md = try h.runQuery("CALL algo.meandistance()");
    defer md.deinit(aa);
    const mean = try valToF64(md.rows[0][0]);
    try testing.expect(std.math.isFinite(mean));
    try testing.expect(mean >= 1);
    try testing.expect(mean <= diameter);

    // Triangle count: at least the two seeded 3-cycles register as triangles.
    var tc = try h.runQuery("CALL algo.trianglecount()");
    defer tc.deinit(aa);
    const triangles = try valToF64(tc.rows[0][0]);
    try testing.expect(triangles >= 1);

    // Global clustering coefficient: a valid ratio in [0, 1].
    var gc = try h.runQuery("CALL algo.globalclustering()");
    defer gc.deinit(aa);
    const coeff = try valToF64(gc.rows[0][0]);
    try testing.expect(std.math.isFinite(coeff));
    try testing.expect(coeff >= 0 and coeff <= 1);
}
