// SONNY-2675 regression: an aggregate named only in a grouped HAVING was
// evaluated against one row.
//
// The shared grouped projection (`executeWithClauseWithGroupByAndParams`:
// the planned read's RETURN, every WITH stage, and since SONNY-2674 the legacy
// executor's RETURN) evaluated HAVING with plain evaluation over the group's
// output row and its first input row. Plain evaluation of `count(*)` is 1, of
// `sum(x)` the first row's x, so:
//   * `GROUP BY k HAVING count(*) > 1` dropped every group;
//   * `HAVING count(*) >= 1` kept every group, `count(*) < 10` too;
//   * `HAVING sum(n.i) > 100` compared the first row's n.i.
// SONNY-2674 routed the legacy executor's grouped RETURN through that code, so
// in-memory, RLS-policy and tenant-scoped sessions got it too.
//
// A grouped HAVING now computes the aggregates it names for each group (the
// item's column when an item computes the same aggregate, else a hidden
// aggregate), reads grouping keys and projected columns from the group, and
// refuses any other input column with error.UngroupedHavingReference
// (SQLSTATE 42803). A WHERE after a RETURN with only aggregates is a HAVING
// over the one aggregate row: `RETURN count(*) AS c WHERE c > 5` filters
// it, and `RETURN count(*) AS c WHERE n.i > 5` is refused (n.i is not
// grouped). An aggregate in a per-row WHERE after RETURN is refused with
// error.AggregateInRowFilter (42803).
//
// Every check runs in all three legacy sessions (each query must be served by
// the legacy executor) and on the planned read (a persisted deployment with
// no RLS policy or tenant scope, where the single-pattern queries must be
// served by the planned read). The expected groups come from the seed.
//
// CANARY: REQ=REQ-SONNY-2675-GROUPED-HAVING; FEATURE="GroupedHaving"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2675_grouped_having.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

/// Which executor serves the session's reads.
const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, with an RLS policy: the legacy executor.
    rls_policy,
    /// Persisted, tenant-scoped: the legacy executor.
    tenant_scoped,
    /// Persisted, no policy, no tenant: the planned read.
    planned,
};

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

    /// The data every mode sees: 25 `(:G {i, g, h, s})-[:R]->(:X {s})` pairs
    /// with g = 'a' for i = 0..9, 'b' for 10..19 and 'c' for 20..24, h the
    /// upper-case g (the same in every row of a g group, but not grouped),
    /// and 2 `:Y` nodes. Per group: count 10, 10, 5; sum(i) 45, 145, 110;
    /// avg(i) 4.5, 14.5, 22; min(i) 0, 10, 20; max(i) 9, 19, 24.
    /// Then the mode's own setup: a tenant-scoped session also has another
    /// tenant's `:G` nodes it must not see (which would change every group
    /// 'a' aggregate), and an RLS session has a policy (on another label) so
    /// the legacy executor serves it.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        if (self.mode == .tenant_scoped) {
            self.ctx.tenant_id = "tenant_b";
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..5) |j| try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: 'a', h: 'A', s: 'other'}})-[:R]->(:X {{s: 'other'}})", .{100 + j}));
            self.ctx.tenant_id = "tenant_a";
        }
        {
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            for (0..25) |i| {
                const g: []const u8 = if (i < 10) "a" else if (i < 20) "b" else "c";
                const h: []const u8 = if (i < 10) "A" else if (i < 20) "B" else "C";
                try self.exec(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}', h: '{s}', s: 's{d:0>2}'}})-[:R]->(:X {{s: 'x{d:0>2}'}})", .{ i, g, h, i, i }));
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
            .Double => |d| try out.print(aa, "{d}", .{d}),
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

/// Which executor must serve a query in the planned mode (in the legacy
/// modes it is always the legacy executor).
const Path = enum {
    /// The planned read.
    planned,
    /// Either: a shape the planned read may decline (several patterns, a
    /// relationship).
    any,
};

/// `query` returns exactly `want`, in any order, and was served as `path`
/// says.
fn expectSet(s: *Session, f: *Failures, path: Path, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        try f.add(aa, "[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    if (s.mode == .planned) {
        if (path == .planned and materialized == 0) try f.add(aa, "[{s}] {s}: not served by the planned read", .{ @tagName(s.mode), query });
    } else if (materialized != 0) {
        try f.add(aa, "[{s}] {s}: served by the planned read ({d} materialized)", .{ @tagName(s.mode), query, materialized });
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
        const want_text = try std.mem.join(aa, ",", exp);
        const got_text = try std.mem.join(aa, ",", got);
        try f.add(aa, "[{s}] {s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ @tagName(s.mode), query, exp.len, want_text, got.len, got_text });
    }
}

/// `query` fails with `want`.
fn expectFail(s: *Session, f: *Failures, query: []const u8, want: anyerror) !void {
    const aa = s.arena.allocator();
    if (s.run(query)) |ok| {
        var result = ok;
        try f.add(aa, "[{s}] {s}: expected error {s}, got {d} rows", .{ @tagName(s.mode), query, @errorName(want), result.rows.len });
        result.deinit(aa);
    } else |err| {
        if (err != want) try f.add(aa, "[{s}] {s}: expected error {s}, got {s}", .{ @tagName(s.mode), query, @errorName(want), @errorName(err) });
    }
}

/// The whole matrix for one session.
fn checkMode(mode: Mode) !void {
    harness.silenceEngineLogs();
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    // count(*) only in HAVING, unaliased: each threshold keeps exactly the
    // groups whose row count passes (count 10, 10, 5).
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) > 1", &.{ "a", "b", "c" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) > 5", &.{ "a", "b" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) < 10", &.{"c"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) = 10", &.{ "a", "b" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) > 10", &.{});
    // Aliased: GROUP BY the alias, and the same aggregate as a projected
    // column (whose value the HAVING reuses).
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k GROUP BY k HAVING count(*) > 5", &.{ "a", "b" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k, count(*) AS c GROUP BY n.g HAVING count(*) > 5", &.{ "a|10", "b|10" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k, count(*) AS c GROUP BY k HAVING count(*) < 10", &.{"c|5"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g, count(*) GROUP BY n.g HAVING COUNT(*) > 5", &.{ "a|10", "b|10" });

    // sum and avg only in HAVING (sum 45, 145, 110; avg 4.5, 14.5, 22).
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING sum(n.i) > 100", &.{ "b", "c" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING sum(n.i) < 100", &.{"a"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k GROUP BY k HAVING avg(n.i) > 12", &.{ "b", "c" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k GROUP BY k HAVING avg(n.i) < 10", &.{"a"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING avg(n.i) < 10 OR sum(n.i) = 110", &.{ "a|10", "c|5" });
    // The other aggregates, one inside a scalar function, one DISTINCT.
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING max(n.i) >= 20", &.{"c"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING min(n.i) = 10", &.{"b"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING size(collect(n.i)) = 5", &.{"c"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(DISTINCT n.i) = 10", &.{ "a", "b" });
    // With the grouping key, and inside a CASE.
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.g <> 'a' AND count(*) > 5", &.{"b"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING CASE WHEN count(*) > 5 THEN true ELSE false END", &.{ "a", "b" });

    // At a WITH stage.
    try expectSet(&s, &f, .any, "MATCH (n:G) WITH n.g AS k GROUP BY n.g HAVING count(*) > 5 RETURN k", &.{ "a", "b" });
    try expectSet(&s, &f, .any, "MATCH (n:G) WITH n.g AS k, sum(n.i) AS t GROUP BY n.g HAVING avg(n.i) > 12 RETURN k, t", &.{ "b|145", "c|110" });

    // The legacy executor's other pattern shapes: a relationship, two
    // patterns (count 20, 20, 10 with the two :Y nodes).
    try expectSet(&s, &f, .any, "MATCH (n:G)-[:R]->(x:X) RETURN n.g GROUP BY n.g HAVING count(*) > 5", &.{ "a", "b" });
    try expectSet(&s, &f, .any, "MATCH (n:G)-[:R]->(x:X) RETURN n.g GROUP BY n.g HAVING count(x) < 10", &.{"c"});
    try expectSet(&s, &f, .any, "MATCH (n:G), (y:Y) RETURN n.g GROUP BY n.g HAVING count(*) > 10", &.{ "a", "b" });

    // A WHERE after a RETURN with only aggregates: a HAVING over its one row.
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN count(*) AS c WHERE c > 5", &.{"25"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN count(*) AS c WHERE c > 100", &.{});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN count(*) AS c WHERE count(*) > 20", &.{"25"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN count(*) AS c WHERE sum(n.i) = 300", &.{"25"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN sum(n.i) AS t WHERE avg(n.i) > 100", &.{});

    // A projected column that is not grouped: the group's projected value
    // (its first row's), here the same in every row of the group. A property
    // of a grouped node, and the key through its alias, read the key.
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g, n.h GROUP BY n.g HAVING n.h <> 'A'", &.{ "b|B", "c|C" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g, n.h AS u GROUP BY n.g HAVING u = 'C'", &.{"c|C"});
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN n.g AS k GROUP BY k HAVING n.g <> 'a'", &.{ "b", "c" });
    try expectSet(&s, &f, .planned, "MATCH (n:G) RETURN count(*) AS c GROUP BY n HAVING n.i >= 22", &.{ "1", "1", "1" });

    // A name that is neither a column nor a binding is refused (it was NULL,
    // GAP-0926's silent-accept, which dropped every group).
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING nosuchalias IS NULL", error.UnknownHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING nosuchalias > 2", error.UnknownHavingReference);

    // Refused: an input column that is neither grouped, projected nor
    // aggregated (42803), also through a WITH and over the one aggregate
    // row; an aggregate in a per-row WHERE after RETURN; a nested aggregate.
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.i > 5", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING n.s = 's00'", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) > 1 AND n.i > 5", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G)-[:R]->(x:X) RETURN n.g GROUP BY n.g HAVING x.s = 'x00'", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) WITH n.g AS k GROUP BY n.g HAVING n.i > 5 RETURN k", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) RETURN count(*) AS c WHERE n.i > 5", error.UngroupedHavingReference);
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.i WHERE count(*) > 1", error.AggregateInRowFilter);
    try expectFail(&s, &f, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING sum(count(*)) > 1", error.NestedAggregate);

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.GroupedHavingWrong;
    }
}

test "SONNY-2675: an in-memory store's grouped HAVING computes its aggregates per group" {
    try checkMode(.in_memory);
}

test "SONNY-2675: an RLS-policy session's grouped HAVING computes its aggregates per group" {
    try checkMode(.rls_policy);
}

test "SONNY-2675: a tenant-scoped session's grouped HAVING computes its aggregates per group" {
    try checkMode(.tenant_scoped);
}

test "SONNY-2675: a planned read's grouped HAVING computes its aggregates per group" {
    try checkMode(.planned);
}

test "SONNY-2675: a refused HAVING reaches the client as SQLSTATE 42803 (0A000 for a pattern predicate)" {
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.UngroupedHavingReference).code);
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.AggregateInRowFilter).code);
    try testing.expectEqualStrings("0A000", geode.proto_util.mapError(error.UnsupportedGroupedHavingPredicate).code);
    try testing.expectEqualStrings("42703", geode.proto_util.mapError(error.UnknownHavingReference).code);
    try testing.expectEqualStrings("42803", geode.proto_util.mapError(error.NestedAggregate).code);
}
