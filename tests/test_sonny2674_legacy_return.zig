// SONNY-2674 regression: the legacy executor's RETURN got grouping, HAVING
// and a WHERE after RETURN wrong.
//
// The legacy executor serves every read the planned read does not: in-memory
// stores, sessions with an RLS policy, and tenant-scoped sessions. Its RETURN
// had its own grouping code per pattern shape, and on these features:
//   * a WHERE after RETURN (which the parser stores as HAVING) was ignored;
//   * a GROUP BY with no aggregate did not group;
//   * a HAVING was replaced by "the group has at least two rows" in two of the
//     grouping paths, and evaluated over the output row alone in another, so a
//     HAVING on a key or an alias misfired.
//
// A RETURN-level GROUP BY, and a WHERE after RETURN, now go through the same
// shared projection the planned read and every WITH stage use
// (`executeWithClauseWithGroupByAndParams`). The legacy executor reads the
// bindings; the shared projection groups, applies the HAVING, and projects;
// DISTINCT and ORDER BY follow. The expected rows come from the seed, and each
// query must be served by the legacy executor (the planned read materializes
// nothing).
//
// CANARY: REQ=REQ-SONNY-2674-LEGACY-RETURN; FEATURE="LegacyReturnProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2674_legacy_return.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

/// How the session reaches the legacy executor. `persisted` (no policy, no
/// tenant) reaches it only through a caller of the executor itself, as
/// executeQueryWithBindingsImpl and VALUES ... MATCH are.
const Mode = enum { in_memory, rls_policy, tenant_scoped, persisted };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
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

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// The data every mode sees: 25 `(:G {i, g, s})-[:R]->(:X)` pairs with
    /// g = 'a' for i = 0..9, 'b' for 10..19 and 'c' for 20..24, and 2 `:Y`
    /// nodes. Then the mode's own setup: a tenant-scoped session also has
    /// another tenant's `:G` nodes it must not see, and an RLS session has a
    /// policy (on another label) so it is served by the legacy executor.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        if (self.mode == .tenant_scoped) {
            self.ctx.tenant_id = "tenant_b";
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..5) |j| try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a', s: 'other'}})-[:R]->(:X {{s: 'other'}})", .{100 + j}));
            self.ctx.tenant_id = "tenant_a";
        }
        {
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..25) |i| {
                const g: []const u8 = if (i < 10) "a" else if (i < 20) "b" else "c";
                try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}', s: 's{d:0>2}'}})-[:R]->(:X {{s: 'x{d:0>2}'}})", .{ i, g, i, i }));
            }
            for (0..2) |j| try self.exec(try std.fmt.allocPrint(aa, "CREATE (:Y {{s: 'y{d}'}})", .{j}));
            try self.exec("CREATE (:Hidden {s: 'h'})");
        }
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

fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row, 0..) |cell, c| {
        if (c > 0) try out.append(aa, '|');
        switch (cell) {
            .Str => |s| try out.appendSlice(aa, s),
            .Int => |n| try out.print(aa, "{d}", .{n}),
            .Null => try out.appendSlice(aa, "null"),
            else => try out.print(aa, "<{s}>", .{@tagName(cell)}),
        }
    }
    return out.toOwnedSlice(aa);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }
};

/// Run `query`: record a failure unless the legacy executor served it (the
/// planned read materialized nothing). Returns the rows in serve order.
fn legacyRows(s: *Session, f: *Failures, query: []const u8) ![][]const u8 {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        try f.add(aa, "[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return &.{};
    };
    defer result.deinit(aa);
    const planned = planned_read_runtime.getPathRowsMaterialized();
    if (planned != 0) try f.add(aa, "[{s}] {s}: served by the planned read ({d} materialized)", .{ @tagName(s.mode), query, planned });
    const rows = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, 0..) |row, i| rows[i] = try renderRow(aa, row);
    return rows;
}

/// `query` returns exactly `want`, in any order. Returns the rows in serve
/// order.
fn expectSet(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) ![][]const u8 {
    const aa = s.arena.allocator();
    const rows = try legacyRows(s, f, query);
    const got = try aa.dupe([]const u8, rows);
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        const got_text = try std.mem.join(aa, ",", got);
        const want_text = try std.mem.join(aa, ",", exp);
        try f.add(aa, "[{s}] {s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ @tagName(s.mode), query, exp.len, want_text, got.len, got_text });
    }
    return rows;
}

/// `query` (a window over `base`) returns `want` in exactly this order.
fn expectList(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    const rows = try legacyRows(s, f, query);
    const same = rows.len == want.len and for (rows, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        try f.add(aa, "[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), query, try std.mem.join(aa, ",", want), try std.mem.join(aa, ",", rows) });
    }
}

fn ints(aa: std.mem.Allocator, from: usize, to: usize) ![][]const u8 {
    const out = try aa.alloc([]const u8, to - from + 1);
    for (out, from..) |*o, i| o.* = try std.fmt.allocPrint(aa, "{d}", .{i});
    return out;
}

/// The whole matrix for one session.
fn checkMode(mode: Mode) !void {
    harness.silenceEngineLogs();
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();
    var f: Failures = .{};

    // A WHERE after RETURN, with and without a window.
    const base = "MATCH (n:G) RETURN n.i WHERE n.i >= 10";
    const all = try expectSet(&s, &f, base, try ints(aa, 10, 24));
    if (all.len == 15) {
        try expectList(&s, &f, "MATCH (n:G) RETURN n.i WHERE n.i >= 10 LIMIT 5", all[0..5]);
        try expectList(&s, &f, "MATCH (n:G) RETURN n.i WHERE n.i >= 10 SKIP 3 LIMIT 5", all[3..8]);
    }
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.i AS x WHERE x >= 10", try ints(aa, 10, 24));
    // After a WITH, the WHERE after RETURN still belongs to the RETURN.
    _ = try expectSet(&s, &f, "MATCH (n:G) WITH n RETURN n.i WHERE n.i >= 10", try ints(aa, 10, 24));

    // GROUP BY with no aggregate, and HAVING on a key, an alias, an aggregate
    // alias.
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.g GROUP BY n.g", &.{ "a", "b", "c" });
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.g <> 'a'", &.{ "b", "c" });
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.g AS k GROUP BY n.g HAVING k <> 'a'", &.{ "b", "c" });
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" });
    _ = try expectSet(&s, &f, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g", &.{ "a|10", "b|10", "c|5" });

    // The other grouping shapes: two patterns, an OPTIONAL MATCH, a path.
    _ = try expectSet(&s, &f, "MATCH (n:G), (y:Y) RETURN n.g, count(*) AS c GROUP BY n.g HAVING n.g <> 'a'", &.{ "b|20", "c|10" });
    _ = try expectSet(&s, &f, "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) RETURN n.g GROUP BY n.g HAVING n.g <> 'c'", &.{ "a", "b" });
    _ = try expectSet(&s, &f, "MATCH (n:G)-[:R]->(x:X) RETURN n.g, count(*) AS c GROUP BY n.g HAVING n.g <> 'a'", &.{ "b|10", "c|5" });

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.LegacyReturnWrong;
    }
}

test "SONNY-2674: an in-memory store's RETURN groups, applies HAVING and a WHERE after RETURN" {
    try checkMode(.in_memory);
}

test "SONNY-2674: an RLS-policy session's RETURN groups, applies HAVING and a WHERE after RETURN" {
    try checkMode(.rls_policy);
}

test "SONNY-2674: a tenant-scoped session's RETURN groups, applies HAVING and a WHERE after RETURN" {
    try checkMode(.tenant_scoped);
}

/// Run `query` on the legacy executor directly, as
/// executeQueryWithBindingsImpl and VALUES ... MATCH do: no planned read and
/// none of the query executor's fast paths.
fn runLegacyDirect(s: *Session, query: []const u8) !execution.ExecutionResult {
    const aa = s.arena.allocator();
    var parsed = try geode.parseGql(query, aa);
    defer parsed.deinit();
    return execution.executeMatchQueryImpl(aa, parsed.program.statements[0].Query, &.{}, &.{}, &.{}, null);
}

fn expectRows(s: *Session, result: execution.ExecutionResult, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = try renderRow(aa, row);
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    try testing.expectEqual(exp.len, got.len);
    for (exp, got) |w, g| try testing.expectEqualStrings(w, g);
}

// M5 (the SONNY-2674 review): the check that sends a grouped RETURN to the
// shared projection runs first in executeMatchQueryImpl, ahead of the two
// GROUP BY fast paths the executor used to try, so the callers that reach it
// directly lost them. They now run first inside that branch.
test "SONNY-2674: a grouped RETURN given to the legacy executor directly still takes its GROUP BY fast paths" {
    harness.silenceEngineLogs();
    var s = try Session.init(.persisted);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();

    // Counts of the indexed key: served from the index postings.
    execution.resetIndexServedAggregateTotal();
    execution.resetReturnOverBindingsTotal();
    {
        var r = try runLegacyDirect(&s, "MATCH (n:G) RETURN n.g AS k, count(*) AS c GROUP BY n.g");
        defer r.deinit(aa);
        try expectRows(&s, r, &.{ "a|10", "b|10", "c|5" });
    }
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), execution.getReturnOverBindingsTotal());

    // A sum, which the index path declines: the streaming GROUP BY scan.
    execution.resetIndexServedAggregateTotal();
    {
        var r = try runLegacyDirect(&s, "MATCH (n:G) RETURN n.g AS k, sum(n.i) AS t GROUP BY n.g");
        defer r.deinit(aa);
        try expectRows(&s, r, &.{ "a|45", "b|145", "c|110" });
    }
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), execution.getReturnOverBindingsTotal());

    // A HAVING, which both decline: the shared projection.
    {
        var r = try runLegacyDirect(&s, "MATCH (n:G) RETURN n.g AS k, sum(n.i) AS t GROUP BY n.g HAVING t > 100");
        defer r.deinit(aa);
        try expectRows(&s, r, &.{ "b|145", "c|110" });
    }
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 1), execution.getReturnOverBindingsTotal());
}
