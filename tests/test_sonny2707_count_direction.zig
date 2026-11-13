// SONNY-2707 parts (2) and (3), and the multi-hop residual: the expression
// path's pattern subqueries (`COUNT { }`, `EXISTS { }`, pattern
// comprehensions) answered a different question from the MATCH they spell.
//
//   (2) COUNT {} over an unbound relationship counted the start nodes. The
//       SONNY-1562 fix (6291d8ff) made an uncorrelated pattern count its hop
//       per start node, but the hop it counted still walked OUTGOING edges
//       only (`(a)<-[r]-(b)` and `(a)-[r]-(b)` counted `(a)-[r]->(b)`), and it
//       ignored a property map on the relationship and never bound the
//       relationship variable for the WHERE (`WHERE r.w >= 2` read null).
//   (3) A variable-length subquery walked outgoing edges only, whatever the
//       pattern's direction, and counted the DISTINCT nodes it reached instead
//       of the paths (and a comprehension treated `-[*1..2]-` as one hop).
//   (multi-hop) Only `hops[0]` of a chain was evaluated: `COUNT { (a)-[:R]->
//       (m)-[:R]->(b) }` counted `(a)-[:R]->(m)`.
//
// The oracle is the plain MATCH that spells the same pattern, run in the same
// session: `RETURN COUNT { P } AS c` must equal `MATCH P RETURN count(*)`, a
// correlated `COUNT { (a)… }` per row must equal the MATCH grouped by `a`,
// `EXISTS { P }` must be `count > 0`, and `size([P | x])` must equal the
// count. The single-hop and variable-length counts are also checked against
// the test's own walk of the seeded edge list, so a MATCH that is itself wrong
// shows up.
//
// Four sessions, as the neighbouring regressions use: in-memory, plain
// persisted, tenant-scoped (tenant_b holds a copy of the graph and two bridge
// edges carrying the READER's tag reach into it) and an RLS session whose user
// may not read `:Hidden` (node 6, which sits on incoming and undirected paths).
// The persisted sessions are checked again after a checkpoint and a reload.
//
// CANARY: REQ=REQ-SONNY-2707-COUNT-DIRECTION; FEATURE="PatternSubquery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2707_count_direction.zig; OWNER=execution; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// The graph.

const node_count = 7;
/// `:Hidden` in every session; only the RLS session's policy denies it.
const hidden_k = 6;

/// Each node's extra label (every node is `:V`).
const labels = [node_count][]const u8{ "A", "B", "A", "B", "", "A", "Hidden" };

const Edge = struct { from: u8, to: u8, rel: []const u8, w: i64 };

/// A cycle 0->1->2->0, parallel edges 0->1 (R and S) and 4->2 (R and S), a
/// self-loop on 3, and 3->6->5 through the hidden node.
const edges = [_]Edge{
    .{ .from = 0, .to = 1, .rel = "R", .w = 1 }, .{ .from = 1, .to = 2, .rel = "R", .w = 2 },
    .{ .from = 2, .to = 0, .rel = "R", .w = 3 }, .{ .from = 2, .to = 3, .rel = "S", .w = 1 },
    .{ .from = 3, .to = 3, .rel = "R", .w = 1 }, .{ .from = 4, .to = 2, .rel = "R", .w = 2 },
    .{ .from = 4, .to = 2, .rel = "S", .w = 1 }, .{ .from = 0, .to = 1, .rel = "S", .w = 2 },
    .{ .from = 5, .to = 4, .rel = "R", .w = 1 }, .{ .from = 3, .to = 6, .rel = "R", .w = 1 },
    .{ .from = 6, .to = 5, .rel = "R", .w = 1 }, .{ .from = 1, .to = 4, .rel = "R", .w = 3 },
};

// ---------------------------------------------------------------------------
// The test's own walk of `edges`.

const Direction = enum { out, in, both };

const Walk = struct {
    /// The start node's k (null: any).
    start_k: ?u8 = null,
    start_label: ?[]const u8 = null,
    end_label: ?[]const u8 = null,
    end_k: ?u8 = null,
    dir: Direction,
    rel: ?[]const u8 = null,
    /// Only edges whose w is this (a property map on the relationship).
    w: ?i64 = null,
    /// Only edges whose w is at least / at most this (a WHERE on it).
    w_min: ?i64 = null,
    w_max: ?i64 = null,
    min: u8 = 1,
    max: u8 = 1,
    /// A quantified pattern: no node twice on a path (the engine's default
    /// ACYCLIC mode). A fixed single hop has no such rule.
    acyclic: bool = false,
};

/// How the walk's matches are reported, to compare with the query's rows.
const Rows = enum {
    /// One count.
    total,
    /// `start|n` for each start with a match.
    by_start,
    /// `end|n` for each end with a match.
    by_end,
    /// `start|end|n` for each pair with a match.
    by_start_end,
    /// `start` for each start with a match (an EXISTS filter).
    starts,
};

fn hasLabel(k: usize, label: ?[]const u8) bool {
    const l = label orelse return true;
    return std.mem.eql(u8, l, "V") or std.mem.eql(u8, labels[k], l);
}

const Counts = [node_count][node_count]usize;

/// The matches of `w` through nodes `visible` admits, by start and end. An
/// undirected pattern walks each edge once per orientation, except a
/// self-loop, whose two orientations bind the same path (ISO/IEC 39075
/// matches are path bindings): one match.
fn walkCounts(w: Walk, visible: [node_count]bool) Counts {
    var counts: Counts = @splat(@splat(0));
    for (0..node_count) |s| {
        if (w.start_k) |k| if (s != k) continue;
        if (!visible[s] or !hasLabel(s, w.start_label)) continue;
        var on_path: [node_count]bool = @splat(false);
        on_path[s] = true;
        walkFrom(w, visible, &on_path, &counts[s], @intCast(s), 0);
    }
    return counts;
}

fn walkFrom(w: Walk, visible: [node_count]bool, on_path: *[node_count]bool, ends: *[node_count]usize, at: u8, depth: u8) void {
    if (depth >= w.min and hasLabel(at, w.end_label)) {
        if (w.end_k == null or w.end_k.? == at) ends[at] += 1;
    }
    if (depth == w.max) return;
    for (edges) |e| {
        if (w.rel) |rel| if (!std.mem.eql(u8, rel, e.rel)) continue;
        if (w.w) |want| if (e.w != want) continue;
        if (w.w_min) |lo| if (e.w < lo) continue;
        if (w.w_max) |hi| if (e.w > hi) continue;
        for ([_]Direction{ .out, .in }) |way| {
            if (w.dir != .both and w.dir != way) continue;
            if (w.dir == .both and way == .in and e.from == e.to) continue;
            const from, const to = switch (way) {
                .out => .{ e.from, e.to },
                .in, .both => .{ e.to, e.from },
            };
            if (from != at or !visible[to]) continue;
            if (w.acyclic and on_path[to]) continue;
            on_path[to] = true;
            walkFrom(w, visible, on_path, ends, to, depth + 1);
            on_path[to] = false;
        }
    }
}

/// The walk's matches as the query's rows would show them, sorted.
fn walkRows(aa: std.mem.Allocator, w: Walk, visible: [node_count]bool, rows: Rows) ![]const []const u8 {
    const counts = walkCounts(w, visible);
    var out: std.ArrayList([]const u8) = .empty;
    switch (rows) {
        .total => {
            var n: usize = 0;
            for (counts) |row| for (row) |c| {
                n += c;
            };
            try out.append(aa, try std.fmt.allocPrint(aa, "{d}", .{n}));
        },
        .by_start, .starts => for (counts, 0..) |row, s| {
            var n: usize = 0;
            for (row) |c| n += c;
            if (n == 0) continue;
            try out.append(aa, if (rows == .starts) try std.fmt.allocPrint(aa, "{d}", .{s}) else try std.fmt.allocPrint(aa, "{d}|{d}", .{ s, n }));
        },
        .by_end => for (0..node_count) |e| {
            var n: usize = 0;
            for (counts) |row| n += row[e];
            if (n != 0) try out.append(aa, try std.fmt.allocPrint(aa, "{d}|{d}", .{ e, n }));
        },
        .by_start_end => for (counts, 0..) |row, s| for (row, 0..) |c, e| {
            if (c != 0) try out.append(aa, try std.fmt.allocPrint(aa, "{d}|{d}|{d}", .{ s, e, c }));
        },
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

// ---------------------------------------------------------------------------
// Sessions.

const Mode = enum { in_memory, persisted, tenant_scoped, rls_policy };

const tenant_a = "tenant_a";
const tenant_b = "tenant_b";

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        const persisted = mode != .in_memory;
        if (persisted) graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        // The catalog's own files go to the test's directory either way.
        graph_store.setDataDirOverride(allocator, data_dir);
        defer if (!persisted) graph_store.setDataDirOverride(allocator, null);
        const catalog = try execution.ensureCatalogInstance(allocator);
        // COUNT {}, EXISTS {} and pattern comprehensions reach the executor
        // through the evaluator's injected callbacks.
        execution.initEvaluator();
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.rls) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Run one statement as the server does: with the context installed.
    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn seedGraph(self: *Session, tenant: ?[]const u8) !void {
        const aa = self.arena.allocator();
        for (0..node_count) |k| {
            const extra = labels[k];
            const label = if (extra.len == 0) "V" else try std.fmt.allocPrint(aa, "V:{s}", .{extra});
            try self.execAs(tenant, try std.fmt.allocPrint(aa, "CREATE (:{s} {{k: {d}}})", .{ label, k }));
        }
        for (edges) |e| {
            try self.execAs(tenant, try std.fmt.allocPrint(aa, "MATCH (a:V {{k: {d}}}), (b:V {{k: {d}}}) CREATE (a)-[:{s} {{w: {d}}}]->(b)", .{ e.from, e.to, e.rel, e.w }));
        }
    }

    fn seed(self: *Session) !void {
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        if (self.mode == .tenant_scoped) try self.seedGraph(tenant_b);
        try self.seedGraph(own);
        if (self.mode == .tenant_scoped) {
            // Two bridges between the tenants, both carrying the READER's tag:
            // only the endpoint check keeps a walk out of tenant_b.
            const store = graph_store.getGlobalStore(testing.allocator);
            _ = try store.createEdgeWithGraphAndTenant(try idOf(tenant_a, 0), try idOf(tenant_b, 4), "R", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
            _ = try store.createEdgeWithGraphAndTenant(try idOf(tenant_b, 1), try idOf(tenant_a, 2), "R", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
        }
        self.ctx.tenant_id = own;
        if (self.mode == .rls_policy) {
            const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
            engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
            self.rls = engine;
            try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", "bob");
            rls_types.setGlobalRLSFilterEngine(engine);
            self.ctx.user = "bob";
        }
    }

    fn visible(self: *const Session) [node_count]bool {
        var v: [node_count]bool = @splat(true);
        if (self.mode == .rls_policy) v[hidden_k] = false;
        return v;
    }

    fn reopen(self: *Session) !void {
        if (self.mode == .in_memory) return;
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
        try graph_store.getGlobalStore(testing.allocator).loadFromFile();
    }
};

fn idOf(tenant: []const u8, k: i64) !u64 {
    const store = graph_store.getGlobalStore(testing.allocator);
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (!std.mem.eql(u8, node.tenant_id, tenant)) continue;
        if (node.properties.get("k")) |pv| {
            if (pv == .Int and pv.Int == k) return entry.key_ptr.*;
        }
    }
    return error.NodeNotFound;
}

// ---------------------------------------------------------------------------
// Checks.

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str, .Text => |s| try aa.dupe(u8, s),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// The rows as `a|b` strings, sorted; with `drop_zero`, without the rows
/// whose last cell is 0 or false (a correlated subquery's empty rows, which
/// the grouped MATCH has no row for).
fn rowsOf(s: *Session, query: []const u8, drop_zero: bool) ![]const []const u8 {
    const aa = s.arena.allocator();
    var result = try s.run(query);
    defer result.deinit(aa);
    var out: std.ArrayList([]const u8) = .empty;
    for (result.rows) |row| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        if (drop_zero and cells.len > 0) {
            const last = cells[cells.len - 1];
            if (std.mem.eql(u8, last, "0") or std.mem.eql(u8, last, "false")) continue;
        }
        try out.append(aa, try std.mem.join(aa, "|", cells));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

const Failures = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.SubqueryDisagreesWithMatch;
    }
};

const Kind = enum {
    /// The same rows (a count, or per-row counts with the zero rows dropped).
    same,
    /// `q` is one boolean, the oracle one count: EXISTS is count > 0.
    exists,
};

const Case = struct {
    /// The COUNT {}, EXISTS {} or comprehension query.
    q: []const u8,
    /// The plain MATCH that spells the same pattern.
    oracle: []const u8,
    kind: Kind = .same,
    /// Drop `q`'s rows whose last cell is 0 or false (a correlated
    /// subquery's empty rows, which the grouped MATCH has no row for).
    drop_zero: bool = false,
    /// The test's own walk, and how its matches are reported. When set it is
    /// the expected answer, and MATCH must agree with it too.
    walk: ?Walk = null,
    rows: Rows = .total,
    /// MATCH is itself wrong for this shape in some session (each is named
    /// in the case's comment and reported separately): the subquery is held
    /// to the walk, and MATCH is not compared.
    match_wrong: bool = false,
    /// The engine's PathIterator, which the MATCH executors and now the
    /// subqueries share, yields fewer paths than the walk here (it expands
    /// only the first path to reach a node at a given depth, reported
    /// separately): the subquery is held to MATCH, not the walk.
    path_dedup: bool = false,
};

fn sameRows(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn runCase(s: *Session, stage: []const u8, c: Case, f: *Failures) !void {
    const aa = s.arena.allocator();
    const mode = @tagName(s.mode);
    var expected: []const []const u8 = &.{};
    var source: []const u8 = c.oracle;
    if (c.walk != null and !c.path_dedup) {
        expected = try walkRows(aa, c.walk.?, s.visible(), c.rows);
        source = "the walk";
        if (!c.match_wrong) {
            const from_match = rowsOf(s, c.oracle, false) catch |err| {
                try f.add("[{s}/{s}] oracle {s}: error {s}", .{ mode, stage, c.oracle, @errorName(err) });
                return;
            };
            if (!sameRows(from_match, expected)) {
                try f.add("[{s}/{s}] MATCH disagrees with the walk: {s}: walk {{{s}}}, MATCH {{{s}}}", .{ mode, stage, c.oracle, try std.mem.join(aa, ",", expected), try std.mem.join(aa, ",", from_match) });
            }
        }
    } else {
        expected = rowsOf(s, c.oracle, false) catch |err| {
            try f.add("[{s}/{s}] oracle {s}: error {s}", .{ mode, stage, c.oracle, @errorName(err) });
            return;
        };
    }
    if (c.kind == .exists) {
        const nonzero = expected.len == 1 and !std.mem.eql(u8, expected[0], "0");
        const one = try aa.alloc([]const u8, 1);
        one[0] = if (nonzero) "true" else "false";
        expected = one;
    }
    const got = rowsOf(s, c.q, c.drop_zero) catch |err| {
        try f.add("[{s}/{s}] {s}: error {s}", .{ mode, stage, c.q, @errorName(err) });
        return;
    };
    if (!sameRows(got, expected)) {
        try f.add("[{s}/{s}] {s}: expected {{{s}}} (from {s}), got {{{s}}}", .{ mode, stage, c.q, try std.mem.join(aa, ",", expected), source, try std.mem.join(aa, ",", got) });
    }
}

fn runCases(title: []const u8, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for ([_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy }) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.seed();
        for (cases) |c| try runCase(&s, "warm", c, &f);
        if (mode == .in_memory) continue;
        s.reopen() catch |err| {
            try f.add("[{s}] reload failed: {s}", .{ @tagName(mode), @errorName(err) });
            continue;
        };
        for (cases) |c| try runCase(&s, "reloaded", c, &f);
    }
    try f.finish(title);
}

// ---------------------------------------------------------------------------
// Part (2): a single unbound relationship, every direction.

const unbound_relationship_cases = [_]Case{
    // Uncorrelated: untyped, each direction. The undirected count holds the
    // self-loop on 3 once; the legacy MATCH executor (in-memory, tenant and
    // RLS sessions) counts it twice, the persisted planned read once.
    .{ .q = "RETURN COUNT { ()-[]->() } AS c", .oracle = "MATCH ()-[]->() RETURN count(*) AS c", .walk = .{ .dir = .out } },
    .{ .q = "RETURN COUNT { (a)-[r]->(b) } AS c", .oracle = "MATCH (a)-[r]->(b) RETURN count(*) AS c", .walk = .{ .dir = .out } },
    .{ .q = "RETURN COUNT { (a)<-[r]-(b) } AS c", .oracle = "MATCH (a)<-[r]-(b) RETURN count(*) AS c", .walk = .{ .dir = .in } },
    .{ .q = "RETURN COUNT { (a)-[r]-(b) } AS c", .oracle = "MATCH (a)-[r]-(b) RETURN count(*) AS c", .walk = .{ .dir = .both }, .match_wrong = true },
    // Typed, labels on either end.
    .{ .q = "RETURN COUNT { (a:A)-[:R]->(b) } AS c", .oracle = "MATCH (a:A)-[:R]->(b) RETURN count(*) AS c", .walk = .{ .dir = .out, .rel = "R", .start_label = "A" } },
    .{ .q = "RETURN COUNT { (a:A)<-[:R]-(b:B) } AS c", .oracle = "MATCH (a:A)<-[:R]-(b:B) RETURN count(*) AS c", .walk = .{ .dir = .in, .rel = "R", .start_label = "A", .end_label = "B" } },
    .{ .q = "RETURN COUNT { (a:A)-[:S]-(b) } AS c", .oracle = "MATCH (a:A)-[:S]-(b) RETURN count(*) AS c", .walk = .{ .dir = .both, .rel = "S", .start_label = "A" } },
    .{ .q = "RETURN COUNT { (a)-[:R]-(b:A) } AS c", .oracle = "MATCH (a)-[:R]-(b:A) RETURN count(*) AS c", .walk = .{ .dir = .both, .rel = "R", .end_label = "A" } },
    // A property map on the relationship, and on the end node. MATCH is
    // wrong for two: the persisted planned read answers 0 for an untyped
    // relationship with a property map, and the legacy executor ignores the
    // end node's property map behind an unlabelled start.
    .{ .q = "RETURN COUNT { (a)-[r:R {w: 1}]->(b) } AS c", .oracle = "MATCH (a)-[r:R {w: 1}]->(b) RETURN count(*) AS c", .walk = .{ .dir = .out, .rel = "R", .w = 1 } },
    .{ .q = "RETURN COUNT { (a)<-[{w: 2}]-(b) } AS c", .oracle = "MATCH (a)<-[{w: 2}]-(b) RETURN count(*) AS c", .walk = .{ .dir = .in, .w = 2 }, .match_wrong = true },
    .{ .q = "RETURN COUNT { (a)<-[:R]-(b:V {k: 4}) } AS c", .oracle = "MATCH (a)<-[:R]-(b:V {k: 4}) RETURN count(*) AS c", .walk = .{ .dir = .in, .rel = "R", .end_k = 4 }, .match_wrong = true },
    // A WHERE inside the subquery, on the relationship and on both ends.
    // The persisted planned read misses matches of an undirected pattern
    // with a WHERE or a property map on the relationship.
    .{ .q = "RETURN COUNT { (a:B)-[r]-(b) WHERE r.w >= 2 } AS c", .oracle = "MATCH (a:B)-[r]-(b) WHERE r.w >= 2 RETURN count(*) AS c", .walk = .{ .dir = .both, .start_label = "B", .w_min = 2 }, .match_wrong = true },
    .{ .q = "RETURN COUNT { MATCH (a)<-[r]-(b) WHERE a.k < b.k } AS c", .oracle = "MATCH (a)<-[r]-(b) WHERE a.k < b.k RETURN count(*) AS c" },
    // EXISTS, true and false, where only the direction decides.
    .{ .q = "RETURN EXISTS { (a:B)<-[:S]-(b:A) } AS e", .oracle = "MATCH (a:B)<-[:S]-(b:A) RETURN count(*) AS c", .kind = .exists, .walk = .{ .dir = .in, .rel = "S", .start_label = "B", .end_label = "A" } },
    .{ .q = "RETURN EXISTS { (a:A)<-[:S]-(b:B) } AS e", .oracle = "MATCH (a:A)<-[:S]-(b:B) RETURN count(*) AS c", .kind = .exists, .walk = .{ .dir = .in, .rel = "S", .start_label = "A", .end_label = "B" } },
    // Correlated to an outer variable: the start, the end, and both.
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)<-[r]-(b) } AS c", .oracle = "MATCH (a:V)<-[r]-(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .in }, .rows = .by_start },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[r]-(b) } AS c", .oracle = "MATCH (a:V)-[r]-(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .both }, .rows = .by_start, .match_wrong = true },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[:R {w: 1}]->() } AS c", .oracle = "MATCH (a:V)-[:R {w: 1}]->() RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .out, .rel = "R", .w = 1 }, .rows = .by_start },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[r]-(b) WHERE r.w = 2 } AS c", .oracle = "MATCH (a:V)-[r]-(b) WHERE r.w = 2 RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .both, .w = 2 }, .rows = .by_start, .match_wrong = true },
    .{ .q = "MATCH (b:V) RETURN b.k, COUNT { (a:A)<-[:R]-(b) } AS c", .oracle = "MATCH (a:A)<-[:R]-(b:V) RETURN b.k, count(*) AS c GROUP BY b.k", .drop_zero = true, .walk = .{ .dir = .in, .rel = "R", .start_label = "A" }, .rows = .by_end },
    .{ .q = "MATCH (a:V), (b:V) RETURN a.k, b.k, COUNT { (a)-[]-(b) } AS c", .oracle = "MATCH (a:V)-[]-(b:V) RETURN a.k, b.k, count(*) AS c GROUP BY a.k, b.k", .drop_zero = true, .walk = .{ .dir = .both }, .rows = .by_start_end, .match_wrong = true },
    .{ .q = "MATCH (a:V) WHERE EXISTS { (a)<-[:S]-() } RETURN a.k", .oracle = "MATCH (a:V)<-[:S]-() RETURN DISTINCT a.k", .walk = .{ .dir = .in, .rel = "S" }, .rows = .starts },
    .{ .q = "MATCH (a:V) WHERE EXISTS { (a)-[:S]-(:A) } RETURN a.k", .oracle = "MATCH (a:V)-[:S]-(:A) RETURN DISTINCT a.k", .walk = .{ .dir = .both, .rel = "S", .end_label = "A" }, .rows = .starts },
    // A pattern comprehension, incoming and undirected. The persisted planned
    // read returns no group at all for the first oracle, and misses a match
    // of the second.
    .{ .q = "MATCH (a:V) RETURN a.k, size([(a)<-[r]-(b) WHERE r.w <= 2 | b.k]) AS n", .oracle = "MATCH (a:V)<-[r]-(b) WHERE r.w <= 2 RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .in, .w_max = 2 }, .rows = .by_start, .match_wrong = true },
    .{ .q = "RETURN size([(a:A)-[:R {w: 3}]-(b) | b.k]) AS n", .oracle = "MATCH (a:A)-[:R {w: 3}]-(b) RETURN count(*) AS c", .walk = .{ .dir = .both, .rel = "R", .w = 3, .start_label = "A" }, .match_wrong = true },
};

test "SONNY-2707 (2): COUNT {} and EXISTS {} over an unbound relationship agree with MATCH, in every direction" {
    try runCases("unbound relationship subqueries", &unbound_relationship_cases);
}

// ---------------------------------------------------------------------------
// Part (3): variable-length subqueries honour the pattern's direction, and
// count paths.

// The cases marked `path_dedup` reach a node twice at one depth (the parallel
// 0->1 and 4->2 edges, the diamond through 1 and 4): the walk counts every
// path, PathIterator expands only the first, so MATCH and the subquery,
// which share it, count fewer (e.g. `(a:V {k: 0})-[*1..3]->(b)`: the walk 12,
// MATCH 7). The subquery is held to MATCH there.
const variable_length_cases = [_]Case{
    .{ .q = "RETURN COUNT { (a:V {k: 0})-[*1..3]->(b) } AS c", .oracle = "MATCH (a:V {k: 0})-[*1..3]->(b) RETURN count(*) AS c", .walk = .{ .start_k = 0, .dir = .out, .min = 1, .max = 3, .acyclic = true }, .path_dedup = true },
    .{ .q = "RETURN COUNT { (a:V {k: 0})<-[*1..3]-(b) } AS c", .oracle = "MATCH (a:V {k: 0})<-[*1..3]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 0, .dir = .in, .min = 1, .max = 3, .acyclic = true }, .path_dedup = true },
    .{ .q = "RETURN COUNT { (a:V {k: 0})-[*1..3]-(b) } AS c", .oracle = "MATCH (a:V {k: 0})-[*1..3]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 0, .dir = .both, .min = 1, .max = 3, .acyclic = true }, .path_dedup = true },
    .{ .q = "RETURN COUNT { (a:V {k: 2})<-[:R*1..2]-(b) } AS c", .oracle = "MATCH (a:V {k: 2})<-[:R*1..2]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 2, .dir = .in, .rel = "R", .min = 1, .max = 2, .acyclic = true } },
    .{ .q = "RETURN COUNT { (a:V {k: 2})-[:R*0..2]-(b) } AS c", .oracle = "MATCH (a:V {k: 2})-[:R*0..2]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 2, .dir = .both, .rel = "R", .min = 0, .max = 2, .acyclic = true } },
    // m = 0 incoming: the only way into 5 is through the hidden node 6.
    .{ .q = "RETURN COUNT { (a:V {k: 5})<-[*0..2]-(b) } AS c", .oracle = "MATCH (a:V {k: 5})<-[*0..2]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 5, .dir = .in, .min = 0, .max = 2, .acyclic = true } },
    // Every start, labels on either end.
    .{ .q = "RETURN COUNT { (a:A)<-[:R*1..2]-(b) } AS c", .oracle = "MATCH (a:A)<-[:R*1..2]-(b) RETURN count(*) AS c", .walk = .{ .start_label = "A", .dir = .in, .rel = "R", .min = 1, .max = 2, .acyclic = true } },
    .{ .q = "RETURN COUNT { (a)-[*1..2]-(b:B) } AS c", .oracle = "MATCH (a)-[*1..2]-(b:B) RETURN count(*) AS c", .walk = .{ .end_label = "B", .dir = .both, .min = 1, .max = 2, .acyclic = true }, .path_dedup = true },
    .{ .q = "RETURN COUNT { (a:V {k: 4})<-[*1..3]-(b:A) WHERE b.k > 0 } AS c", .oracle = "MATCH (a:V {k: 4})<-[*1..3]-(b:A) WHERE b.k > 0 RETURN count(*) AS c" },
    .{ .q = "RETURN EXISTS { (a:V {k: 3})<-[:S*1..2]-(b:V {k: 4}) } AS e", .oracle = "MATCH (a:V {k: 3})<-[:S*1..2]-(b:V {k: 4}) RETURN count(*) AS c", .kind = .exists, .walk = .{ .start_k = 3, .end_k = 4, .dir = .in, .rel = "S", .min = 1, .max = 2, .acyclic = true } },
    .{ .q = "RETURN EXISTS { (a:V {k: 4})<-[:S*1..2]-(b) } AS e", .oracle = "MATCH (a:V {k: 4})<-[:S*1..2]-(b) RETURN count(*) AS c", .kind = .exists, .walk = .{ .start_k = 4, .dir = .in, .rel = "S", .min = 1, .max = 2, .acyclic = true } },
    // Correlated.
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)<-[*1..2]-(b) } AS c", .oracle = "MATCH (a:V)<-[*1..2]-(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .in, .min = 1, .max = 2, .acyclic = true }, .rows = .by_start, .path_dedup = true },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[:R*1..2]-(b) } AS c", .oracle = "MATCH (a:V)-[:R*1..2]-(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .both, .rel = "R", .min = 1, .max = 2, .acyclic = true }, .rows = .by_start },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[*0..1]->(b) } AS c", .oracle = "MATCH (a:V)-[*0..1]->(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .out, .min = 0, .max = 1, .acyclic = true }, .rows = .by_start },
    .{ .q = "MATCH (a:V) WHERE EXISTS { (a)<-[:S*1..2]-(:A) } RETURN a.k", .oracle = "MATCH (a:V)<-[:S*1..2]-(:A) RETURN DISTINCT a.k", .walk = .{ .dir = .in, .rel = "S", .end_label = "A", .min = 1, .max = 2, .acyclic = true }, .rows = .starts },
    // Pattern comprehensions.
    .{ .q = "RETURN size([(a:V {k: 0})<-[*1..2]-(b) | b.k]) AS n", .oracle = "MATCH (a:V {k: 0})<-[*1..2]-(b) RETURN count(*) AS c", .walk = .{ .start_k = 0, .dir = .in, .min = 1, .max = 2, .acyclic = true } },
    .{ .q = "MATCH (a:V) RETURN a.k, size([(a)-[*1..2]-(b) | b.k]) AS n", .oracle = "MATCH (a:V)-[*1..2]-(b) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true, .walk = .{ .dir = .both, .min = 1, .max = 2, .acyclic = true }, .rows = .by_start, .path_dedup = true },
};

test "SONNY-2707 (3): variable-length COUNT {}, EXISTS {} and comprehensions honour the pattern's direction" {
    try runCases("variable-length subqueries", &variable_length_cases);
}

// ---------------------------------------------------------------------------
// The multi-hop residual: every hop of a chain, and every chain of a comma
// pattern, is evaluated.

const multi_hop_cases = [_]Case{
    .{ .q = "RETURN COUNT { (a)-[:R]->(m)-[:R]->(b) } AS c", .oracle = "MATCH (a:V)-[:R]->(m)-[:R]->(b) RETURN count(*) AS c" },
    .{ .q = "RETURN COUNT { (a:A)-[]->(m)<-[:S]-(b) } AS c", .oracle = "MATCH (a:A)-[]->(m)<-[:S]-(b) RETURN count(*) AS c" },
    .{ .q = "RETURN COUNT { (a)-[:R]->(m)-[:R*1..2]-(b) } AS c", .oracle = "MATCH (a:V)-[:R]->(m)-[:R*1..2]-(b) RETURN count(*) AS c" },
    .{ .q = "RETURN COUNT { (a)-[r1]->(m)-[r2]->(b) WHERE r1.w < r2.w } AS c", .oracle = "MATCH (a:V)-[r1]->(m)-[r2]->(b) WHERE r1.w < r2.w RETURN count(*) AS c" },
    .{ .q = "RETURN EXISTS { (a:B)-[:S]->(m)-[:S]->(b) } AS e", .oracle = "MATCH (a:B)-[:S]->(m)-[:S]->(b) RETURN count(*) AS c", .kind = .exists },
    .{ .q = "RETURN COUNT { (a:A)-[:R]->(b), (b)-[:R]->(c:A) } AS c", .oracle = "MATCH (a:A)-[:R]->(b), (b)-[:R]->(c:A) RETURN count(*) AS c" },
    .{ .q = "MATCH (a:V) RETURN a.k, COUNT { (a)-[]-(m)-[:R]->(b:A) } AS c", .oracle = "MATCH (a:V)-[]-(m)-[:R]->(b:A) RETURN a.k, count(*) AS c GROUP BY a.k", .drop_zero = true },
    .{ .q = "MATCH (a:V) WHERE EXISTS { (a)-[:R]->()-[:S]->() } RETURN a.k", .oracle = "MATCH (a:V)-[:R]->()-[:S]->() RETURN DISTINCT a.k" },
    .{ .q = "RETURN size([(a)-[:R]->(m)-[:R]->(b) | b.k]) AS n", .oracle = "MATCH (a:V)-[:R]->(m)-[:R]->(b) RETURN count(*) AS c" },
};

test "SONNY-2707: a multi-hop chain inside COUNT {} or EXISTS {} is evaluated hop by hop, not by its first hop" {
    try runCases("multi-hop subqueries", &multi_hop_cases);
}
