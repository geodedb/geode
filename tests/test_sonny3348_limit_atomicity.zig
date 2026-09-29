// SONNY-3348 regression (round 17, the v0.8.23 blocker).
//
// The limit relay (SONNY-3251, SONNY-3316) fails a statement in which a
// caller swallowed a limit (54001, out of memory, the read budget) or an IN
// type error. It failed it only after the statement had run, so the
// statement's writes stayed: `MATCH (n:C) SET n.w = EXISTS { MATCH (m:C)
// WHERE <limit> } RETURN n.v AS v` answered 54001 and `n.w` was set on all
// three rows (round 16 review, probe P3).
//
// The store now refuses every change while the statement is to fail
// (`graph_store.statementWriteFence`), so nothing a swallowed limit decided is
// written, on the legacy MATCH, CREATE, MERGE and DELETE executors alike.
//
// Through the real gRPC handler in process, with the evaluator's test seam
// (`eval.test_force_limit_error`) failing the marker literal.
//
// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3348_limit_atomicity.zig; OWNER=execution; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const eval = geode.eval;

/// Where the evaluator's test seam fails (`eval.test_force_limit_marker`).
const L = "'" ++ eval.test_force_limit_marker ++ "'";
/// A subquery whose WHERE swallows the forced failure (EXISTS turns it into
/// false, COUNT { } into 0).
const exists_limit = "EXISTS { MATCH (m:C) WHERE " ++ L ++ " = 'x' }";
const count_limit = "COUNT { MATCH (m:C) WHERE " ++ L ++ " = 'x' }";

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
    std.debug.print("SONNY-3348: force={s} -> code={s} err={s} rows={d} :: {s}\n", .{
        if (force) |e| @errorName(e) else "none",
        r.code orelse "ran",
        if (r.err) |e| @errorName(e) else "-",
        r.rows,
        query,
    });
    return r;
}

/// The rows `query` answers, which must run.
fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query, null);
    if (r.err) |e| return e;
    if (r.code) |c| {
        std.debug.print("SONNY-3348: {s} refused {s}\n", .{ query, c });
        return error.QueryFailed;
    }
    return r.rows;
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
}

/// `query` is refused with `code` when the marker fails with `force`.
fn expectFails(ga: std.mem.Allocator, s: []const u8, query: []const u8, force: eval.EvalError, code: []const u8) !void {
    const r = try runOn(ga, s, query, force);
    try testing.expect(r.err == null);
    try testing.expectEqualStrings(code, r.code orelse "ran");
}

test "SONNY-3348: a SET whose value a swallowed 54001 decided answers 54001 and writes nothing (round 16 probe P3)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3348a");
    try seed(ga, s);

    try expectFails(ga, s, "MATCH (n:C) SET n.w = " ++ exists_limit ++ " RETURN n.v AS v", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n.w AS w"));

    // Without RETURN, and with COUNT { } (a 0, not a false).
    try expectFails(ga, s, "MATCH (n:C) SET n.w = " ++ count_limit, error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n.w AS w"));

    // A label and a property in one SET: neither lands.
    try expectFails(ga, s, "MATCH (n:C) SET n:Tagged, n.t = " ++ exists_limit, error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:Tagged) RETURN n.v AS v"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.t IS NOT NULL RETURN n.t AS t"));

    // A REMOVE whose rows a swallowed limit chose (COUNT { } read 0).
    try expectFails(ga, s, "MATCH (n:C) WHERE " ++ count_limit ++ " = 0 REMOVE n.v", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.v IS NOT NULL RETURN n.v AS v"));

    // The same statement without the forced limit writes every row.
    try testing.expectEqual(@as(usize, 3), (try runOn(ga, s, "MATCH (n:C) SET n.w = " ++ exists_limit ++ " RETURN n.v AS v", null)).rows);
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w = false RETURN n.w AS w"));
}

test "SONNY-3348: a forced out of memory or read budget in the value fails the statement and writes nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3348b");
    try seed(ga, s);

    for ([_]eval.EvalError{ error.OutOfMemory, error.ReadQueryBudgetExceeded }) |forced| {
        const r = try runOn(ga, s, "MATCH (n:C) SET n.w = " ++ exists_limit ++ " RETURN n.v AS v", forced);
        // An error frame or the handler's own error: never an answer.
        try testing.expect(r.code != null or r.err != null);
        try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n.w AS w"));
    }
}

test "SONNY-3348: CREATE, MATCH ... CREATE, MERGE and DETACH DELETE decided by a swallowed limit change nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3348c");
    try seed(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:X {k: 1})");
    try fx.expectRuns(ga, s, "CREATE (:X {k: 2})");

    try expectFails(ga, s, "CREATE (:D {w: " ++ exists_limit ++ "})", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (d:D) RETURN d.w AS w"));

    try expectFails(ga, s, "MATCH (n:C) CREATE (:E {v: n.v, w: " ++ count_limit ++ "})", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (e:E) RETURN e.v AS v"));

    try expectFails(ga, s, "MATCH (n:C) WITH n, " ++ count_limit ++ " AS c CREATE (:E {v: n.v, c: c})", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (e:E) RETURN e.v AS v"));

    try expectFails(ga, s, "MERGE (m:M {k: 1}) ON CREATE SET m.w = " ++ exists_limit, error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (m:M) RETURN m.k AS k"));

    try expectFails(ga, s, "MATCH (x:X) WHERE " ++ count_limit ++ " = 0 DETACH DELETE x", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 2), try rowsOf(ga, s, "MATCH (x:X) RETURN x.k AS k"));
    try expectFails(ga, s, "MATCH (x:X) WHERE " ++ count_limit ++ " = 0 DELETE x", error.ExpressionTooDeep, "54001");
    try testing.expectEqual(@as(usize, 2), try rowsOf(ga, s, "MATCH (x:X) RETURN x.k AS k"));

    // An IN type error a subquery's WHERE swallowed (22000) is the same.
    try expectFails(ga, s, "MATCH (n:C) SET n.i = EXISTS { MATCH (m:C) WHERE m.v IN 5 }", error.ExpressionTooDeep, "22000");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.i IS NOT NULL RETURN n.i AS i"));
}

test "SONNY-3348: inside an explicit transaction the statement fails the transaction and nothing of it is written" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3348d");
    try seed(ga, s);

    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:T {k: 1})");
    try expectFails(ga, s, "MATCH (n:C) SET n.w = " ++ exists_limit ++ " RETURN n.v AS v", error.ExpressionTooDeep, "54001");
    // The transaction is failed: its COMMIT does not commit.
    try testing.expect(!(try fx.commit(ga, s)));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n.w AS w"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (t:T) RETURN t.k AS k"));

    // The session serves on, in and out of a transaction.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:T {k: 2})");
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (t:T) RETURN t.k AS k"));
}

test "SONNY-3348: a retry after the failure applies the statement once" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3348e");
    try seed(ga, s);

    const q = "MATCH (n:C) SET n.cnt = coalesce(n.cnt, 0) + 1, n.e = " ++ exists_limit ++ " RETURN n.v AS v";
    try expectFails(ga, s, q, error.ExpressionTooDeep, "54001");
    const oom = try runOn(ga, s, q, error.OutOfMemory);
    try testing.expect(oom.code != null or oom.err != null);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.cnt IS NOT NULL RETURN n.cnt AS c"));
    // The retry, which runs.
    try testing.expectEqual(@as(usize, 3), (try runOn(ga, s, q, null)).rows);
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.cnt = 1 RETURN n.cnt AS c"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.cnt > 1 RETURN n.cnt AS c"));
}
