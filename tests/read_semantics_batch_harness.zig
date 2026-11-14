//! The read-semantics batch harness (SONNY-2672 and its follow-ups): a
//! case list run in the in-memory, persisted (warm), tenant-scoped and
//! RLS-policy sessions through `executeProgramWithContext`, the entry the
//! QUIC and gRPC servers call, each statement on its own leak-checked
//! allocator with a query scratch arena installed. The fixture is described
//! in tests/test_sonny2672_read_semantics_batch.zig.
//!
//! SONNY-6437 item 8: this file has no `test` blocks. A test file that
//! imported the batch file itself for `Case` and `inEveryMode` ran the
//! batch's 13 tests again (about seven minutes per step); they import this
//! one. A test module that imports it also needs the `geode` and
//! `rls_types` modules.

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

pub const Param = struct { name: []const u8, value: Value };

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
        // The statement undo log: a failed write statement rolls back.
        _ = geode.txn_undo_log.getGlobalUndoLog(std.heap.page_allocator);
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
        // The server's parse options (src/server/quic_connection_handler.zig,
        // src/transport/grpc_server.zig): expression ORDER BY keys are the
        // default there (server_flags.g_order_keys_expr).
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        var ctx = self.ctx;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeProgramWithContext(allocator, &parsed.program, ctx);
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
        for (0..8) |k| try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:Z {{k: {d}, g: {d}, r: {d}}})", .{ k, k / 4, 7 - k }));
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

pub const Case = struct {
    q: []const u8,
    /// The rows, each rendered as `a, b`; in any order unless `ordered`.
    want: []const []const u8 = &.{},
    /// The rows must come in `want`'s order.
    ordered: bool = false,
    /// The statement must fail with this error instead.
    err: ?anyerror = null,
    /// The query's parameters.
    params: []const Param = &.{},
    /// The expected column names, when the case checks them.
    columns: ?[]const []const u8 = null,
    /// SONNY-6525: how many times the statement runs an expression
    /// subquery (`execution.subquery_cache.runCount`), when the case checks.
    subquery_runs: ?u64 = null,
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
    const result_allocator = gpa.allocator();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const names = try aa.alloc([]const u8, c.params.len);
    const values = try aa.alloc(Value, c.params.len);
    for (c.params, names, values) |p, *n, *v| {
        n.* = p.name;
        v.* = p.value;
    }
    s.ctx.query_param_names = names;
    s.ctx.query_param_values = values;
    defer {
        s.ctx.query_param_names = &.{};
        s.ctx.query_param_values = &.{};
    }
    var got_columns: []const []const u8 = &.{};
    const runs_before = execution.subquery_cache.runCount();
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
        const cols = try aa.alloc([]const u8, result.columns.len);
        for (result.columns, cols) |col, *cc| cc.* = try aa.dupe(u8, col);
        got_columns = cols;
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
    if (c.subquery_runs) |want_runs| {
        const runs = execution.subquery_cache.runCount() - runs_before;
        if (runs != want_runs) try f.add("[{s}] {s}: expected {d} subquery runs, got {d}", .{ @tagName(s.mode), c.q, want_runs, runs });
    }
    const rows = got orelse return;
    if (c.err) |want| {
        try f.add("[{s}] {s}: expected error {s}, got {d} rows {{{s}}}", .{ @tagName(s.mode), c.q, @errorName(want), rows.len, try std.mem.join(aa, " | ", rows) });
        return;
    }
    if (c.columns) |want_cols| {
        const same_cols = want_cols.len == got_columns.len and for (want_cols, got_columns) |w, g| {
            if (!std.mem.eql(u8, w, g)) break false;
        } else true;
        if (!same_cols) try f.add("[{s}] {s}: expected columns {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), c.q, try std.mem.join(aa, ", ", want_cols), try std.mem.join(aa, ", ", got_columns) });
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

pub fn inEveryMode(name: []const u8, cases: []const Case) !void {
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

pub fn int(n: i64) Value {
    return .{ .Int = n };
}

pub const overflow = "9223372036854775807";
