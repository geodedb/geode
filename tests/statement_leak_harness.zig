// Shared harness for leak-checked and allocation-failure-swept statements
// (SONNY-738 query-memory sweep: SONNY-6297, SONNY-3126, SONNY-3378,
// SONNY-2669, SONNY-3148, SONNY-6483).
//
// A `Session` is one of the four deployments the executor serves a statement
// in: in memory (the legacy executor), persisted (the planned read and its
// fast paths), persisted with a session tenant, and persisted with an RLS
// deny policy (both the legacy executor). Rows the session may not see are
// seeded beside the visible ones.
//
// `run` executes one statement as a transport does (the query scratch arena
// installed) or as an embedded caller does (none installed: the entry point
// opens its own), on its own leak-checking allocator, and renders every cell
// before the result is released, so a cell that points into freed memory
// reads wrong. `sweep` runs a statement embedded with its N-th allocation
// failing, for N = 0, 1, ... until it runs without reaching a failure: every
// run must leak nothing, and must either succeed or fail with OutOfMemory.
//
// No mocks: every statement goes through `execution.executeStatementWithContext`.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_arena = geode.query_arena;
pub const Value = geode.value_types.Value;

pub const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, no tenant, no policy: the planned read and its fast paths.
    persisted,
    /// Persisted, session tenant `tenant_a`: the legacy executor.
    tenant_scoped,
    /// Persisted, the user may not read `:Hidden`: the legacy executor.
    rls_policy,
};

pub const modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

pub const Param = struct { name: []const u8, value: Value };

/// How a statement runs: with the query scratch arena a transport installs,
/// or embedded, the entry point opening its own.
pub const Install = enum { scratch, embedded };

pub const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    pub fn init(mode: Mode) !Session {
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
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    pub fn deinit(self: *Session) void {
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

    /// One statement, the context installed, the result on `allocator`.
    pub fn exec(self: *Session, allocator: std.mem.Allocator, query: []const u8, params: []const Param) !execution.ExecutionResult {
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
        var r = self.exec(self.arena.allocator(), query, &.{}) catch |err| {
            std.debug.print("seeding [{s}] {s}: {s}\n", .{ @tagName(self.mode), query, @errorName(err) });
            return err;
        };
        r.deinit(self.arena.allocator());
    }

    /// Seed: `visible` as the session's own rows; `hidden` (each with a
    /// `{H}` placeholder for a label) as rows the session may not read: the
    /// other tenant's in a tenant-scoped session, `:Hidden` ones in an RLS
    /// session, none otherwise. Then the session's tenant and user are set.
    pub fn seed(self: *Session, visible: []const []const u8, hidden: []const []const u8) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) "tenant_a" else null;
        switch (self.mode) {
            .tenant_scoped => for (hidden) |q| try self.execAs("tenant_b", try std.mem.replaceOwned(u8, aa, q, "{H}", "")),
            .rls_policy => for (hidden) |q| try self.execAs(null, try std.mem.replaceOwned(u8, aa, q, "{H}", ":Hidden")),
            else => {},
        }
        for (visible) |q| try self.execAs(own, q);
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

/// A cell, its type visible: 'text', `12.5d` for a double, a list in its
/// order (sorted when `sort_lists`), a map with its keys sorted, a node or a
/// relationship by its properties, a path by its length.
pub fn renderCell(aa: std.mem.Allocator, cell: Value, sort_lists: bool) anyerror![]const u8 {
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
        .Node => |n| try std.fmt.allocPrint(aa, "(:{s})", .{try std.mem.join(aa, ":", n.labels)}),
        .Path => |p| try std.fmt.allocPrint(aa, "<path {d}>", .{p.edges.len}),
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

pub const Outcome = struct {
    /// Each row's cells joined by `, `; null on an error.
    rows: ?[]const []const u8,
    err: ?anyerror,
    leaked: bool,
};

/// Run `query` on its own leak-checking allocator; every cell is rendered
/// before the result is released.
pub fn run(s: *Session, install: Install, query: []const u8, params: []const Param, sort_lists: bool) !Outcome {
    const aa = s.arena.allocator();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var out: Outcome = .{ .rows = null, .err = null, .leaked = false };
    {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        const prev = if (install == .scratch) query_arena.pushScratchAllocator(scratch.allocator()) else null;
        defer if (install == .scratch) query_arena.popScratchAllocator(prev);
        if (s.exec(gpa.allocator(), query, params)) |result_const| {
            var result = result_const;
            defer result.deinit(gpa.allocator());
            const rows = try aa.alloc([]const u8, result.rows.len);
            for (result.rows, rows) |row, *r| {
                const n = @min(row.len, result.columns.len);
                const cells = try aa.alloc([]const u8, n);
                for (row[0..n], cells) |cell, *t| t.* = try renderCell(aa, cell, sort_lists);
                r.* = try std.mem.join(aa, ", ", cells);
            }
            out.rows = rows;
        } else |err| out.err = err;
    }
    out.leaked = gpa.deinit() == .leak;
    return out;
}

pub const SweepResult = struct {
    /// Runs made: failure indices 0 .. runs - 2 hit a failure, the last ran
    /// to completion (or `max_runs` was reached).
    runs: usize = 0,
    /// Failure indices at which the run leaked.
    leaks: std.ArrayList(usize) = .empty,
    /// Failure indices at which the run failed with an error other than
    /// OutOfMemory (an allocation failure reported as something else), and
    /// the error.
    wrong_errors: std.ArrayList(struct { usize, anyerror }) = .empty,
    /// Failure indices at which the run reached the failure and still
    /// answered successfully: the failure was swallowed.
    swallowed: std.ArrayList(usize) = .empty,
    completed: bool = false,
};

/// Run `query` embedded with its `n`-th allocation failing, n = 0, 1, ...,
/// until a run reaches no failure (or `max_runs`). Every run's cells are
/// rendered before release.
pub fn sweep(s: *Session, query: []const u8, params: []const Param, max_runs: usize) !SweepResult {
    const aa = s.arena.allocator();
    var res: SweepResult = .{};
    var n: usize = 0;
    while (n < max_runs) : (n += 1) {
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        var failing = std.testing.FailingAllocator.init(gpa.allocator(), .{ .fail_index = n });
        const fa = failing.allocator();
        var answered = false;
        var err_seen: ?anyerror = null;
        if (s.exec(fa, query, params)) |result_const| {
            var result = result_const;
            defer result.deinit(fa);
            answered = true;
            for (result.rows) |row| {
                const k = @min(row.len, result.columns.len);
                for (row[0..k]) |cell| _ = try renderCell(aa, cell, false);
            }
        } else |err| err_seen = err;
        const hit = failing.has_induced_failure;
        if (gpa.deinit() == .leak) try res.leaks.append(aa, n);
        res.runs += 1;
        if (err_seen) |err| {
            if (hit and err != error.OutOfMemory) try res.wrong_errors.append(aa, .{ n, err });
        } else if (hit and answered) {
            try res.swallowed.append(aa, n);
        }
        if (!hit) {
            res.completed = true;
            break;
        }
    }
    return res;
}
