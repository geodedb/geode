// Shared session harness for the value-semantics regressions (SONNY-2807,
// SONNY-3055, SONNY-2796, SONNY-2797, SONNY-2808): a query runs through the
// real parser, planner and executor on an in-memory store (the legacy
// executor) or a persisted one (the planned read and the fast paths), and the
// rows it returns are compared, typed, with the expected ones. Every failed
// check is collected and reported together.
//
// Adapted from tests/test_sonny2806_exact_property_matching.zig's session.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
pub const Value = geode.value_types.Value;
pub const silenceEngineLogs = harness.silenceEngineLogs;

/// Which executor serves the session's reads.
pub const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, tenant-scoped: the legacy executor and the tenant-filtered
    /// fast paths.
    tenant_scoped,
    /// Persisted, no tenant: the planned read and the fast paths, which read
    /// the storage engine directly (the node cache is bounded).
    persisted,
    /// The same with an unbounded node cache (`GEODE_NODE_CACHE_ENTRIES=0`).
    unbounded_cache,
};

pub const all_modes = [_]Mode{ .in_memory, .tenant_scoped, .persisted, .unbounded_cache };
/// The expression checks do not depend on the executor: a legacy session and
/// the planned read.
pub const eval_modes = [_]Mode{ .in_memory, .persisted };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Param = struct { name: []const u8, value: Value };

pub const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,

    pub fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        if (mode == .unbounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
        }
        errdefer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
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
        // The catalog is kept in the temporary directory in every mode (see
        // tests/test_sonny2806_exact_property_matching.zig).
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

    /// Closes the persisted store and opens it again from its data
    /// directory, as a server restart does.
    pub fn reopen(self: *Session) !void {
        if (self.mode == .in_memory) return error.NotPersisted;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, self.data_dir.?);
        self.ctx.catalog = try execution.ensureCatalogInstance(testing.allocator);
        _ = graph_store.getGlobalStore(testing.allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
    }

    pub fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    pub fn run(self: *Session, query: []const u8, params: []const Param) !execution.ExecutionResult {
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
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    pub fn exec(self: *Session, query: []const u8, params: []const Param) !void {
        var r = try self.run(query, params);
        r.deinit(self.arena.allocator());
    }
};

/// A cell, with its type visible: 'text' for a string, `1.5d` for a double,
/// `1.25m` for a decimal, `null`; a temporal value or a duration as the
/// server's response encoder writes it.
pub fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    var buf: [64]u8 = undefined;
    return switch (cell) {
        .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| if (@abs(d) >= 1e21)
            try std.fmt.allocPrint(aa, "{e}d", .{d})
        else
            try std.fmt.allocPrint(aa, "{d}d", .{d}),
        .Decimal => try std.fmt.allocPrint(aa, "{s}m", .{try geode.value_types.stringify(cell, &buf)}),
        .Date, .Timestamp, .Time, .TimestampTZ, .TimeTZ, .Interval => try aa.dupe(u8, try geode.value_types.stringify(cell, &buf)),
        .ExtValue => |ext| switch (ext) {
            .Date => |d| try renderCell(aa, .{ .Date = d }),
            .Time => |t| try renderCell(aa, .{ .Time = t }),
            .TimeTZ => |t| try renderCell(aa, .{ .TimeTZ = t }),
            .Timestamp => |t| try renderCell(aa, .{ .Timestamp = t }),
            .TimestampTZ => |t| try renderCell(aa, .{ .TimestampTZ = t }),
            .Interval => |iv| try renderCell(aa, .{ .Interval = iv }),
            .Double => |d| try renderCell(aa, .{ .Double = d }),
            else => try std.fmt.allocPrint(aa, "<ext {s}>", .{@tagName(ext)}),
        },
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

pub fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
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
pub const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    pub fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    pub fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.ChecksFailed;
    }
};

/// `query` returns exactly `want` (rows rendered by `renderRow`), in any
/// order, or in this order when `ordered`.
fn expectRowsImpl(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const []const u8, ordered: bool) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, params) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    // Encode every cell as the server's response does.
    for (result.rows) |row| {
        for (row) |cell| _ = try geode.proto_util.valueToProto(aa, cell);
    }
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = try renderRow(aa, row);
    const exp = try aa.dupe([]const u8, want);
    if (!ordered) {
        std.mem.sort([]const u8, got, {}, lessThan);
        std.mem.sort([]const u8, exp, {}, lessThan);
    }
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        const want_text = try std.mem.join(aa, " | ", exp);
        const got_text = try std.mem.join(aa, " | ", got);
        try f.add("[{s}] {s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ @tagName(s.mode), query, exp.len, want_text, got.len, got_text });
    }
}

pub fn expectRows(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const []const u8) !void {
    return expectRowsImpl(s, f, query, params, want, false);
}

pub fn expectOrdered(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const []const u8) !void {
    return expectRowsImpl(s, f, query, params, want, true);
}

/// `query` returns the single cell `want`.
pub fn expectValue(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: []const u8) !void {
    return expectRowsImpl(s, f, query, params, &.{want}, false);
}

/// `query` fails with `want`.
pub fn expectFail(s: *Session, f: *Failures, query: []const u8, params: []const Param, want: anyerror) !void {
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

/// Run `checks` in a fresh session of each of `which`.
pub fn inModes(name: []const u8, which: []const Mode, comptime checks: fn (*Session, *Failures) anyerror!void) !void {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (which) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try checks(&s, &f);
    }
    try f.check(name);
}
