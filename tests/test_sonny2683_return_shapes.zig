// SONNY-2683 regression: the RETURN shapes SONNY-2674 left out of the shared
// projection.
//
// SONNY-2674 routed a legacy RETURN that groups (a RETURN-level GROUP BY) or
// filters (a WHERE after RETURN) through the shared projection, but only for
// a plain read. The other shapes kept their own executors:
//   * after a CTE, the legacy grouping code: its "at least two rows" HAVING
//     stand-in, a WHERE after RETURN ignored, and no grouping without an
//     aggregate;
//   * after a SET or REMOVE, the same code, which also never applied the
//     write: `MATCH (n:G) SET n.t = 7 RETURN n.g, count(*) GROUP BY n.g`
//     returned its groups and left every n.t unset; and on a persisted or
//     tenant-scoped session the streaming GROUP BY / DISTINCT fast path,
//     which declined a SET but not a REMOVE, answered a REMOVE without
//     removing anything;
//   * after a CREATE or MERGE, or with a procedure CALL, executors that
//     ignore a GROUP BY, HAVING or WHERE after RETURN and return other rows;
//   * after `WITH ... FOR ... RETURN`, a GROUP BY or HAVING that the parser
//     attached to the enclosing query.
// A CTE, SET or REMOVE now goes through the shared projection (the write is
// applied while the bindings are read, and the RETURN computed after), and
// no read fast path answers a REMOVE. A CREATE, MERGE or procedure CALL
// with such a RETURN is refused with error.UnsupportedGroupedReturn
// (SQLSTATE 0A000) before anything is written. A FOR's RETURN refuses a
// GROUP BY, HAVING or WHERE at parse time.
//
// Every check runs in the three legacy sessions and on a persisted
// deployment with no policy or tenant scope. Writes are legacy everywhere.
// The expected rows come from the seed.
//
// CANARY: REQ=REQ-SONNY-2683-RETURN-SHAPES; FEATURE="LegacyReturnProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2683_return_shapes.zig; OWNER=engine; UPDATED=2026-09-25

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
    /// Persisted, no policy, no tenant: the planned read serves its reads.
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

fn ints(aa: std.mem.Allocator, from: usize, to: usize) ![]const []const u8 {
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

    // After a CTE (whose results are parameters by the time the read runs).
    const cte = "WITH cte AS (MATCH (y:Y) RETURN y.s AS s) ";
    try expectSet(&s, &f, .any, cte ++ "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" });
    try expectSet(&s, &f, .any, cte ++ "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING count(*) < 10", &.{"c"});
    try expectSet(&s, &f, .any, cte ++ "MATCH (n:G) RETURN n.g GROUP BY n.g", &.{ "a", "b", "c" });
    try expectSet(&s, &f, .any, cte ++ "MATCH (n:G) RETURN n.i WHERE n.i >= 20", try ints(aa, 20, 24));
    try expectSet(&s, &f, .any, "WITH RECURSIVE r AS (RETURN 1 AS x UNION ALL MATCH (y:Y) RETURN 2 AS x) MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" });

    // After a SET or REMOVE: the write reaches every matched row. (The
    // RETURN sees the values from before the write, as a RETURN after a SET
    // does on every legacy path, so the written values are read back.)
    try expectSet(&s, &f, .any, "MATCH (n:G) SET n.t = 7 RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" });
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.t = 7 RETURN count(*) AS c", &.{"25"});
    try expectSet(&s, &f, .any, "MATCH (n:G) SET n.y = n.i * 2 RETURN n.g, sum(n.i) AS t GROUP BY n.g", &.{ "a|45", "b|145", "c|110" });
    try expectSet(&s, &f, .any, "MATCH (n:G) RETURN n.g, sum(n.y) AS t GROUP BY n.g", &.{ "a|90", "b|290", "c|220" });
    try expectSet(&s, &f, .any, "MATCH (n:G) SET n.u = 1 RETURN n.i WHERE n.i >= 20", try ints(aa, 20, 24));
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.u = 1 RETURN count(*) AS c", &.{"25"});
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.g = 'a' SET n.v = 1 RETURN n.g, count(*) AS c GROUP BY n.g", &.{"a|10"});
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.v = 1 RETURN count(*) AS c", &.{"10"});
    try expectSet(&s, &f, .any, "MATCH (n:G) REMOVE n.t RETURN n.g GROUP BY n.g", &.{ "a", "b", "c" });
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.t IS NOT NULL RETURN count(*) AS c", &.{"0"});
    // A DISTINCT RETURN after a REMOVE: not a read fast path's to answer.
    try expectSet(&s, &f, .any, "MATCH (n:G) SET n.t = 8 RETURN n.i WHERE n.i < 0", &.{});
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.t = 8 RETURN count(*) AS c", &.{"25"});
    try expectSet(&s, &f, .any, "MATCH (n:G) REMOVE n.t RETURN DISTINCT n.g", &.{ "a", "b", "c" });
    try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.t IS NOT NULL RETURN count(*) AS c", &.{"0"});
    try expectSet(&s, &f, .any, "MATCH (n:G)-[:R]->(x:X) SET x.t = 3 RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" });
    try expectSet(&s, &f, .any, "MATCH (x:X) WHERE x.t = 3 RETURN count(*) AS c", &.{"25"});
    if (mode == .tenant_scoped) {
        // The other tenant's rows were not written.
        s.ctx.tenant_id = "tenant_b";
        defer s.ctx.tenant_id = "tenant_a";
        try expectSet(&s, &f, .any, "MATCH (n:G) WHERE n.y IS NOT NULL OR n.u = 1 RETURN count(*) AS c", &.{"0"});
        try expectSet(&s, &f, .any, "MATCH (n:G) RETURN count(*) AS c", &.{"5"});
    }

    // Refused before anything is written: a CREATE, a MERGE, a procedure CALL.
    try expectFail(&s, &f, "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 5", error.UnsupportedGroupedReturn);
    try expectFail(&s, &f, "MATCH (n:G) CREATE (n)-[:T]->(:Z) RETURN n.i WHERE n.i >= 20", error.UnsupportedGroupedReturn);
    try expectSet(&s, &f, .any, "MATCH (z:Z) RETURN count(*) AS c", &.{"0"});
    try expectFail(&s, &f, "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN n.g, count(*) AS c GROUP BY n.g", error.UnsupportedGroupedReturn);
    try expectSet(&s, &f, .any, "MATCH (m:M) RETURN count(*) AS c", &.{"0"});
    try expectFail(&s, &f, "MATCH (n:G) CALL db.labels() YIELD label RETURN label, count(*) AS c GROUP BY label", error.UnsupportedGroupedReturn);
    try expectFail(&s, &f, "MATCH (n:G) CALL db.labels() YIELD label RETURN label WHERE label = 'G'", error.UnsupportedGroupedReturn);

    // FOR: its RETURN neither groups nor filters; a loop body does, per
    // element (two here).
    try expectFail(&s, &f, "MATCH (n:G) WITH n FOR x IN [1, 2] RETURN x, count(*) AS c GROUP BY x HAVING c > 100", error.UnexpectedToken);
    try expectFail(&s, &f, "MATCH (n:G) WITH n FOR x IN [1, 2] RETURN x WHERE x > 1", error.UnexpectedToken);
    try expectSet(&s, &f, .any, "FOR x IN [1, 2] MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "a|10", "b|10", "b|10" });

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.ReturnShapesWrong;
    }
}

test "SONNY-2683: an in-memory store groups and filters a RETURN after a CTE, SET or REMOVE, and refuses the rest" {
    try checkMode(.in_memory);
}

test "SONNY-2683: an RLS-policy session groups and filters a RETURN after a CTE, SET or REMOVE, and refuses the rest" {
    try checkMode(.rls_policy);
}

test "SONNY-2683: a tenant-scoped session groups and filters a RETURN after a CTE, SET or REMOVE, and refuses the rest" {
    try checkMode(.tenant_scoped);
}

test "SONNY-2683: a persisted deployment groups and filters a RETURN after a CTE, SET or REMOVE, and refuses the rest" {
    try checkMode(.planned);
}

// A routed write reads its bindings through the legacy executor, which
// applies the session's RLS policy to every candidate before it writes. The
// pattern here reaches the node the policy hides from bob (it has no label,
// and the hidden node's `s` matches): bob's grouped and filtered RETURNs after
// a SET must neither write that node nor count or return it.
test "SONNY-2683: a routed SET skips the node the session's RLS policy hides" {
    harness.silenceEngineLogs();
    var s = try Session.init(.rls_policy);
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    try expectSet(&s, &f, .any, "MATCH (n) WHERE n.s = 'h' OR n.s = 's00' SET n.hit = 1 RETURN n.s, count(*) AS c GROUP BY n.s", &.{"s00|1"});
    try expectSet(&s, &f, .any, "MATCH (n) WHERE n.s = 'h' OR n.s = 's01' SET n.hit = 2 RETURN n.s WHERE n.s <> 'zzz'", &.{"s01"});
    try expectSet(&s, &f, .any, "MATCH (n) WHERE n.s = 'h' REMOVE n.s RETURN count(*) AS c GROUP BY n.s", &.{});
    // bob does not see the hidden node at all.
    try expectSet(&s, &f, .any, "MATCH (n) WHERE n.s = 'h' RETURN count(*) AS c", &.{"0"});
    // A user the policy does not cover sees it, unwritten.
    s.ctx.user = "alice";
    try expectSet(&s, &f, .any, "MATCH (n:Hidden) RETURN n.s, n.hit", &.{"h|null"});
    try expectSet(&s, &f, .any, "MATCH (n) WHERE n.hit IS NOT NULL RETURN n.s, n.hit", &.{ "s00|1", "s01|2" });

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.RoutedWriteRlsWrong;
    }
}

test "SONNY-2683: a refused RETURN reaches the client as SQLSTATE 0A000" {
    try testing.expectEqualStrings("0A000", geode.proto_util.mapError(error.UnsupportedGroupedReturn).code);
}
