// SONNY-2769: integer overflow and narrowing no longer abort the server.
//
// Integer overflow, a narrowing `@intCast` that does not fit, `@rem` or
// `@divTrunc` of minInt by -1, and `std.math.pow` past its type (it unwraps
// the overflow with `catch unreachable`) are safety-checked: they abort a Debug
// or ReleaseSafe process, the server with every session on it. A read-only
// user reached them with a literal, a parameter or a stored value: decimal
// `*` and `/`, unary minus and `abs()` of minInt(i64), date arithmetic, a
// timestamp before 1970 in a result, CAST to DECIMAL, casts of function and
// procedure arguments, parameter decoders. Each case aborted a ReleaseSafe
// build before the fix (the round-4 report has the probe runs); a value that
// does not fit is refused with a typed error (22003) now.
//
// CANARY: REQ=REQ-SONNY-2769-INTEGER-OVERFLOW; FEATURE="IntegerOverflow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2769_integer_overflow.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const min_int = "(-9223372036854775807 - 1)";

/// Which executor serves the session's reads.
const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, with an RLS policy: the legacy executor.
    rls_policy,
    /// Persisted, tenant-scoped: the legacy executor and the tenant-filtered
    /// fast paths.
    tenant_scoped,
    /// Persisted, no policy, no tenant: the planned read and the fast paths,
    /// which read the storage engine directly (the node cache is bounded).
    persisted,
    /// The same with an unbounded node cache (`GEODE_NODE_CACHE_ENTRIES=0`):
    /// the fast paths read the resident nodes instead.
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
        var ctx: execution.ExecutionContext = .{ .catalog = catalog };
        if (mode == .tenant_scoped) ctx.tenant_id = "tenant_a";
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = ctx };
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
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var r = try self.run(query, params);
        r.deinit(self.arena.allocator());
    }

    fn double(self: *Session, query: []const u8, v: f64) !void {
        try self.exec(query, &.{.{ .name = "v", .value = .{ .Double = v } }});
    }

    /// Nodes :T with integer x at the i64 boundary, and :U; a tenant-scoped
    /// session also gets a decoy in another tenant; an RLS session a hidden
    /// node.
    fn seed(self: *Session) !void {
        if (self.mode == .tenant_scoped) {
            self.ctx.tenant_id = "tenant_b";
            try self.exec("CREATE (:T {x: 5, g: 1})", &.{});
            self.ctx.tenant_id = "tenant_a";
        }
        try self.exec("CREATE (:T {x: 9223372036854775807, g: 1})", &.{});
        try self.exec("CREATE (:T {x: 1, g: 1})", &.{});
        try self.exec("CREATE (:U {y: 1})", &.{});
        if (self.mode == .rls_policy) {
            try self.exec("CREATE (:Hidden:T {x: 1, g: 1})", &.{});
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
/// `1.25m` for a decimal, `null`.
fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    var buf: [64]u8 = undefined;
    return switch (cell) {
        .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| if (@abs(d) >= 1e21)
            try std.fmt.allocPrint(aa, "{e}d", .{d})
        else
            try std.fmt.allocPrint(aa, "{d}d", .{d}),
        .Decimal => try std.fmt.allocPrint(aa, "{s}m", .{try geode.value_types.stringify(cell, &buf)}),
        .Date, .Timestamp, .Time, .TimestampTZ => try aa.dupe(u8, try geode.value_types.stringify(cell, &buf)),
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

fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row, 0..) |cell, c| {
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
        return error.OverflowWrong;
    }
};

/// `query` returns exactly `want` (rows rendered by `renderRow`, in any order).
fn expectRows(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, params) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    // Encode every cell as the server's response does (the response encoder
    // formats dates, times and decimals).
    for (result.rows) |row| {
        for (row) |cell| _ = try geode.proto_util.valueToProto(aa, cell);
    }
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = try renderRow(aa, row);
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

/// `query` returns the single cell `want`.
fn expectValue(s: *Session, f: *Failures, query: []const u8, want: []const u8) !void {
    return expectRows(s, f, query, &.{}, &.{want});
}

/// `query` fails with `want`.
fn expectFail(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: anyerror) !void {
    const aa = s.arena.allocator();
    if (s.run(query, params)) |ok| {
        var result = ok;
        defer result.deinit(aa);
        const first = if (result.rows.len > 0) try renderRow(aa, result.rows[0]) else "";
        try f.add("[{s}] {s}: expected error {s}, got {d} rows {{{s}}}", .{ @tagName(s.mode), query, @errorName(want), result.rows.len, first });
    } else |err| {
        if (err != want) try f.add("[{s}] {s}: expected error {s}, got {s}", .{ @tagName(s.mode), query, @errorName(want), @errorName(err) });
    }
}

/// Run `checks` in a fresh, seeded session of each of `which`.
fn inModes(name: []const u8, which: []const Mode, comptime checks: fn (*Session, *Failures) anyerror!void) !void {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (which) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.seed();
        try checks(&s, &f);
    }
    try f.check(name);
}

/// The evaluator checks do not depend on the executor; they run on a legacy
/// session and on the planned read.
const eval_modes = [_]Mode{ .in_memory, .persisted };

// ---------------------------------------------------------------------------
// Arithmetic operators
// ---------------------------------------------------------------------------

/// 0.000...01 with 201 fraction digits: a product of two has 402.
const scale201 = "0." ++ "0" ** 200 ++ "1";

fn checkArithmetic(s: *Session, f: *Failures) !void {
    // Decimal *: the coefficient and the scale.
    try expectFail(s, f, "RETURN 10000000000000000000.0 * 10000000000000000000.0 AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN " ++ scale201 ++ " * " ++ scale201 ++ " AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN 10.0 * 2.5 AS x", "25.00m");
    try expectValue(s, f, "RETURN -1.5 * 2 AS x", "-3.0m");
    // Decimal /: the scaled numerator.
    try expectFail(s, f, "RETURN 1000000000000000000000000000000000.0 / 3 AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN 1.0 / 4 AS x", "0.2500000m");
    // Decimal + and -.
    try expectFail(s, f, "RETURN 1.5e38 + 1.5e38 AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN -1.5e38 - 1.5e38 AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN 1.5 + 2.25 AS x", "3.75m");
    try expectValue(s, f, "RETURN 1.5 - 2.25 AS x", "-0.75m");
    // Integer /, % and unary minus at minInt.
    try expectFail(s, f, "RETURN " ++ min_int ++ " / -1 AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN -" ++ min_int ++ " AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN " ++ min_int ++ " % -1 AS x", "0");
    try expectValue(s, f, "RETURN 7 % -1 AS x", "0");
    try expectValue(s, f, "RETURN -7 % 2 AS x", "-1");
    try expectValue(s, f, "RETURN " ++ min_int ++ " / 1 AS x", "-9223372036854775808");
    try expectValue(s, f, "RETURN -9223372036854775807 AS x", "-9223372036854775807");
    try expectValue(s, f, "RETURN -(1.5) AS x", "-1.5m");
    // A boolean coerced into an integer sum.
    try expectFail(s, f, "RETURN true + 9223372036854775807 AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN 9223372036854775807 + true AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN 9223372036854775806 + true AS x", "9223372036854775807");
}

test "SONNY-2769: arithmetic past i64 or the decimal is 22003" {
    try inModes("arithmetic", &eval_modes, checkArithmetic);
}

// ---------------------------------------------------------------------------
// Dates, times and timestamps
// ---------------------------------------------------------------------------

fn checkTemporal(s: *Session, f: *Failures) !void {
    // Date +/- interval past the day range.
    try expectFail(s, f, "RETURN DATE '2026-01-01' + duration('P2147483647D') AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN DATE '2026-01-01' + duration('P2147483647M') AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN DATE '2026-01-01' + duration('P100000000Y') AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN DATE '1000-01-01' - duration('P2147483647D') AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN DATE '2026-01-01' - duration('P2147483647M') AS x", &.{}, error.IntegerOverflow);
    // In range, and unchanged: the day clamps to the target month.
    try expectValue(s, f, "RETURN DATE '2026-01-31' + duration('P1M') AS x", "2026-02-28");
    try expectValue(s, f, "RETURN duration('P1M') + DATE '2026-01-31' AS x", "2026-02-28");
    try expectValue(s, f, "RETURN DATE '2026-03-31' - duration('P1M') AS x", "2026-02-28");
    try expectValue(s, f, "RETURN DATE '2024-02-29' + duration('P1Y') AS x", "2025-02-28");
    try expectValue(s, f, "RETURN DATE '2026-01-01' + duration('P1000000Y2D') AS x", "1002026-01-03");
    // Before year 1 (astronomical numbering: year 0 is 1 BCE), and before
    // 1970, in a result (the response encoder).
    try expectValue(s, f, "RETURN DATE '0001-01-01' - duration('P2Y') AS x", "-0001-01-01");
    try expectValue(s, f, "RETURN timestamp('1969-12-31T23:00:00') AS x", "1969-12-31T23:00:00");
    try expectValue(s, f, "RETURN timestamp('1900-01-01T00:00:00.5') AS x", "1900-01-01T00:00:00.500000");
    try expectValue(s, f, "RETURN timestamptz('1969-12-31T23:00:00Z') AS x", "1969-12-31T23:00:00Z");
    // A TIME literal with more fraction digits than a nanosecond keeps nine.
    try expectValue(s, f, "RETURN TIME '10:00:00." ++ "1" ** 300 ++ "' AS x", "10:00:00.111111");
}

test "SONNY-2769: date arithmetic and pre-1970 timestamps do not abort" {
    try inModes("temporal", &eval_modes, checkTemporal);
}

test "SONNY-2769: the response encoder formats every date and decimal" {
    const datetime = geode.types.datetime;
    const a = testing.allocator;
    // The encoder's own formatting, for the values the queries above build.
    const d = datetime.Date{ .days_since_epoch = try datetime.Date.daysSinceEpoch(-1, 1, 1) };
    const d_text = try d.toString(a);
    defer a.free(d_text);
    try testing.expectEqualStrings("-0001-01-01", d_text);
    const ts = datetime.Timestamp{ .micros_since_epoch = -3600 * 1_000_000 };
    const ts_text = try ts.toString(a);
    defer a.free(ts_text);
    try testing.expectEqualStrings("1969-12-31T23:00:00", ts_text);
    const t = datetime.Time{ .micros_since_midnight = -1_000_000 };
    const t_text = try t.toString(a);
    defer a.free(t_text);
    try testing.expectEqualStrings("23:59:59", t_text);
    // The last representable day counts, both ways.
    try testing.expectError(error.Overflow, datetime.Date.daysSinceEpoch(std.math.maxInt(i32), 1, 1));
    const far = datetime.Date.dateFromDays(std.math.minInt(i32));
    try testing.expect(far.year < -5_000_000);
    // A decimal coefficient of minInt(i128) (`-coeff` overflowed).
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try geode.proto_util.valueToProto(arena.allocator(), .{ .Decimal = .{ .coeff = std.math.minInt(i128), .scale = 1 } });
    try testing.expectEqualStrings("-17014118346046923173168730371588410572.8", v.kind.?.decimal_val.orig_repr);
}

test "SONNY-2769: a zoned time at the i64 edge orders and keys without overflow" {
    // Round-3 helper audit: the UTC time of day was i64 arithmetic
    // (micros - offset * 10^6), which overflowed for a decoded time of day at
    // the edge of i64.
    const edge = Value{ .TimeTZ = .{ .time = .{ .micros_since_midnight = std.math.minInt(i64) }, .offset_seconds = 14 * 3600 } };
    const other = Value{ .TimeTZ = .{ .time = .{ .micros_since_midnight = std.math.maxInt(i64) }, .offset_seconds = -14 * 3600 } };
    try testing.expect(geode.value_order.timeTzUtcMicros(edge.TimeTZ) < geode.value_order.timeTzUtcMicros(other.TimeTZ));
    var set = geode.execution.distinct_set.DistinctSet.init(testing.allocator);
    defer set.deinit();
    try testing.expect(try set.add(edge));
    try testing.expect(try set.add(other));
    try testing.expect(!try set.add(edge));
}
