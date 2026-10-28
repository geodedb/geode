// SONNY-3189 (round 15, F1): a grouped HAVING with an operator chain as long
// as the parser takes is evaluated correctly; past the cap it is refused
// (42000); it never overflows a server thread.
//
// Round 14 capped an expression at `max_expr_links` (4096) links and turned
// the rewrite of a grouped HAVING (`grouped_having.Rewriter.rewrite`) into a
// loop over binary chains, but the walkers it calls on every link and every
// projection item still recursed once per link: `containsAggregate` and
// `mentionsAnyName` from `Rewriter.aggregate`, and `exprEql` from
// `Rewriter.matchSlot`, outside the rewrite's stack guard. The review's
// probes, through the real gRPC handler:
//   - `GROUP BY v HAVING sum(n.v + 0 + ... x4090) >= 0` crashed an 8 MiB
//     thread in ReleaseSafe (from about 2,700 links), and an 8 MiB and a
//     16 MiB one in Debug (from about 1,600);
//   - the item-equality form `RETURN n.v + 0 ... AS x, count(n) AS c GROUP BY
//     x HAVING n.v + 0 ... >= 0` crashed a 16 MiB thread in ReleaseSafe;
//   - the implicit HAVING `RETURN count(n) AS c WHERE sum(n.v + 0 ...) >= 0`
//     crashed as well.
//
// Now those walkers follow the left spine of a chain with a loop, and so does
// the rewrite for unary, member, index, slice and map-projection chains. Each
// shape below runs just under the cap (4090 repetitions) and just past it, on
// an 8 MiB thread (the gRPC connection threads') and a 16 MiB one (the QUIC
// workers'), through the real gRPC Execute and Pull handlers in process, and
// checks the rows, not only that it ran. Run the step in Debug and in
// ReleaseSafe (`-Doptimize=ReleaseSafe`): the frames differ several-fold.
//
// CANARY: REQ=REQ-SONNY-3189-HAVING-WALKERS; FEATURE="GroupedHaving"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3189_grouped_having_chains.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const limit: usize = geode.gql.parser.max_expr_links;

const grpc_conn_stack = 8 * 1024 * 1024;
const worker_stack = 16 * 1024 * 1024;
const stacks = [_]usize{ grpc_conn_stack, worker_stack };

/// Repetitions just under the cap (each shape's other links are fewer than
/// 6), and just past it.
const reps_under: usize = limit - 6;
const reps_over: usize = limit + 4;

/// What a shape answers with the seed (:C {v: 0}), (:C {v: 1}), (:C {v: 2}).
const Want = struct {
    rows: usize,
    /// The first column of the first row, when checked.
    first_int: ?i64 = null,
};

const Shape = struct {
    name: []const u8,
    head: []const u8,
    rep: []const u8,
    mid: []const u8 = "",
    rep2: []const u8 = "",
    tail: []const u8,
    want: Want,
};

const shapes = [_]Shape{
    // The review's F1 repro: an aggregate's argument, a hidden aggregate.
    .{ .name = "GROUP BY HAVING sum(+ chain)", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING sum(n.v", .rep = " + 0", .tail = ") >= 1", .want = .{ .rows = 2 } },
    .{ .name = "GROUP BY HAVING sum(+ chain) >= 0", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING sum(n.v", .rep = " + 0", .tail = ") >= 0", .want = .{ .rows = 3 } },
    .{ .name = "GROUP BY HAVING count(+ chain)", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING count(n.v", .rep = " + 0", .tail = ") > 0", .want = .{ .rows = 3 } },
    // The item-equality form: the HAVING's chain is the projected item's.
    .{ .name = "GROUP BY item-equality chain", .head = "MATCH (n:C) RETURN n.v", .rep = " + 0", .mid = " AS x, count(n) AS c GROUP BY x HAVING n.v", .rep2 = " + 0", .tail = " >= 1", .want = .{ .rows = 2 } },
    // A chain over a grouping key, and over an aggregate.
    .{ .name = "GROUP BY HAVING key + chain", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING v", .rep = " + 0", .tail = " >= 1", .want = .{ .rows = 2 } },
    .{ .name = "GROUP BY HAVING sum() + chain", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING sum(n.v)", .rep = " + 0", .tail = " >= 1", .want = .{ .rows = 2 } },
    // The implicit HAVING: a WHERE after a RETURN of aggregates only.
    .{ .name = "RETURN count() WHERE sum(+ chain)", .head = "MATCH (n:C) RETURN count(n) AS c WHERE sum(n.v", .rep = " + 0", .tail = ") >= 0", .want = .{ .rows = 1, .first_int = 3 } },
    .{ .name = "RETURN count() WHERE sum(+ chain) false", .head = "MATCH (n:C) RETURN count(n) AS c WHERE sum(n.v", .rep = " + 0", .tail = ") >= 4", .want = .{ .rows = 0 } },
    .{ .name = "RETURN count() WHERE count(+ chain)", .head = "MATCH (n:C) RETURN count(n) AS c WHERE count(n.v", .rep = " + 0", .tail = ") = 3", .want = .{ .rows = 1, .first_int = 3 } },
    // An aggregate's argument in the projection itself, grouped.
    .{ .name = "GROUP BY sum(+ chain) item", .head = "MATCH (n:C) RETURN n.v AS v, sum(n.v", .rep = " + 0", .tail = ") AS s GROUP BY v HAVING s >= 1", .want = .{ .rows = 2 } },
};

fn build(allocator: std.mem.Allocator, shape: Shape, n: usize) ![]u8 {
    var q = std.ArrayList(u8).empty;
    errdefer q.deinit(allocator);
    try q.ensureTotalCapacity(allocator, shape.head.len + (shape.rep.len + shape.rep2.len) * n + shape.mid.len + shape.tail.len);
    q.appendSliceAssumeCapacity(shape.head);
    var i: usize = 0;
    while (i < n) : (i += 1) q.appendSliceAssumeCapacity(shape.rep);
    q.appendSliceAssumeCapacity(shape.mid);
    i = 0;
    if (shape.rep2.len > 0) while (i < n) : (i += 1) q.appendSliceAssumeCapacity(shape.rep2);
    q.appendSliceAssumeCapacity(shape.tail);
    return q.toOwnedSlice(allocator);
}

/// Execute + Pull, as a client does, on its own thread.
const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    code: ?[]const u8 = null,
    message: []const u8 = "",
    rows: usize = 0,
    first: ?schema.Value = null,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 16 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| {
                self.rows = p.rows.items.len;
                if (p.rows.items.len > 0 and p.rows.items[0].values.items.len > 0) self.first = p.rows.items[0].values.items[0];
            },
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
            },
            else => return error.UnexpectedPayload,
        }
    }
};

fn runOn(stack: usize, ga: std.mem.Allocator, session: []const u8, query: []const u8) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query };
    const t = try std.Thread.spawn(.{ .stack_size = stack }, Run.go, .{&r});
    t.join();
    if (r.err) |e| {
        r.code = try std.fmt.allocPrint(ga, "zig:{s}", .{@errorName(e)});
        r.err = null;
    }
    return r;
}

fn intOf(v: ?schema.Value) ?i64 {
    const val = v orelse return null;
    const k = val.kind orelse return null;
    return switch (k) {
        .int_val => |x| x.value,
        else => null,
    };
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
}

fn monoMs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "SONNY-3189: a grouped or implicit HAVING with a chain just under max_expr_links is evaluated correctly, and one past it refused (42000), on 8 MiB and 16 MiB threads over gRPC" {
    const allocator = testing.allocator;
    var failures: usize = 0;
    for (shapes) |shape| {
        // A fixture per shape: every request stays in its arena.
        var f: fx.Fixture = undefined;
        try f.init();
        defer f.deinit();
        const ga = f.ga();
        const s = try f.session("having-chains");
        try seed(ga, s);
        // One repetition: the shape answers what it should at all.
        {
            const q = try build(allocator, shape, 1);
            defer allocator.free(q);
            const r = try runOn(worker_stack, ga, s, q);
            const ok = r.code == null and r.rows == shape.want.rows and
                (shape.want.first_int == null or intOf(r.first) == shape.want.first_int.?);
            std.debug.print("{s} reps=1 -> {s} rows={d} first={any}{s}\n", .{ shape.name, r.code orelse "ran", r.rows, intOf(r.first), if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
        for ([_]usize{ reps_under, reps_over }) |reps| {
            const q = try build(allocator, shape, reps);
            defer allocator.free(q);
            for (stacks) |stack| {
                const t0 = monoMs();
                const r = try runOn(stack, ga, s, q);
                const ok = if (reps == reps_under)
                    r.code == null and r.rows == shape.want.rows and
                        (shape.want.first_int == null or intOf(r.first) == shape.want.first_int.?)
                else
                    r.code != null and std.mem.eql(u8, r.code.?, "42000");
                std.debug.print("{s} reps={d} {d} MiB -> {s} {s} rows={d} first={any} ({d} ms){s}\n", .{
                    shape.name,                            reps,   stack >> 20,    r.code orelse "ran",
                    r.message[0..@min(r.message.len, 80)], r.rows, intOf(r.first), monoMs() - t0,
                    if (ok) "" else "  <-- UNEXPECTED",
                });
                if (!ok) failures += 1;
            }
        }
        // The session still serves.
        try fx.expectRuns(ga, s, "MATCH (n:C) RETURN count(n) AS c");
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-3189: a HAVING with a long AND chain or member chain is evaluated as with one link, never overflowing" {
    const allocator = testing.allocator;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("having-postfix");
    try seed(ga, s);
    var failures: usize = 0;
    const Case = struct { name: []const u8, shape: Shape, reps: usize };
    const grouped = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING ";
    const cases = [_]Case{
        // 3 links a repetition.
        .{ .name = "HAVING AND chain", .reps = (limit - 8) / 3, .shape = .{ .name = "", .head = grouped ++ "c > 0", .rep = " AND c > 0", .tail = " AND v >= 1", .want = .{ .rows = 2 } } },
        .{ .name = "HAVING member chain", .reps = limit - 8, .shape = .{ .name = "", .head = grouped ++ "{a: v}.a", .rep = ".b", .tail = " IS NULL", .want = .{ .rows = 0 } } },
    };
    for (cases) |c| {
        // What the shape answers with one link: the rows to expect.
        const one_q = try build(allocator, c.shape, 1);
        defer allocator.free(one_q);
        const one = try runOn(worker_stack, ga, s, one_q);
        std.debug.print("{s} reps=1 -> {s} {s} rows={d}\n", .{ c.name, one.code orelse "ran", one.message[0..@min(one.message.len, 80)], one.rows });
        if (one.code != null) failures += 1;
        const q = try build(allocator, c.shape, c.reps);
        defer allocator.free(q);
        for (stacks) |stack| {
            const r = try runOn(stack, ga, s, q);
            // Evaluated as with one link. (Index and slice chains:
            // tests/test_sonny3251_limit_errors.zig.)
            const ok = r.code == null and r.rows == one.rows;
            std.debug.print("{s} reps={d} {d} MiB -> {s} {s} rows={d}{s}\n", .{ c.name, c.reps, stack >> 20, r.code orelse "ran", r.message[0..@min(r.message.len, 80)], r.rows, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    try fx.expectRuns(ga, s, "RETURN 1 AS x");
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-3189: a planned read with a hop analyses index and slice chains in RETURN, GROUP BY and HAVING with loops, never overflowing" {
    // `planned_read_runtime.analyzeExprForProjection` walks every item, key,
    // HAVING and ORDER BY key of a planned read with a hop; an index or slice
    // link recursed on its target with no stack guard.
    const allocator = testing.allocator;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("hop-chains");
    try seed(ga, s);
    try fx.expectRuns(ga, s, "MATCH (a:C {v: 0}), (b:C {v: 1}) CREATE (a)-[:R {w: 1}]->(b)");
    var failures: usize = 0;
    const hop = "MATCH (a:C)-[:R]->(b:C) ";
    const Case = struct { name: []const u8, shape: Shape };
    const cases = [_]Case{
        .{ .name = "RETURN index chain", .shape = .{ .name = "", .head = hop ++ "RETURN [null, a.v][0]", .rep = "[0]", .tail = " IS NULL AS x", .want = .{ .rows = 1 } } },
        .{ .name = "RETURN slice chain", .shape = .{ .name = "", .head = hop ++ "RETURN size([a.v, 1]", .rep = "[0..2]", .tail = ") AS x", .want = .{ .rows = 1, .first_int = 2 } } },
        .{ .name = "GROUP BY HAVING + chain", .shape = .{ .name = "", .head = hop ++ "RETURN a.v AS v, count(b) AS c GROUP BY v HAVING sum(b.v", .rep = " + 0", .tail = ") = 1", .want = .{ .rows = 1, .first_int = 0 } } },
    };
    for (cases) |c| {
        const q = try build(allocator, c.shape, limit - 8);
        defer allocator.free(q);
        for (stacks) |stack| {
            const r = try runOn(stack, ga, s, q);
            const ran_ok = r.code == null and r.rows == c.shape.want.rows and
                (c.shape.want.first_int == null or intOf(r.first) == c.shape.want.first_int.?);
            // The evaluator's stack guard may refuse a postfix chain it
            // still evaluates with recursion (54001, SONNY-3251 F7).
            const refused_ok = r.code != null and std.mem.eql(u8, r.code.?, "54001");
            const ok = ran_ok or refused_ok;
            std.debug.print("{s} reps={d} {d} MiB -> {s} {s} rows={d} first={any}{s}\n", .{ c.name, limit - 8, stack >> 20, r.code orelse "ran", r.message[0..@min(r.message.len, 80)], r.rows, intOf(r.first), if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    try fx.expectRuns(ga, s, "RETURN 1 AS x");
    try testing.expectEqual(@as(usize, 0), failures);
}
