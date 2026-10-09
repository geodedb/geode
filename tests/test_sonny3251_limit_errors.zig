// SONNY-3251 (round 15, F6, F7): a resource limit the evaluator runs into
// (54001, the expression nests past the thread's stack) fails the query; it
// is never answered as a row that did not match. And postfix chains (index,
// slice, member, map projection) are evaluated with a loop, so the parser's
// cap of 4096 links is the real limit for them.
//
// The round 14 review:
//   - F6: about 140 sites turn an evaluation error into false, NULL, 0 or a
//     skipped row (the WHERE filters, e.g. planned_read_runtime's, the
//     projection cells, the aggregates' arguments, EXISTS and COUNT { }), and
//     `isQueryLevelEvalError` did not list ExpressionTooDeep. `MATCH (n:C)
//     WHERE size([n.v, 1][0..2] ... x4000) = 2 RETURN count(n)` answered 0
//     rows instead of 54001 (ReleaseSafe, 8 MiB); WITH ... WHERE and EXISTS
//     the same;
//   - F7: index, slice and call links count toward the cap but were
//     evaluated with recursion, so such a chain of 4000 links got 54001.
//
// Now the evaluator loops every postfix chain (`evalPostfixChain`), the
// sites that decide a query's rows pass limit errors on
// (`eval.isResourceLimitError`), `isQueryLevelEvalError` lists
// ExpressionTooDeep, and every other site is covered by the statement
// chokepoint, which fails the statement with a limit the evaluator recorded
// (`eval.noteLimitError`). The reviewer's shapes evaluate correctly now; the
// refusal itself is forced with the evaluator's test seam
// (`eval.test_force_expression_too_deep`) in every context, and must come
// back as 54001. Through the real gRPC handler, on 8 MiB and 16 MiB threads.
// Run the step in Debug and ReleaseSafe.
//
// CANARY: REQ=REQ-SONNY-3251-LIMIT-ERRORS; FEATURE="ExpressionEvaluator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3251_limit_errors.zig; OWNER=eval; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const limit: usize = geode.gql.parser.max_expr_links;
const stacks = [_]usize{ 8 * 1024 * 1024, 16 * 1024 * 1024 };

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    force_too_deep: bool = false,
    code: ?[]const u8 = null,
    message: []const u8 = "",
    rows: usize = 0,
    first: ?schema.Value = null,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        geode.eval.test_force_expression_too_deep = self.force_too_deep;
        defer geode.eval.test_force_expression_too_deep = false;
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

fn runOn(stack: usize, ga: std.mem.Allocator, session: []const u8, query: []const u8, force_too_deep: bool) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query, .force_too_deep = force_too_deep };
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

fn boolOf(v: ?schema.Value) ?bool {
    const val = v orelse return null;
    const k = val.kind orelse return null;
    return switch (k) {
        .bool_val => |b| b,
        else => null,
    };
}

fn build(allocator: std.mem.Allocator, head: []const u8, rep: []const u8, n: usize, tail: []const u8) ![]u8 {
    var q = std.ArrayList(u8).empty;
    errdefer q.deinit(allocator);
    try q.ensureTotalCapacity(allocator, head.len + rep.len * n + tail.len);
    q.appendSliceAssumeCapacity(head);
    var i: usize = 0;
    while (i < n) : (i += 1) q.appendSliceAssumeCapacity(rep);
    q.appendSliceAssumeCapacity(tail);
    return q.toOwnedSlice(allocator);
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
    try fx.expectRuns(ga, s, "MATCH (a:C {v: 0}), (b:C {v: 1}) CREATE (a)-[:R]->(b)");
}

const Want = union(enum) {
    int: i64,
    boolean: bool,
    rows: usize,
};

const Chain = struct { name: []const u8, head: []const u8, rep: []const u8, tail: []const u8, reps: usize, want: Want };

test "SONNY-3251: the review's chain shapes (slice, index, member and mixed postfix chains) evaluate correctly just under the cap in WHERE, RETURN, WITH ... WHERE, EXISTS and HAVING, on 8 MiB and 16 MiB threads" {
    const allocator = testing.allocator;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("chains");
    try seed(ga, s);
    const slice4000 = limit - 96;
    const chains = [_]Chain{
        // The review's shapes (shapes4.py): 0 rows at 23159b1f.
        .{ .name = "WHERE slice x100", .head = "MATCH (n:C) WHERE size([n.v, 1]", .rep = "[0..2]", .tail = ") = 2 RETURN count(n) AS c", .reps = 100, .want = .{ .int = 3 } },
        .{ .name = "WHERE slice x4000", .head = "MATCH (n:C) WHERE size([n.v, 1]", .rep = "[0..2]", .tail = ") = 2 RETURN count(n) AS c", .reps = slice4000, .want = .{ .int = 3 } },
        .{ .name = "RETURN slice x4000", .head = "MATCH (n:C) RETURN size([n.v, 1]", .rep = "[0..2]", .tail = ") AS c", .reps = slice4000, .want = .{ .int = 2 } },
        .{ .name = "WITH ... WHERE slice x4000", .head = "MATCH (n:C) WITH n WHERE size([n.v, 1]", .rep = "[0..2]", .tail = ") = 2 RETURN count(n) AS c", .reps = slice4000, .want = .{ .int = 3 } },
        .{ .name = "EXISTS slice x4000", .head = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE size([m.v, 1]", .rep = "[0..2]", .tail = ") = 2 } RETURN count(n) AS c", .reps = slice4000, .want = .{ .int = 3 } },
        // Index, member and mixed chains.
        .{ .name = "RETURN index x4000", .head = "RETURN [null, 1][0]", .rep = "[0]", .tail = " IS NULL AS x", .reps = limit - 8, .want = .{ .boolean = true } },
        .{ .name = "WHERE index x4000", .head = "MATCH (n:C) WHERE [n.v][0]", .rep = "[0]", .tail = " IS NULL RETURN count(n) AS c", .reps = limit - 8, .want = .{ .int = 3 } },
        .{ .name = "RETURN mixed [0].a x2000", .head = "WITH [{a: [{a: null}]}] AS l RETURN l", .rep = "[0].a", .tail = " IS NULL AS x", .reps = (limit - 8) / 2, .want = .{ .boolean = true } },
        .{ .name = "RETURN projection chain", .head = "WITH {a: 1} AS m RETURN m", .rep = "{.a}", .tail = ".a AS x", .reps = limit - 8, .want = .{ .int = 1 } },
        // Grouped: the HAVING's chain (planned read with a hop, and not).
        .{ .name = "GROUP BY HAVING slice x4000", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING size([v, 1]", .rep = "[0..2]", .tail = ") = 2", .reps = limit - 8, .want = .{ .rows = 3 } },
        .{ .name = "GROUP BY HAVING index x4000", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING [null, v][0]", .rep = "[0]", .tail = " IS NULL", .reps = limit - 8, .want = .{ .rows = 3 } },
        .{ .name = "hop GROUP BY HAVING slice x4000", .head = "MATCH (a:C)-[:R]->(b:C) RETURN a.v AS v, count(b) AS c GROUP BY v HAVING size([v, 1]", .rep = "[0..2]", .tail = ") = 2", .reps = limit - 8, .want = .{ .rows = 1 } },
        .{ .name = "hop RETURN index x4000", .head = "MATCH (a:C)-[:R]->(b:C) RETURN [null, a.v][0]", .rep = "[0]", .tail = " IS NULL AS x", .reps = limit - 8, .want = .{ .boolean = true } },
        // Past the cap: refused by the parser.
        .{ .name = "WHERE slice past the cap", .head = "MATCH (n:C) WHERE size([n.v, 1]", .rep = "[0..2]", .tail = ") = 2 RETURN count(n) AS c", .reps = limit + 8, .want = .{ .rows = 0 } },
    };
    var failures: usize = 0;
    for (chains) |c| {
        const q = try build(allocator, c.head, c.rep, c.reps, c.tail);
        defer allocator.free(q);
        for (stacks) |stack| {
            const r = try runOn(stack, ga, s, q, false);
            const ok = if (c.reps > limit)
                r.code != null and std.mem.eql(u8, r.code.?, "42000")
            else
                r.code == null and switch (c.want) {
                    .int => |w| intOf(r.first) == w,
                    .boolean => |w| boolOf(r.first) == w,
                    .rows => |w| r.rows == w,
                };
            std.debug.print("{s} reps={d} {d} MiB -> {s} {s} rows={d} first={any}{s}\n", .{ c.name, c.reps, stack >> 20, r.code orelse "ran", r.message[0..@min(r.message.len, 80)], r.rows, if (r.first) |v| v.kind else null, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    try fx.expectRuns(ga, s, "RETURN 1 AS x");
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-3251: a refusal of the evaluator's stack guard (54001) fails the query in every context: WHERE, WITH ... WHERE, EXISTS, COUNT, HAVING, an aggregate, a function argument, a projection, a hop" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("refusals");
    try seed(ga, s);
    const queries = [_][]const u8{
        "MATCH (n:C) WHERE n.v >= 0 RETURN n.v AS v",
        "MATCH (n:C) WHERE n.v >= 0 RETURN count(n) AS c",
        "MATCH (n:C) WITH n WHERE n.v >= 0 RETURN count(n) AS c",
        "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v >= 0 } RETURN count(n) AS c",
        "MATCH (n:C) RETURN COUNT { MATCH (m:C) WHERE m.v >= n.v } AS c",
        "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING c > 0",
        "MATCH (n:C) RETURN count(n) AS c WHERE c > 0",
        "MATCH (n:C) RETURN sum(n.v * 2) AS s",
        "MATCH (n:C) RETURN coalesce(n.v, 1) AS x",
        "MATCH (n:C) RETURN n.v + 1 AS x ORDER BY x",
        "MATCH (a:C)-[:R]->(b:C) WHERE b.v >= 0 RETURN count(a) AS c",
        "MATCH (a:C)-[:R]->(b:C) RETURN a.v AS v, count(b) AS c GROUP BY v",
        "RETURN 1 + 1 AS x",
    };
    var failures: usize = 0;
    for (queries) |q| {
        for (stacks) |stack| {
            const r = try runOn(stack, ga, s, q, true);
            const ok = r.code != null and std.mem.eql(u8, r.code.?, "54001");
            std.debug.print("forced 54001: {s} {d} MiB -> {s} rows={d} first={any}{s}\n", .{ q, stack >> 20, r.code orelse "ran", r.rows, if (r.first) |v| v.kind else null, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
        // Without the refusal, the next query on the session answers.
        const again = try runOn(stacks[0], ga, s, "MATCH (n:C) RETURN count(n) AS c", false);
        if (again.code != null or intOf(again.first) != 3) {
            std.debug.print("after {s}: {s} {any}  <-- UNEXPECTED\n", .{ q, again.code orelse "ran", intOf(again.first) });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
