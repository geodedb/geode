// SONNY-6337, SONNY-3184, SONNY-3167, SONNY-3389: OPTIONAL MATCH, WITH
// DISTINCT and CALL { } in the read executors.
//
// ISO/IEC 39075 composes a linear query over one working table:
// - OPTIONAL MATCH is a left outer join: each incoming record is joined to the
//   matches of the optional pattern (its own WHERE is part of the match
//   condition); a record with no surviving match is kept once, with the
//   optional pattern's new variables NULL. A variable bound before it (by the
//   MATCH, or a WITH before it) constrains the pattern. A WHERE written on the
//   OPTIONAL MATCH restricts which matches join; it never drops the incoming
//   record. A FILTER or a WITH ... WHERE after it does.
// - DISTINCT on a WITH or RETURN removes duplicate records (NULLs equal).
// - A statement-level CALL { } joins the body's records onto the incoming
//   record; the RETURN after it is computed over the joined table.
//
// SONNY-6337: `WITH ... OPTIONAL MATCH` was a syntax error, and a part with an
// OPTIONAL MATCH naming a WITH-bound variable was refused (0A000).
// SONNY-3184: the OPTIONAL MATCH's WHERE filtered the whole row; a chained
// OPTIONAL MATCH bound null; an EXISTS { } inner WHERE was always false.
// SONNY-3167 / SONNY-6296 item 1: the legacy executor ignored WITH DISTINCT
// (hop and comma patterns); CALL { } returned the body's rows.
// SONNY-3389: the RETURN after a statement-level CALL { } was ignored.
// SONNY-3391: EXISTS / COUNT { } over a relationship with no bound end.
//
// Fixture (as tests/test_sonny3046_with_bound_variable_join.zig): four
// `:Q {k}` (k = 0..3; Q0 and Q1 also `f: 1`), four `:X {k}`, four `:Y {k}`,
// eight `:Z {k}`; `(Yk)-[:R]->(Qk)-[:R {w: k}]->(Xk)`, `(Q0)-[:S]->(Q1)` and a
// self loop `(Q3)-[:S]->(Q3)`. So `(q)-[:S]->(t)` matches for Q0 (t = Q1) and
// Q3 (t = Q3) only. A tenant-scoped session's other tenant has a `:Q {k: 50}`
// and an untagged `:X {k: 99}` hangs off Q0 by an untagged `:R`; an RLS
// session has the same `:X:Hidden {k: 99}` its user may not read: neither may
// appear in any answer, and an optional side that reaches only it is NULL.
//
// Every statement runs on its own leak-checked allocator with a query scratch
// arena installed, as the server does.
//
// CANARY: REQ=REQ-SONNY-3184-OPTIONAL-MATCH; FEATURE="OptionalMatchLeftOuterJoin"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11

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
    /// Persisted, no tenant, no policy (warm).
    persisted,
    /// Persisted, session tenant `tenant_a`.
    tenant_scoped,
    /// Persisted, the user may not read `:Hidden`.
    rls_policy,
};

const modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

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
        // EXISTS {} and COUNT {} reach the executor through the evaluator's
        // injected callbacks.
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

fn renderCell(aa: std.mem.Allocator, cell: Value) anyerror![]const u8 {
    return switch (cell) {
        .Str, .Text => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *p| p.* = try renderCell(aa, item);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ", ", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

const Case = struct {
    q: []const u8,
    /// The rows, each rendered as `a, b`; in any order unless `ordered`.
    want: []const []const u8 = &.{},
    /// The rows must come in `want`'s order.
    ordered: bool = false,
    /// The statement must fail with this error instead.
    err: ?anyerror = null,
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
        return error.WrongReadResult;
    }
};

fn runCase(s: *Session, f: *Failures, c: Case) !void {
    const aa = s.arena.allocator();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const got: ?[]const []const u8 = blk: {
        const prev = query_arena.pushScratchAllocator(scratch.allocator());
        defer query_arena.popScratchAllocator(prev);
        var result = s.runWith(gpa.allocator(), c.q) catch |err| {
            if (c.err) |want| {
                if (err != want) try f.add("[{s}] {s}: expected error {s}, got error {s}", .{ @tagName(s.mode), c.q, @errorName(want), @errorName(err) });
            } else {
                try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), c.q, @errorName(err) });
            }
            break :blk null;
        };
        defer result.deinit(gpa.allocator());
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
    const exp = try aa.dupe([]const u8, c.want);
    const cmp = try aa.dupe([]const u8, rows);
    if (!c.ordered) {
        std.mem.sort([]const u8, exp, {}, lessThan);
        std.mem.sort([]const u8, cmp, {}, lessThan);
    }
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
        for (cases) |c| try runCase(&s, &f, c);
    }
    try f.check(name);
}

/// `q.k, t.k` of `(q:Q)` and its optional `(q)-[:S]->(t)`.
const opt_s: []const []const u8 = &.{ "0, 1", "1, null", "2, null", "3, 3" };
const all_null: []const []const u8 = &.{ "0, null", "1, null", "2, null", "3, null" };
const pairs4: []const []const u8 = &.{ "0, 0", "1, 1", "2, 2", "3, 3" };

// SONNY-6337: OPTIONAL MATCH after WITH parses, and joins on the bound variable.
const sonny6337 = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t", .want = opt_s },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t ORDER BY q DESC", .want = &.{ "3, 3", "2, null", "1, null", "0, 1" }, .ordered = true },
    .{ .q = "MATCH (q:Q {k: 2}) WITH q OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t", .want = &.{"2, null"} },
    .{ .q = "MATCH (q:Q) WITH q AS z OPTIONAL MATCH (z)-[:S]->(t) RETURN z.k AS q, t.k AS t", .want = opt_s },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t:X) RETURN q.k AS q, t.k AS t", .want = all_null },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t {k: 3}) RETURN q.k AS q, t.k AS t", .want = &.{ "0, null", "1, null", "2, null", "3, 3" } },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) RETURN count(t) AS ct, count(*) AS c", .want = &.{"2, 4"} },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) WITH q, t OPTIONAL MATCH (t)-[:R]->(x) RETURN q.k AS q, t.k AS t, x.k AS x", .want = &.{ "0, 1, 1", "1, null, null", "2, null, null", "3, 3, 3" } },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) WITH q, t WHERE t IS NULL RETURN q.k AS k", .want = &.{ "1", "2" } },
    // A hidden or foreign node is no match: the optional side is NULL.
    .{ .q = "MATCH (q:Q {k: 0}) WITH q OPTIONAL MATCH (q)-[:R]->(x:X {k: 99}) RETURN q.k AS q, x.k AS x", .want = &.{"0, null"} },
    .{ .q = "MATCH (q:Q {k: 0}) WITH q OPTIONAL MATCH (q)-[:R]->(x) RETURN q.k AS q, x.k AS x", .want = &.{"0, 0"} },
};

// SONNY-3184: OPTIONAL MATCH in one part: base case, its WHERE, chains.
const sonny3184_optional = [_]Case{
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t", .want = opt_s },
    // The optional's WHERE restricts the matches; the row survives with NULL.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) WHERE t.k > 1 RETURN q.k AS q, t.k AS t", .want = &.{ "0, null", "1, null", "2, null", "3, 3" } },
    .{ .q = "MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t) WHERE t.k > 1 RETURN q.k AS q, t.k AS t", .want = &.{ "0, null", "1, null", "2, null", "3, 3" } },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) WHERE t.k = q.k RETURN q.k AS q, t.k AS t", .want = &.{ "0, null", "1, null", "2, null", "3, 3" } },
    // A WITH ... WHERE or a FILTER after it drops rows.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) WITH q, t WHERE t.k > 1 RETURN q.k AS q, t.k AS t", .want = &.{"3, 3"} },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) FILTER t.k > 1 RETURN q.k AS q, t.k AS t", .want = &.{"3, 3"} },
    // The MATCH's own WHERE still filters.
    .{ .q = "MATCH (q:Q) WHERE q.k >= 2 OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t", .want = &.{ "2, null", "3, 3" } },
    // Incoming direction, and an endpoint label.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)<-[:R]-(y:Y) RETURN q.k AS q, y.k AS y", .want = pairs4 },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)<-[:S]-(p) RETURN q.k AS q, p.k AS p", .want = &.{ "0, null", "1, 0", "2, null", "3, 3" } },
    // Two in sequence: the second starts from the first's possibly-NULL t.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) OPTIONAL MATCH (t)-[:R]->(x) RETURN q.k AS q, t.k AS t, x.k AS x", .want = &.{ "0, 1, 1", "1, null, null", "2, null, null", "3, 3, 3" } },
    .{ .q = "MATCH (y:Y) OPTIONAL MATCH (y)-[:R]->(q)-[:S]->(t) RETURN y.k AS y, t.k AS t", .want = opt_s },
    // Naming no bound variable: NULLs when nothing matches, a product when it does.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (n:Nope) RETURN q.k AS q, n.k AS n", .want = all_null },
    .{ .q = "MATCH (q:Q {k: 1}) OPTIONAL MATCH (z:Z) WHERE z.k < 2 RETURN q.k AS q, z.k AS z", .want = &.{ "1, 0", "1, 1" } },
    .{ .q = "OPTIONAL MATCH (n:Nope) RETURN n.k AS k", .want = &.{"null"} },
    // Aggregates: count(t) skips NULL, count(*) counts rows, collect skips NULL.
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN count(t) AS ct, count(*) AS c", .want = &.{"2, 4"} },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN size(collect(t.k)) AS n", .want = &.{"2"} },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) WITH q, count(t) AS c RETURN q.k AS q, c", .want = &.{ "0, 1", "1, 0", "2, 0", "3, 1" } },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) WITH q, t WHERE t IS NULL RETURN q.k AS k", .want = &.{ "1", "2" } },
    // Hidden or foreign: no match.
    .{ .q = "MATCH (q:Q {k: 0}) OPTIONAL MATCH (q)-[:R]->(x:X {k: 99}) RETURN q.k AS q, x.k AS x", .want = &.{"0, null"} },
    .{ .q = "MATCH (q:Q {k: 0}) OPTIONAL MATCH (q)-[:R]->(x) RETURN q.k AS q, x.k AS x", .want = &.{"0, 0"} },
};

// SONNY-3184 (EXISTS inner WHERE) and SONNY-3391 (no bound end).
const sonny3184_exists = [_]Case{
    .{ .q = "MATCH (q:Q) WHERE EXISTS { (q)-[:S]->(t) WHERE t.k = 1 } RETURN q.k AS k", .want = &.{"0"} },
    .{ .q = "MATCH (q:Q) WHERE EXISTS { MATCH (q)-[:S]->(t) WHERE t.k = 1 } RETURN q.k AS k", .want = &.{"0"} },
    .{ .q = "MATCH (q:Q) WHERE EXISTS { (q)-[:S]->(t) WHERE t.k = q.k } RETURN q.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (q:Q) RETURN q.k AS k, COUNT { (q)-[:S]->(t) WHERE t.k >= 1 } AS c", .want = &.{ "0, 1", "1, 0", "2, 0", "3, 1" } },
    // SONNY-3391: the pattern binds no outer variable.
    .{ .q = "MATCH (q:Q) WHERE EXISTS { (a:Q)-[:S]->(b:Q) WHERE b.k = 3 } RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q {k: 0}) RETURN COUNT { (a:Q)-[:S]->(b) WHERE b.k = 1 } AS c", .want = &.{"1"} },
};

// SONNY-3167 / SONNY-6296 item 1: WITH DISTINCT and RETURN DISTINCT.
const sonny3167_distinct = [_]Case{
    .{ .q = "MATCH (q:Q)-[:R]->(x) WITH DISTINCT q.f AS f RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (q:Q)-[:R]->(x) WITH DISTINCT q.f AS f RETURN f", .want = &.{ "1", "null" } },
    .{ .q = "MATCH (q:Q),(z:Z) WITH DISTINCT q MATCH (q) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q),(z:Z) WITH DISTINCT q RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (q:Q),(z:Z) WITH DISTINCT q RETURN q.k AS k", .want = &.{ "0", "1", "2", "3" } },
    .{ .q = "MATCH (q:Q) WITH DISTINCT q.f AS f RETURN f", .want = &.{ "1", "null" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN DISTINCT q.f AS f", .want = &.{ "1", "null" } },
    .{ .q = "MATCH (q:Q),(z:Z) WITH DISTINCT q ORDER BY q.k DESC LIMIT 2 RETURN q.k AS k", .want = &.{ "3", "2" }, .ordered = true },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x) WITH DISTINCT 1 AS one RETURN one", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q) RETURN DISTINCT [q.f] AS l", .want = &.{ "[1]", "[null]" } },
    // A hidden or foreign :X never counts.
    .{ .q = "MATCH (q:Q)-[:R]->(x) WITH DISTINCT x RETURN count(*) AS c", .want = &.{"4"} },
};

// SONNY-3389 / SONNY-3167: the statement after CALL { }.
const sonny3389_call = [_]Case{
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN k + 1 AS j", .want = &.{ "1", "2", "3", "4" } },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN k ORDER BY k DESC LIMIT 2", .want = &.{ "3", "2" }, .ordered = true },
    .{ .q = "CALL { MATCH (x:X) RETURN count(*) AS n } RETURN n * 10 AS m", .want = &.{"40"} },
    .{ .q = "CALL { MATCH (x:Nope) RETURN x.k AS k } RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "CALL { MATCH (q:Q) RETURN q.f AS f } RETURN DISTINCT f", .want = &.{ "1", "null" } },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } WITH k WHERE k > 1 RETURN count(*) AS c", .want = &.{"2"} },
};

test "SONNY-6337: OPTIONAL MATCH after WITH parses and joins the bound variable" {
    try inEveryMode("SONNY-6337", &sonny6337);
}

test "SONNY-3184: OPTIONAL MATCH keeps the row; its WHERE restricts the match only" {
    try inEveryMode("SONNY-3184 optional", &sonny3184_optional);
}

test "SONNY-3184 / SONNY-3391: EXISTS and COUNT subquery inner WHERE" {
    try inEveryMode("SONNY-3184 exists", &sonny3184_exists);
}

test "SONNY-3167 / SONNY-6296 item 1: WITH DISTINCT and RETURN DISTINCT on every session" {
    try inEveryMode("SONNY-3167 distinct", &sonny3167_distinct);
}

test "SONNY-3389 / SONNY-3167: the RETURN after a statement-level CALL { }" {
    try inEveryMode("SONNY-3389 call", &sonny3389_call);
}
