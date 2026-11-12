//! SONNY-738 Task W fix round: the session, seed and checks that the write
//! regressions share (SONNY-3039, SONNY-3040, SONNY-3041, SONNY-3042,
//! SONNY-3043). A test module that imports this file also needs the `geode`,
//! `logging` and `rls_types` modules.
//!
//! Every case runs the write as the session and then reads its effect back.
//! Four sessions: an in-memory store; a plain persisted session (the default
//! server: no tenant, no row-level security); a persisted, tenant-scoped
//! session whose other tenant holds a copy of the graph; and a persisted
//! session whose user may not read `:Hidden`, with hidden rows beside the
//! seed. The last two also check that the rows the session may not see were
//! neither written nor deleted, and a persisted store is read back again
//! after a checkpoint and a reload from the engine.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

pub const execution = geode.execution;
pub const graph_store = geode.graph_store;
pub const Value = geode.value_types.Value;

pub const Mode = enum {
    /// No storage adapter.
    in_memory,
    /// SONNY-3146 (reopened): persisted, no tenant, no policy: the default
    /// server. A path DELETE deleted nothing here only.
    persisted,
    /// Persisted, session tenant `tenant_a`; `tenant_b` holds rows the
    /// session must neither write nor count.
    tenant_scoped,
    /// Persisted; the session's user `bob` may not read `:Hidden`, and hidden
    /// rows sit beside the seed.
    rls_policy,
};

pub const all_modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

pub const tenant_a = "tenant_a";
pub const tenant_b = "tenant_b";

pub const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    pub fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(allocator, null);
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        // The in-memory mode still gives the catalog a data directory of its
        // own, so index DDL persists there while the graph's storage adapter
        // stays disabled. (With no data directory at all the catalogs are in
        // memory: SONNY-2795 for the index catalog, SONNY-6274 for the FLE
        // catalog; neither falls back to a shared /tmp file any more.)
        tmp = std.testing.tmpDir(.{});
        data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
        const persisted = mode != .in_memory;
        if (persisted) {
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        graph_store.setDataDirOverride(allocator, data_dir.?);
        defer if (!persisted) graph_store.setDataDirOverride(allocator, null);
        const catalog = try execution.ensureCatalogInstance(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
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
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    /// Run one statement as the server does, with the context installed; the
    /// result is allocated with `allocator`.
    pub fn runWith(self: *Session, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.arena.allocator());
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], self.ctx);
    }

    pub fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        return self.runWith(self.arena.allocator(), query);
    }

    /// Run as `tenant` and `user`, restoring the session's own after.
    pub fn execAs(self: *Session, tenant: ?[]const u8, user: ?[]const u8, query: []const u8) !void {
        const saved_tenant = self.ctx.tenant_id;
        const saved_user = self.ctx.user;
        defer {
            self.ctx.tenant_id = saved_tenant;
            self.ctx.user = saved_user;
        }
        self.ctx.tenant_id = tenant;
        self.ctx.user = user;
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// 10 `(:G {i, g, t: 1})-[:R {w}]->(:X {j, u: 1})` pairs, i = 0..9, g =
    /// 'a' for i < 5 and 'b' after (count 10, sum(i) 45, 3 rows with i >= 7),
    /// and 4 edge-free `(:Q {i, name})`. A tenant-scoped session's data is
    /// `tenant_a`'s, and `tenant_b` holds 3 more G-R-X pairs, an `(:M {g:
    /// 'a'})` and 2 `:Q`. The RLS session's data has no tenant, and a hidden
    /// `(:G:Hidden)-[:R]->(:X:Hidden)` pair and `(:Q:Hidden)` sit beside it.
    pub fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        if (self.mode == .tenant_scoped) {
            for (0..3) |j| try self.execAs(tenant_b, null, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a', t: 1}})-[:R {{w: 'other-{d}'}}]->(:X {{j: {d}, u: 1}})", .{ 100 + j, j, 100 + j }));
            try self.execAs(tenant_b, null, "CREATE (:M {g: 'a'})");
            for (0..2) |j| try self.execAs(tenant_b, null, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}, name: 'other-{d}'}})", .{ 100 + j, j }));
        }
        if (self.mode == .rls_policy) {
            try self.execAs(null, null, "CREATE (:G:Hidden {i: 100, g: 'a', t: 1})-[:R {w: 'hidden'}]->(:X:Hidden {j: 100, u: 1})");
            try self.execAs(null, null, "CREATE (:Q:Hidden {i: 100, name: 'hidden'})");
        }
        for (0..10) |i| {
            const g: []const u8 = if (i < 5) "a" else "b";
            try self.execAs(own, null, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}', t: 1}})-[:R {{w: 'w-{d}'}}]->(:X {{j: {d}, u: 1}})", .{ i, g, i, i }));
        }
        for (0..4) |k| try self.execAs(own, null, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}, name: 'q-{d}'}})", .{ k, k }));
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

    /// Drop the in-memory graph and reload it from the engine (persisted
    /// modes only).
    pub fn reopen(self: *Session) !void {
        if (self.mode == .in_memory) return;
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
        try graph_store.getGlobalStore(testing.allocator).loadFromFile();
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        // Copied: the value may be freed with its result before it is compared.
        .Str, .Text => |s| try aa.dupe(u8, s),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| try std.fmt.allocPrint(aa, "{d}", .{d}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *p| p.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ";", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// The rows of a result as `a|b` strings, sorted.
pub fn renderRows(aa: std.mem.Allocator, result: execution.ExecutionResult) ![]const []const u8 {
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

/// Every failed check, reported together. The messages outlive the sessions
/// (each case's session arena is freed when the case ends), so they live in
/// the test's own arena.
pub const Failures = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    pub fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.WriteWrong;
    }
};

fn sameRows(aa: std.mem.Allocator, got: []const []const u8, want: []const []const u8) !bool {
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    if (got.len != exp.len) return false;
    for (got, exp) |g, w| if (!std.mem.eql(u8, g, w)) return false;
    return true;
}

/// `query`, run as the session, returns exactly `want`.
pub fn expectRows(s: *Session, f: *Failures, stage: []const u8, case: []const u8, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query) catch |err| {
        try f.add("[{s}] {s} | {s}: {s}: expected {{{s}}}, got error {s}", .{ @tagName(s.mode), case, stage, query, try std.mem.join(aa, ",", want), @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const got = try renderRows(aa, result);
    if (!try sameRows(aa, got, want)) {
        const exp = try aa.dupe([]const u8, want);
        std.mem.sort([]const u8, exp, {}, lessThan);
        try f.add("[{s}] {s} | {s}: {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), case, stage, query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
    }
}

/// `query`, run as the session's tenant with no user (so no policy hides
/// what was written), returns exactly `want`.
pub fn expectEffect(s: *Session, f: *Failures, stage: []const u8, case: []const u8, query: []const u8, want: []const []const u8) !void {
    const saved = s.ctx.user;
    defer s.ctx.user = saved;
    s.ctx.user = null;
    try expectRows(s, f, stage, case, query, want);
}

pub const Check = struct { query: []const u8, want: []const []const u8 };

pub const Case = struct {
    /// The write, run as the session.
    write: []const u8,
    /// What it returns (null: not checked).
    want: ?[]const []const u8 = null,
    /// When set, the write must fail with this error, and the checks show
    /// that nothing changed.
    refused: ?anyerror = null,
    /// Its effect, read back as the session after it (and after a reload
    /// when persisted).
    checks: []const Check = &.{},
};

/// The rows the session may not see, after any case: not written, not
/// deleted, not joined. Tenant mode reads them as `tenant_b`; RLS mode as no
/// user, through their `:Hidden` label.
const other_tenant_untouched = [_]Check{
    .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:G) WHERE n.t = 1 AND n.x IS NULL AND n.y IS NULL AND n.c IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (x:X) WHERE x.u = 1 AND x.x IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.z IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH ()-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"a"} },
    .{ .query = "MATCH (q:Q) WHERE q.x IS NULL RETURN count(*) AS c", .want = &.{"2"} },
};

const hidden_untouched = [_]Check{
    .{ .query = "MATCH (n:Hidden) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.x IS NULL AND n.y IS NULL AND n.c IS NULL AND n.k IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.t = 1 RETURN n.i", .want = &.{"100"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.u = 1 RETURN n.j", .want = &.{"100"} },
    .{ .query = "MATCH (:Hidden)-[r:R]->(:Hidden) WHERE r.z IS NULL RETURN r.w", .want = &.{"hidden"} },
    .{ .query = "MATCH (:Hidden)-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (h:Hidden)<-[r:T]-() RETURN count(*) AS c", .want = &.{"0"} },
};

pub fn checkOthersUntouched(s: *Session, f: *Failures, case: []const u8, stage: []const u8) !void {
    switch (s.mode) {
        .in_memory, .persisted => {},
        .tenant_scoped => {
            const saved = s.ctx.tenant_id;
            defer s.ctx.tenant_id = saved;
            s.ctx.tenant_id = tenant_b;
            for (other_tenant_untouched) |chk| try expectEffect(s, f, stage, case, chk.query, chk.want);
        },
        .rls_policy => for (hidden_untouched) |chk| try expectEffect(s, f, stage, case, chk.query, chk.want),
    }
}

pub fn runCase(mode: Mode, c: Case, f: *Failures) !void {
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();
    if (c.refused) |want_err| {
        if (s.run(c.write)) |r| {
            var result = r;
            const got = try renderRows(aa, result);
            result.deinit(aa);
            try f.add("[{s}] {s}: expected error {s}, got {{{s}}}", .{ @tagName(mode), c.write, @errorName(want_err), try std.mem.join(aa, ",", got) });
        } else |err| if (err != want_err) {
            try f.add("[{s}] {s}: expected error {s}, got error {s}", .{ @tagName(mode), c.write, @errorName(want_err), @errorName(err) });
        }
    } else if (c.want) |want| {
        try expectRows(&s, f, "returns", c.write, c.write, want);
    } else {
        var result = s.run(c.write) catch |err| {
            try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        result.deinit(aa);
    }
    for (c.checks) |chk| try expectRows(&s, f, "effect", c.write, chk.query, chk.want);
    try checkOthersUntouched(&s, f, c.write, "others");
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        for (c.checks) |chk| try expectRows(&s, f, "effect after reload", c.write, chk.query, chk.want);
        try checkOthersUntouched(&s, f, c.write, "others after reload");
    }
}

pub fn runCases(title: []const u8, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for (all_modes) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish(title);
}
