// SONNY-2806: an inline property map compares a stored property by its exact
// value on every path, and MERGE's property index keys a number by its value.
//
// `MATCH (n:T {x: v})` asks whether x equals v. The legacy executor compares
// with execution.valuesEqual, numbers by their exact value (value_order, the
// identity GROUP BY keys them by). The persisted paths compared by
// representation:
//   * the planned read's and the streaming node scan's matchers compared a
//     decimal by coefficient and scale ({x: 1.50} missed a stored 1.5,
//     {x: 1.0} a stored 1), had no DOUBLE arm (the planned read) and never
//     matched an extended value, and a stored DOUBLE is one: MATCH
//     (n:T {x: $d}) never matched a node created from the same DOUBLE;
//   * the adapter's exact node-property index, which both seek before they
//     match, hashed a value's bytes, so a seek for {x: 1} found no stored 1.0
//     and returned nothing;
//   * MERGE's property index (graph_store) keyed an integer by its text and
//     did not index a decimal or a double, so MERGE (n:U {x: 1}) trusted the
//     miss and duplicated a stored 1.0 on every session, while
//     MERGE {x: 1.0} matched a stored 1 (round-5 regression, I1a).
// A duration and a zoned time are compared by value too: {v: PT24H} matches a
// stored P1D, and MERGE does not duplicate it (round 6, M2).
//
// CANARY: REQ=REQ-SONNY-2806-EXACT-PROPERTY-MATCHING; FEATURE="InlinePropertyMatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2806_exact_property_matching.zig; OWNER=execution; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const Value = geode.value_types.Value;

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

const node_scan_stream = geode.node_scan_stream;

// ---------------------------------------------------------------------------
// MERGE's property index: both directions, every session (I1a)
// ---------------------------------------------------------------------------

fn checkMergeNumbers(s: *Session, f: *Failures) !void {
    // A node MERGE creates takes the session's tenant from the active context.
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    try s.exec("CREATE (:MT {x: 1})", &.{});
    try s.exec("CREATE (:MU {x: 1.0})", &.{});
    try s.double("CREATE (:MD {x: $v})", 1.5);
    try s.exec("CREATE (:MS {x: $v})", &.{.{ .name = "v", .value = .{ .SmallInt = 7 } }});
    // A decimal finds the integer, and the integer finds the decimal (it
    // trusted an index miss and created a second :MU).
    try expectValue(s, f, "MERGE (n:MT {x: 1.0}) RETURN n.x AS x", "1");
    try expectValue(s, f, "MERGE (n:MU {x: 1}) RETURN n.x AS x", "1.0m");
    try expectValue(s, f, "MERGE (n:MU {x: 1.00}) RETURN n.x AS x", "1.0m");
    // A DOUBLE and a decimal of the same value, and a SMALLINT and an INT.
    try expectValue(s, f, "MERGE (n:MD {x: 1.5}) RETURN n.x AS x", "1.5d");
    try expectValue(s, f, "MERGE (n:MD {x: 1.50}) RETURN n.x AS x", "1.5d");
    try expectValue(s, f, "MERGE (n:MS {x: 7}) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MERGE (n:MS {x: 7.0}) RETURN count(n) AS c", "1");
    for ([_][]const u8{ "MT", "MU", "MD", "MS" }) |label| {
        const q = try std.fmt.allocPrint(s.arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
        try expectValue(s, f, q, "1");
    }
    // A different value is created.
    try expectValue(s, f, "MERGE (n:MT {x: 1.5}) RETURN n.x AS x", "1.5m");
    try expectValue(s, f, "MATCH (n:MT) RETURN count(n) AS c", "2");
}

test "SONNY-2806: MERGE finds a stored number of any representation" {
    try inModes("merge numbers", &modes, checkMergeNumbers);
}

// ---------------------------------------------------------------------------
// Inline property maps on every path: nodes and relationships, literals and
// parameters (I1b)
// ---------------------------------------------------------------------------

const d15: Param = .{ .name = "d", .value = .{ .Double = 1.5 } };
const d01: Param = .{ .name = "d", .value = .{ .Double = 0.1 } };

fn checkInlineNumbers(s: *Session, f: *Failures) !void {
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    try s.exec("CREATE (:IT {x: $d})", &.{d15});
    try s.exec("CREATE (:ID {x: 1.5})", &.{});
    try s.exec("CREATE (:II {x: 1})", &.{});
    try s.exec("CREATE (:IP {x: $d})", &.{d01});
    try s.exec("CREATE (:IA)-[:IR {w: 1}]->(:IB)", &.{});
    try s.exec("CREATE (:IA)-[:IR2 {w: $d}]->(:IB)", &.{d15});
    // A stored DOUBLE matches the same DOUBLE and the decimal of its value
    // (the persisted paths matched neither).
    try expectRows(s, f, "MATCH (n:IT {x: $d}) RETURN count(n) AS c", &.{d15}, &.{"1"});
    try expectValue(s, f, "MATCH (n:IT {x: 1.5}) RETURN count(n) AS c", "1");
    // A decimal at another scale, a DOUBLE parameter, an integer.
    try expectValue(s, f, "MATCH (n:ID {x: 1.50}) RETURN count(n) AS c", "1");
    try expectRows(s, f, "MATCH (n:ID {x: $d}) RETURN count(n) AS c", &.{d15}, &.{"1"});
    try expectValue(s, f, "MATCH (n:II {x: 1.0}) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MATCH (n:II {x: 1}) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MATCH (n:ID {x: 1}) RETURN count(n) AS c", "0");
    try expectValue(s, f, "MATCH (n:II {x: 1.5}) RETURN count(n) AS c", "0");
    // An integer against a stored decimal: the exact index seek found none.
    try s.exec("CREATE (:IJ {x: 2.0})", &.{});
    try expectValue(s, f, "MATCH (n:IJ {x: 2}) RETURN count(n) AS c", "1");
    // Relationships.
    try expectValue(s, f, "MATCH ()-[r:IR {w: 1.0}]->() RETURN count(r) AS c", "1");
    try expectValue(s, f, "MATCH ()-[r:IR2 {w: 1.5}]->() RETURN count(r) AS c", "1");
    // A parameter in a relationship's map reaches only the planned read: the
    // legacy executor evaluates it without the parameters and never matches
    // (pre-existing, reported for SONNY-2734).
    if (s.mode == .persisted or s.mode == .unbounded_cache) {
        try expectRows(s, f, "MATCH ()-[r:IR2 {w: $d}]->() RETURN count(r) AS c", &.{d15}, &.{"1"});
    }
    // WHERE agrees wherever `=` is exact.
    try expectValue(s, f, "MATCH (n:ID) WHERE n.x = 1.50 RETURN count(n) AS c", "1");
    // DOUBLE 0.1 is not DECIMAL 0.1: an inline map is exact, as GROUP BY and
    // `=` are (SONNY-2807).
    try expectValue(s, f, "MATCH (n:IP {x: 0.1}) RETURN count(n) AS c", "0");
    try expectRows(s, f, "MATCH (n:IP {x: $d}) RETURN count(n) AS c", &.{d01}, &.{"1"});
}

test "SONNY-2806: an inline property map matches a stored number by value on every path" {
    try inModes("inline numbers", &modes, checkInlineNumbers);
}

// ---------------------------------------------------------------------------
// Durations and zoned times (M2)
// ---------------------------------------------------------------------------

fn checkInlineTemporal(s: *Session, f: *Failures) !void {
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    try s.exec("CREATE (:IV {v: duration('P1D')})", &.{});
    try s.exec("CREATE (:IZ {t: timetz('11:00:00+00:00')})", &.{});
    try expectValue(s, f, "MATCH (n:IV {v: duration('PT24H')}) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MATCH (n:IV {v: duration('P30D')}) RETURN count(n) AS c", "0");
    try expectValue(s, f, "MATCH (n:IZ {t: timetz('01:00:00+14:00')}) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MATCH (n:IZ {t: timetz('12:00:00+00:00')}) RETURN count(n) AS c", "0");
    try expectValue(s, f, "MERGE (n:IV {v: duration('PT24H')}) RETURN 1 AS m", "1");
    try expectValue(s, f, "MERGE (n:IZ {t: timetz('01:00:00+14:00')}) RETURN 1 AS m", "1");
    try expectValue(s, f, "MATCH (n:IV) RETURN count(n) AS c", "1");
    try expectValue(s, f, "MATCH (n:IZ) RETURN count(n) AS c", "1");
}

test "SONNY-2806: an inline map and MERGE compare durations and zoned times by value" {
    try inModes("inline temporal", &modes, checkInlineTemporal);
}

// ---------------------------------------------------------------------------
// The server's streaming node scan (node_scan_stream), a persisted deployment
// ---------------------------------------------------------------------------

/// Rows the fast-path stream serves for `src`; it must not decline.
fn streamRows(h: *harness.Harness, src: []const u8, names: []const []const u8, values: []const Value) !usize {
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const q = try harness.parseQuery(&qa, src);
    var stream = (try node_scan_stream.prepare(testing.allocator, q, h.ctx, names, values, &.{})) orelse return error.FastPathDeclined;
    defer stream.deinit();
    var rows: usize = 0;
    while (true) {
        var page = try stream.buildNextPage(testing.allocator, 0);
        defer page.result.deinit(testing.allocator);
        rows += page.result.rows.len;
        if (page.final) break;
    }
    return rows;
}

test "SONNY-2806: the streaming node scan matches a stored number by value" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.seed(&.{
        "CREATE (:ST {x: 1})",
        "CREATE (:SD {x: 1.5})",
        "CREATE (:SJ {x: 2.0})",
        "CREATE (:SV {v: duration('P1D')})",
    });
    {
        var parsed = try geode.parseGql("CREATE (:SF {x: $d})", aa);
        defer parsed.deinit();
        var ctx = h.ctx;
        ctx.query_param_names = &.{"d"};
        ctx.query_param_values = &.{.{ .Double = 1.5 }};
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        r.deinit(aa);
    }
    const names = [_][]const u8{"d"};
    const dbl = [_]Value{.{ .Double = 1.5 }};
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:ST {x: 1.0}) RETURN n.x", &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:ST {x: 1}) RETURN n.x", &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SD {x: 1.50}) RETURN n.x", &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SD {x: $d}) RETURN n.x", &names, &dbl));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SF {x: $d}) RETURN n.x", &names, &dbl));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SF {x: 1.5}) RETURN n.x", &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SJ {x: 2}) RETURN n.x", &.{}, &.{}));
    const iv_names = [_][]const u8{"iv"};
    const pt24h = [_]Value{.{ .Interval = .{ .months = 0, .days = 0, .micros = 24 * 3600 * std.time.us_per_s } }};
    try testing.expectEqual(@as(usize, 1), try streamRows(&h, "MATCH (n:SV {v: $iv}) RETURN n.v", &iv_names, &pt24h));
    try testing.expectEqual(@as(usize, 0), try streamRows(&h, "MATCH (n:ST {x: 1.5}) RETURN n.x", &.{}, &.{}));
}

// ---------------------------------------------------------------------------
// SONNY-2807: the planned read's WHERE seek agrees with `=` past 2^53
// ---------------------------------------------------------------------------

fn checkWhereSeekPast2p53(s: *Session, f: *Failures) !void {
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    try s.double("CREATE (:B53 {x: $v})", 9007199254740992.0);
    try s.exec("CREATE (:B53 {x: 9007199254740992})", &.{});
    // SONNY-2807: `=` compares a DOUBLE with an integer exactly, as GROUP BY
    // does (ISO/IEC 39075 19.3 GR 3a: by numerical value): 2^53 + 1 is not
    // the double 2^53. The count, the rows and the exact-index seek agree.
    try expectRows(s, f, "MATCH (n:B53) RETURN n.x = 9007199254740993 AS eq", &.{}, &.{ "false", "false" });
    try expectValue(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740993 RETURN count(n) AS c", "0");
    try expectRows(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740993 RETURN n.x AS x", &.{}, &.{});
    try expectRows(s, f, "MATCH (n:B53) WHERE 9007199254740993 = n.x RETURN n.x AS x", &.{}, &.{});
    try expectRows(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740992 RETURN n.x AS x", &.{}, &.{ "9007199254740992", "9007199254740992d" });
    try expectRows(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740994 RETURN n.x AS x", &.{}, &.{});
    // An inline map compares exactly, as GROUP BY does.
    try expectRows(s, f, "MATCH (n:B53 {x: 9007199254740993}) RETURN n.x AS x", &.{}, &.{});
    try expectRows(s, f, "MATCH (n:B53 {x: 9007199254740992}) RETURN n.x AS x", &.{}, &.{ "9007199254740992", "9007199254740992d" });
}

test "SONNY-2807: a WHERE equality seek agrees with an exact = past 2^53" {
    try inModes("where seek past 2^53", &eval_modes, checkWhereSeekPast2p53);
}
