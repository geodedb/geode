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
//     swallowed as a skipped row;
//   * min and max order every value type: doubles, decimals, dates, and
//     integers mixed with doubles, in the value order ORDER BY uses. Only
//     integers and strings were compared, so otherwise the first value won.
//     The GROUP BY fast path also skipped a double sent as a parameter
//     (stored as an extended value) as not a number, and reported a float
//     extreme for an integer one;
//   * a group key keeps its type: doubles, dates, decimals, texts and lists
//     group by value, 1 and '1' and 'null' and NULL are four groups, and a
//     `|` inside a string does not move a multi-key boundary. Every grouping
//     site, the GROUP BY fast paths included, wrote integers and strings as
//     text, NULL as "null" and anything else as "?", joined with "|";
//   * inside a HAVING aggregate, an alias is the item's expression
//     (`RETURN n.i AS amt ... HAVING sum(amt) > 100`); it was NULL for every
//     row, so every group was dropped;
//   * a HAVING name that is no column, binding or parameter is refused with
//     42703; it was NULL.
// Every check runs in the three legacy sessions and on a persisted deployment
// with no policy or tenant scope (the planned read and the GROUP BY fast
// paths), with the node cache bounded (the default: the fast paths read the
// storage engine) and unbounded (they read the resident nodes). The expected
// rows come from the seed.
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
    /// Persisted, no policy, no tenant: the planned read and the fast paths,
    /// which read the storage engine directly (the node cache is bounded).
    persisted,
    /// The same with an unbounded node cache
    /// (`GEODE_NODE_CACHE_ENTRIES=0`): the fast paths read the resident
    /// nodes instead.
    unbounded_cache,
};

const modes = [_]Mode{ .in_memory, .rls_policy, .tenant_scoped, .persisted, .unbounded_cache };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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
        if (mode == .unbounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
        }
        errdefer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
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
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
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
    ///   * `:L {v}`: the lists [1, 2] (twice), [1, 3] and [2, 1];
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
            for (0..2) |_| try self.exec("CREATE (:L {v: [1, 2]})", &.{});
            try self.exec("CREATE (:L {v: [1, 3]})", &.{});
            try self.exec("CREATE (:L {v: [2, 1]})", &.{});
            try self.exec("CREATE (:M {g2: 'x', d: $v, dt: DATE '2026-03-01', m: 1.5})", &.{.{ .name = "v", .value = .{ .Double = 1.5 } }});
            try self.exec("CREATE (:M {g2: 'x', d: $v, dt: DATE '2026-01-15', m: 0.25})", &.{.{ .name = "v", .value = .{ .Double = 3.25 } }});
            try self.exec("CREATE (:M {g2: 'x', d: 2, dt: DATE '2026-02-01', m: 10.0})", &.{});
            try self.exec("CREATE (:M {g2: 'y', d: 7, dt: DATE '2025-12-31', m: 2.5})", &.{});
            try self.exec("CREATE (:M {g2: 'y', d: $v, dt: DATE '2026-06-30', m: 2.25})", &.{.{ .name = "v", .value = .{ .Double = 7.5 } }});
            try self.exec("CREATE (:Hidden {s: 'h'})", &.{});
            // SONNY-2675 M2: decimals past 16 significant digits, a decimal
            // and a double of the same and of different exact values,
            // durations, zoned times.
            try self.exec("CREATE (:N {g: 'p', v: 1234567890.123456789})", &.{});
            try self.exec("CREATE (:N {g: 'p', v: 1234567890.123456788})", &.{});
            try self.exec("CREATE (:N {g: 'q', v: 0.5})", &.{});
            try self.exec("CREATE (:N {g: 'q', v: $v})", &.{.{ .name = "v", .value = .{ .Double = 0.5 } }});
            try self.exec("CREATE (:N {g: 'r', v: 0.1})", &.{});
            try self.exec("CREATE (:N {g: 'r', v: $v})", &.{.{ .name = "v", .value = .{ .Double = 0.1 } }});
            for ([_][]const u8{ "P1M", "P30D", "P1D", "PT24H" }) |t| {
                try self.exec(try std.fmt.allocPrint(aa, "CREATE (:D {{g: 'd', t: '{s}'}})", .{t}), &.{});
            }
            for ([_][]const u8{ "10:00:00+01:00", "09:00:00+00:00", "11:00:00+00:00" }) |t| {
                try self.exec(try std.fmt.allocPrint(aa, "CREATE (:Z {{g: 'z', t: '{s}'}})", .{t}), &.{});
            }
            // NaN in memory only: the storage engine refuses a non-finite
            // double. Two NaNs of different bit patterns.
            if (self.mode == .in_memory) {
                try self.exec("CREATE (:Q {v: $v})", &.{.{ .name = "v", .value = .{ .Double = std.math.nan(f64) } }});
                try self.exec("CREATE (:Q {v: $v})", &.{.{ .name = "v", .value = .{ .Double = -std.math.nan(f64) } }});
                try self.exec("CREATE (:Q {v: $v})", &.{.{ .name = "v", .value = .{ .Double = @bitCast(@as(u64, 0x7ff8000000000001)) } }});
            }
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
        .List => |items| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(aa, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(aa, ", ");
                try out.appendSlice(aa, try renderCell(aa, item));
            }
            try out.append(aa, ']');
            break :blk try out.toOwnedSlice(aa);
        },
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

fn checkMinMax(s: *Session, f: *Failures) !void {
    // Over the shared projection (a HAVING makes every path group there), and
    // as a plain GROUP BY (on a persisted deployment, the fast path).
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.d) AS hi, min(n.d) AS lo GROUP BY n.g2 HAVING count(*) > 0", &.{}, &.{ "'x', 3.25d, 1.5d", "'y', 7.5d, 7" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.d) AS hi, min(n.d) AS lo GROUP BY n.g2", &.{}, &.{ "'x', 3.25d, 1.5d", "'y', 7.5d, 7" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.dt) AS hi, min(n.dt) AS lo GROUP BY n.g2 HAVING count(*) > 0", &.{}, &.{ "'x', 2026-03-01, 2026-01-15", "'y', 2026-06-30, 2025-12-31" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.m) AS hi, min(n.m) AS lo GROUP BY n.g2 HAVING count(*) > 0", &.{}, &.{ "'x', 10.0m, 0.25m", "'y', 2.5m, 2.25m" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.dt) AS hi, min(n.dt) AS lo GROUP BY n.g2", &.{}, &.{ "'x', 2026-03-01, 2026-01-15", "'y', 2026-06-30, 2025-12-31" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, max(n.m) AS hi, min(n.m) AS lo GROUP BY n.g2", &.{}, &.{ "'x', 10.0m, 0.25m", "'y', 2.5m, 2.25m" });
    // A double sent as a parameter is a number to sum.
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g, sum(n.d) AS t GROUP BY n.g2", &.{}, &.{ "'x', 6.75d", "'y', 14.5d" });
    // In a HAVING-only aggregate.
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g GROUP BY n.g2 HAVING max(n.d) > 5", &.{}, &.{"'y'"});
    try expectRows(s, f, "MATCH (n:M) RETURN n.g2 AS g GROUP BY n.g2 HAVING min(n.dt) < DATE '2026-01-01'", &.{}, &.{"'y'"});
    // Without a GROUP BY, on the persisted deployments (the property
    // aggregate fast path; a date declines to the planned read). The legacy
    // executor's own ungrouped aggregates are not this code.
    if (s.mode == .persisted or s.mode == .unbounded_cache) {
        try expectRows(s, f, "MATCH (n:M) RETURN max(n.d) AS hi", &.{}, &.{"7.5d"});
        try expectRows(s, f, "MATCH (n:M) RETURN min(n.d) AS lo", &.{}, &.{"1.5d"});
        try expectRows(s, f, "MATCH (n:M) RETURN max(n.dt) AS hi", &.{}, &.{"2026-06-30"});
        try expectRows(s, f, "MATCH (n:M) RETURN min(n.m) AS lo", &.{}, &.{"0.25m"});
    }
}

test "SONNY-2675: min and max order doubles, decimals, dates and mixed numbers" {
    try inEveryMode("min/max", checkMinMax);
}

fn checkGroupKeys(s: *Session, f: *Failures) !void {
    const all_k: []const []const u8 = &.{
        "1, 2",     "'1', 1",  "'null', 1",     "null, 2",
        "1.5d, 2",  "2.5d, 1", "2026-01-01, 2", "2026-01-02, 1",
        "1.25m, 1", "'t1', 1", "'t2', 1",
    };
    try expectRows(s, f, "MATCH (n:K) RETURN n.k AS k, count(*) AS c GROUP BY n.k", &.{}, all_k);
    try expectRows(s, f, "MATCH (n:K) RETURN n.k AS k, count(*) AS c GROUP BY n.k HAVING count(*) > 0", &.{}, all_k);
    try expectRows(s, f, "MATCH (n:K) WITH n.k AS k, count(*) AS c GROUP BY n.k RETURN k, c", &.{}, all_k);
    // A `|` inside a key does not move the boundary between two keys.
    try expectRows(s, f, "MATCH (n:P) RETURN n.a AS a, n.b AS b, count(*) AS c GROUP BY n.a, n.b", &.{}, &.{ "'a|b', 'c', 1", "'a', 'b|c', 1" });
    try expectRows(s, f, "MATCH (n:P) RETURN n.a AS a, n.b AS b, count(*) AS c GROUP BY n.a, n.b HAVING count(*) > 0", &.{}, &.{ "'a|b', 'c', 1", "'a', 'b|c', 1" });
    // A list groups element by element, in order.
    try expectRows(s, f, "MATCH (n:L) RETURN n.v AS v, count(*) AS c GROUP BY n.v", &.{}, &.{ "[1, 2], 2", "[1, 3], 1", "[2, 1], 1" });
}

test "SONNY-2675: a group key keeps its type" {
    try inEveryMode("group keys", checkGroupKeys);
}

fn checkAliasInAggregate(s: *Session, f: *Failures) !void {
    // An alias inside an aggregate names the item's expression, per row.
    try expectRowsN(s, f, "MATCH (n:G) RETURN n.g AS k, n.i AS amt GROUP BY n.g HAVING sum(amt) > 100", &.{}, 1, &.{ "'b'", "'c'" });
    try expectRowsN(s, f, "MATCH (n:G) WITH n.g AS k, n.i AS amt GROUP BY n.g HAVING sum(amt) > 100 RETURN k", &.{}, 1, &.{ "'b'", "'c'" });
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS k, count(*) AS c GROUP BY n.g HAVING count(DISTINCT k) = 1", &.{}, &.{ "'a', 10", "'b', 10", "'c', 5" });
    // An alias of an aggregate inside an aggregate nests them.
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS k, count(*) AS c GROUP BY n.g HAVING sum(c) > 1", &.{}, error.NestedAggregate);
}

test "SONNY-2675: an alias inside a HAVING aggregate names the item's expression" {
    try inEveryMode("alias in aggregate", checkAliasInAggregate);
}

fn checkUnknownNames(s: *Session, f: *Failures) !void {
    const lim: []const Param = &.{.{ .name = "lim", .value = .{ .Int = 7 } }};
    // A parameter, named with or without its `$`.
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING count(*) > lim", lim, &.{ "'a', 10", "'b', 10" });
    try expectRows(s, f, "MATCH (n:G) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING count(*) > $lim", lim, &.{ "'a', 10", "'b', 10" });
    // Anything else is refused: over groups, inside an aggregate, per row.
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING nosuchalias > 2", &.{}, error.UnknownHavingReference);
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING nosuchalias IS NULL", &.{}, error.UnknownHavingReference);
    try expectFail(s, f, "MATCH (n:G) RETURN n.g AS g GROUP BY n.g HAVING sum(nosuch) > 1", &.{}, error.UnknownHavingReference);
    try expectFail(s, f, "MATCH (n:G) RETURN n.i AS i WHERE nosuch > 1", &.{}, error.UnknownHavingReference);
    try expectFail(s, f, "MATCH (n:G) RETURN n.i AS i WHERE nosuch.x > 1", &.{}, error.UnknownHavingReference);
}

test "SONNY-2675: a HAVING name that is no column, binding or parameter is refused" {
    try inEveryMode("unknown names", checkUnknownNames);
}

test "SONNY-2675: a grouping error reaches the client as SQLSTATE 42803" {
    // A mixed RETURN without a GROUP BY, like every other grouping refusal.
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.GroupingError).code);
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.NestedAggregate).code);
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.UngroupedHavingReference).code);
}

fn checkExactKeys(s: *Session, f: *Failures) !void {
    // Decimals past 16 significant digits are two values (they went through
    // f64 and merged), under GROUP BY, count(DISTINCT) and a HAVING.
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'p' RETURN count(*) AS c GROUP BY n.v", &.{}, &.{ "1", "1" });
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'p' RETURN count(*) AS c GROUP BY n.v HAVING count(*) > 0", &.{}, &.{ "1", "1" });
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'p' RETURN count(DISTINCT n.v) AS c", &.{}, &.{"2"});
    // DECIMAL 0.5 and DOUBLE 0.5 are one value; DECIMAL 0.1 and DOUBLE 0.1
    // (0.1000000000000000055...) are two, for keys, min and max alike.
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'q' RETURN count(*) AS c GROUP BY n.v", &.{}, &.{"2"});
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'r' RETURN count(*) AS c GROUP BY n.v", &.{}, &.{ "1", "1" });
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'r' RETURN count(DISTINCT n.v) AS c", &.{}, &.{"2"});
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'r' RETURN n.g AS g, max(n.v) AS hi, min(n.v) AS lo GROUP BY n.g", &.{}, &.{"'r', 0.1d, 0.1m"});
    try expectRows(s, f, "MATCH (n:N) WHERE n.g = 'r' RETURN n.g AS g, max(n.v) AS hi, min(n.v) AS lo GROUP BY n.g HAVING count(*) > 0", &.{}, &.{"'r', 0.1d, 0.1m"});
    // A month is not 30 days; a day is 24 hours. (Grouped with a HAVING:
    // the legacy executor's own ungrouped aggregates do not evaluate a
    // computed argument, SONNY-2734.)
    try expectRows(s, f, "MATCH (n:D) RETURN n.g AS g, count(DISTINCT duration(n.t)) AS c GROUP BY n.g HAVING count(*) > 0", &.{}, &.{"'d', 3"});
    // A time with a time zone is its UTC time: 10:00+01:00 is 09:00+00:00.
    try expectRows(s, f, "MATCH (n:Z) RETURN n.g AS g, count(DISTINCT timetz(n.t)) AS c GROUP BY n.g HAVING count(*) > 0", &.{}, &.{"'z', 2"});
    // Every NaN is one value.
    if (s.mode == .in_memory) {
        try expectRows(s, f, "MATCH (n:Q) RETURN count(DISTINCT n.v) AS c", &.{}, &.{"1"});
        try expectRows(s, f, "MATCH (n:Q) RETURN count(*) AS c GROUP BY n.v", &.{}, &.{"3"});
    }
}

test "SONNY-2675: group and DISTINCT keys agree with the value order" {
    try inEveryMode("exact keys", checkExactKeys);
}

// The comparator and the keys, unit by unit (value_order.zig).
const value_order = geode.value_order;

fn dec(c: i128, sc: u8) value_order.Number {
    return .{ .exact = .{ .coeff = c, .scale = sc } };
}

fn dbl(x: f64) value_order.Number {
    var y = x;
    _ = &y;
    return .{ .float = y };
}

test "SONNY-2675: numbers compare by their exact value" {
    const cmp = value_order.compareNumbers;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectEqual(@as(i8, 0), cmp(dec(5, 1), dbl(0.5)));
    try testing.expectEqual(@as(i8, -1), cmp(dec(1, 1), dbl(0.1)));
    try testing.expectEqual(@as(i8, 1), cmp(dbl(0.1), dec(1, 1)));
    try testing.expectEqual(@as(i8, 0), cmp(dec(9223372036854775808, 0), dbl(0x1p63)));
    try testing.expectEqual(@as(i8, -1), cmp(dec(9223372036854775807, 0), dbl(0x1p63)));
    try testing.expectEqual(@as(i8, 1), cmp(dec(100000000000000000001, 0), dbl(1e20)));
    try testing.expectEqual(@as(i8, 0), cmp(dec(100000000000000000000, 0), dbl(1e20)));
    try testing.expectEqual(@as(i8, -1), cmp(dbl(-0.0), dec(1, 255)));
    try testing.expectEqual(@as(i8, 0), cmp(dbl(-0.0), dec(0, 3)));
    try testing.expectEqual(@as(i8, 1), cmp(dbl(nan), dec(1, 0)));
    try testing.expectEqual(@as(i8, 0), cmp(dbl(nan), dbl(-nan)));
    try testing.expectEqual(@as(i8, -1), cmp(dbl(-inf), dec(std.math.minInt(i128), 0)));
    try testing.expectEqual(@as(i8, 1), cmp(dbl(inf), dec(std.math.maxInt(i128), 0)));
    // Decimals whose common scale overflows i128.
    try testing.expectEqual(@as(i8, 1), cmp(dec(std.math.maxInt(i128), 0), dec(1, 200)));
    try testing.expectEqual(@as(i8, 0), cmp(dec(12345, 2), dec(123450000000000000000000000000000000000, 36)));
    try testing.expectEqual(@as(i8, 1), cmp(dec(99999, 0), dec(123450000000000000000000000000000000000, 34)));
    try testing.expectEqual(@as(i8, -1), cmp(dec(-99999, 0), dec(-123450000000000000000000000000000000000, 34)));
    try testing.expectEqual(@as(i8, -1), cmp(dec(12344, 0), dec(123450000000000000000000000000000000000, 34)));
    // Past 16 significant digits.
    try testing.expectEqual(@as(i8, 1), cmp(dec(1234567890123456789, 9), dec(1234567890123456788, 9)));
    // Subnormal and huge doubles against a decimal.
    try testing.expectEqual(@as(i8, -1), cmp(dbl(4.9e-324), dec(1, 255)));
    try testing.expectEqual(@as(i8, 1), cmp(dbl(1e300), dec(std.math.maxInt(i128), 0)));
    try testing.expectEqual(@as(i8, -1), cmp(dbl(-1e300), dec(std.math.minInt(i128), 0)));
}

fn numberKey(buf: []u8, n: value_order.Number) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try value_order.writeNumberKey(&w, n);
    return w.buffered();
}

test "SONNY-2675: two numbers share a key exactly when they compare equal" {
    const nums = [_]value_order.Number{
        dec(5, 1),                     dbl(0.5),
        dec(1, 1),                     dbl(0.1),
        dec(10, 1),                    dbl(1.0),
        dec(1, 0),                     dbl(-0.0),
        dec(0, 5),                     dbl(std.math.nan(f64)),
        dbl(-std.math.nan(f64)),       dbl(@bitCast(@as(u64, 0x7ff8000000000001))),
        dbl(std.math.inf(f64)),        dbl(-std.math.inf(f64)),
        dbl(0x1p63),                   dec(92233720368547758080, 1),
        dbl(-0x1p63),                  dec(std.math.minInt(i64), 0),
        dbl(1e20),                     dec(100000000000000000000, 0),
        dec(100000000000000000001, 0), dec(1000000000000000000010, 1),
        dec(1234567890123456789, 18),  dec(1234567890123456788, 18),
        dbl(0x1p-54),                  dec(55511151231257827021181583404541015625, 54),
        dbl(0x1.fffffffffffffp62),     dec(9223372036854774784, 0),
    };
    var ba: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    for (nums) |a| {
        for (nums) |b| {
            const same_key = std.mem.eql(u8, try numberKey(&ba, a), try numberKey(&bb, b));
            const equal = value_order.compareNumbers(a, b) == 0;
            if (same_key != equal) {
                std.debug.print("key and order disagree: {any} vs {any}: same key {}, equal {}\n", .{ a, b, same_key, equal });
                return error.KeyOrderMismatch;
            }
        }
    }
}

test "SONNY-2675: a month is not 30 days, a day is 24 hours" {
    const Interval = @FieldType(Value, "Interval");
    const month: Interval = .{ .months = 1, .days = 0, .micros = 0 };
    const thirty_days: Interval = .{ .months = 0, .days = 30, .micros = 0 };
    const day: Interval = .{ .months = 0, .days = 1, .micros = 0 };
    const hours24: Interval = .{ .months = 0, .days = 0, .micros = 24 * std.time.us_per_hour };
    try testing.expect(value_order.compareIntervals(month, thirty_days) != 0);
    try testing.expectEqual(@as(i8, 1), value_order.compareIntervals(month, .{ .months = 0, .days = 400, .micros = 0 }));
    try testing.expectEqual(@as(i8, 0), value_order.compareIntervals(day, hours24));
    try testing.expectEqual(@as(i8, -1), value_order.compareIntervals(hours24, .{ .months = 0, .days = 1, .micros = 1 }));
}
