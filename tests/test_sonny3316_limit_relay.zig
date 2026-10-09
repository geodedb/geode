// SONNY-3316 regression (round 16, I4 and M2).
//
// I4: SONNY-3251's limit relay had gaps.
//   - A parallel UNION arm runs on a thread of its own, outside the
//     statement's scope, so the limit it recorded (thread-local) was lost and
//     the UNION answered as if the arm's rows did not match. The arm now opens
//     its own scope and fails with its record (`ArmJob.runnerEntry`).
//   - Only the stack guard's `ExpressionTooDeep` was recorded; an out of
//     memory (53200), the read budget or a cancel swallowed by a WHERE, a cell
//     or an aggregate became an answer. `eval.evalExpr` records every
//     `isResourceLimitError` now.
//   - `node_scan_stream`'s index seek and inline-property match turned a
//     limit into "cannot seek" / "no match"; they fail the read now.
// M2: `Rewriter.rewriteChain` asked `matchSlot` at every link of a HAVING
//   chain, and `exprEql` walked each projection item down with it: K items
//   of N links cost O(K*N^2) (K=32, N=4088: 20 s). Only items and keys of the
//   link's chain length are compared now: under 2 s in ReleaseSafe.
//
// Through the real gRPC handler in process. Run it in Debug and ReleaseSafe.
//
// CANARY: REQ=REQ-SONNY-3316-LIMIT-RELAY; FEATURE="ExpressionEvaluator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3316_limit_relay.zig; OWNER=eval; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const eval = geode.eval;
const limit: usize = geode.gql.parser.max_expr_links;

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    force: ?eval.EvalError = null,
    code: ?[]const u8 = null,
    rows: usize = 0,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        eval.test_force_limit_error = self.force;
        defer eval.test_force_limit_error = null;
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| self.rows = p.rows.items.len,
            .@"error" => |e| self.code = e.code,
            else => return error.UnexpectedPayload,
        }
    }
};

fn runOn(ga: std.mem.Allocator, session: []const u8, query: []const u8, force: ?eval.EvalError) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query, .force = force };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Run.go, .{&r});
    t.join();
    return r;
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
}

/// Where the evaluator's test seam fails (`eval.test_force_limit_marker`).
const L = "'" ++ eval.test_force_limit_marker ++ "'";

/// Places a caller turns an evaluation error into a value or a skipped row
/// (found with the relay removed: each of these answered rows).
const swallowing = [_][]const u8{
    "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v = n.v AND " ++ L ++ " = 'x' } RETURN n.v AS v",
    "MATCH (n:C) RETURN COUNT { MATCH (m:C) WHERE " ++ L ++ " = 'x' } AS v",
    "MATCH (n:C) RETURN n.v AS v ORDER BY " ++ L,
};

test "SONNY-3316 (I4): a limit a parallel UNION arm runs into on its own thread fails the UNION (54001)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3316a");
    try seed(ga, s);
    // The first arm runs on a thread of its own, the last on the calling one;
    // the seam fails the marker on the arm threads only.
    const tail = " UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v";
    const queries = [_][]const u8{
        "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v = n.v AND " ++ L ++ " = 'x' } RETURN n.v AS v" ++ tail,
        "MATCH (n:C) WHERE n.v >= 0 RETURN COUNT { MATCH (m:C) WHERE " ++ L ++ " = 'x' } AS v" ++ tail,
        "MATCH (n:C) WHERE n.v >= 0 AND " ++ L ++ " = 'x' RETURN n.v AS v" ++ tail,
    };
    for (queries) |q| {
        // Unforced, each answers.
        const plain = try runOn(ga, s, q, null);
        try testing.expect(plain.code == null and plain.err == null);
        execution.setTestForceLimitInSpawnedUnionArms(true);
        defer execution.setTestForceLimitInSpawnedUnionArms(false);
        const before = execution.parallelUnionInvocations();
        const r = try runOn(ga, s, q, null);
        const parallel = execution.parallelUnionInvocations() > before;
        std.debug.print("SONNY-3316 arm limit: {s} -> {s} rows={d} parallel={}\n", .{ q, r.code orelse "ran", r.rows, parallel });
        try testing.expect(parallel);
        try testing.expectEqualStrings("54001", r.code orelse "ran");
    }
}

test "SONNY-3316 (I4): an out of memory, the read budget or 54001 the evaluator runs into fails the query where a caller swallowed it (EXISTS, COUNT { }, ORDER BY, the node scan)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3316b");
    try seed(ga, s);
    for (swallowing) |q| {
        for ([_]eval.EvalError{ error.OutOfMemory, error.ReadQueryBudgetExceeded, error.ExpressionTooDeep }) |forced| {
            const r = try runOn(ga, s, q, forced);
            std.debug.print("SONNY-3316 forced {s}: {s} -> code={s} err={s} rows={d}\n", .{ @errorName(forced), q, r.code orelse "-", if (r.err) |e| @errorName(e) else "-", r.rows });
            // An error frame or the handler's own error: never rows.
            try testing.expect(r.code != null or r.err != null);
        }
    }
    // The node scan's inline-property seek and match (node_scan_stream).
    for ([_][]const u8{ "MATCH (n:C {v: " ++ L ++ "}) RETURN n.v AS v", "MATCH (n:C {v: 1, w: " ++ L ++ "}) RETURN n.v AS v" }) |q| {
        const r = try runOn(ga, s, q, error.OutOfMemory);
        std.debug.print("SONNY-3316 forced OutOfMemory: {s} -> code={s} err={s} rows={d}\n", .{ q, r.code orelse "-", if (r.err) |e| @errorName(e) else "-", r.rows });
        try testing.expect(r.code != null or r.err != null);
    }
    // The session serves on.
    const ok = try runOn(ga, s, "MATCH (n:C) RETURN n.v + 1 AS v", null);
    try testing.expectEqual(@as(usize, 3), ok.rows);
}

fn buildWideHaving(a: std.mem.Allocator, k: usize, n: usize) ![]u8 {
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "MATCH (n:C) RETURN ");
    for (0..k) |i| {
        try q.appendSlice(a, "n.v");
        for (0..n) |_| try q.appendSlice(a, " + 0");
        try q.print(a, " AS x{d}, ", .{i});
    }
    try q.appendSlice(a, "count(n) AS c GROUP BY ");
    for (0..k) |i| {
        if (i > 0) try q.appendSlice(a, ", ");
        try q.print(a, "x{d}", .{i});
    }
    // The HAVING's chain has the items' shape but differs at its bottom (x0,
    // not n.v): every link was compared with every item down to there.
    try q.appendSlice(a, " HAVING x0");
    for (0..n) |_| try q.appendSlice(a, " + 0");
    try q.appendSlice(a, " >= 0");
    return q.toOwnedSlice(a);
}

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "SONNY-3316 (M2): a HAVING chain against 32 projected chains of 4088 links runs in O(K*N): under 2 s in ReleaseSafe" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3316c");
    try seed(ga, s);
    const n = limit - 8;
    for ([_]usize{ 1, 8, 32 }) |k| {
        const q = try buildWideHaving(ga, k, n);
        const t0 = monoMs();
        const r = try runOn(ga, s, q, null);
        const ms = monoMs() - t0;
        std.debug.print("SONNY-3316 M2: K={d} N={d} ({d} bytes, {s}): {s} rows={d} in {d} ms\n", .{ k, n, q.len, @tagName(builtin.mode), r.code orelse "ran", r.rows, ms });
        try testing.expect(r.err == null);
        try testing.expect(r.code == null);
        try testing.expectEqual(@as(usize, 3), r.rows);
        if (builtin.mode == .ReleaseSafe and k == 32) try testing.expect(ms < 2000);
    }
}
