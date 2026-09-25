// SONNY-2739: a float or a decimal narrowed to an integer no longer aborts
// the server.
//
// `@intFromFloat` of an infinity or of a value whose integer part does not fit
// the target, and `@intCast` of an integer that does not fit, are
// safety-checked: they abort a Debug or ReleaseSafe process, the server with
// every session on it. NaN slips past the check and yields a garbage integer.
// A read-only user reached these conversions with a literal, a parameter or a
// stored value:
//   * a GROUP BY or DISTINCT key of 2^63 (`count(DISTINCT
//     9223372036854775808.0)`): the key guard compared with
//     `@floatFromInt(maxInt(i64))`, which rounds up to 2^63 and so admits it;
//   * the power operator: `2 ^ 63` passed the same guard, and `10 ^ 40`,
//     `10 ^ 400` and `0 ^ -1` went into a Decimal coefficient unguarded.
// Every such conversion is checked now: a value that does not fit is refused
// with a typed error (22003), and every boundary below is tested at +-2^63 and
// +-2^127, NaN and the infinities. Each case aborted a ReleaseSafe build before
// the fix (the round-3 report has the probe runs).
//
// The GROUP BY and DISTINCT checks run in the three legacy sessions and on
// the persisted deployments (the planned read and the GROUP BY fast paths),
// with the node cache bounded and unbounded.
//
// CANARY: REQ=REQ-SONNY-2739-FLOAT-NARROWING; FEATURE="NumericNarrowing"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2739_float_narrowing.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;
const narrowing = geode.types.narrowing;

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

const two63: f64 = 0x1p63;

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

    /// Nodes :F whose x is at the i64 boundary, as a decimal, a double and an
    /// integer; in memory also NaN and the infinities (the storage engine
    /// refuses a non-finite double: FloatNaN). A tenant-scoped session also
    /// gets decoys in another tenant; an RLS session a hidden node.
    fn seed(self: *Session) !void {
        if (self.mode == .tenant_scoped) {
            self.ctx.tenant_id = "tenant_b";
            try self.exec("CREATE (:F {x: 9223372036854775808.0})", &.{});
            try self.exec("CREATE (:F {x: 5})", &.{});
            self.ctx.tenant_id = "tenant_a";
        }
        // 2^63 twice: a decimal and a double.
        try self.exec("CREATE (:F {x: 9223372036854775808.0})", &.{});
        try self.double("CREATE (:F {x: $v})", two63);
        // -2^63 three times: a decimal, a double and an integer.
        try self.exec("CREATE (:F {x: -9223372036854775808.0})", &.{});
        try self.double("CREATE (:F {x: $v})", -two63);
        try self.exec("CREATE (:F {x: $v})", &.{.{ .name = "v", .value = .{ .Int = std.math.minInt(i64) } }});
        try self.exec("CREATE (:F {x: 9223372036854775807})", &.{});
        if (self.mode == .in_memory) {
            try self.double("CREATE (:F {x: $v})", std.math.nan(f64));
            try self.double("CREATE (:F {x: $v})", std.math.inf(f64));
            try self.double("CREATE (:F {x: $v})", -std.math.inf(f64));
        }
        if (self.mode == .rls_policy) {
            try self.exec("CREATE (:Hidden:F {x: 1})", &.{});
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
        return error.NarrowingWrong;
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
// The checked conversions themselves
// ---------------------------------------------------------------------------

/// A runtime copy: a comptime-known operand would make the conversion a
/// compile-time check.
fn rt(x: f64) f64 {
    var y = x;
    _ = &y;
    return y;
}

test "SONNY-2739: the checked float conversions hold at +-2^63, +-2^127, NaN and the infinities" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try narrowing.floatToInt(i64, rt(-two63)));
    try testing.expectError(error.IntegerOverflow, narrowing.floatToInt(i64, rt(two63)));
    try testing.expectEqual(@as(i64, 9223372036854774784), try narrowing.floatToInt(i64, rt(std.math.nextAfter(f64, two63, 0))));
    try testing.expectError(error.IntegerOverflow, narrowing.floatToInt(i64, rt(std.math.nextAfter(f64, -two63, -inf))));
    try testing.expectEqual(@as(i128, std.math.minInt(i128)), try narrowing.floatToInt(i128, rt(-0x1p127)));
    try testing.expectError(error.IntegerOverflow, narrowing.floatToInt(i128, rt(0x1p127)));
    for ([_]f64{ nan, inf, -inf }) |bad| {
        try testing.expectError(error.IntegerOverflow, narrowing.floatToInt(i64, rt(bad)));
        try testing.expectError(error.IntegerOverflow, narrowing.floatToInt(i128, rt(bad)));
        try testing.expectError(error.DecimalOverflow, geode.types.decimal128.checkedScaledCoeff(rt(bad), 1_000_000.0));
    }
    try testing.expectEqual(@as(i64, 0), narrowing.floatToIntSaturating(i64, rt(nan)));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), narrowing.floatToIntSaturating(i64, rt(two63)));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), narrowing.floatToIntSaturating(u64, rt(inf)));
    // 2^127 scaled to a Decimal coefficient does not fit its 38 digits.
    try testing.expectError(error.DecimalOverflow, geode.types.decimal128.checkedScaledCoeff(rt(0x1p127), 1.0));
    try testing.expectError(error.DecimalOverflow, geode.types.decimal128.checkedScaledCoeff(rt(-0x1p127), 1.0));
}

test "SONNY-2739: the exact decimal-to-integer rounding refuses what does not fit i64" {
    // 9223372036854775807.5 rounds down into i64 and up out of it.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try narrowing.decimalToInt(92233720368547758075, 1, .floor));
    try testing.expectError(error.IntegerOverflow, narrowing.decimalToInt(92233720368547758075, 1, .ceil));
    try testing.expectError(error.IntegerOverflow, narrowing.decimalToInt(92233720368547758075, 1, .half_away_from_zero));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try narrowing.decimalToInt(-92233720368547758080, 1, .ceil));
    try testing.expectError(error.IntegerOverflow, narrowing.decimalToInt(-92233720368547758081, 1, .floor));
    // A scale past 10^38, where `std.math.pow(i128, 10, scale)` panics.
    try testing.expectEqual(@as(i64, 0), try narrowing.decimalToInt(1, 60, .floor));
    try testing.expectEqual(@as(i64, -1), try narrowing.decimalToInt(-1, 60, .floor));
    try testing.expectEqual(@as(i64, 1), try narrowing.decimalToInt(1, 255, .ceil));
}

// ---------------------------------------------------------------------------
// Group and DISTINCT keys at the i64 boundary
// ---------------------------------------------------------------------------

fn checkBoundaryKeys(s: *Session, f: *Failures) !void {
    // A literal 2^63 and -2^63 (decimals), and doubles at the boundary, NaN
    // and the infinities (parameters), under count(DISTINCT). (An RLS session
    // does not aggregate a RETURN without a MATCH at all: UnknownFunction.)
    if (s.mode != .rls_policy) {
        try expectValue(s, f, "RETURN count(DISTINCT 9223372036854775808.0) AS c", "1");
        try expectValue(s, f, "RETURN count(DISTINCT -9223372036854775808.0) AS c", "1");
        for ([_]f64{ two63, -two63, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |v| {
            try expectRows(s, f, "RETURN count(DISTINCT $v) AS c", &.{.{ .name = "v", .value = .{ .Double = v } }}, &.{"1"});
        }
    }
    // The stored boundary values: 2^63 (a decimal and a double) is one value,
    // -2^63 (a decimal, a double, an integer) is one value, maxInt(i64) is
    // one; in memory NaN, +Inf and -Inf are one each.
    const stored: []const []const u8 = &.{ "2", "3", "1" };
    const in_memory: []const []const u8 = &.{ "2", "3", "1", "1", "1", "1" };
    const groups = if (s.mode == .in_memory) in_memory else stored;
    try expectRows(s, f, "MATCH (n:F) RETURN count(*) AS c GROUP BY n.x", &.{}, groups);
    try expectRows(s, f, "MATCH (n:F) RETURN count(*) AS c GROUP BY n.x HAVING count(*) > 0", &.{}, groups);
    try expectRows(s, f, "MATCH (n:F) WITH n.x AS x, count(*) AS c GROUP BY n.x RETURN c", &.{}, groups);
    try expectValue(s, f, "MATCH (n:F) RETURN count(DISTINCT n.x) AS c", if (s.mode == .in_memory) "6" else "3");
    try expectValue(s, f, "MATCH (n:F) RETURN count(*) AS c", if (s.mode == .in_memory) "9" else "6");
}

test "SONNY-2739: a group or DISTINCT key at +-2^63, NaN or an infinity does not abort" {
    try inModes("boundary keys", &modes, checkBoundaryKeys);
}

// ---------------------------------------------------------------------------
// The power operator
// ---------------------------------------------------------------------------

fn checkPower(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "RETURN 2 ^ 62 AS p", "4611686018427387904");
    try expectValue(s, f, "RETURN (-2) ^ 63 AS p", "-9223372036854775808");
    // Past i64: an exact scale-6 decimal, as before, while it fits.
    try expectValue(s, f, "RETURN 2 ^ 63 AS p", "9223372036854775808.000000m");
    try expectValue(s, f, "RETURN (-2) ^ 65 AS p", "-36893488147419103232.000000m");
    try expectValue(s, f, "RETURN 10 ^ 31 AS p", "10000000000000000000000000000000.000000m");
    // Exact past 2^53 (f64 gave 4052555153018976256).
    try expectValue(s, f, "RETURN 3 ^ 39 AS p", "4052555153018976267");
    // Too large for the decimal: 22003.
    try expectFail(s, f, "RETURN 10 ^ 32 AS p", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN 10 ^ 40 AS p", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN 10 ^ 400 AS p", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN 2 ^ 9223372036854775807 AS p", &.{}, error.DecimalOverflow);
    // Negative exponents: a fraction, or an integer for +-1; zero is 22012.
    try expectValue(s, f, "RETURN 2 ^ -1 AS p", "0.500000m");
    try expectValue(s, f, "RETURN 1 ^ -3 AS p", "1");
    try expectValue(s, f, "RETURN (-1) ^ -3 AS p", "-1");
    try expectFail(s, f, "RETURN 0 ^ -1 AS p", &.{}, error.DivisionByZero);
    // A decimal base.
    try expectValue(s, f, "RETURN 2.0 ^ 3 AS p", "8");
    try expectValue(s, f, "RETURN 1.5 ^ 2 AS p", "2.250000m");
    try expectValue(s, f, "RETURN 2.0 ^ 63 AS p", "9223372036854775808.000000m");
    try expectValue(s, f, "RETURN (-2.0) ^ 63 AS p", "-9223372036854775808");
    try expectFail(s, f, "RETURN 10.0 ^ 400 AS p", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN 0.0 ^ -1 AS p", &.{}, error.DivisionByZero);
}

test "SONNY-2739: the power operator refuses a result that does not fit" {
    try inModes("power", &eval_modes, checkPower);
}

// ---------------------------------------------------------------------------
// Casts, conversions and rounding
// ---------------------------------------------------------------------------

/// 0.000...01 with 60 and 40 fraction digits: past 10^38, where
/// `std.math.pow(i128, 10, scale)` panicked.
const scale60 = "0." ++ "0" ** 59 ++ "1";
const scale40 = "0." ++ "0" ** 39 ++ "1";

fn checkConversions(s: *Session, f: *Failures) !void {
    // toFloat and CAST to a float type are a scale-6 decimal: a string past
    // it, NaN or an infinity is 22003 (NaN was a garbage coefficient).
    for ([_][]const u8{ "1e400", "-1e400", "nan", "inf", "1e33" }) |text| {
        try expectFail(s, f, try std.fmt.allocPrint(s.arena.allocator(), "RETURN toFloat('{s}') AS x", .{text}), &.{}, error.DecimalOverflow);
    }
    try expectValue(s, f, "RETURN toFloat('4503599627370496') AS x", "4503599627370496.000000m");
    try expectValue(s, f, "RETURN toFloat('2.5') AS x", "2.500000m");
    try expectFail(s, f, "RETURN CAST('nan' AS DOUBLE) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN CAST('1e400' AS FLOAT) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN CAST('-inf' AS REAL) AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN CAST('2.5' AS DOUBLE) AS x", "2.500000m");
    // degrees and radians.
    try expectFail(s, f, "RETURN degrees(1e33) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN radians(1e35) AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN radians(180) AS x", "3.141593m");
    // A JSON number past the decimal is its double.
    try expectValue(s, f, "RETURN json('{\"a\": 1e300}').a AS x", "1e300d");
    try expectValue(s, f, "RETURN json('{\"a\": 1.5}').a AS x", "1.500000m");
    // ceil, floor, round and toInteger over a decimal: exact, 22003 past i64.
    try expectFail(s, f, "RETURN ceil(9223372036854775807.5) AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN floor(9223372036854775807.5) AS x", "9223372036854775807");
    try expectValue(s, f, "RETURN ceil(-9223372036854775808.5) AS x", "-9223372036854775808");
    try expectFail(s, f, "RETURN floor(-9223372036854775808.5) AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN floor(1e30) AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN round(1e30) AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN round(2.5) AS x", "3");
    try expectValue(s, f, "RETURN round(-2.5) AS x", "-3");
    try expectValue(s, f, "RETURN round(" ++ scale60 ++ ") AS x", "0");
    try expectValue(s, f, "RETURN ceil(" ++ scale60 ++ ") AS x", "1");
    try expectValue(s, f, "RETURN floor(-" ++ scale60 ++ ") AS x", "-1");
    try expectValue(s, f, "RETURN round(" ++ scale60 ++ ", 2) AS x", "0.00m");
    try expectValue(s, f, "RETURN round(1.2345, 2) AS x", "1.23m");
    try expectValue(s, f, "RETURN round(1234, -2) AS x", "1200");
    try expectValue(s, f, "RETURN round(5, -19) AS x", "0");
    try expectFail(s, f, "RETURN round(5000000000000000000, -19) AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN round(1250.5, -2) AS x", "1300");
    try expectValue(s, f, "RETURN round(1.5, -300) AS x", "0");
    try expectFail(s, f, "RETURN toInteger(9223372036854775808.0) AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN toInteger(9223372036854775807.9) AS x", "9223372036854775807");
    try expectValue(s, f, "RETURN toInteger(" ++ scale40 ++ ") AS x", "0");
    try expectValue(s, f, "RETURN toInteger(-" ++ scale40 ++ ") AS x", "-1");
    // sum() and avg() of a list (a scalar function, in WHERE or a list
    // comprehension): a decimal narrowed to its floor, and the sum, checked.
    // (The planned read's WHERE drops a row whose predicate fails, so there
    // the overflow filters every row out instead of failing the query.)
    for ([_][]const u8{
        "MATCH (n:F) WHERE sum([9223372036854775808.0]) > 0 RETURN count(*) AS c",
        "MATCH (n:F) WHERE sum([9223372036854775807, 1]) > 0 RETURN count(*) AS c",
        "MATCH (n:F) WHERE avg([9223372036854775808.0]) > 0 RETURN count(*) AS c",
    }) |q| {
        if (s.mode == .in_memory) try expectFail(s, f, q, &.{}, error.IntegerOverflow) else try expectValue(s, f, q, "0");
    }
    try expectValue(s, f, "RETURN [x IN [1] | sum([1.5, 2])] AS s", "[3]");
    try expectValue(s, f, "RETURN [x IN [1] | avg([2.5, 4])] AS s", "[3]");
    // A decimal literal with more than 255 fraction digits is out of range.
    try expectFail(s, f, "RETURN 0." ++ "0" ** 299 ++ "1 AS x", &.{}, error.Overflow);
}

test "SONNY-2739: casts, conversions and rounding refuse a value that does not fit" {
    try inModes("conversions", &eval_modes, checkConversions);
}

test "SONNY-2739: the heap rounding functions refuse a value past i64" {
    const ef = geode.types.evaluator_functions;
    const D = geode.types.decimal128.Decimal128;
    const HeapValue = geode.heap.Value;
    const big = HeapValue{ .Decimal128 = D{ .coeff = 92233720368547758075, .scale = 1 } };
    try testing.expectError(error.Overflow, ef.ceil_val(big));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try ef.floor_val(big)).Int);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try ef.toInteger_val(big)).Int);
    try testing.expectEqual(@as(i64, 5), (try ef.ceil_val(.{ .Decimal128 = D{ .coeff = 45, .scale = 1 } })).Int);
    try testing.expectEqual(@as(i64, -5), (try ef.floor_val(.{ .Decimal128 = D{ .coeff = -45, .scale = 1 } })).Int);
    try testing.expectEqual(@as(i64, 500), (try ef.ceil_val(.{ .Decimal128 = D{ .coeff = 5, .scale = -2 } })).Int);
    try testing.expectError(error.Overflow, ef.toInteger_val(.{ .Decimal128 = D{ .coeff = 92233720368547758080, .scale = 1 } }));
    try testing.expectError(error.Overflow, ef.toInteger_val(.{ .Double = rt(two63) }));
    try testing.expectError(error.Overflow, ef.toInteger_val(.{ .Double = rt(std.math.nan(f64)) }));
    try testing.expectError(error.Overflow, ef.toInteger_val(.{ .Double = rt(std.math.inf(f64)) }));
    try testing.expectError(error.Overflow, ef.toInteger_val(.{ .Real = @floatCast(rt(two63)) }));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), (try ef.toInteger_val(.{ .Double = rt(-two63) })).Int);
}

test "SONNY-2739: a typed ARRAY parameter past the decimal is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codec = geode.property_value_codec;
    try testing.expectError(error.DecimalOverflow, codec.protoExtendedToHeapValue(a, .{ .type_name = "ARRAY", .data = .{ .text = "[1e300]" } }));
    try testing.expectError(error.DecimalOverflow, codec.protoExtendedToHeapValue(a, .{ .type_name = "ARRAY", .data = .{ .text = "[-1e33]" } }));
    // An integer past i64 / 10^6 after a float: was an i64 overflow.
    _ = try codec.protoExtendedToHeapValue(a, .{ .type_name = "ARRAY", .data = .{ .text = "[1.5, 10000000000000]" } });
    _ = try codec.protoExtendedToHeapValue(a, .{ .type_name = "ARRAY", .data = .{ .text = "[1.5, 2.25]" } });
}
