// SONNY-2696, SONNY-2734: an aggregate combined with an expression.
//
// SONNY-2696: an aggregate NESTED INSIDE a projection item's expression
// (`RETURN count(*) + 1`, `toString(count(*))`, `[count(*), sum(n.i)]`,
// `CASE WHEN count(*) > 5 ...`, the same in a WITH item) was evaluated per
// row or not at all: the shared projection handed the whole item to the
// aggregate code, which computes only a bare aggregate call (NULL for
// `count(*) + 1`), and an item whose outermost node is not an arithmetic
// operator (a function call, a list, a map, a CASE) was not recognised as
// aggregating, so it was evaluated against one row (`toString(count(*))` was
// '1'). Every aggregate inside an item is now lifted into a hidden aggregate
// column computed by the same code as a bare aggregate item, and the item is
// evaluated once per group over those columns and the group's keys.
//
// SONNY-2734: an EXPRESSION INSIDE an aggregate's argument (`sum(n.i * $f)`,
// `count(CASE WHEN n.i > 15 THEN 1 END)`, `avg(n.i + 1)`, `max(n.i * -1)`,
// min / max over dates and strings, `sum(toInteger(n.s))`) was computed
// wrongly by the legacy executor (in-memory, tenant-scoped and RLS sessions),
// whose own aggregate loops read only a property or a member argument. Every
// aggregating RETURN and WITH of a legacy read now goes through the shared
// projection, whose arguments are evaluated per input row by the general
// evaluator.
//
// One fixture with a closed-form answer for every case: 25 `:A {i, g, s, d}`
// with i = 0..24, g = i % 3 (count 9 / 8 / 8, sum(i) 108 / 92 / 100), s =
// toString(i), d = DATE 2026-01-(i+1), and v = i for even i only (13 values,
// sum 156); four `(:P {k})-[:R]->(:Q {k})-[:S]->(:T {k})` chains, k = 0..3.
// A tenant-scoped session's other tenant has five more `:A` nodes and a
// chain; an RLS session has five `:A:Hidden` nodes and a chain its user may
// not read. Neither may contribute to any aggregate.
//
// Every statement runs on its own leak-checked allocator, with a query
// scratch arena installed as the server does, so a hidden column or a lifted
// expression copy that is not freed (on a success or an error path) fails
// the case.
//
// CANARY: REQ=REQ-SONNY-2696-AGGREGATE-EXPRESSIONS; FEATURE="SharedProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2696_aggregate_expressions.zig; OWNER=engine; UPDATED=2026-11-11

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
    /// Persisted, no tenant, no policy: the planned read and its fast paths.
    persisted,
    /// Persisted, session tenant `tenant_a`: the legacy executor.
    tenant_scoped,
    /// Persisted, the user may not read `:Hidden`: the legacy executor.
    rls_policy,
};

const modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

const Param = struct { name: []const u8, value: Value };

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
        // The catalog's own file goes to this test's directory either way.
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

    /// One statement as the server runs it: the context installed, a query
    /// scratch arena on the thread, the result on `allocator`.
    fn runWith(self: *Session, allocator: std.mem.Allocator, query: []const u8, params: []const Param) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const names = try aa.alloc([]const u8, params.len);
        const values = try aa.alloc(Value, params.len);
        for (params, names, values) |p, *n, *v| {
            n.* = p.name;
            v.* = p.value;
        }
        var ctx = self.ctx;
        ctx.query_param_names = names;
        ctx.query_param_values = values;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        var r = try self.runWith(self.arena.allocator(), query, &.{});
        r.deinit(self.arena.allocator());
    }

    /// One `(:P {k})-[:R]->(:Q {k})-[:S]->(:T {k})` chain, the nodes
    /// labelled `extra` too, in one chained CREATE (its anonymous middle
    /// node is created once, SONNY-6295).
    fn chain(self: *Session, tenant: ?[]const u8, k: usize, extra: []const u8) !void {
        const aa = self.arena.allocator();
        try self.execAs(tenant, try std.fmt.allocPrint(aa, "CREATE (:P{s} {{k: {d}}})-[:R]->(:Q{s} {{k: {d}}})-[:S]->(:T{s} {{k: {d}}})", .{ extra, k, extra, k, extra, k }));
    }

    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) "tenant_a" else null;
        if (self.mode == .tenant_scoped) {
            for (0..5) |j| try self.execAs("tenant_b", try std.fmt.allocPrint(aa, "CREATE (:A {{i: {d}, g: 0, s: '{d}', d: DATE '2027-01-01', v: {d}}})", .{ 100 + j, 100 + j, 100 + j }));
            try self.chain("tenant_b", 50, "");
        }
        if (self.mode == .rls_policy) {
            for (0..5) |j| try self.execAs(null, try std.fmt.allocPrint(aa, "CREATE (:A:Hidden {{i: {d}, g: 0, s: '{d}', d: DATE '2027-01-01', v: {d}}})", .{ 100 + j, 100 + j, 100 + j }));
            try self.chain(null, 50, ":Hidden");
        }
        for (0..25) |i| {
            const q = if (i % 2 == 0)
                try std.fmt.allocPrint(aa, "CREATE (:A {{i: {d}, g: {d}, s: '{d}', d: DATE '2026-01-{d:0>2}', v: {d}}})", .{ i, i % 3, i, i + 1, i })
            else
                try std.fmt.allocPrint(aa, "CREATE (:A {{i: {d}, g: {d}, s: '{d}', d: DATE '2026-01-{d:0>2}'}})", .{ i, i % 3, i, i + 1 });
            try self.execAs(own, q);
        }
        for (0..4) |k| try self.chain(own, k, "");
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

/// A cell, its type visible: 'text', `12.5d` for a double, `1.5m` for a
/// decimal, an ISO date, a list in its order (sorted when `sort_lists`), a
/// map with its keys sorted.
fn renderCell(aa: std.mem.Allocator, cell: Value, sort_lists: bool) anyerror![]const u8 {
    var buf: [64]u8 = undefined;
    return switch (cell) {
        .Str, .Text => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| try std.fmt.allocPrint(aa, "{d}d", .{d}),
        .Decimal => try std.fmt.allocPrint(aa, "{s}m", .{try geode.value_types.stringify(cell, &buf)}),
        .Date => try aa.dupe(u8, try geode.value_types.stringify(cell, &buf)),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *p| p.* = try renderCell(aa, item, sort_lists);
            if (sort_lists) std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ", ", parts)});
        },
        .Map => |m| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = m.iterator();
            while (it.next()) |entry| try parts.append(aa, try std.fmt.allocPrint(aa, "{s}:{s}", .{ entry.key_ptr.*, try renderCell(aa, entry.value_ptr.*, sort_lists) }));
            std.mem.sort([]const u8, parts.items, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "{{{s}}}", .{try std.mem.join(aa, ", ", parts.items)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

/// A statement and what it must answer.
const Case = struct {
    q: []const u8,
    params: []const Param = &.{},
    /// The rows, each rendered as `a, b`; in any order unless `ordered`.
    want: []const []const u8 = &.{},
    ordered: bool = false,
    sort_lists: bool = false,
    /// The statement must fail with this error instead.
    err: ?anyerror = null,
};

/// Every failed check, reported together.
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
        return error.AggregateExpressionsWrong;
    }
};

/// Run `c` on its own leak-checked allocator (rows read before the result is
/// released) and compare.
fn runCase(s: *Session, f: *Failures, c: Case) !void {
    const aa = s.arena.allocator();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const got: ?[]const []const u8 = blk: {
        const prev = query_arena.pushScratchAllocator(scratch.allocator());
        defer query_arena.popScratchAllocator(prev);
        var result = s.runWith(gpa.allocator(), c.q, c.params) catch |err| {
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
            for (row[0..n], cells) |cell, *cell_text| cell_text.* = try renderCell(aa, cell, c.sort_lists);
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

/// Run `cases` in a fresh, seeded session of every mode.
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

const f2: []const Param = &.{.{ .name = "f", .value = .{ .Int = 2 } }};

// SONNY-2696: an aggregate inside an item, ungrouped.
const nested_ungrouped = [_]Case{
    .{ .q = "MATCH (n:A) RETURN count(*) + 1 AS x", .want = &.{"26"} },
    .{ .q = "MATCH (n:A) RETURN count(*) + 0 AS x", .want = &.{"25"} },
    .{ .q = "MATCH (n:A) RETURN toString(count(*)) AS x", .want = &.{"'25'"} },
    .{ .q = "MATCH (n:A) RETURN sum(n.i) / count(*) AS x", .want = &.{"12"} },
    .{ .q = "MATCH (n:A) RETURN count(*) > 0 AS x", .want = &.{"true"} },
    .{ .q = "MATCH (n:A) RETURN coalesce(max(n.i), 0) AS x", .want = &.{"24"} },
    .{ .q = "MATCH (n:A) RETURN [count(*), sum(n.i)] AS x", .want = &.{"[25, 300]"} },
    .{ .q = "MATCH (n:A) RETURN {c: count(*)} AS x", .want = &.{"{c:25}"} },
    .{ .q = "MATCH (n:A) RETURN CASE WHEN count(*) > 5 THEN 'many' ELSE 'few' END AS x", .want = &.{"'many'"} },
    .{ .q = "MATCH (n:A) RETURN count(*) + count(*) AS x", .want = &.{"50"} },
    .{ .q = "MATCH (n:A) RETURN sum(n.i) - count(*) AS x", .want = &.{"275"} },
    .{ .q = "MATCH (n:A) RETURN count(*) AS c, count(*) + 1 AS x", .want = &.{"25, 26"} },
    .{ .q = "MATCH (n:A) RETURN toString(count(*)) + '/' + toString(sum(n.i)) AS x", .want = &.{"'25/300'"} },
    .{ .q = "MATCH (n:A) RETURN size(collect(n.i + 1)) AS x", .want = &.{"25"} },
    // Over no rows: count is 0 and sum NULL, inside the expression as alone.
    .{ .q = "MATCH (n:A) WHERE n.i > 1000 RETURN count(*) + 1 AS x, coalesce(sum(n.i), -1) AS s", .want = &.{"1, -1"} },
    // A WHERE after the RETURN filters the computed column.
    .{ .q = "MATCH (n:A) RETURN count(*) + 1 AS x WHERE x > 20", .want = &.{"26"} },
};

// SONNY-2696: the same inside a WITH item.
const nested_with = [_]Case{
    .{ .q = "MATCH (n:A) WITH count(*) + 1 AS x RETURN x", .want = &.{"26"} },
    .{ .q = "MATCH (n:A) WITH toString(count(*)) AS x RETURN x", .want = &.{"'25'"} },
    .{ .q = "MATCH (n:A) WITH [count(*), sum(n.i)] AS x RETURN x", .want = &.{"[25, 300]"} },
    .{ .q = "MATCH (n:A) WITH n.g AS g, count(*) + 1 AS x RETURN g, x", .want = &.{ "0, 10", "1, 9", "2, 9" } },
    .{ .q = "MATCH (n:A) WITH sum(n.i * 2) AS s RETURN s + 1 AS x", .want = &.{"601"} },
};

// SONNY-2696: beside grouping keys, with ORDER BY and HAVING. A RETURN that
// mixes a key with an aggregate needs its GROUP BY on every path
// (`validateGroupBy`, 42803); a WITH groups implicitly (above).
const nested_grouped = [_]Case{
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) + 1 AS x GROUP BY n.g", .want = &.{ "0, 10", "1, 9", "2, 9" } },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) * 10 + sum(n.i) AS x GROUP BY n.g", .want = &.{ "0, 198", "1, 172", "2, 180" } },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, toString(count(*)) AS x GROUP BY n.g", .want = &.{ "0, '9'", "1, '8'", "2, '8'" } },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, sum(n.i) + 0 AS x GROUP BY n.g ORDER BY x DESC", .want = &.{ "0, 108", "2, 100", "1, 92" }, .ordered = true },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) + 1 AS x GROUP BY n.g HAVING x > 9", .want = &.{"0, 10"} },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) AS c, count(*) + 1 AS x GROUP BY n.g", .want = &.{ "0, 9, 10", "1, 8, 9", "2, 8, 9" } },
    // A grouping key inside the item reads the group's key.
    .{ .q = "MATCH (n:A) RETURN n.g AS g, n.g * 100 + count(*) AS x GROUP BY n.g", .want = &.{ "0, 9", "1, 108", "2, 208" } },
    .{ .q = "MATCH (n:A) WITH n.g AS g, n.g * 100 + count(*) AS x RETURN g, x", .want = &.{ "0, 9", "1, 108", "2, 208" } },
    // Without its GROUP BY, the same refusal as `RETURN n.g, count(*)`.
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) AS x", .err = error.GroupingError },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) + 1 AS x", .err = error.GroupingError },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, toString(count(*)) AS x", .err = error.GroupingError },
};

// ISO/IEC 39075 grouping rules: errors, not answers.
const nested_errors = [_]Case{
    // A non-grouped column beside an aggregate in one item (42803).
    .{ .q = "MATCH (n:A) RETURN n.i + count(*) AS x", .err = error.GroupingError },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, n.i + count(*) AS x GROUP BY n.g", .err = error.GroupingError },
    // An aggregate inside an aggregate (42803).
    .{ .q = "MATCH (n:A) RETURN sum(count(*)) AS x", .err = error.NestedAggregate },
    .{ .q = "MATCH (n:A) RETURN [sum(count(*))] AS x", .err = error.NestedAggregate },
    // Arithmetic on aggregates that overflows (22003), as on a constant.
    .{ .q = "MATCH (n:A) RETURN max(n.i) + 9223372036854775807 AS x", .err = error.IntegerOverflow },
};

// SONNY-2734: computed aggregate arguments, ungrouped.
const computed_arguments = [_]Case{
    .{ .q = "MATCH (n:A) RETURN sum(n.i * $f) AS x", .params = f2, .want = &.{"600"} },
    .{ .q = "MATCH (n:A) RETURN sum(n.i * 2) AS x", .want = &.{"600"} },
    .{ .q = "MATCH (n:A) RETURN count(CASE WHEN n.i > 15 THEN 1 END) AS x", .want = &.{"9"} },
    .{ .q = "MATCH (n:A) RETURN avg(n.i + 1) AS x", .want = &.{"13d"} },
    .{ .q = "MATCH (n:A) RETURN max(n.i * -1) AS hi, min(n.i * -1) AS lo", .want = &.{"0, -24"} },
    .{ .q = "MATCH (n:A) RETURN max(n.i - 100) AS x", .want = &.{"-76"} },
    .{ .q = "MATCH (n:A) RETURN max(n.d) AS hi, min(n.d) AS lo", .want = &.{"2026-01-25, 2026-01-01"} },
    .{ .q = "MATCH (n:A) RETURN max(n.s) AS hi, min(n.s) AS lo", .want = &.{"'9', '0'"} },
    .{ .q = "MATCH (n:A) RETURN collect(n.i + 1) AS x", .sort_lists = true, .want = &.{"[1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 2, 20, 21, 22, 23, 24, 25, 3, 4, 5, 6, 7, 8, 9]"} },
    .{ .q = "MATCH (n:A) RETURN count(DISTINCT n.i % 3) AS x", .want = &.{"3"} },
    .{ .q = "MATCH (n:A) RETURN sum(toInteger(n.s)) AS x", .want = &.{"300"} },
    .{ .q = "MATCH (n:A) RETURN sum(n.i * $f) AS s, count(*) AS c", .params = f2, .want = &.{"600, 25"} },
    // NULL arguments are ignored.
    .{ .q = "MATCH (n:A) RETURN count(n.v * 2) AS c, sum(n.v * 2) AS s", .want = &.{"13, 312"} },
    // Over no rows: count 0, the others NULL.
    .{ .q = "MATCH (n:A) WHERE n.i < 0 RETURN count(n.i * 2) AS c, sum(n.i * 2) AS s, avg(n.i + 1) AS a, min(n.i + 1) AS lo, max(n.i + 1) AS hi", .want = &.{"0, null, null, null, null"} },
    // Grouped, beside a key.
    .{ .q = "MATCH (n:A) RETURN n.g AS g, sum(n.i * 2) AS x GROUP BY n.g", .want = &.{ "0, 216", "1, 184", "2, 200" } },
    // An error inside the argument fails the query (22003), as it would
    // outside an aggregate; it is no skipped row.
    .{ .q = "MATCH (n:A) RETURN sum(9223372036854775807 + n.i) AS x", .err = error.IntegerOverflow },
    .{ .q = "MATCH (n:A) RETURN count(n.i / (n.i - n.i)) AS x", .err = error.DivisionByZero },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, sum(n.i / (n.g - n.g)) AS x GROUP BY n.g", .err = error.DivisionByZero },
};

// Multi-hop, multi-pattern and inline-property shapes the legacy executor
// served with its own aggregate loops (SONNY-3127, SONNY-2688, SONNY-2734's
// disconnected multi-pattern), here because the same routing serves them.
const pattern_shapes = [_]Case{
    .{ .q = "MATCH (a:P)-[:R]->(b:Q)-[:S]->(c:T) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q)-[:S]->(c:T) RETURN count(*) + 1 AS c", .want = &.{"5"} },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q)-[:S]->(c:T) RETURN sum(a.k * 2) AS s", .want = &.{"12"} },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN sum(a.k + b.k) AS s", .want = &.{"12"} },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN toString(count(*)) AS s", .want = &.{"'4'"} },
    .{ .q = "MATCH (a:P), (b:Q) RETURN sum(a.k) AS s, count(*) AS c", .want = &.{"24, 16"} },
    .{ .q = "MATCH (a:P {k: 1})-[:R]->(b:Q) RETURN count(*) AS c", .want = &.{"1"} },
};

// Rows a session may not see contribute to no aggregate: the tenant-scoped
// session's other tenant and the RLS session's hidden rows (i >= 100) would
// change every one of these answers.
const security_cases = [_]Case{
    .{ .q = "MATCH (n:A) RETURN count(*) + 0 AS c, sum(n.i * 2) AS s, max(n.i + 0) AS hi", .want = &.{"25, 600, 24"} },
    .{ .q = "MATCH (n:A) WITH toString(count(*)) AS c RETURN c", .want = &.{"'25'"} },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) + 0 AS c GROUP BY n.g", .want = &.{ "0, 9", "1, 8", "2, 8" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q)-[:S]->(c:T) RETURN sum(c.k + 0) AS s", .want = &.{"6"} },
};

test "SONNY-2696: aggregates inside RETURN items, ungrouped" {
    try inEveryMode("nested ungrouped", &nested_ungrouped);
}

test "SONNY-2696: aggregates inside WITH items" {
    try inEveryMode("nested WITH", &nested_with);
}

test "SONNY-2696: aggregates inside items beside grouping keys" {
    try inEveryMode("nested grouped", &nested_grouped);
}

test "SONNY-2696: grouping errors and errors on aggregates" {
    try inEveryMode("nested errors", &nested_errors);
}

test "SONNY-2734: computed aggregate arguments" {
    try inEveryMode("computed arguments", &computed_arguments);
}

test "SONNY-3127, SONNY-2688: aggregates over multi-hop and multi-pattern matches" {
    try inEveryMode("pattern shapes", &pattern_shapes);
}

test "SONNY-2696, SONNY-2734: hidden rows contribute to no aggregate" {
    try inEveryMode("security", &security_cases);
}
