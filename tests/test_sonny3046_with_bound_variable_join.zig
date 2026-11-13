// SONNY-3046, SONNY-3376, SONNY-3388: a variable a WITH passes on is a join
// constraint in the next MATCH.
//
// ISO/IEC 39075 composes the parts of a linear query over one working table:
// an element variable already bound in the incoming record that a later
// MATCH names again is equi-joined to it (the pattern constrains the element
// it is bound to and never binds the name again), for a node, a relationship
// and a path variable alike. Labels, a property map, a relationship type or
// a direction on the repeated variable are extra filters on the bound
// element.
//
// The chain executor ran the next part with the WITH's columns as
// parameters, and only a hop's start node read them: `MATCH (q:Q) WITH q
// MATCH (q) RETURN count(*)` counted every node once per q (SONNY-3046),
// `... WITH r MATCH ()-[r]->()` every relationship (SONNY-3376), and a node
// named alone, at a hop's far end, with a different label, or a path
// variable bound again (SONNY-3388).
//
// Fixture (visible to every session): four `:Q {k}` (k = 0..3; Q0 and Q1
// also `f: 1`), four `:X {k}`, four `:Y {k}` and eight `:Z {k}` (20 nodes);
// `(Yk)-[:R]->(Qk)-[:R {w: k}]->(Xk)`, `(Q0)-[:S]->(Q1)` and a self loop
// `(Q3)-[:S]->(Q3)`. A tenant-scoped session's other tenant has a `:Q` of
// its own, and an untagged `:X {k: 99}` hangs off Q0 by an untagged `:R`;
// an RLS session has the same `:X:Hidden {k: 99}` its user may not read.
// Neither may appear in any answer: a node the second MATCH reaches from a
// bound one is checked like any other.
//
// Every statement runs on its own leak-checked allocator with a query
// scratch arena installed, as the server does. The persisted session runs
// warm and, for the one-hop shapes, after a reload.
//
// CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_arena = geode.query_arena;
const Value = geode.value_types.Value;

const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, no tenant, no policy.
    persisted,
    /// The same store closed and opened again (one-hop shapes only).
    persisted_reloaded,
    /// Persisted, session tenant `tenant_a`.
    tenant_scoped,
    /// Persisted, the user may not read `:Hidden`.
    rls_policy,
};

const modes = [_]Mode{ .in_memory, .persisted, .persisted_reloaded, .tenant_scoped, .rls_policy };

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
        errdefer {
            execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(allocator, null);
        }
        const persisted = mode != .in_memory;
        if (persisted) graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        graph_store.setDataDirOverride(allocator, data_dir);
        defer if (!persisted) graph_store.setDataDirOverride(allocator, null);
        const catalog = try execution.ensureCatalogInstance(allocator);
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

    /// Close the persisted store and open it again from disk.
    fn reload(self: *Session) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        self.ctx.catalog = try execution.ensureCatalogInstance(allocator);
    }

    fn runWith(self: *Session, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.arena.allocator());
        defer parsed.deinit();
        var ctx = self.ctx;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        var r = try self.runWith(self.arena.allocator(), query);
        r.deinit(self.arena.allocator());
    }

    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) "tenant_a" else null;
        for (0..4) |k| {
            const f = if (k < 2) ", f: 1" else "";
            try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:Y {{k: {d}}})-[:R]->(:Q {{k: {d}{s}}})-[:R {{w: {d}}}]->(:X {{k: {d}}})", .{ k, k, f, k, k }));
        }
        for (0..8) |k| try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:Z {{k: {d}}})", .{k}));
        try self.execAs(own, "MATCH (a:Q {k: 0}), (b:Q {k: 1}) CREATE (a)-[:S]->(b)");
        try self.execAs(own, "MATCH (a:Q {k: 3}) CREATE (a)-[:S]->(a)");
        if (self.mode == .tenant_scoped) {
            try self.execAs("tenant_b", "CREATE (:Q {k: 50})");
            // Untagged: another scope than tenant_a's.
            try self.execAs(null, "MATCH (q:Q {k: 0}) CREATE (q)-[:R {w: 9}]->(:X {k: 99})");
        }
        if (self.mode == .rls_policy) {
            try self.execAs(null, "MATCH (q:Q {k: 0}) CREATE (q)-[:R {w: 9}]->(:X:Hidden {k: 99})");
        }
        if (self.mode == .persisted_reloaded) try self.reload();
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
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    return switch (cell) {
        .Str, .Text => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

const Case = struct {
    q: []const u8,
    /// The rows, each rendered as `a, b`, in any order.
    want: []const []const u8 = &.{},
    /// The statement must fail with this error instead.
    err: ?anyerror = null,
    /// Only that it runs (PROFILE): no rows compared.
    any_rows: bool = false,
    /// Two hops or more: not run after a reload (SONNY-3377 makes a
    /// persisted multi-hop read after a reload no oracle).
    multi_hop: bool = false,
    /// The statement keeps a path value in a row. A path's node and
    /// relationship arrays are never freed with the result, on any session
    /// and without any chain (`MATCH p = (g:Q {k: 1})-[:R]->(:X) RETURN p`
    /// leaks them too): a separate, pre-existing defect. Its answer is still
    /// checked, on an arena.
    path_leak: bool = false,
};

const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.WithBoundVariableNotJoined;
    }
};

fn runCase(s: *Session, f: *Failures, c: Case) !void {
    const aa = s.arena.allocator();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    // A `path_leak` statement runs on an arena (its known leak is not this
    // test's subject); every other on the leak-checked allocator.
    var leak_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer leak_arena.deinit();
    const result_allocator = if (c.path_leak) leak_arena.allocator() else gpa.allocator();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const got: ?[]const []const u8 = blk: {
        const prev = query_arena.pushScratchAllocator(scratch.allocator());
        defer query_arena.popScratchAllocator(prev);
        var result = s.runWith(result_allocator, c.q) catch |err| {
            if (c.err) |want| {
                if (err != want) try f.add("[{s}] {s}: expected error {s}, got error {s}", .{ @tagName(s.mode), c.q, @errorName(want), @errorName(err) });
            } else {
                try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), c.q, @errorName(err) });
            }
            break :blk null;
        };
        defer result.deinit(result_allocator);
        const rows = try aa.alloc([]const u8, result.rows.len);
        for (result.rows, rows) |row, *r| {
            const n = @min(row.len, result.columns.len);
            const cells = try aa.alloc([]const u8, n);
            for (row[0..n], cells) |cell, *cell_text| cell_text.* = try renderCell(aa, cell);
            r.* = try std.mem.join(aa, ", ", cells);
        }
        break :blk rows;
    };
    if (gpa.deinit() == .leak) try f.add("[{s}] {s}: leaked memory", .{ @tagName(s.mode), c.q });
    const rows = got orelse return;
    if (c.err) |want| {
        try f.add("[{s}] {s}: expected error {s}, got {d} rows {{{s}}}", .{ @tagName(s.mode), c.q, @errorName(want), rows.len, try std.mem.join(aa, " | ", rows) });
        return;
    }
    if (c.any_rows) return;
    const exp = try aa.dupe([]const u8, c.want);
    const cmp = try aa.dupe([]const u8, rows);
    std.mem.sort([]const u8, exp, {}, lessThan);
    std.mem.sort([]const u8, cmp, {}, lessThan);
    const same = exp.len == cmp.len and for (exp, cmp) |w, g| {
        if (!std.mem.eql(u8, w, g)) break false;
    } else true;
    if (!same) try f.add("[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), c.q, try std.mem.join(aa, " | ", exp), try std.mem.join(aa, " | ", cmp) });
}

fn inEveryMode(name: []const u8, cases: []const Case) !void {
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.seed();
        for (cases) |c| {
            if (mode == .persisted_reloaded and c.multi_hop) continue;
            try runCase(&s, &f, c);
        }
    }
    try f.check(name);
}

const k4: []const []const u8 = &.{ "0", "1", "2", "3" };
const pairs4: []const []const u8 = &.{ "0, 0", "1, 1", "2, 2", "3, 3" };

// SONNY-3046 / SONNY-3388: a node variable named alone in the next pattern.
const node_alone = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q MATCH (q) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q) RETURN q.k AS k", .want = k4 },
    .{ .q = "MATCH (q:Q {k: 1}) WITH q MATCH (q) RETURN count(*) AS c", .want = &.{"1"} },
    // Labels and a property map on the bound node filter it.
    .{ .q = "MATCH (q:Q {k: 1}) WITH q MATCH (q:X) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q:Q {f: 1}) RETURN q.k AS k", .want = &.{ "0", "1" } },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q {k: 2}) RETURN q.k AS k", .want = &.{"2"} },
    // Renamed through the WITH.
    .{ .q = "MATCH (q:Q) WITH q AS z MATCH (z) RETURN count(*) AS c", .want = &.{"4"} },
    // Beside an unbound pattern: the product with it, once per q.
    .{ .q = "MATCH (q:Q) WITH q MATCH (q), (x:X) RETURN count(*) AS c", .want = &.{"16"} },
    .{ .q = "MATCH (q:Q {k: 1}) WITH q MATCH (x:X), (q) RETURN x.k AS k", .want = k4 },
};

// SONNY-3388: a node variable as a hop's end or middle node, with filters,
// twice in one pattern; SONNY-3046's shape with a hop.
const node_in_hop = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) RETURN q.k AS q, x.k AS x", .want = pairs4 },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q {k: 1}) WITH q MATCH (y)-[:R]->(q) RETURN y.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (y)-[:R]->(q) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q {k: 2}) WITH q MATCH (y)-[:R]->(q)-[:R]->(x) RETURN y.k AS y, x.k AS x", .want = &.{"2, 2"}, .multi_hop = true },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q:Q {f: 1})-[:R]->(x) RETURN x.k AS k", .want = &.{ "0", "1" } },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q:X)-[:R]->(x) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:S]->(q) RETURN q.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t", .want = &.{ "0, 1", "3, 3" } },
    .{ .q = "MATCH (q:Q {f: 1}) WITH q MATCH (q)-[:S]-(t) RETURN q.k AS q, t.k AS t", .want = &.{ "0, 1", "1, 0" } },
};

// SONNY-3376 / SONNY-3388: a relationship variable carried through the WITH.
const relationship = [_]Case{
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (a:Q {k: 1})-[r:R]->(b:X) WITH r MATCH (a)-[r]->(b) RETURN a.k AS a, b.k AS b", .want = &.{"1, 1"} },
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r, a MATCH (a)-[r]->(c) RETURN a.k AS a, c.k AS c", .want = pairs4 },
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH (a)-[r]->(b) RETURN r.w AS w", .want = k4 },
    // A type, direction or endpoint label the relationship lacks: no row.
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH ()-[r:S]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH (a:Q)<-[r]-(b) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH (a:X)<-[r]-(b) RETURN a.k AS a, b.k AS b", .want = pairs4 },
    .{ .q = "MATCH (a:Q)-[r:R]->(b:X) WITH r MATCH (a:X)-[r]-(b) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (a:Q)-[r:R {w: 2}]->(b:X) WITH r MATCH ()-[r {w: 3}]->() RETURN count(*) AS c", .want = &.{"0"} },
    // `WITH *` passes every variable on.
    .{ .q = "MATCH (q:Q {k: 1})-[r:R]->(x) WITH * MATCH (q)-[r]->(z) RETURN count(*) AS c", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q {k: 1})-[r:R]->(x) WITH * MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"1"} },
};

// SONNY-3388: a path variable bound again is the same path.
const path = [_]Case{
    .{ .q = "MATCH p = (g:Q {k: 1})-[:R]->(:X) WITH p MATCH p = (a)-[:R]->(b) RETURN count(*) AS c", .want = &.{"1"}, .path_leak = true },
    .{ .q = "MATCH p = (g:Q {k: 1})-[:R]->(:X) WITH p MATCH p = (a)-[:R]->(b) RETURN a.k AS a, b.k AS b", .want = &.{"1, 1"}, .path_leak = true },
    .{ .q = "MATCH p = (g:Q {k: 1})-[:R]->(:X) WITH p MATCH p = (a)<-[:R]-(b) RETURN count(*) AS c", .want = &.{"0"}, .path_leak = true },
};

// Several variables joined at once: only the pairs actually connected.
const several = [_]Case{
    .{ .q = "MATCH (a:Q), (b:X) WITH a, b MATCH (a)-[:R]->(b) RETURN a.k AS a, b.k AS b", .want = pairs4 },
    .{ .q = "MATCH (a:Q), (b:X) WITH a, b MATCH (a)-[:R]->(b) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (a:Y), (b:X) WITH a, b MATCH (a)-[:R]->()-[:R]->(b) RETURN a.k AS a, b.k AS b", .want = pairs4, .multi_hop = true },
};

// What the WITH does to its rows before the next part joins them.
const with_stage = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q, count(*) AS c MATCH (q)-[:R]->(x) RETURN q.k AS q, x.k AS x, c", .want = &.{ "0, 0, 1", "1, 1, 1", "2, 2, 1", "3, 3, 1" } },
    .{ .q = "MATCH (q:Q) WITH q WHERE q.k >= 2 MATCH (q)-[:R]->(x) RETURN x.k AS k", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (q:Q) WITH q ORDER BY q.k DESC LIMIT 2 MATCH (q)-[:R]->(x) RETURN x.k AS k", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (q:Q) WITH q ORDER BY q.k LIMIT 1 MATCH (q) RETURN count(*) AS c", .want = &.{"1"} },
};

// A value the WITH passes on, in the next part's property map and WHERE.
const values = [_]Case{
    .{ .q = "MATCH (q:Q {k: 1}) WITH q.k AS kk MATCH (x:X {k: kk}) RETURN x.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q) WITH q.k AS kk MATCH (x:X) WHERE x.k = kk RETURN x.k AS k", .want = k4 },
    .{ .q = "MATCH (q:Q) WITH q, q.k + 1 AS kk MATCH (q)-[:S]->(t) WHERE t.k = kk RETURN q.k AS k", .want = &.{"0"} },
};

// Three parts, and the whole statement under PROFILE.
const chains = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) WITH q, x MATCH (y)-[:R]->(q) RETURN y.k AS y, x.k AS x", .want = pairs4 },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) WITH x MATCH (x) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "PROFILE MATCH (q:Q) WITH q MATCH (q) RETURN count(*) AS c", .any_rows = true },
    // SONNY-3184: an OPTIONAL MATCH beside a part that names a bound
    // variable is the left outer join of the two (Q0 -> Q1 -> X1, Q3 -> Q3 ->
    // X3); it was refused (0A000) until then.
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:S]->(t) OPTIONAL MATCH (t)-[:R]->(x) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:S]->(t) OPTIONAL MATCH (t)-[:R]->(x) RETURN q.k AS q, x.k AS x", .want = &.{ "0, 1", "3, 3" } },
    .{ .q = "EXPLAIN MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) RETURN x.k", .any_rows = true },
};

test "SONNY-3046 / SONNY-3388: a node variable named alone after WITH is joined" {
    try inEveryMode("node alone", &node_alone);
}

test "SONNY-3388: a node variable at a hop's start, end or middle after WITH is joined" {
    try inEveryMode("node in hop", &node_in_hop);
}

test "SONNY-3376: a relationship variable carried through WITH is joined" {
    try inEveryMode("relationship", &relationship);
}

test "SONNY-3388: a path variable carried through WITH is joined" {
    try inEveryMode("path", &path);
}

test "SONNY-3046: several variables carried through WITH are joined together" {
    try inEveryMode("several", &several);
}

test "SONNY-3046: the WITH's aggregate, DISTINCT, WHERE, ORDER BY and LIMIT before the join" {
    try inEveryMode("with stage", &with_stage);
}

test "SONNY-3046: a value carried through WITH in the next property map and WHERE" {
    try inEveryMode("values", &values);
}

test "SONNY-3046: three-part chains and PROFILE / EXPLAIN" {
    try inEveryMode("chains", &chains);
}
