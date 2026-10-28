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
//     asked for, and a DELETE after a SET (a DELETE the parser keeps in the
//     query) was never applied;
//   * the CREATE pattern's property values were evaluated without the
//     matched row, so `MATCH (n) CREATE (:Z {k: n.i})` wrote null.
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
// The SONNY-738 Task W fix round widened the matrix: a session with an RLS
// policy (hidden rows beside the seed, neither written nor counted), and the
// shapes the review found writes lost in: a WITH (and a WHERE after it), a
// RETURN with ORDER BY and LIMIT, a comma pattern and an OPTIONAL MATCH. It
// also checks that a DELETE's RETURN returns what it read, on the testing
// allocator: `DELETE r RETURN r.w`, type(r), keys(r) and collect(r.w)
// returned freed memory (a use after free; Debug fills it with 0xAA), and the
// typed strings it copied leaked.
//
// CANARY: REQ=REQ-SONNY-2694-WRITE-BEHIND-AGGREGATE; FEATURE="ReadFastPaths"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
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
    /// Persisted; the session's user `bob` may not read `:Hidden`, and hidden
    /// rows sit beside the seed that the session must neither write nor
    /// count.
    rls_policy,
};

const tenant_a = "tenant_a";
const tenant_b = "tenant_b";

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

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

    /// Run one statement, without installing the context as the active one:
    /// the statement must scope itself.
    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        return self.runOn(self.arena.allocator(), query);
    }

    /// `run`, with the result (and every allocation the statement makes)
    /// on `allocator`.
    fn runOn(self: *Session, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.arena.allocator());
        defer parsed.deinit();
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], self.ctx);
    }

    /// Run one statement as the server does: with the context installed.
    fn runInstalled(self: *Session, query: []const u8) !execution.ExecutionResult {
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return self.run(query);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        const saved_user = self.ctx.user;
        defer {
            self.ctx.tenant_id = saved;
            self.ctx.user = saved_user;
        }
        self.ctx.tenant_id = tenant;
        self.ctx.user = null;
        var r = try self.runInstalled(query);
        r.deinit(self.arena.allocator());
    }

    /// 10 `(:G {i, g, t: 1})-[:R {w}]->(:X {j, u: 1})` pairs, i = 0..9, g =
    /// 'a' for i < 5 and 'b' after (count 10, sum(i) 45, min 0, max 9, 3 rows
    /// with i >= 7), and 4 edge-free `(:Q {i, name})`. A tenant-scoped
    /// session's data belongs to `tenant_a`, and `tenant_b` holds 3 more G-R-X
    /// pairs, an `(:M {g: 'a'})` (which a MERGE on M must not bind) and 2
    /// `:Q`. The RLS session's user may not read `:Hidden`: a hidden G-R-X
    /// pair and a hidden `:Q` sit beside its data.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        if (self.mode == .tenant_scoped) {
            for (0..3) |j| try self.execAs(tenant_b, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a', t: 1}})-[:R {{w: 'other'}}]->(:X {{j: {d}, u: 1}})", .{ 100 + j, 100 + j }));
            try self.execAs(tenant_b, "CREATE (:M {g: 'a'})");
            for (0..2) |j| try self.execAs(tenant_b, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}, name: 'other'}})", .{100 + j}));
        }
        if (self.mode == .rls_policy) {
            try self.execAs(null, "CREATE (:G:Hidden {i: 100, g: 'a', t: 1})-[:R {w: 'hidden'}]->(:X:Hidden {j: 100, u: 1})");
            try self.execAs(null, "CREATE (:Q:Hidden {i: 100, name: 'hidden'})");
        }
        for (0..10) |i| {
            const g: []const u8 = if (i < 5) "a" else "b";
            try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}', t: 1}})-[:R {{w: 'edge-w-{d}-padpadpadpad'}}]->(:X {{j: {d}, u: 1}})", .{ i, g, i, i }));
        }
        for (0..4) |k| try self.execAs(own, try std.fmt.allocPrint(aa, "CREATE (:Q {{i: {d}, name: 'q-name-{d}-padpadpadpad'}})", .{ k, k }));
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
        // Copied: the value may be freed with its result before it is compared.
        .Str, .Text => |s| try aa.dupe(u8, s),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Double => |d| try std.fmt.allocPrint(aa, "{d}", .{d}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        // A list's items and a map's entries, sorted.
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *p| p.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ";", parts)});
        },
        .Map => |m| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = m.iterator();
            while (it.next()) |e| try parts.append(aa, try std.fmt.allocPrint(aa, "{s}:{s}", .{ e.key_ptr.*, try render(aa, e.value_ptr.*) }));
            std.mem.sort([]const u8, parts.items, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "{{{s}}}", .{try std.mem.join(aa, ";", parts.items)});
        },
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

/// The hidden rows after any case, read as no user: not written, not
/// deleted, not joined.
const hidden_untouched = [_]Check{
    .{ .query = "MATCH (n:Hidden) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.x IS NULL AND n.y IS NULL RETURN count(*) AS c", .want = &.{"3"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.t = 1 RETURN n.i", .want = &.{"100"} },
    .{ .query = "MATCH (n:Hidden) WHERE n.u = 1 RETURN n.j", .want = &.{"100"} },
    .{ .query = "MATCH (:Hidden)-[r:R]->(:Hidden) RETURN r.w", .want = &.{"hidden"} },
    .{ .query = "MATCH (:Hidden)-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (q:Hidden) WHERE q.name = 'hidden' RETURN q.i", .want = &.{"100"} },
};

fn checkHidden(s: *Session, f: *Failures, case: []const u8, stage: []const u8) !void {
    const saved = s.ctx.user;
    defer s.ctx.user = saved;
    s.ctx.user = null;
    for (hidden_untouched) |chk| try expectRows(s, f, stage, case, false, chk.query, chk.want);
}

fn runCase(mode: Mode, c: Case, f: *Failures) !void {
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const runs: usize = if (c.twice) 2 else 1;
    for (0..runs) |r| try expectRows(&s, f, if (r == 0) "returns" else "returns (second run)", c.write, true, c.write, c.want);
    for (c.checks) |chk| try expectRows(&s, f, "effect", c.write, false, chk.query, chk.want);
    if (mode == .tenant_scoped) try checkOtherTenant(&s, f, c.write, "other tenant");
    if (mode == .rls_policy) try checkHidden(&s, f, c.write, "hidden rows");
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        for (c.checks) |chk| try expectRows(&s, f, "effect after reload", c.write, false, chk.query, chk.want);
        if (mode == .tenant_scoped) try checkOtherTenant(&s, f, c.write, "other tenant after reload");
        if (mode == .rls_policy) try checkHidden(&s, f, c.write, "hidden rows after reload");
    }
}

fn runCases(title: []const u8, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for ([_]Mode{ .in_memory, .tenant_scoped, .persisted, .rls_policy }) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish(title);
}

// ---------------------------------------------------------------------------
// SET

const x10 = [_]Check{.{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN count(*) AS c", .want = &.{"10"} }};

const set_cases = [_]Case{
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &x10 },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN sum(n.i) AS s", .want = &.{"45"}, .checks = &x10 },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN min(n.i) AS lo", .want = &.{"0"}, .checks = &x10 },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN max(n.i) AS hi", .want = &.{"9"}, .checks = &x10 },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &x10 },
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 SET n.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) SET x.x = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) SET x.x = 1 RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
};

test "SONNY-2694: MATCH ... SET behind an aggregating or DISTINCT RETURN writes every matched row" {
    try runCases("SET", &set_cases);
}

// ---------------------------------------------------------------------------
// REMOVE

const t0 = [_]Check{.{ .query = "MATCH (n:G) WHERE n.t IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} }};

const remove_cases = [_]Case{
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN count(*) AS c", .want = &.{"10"}, .checks = &t0 },
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN sum(n.i) AS s", .want = &.{"45"}, .checks = &t0 },
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN min(n.i) AS lo", .want = &.{"0"}, .checks = &t0 },
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN max(n.i) AS hi", .want = &.{"9"}, .checks = &t0 },
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &t0 },
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 REMOVE n.t RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) REMOVE x.u RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.u IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) REMOVE x.u RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.u IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
};

test "SONNY-2694: MATCH ... REMOVE behind an aggregating or DISTINCT RETURN removes from every matched row" {
    try runCases("REMOVE", &remove_cases);
}

// ---------------------------------------------------------------------------
// CREATE

const z10 = [_]Check{
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (:G)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"} },
};

const create_cases = [_]Case{
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN sum(n.i) AS s", .want = &.{"45"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN min(n.i) AS lo", .want = &.{"0"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN max(n.i) AS hi", .want = &.{"9"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &z10 },
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 CREATE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"3"} },
        .{ .query = "MATCH (n:G)-[:T]->(:Z) RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // An aggregate over the created variable: one created node per row.
    .{ .write = "MATCH (n:G) CREATE (z:Z {k: n.i}) RETURN count(z) AS c, sum(z.k) AS s", .want = &.{"10|45"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c, sum(z.k) AS s", .want = &.{"10|45"} },
    } },
    // Through a relationship pattern.
    .{ .write = "MATCH (n:G)-[:R]->(x:X) CREATE (x)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (:X)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) CREATE (x)-[:T]->(:Z) RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &.{
        .{ .query = "MATCH (:X)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"} },
    } },
};

test "SONNY-2694: MATCH ... CREATE behind an aggregating or DISTINCT RETURN creates for every matched row and aggregates over them" {
    try runCases("CREATE", &create_cases);
}

// ---------------------------------------------------------------------------
// MERGE: once per matched row. A second run binds what the first created.

const m_ab = [_]Check{.{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } }};

const merge_cases = [_]Case{
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &m_ab, .twice = true },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN sum(n.i) AS s", .want = &.{"45"}, .checks = &m_ab, .twice = true },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN min(n.i) AS lo", .want = &.{"0"}, .checks = &m_ab },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN max(n.i) AS hi", .want = &.{"9"}, .checks = &m_ab },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &m_ab, .twice = true },
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"b"} },
    } },
    // An aggregate over the merged variable.
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN count(m) AS c, count(DISTINCT m.g) AS d", .want = &.{"10|2"}, .checks = &m_ab, .twice = true },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN DISTINCT m.g", .want = &.{ "a", "b" }, .checks = &m_ab },
    // A relationship MERGE, once per matched row.
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 MERGE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(:Z) RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // Through a relationship pattern.
    .{ .write = "MATCH (n:G)-[:R]->(x:X) MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &m_ab },
};

test "SONNY-2694: MATCH ... MERGE behind an aggregating or DISTINCT RETURN merges once per matched row and aggregates over them" {
    try runCases("MERGE", &merge_cases);
}

// ---------------------------------------------------------------------------
// DELETE: the RETURN is computed over the rows the statement matched.

const q0 = [_]Check{.{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"0"} }};

const delete_cases = [_]Case{
    .{ .write = "MATCH (q:Q) DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &q0 },
    .{ .write = "MATCH (q:Q) DELETE q RETURN sum(q.i) AS s", .want = &.{"6"}, .checks = &q0 },
    .{ .write = "MATCH (q:Q) DELETE q RETURN min(q.i) AS lo", .want = &.{"0"}, .checks = &q0 },
    .{ .write = "MATCH (q:Q) DELETE q RETURN max(q.i) AS hi", .want = &.{"3"}, .checks = &q0 },
    .{ .write = "MATCH (n:G) DETACH DELETE n RETURN DISTINCT n.g", .want = &.{ "a", "b" }, .checks = &.{
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = "MATCH (x:X) RETURN count(*) AS c", .want = &.{"10"} },
        .{ .query = "MATCH ()-[r:R]->() RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (q:Q) WHERE q.i >= 2 DELETE q RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "0", "1" } },
    } },
    // A relationship.
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) DELETE r RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
    } },
    // A DELETE after a SET is a query, not a DELETE statement.
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &q0 },
};

test "SONNY-2694: MATCH ... DELETE behind an aggregating or DISTINCT RETURN deletes every matched row and returns the aggregate over them" {
    try runCases("DELETE", &delete_cases);
}

// ---------------------------------------------------------------------------
// The shapes the Task W review found writes lost in (SONNY-3039, SONNY-3040,
// SONNY-3041): a WITH, a RETURN with ORDER BY and LIMIT, a comma pattern and
// an OPTIONAL MATCH, behind every write clause.

const q01 = [_]Check{.{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "0", "1" } }};

const with_cases = [_]Case{
    .{ .write = "MATCH (n:G) WITH n SET n.x = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &x10 },
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 REMOVE n.t RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G) WITH n CREATE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) WITH n MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &m_ab },
    .{ .write = "MATCH (q:Q) WITH q DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &q0 },
    .{ .write = "MATCH (q:Q) WITH q WHERE q.i >= 2 SET q.x = 1 DELETE q RETURN count(*) AS c", .want = &.{"2"}, .checks = &q01 },
};

test "SONNY-2694: every write clause after a WITH writes the rows the WITH keeps" {
    try runCases("WITH", &with_cases);
}

const order_limit_cases = [_]Case{
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN n.i AS i ORDER BY i LIMIT 2", .want = &.{ "0", "1" }, .checks = &x10 },
    .{ .write = "MATCH (n:G) REMOVE n.t RETURN n.i AS i ORDER BY i DESC LIMIT 1", .want = &.{"9"}, .checks = &t0 },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) SET x.x = 1 RETURN x.j AS j ORDER BY j LIMIT 2", .want = &.{ "0", "1" }, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN DISTINCT n.g AS g ORDER BY g LIMIT 1", .want = &.{"a"}, .checks = &z10 },
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q RETURN q.i AS i ORDER BY i LIMIT 1", .want = &.{"0"}, .checks = &q0 },
};

test "SONNY-2694: a RETURN with ORDER BY and LIMIT does not limit the write" {
    try runCases("ORDER BY / LIMIT", &order_limit_cases);
}

const comma_cases = [_]Case{
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1 RETURN count(*) AS c", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{"5"} },
    } },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 REMOVE a.t RETURN count(*) AS c", .want = &.{"4"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{"5"} },
    } },
    .{ .write = "MATCH (a:G), (b:G) WHERE a.i = 5 AND b.i = 6 CREATE (a)-[:T]->(b) RETURN count(*) AS c", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (a:G)-[:T]->(b:G) RETURN a.i, b.i", .want = &.{"5|6"} },
    } },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 MERGE (m:M {g: a.g}) RETURN count(*) AS c", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"b"} },
    } },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 SET q.x = 1 DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &q0 },
};

test "SONNY-2694: every write clause on a comma pattern writes every matched row" {
    try runCases("comma pattern", &comma_cases);
}

const optional_cases = [_]Case{
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) SET n.y = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.y = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:NOPE]->(y) CREATE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &m_ab },
    .{ .write = "MATCH (q:Q) OPTIONAL MATCH (q)-[:NOPE]->(y) SET q.x = 1 DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &q0 },
};

test "SONNY-2694: every write clause after an OPTIONAL MATCH writes every matched row" {
    try runCases("OPTIONAL MATCH", &optional_cases);
}

// ---------------------------------------------------------------------------
// A DELETE's RETURN returns what it read, on the testing allocator (the
// statement's every allocation too, so a leak fails the test).

const DeleteReturn = struct { write: []const u8, want: []const []const u8 };

const w_all = "[edge-w-0-padpadpadpad;edge-w-1-padpadpadpad;edge-w-2-padpadpadpad;edge-w-3-padpadpadpad;edge-w-4-padpadpadpad;edge-w-5-padpadpadpad;edge-w-6-padpadpadpad;edge-w-7-padpadpadpad;edge-w-8-padpadpadpad;edge-w-9-padpadpadpad]";

const delete_returns = [_]DeleteReturn{
    // A relationship's properties, type and keys.
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 DELETE r RETURN r.w AS w, type(r) AS t, keys(r) AS k", .want = &.{"edge-w-5-padpadpadpad|R|[w]"} },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 DELETE r RETURN properties(r) AS p", .want = &.{"{w:edge-w-5-padpadpadpad}"} },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) DELETE r RETURN collect(r.w) AS c", .want = &.{w_all} },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 SET r.z = 1 DELETE r RETURN r.w, r.z", .want = &.{"edge-w-5-padpadpadpad|1"} },
    // A node's.
    .{ .write = "MATCH (q:Q) DELETE q RETURN q.name AS n", .want = &.{ "q-name-0-padpadpadpad", "q-name-1-padpadpadpad", "q-name-2-padpadpadpad", "q-name-3-padpadpadpad" } },
    .{ .write = "MATCH (q:Q) WHERE q.i = 1 DELETE q RETURN q.name, labels(q) AS l, keys(q) AS k, toUpper(q.name) AS u", .want = &.{"q-name-1-padpadpadpad|[Q]|[i;name]|Q-NAME-1-PADPADPADPAD"} },
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q RETURN collect(q.name) AS c", .want = &.{"[q-name-0-padpadpadpad;q-name-1-padpadpadpad;q-name-2-padpadpadpad;q-name-3-padpadpadpad]"} },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 DETACH DELETE n RETURN n.g, r.w, x.j", .want = &.{"b|edge-w-5-padpadpadpad|5"} },
};

test "SONNY-2694: a DELETE's RETURN returns the values it read, not freed memory, and frees what it copied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for ([_]Mode{ .in_memory, .tenant_scoped, .rls_policy }) |mode| {
        for (delete_returns) |c| {
            var s = try Session.init(mode);
            defer s.deinit();
            try s.seed();
            const aa = s.arena.allocator();
            const prev = execution.pushActiveContext(&s.ctx);
            defer execution.popActiveContext(prev);
            var result = s.runOn(testing.allocator, c.write) catch |err| {
                try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), c.write, @errorName(err) });
                continue;
            };
            // Rendered (copied into the session arena) before the result is
            // freed; a use after free reads the 0xAA fill.
            const got = try renderRows(aa, result);
            result.deinit(testing.allocator);
            if (!try sameRows(aa, got, c.want)) {
                try f.add("[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(mode), c.write, try std.mem.join(aa, ",", c.want), try std.mem.join(aa, ",", got) });
            }
        }
    }
    try f.finish("DELETE RETURN values");
}

test "SONNY-2694: a DELETE's RETURN of a typed string frees its copy" {
    // TEXT, CHAR, VARCHAR, BYTEA and JSON values are copied before the DELETE
    // frees the node; the copies were never freed. The result is on the
    // testing allocator, so a leak fails the test.
    var s = try Session.init(.in_memory);
    defer s.deinit();
    try s.seed();
    try s.execAs(null, "CREATE (:K {t: Text('hello'), c: Char('ab', 5), v: Varchar('ab', 5), b: Bytea('\\\\x0102ff'), j: Json('{\"a\": 1}')})");
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    var result = try s.runOn(testing.allocator, "MATCH (k:K) DELETE k RETURN k.t, k.c, k.v, k.b, k.j, [k.t] AS l");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expectEqualStrings("hello", result.rows[0][0].Text);
}

// ---------------------------------------------------------------------------
// The guard itself: one structural check, every read fast path.

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
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
