// CANARY: REQ=REQ-GQL-FOR-RETURN-AGGREGATION; FEATURE="ForStatement"; ASPECT=ReturnAggregation; STATUS=TESTED; TEST=tests/test_for_aggregation.zig:1; OWNER=engine; UPDATED=2026-10-11
//
// `FOR ... RETURN` projected each element on its own:
//
//   * `FOR x IN [1, 2, 3] RETURN sum(x)` returned three rows of NULL, not one
//     row of 6 (count, avg, min, max and collect failed with UnknownFunction);
//   * `FOR x IN [1, 2, 3] RETURN x` named its column `?column?`, not `x`;
//   * the RETURN's DISTINCT, ORDER BY, SKIP and LIMIT were ignored;
//   * `MATCH (n) WITH n FOR x IN n.list RETURN x` returned one NULL per node,
//     and with an aggregate aggregated the MATCH's rows instead of the loop's;
//   * `MATCH (n) FOR x IN n.list ...` and a nested `FOR ... FOR ...` were
//     syntax errors.
//
// ISO/IEC 39075 FOR extends the working table, one row per element, and the
// RETURN after it projects that table: an aggregate is a set function over
// all of its rows, as after a MATCH. Geode's RETURN after a MATCH requires a
// GROUP BY next to a non-aggregated item (42803), names a bare variable's
// column after it and a property's after the property, and with no rows
// returns one row with sum NULL and count 0. A FOR's RETURN now does the same.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

// The graph_store/catalog instances are process-wide. Serialize every test
// that touches them (tests/test_for_write_body.zig does the same).
var test_mutex: std.Io.Mutex = .init;

fn lockStore() void {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
}

fn unlockStore() void {
    test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

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

    fn init(allocator: std.mem.Allocator) !Harness {
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

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = geode.parseGqlOptions(query, aa, .{}) catch |err| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {any}\n", .{ query, err });
            return err;
        };
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// The result's rows rendered `a|b|...` and sorted, so a check does not
    /// depend on the order of groups.
    fn rowSet(self: *Harness, query: []const u8) ![]const []const u8 {
        const res = try self.exec(query);
        const aa = self.arena.allocator();
        const out = try aa.alloc([]const u8, res.rows.len);
        for (res.rows, out) |row, *line| {
            var buf: std.Io.Writer.Allocating = .init(aa);
            for (row, 0..) |value, i| {
                if (i > 0) try buf.writer.writeByte('|');
                try render(&buf.writer, value);
            }
            line.* = buf.written();
        }
        std.mem.sort([]const u8, out, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return out;
    }

    /// The rows rendered as `rowSet` does, in the result's order.
    fn rowList(self: *Harness, query: []const u8) ![]const []const u8 {
        const res = try self.exec(query);
        const aa = self.arena.allocator();
        const out = try aa.alloc([]const u8, res.rows.len);
        for (res.rows, out) |row, *line| {
            var buf: std.Io.Writer.Allocating = .init(aa);
            for (row, 0..) |value, i| {
                if (i > 0) try buf.writer.writeByte('|');
                try render(&buf.writer, value);
            }
            line.* = buf.written();
        }
        return out;
    }

    fn columns(self: *Harness, query: []const u8) ![]const []const u8 {
        const res = try self.exec(query);
        return res.columns;
    }
};

fn render(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .Null => try w.writeAll("null"),
        .Int => |i| try w.print("{d}", .{i}),
        .Double => |f| try w.print("{d}", .{f}),
        .Real => |f| try w.print("{d}", .{f}),
        .Decimal => |d| {
            // coeff * 10^-scale, trailing fraction zeros dropped.
            var coeff = d.coeff;
            var scale = d.scale;
            while (scale > 0 and @rem(coeff, 10) == 0) : (scale -= 1) coeff = @divTrunc(coeff, 10);
            if (scale == 0) return w.print("{d}", .{coeff});
            if (coeff < 0) try w.writeByte('-');
            const mag: u128 = @abs(coeff);
            const pow = std.math.powi(u128, 10, scale) catch unreachable;
            try w.print("{d}.", .{mag / pow});
            var frac = mag % pow;
            var digits = scale;
            var div = pow / 10;
            while (digits > 0) : (digits -= 1) {
                try w.print("{d}", .{frac / div});
                frac %= div;
                div /= 10;
            }
        },
        .Bool => |b| try w.writeAll(if (b) "true" else "false"),
        .Str => |s| try w.writeAll(s),
        .List => |list| {
            try w.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try render(w, item);
            }
            try w.writeByte(']');
        },
        else => try w.print("{s}", .{@tagName(value)}),
    }
}

fn expectRows(got: []const []const u8, want: []const []const u8) !void {
    if (got.len != want.len) {
        std.debug.print("\nrows: got {d}, want {d}\n", .{ got.len, want.len });
        for (got) |g| std.debug.print("  got: {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("\nrow: got {s}, want {s}\n", .{ g, w });
            return error.TestExpectedEqual;
        }
    }
}

fn expectColumns(got: []const []const u8, want: []const []const u8) !void {
    if (got.len != want.len) {
        std.debug.print("\ncolumns: got {d}, want {d}\n", .{ got.len, want.len });
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("\ncolumn: got {s}, want {s}\n", .{ g, w });
            return error.TestExpectedEqual;
        }
    }
}

fn withHarness(comptime body: fn (h: *Harness) anyerror!void) !void {
    lockStore();
    defer unlockStore();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try body(&h);
}

// ===========================================================================
// Aggregates over the loop's rows.
// ===========================================================================

test "FOR ... RETURN sum(x) is one row with the total" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, 2, 3] RETURN sum(x)"), &.{"6"});
            try expectRows(try h.rowSet("FOR x IN [1, 2, 3] RETURN sum(x) AS total"), &.{"6"});
            try expectRows(try h.rowSet("FOR x IN [1.5, 2.5] RETURN sum(x) AS total"), &.{"4"});
        }
    }.run);
}

test "FOR ... RETURN count(x) and count(*)" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, null, 3] RETURN count(x) AS c, count(*) AS n"), &.{"2|3"});
        }
    }.run);
}

test "FOR ... RETURN avg(x)" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, 2, 3, 4] RETURN avg(x) AS a"), &.{"2.5"});
        }
    }.run);
}

test "FOR ... RETURN min(x) and max(x)" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [3, 1, 4, 1, 5] RETURN min(x) AS lo, max(x) AS hi"), &.{"1|5"});
            try expectRows(try h.rowSet("FOR s IN ['pear', 'apple', 'fig'] RETURN min(s) AS lo, max(s) AS hi"), &.{"apple|pear"});
        }
    }.run);
}

test "FOR ... RETURN collect(x)" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, 2, 3] RETURN collect(x) AS xs"), &.{"[1,2,3]"});
        }
    }.run);
}

test "FOR ... RETURN aggregates of an expression over the loop variable" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, 2, 3] RETURN sum(x * 10) AS s, count(*) AS c"), &.{"60|3"});
            try expectRows(try h.rowSet("FOR m IN [{v: 2}, {v: 5}] RETURN sum(m.v) AS s"), &.{"7"});
        }
    }.run);
}

test "FOR ... WITH ORDINALITY: the ordinality aggregates too" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [5, 6, 7] WITH ORDINALITY i RETURN sum(i) AS s, max(x) AS m"), &.{"6|7"});
        }
    }.run);
}

// ===========================================================================
// Grouping.
// ===========================================================================

test "FOR ... RETURN key, count(*) GROUP BY key groups the loop's rows" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [1, 1, 2] RETURN x, count(*) AS c GROUP BY x"), &.{ "1|2", "2|1" });
            try expectRows(try h.rowSet("FOR x IN ['a', 'b', 'a', 'a'] RETURN x AS k, sum(1) AS n GROUP BY k"), &.{ "a|3", "b|1" });
        }
    }.run);
}

test "FOR ... RETURN key, count(*) without GROUP BY is a grouping error, as after MATCH" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            _ = try h.exec("CREATE (:ForAggG {k: 1})");
            try testing.expectError(error.GroupingError, h.exec("MATCH (n:ForAggG) RETURN n.k, count(*)"));
            try testing.expectError(error.GroupingError, h.exec("FOR x IN [1, 1, 2] RETURN x, count(*)"));
        }
    }.run);
}

// ===========================================================================
// An empty list.
// ===========================================================================

test "FOR over an empty list: sum is NULL and count is 0, as after MATCH" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            // The MATCH baseline the FOR must agree with.
            try expectRows(try h.rowSet("MATCH (n:ForAggNone) RETURN sum(n.v) AS s, count(*) AS c, count(n.v) AS cv"), &.{"null|0|0"});
            try expectRows(try h.rowSet("FOR x IN [] RETURN sum(x) AS s, count(*) AS c, count(x) AS cv"), &.{"null|0|0"});
            try expectRows(try h.rowSet("FOR x IN [] RETURN avg(x) AS a, min(x) AS lo, max(x) AS hi, collect(x) AS xs"), &.{"null|null|null|[]"});
            // A null list has no element either.
            try expectRows(try h.rowSet("FOR x IN null RETURN count(*) AS c"), &.{"0"});
            // Grouped, no row has a group.
            try expectRows(try h.rowSet("FOR x IN [] RETURN x, count(*) AS c GROUP BY x"), &.{});
        }
    }.run);
}

// ===========================================================================
// Nested FOR.
// ===========================================================================

test "nested FOR aggregates over the rows of both loops" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("FOR x IN [[1, 2], [3]] FOR y IN x RETURN sum(y) AS s, count(*) AS c"), &.{"6|3"});
            try expectRows(try h.rowList("FOR x IN [[1, 2], [3]] FOR y IN x RETURN y"), &.{ "1", "2", "3" });
            try expectRows(try h.rowSet("FOR a IN [1, 2] FOR b IN [10, 20] RETURN a, sum(b) AS s GROUP BY a"), &.{ "1|30", "2|30" });
            try expectRows(try h.rowSet("FOR x IN [[1, 2], []] FOR y IN x RETURN count(*) AS c"), &.{"2"});
            // Only a RETURN may follow a nested FOR: a write body runs once
            // per element of one list.
            try testing.expectError(error.UnexpectedToken, geode.parseGqlOptions("FOR x IN [[1]] FOR y IN x CREATE (:T {v: y})", h.arena.allocator(), .{}));
        }
    }.run);
}

// ===========================================================================
// FOR after MATCH (and after WITH).
// ===========================================================================

fn seedLists(h: *Harness) !void {
    _ = try h.exec("CREATE (:ForAggL {g: 'a', list: [1, 2, 3]})");
    _ = try h.exec("CREATE (:ForAggL {g: 'b', list: [10, 20]})");
}

test "MATCH ... FOR x IN n.list RETURN sum(x) sums every matched row's list" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try seedLists(h);
            try expectRows(try h.rowSet("MATCH (n:ForAggL) FOR x IN n.list RETURN sum(x) AS s"), &.{"36"});
            try expectRows(try h.rowSet("MATCH (n:ForAggL) FOR x IN n.list RETURN n.g, sum(x) AS s GROUP BY n.g"), &.{ "a|6", "b|30" });
            try expectRows(try h.rowSet("MATCH (n:ForAggL) WHERE n.g = 'b' FOR x IN n.list RETURN count(*) AS c, max(x) AS m"), &.{"2|20"});
            try expectRows(try h.rowSet("MATCH (n:ForAggL) FOR x IN n.list RETURN x"), &.{ "1", "10", "2", "20", "3" });
            // Every variable of the pattern is in scope after it.
            _ = try h.exec("MATCH (a:ForAggL {g: 'a'}), (b:ForAggL {g: 'b'}) CREATE (a)-[:ForAggR {w: [4, 5]}]->(b)");
            try expectRows(try h.rowSet("MATCH p = (a:ForAggL)-[r:ForAggR]->(b) FOR x IN r.w RETURN a.g, b.g, sum(x) AS s GROUP BY a.g, b.g"), &.{"a|b|9"});
        }
    }.run);
}

test "MATCH ... WITH n FOR x IN n.list binds x for every row" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try seedLists(h);
            try expectRows(try h.rowSet("MATCH (n:ForAggL) WITH n FOR x IN n.list RETURN x"), &.{ "1", "10", "2", "20", "3" });
            try expectRows(try h.rowSet("MATCH (n:ForAggL) WITH n FOR x IN n.list RETURN sum(x) AS s"), &.{"36"});
            try expectRows(try h.rowSet("MATCH (n:ForAggNone) WITH n FOR x IN n.list RETURN sum(x) AS s, count(*) AS c"), &.{"null|0"});
        }
    }.run);
}

test "WITH ... FOR x IN l RETURN sum(x)" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowSet("WITH [1, 2, 3] AS l FOR x IN l RETURN sum(x) AS s"), &.{"6"});
            try expectRows(try h.rowSet("WITH [1, 1, 2] AS l FOR x IN l RETURN x, count(*) AS c GROUP BY x"), &.{ "1|2", "2|1" });
        }
    }.run);
}

// ===========================================================================
// DISTINCT, ORDER BY, SKIP and LIMIT apply to the RETURN.
// ===========================================================================

test "FOR ... RETURN applies DISTINCT, ORDER BY, SKIP and LIMIT" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectRows(try h.rowList("FOR x IN [3, 1, 2] RETURN x ORDER BY x DESC LIMIT 2"), &.{ "3", "2" });
            try expectRows(try h.rowList("FOR x IN [3, 1, 2] RETURN x ORDER BY x SKIP 1"), &.{ "2", "3" });
            try expectRows(try h.rowSet("FOR x IN [1, 1, 2] RETURN DISTINCT x"), &.{ "1", "2" });
            try expectRows(try h.rowList("FOR x IN [1, 1, 2, 3] RETURN x, count(*) AS c GROUP BY x ORDER BY c DESC, x LIMIT 2"), &.{ "1|2", "2|1" });
        }
    }.run);
}

// ===========================================================================
// Column names: as a RETURN after a MATCH names them.
// ===========================================================================

test "FOR ... RETURN x names its column x" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try expectColumns(try h.columns("FOR x IN [1, 2, 3] RETURN x"), &.{"x"});
            try expectColumns(try h.columns("FOR x IN [1] WITH ORDINALITY i RETURN x, i"), &.{ "x", "i" });
            try expectColumns(try h.columns("FOR x IN [1] WITH OFFSET o RETURN o, x AS y"), &.{ "o", "y" });
            try expectColumns(try h.columns("FOR x IN [[1]] FOR y IN x RETURN x, y"), &.{ "x", "y" });
            try expectColumns(try h.columns("WITH [1] AS l FOR x IN l RETURN x"), &.{"x"});
        }
    }.run);
}

test "FOR column names match MATCH's for properties and aggregates" {
    try withHarness(struct {
        fn run(h: *Harness) !void {
            try seedLists(h);
            // MATCH: a property is named after the property, an aggregate
            // after its function.
            try expectColumns(try h.columns("MATCH (n:ForAggL) RETURN n.g"), &.{"g"});
            try expectColumns(try h.columns("MATCH (n:ForAggL) RETURN count(n.g)"), &.{"count"});
            try expectColumns(try h.columns("FOR m IN [{g: 1}] RETURN m.g"), &.{"g"});
            try expectColumns(try h.columns("FOR x IN [1, 2, 3] RETURN count(x)"), &.{"count"});
            try expectColumns(try h.columns("FOR x IN [1, 2, 3] RETURN sum(x)"), &.{"sum"});
            try expectColumns(try h.columns("MATCH (n:ForAggL) FOR x IN n.list RETURN n.g, x GROUP BY n.g, x"), &.{ "g", "x" });
            try expectColumns(try h.columns("MATCH (n:ForAggL) WITH n FOR x IN n.list RETURN x"), &.{"x"});
        }
    }.run);
}
