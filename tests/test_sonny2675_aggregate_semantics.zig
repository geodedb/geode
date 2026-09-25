// SONNY-2675 follow-up: the shared aggregate code every GROUP BY ... HAVING
// now relies on.
//
// Once a grouped HAVING computes its own aggregates (SONNY-2675), every
// grouped query leans on the shared aggregate code (`computeGroupAggregation`)
// and its group keys:
//   * query parameters reach an aggregate's argument, as they reach every
//     other expression: `sum(n.i * $f)`, `count(CASE WHEN n.i > $t ...)`. The
//     argument was evaluated without them, so `$f` was NULL; and a positional
//     `$2` that was not supplied, an error anywhere else (GAP-0926), was
//     swallowed as a skipped row.
// Every check runs in the three legacy sessions and on a persisted deployment
// with no policy or tenant scope (the planned read and the GROUP BY fast
// paths). The expected rows come from the seed.
//
// CANARY: REQ=REQ-SONNY-2675-AGGREGATE-SEMANTICS; FEATURE="GroupedAggregates"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

/// Which executor serves the session's reads.
const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, with an RLS policy: the legacy executor.
    rls_policy,
    /// Persisted, tenant-scoped: the legacy executor.
    tenant_scoped,
    /// Persisted, no policy, no tenant: the planned read and the fast paths.
    persisted,
};

const modes = [_]Mode{ .in_memory, .rls_policy, .tenant_scoped, .persisted };

const Param = struct { name: []const u8, value: Value };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        const persisted = mode != .in_memory;
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
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
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    fn run(self: *Session, query: []const u8, params: []const Param) !execution.ExecutionResult {
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
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn exec(self: *Session, query: []const u8, params: []const Param) !void {
        var r = try self.run(query, params);
        r.deinit(self.arena.allocator());
    }

    /// 25 `:G {i, g}` nodes (g = 'a' for i = 0..9, 'b' for 10..19, 'c' for
    /// 20..24: count 10/10/5, sum(i) 45/145/110), then the typed data:
    ///   * `:K {k}`: k = 1 (twice), '1', 'null', absent (twice), the doubles
    ///     1.5 (twice) and 2.5, the dates 2026-01-01 (twice) and 2026-01-02,
    ///     the decimal 1.25, and the texts 't1' and 't2';
    ///   * `:P {a, b}`: ('a|b', 'c') and ('a', 'b|c');
    ///   * `:M {g2, d, dt, m}`: group x has d = 1.5, 3.25 (doubles) and 2,
    ///     dt = 2026-03-01, 2026-01-15, 2026-02-01, m = 1.5, 0.25, 10.0;
    ///     group y has d = 7 and 7.5 (a double), dt = 2025-12-31, 2026-06-30,
    ///     m = 2.5, 2.25.
    /// A tenant-scoped session also has another tenant's copies of `:G`, `:K`
    /// and `:M` nodes it must not see; an RLS session has a policy on another
    /// label, so the legacy executor serves it.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        if (self.mode == .tenant_scoped) {
            self.ctx.tenant_id = "tenant_b";
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..5) |j| try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a'}})", .{100 + j}), &.{});
            try self.exec("CREATE (:K {k: 1})", &.{});
            try self.exec("CREATE (:K {k: $v})", &.{.{ .name = "v", .value = .{ .Double = 1.5 } }});
            try self.exec("CREATE (:M {g2: 'x', d: $v, dt: DATE '2030-01-01', m: 99.5})", &.{.{ .name = "v", .value = .{ .Double = 99.5 } }});
            self.ctx.tenant_id = "tenant_a";
        }
        {
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..25) |i| {
                const g: []const u8 = if (i < 10) "a" else if (i < 20) "b" else "c";
                try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}'}})", .{ i, g }), &.{});
            }
            for (0..2) |_| try self.exec("CREATE (:K {k: 1})", &.{});
            try self.exec("CREATE (:K {k: '1'})", &.{});
            try self.exec("CREATE (:K {k: 'null'})", &.{});
            for (0..2) |_| try self.exec("CREATE (:K {z: 0})", &.{});
            for (0..2) |_| try self.exec("CREATE (:K {k: $v})", &.{.{ .name = "v", .value = .{ .Double = 1.5 } }});
            try self.exec("CREATE (:K {k: $v})", &.{.{ .name = "v", .value = .{ .Double = 2.5 } }});
            for (0..2) |_| try self.exec("CREATE (:K {k: DATE '2026-01-01'})", &.{});
            try self.exec("CREATE (:K {k: DATE '2026-01-02'})", &.{});
            try self.exec("CREATE (:K {k: 1.25})", &.{});
            try self.exec("CREATE (:K {k: $v})", &.{.{ .name = "v", .value = .{ .Text = "t1" } }});
            try self.exec("CREATE (:K {k: $v})", &.{.{ .name = "v", .value = .{ .Text = "t2" } }});
            try self.exec("CREATE (:P {a: 'a|b', b: 'c'})", &.{});
            try self.exec("CREATE (:P {a: 'a', b: 'b|c'})", &.{});
            try self.exec("CREATE (:M {g2: 'x', d: $v, dt: DATE '2026-03-01', m: 1.5})", &.{.{ .name = "v", .value = .{ .Double = 1.5 } }});
            try self.exec("CREATE (:M {g2: 'x', d: $v, dt: DATE '2026-01-15', m: 0.25})", &.{.{ .name = "v", .value = .{ .Double = 3.25 } }});
            try self.exec("CREATE (:M {g2: 'x', d: 2, dt: DATE '2026-02-01', m: 10.0})", &.{});
            try self.exec("CREATE (:M {g2: 'y', d: 7, dt: DATE '2025-12-31', m: 2.5})", &.{});
            try self.exec("CREATE (:M {g2: 'y', d: $v, dt: DATE '2026-06-30', m: 2.25})", &.{.{ .name = "v", .value = .{ .Double = 7.5 } }});
            try self.exec("CREATE (:Hidden {s: 'h'})", &.{});
        }
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

/// A cell, with its type visible: 'text' for a string, `1.5d` for a double,
/// `1.25m` for a decimal, an ISO date, `null`.
fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    var buf: [64]u8 = undefined;
    return switch (cell) {
        .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Text => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| try std.fmt.allocPrint(aa, "{d}d", .{d}),
        .Decimal => try std.fmt.allocPrint(aa, "{s}m", .{try geode.value_types.stringify(cell, &buf)}),
        .Date => try aa.dupe(u8, try geode.value_types.stringify(cell, &buf)),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

fn renderRow(aa: std.mem.Allocator, row: []const Value, columns: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row[0..@min(columns, row.len)], 0..) |cell, c| {
        if (c > 0) try out.appendSlice(aa, ", ");
        try out.appendSlice(aa, try renderCell(aa, cell));
    }
    return out.toOwnedSlice(aa);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

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
        return error.AggregateSemanticsWrong;
    }
};

/// `query` returns exactly `want` (rows rendered by `renderRow`, in any
/// order), comparing the first `columns` columns.
fn expectRowsN(s: *Session, f: *Failures, query: []const u8, params: []const Param, columns: usize, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, params) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = try renderRow(aa, row, columns);
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        const want_text = try std.mem.join(aa, " | ", exp);
        const got_text = try std.mem.join(aa, " | ", got);
        try f.add("[{s}] {s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ @tagName(s.mode), query, exp.len, want_text, got.len, got_text });
    }
}

fn expectRows(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const []const u8) !void {
    return expectRowsN(s, f, query, params, std.math.maxInt(usize), want);
}

/// `query` fails with `want`.
fn expectFail(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: anyerror) !void {
    const aa = s.arena.allocator();
    if (s.run(query, params)) |ok| {
        var result = ok;
        try f.add("[{s}] {s}: expected error {s}, got {d} rows", .{ @tagName(s.mode), query, @errorName(want), result.rows.len });
        result.deinit(aa);
    } else |err| {
        if (err != want) try f.add("[{s}] {s}: expected error {s}, got {s}", .{ @tagName(s.mode), query, @errorName(want), @errorName(err) });
    }
}

/// Run `checks` in a fresh, seeded session of every mode.
fn inEveryMode(name: []const u8, comptime checks: fn (*Session, *Failures) anyerror!void) !void {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.seed();
        try checks(&s, &f);
    }
    try f.check(name);
}

fn checkParameters(s: *Session, f: *Failures) !void {
    const t: []const Param = &.{.{ .name = "t", .value = .{ .Int = 15 } }};
    const two: []const Param = &.{.{ .name = "f", .value = .{ .Int = 2 } }};
    const positional: []const Param = &.{.{ .name = "1", .value = .{ .Int = 2 } }};
    // In a HAVING-only aggregate: i > 15 in b (16..19) and c (20..24).
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING count(CASE WHEN n.i > $t THEN 1 END) > 2", t, &.{ "'b', 10", "'c', 5" });
    // In projected aggregates, at the RETURN and at a WITH.
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS g, sum(n.i * $f) AS s GROUP BY n.g", two, &.{ "'a', 90", "'b', 290", "'c', 220" });
    try expectRows(s, f, "MATCH (n:G) WITH n.g AS k, sum(n.i * $f) AS s GROUP BY n.g RETURN k, s", two, &.{ "'a', 90", "'b', 290", "'c', 220" });
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS g, sum(n.i * $1) AS s GROUP BY n.g HAVING sum(n.i * $1) > 250", positional, &.{"'b', 290"});
    // A positional parameter that was not supplied is an error, inside an
    // aggregate as anywhere else (GAP-0926).
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS g, sum(n.i * $2) AS s GROUP BY n.g", positional, error.MissingParameter);
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS g GROUP BY n.g HAVING count(CASE WHEN n.i > $2 THEN 1 END) > 2", positional, error.MissingParameter);
}

test "SONNY-2675: query parameters reach grouped aggregates" {
    try inEveryMode("parameters", checkParameters);
}
