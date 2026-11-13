// SONNY-6437 regressions.
//
//   3. `src/exec.zig` (the `gql` executable's engine) added sums with an
//      unchecked `+=`. The aggregator that did (HashAggregator) was removed in
//      SONNY-6436 (9f77dd1b); the live `groupAndAggregate` adds with an
//      overflow check. Pinned: a SUM and an AVG past i64 range are NULL, and
//      nothing panics. Re-checking it found that it freed each group's key
//      right after putting it in its group map, so a later row compared
//      against freed bytes and every row was a group of its own.
//   5. `CALL db.relationshipTypes()` and `CALL db.propertyKeys()` ignored the
//      session's RLS label policies, which `CALL db.labels()` applies
//      (`sessionLabelPolicies`): a user denied the edge type `:HIDE` and the
//      label `:Sec` was told the type exists and the names of the properties
//      only `:Sec` nodes and `:HIDE` edges carry. A type is a table as a label
//      is (SONNY-2710); a node is hidden by a deny on any of its labels
//      (SONNY-2690), so a key held only by hidden nodes is not listed even
//      when one of their labels is not denied.
//   4. `match_operations.executeMatchWithOptionalPatterns` and the legacy
//      aggregate RETURN-after-WITH loop of `executeMatchQueryImpl` were
//      unreachable from parsed queries and are removed. Pinned: the shapes
//      their dispatch arms were written for (OPTIONAL MATCH after a comma
//      pattern or a multi-hop pattern, with a SET, an aggregate after a WITH,
//      an initial WITH) are answered by the executors that serve them.
//   7. `CALL db.labels() YIELD label WHERE ...` is not ISO/IEC 39075:2024
//      syntax: 16.14 <yield clause> is `YIELD <yield item list>` only, and a
//      call query statement (14.5) is followed in a linear query (14.3) by a
//      filter statement (14.6), `FILTER [WHERE] <search condition>`. The
//      WHERE is refused with a 42000 message that says so.
//
// Items 1, 2 and 6 (list values leaked by DISTINCT, GROUP BY, comprehensions
// and VALUES ... MATCH) are covered by
// tests/test_sonny6449_projection_value_ownership.zig.
//
// The real executor, the real RLS filter engine and the real parser. No
// mocks.
//
// CANARY: REQ=REQ-SONNY-6437-QUERY-RESIDUALS; FEATURE="GPS Metadata Isolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6437_query_residuals.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const rls_types = @import("rls_types");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const exec = geode.exec;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Item 3
// ---------------------------------------------------------------------------

test "SONNY-6437 (3): the gql engine's SUM and AVG past i64 range are NULL, not a panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    const rows: []const []const exec.BindingValue = &.{
        &.{ .{ .Str = "up" }, .{ .Int = max } },
        &.{ .{ .Str = "up" }, .{ .Int = max } },
        &.{ .{ .Str = "down" }, .{ .Int = min } },
        &.{ .{ .Str = "down" }, .{ .Int = -1 } },
        &.{ .{ .Str = "fits" }, .{ .Int = max } },
        &.{ .{ .Str = "fits" }, .{ .Int = -1 } },
    };
    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .Avg } };
    const out = try exec.groupAndAggregate(aa, rows, spec, &.{ 1, 1 });
    try testing.expectEqual(@as(usize, 3), out.len);
    for (out) |row| {
        const key = row[0].Str;
        if (std.mem.eql(u8, key, "fits")) {
            try testing.expectEqual(@as(i64, max - 1), row[1].Int);
        } else {
            // The i128 accumulator holds the sum; it is outside i64.
            try testing.expect(row[1] == .Null);
        }
    }
}

// ---------------------------------------------------------------------------
// Item 5
// ---------------------------------------------------------------------------

const Session = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    rls: *rls_types.RLSFilterEngine,

    fn init(self: *Session) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;
        self.rls = try testing.allocator.create(rls_types.RLSFilterEngine);
        self.rls.* = rls_types.RLSFilterEngine.init(testing.allocator);

        // Public data, and data only `:Sec` nodes and `:HIDE` edges carry; a
        // node labelled both `:Pub` and `:Sec` (hidden from bob by its
        // `:Sec`) carries `mixed_key`.
        for ([_][]const u8{
            "CREATE (:Pub {pub_key: 1})-[:OK {ok_key: 1}]->(:Pub {pub_key: 2})",
            "CREATE (:Sec {sec_key: 1})-[:HIDE {hide_key: 1}]->(:Pub {pub_key: 3})",
            "CREATE (:Pub:Sec {mixed_key: 1})",
            "MATCH (a:Pub {pub_key: 1}), (b:Pub {pub_key: 3}) CREATE (a)-[:OK {ok_key: 2}]->(b)",
        }) |q| {
            var r = try self.run(null, q);
            r.deinit(self.arena.allocator());
        }
        try self.rls.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Sec", "bob");
        try self.rls.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "HIDE", "bob");
        rls_types.setGlobalRLSFilterEngine(self.rls);
    }

    fn deinit(self: *Session) void {
        rls_types.setGlobalRLSFilterEngine(null);
        self.rls.deinit();
        testing.allocator.destroy(self.rls);
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn run(self: *Session, user: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.user = user;
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], self.ctx);
    }

    /// The one string column of `query`'s rows, in order.
    fn strings(self: *Session, user: ?[]const u8, query: []const u8) ![]const []const u8 {
        const res = self.run(user, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        const out = try self.arena.allocator().alloc([]const u8, res.rows.len);
        for (res.rows, out) |row, *s| s.* = row[0].Str;
        return out;
    }
};

fn expectStrings(want: []const []const u8, got: []const []const u8, what: []const u8) !void {
    var ok = want.len == got.len;
    if (ok) for (want, got) |w, g| {
        if (!std.mem.eql(u8, w, g)) ok = false;
    };
    if (!ok) {
        std.debug.print("{s}: got", .{what});
        for (got) |g| std.debug.print(" '{s}'", .{g});
        std.debug.print(", expected", .{});
        for (want) |w| std.debug.print(" '{s}'", .{w});
        std.debug.print("\n", .{});
        return error.WrongRows;
    }
}

test "SONNY-6437 (5): db.relationshipTypes() omits an edge type the session's RLS policy denies" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const q = "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType";
    try expectStrings(&.{ "HIDE", "OK" }, try s.strings("alice", q), "alice");
    try expectStrings(&.{ "HIDE", "OK" }, try s.strings(null, q), "no user");
    try expectStrings(&.{"OK"}, try s.strings("bob", q), "bob");
    // The labels, for comparison: the existing behaviour.
    try expectStrings(&.{"Pub"}, try s.strings("bob", "CALL db.labels() YIELD label RETURN label ORDER BY label"), "bob labels");
}

test "SONNY-6437 (5): db.propertyKeys() omits the keys only rows the session's RLS policy hides carry" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const q = "CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey ORDER BY propertyKey";
    const all = [_][]const u8{ "hide_key", "mixed_key", "ok_key", "pub_key", "sec_key" };
    try expectStrings(&all, try s.strings("alice", q), "alice");
    try expectStrings(&all, try s.strings(null, q), "no user");
    try expectStrings(&.{ "ok_key", "pub_key" }, try s.strings("bob", q), "bob");
}

// ---------------------------------------------------------------------------
// Item 4
// ---------------------------------------------------------------------------

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str => |x| x,
        .Int => |i| std.fmt.allocPrint(aa, "{d}", .{i}),
        .Null => "null",
        else => std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// `query`'s rows, each rendered as `a, b`, in order.
fn renderedRows(s: *Session, query: []const u8) ![]const []const u8 {
    const aa = s.arena.allocator();
    const res = s.run("alice", query) catch |err| {
        std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
        return err;
    };
    const out = try aa.alloc([]const u8, res.rows.len);
    for (res.rows, out) |row, *o| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        o.* = try std.mem.join(aa, ", ", cells);
    }
    return out;
}

test "SONNY-6437 (4): the shapes of the removed legacy executors are answered by the live ones" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const Pin = struct { q: []const u8, want: []const []const u8 };
    const pins = [_]Pin{
        // OPTIONAL MATCH after a single-node pattern, a comma pattern and a
        // multi-hop pattern.
        .{ .q = "MATCH (a:Pub) OPTIONAL MATCH (a)-[:OK]->(b) RETURN a.pub_key AS k, b.pub_key AS bk ORDER BY k, bk", .want = &.{ "null, null", "1, 2", "1, 3", "2, null", "3, null" } },
        .{ .q = "MATCH (a:Pub), (b:Sec) OPTIONAL MATCH (b)-[:HIDE]->(c) RETURN count(*) AS c, count(c) AS cc", .want = &.{"8, 4"} },
        .{ .q = "MATCH (a:Pub {pub_key: 1})-[:OK]->(b) OPTIONAL MATCH (b)-[:OK]->(c) RETURN b.pub_key AS k, c.pub_key AS ck ORDER BY k", .want = &.{ "2, null", "3, null" } },
        // With a SET.
        .{ .q = "MATCH (a:Pub {pub_key: 1}) OPTIONAL MATCH (a)-[:OK]->(b) SET a.seen = 1 RETURN a.seen AS s, b.pub_key AS bk ORDER BY bk", .want = &.{ "1, 2", "1, 3" } },
        // An aggregate RETURN after a WITH, and after an initial WITH.
        .{ .q = "MATCH (n:Pub) WITH n RETURN count(n) AS c", .want = &.{"4"} },
        .{ .q = "MATCH (n:Pub) WITH n, n.pub_key AS k WHERE k > 1 RETURN count(*) AS c, sum(k) AS s", .want = &.{"2, 5"} },
        .{ .q = "WITH 1 AS x MATCH (n:Pub) WHERE x = 1 RETURN count(n) AS c", .want = &.{"4"} },
    };
    var failures: usize = 0;
    for (pins) |pin| {
        const got = try renderedRows(&s, pin.q);
        expectStrings(pin.want, got, pin.q) catch {
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Item 7
// ---------------------------------------------------------------------------

test "SONNY-6437 (7): a WHERE after YIELD is refused with a 42000 message naming the ISO FILTER statement" {
    const queries = [_][]const u8{
        "CALL db.labels() YIELD label WHERE label <> 'X' RETURN label",
        "MATCH (n:Pub) CALL db.labels() YIELD label WHERE label <> 'X' RETURN n, label",
    };
    var failures: usize = 0;
    for (queries) |q| {
        var outcome = try geode.parseGqlOutcome(q, testing.allocator, .{});
        defer outcome.deinit();
        switch (outcome) {
            .Ok => {
                std.debug.print("{s}: parsed\n", .{q});
                failures += 1;
            },
            .Err => |e| {
                const named = std.mem.indexOf(u8, e.msg, "FILTER") != null and std.mem.indexOf(u8, e.msg, "YIELD") != null;
                if (!std.mem.eql(u8, e.code, "42000") or !named) {
                    std.debug.print("{s}: {s} '{s}'\n", .{ q, e.code, e.msg });
                    failures += 1;
                }
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
