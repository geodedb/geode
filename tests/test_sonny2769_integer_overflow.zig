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
// Round 5: every hand-rolled 10^scale over a decimal scale (`*= 10` per
// digit, then `coeff *` it) overflowed past scale 38: CAST to a string type,
// string concatenation, an inline property map and MERGE, the legacy WITH
// ... ORDER BY, a map property's JSONB text and the server's ORDER BY keys.
// Decimals are now formatted digit by digit (types/decimal_text.zig) and
// compared by exact value (value_order).
//
// CANARY: REQ=REQ-SONNY-2769-INTEGER-OVERFLOW; FEATURE="IntegerOverflow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2769_integer_overflow.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
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
        // The index manager is process-global and a CREATE INDEX creates it
        // with the session's arena, so it is released here and in deinit,
        // before the arena: the catalog cleanup clears its dimension registry.
        // Same discipline as tests/test_vector_knn_silent_failures.zig.
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp: ?std.testing.TmpDir = std.testing.tmpDir(.{});
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
        // The catalog is kept in the temporary directory in every mode. With
        // no data directory it falls back to /tmp and persists there, shared
        // by every run: a second run failed its CREATE INDEX with
        // DuplicateIndex. Same two steps as
        // tests/test_count_nodes_pushdown_perf.zig: create the catalog, then
        // clear the override for an in-memory store.
        graph_store.setDataDirOverride(allocator, data_dir.?);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        const persisted = mode != .in_memory;
        if (!persisted) graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
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
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
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

// ---------------------------------------------------------------------------
// Functions: user integers as arguments, CAST to DECIMAL
// ---------------------------------------------------------------------------

const scale200 = "0." ++ "0" ** 199 ++ "1";

fn checkFunctions(s: *Session, f: *Failures) !void {
    // abs() and mod() at minInt.
    try expectFail(s, f, "RETURN abs(" ++ min_int ++ ") AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN abs(-5) AS x", "5");
    try expectValue(s, f, "RETURN abs(-1.5) AS x", "1.5m");
    try expectValue(s, f, "RETURN mod(" ++ min_int ++ ", -1) AS x", "0");
    try expectValue(s, f, "RETURN mod(-7, 3) AS x", "-1");
    // range() with a span or a step at the edge of i64.
    try expectFail(s, f, "RETURN range(" ++ min_int ++ ", 9223372036854775807) AS x", &.{}, error.RangeTooLarge);
    try expectValue(s, f, "RETURN range(0, -10, " ++ min_int ++ ") AS x", "[0]");
    try expectValue(s, f, "RETURN range(9223372036854775806, 9223372036854775807, 9223372036854775807) AS x", "[9223372036854775806]");
    try expectValue(s, f, "RETURN range(1, 7, 2) AS x", "[1, 3, 5]");
    // CAST to DECIMAL: every rescale checked; fraction digits past the
    // target scale truncated before they can overflow.
    try expectFail(s, f, "RETURN CAST(9223372036854775807 AS DECIMAL(38, 30)) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN CAST(1 AS DECIMAL(38, 255)) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN CAST(1.5 AS DECIMAL(38, 200)) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN CAST('1.5' AS DECIMAL(38, 255)) AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN CAST('1." ++ "0" ** 40 ++ "' AS DECIMAL) AS x", "1m");
    try expectValue(s, f, "RETURN CAST('1." ++ "9" ** 300 ++ "' AS DECIMAL(10, 2)) AS x", "1.99m");
    try expectValue(s, f, "RETURN CAST(0 AS DECIMAL(38, 255)) = 0 AS x", "true");
    try expectValue(s, f, "RETURN CAST('12.345' AS DECIMAL(10, 2)) AS x", "12.34m");
    // The sign applies to the fraction ("-1.5" was -0.5, "-0.5" was 0.5).
    try expectValue(s, f, "RETURN CAST('-1.5' AS DECIMAL(10, 1)) AS x", "-1.5m");
    try expectValue(s, f, "RETURN CAST('-0.5' AS DECIMAL(10, 1)) AS x", "-0.5m");
    // char(), varchar() and decimal() arguments.
    try expectFail(s, f, "RETURN char('abc', -1) AS x", &.{}, error.InvalidArgs);
    try expectFail(s, f, "RETURN varchar('abc', 100000) AS x", &.{}, error.InvalidArgs);
    try expectRows(s, f, "RETURN varchar('abc', 5) AS x", &.{}, &.{"<Varchar>"});
    try expectFail(s, f, "RETURN decimal('1.5', 40000) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN decimal('15', -1) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN decimal('1.5', 300) AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN decimal('200000000000000000000000000000000000000') AS x", &.{}, error.DecimalOverflow);
    try expectFail(s, f, "RETURN decimal('0." ++ "0" ** 40000 ++ "1') AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN decimal('1.25', 1) AS x", "1.2m");
    try expectFail(s, f, "RETURN decimal_mul(" ++ scale200 ++ ", " ++ scale200 ++ ") AS x", &.{}, error.DecimalOverflow);
    try expectValue(s, f, "RETURN decimal_mul(1.5, 2.0) AS x", "3.00m");
    // Vectors, ranges, networks, time series, degrees.
    try expectFail(s, f, "RETURN vectori32([3000000000]) AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN intrange(3000000000, 4000000000, true, false) AS x", &.{}, error.IntegerOverflow);
    try expectValue(s, f, "RETURN range_contains(intrange(1, 5, true, false), 3000000000) AS x", "false");
    try expectValue(s, f, "RETURN range_contains(intrange(1, 5, true, false), 3) AS x", "true");
    try expectFail(s, f, "RETURN ip_netmask(ipaddr('10.0.0.1'), 300) AS x", &.{}, error.InvalidArgs);
    try expectFail(s, f, "RETURN timeseries.dtw([1.0, 2.0], [1.0, 2.0], -1) AS x", &.{}, error.InvalidArgs);
    try expectFail(s, f, "RETURN timeseries.dtw_derivative([1.0, 2.0], [1.0, 2.0], -1) AS x", &.{}, error.InvalidArgs);
    try expectFail(s, f, "RETURN timeseries.dtw_shape([1.0, 2.0], [1.0, 2.0], -1) AS x", &.{}, error.InvalidArgs);
    try expectValue(s, f, "RETURN indegree(-1) AS x", "0");
    try expectValue(s, f, "RETURN outdegree(-1) AS x", "0");
}

test "SONNY-2769: functions refuse an integer argument that does not fit" {
    try inModes("functions", &eval_modes, checkFunctions);
}

test "SONNY-2769: the heap decimal and abs functions refuse what does not fit" {
    const ef = geode.types.evaluator_functions;
    const D = geode.types.decimal128.Decimal128;
    try testing.expectError(error.Overflow, ef.abs_val(.{ .Int = std.math.minInt(i64) }));
    try testing.expectError(error.Overflow, ef.abs_val(.{ .SmallInt = std.math.minInt(i16) }));
    try testing.expectError(error.Overflow, ef.abs_val(.{ .Decimal128 = D{ .coeff = std.math.minInt(i128), .scale = 0 } }));
    try testing.expectEqual(@as(i64, 5), (try ef.abs_val(.{ .Int = -5 })).Int);
    // Decimal128: the 39-digit bound, the fraction-digit count, the scale sums.
    try testing.expectError(error.Overflow, D.fromStr("200000000000000000000000000000000000000"));
    try testing.expectEqual(@as(i128, std.math.maxInt(i128)), (try D.fromStr("170141183460469231731687303715884105727")).coeff);
    const big_scale = D{ .coeff = 1, .scale = std.math.maxInt(i16) };
    try testing.expectError(error.Overflow, big_scale.mul(big_scale));
    try testing.expectError(error.Overflow, (D{ .coeff = 15, .scale = std.math.maxInt(i16) }).roundHalfEven(std.math.minInt(i16)));
    const min_d = D{ .coeff = std.math.minInt(i128), .scale = 0 };
    try testing.expectError(error.Overflow, min_d.div(D{ .coeff = -1, .scale = 18 }));
}

// ---------------------------------------------------------------------------
// Procedure arguments, parameter decoders, helpers
// ---------------------------------------------------------------------------

/// `query` succeeds (its rows are not checked).
fn expectOk(s: *Session, f: *Failures, query: []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, &.{}) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    result.deinit(aa);
}

fn checkProcedures(s: *Session, f: *Failures) !void {
    // An integer argument outside its type is InvalidArgs; the casts aborted
    // the server. (A negative literal is not an integer literal here, so only
    // the large ones reach the casts.)
    try expectFail(s, f, "CALL tde.configure_mock_kms(70000)", &.{}, error.InvalidArgs);
    try expectFail(s, f, "CALL tde.configure_mock_kms(9999, false, false, 5000000000)", &.{}, error.InvalidArgs);
    try expectFail(s, f, "CALL tde.configure_rotation('x', 5000000000)", &.{}, error.InvalidArgs);
    try expectFail(s, f, "CALL audit.configure('info', 'json', 4611686018427387904)", &.{}, error.InvalidArgs);
    // A BFS depth past u32 is clamped (it aborted the server).
    try expectOk(s, f, "CALL algo.bfs.stream(1, {maxDepth: 5000000000})");
    // knn() through a vector index with a k past u32 (the index takes a u32).
    try s.exec("CREATE (:VDoc {embedding: vectorf32([1.0, 0.0])})", &.{});
    try s.exec("CREATE INDEX vdoc_vec ON VDoc (embedding) USING vector", &.{});
    try expectValue(s, f, "RETURN size(knn('embedding', vectorf32([1.0, 0.0]), 5000000000, 'l2')) AS x", "1");
    // interval_contains() over month counts past i64 microseconds.
    try expectValue(s, f, "RETURN interval_contains(duration('P2147483647M'), duration('P1D')) AS x", "true");
}

test "SONNY-2769: procedure arguments outside their type are refused" {
    try inModes("procedures", &.{.in_memory}, checkProcedures);
}

test "SONNY-2769: parameter decoders refuse or fold what does not fit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codec = geode.property_value_codec;
    // A SMALLINT parameter past i16.
    try testing.expectError(error.InvalidParams, codec.protoExtendedToHeapValue(a, .{ .type_name = "SMALLINT", .data = .{ .int_val = 100000 } }));
    try testing.expectEqual(@as(i16, -7), (try codec.protoExtendedToHeapValue(a, .{ .type_name = "SMALLINT", .data = .{ .int_val = -7 } })).SmallInt);
    // A typed DECIMAL parameter's bytes (tag 0x24, i128 coefficient, i16
    // scale) with a scale outside 0..255: folded or truncated, not aborted.
    var bytes: [19]u8 = undefined;
    bytes[0] = 0x24;
    std.mem.writeInt(i128, bytes[1..17], 15, .little);
    std.mem.writeInt(i16, bytes[17..19], -1, .little);
    const neg = try codec.protoExtendedToHeapValue(a, .{ .type_name = "DECIMAL", .data = .{ .bytes = &bytes } });
    const neg_v = codec.heapValueToValue(neg);
    try testing.expectEqual(@as(i128, 150), neg_v.Decimal.coeff);
    try testing.expectEqual(@as(u8, 0), neg_v.Decimal.scale);
    std.mem.writeInt(i16, bytes[17..19], 1000, .little);
    const deep = try codec.protoExtendedToHeapValue(a, .{ .type_name = "DECIMAL", .data = .{ .bytes = &bytes } });
    const deep_v = codec.heapValueToValue(deep);
    try testing.expectEqual(@as(u8, 255), deep_v.Decimal.scale);
    try testing.expectEqual(@as(i128, 0), deep_v.Decimal.coeff);
    std.mem.writeInt(i128, bytes[1..17], std.math.maxInt(i128), .little);
    std.mem.writeInt(i16, bytes[17..19], -30, .little);
    const huge = try codec.protoExtendedToHeapValue(a, .{ .type_name = "DECIMAL", .data = .{ .bytes = &bytes } });
    try testing.expect(codec.heapValueToValue(huge) == .Null);
    // A decimal array element's i16 scale past 255.
    var data: [18]u8 = undefined;
    std.mem.writeInt(i128, data[0..16], 1, .little);
    std.mem.writeInt(i16, data[16..18], 1000, .little);
    const ext = geode.eval_ext.ExtValue{ .Array = .{ .elem_type = .decimal, .data = &data, .allocator = a } };
    try testing.expectError(error.InvalidParams, codec.extValueToProjectedValue(a, ext));
}

test "SONNY-2769: the JSON result writer formats a decimal at any scale" {
    var cols = [_][]const u8{"x"};
    var row = [_]Value{.{ .Decimal = .{ .coeff = 5, .scale = 19 } }};
    var rows = [_][]Value{&row};
    const r = execution.ExecutionResult{ .columns = &cols, .rows = &rows, .flags = .empty };
    const json = try r.toJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "0.0000000000000000005") != null);
}

// ---------------------------------------------------------------------------
// Round 5: decimals at any scale, formatted and compared
// ---------------------------------------------------------------------------

/// 1 at scale 36, 40 and 255, 15 at scale 40, and 38 digits at scale 20.
const s36 = "0." ++ "0" ** 35 ++ "1";
const s40 = "0." ++ "0" ** 39 ++ "1";
const s255 = "0." ++ "0" ** 254 ++ "1";
const s40_15 = "0." ++ "0" ** 38 ++ "15";
const big38 = "123456789012345678.90123456789012345678";

fn checkDecimalText(s: *Session, f: *Failures) !void {
    // CAST to a string type computed 10^scale in i128 (C2), wrote the
    // fraction into 32 bytes (NULL past 32 digits) and lost the sign of a
    // value between -1 and 0.
    try expectValue(s, f, "RETURN CAST(" ++ s40 ++ " AS STRING) AS x", "'" ++ s40 ++ "'");
    try expectValue(s, f, "RETURN CAST(" ++ s40 ++ " AS VARCHAR) AS x", "'" ++ s40 ++ "'");
    try expectValue(s, f, "RETURN CAST(" ++ s255 ++ " AS TEXT) AS x", "'" ++ s255 ++ "'");
    try expectValue(s, f, "RETURN CAST(-0.5 AS STRING) AS x", "'-0.5'");
    try expectValue(s, f, "RETURN CAST(12345678901234567890123456789012345.678 AS STRING) AS x", "'12345678901234567890123456789012345.678'");
    // String concatenation: a scale-36 fraction overran a 32-byte padding
    // buffer, a scale-40 one overflowed; past the 64-byte text buffer it is
    // refused, as for every other type.
    try expectValue(s, f, "RETURN 'a' || " ++ s36 ++ " AS x", "'a" ++ s36 ++ "'");
    try expectValue(s, f, "RETURN 'a' || " ++ s40 ++ " AS x", "'a" ++ s40 ++ "'");
    try expectValue(s, f, "RETURN 'a' || -0.5 AS x", "'a-0.5'");
    try expectFail(s, f, "RETURN 'a' || " ++ s255 ++ " AS x", &.{}, error.Unsupported);
    // A map property is stored as JSONB text: `pow *= 10` overflowed, and
    // -0.5 was stored as 0.5.
    try s.exec("CREATE (:DM {m: {a: " ++ s40 ++ ", b: -0.5}})", &.{});
    try expectValue(s, f, "MATCH (n:DM) RETURN n.m.b AS b", "-0.500000m");
    try s.exec("MATCH (n:DM) SET n.m = {a: -0.25, b: " ++ s255 ++ "}", &.{});
    try expectValue(s, f, "MATCH (n:DM) RETURN n.m.a AS a", "-0.250000m");
}

test "SONNY-2769: a decimal is formatted at any scale" {
    try inModes("decimal text", &modes, checkDecimalText);
}

fn checkDecimalEquality(s: *Session, f: *Failures) !void {
    // The session is the active context, as a transport handler makes it: a
    // node MERGE creates takes the session's tenant from it.
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    try s.exec("CREATE (:DQ {x: 1.5})", &.{});
    try s.exec("CREATE (:DQ {x: 100000000000000000000000000000.0})", &.{});
    // C3: an inline property map aligned the scales in i128 (legacy
    // sessions), and MERGE does on every session.
    try expectValue(s, f, "MATCH (n:DQ {x: " ++ s40_15 ++ "}) RETURN count(n) AS c", "0");
    try expectValue(s, f, "MATCH (n:DQ {x: 1.00000000000}) RETURN count(n) AS c", "0");
    try expectValue(s, f, "MERGE (n:DQ {x: " ++ s40_15 ++ "}) RETURN n.x AS x", s40_15 ++ "m");
    try expectValue(s, f, "MERGE (n:DQ {x: 1.00000000000}) RETURN n.x AS x", "1.00000000000m");
    // A number equal by value is the same property value: MERGE matches it.
    try expectValue(s, f, "MERGE (n:DQ {x: 1.50}) RETURN n.x AS x", "1.5m");
    try expectValue(s, f, "MATCH (n:DQ) RETURN count(n) AS c", "4");
    try s.exec("CREATE (:DQI {x: 1})", &.{});
    try expectValue(s, f, "MERGE (n:DQI {x: 1.0}) RETURN n.x AS x", "1");
    try expectValue(s, f, "MATCH (n:DQI) RETURN count(n) AS c", "1");
}

test "SONNY-2769: an inline property map and MERGE compare decimals at any scale" {
    try inModes("decimal equality", &modes, checkDecimalEquality);
}

fn checkWithOrder(s: *Session, f: *Failures) !void {
    try s.exec("CREATE (:DW {x: " ++ big38 ++ "})", &.{});
    try s.exec("CREATE (:DW {x: 0.25})", &.{});
    try s.exec("CREATE (:DW {x: " ++ s40 ++ "})", &.{});
    // The legacy WITH ... ORDER BY cross-multiplied by 10^scale in i128.
    try expectValue(s, f, "MATCH (n:DW) WITH n.x AS x ORDER BY x LIMIT 1 RETURN x", s40 ++ "m");
    try expectValue(s, f, "MATCH (n:DW) WITH n.x AS x ORDER BY x DESC LIMIT 1 RETURN x", big38 ++ "m");
}

test "SONNY-2769: WITH ... ORDER BY orders decimals at any scale" {
    try inModes("with order", &modes, checkWithOrder);
}

fn checkNodeJson(s: *Session, f: *Failures) !void {
    // ExecutionResult.toJson writes a node's properties through its own
    // formatter: `divisor *= 10` overflowed, and -0.5 lost its sign.
    const aa = s.arena.allocator();
    try s.exec("CREATE (:DJ {x: -0.5, y: " ++ s40 ++ "})", &.{});
    var r = try s.run("MATCH (n:DJ) RETURN n", &.{});
    defer r.deinit(aa);
    const json = try r.toJson(aa);
    for ([_][]const u8{ "\"x\":-0.5", "\"y\":" ++ s40 }) |want| {
        if (std.mem.indexOf(u8, json, want) == null) try f.add("[{s}] node JSON: expected {s} in {s}", .{ @tagName(s.mode), want, json });
    }
}

test "SONNY-2769: the JSON writer formats a node's decimal properties at any scale" {
    try inModes("node JSON", &eval_modes, checkNodeJson);
}

test "SONNY-2769: the server's ORDER BY keys print a decimal at any scale" {
    // buildOrderKeys prints every ORDER BY key; `p *= 10` overflowed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var parsed = try geode.parseGqlOptions("RETURN 1 AS x ORDER BY x + " ++ s40 ++ ", " ++ s255, aa, .{});
    defer parsed.deinit();
    const keys = parsed.program.statements[0].Query.order_by.?.keys;
    try testing.expectEqualStrings("x + " ++ s40, try geode.printer.stringifyExprAlloc(aa, keys[0].expr, .{}));
    try testing.expectEqualStrings(s255, try geode.printer.stringifyExprAlloc(aa, keys[1].expr, .{}));
}

test "SONNY-2769: the decimal text, the JSON writer and the library helpers at any scale" {
    const text = geode.types.decimal_text;
    const a = testing.allocator;
    const cases = [_]struct { coeff: i128, scale: u8, want: []const u8 }{
        .{ .coeff = 150, .scale = 2, .want = "1.50" },
        .{ .coeff = -5, .scale = 1, .want = "-0.5" },
        .{ .coeff = 1, .scale = 40, .want = s40 },
        .{ .coeff = std.math.minInt(i128), .scale = 39, .want = "-0.170141183460469231731687303715884105728" },
        .{ .coeff = std.math.maxInt(i128), .scale = 0, .want = "170141183460469231731687303715884105727" },
    };
    for (cases) |c| {
        const got = try text.alloc(a, c.coeff, c.scale);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    const long = try text.alloc(a, 1, 255);
    defer a.free(long);
    try testing.expectEqualStrings(s255, long);
    // Library helpers with no server caller, hardened the same way.
    const conv = geode.types.numeric_promotion.ValueConverter;
    try testing.expectError(error.Overflow, conv.intToDecimal(std.math.maxInt(i64), 20));
    try testing.expectEqual(@as(i128, 12300), (try conv.intToDecimal(123, 2)).coeff);
    try testing.expectError(error.Overflow, geode.ext_types.decimalFromString("1" ** 40));
    try testing.expectError(error.Overflow, geode.ext_types.decimalFromString("0." ++ "0" ** 255 ++ "1"));
    const min_text = try geode.ext_types.decimalToString(.{ .coeff = std.math.minInt(i128), .scale = 2 }, a);
    defer a.free(min_text);
    try testing.expectEqualStrings("-1701411834604692317316873037158841057.28", min_text);
}
