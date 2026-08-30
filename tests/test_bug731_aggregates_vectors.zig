// Regression tests for docs/@BUGS_731.md bugs 6 and 8.
//
//   Bug 6 — `count(DISTINCT ...)` always returns `null` while plain
//   `count(...)` works. The parser rewrites `count(DISTINCT x)` to the
//   synthetic callee `countDistinct` (src/gql/parser.zig:3599-3608), but
//   `computeGroupAggregation` (src/execution.zig:3067) — the function every
//   RETURN projection funnels through via the synthetic WithClause in
//   src/execution/planned_read_runtime.zig:549-554 — dispatches only on
//   count/sum/avg/min/max/collect and falls through to
//   `return Value{ .Null = {} }` (src/execution.zig:3255).
//   ISO/IEC 39075:2024 allows the <set quantifier> (DISTINCT | ALL) on EVERY
//   aggregate, so `collect(DISTINCT x)` / `sum(DISTINCT x)` / `avg(DISTINCT x)`
//   are covered too (today `collect(DISTINCT x)` is a PARSE error).
//
//   Bug 8 — `distance()` / `similarity()` / `euclidean()` / `knn()` return
//   `null`; only `cosine()` computes. Layers:
//     8a  those names are registered nowhere (src/eval_extended.zig:198-201
//         holds only vector_dot / vector_l2 / vector_cosine / vector_knn);
//         `cosine` works via a one-off alias at src/eval.zig:3189.
//     8b  ANY unresolved function silently yields NULL
//         (src/eval.zig:1117-1118) instead of an "undefined function" error.
//     8c  the REGISTERED vector functions reject GQL list literals — they gate
//         on `args[0] != .VectorF32` (src/eval_extended.zig:1947,:1965,:1985)
//         and a list literal converts to ExtValue.List.
//     8d  `knn` is not a scalar of the documented shape: the implemented
//         `vector_knn` takes (property_name:STRING, query_vector, k:INT,
//         metric:STRING) and returns a LIST of node ids (src/eval.zig:2171).
//     8e  `parseVectorMetric` (src/eval.zig:2046-2057) rejects "euclidean"
//         even though CREATE INDEX ... USING vector accepts it
//         (src/execution.zig:1586).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run a query and return the single value of the single row/column.
    pub fn scalar(self: *Harness, query: []const u8) !Value {
        const res = try self.exec(query);
        if (res.rows.len != 1) return error.ExpectedOneRow;
        if (res.rows[0].len != 1) return error.ExpectedOneColumn;
        return res.rows[0][0];
    }

    /// Single integer scalar. Accepts every integral Value representation the
    /// aggregate paths produce (count() → .Int, some paths → .BigInt).
    pub fn scalarInt(self: *Harness, query: []const u8) !i64 {
        return switch (try self.scalar(query)) {
            .Int => |v| v,
            .BigInt => |v| v,
            .SmallInt => |v| @intCast(v),
            .Null => error.GotNullInsteadOfInt,
            else => error.ExpectedIntValue,
        };
    }

    /// Single numeric scalar as f64. Accepts every numeric representation the
    /// vector/aggregate paths produce (vector_l2 → Decimal(scale 6), cosine →
    /// Decimal, avg → Double/Int).
    pub fn scalarNumber(self: *Harness, query: []const u8) !f64 {
        return switch (try self.scalar(query)) {
            .Int => |v| @floatFromInt(v),
            .BigInt => |v| @floatFromInt(v),
            .SmallInt => |v| @floatFromInt(v),
            .Real => |v| @floatCast(v),
            .Double => |v| v,
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
            .Null => error.GotNullInsteadOfNumber,
            else => error.ExpectedNumericValue,
        };
    }

    /// Assert the query is REJECTED with a diagnostic instead of silently
    /// yielding a value (the bug-8b "unresolved function → NULL" shape).
    pub fn expectRejected(self: *Harness, query: []const u8) !void {
        if (self.exec(query)) |res| {
            if (res.rows.len == 1 and res.rows[0].len == 1) {
                std.debug.print(
                    "expected `{s}` to be rejected, but it returned {s}\n",
                    .{ query, @tagName(res.rows[0][0]) },
                );
            } else {
                std.debug.print("expected `{s}` to be rejected, but it succeeded\n", .{query});
            }
            return error.ExpectedQueryRejection;
        } else |_| {}
    }
};

fn expectApprox(expected: f64, actual: f64) !void {
    try testing.expect(std.math.approxEqAbs(f64, expected, actual, 1e-6));
}

// ---------------------------------------------------------------------------
// Bug 6 — count(DISTINCT …)
// ---------------------------------------------------------------------------

/// 4 events: username alice (x2), bob, and one with NO username (NULL).
///   count(*)                     = 4
///   count(n.username)            = 3   (NULL skipped)
///   count(DISTINCT n.username)   = 2   (alice, bob)
/// 4 users with scores 10, 10, 20, 30 and active true,true,false,false:
///   sum(n.score)            = 70  |  sum(DISTINCT n.score) = 60
///   avg(DISTINCT n.score)   = 20  |  count(DISTINCT n.active) = 2
/// Friendships stored bidirectionally (as the source blog post's app does):
///   alice<->bob, alice<->carol, plus an unrelated bob->carol. The undirected
///   one-hop from alice therefore yields 4 rows over 2 distinct friends.
fn seedAgg(h: *Harness) !void {
    _ = try h.exec("CREATE GRAPH b731agg");
    _ = try h.exec("USE GRAPH b731agg");

    _ = try h.exec("CREATE (:B731Event {username: 'alice'})");
    _ = try h.exec("CREATE (:B731Event {username: 'alice'})");
    _ = try h.exec("CREATE (:B731Event {username: 'bob'})");
    _ = try h.exec("CREATE (:B731Event {kind: 'anonymous'})");

    _ = try h.exec("CREATE (:B731User {username: 'alice', city: 'nyc', score: 10, active: true})");
    _ = try h.exec("CREATE (:B731User {username: 'bob', city: 'nyc', score: 10, active: true})");
    _ = try h.exec("CREATE (:B731User {username: 'carol', city: 'sf', score: 20, active: false})");
    _ = try h.exec("CREATE (:B731User {username: 'dave', score: 30, active: false})");

    _ = try h.exec("MATCH (a:B731User {username:'alice'}), (b:B731User {username:'bob'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:B731User {username:'bob'}), (b:B731User {username:'alice'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:B731User {username:'alice'}), (b:B731User {username:'carol'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:B731User {username:'carol'}), (b:B731User {username:'alice'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:B731User {username:'bob'}), (b:B731User {username:'carol'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
}

test "bug6 regression: count(DISTINCT n.username) over duplicate values returns the distinct count" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    // alice, alice, bob, <null> → 2 distinct non-null usernames.
    try testing.expectEqual(
        @as(i64, 2),
        try h.scalarInt("MATCH (n:B731Event) RETURN count(DISTINCT n.username) AS c"),
    );
}

test "bug6 control: plain count(n.username) and count(*) are unaffected" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    try testing.expectEqual(
        @as(i64, 3),
        try h.scalarInt("MATCH (n:B731Event) RETURN count(n.username) AS c"),
    );
    try testing.expectEqual(
        @as(i64, 4),
        try h.scalarInt("MATCH (n:B731Event) RETURN count(*) AS c"),
    );
}

test "bug6 regression: count(DISTINCT n) counts distinct nodes by identity" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    try testing.expectEqual(
        @as(i64, 4),
        try h.scalarInt("MATCH (n:B731Event) RETURN count(DISTINCT n) AS c"),
    );
}

test "bug6 regression: reported traversal shape count(DISTINCT f) over an undirected FRIENDS_WITH hop" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    // alice's distinct friends are exactly {bob, carol}, no matter how many
    // stored edge directions the undirected hop walks.
    try testing.expectEqual(
        @as(i64, 2),
        try h.scalarInt("MATCH (me:B731User {username:'alice'})-[:FRIENDS_WITH]-(f) RETURN count(DISTINCT f) AS cnt"),
    );
    try testing.expectEqual(
        @as(i64, 2),
        try h.scalarInt("MATCH (me:B731User {username:'alice'})-[:FRIENDS_WITH]-(f) RETURN count(DISTINCT f.username) AS cnt"),
    );
}

test "bug6 control: plain count(f) / count(*) on the traversal match the un-aggregated row count" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    const rows = try h.exec("MATCH (me:B731User {username:'alice'})-[:FRIENDS_WITH]-(f) RETURN f");
    const row_count: i64 = @intCast(rows.rows.len);
    try testing.expect(row_count >= 2);

    try testing.expectEqual(
        row_count,
        try h.scalarInt("MATCH (me:B731User {username:'alice'})-[:FRIENDS_WITH]-(f) RETURN count(f) AS cnt"),
    );
    try testing.expectEqual(
        row_count,
        try h.scalarInt("MATCH (me:B731User {username:'alice'})-[:FRIENDS_WITH]-(f) RETURN count(*) AS cnt"),
    );
}

test "bug6 edge case: count(DISTINCT …) over an empty result is 0, not NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    try testing.expectEqual(
        @as(i64, 0),
        try h.scalarInt("MATCH (n:B731NoSuchLabel) RETURN count(DISTINCT n.username) AS c"),
    );
    try testing.expectEqual(
        @as(i64, 0),
        try h.scalarInt("MATCH (n:B731NoSuchLabel) RETURN count(DISTINCT n) AS c"),
    );
}

test "bug6 edge case: count(DISTINCT …) skips NULLs (all-NULL property counts 0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    try testing.expectEqual(
        @as(i64, 0),
        try h.scalarInt("MATCH (n:B731Event) RETURN count(DISTINCT n.no_such_property) AS c"),
    );
}

test "bug6 edge case: count(DISTINCT …) over booleans returns 2" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    try testing.expectEqual(
        @as(i64, 2),
        try h.scalarInt("MATCH (n:B731User) RETURN count(DISTINCT n.active) AS c"),
    );
}

test "bug6 ISO set quantifier: collect(DISTINCT x) parses and de-duplicates" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    // Today this fails in the PARSER: "expected token 'r_paren', got 'identifier'".
    const v = try h.scalar("MATCH (n:B731Event) RETURN collect(DISTINCT n.username) AS names");
    try testing.expect(v == .List);
    try testing.expectEqual(@as(usize, 2), v.List.len);
}

test "bug6 ISO set quantifier: sum(DISTINCT x) sums each distinct value once" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    // scores are 10, 10, 20, 30 → DISTINCT sum is 60, plain sum is 70.
    try expectApprox(60.0, try h.scalarNumber("MATCH (n:B731User) RETURN sum(DISTINCT n.score) AS s"));
    try expectApprox(70.0, try h.scalarNumber("MATCH (n:B731User) RETURN sum(n.score) AS s"));
}

test "bug6 ISO set quantifier: avg(DISTINCT x) averages the distinct values" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedAgg(&h);

    // distinct scores {10, 20, 30} → 20 (plain avg over 10,10,20,30 is 17.5,
    // so this value can only come from a real DISTINCT pass).
    try expectApprox(20.0, try h.scalarNumber("MATCH (n:B731User) RETURN avg(DISTINCT n.score) AS a"));
}

// ---------------------------------------------------------------------------
// Bug 8 — vector similarity functions
// ---------------------------------------------------------------------------

fn vecHarness(h: *Harness) !void {
    _ = try h.exec("CREATE GRAPH b731vec");
    _ = try h.exec("USE GRAPH b731vec");
}

test "bug8 regression: distance() literal-only forms compute the L2 distance (5.0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(5.0, try h.scalarNumber("RETURN distance([0.0,0.0], [3.0,4.0], 'l2') AS d"));
    // 8e: 'euclidean' is a documented CREATE INDEX metric and must be accepted
    // here too (parseVectorMetric currently rejects it).
    try expectApprox(5.0, try h.scalarNumber("RETURN distance([0.0,0.0], [3.0,4.0], 'euclidean') AS d"));
    // 2-arg form defaults to L2.
    try expectApprox(5.0, try h.scalarNumber("RETURN distance([0.0,0.0], [3.0,4.0]) AS d"));
}

test "bug8 regression: euclidean() literal-only form computes 5.0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(5.0, try h.scalarNumber("RETURN euclidean([0.0,0.0], [3.0,4.0]) AS d"));
}

test "bug8 regression: similarity() literal-only forms compute cosine similarity (1.0)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(1.0, try h.scalarNumber("RETURN similarity([1.0,0.0], [1.0,0.0], 'cosine') AS s"));
    try expectApprox(1.0, try h.scalarNumber("RETURN similarity([1.0,0.0], [1.0,0.0]) AS s"));
}

test "bug8 control: cosine() already works and must keep working" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(1.0, try h.scalarNumber("RETURN cosine([1.0,0.0], [1.0,0.0]) AS s"));
}

test "bug8c control: registered vector functions compute over vectorf32() constructors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(5.0, try h.scalarNumber("RETURN vector_l2(vectorf32([0.0,0.0]), vectorf32([3.0,4.0])) AS d"));
    try expectApprox(1.0, try h.scalarNumber("RETURN vector_cosine(vectorf32([1.0,0.0]), vectorf32([1.0,0.0])) AS s"));
}

test "bug8c regression: registered vector functions accept plain GQL list literals" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try expectApprox(5.0, try h.scalarNumber("RETURN vector_l2([0.0,0.0], [3.0,4.0]) AS d"));
    try expectApprox(1.0, try h.scalarNumber("RETURN vector_cosine([1.0,0.0], [1.0,0.0]) AS s"));
}

test "bug8b regression: an unresolved function is rejected instead of yielding NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    try testing.expectError(error.UnknownFunction, h.exec("RETURN totally_bogus_fn(1, 2) AS x"));
}

test "gap-0005 regression: a Double-valued aggregate compares in WHERE instead of TypeMismatch/silent-empty" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    _ = try h.exec("CREATE GRAPH b731avgcmp");
    _ = try h.exec("USE GRAPH b731avgcmp");
    _ = try h.exec("CREATE (:B731Score {value: 70})");
    _ = try h.exec("CREATE (:B731Score {value: 80})");
    _ = try h.exec("CREATE (:B731Score {value: 90})");

    // RED pre-fix: a3d4726d made avg() always Double, and the comparison arm
    // had no float branch — `a > 75` was TypeMismatch, which the post-WITH
    // filter swallowed into an empty result.
    try expectApprox(80.0, try h.scalarNumber("MATCH (s:B731Score) WITH avg(s.value) AS average WHERE average > 75 RETURN average AS a"));
    // Direct comparison surfaces as a Bool, not TypeMismatch.
    const r = try h.scalar("MATCH (s:B731Score) WITH avg(s.value) AS a RETURN a > 1 AS r");
    try testing.expect(r == .Bool and r.Bool);
    // Mixed float/int both directions.
    const r2 = try h.scalar("RETURN 1.5 > 1 AS r");
    try testing.expect(r2 == .Bool and r2.Bool);
    const r3 = try h.scalar("RETURN 1 >= 1.5 AS r");
    try testing.expect(r3 == .Bool and !r3.Bool);
}

test "issue #476: a non-vector scalar argument to the binary vector functions is NULL-propagated, not TypeMismatch" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    // RED pre-fix: the 3871d678 shared-coercion refactor turned the original
    // NULL-in/NULL-out contract for non-vector arguments into a hard
    // TypeMismatch. Real NULLs kept propagating; typed non-vectors errored.
    const c = try h.scalar("RETURN vector_cosine(42, 99) AS r");
    try testing.expect(c == .Null);
    const d = try h.scalar("RETURN vector_dot('not_a_vector', 42) AS r");
    try testing.expect(d == .Null);
    const l = try h.scalar("RETURN vector_l2('not_a_vector', 42) AS r");
    try testing.expect(l == .Null);

    // Controls that must not move: real NULL still propagates...
    const n = try h.scalar("RETURN vector_cosine(NULL, NULL) AS r");
    try testing.expect(n == .Null);
    // ...and a malformed ELEMENT inside a list literal stays a loud error —
    // the caller clearly meant a vector.
    try testing.expectError(error.TypeMismatch, h.exec("RETURN vector_l2([1.0, 'bad'], [1.0, 2.0]) AS r"));
}

test "bug8b residual: an unresolved function NESTED in an extended-registry call is rejected instead of collapsing to NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try vecHarness(&h);

    // The extended-registry arg-eval path swallowed non-propagatable errors to
    // NULL; UnknownFunction must propagate (SQLSTATE 42883), same as the bare
    // call above and the grouped projection path.
    try testing.expectError(error.UnknownFunction, h.exec("RETURN st_astext(totally_bogus_fn(1)) AS g"));
    try testing.expectError(error.UnknownFunction, h.exec("RETURN vector_dot(totally_bogus_fn(1), vectorf32([1.0,2.0])) AS d"));
}

test "bug8d: knn() with the implemented vector_knn signature returns a list" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    _ = try h.exec("CREATE GRAPH b731knn");
    _ = try h.exec("USE GRAPH b731knn");
    _ = try h.exec("CREATE (:B731Doc {title: 'a', embedding: vectorf32([1.0, 0.0])})");
    _ = try h.exec("CREATE (:B731Doc {title: 'b', embedding: vectorf32([0.0, 1.0])})");

    // The only knn shape the engine actually implements is vector_knn's:
    // (property_name STRING, query_vector, k INT, metric STRING) → LIST of ids.
    // `vector_knn(...)` with these exact arguments already returns a 2-element
    // list against this seed, so `knn` is a plain missing-alias (8a/8b).
    const v = try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 2, 'l2') AS ids");
    try testing.expect(v == .List);
    try testing.expectEqual(@as(usize, 2), v.List.len);

    // 8e: 'euclidean' is a synonym of 'l2' everywhere else (CREATE INDEX …
    // USING vector accepts it) — parseVectorMetric currently raises InvalidArgs.
    const e = try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 2, 'euclidean') AS ids");
    try testing.expect(e == .List);
    try testing.expectEqual(@as(usize, 2), e.List.len);
}

test "bug8d: the documented knn(prop, vec, k) form is rejected, not silently NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    _ = try h.exec("CREATE GRAPH b731knn2");
    _ = try h.exec("USE GRAPH b731knn2");
    _ = try h.exec("CREATE (:B731Doc {title: 'a', embedding: vectorf32([1.0, 0.0])})");

    // docs/@BUGS_731.md quotes `knn(d.embedding, $query_vector, 10)`: a VECTOR
    // (not a property NAME) as arg 0 and no metric. That cannot resolve to a
    // scannable property, so it must raise a diagnostic — today it silently
    // returns NULL.
    try h.expectRejected("MATCH (d:B731Doc) RETURN knn(d.embedding, vectorf32([1.0,0.0]), 10) AS ids");
}
