// SONNY-2694 regression: a write behind an aggregating or DISTINCT RETURN was
// silently dropped.
//
// The read fast paths (the node and edge counts, the filtered count, the
// sum/avg/min/max aggregate, the index-served and streaming GROUP BY /
// DISTINCT, the top-K and the ordered scan) run before the write dispatch and
// declined only a SET or a REMOVE, so they answered a CREATE, MERGE or DELETE
// by reading and wrote nothing: `MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN
// count(*)` returned the count and created no :Z. Behind them the executors
// were wrong as well:
//   * MATCH ... CREATE and MATCH ... MERGE read their bindings from the
//     RETURN's own projection, so an aggregating RETURN (one row) created or
//     merged once, or not at all, and returned a count of 1, and a MERGE ran
//     once per RETURN row;
//   * the legacy non-grouped aggregate branch applied a SET but had no REMOVE
//     loop, and the relationship and variable-length aggregate branches
//     applied neither;
//   * a DELETE's RETURN returned the number of deleted nodes whatever it
//     asked for.
//
// Every write clause (CREATE, MERGE, SET, REMOVE, DELETE) runs behind each
// RETURN shape a fast path answered: count(*), sum, min, max, DISTINCT and a
// count behind a WHERE, plus a relationship pattern and, for CREATE and MERGE,
// an aggregate over the created or merged variable. Each case runs on an
// in-memory store, a tenant-scoped session and a persisted deployment, and
// checks both what the statement returns and its effect, read back after the
// statement and, on a persisted store, again after a checkpoint and a reload
// from the engine. The tenant-scoped session also checks that another
// tenant's rows were neither written nor counted.
//
// CANARY: REQ=REQ-SONNY-2694-WRITE-BEHIND-AGGREGATE; FEATURE="ReadFastPaths"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const Mode = enum {
    /// No storage adapter.
    in_memory,
    /// Persisted, session tenant `tenant_a`; `tenant_b` holds rows the
    /// session must neither write nor count.
    tenant_scoped,
    /// Persisted, no tenant scope and no policy: the deployment the planned
    /// read and every fast path serve.
    persisted,
};

const tenant_a = "tenant_a";
const tenant_b = "tenant_b";

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
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
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    /// Run one statement, without installing the context as the active one:
    /// the statement must scope itself.
    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run one statement as the server does: with the context installed.
    fn runInstalled(self: *Session, query: []const u8) !execution.ExecutionResult {
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return self.run(query);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        var r = try self.runInstalled(query);
        r.deinit(self.arena.allocator());
    }

    /// 10 `(:G {i, g, t: 1})-[:R]->(:X {j, u: 1})` pairs, i = 0..9, g = 'a'
    /// for i < 5 and 'b' after (count 10, sum(i) 45, min 0, max 9, 3 rows
    /// with i >= 7), and 4 edge-free `(:Q {i})`. A tenant-scoped session's
    /// data belongs to `tenant_a`, and `tenant_b` holds 3 more G-R-X pairs,
    /// an `(:M {g: 'a'})` (which a MERGE on M must not bind) and 2 `:Q`.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        if (self.mode == .tenant_scoped) {
            for (0..3) |j| try self.execAs(tenant_b, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a', t: 1}})-[:R]->(:X {{j: {d}, u: 1}})", .{ 100 + j, 100 + j }));
            try self.execAs(tenant_b, "CREATE (:M {g: 'a'})");
            for (0..2) |j| try self.execAs(tenant_b, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}}})", .{100 + j}));
        }
        for (0..10) |i| {
            const g: []const u8 = if (i < 5) "a" else "b";
            try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}', t: 1}})-[:R]->(:X {{j: {d}, u: 1}})", .{ i, g, i }));
        }
        for (0..4) |k| try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}}})", .{k}));
        self.ctx.tenant_id = own;
    }

    /// Drop the in-memory graph and reload it from the engine (persisted
    /// modes only).
    fn reopen(self: *Session) !void {
        if (self.mode == .in_memory) return;
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
        try graph_store.getGlobalStore(testing.allocator).loadFromFile();
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| try std.fmt.allocPrint(aa, "{d}", .{d}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// The rows of a result as `a|b` strings, sorted.
fn renderRows(aa: std.mem.Allocator, result: execution.ExecutionResult) ![]const []const u8 {
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

/// Every failed check, reported together. The messages outlive the
/// sessions (each case's session arena is freed when the case ends), so they
/// live in the test's own arena.
const Failures = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.WriteBehindAggregateWrong;
    }
};

fn sameRows(aa: std.mem.Allocator, got: []const []const u8, want: []const []const u8) !bool {
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    if (got.len != exp.len) return false;
    for (got, exp) |g, w| if (!std.mem.eql(u8, g, w)) return false;
    return true;
}

/// `query` (run with `run` or `runInstalled`) returns exactly `want`.
fn expectRows(s: *Session, f: *Failures, stage: []const u8, case: []const u8, installed: bool, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = (if (installed) s.runInstalled(query) else s.run(query)) catch |err| {
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

const Check = struct { query: []const u8, want: []const []const u8 };

const Case = struct {
    /// The write, run with the session's context installed.
    write: []const u8,
    /// What it returns.
    want: []const []const u8,
    /// Its effect, read back after it (and after a reload when persisted).
    checks: []const Check,
    /// Run the write a second time: it returns `want` again and the checks
    /// still hold (a MERGE binds what the first run created).
    twice: bool = false,
};

/// The other tenant's rows after any case: not written, not deleted, not
/// joined by a MERGE.
const other_tenant_untouched = [_]Check{
    .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:G) WHERE n.t = 1 AND n.x IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (x:X) WHERE x.u = 1 AND x.x IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (:G)-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"a"} },
    .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"2"} },
};

fn checkOtherTenant(s: *Session, f: *Failures, case: []const u8, stage: []const u8) !void {
    const saved = s.ctx.tenant_id;
    defer s.ctx.tenant_id = saved;
    s.ctx.tenant_id = tenant_b;
    for (other_tenant_untouched) |chk| try expectRows(s, f, stage, case, false, chk.query, chk.want);
}

fn runCase(mode: Mode, c: Case, f: *Failures) !void {
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const runs: usize = if (c.twice) 2 else 1;
    for (0..runs) |r| try expectRows(&s, f, if (r == 0) "returns" else "returns (second run)", c.write, true, c.write, c.want);
    for (c.checks) |chk| try expectRows(&s, f, "effect", c.write, false, chk.query, chk.want);
    if (mode == .tenant_scoped) try checkOtherTenant(&s, f, c.write, "other tenant");
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        for (c.checks) |chk| try expectRows(&s, f, "effect after reload", c.write, false, chk.query, chk.want);
        if (mode == .tenant_scoped) try checkOtherTenant(&s, f, c.write, "other tenant after reload");
    }
}

fn runCases(title: []const u8, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for ([_]Mode{ .in_memory, .tenant_scoped, .persisted }) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish(title);
}

// ---------------------------------------------------------------------------
// The guard itself: one structural check, every read fast path.

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pathz: [4096]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = linux.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n_signed: isize = @bitCast(linux.read(fd, &chunk, chunk.len));
        if (n_signed < 0) return error.ReadFailed;
        if (n_signed == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n_signed)]);
    }
    return buf.toOwnedSlice(allocator);
}

test "SONNY-2694: the read fast paths decline every statement that writes, through one structural guard" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Each shape a read fast path answers, behind each write clause. The
    // guard must decline them all; the same shapes without the write must
    // stay eligible (the guard is not a blanket refusal).
    const reads = [_][]const u8{
        "MATCH (n:G) RETURN count(*)",
        "MATCH (n:G) RETURN sum(n.i)",
        "MATCH (n:G) RETURN DISTINCT n.g",
        "MATCH (n:G) WHERE n.i >= 7 RETURN count(*)",
    };
    const writes = [_][]const u8{
        "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN count(*)",
        "MATCH (n:G) CREATE (:Z) RETURN sum(n.i)",
        "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN DISTINCT n.g",
        "MATCH (n:G) WHERE n.i >= 7 MERGE (n)-[:T]->(:Z) RETURN count(*)",
        "MATCH (n:G) SET n.x = 1 RETURN count(*)",
        "MATCH (n:G) REMOVE n.t RETURN DISTINCT n.g",
        "MATCH (q:Q) SET q.x = 1 DELETE q RETURN count(*)",
        "MATCH (n:G) CALL db.labels() YIELD label RETURN count(*)",
    };
    for (reads) |src| {
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        try testing.expect(!execution.readFastPathDeclines(parsed.program.statements[0].Query));
    }
    for (writes) |src| {
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        if (!execution.readFastPathDeclines(parsed.program.statements[0].Query)) {
            std.debug.print("the guard admits a write: {s}\n", .{src});
            return error.GuardAdmitsWrite;
        }
    }

    // Every read fast path in match_operations.zig calls the guard (directly
    // or through the count analyses that call it), so a new fast path cannot
    // forget it.
    const source = try readFile(allocator, "src/execution/match_operations.zig");
    defer allocator.free(source);
    var paths: usize = 0;
    var it = std.mem.splitSequence(u8, source, "\npub fn ");
    _ = it.next();
    while (it.next()) |chunk| {
        const name_end = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const name = chunk[0..name_end];
        if (!std.mem.endsWith(u8, name, "FastPath")) continue;
        // The one write fast path, and the fast path the guard itself serves.
        if (std.mem.eql(u8, name, "pointWriteFastPath")) continue;
        paths += 1;
        const body_end = std.mem.indexOf(u8, chunk, "\n}\n") orelse chunk.len;
        const body = chunk[0..body_end];
        const guarded = std.mem.indexOf(u8, body, "readFastPathDeclinesWrite(") != null or
            std.mem.indexOf(u8, body, "analyzeCountFastPath(") != null or
            std.mem.indexOf(u8, body, "analyzeEdgeCountFastPath(") != null;
        if (!guarded) {
            std.debug.print("read fast path {s} does not call the write guard\n", .{name});
            return error.FastPathUnguarded;
        }
    }
    try testing.expect(paths >= 9);
    // The count analyses call it.
    for ([_][]const u8{ "fn analyzeCountFastPath(", "fn analyzeEdgeCountFastPath(" }) |decl| {
        const at = std.mem.indexOf(u8, source, decl) orelse return error.AnalysisMissing;
        const body_end = std.mem.indexOfPos(u8, source, at, "\n}\n") orelse return error.AnalysisMissing;
        try testing.expect(std.mem.indexOf(u8, source[at..body_end], "readFastPathDeclinesWrite(") != null);
    }
}
