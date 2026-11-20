// SONNY-3348 round 19: the statement undo record's budget (the round 18
// review's I2) and its minors (m1, m2, m3, m5).
//
// I2: the record held a before-image of everything a statement changed, in
// memory no budget saw: `MATCH (n) DETACH DELETE n` held the whole graph's
// images until the statement ended, and the failure mode past the host's
// memory was the OOM killer. The record now counts against the statement's
// write budget (`GEODE_WRITE_EXECUTOR_BUDGET_MB`): a write whose image does not
// fit is not made, and the statement fails with the budget's 53200 and undoes
// what it recorded. The record uses the testing allocator under test, so the
// leak checker sees it.
//
// m3: an undo entry that cannot be undone was logged and skipped; the
// statement answered its own error (a retry would apply the rest twice), and
// a transaction's rollback stopped at the first such entry and dropped the
// rest undone. The statement now answers 40003; the rollback continues past it
// and ROLLBACK reports 40003.
//
// m1: a failed statement in an explicit transaction aborts the session's
// engine transaction before its replay (the SONNY-2823 order).
//
// m2: a statement failing at a later PULL page aborts its transaction too.
//
// m5: a COMMIT after a failure answers 40000 as a statement and as the COMMIT
// message (which now carries the code).
//
// gRPC in process, with the evaluator's test seam
// (`eval.test_force_limit_error`) and the undo's (`test_fail_undo_entries`).
//
// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=Round19UndoRegression; STATUS=TESTED; TEST=tests/test_sonny3348_round19_undo.zig; OWNER=execution; UPDATED=2026-09-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const eval = geode.eval;
const statement_undo = geode.statement_undo;
const write_budget = geode.write_budget;

const L = "'" ++ eval.test_force_limit_marker ++ "'";
/// Since the v0.8.23 reconciliation a statement that writes may not hold a
/// subquery or a pattern predicate (the write-shape allowlist refuses it,
/// 0A000, before it runs: SONNY-3182, SONNY-3184), so EXISTS { } and
/// COUNT { } can no longer swallow a limit inside a write. The forced
/// failure is raised in the written value itself; the statement must still
/// fail with it and leave nothing of its earlier rows written.
const EX = "(" ++ L ++ " = 'x')";
/// The limit on the last row only (v = 2).
const EX_LAST = "CASE WHEN n.v = 2 THEN " ++ EX ++ " ELSE true END";
const TE = error.ExpressionTooDeep;

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    force: ?eval.EvalError = null,
    page_size: u32 = 64,
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
        while (true) {
            const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = self.page_size });
            const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
            const presp = pull.response orelse return error.MissingPayload;
            switch (presp.payload orelse return error.MissingPayload) {
                .page => |p| {
                    self.rows += p.rows.items.len;
                    if (p.final) return;
                },
                .@"error" => |e| {
                    self.code = e.code;
                    return;
                },
                else => return error.UnexpectedPayload,
            }
        }
    }
};

fn runOn(ga: std.mem.Allocator, session: []const u8, query: []const u8, force: ?eval.EvalError) !Run {
    return runPaged(ga, session, query, force, 64);
}

fn runPaged(ga: std.mem.Allocator, session: []const u8, query: []const u8, force: ?eval.EvalError, page_size: u32) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query, .force = force, .page_size = page_size };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Run.go, .{&r});
    t.join();
    return r;
}

fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query, null);
    if (r.err) |e| return e;
    if (r.code) |c| {
        std.debug.print("SONNY-3348 r19: {s} refused {s}\n", .{ query, c });
        return error.QueryFailed;
    }
    return r.rows;
}

fn expectCode(ga: std.mem.Allocator, s: []const u8, name: []const u8, query: []const u8, force: ?eval.EvalError, code: []const u8) !void {
    const r = try runOn(ga, s, query, force);
    if (r.code == null or !std.mem.eql(u8, r.code.?, code)) {
        std.debug.print("SONNY-3348 r19 {s}: code={s} err={s} rows={d}; want {s}\n   q: {s}\n", .{
            name, r.code orelse "ran", if (r.err) |e| @errorName(e) else "-", r.rows, code, query,
        });
    }
    try testing.expect(r.code != null);
    try testing.expectEqualStrings(code, r.code.?);
}

/// The aborted session refuses a read (25P02); counts 1 when it does.
fn rowsOfAborted(ga: std.mem.Allocator, s: []const u8) !usize {
    const r = try runOn(ga, s, "MATCH (n:C) RETURN n", null);
    return if (r.code != null and std.mem.eql(u8, r.code.?, "25P02")) 1 else 0;
}

fn seedC(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0, x: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1, x: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2, x: 1})");
}

/// `FOR i IN [0, 1, ..., n-1] <body>`.
fn forRange(ga: std.mem.Allocator, n: usize, body: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(ga, "FOR i IN [");
    for (0..n) |i| {
        if (i > 0) try list.appendSlice(ga, ", ");
        try list.print(ga, "{d}", .{i});
    }
    try list.appendSlice(ga, "] ");
    try list.appendSlice(ga, body);
    return list.items;
}

test "SONNY-3348 r19 I2: a DETACH DELETE whose undo images do not fit the write budget answers 53200 and leaves the graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r19b");

    // The record's memory is the leak checker's under test.
    try testing.expect(statement_undo.allocator.vtable == testing.allocator.vtable);

    const pad = "p" ** 400;
    try fx.expectRuns(ga, s, try forRange(ga, 1200, "CREATE (:BG {i: i, s: '" ++ pad ++ "'})"));
    try fx.expectRuns(ga, s, try forRange(ga, 200, "MATCH (a:BG {i: i}), (b:BG {i: i + 1}) CREATE (a)-[:NEXT {w: i}]->(b)"));
    try testing.expectEqual(@as(usize, 1200), try rowsOf(ga, s, "MATCH (n:BG) RETURN n"));
    try testing.expectEqual(@as(usize, 200), try rowsOf(ga, s, "MATCH ()-[r:NEXT]->() RETURN r.w AS w"));

    // The images of 1200 nodes of 400 bytes and their edges are about
    // 700 KB; the budget is 256 KB.
    write_budget.setBudgetBytesForTest(256 * 1024);
    defer write_budget.setBudgetBytesForTest(0);

    const refusals0 = statement_undo.budget_refusals_total.load(.monotonic);
    try expectCode(ga, s, "I2 DETACH DELETE of the graph", "MATCH (n:BG) DETACH DELETE n", null, "53200");
    try testing.expect(statement_undo.budget_refusals_total.load(.monotonic) > refusals0);
    try testing.expectEqual(@as(usize, 1200), try rowsOf(ga, s, "MATCH (n:BG) RETURN n"));
    try testing.expectEqual(@as(usize, 200), try rowsOf(ga, s, "MATCH ()-[r:NEXT]->() RETURN r.w AS w"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:BG {i: 3})-[r:NEXT {w: 3}]->(b:BG {i: 4}) WHERE a.s = '" ++ pad ++ "' RETURN r.w AS w"));

    // A statement of normal size, under the same budget, is unaffected (a
    // point write, a one-node DETACH DELETE: their records are small).
    const refusals1 = statement_undo.budget_refusals_total.load(.monotonic);
    try fx.expectRuns(ga, s, "MATCH (n:BG {i: 5}) SET n.x = 1");
    try fx.expectRuns(ga, s, "MATCH (n:BG {i: 7}) DETACH DELETE n");
    try fx.expectRuns(ga, s, "FOR i IN [0, 1, 2] CREATE (:BG2 {i: i, s: '" ++ pad ++ "'})");
    try testing.expectEqual(refusals1, statement_undo.budget_refusals_total.load(.monotonic));
    write_budget.setBudgetBytesForTest(0);
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:BG) WHERE n.x = 1 RETURN n"));
    try testing.expectEqual(@as(usize, 1199), try rowsOf(ga, s, "MATCH (n:BG) RETURN n"));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:BG2) RETURN n"));

    // Without the budget, the delete runs.
    write_budget.setBudgetBytesForTest(0);
    try fx.expectRuns(ga, s, "MATCH (n:BG) DETACH DELETE n");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:BG) RETURN n"));
}

test "SONNY-3348 r19 m3: an undo entry that cannot be undone answers 40003; ROLLBACK continues past it and reports it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r19m3");
    try seedC(ga, s);

    defer statement_undo.test_fail_undo_entries.store(0, .release);
    // Autocommit: every row is written, then the RETURN fails on row 2; one
    // of the undo entries fails. 40003, not 54001; the others are undone.
    // (A SET whose value fails on the last row no longer writes the rows
    // before it: the write step evaluates a SET's values before it assigns,
    // SONNY-3242, so the failure comes from the RETURN here.)
    const failures0 = statement_undo.replay_failures_total.load(.monotonic);
    statement_undo.test_fail_undo_entries.store(1, .release);
    try expectCode(ga, s, "m3 autocommit replay", "MATCH (n:C) SET n.w = 1 RETURN " ++ EX_LAST ++ " AS e", TE, "40003");
    statement_undo.test_fail_undo_entries.store(0, .release);
    try testing.expectEqual(failures0 + 1, statement_undo.replay_failures_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n"));

    // ROLLBACK of a transaction: three SETs, one undo fails. The other two
    // are undone (it stopped at the first failure), and ROLLBACK reports it.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.t = 1");
    statement_undo.test_fail_undo_entries.store(1, .release);
    const req = try fx.encodeProto(ga, schema.RollbackRequest{ .session_id = s });
    const resp = try fx.decodeProto(schema.RollbackResponse, ga, try grpc.handleRollback(req, ga));
    statement_undo.test_fail_undo_entries.store(0, .release);
    try testing.expect(!resp.success);
    try testing.expect(resp.@"error" != null);
    try testing.expectEqualStrings("40003", resp.@"error".?.code);
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:C) WHERE n.t IS NOT NULL RETURN n"));
    // The transaction is over; the session serves on.
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.t = NULL");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.t IS NOT NULL RETURN n"));

    // The same through a failed statement's rollback (a read that fails,
    // so the one failing entry is the transaction's), reported by the
    // ROLLBACK statement that ends the aborted transaction.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.u = 1");
    statement_undo.test_fail_undo_entries.store(1, .release);
    try expectCode(ga, s, "m3 failed statement in a transaction", "MATCH (n:C) WHERE n.v = 2 RETURN " ++ EX ++ " AS e", TE, "54001");
    statement_undo.test_fail_undo_entries.store(0, .release);
    try testing.expectEqual(@as(usize, 1), try rowsOfAborted(ga, s));
    try expectCode(ga, s, "m3 ROLLBACK after an incomplete rollback", "ROLLBACK", null, "40003");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:C) WHERE n.u IS NOT NULL RETURN n"));
}

test "SONNY-3348 r19 m1, m5: a failed statement in a transaction is replayed inside the engine transaction (SONNY-6529); COMMIT after it answers 40000 in every form" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r19m1");
    try seedC(ga, s);

    // m1: the CREATE writes in the session's engine transaction (R9), and
    // its RETURN fails. SONNY-6529: the replay's DELETE joins that engine
    // transaction (it was aborted before the replay, which graph-storage
    // 0.4.16 turned into a second undo of the CREATE).
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.a = 1");
    const joined0 = geode.execution.session_txn_replay_joined_total.load(.monotonic);
    try expectCode(ga, s, "m1 CREATE then a failing RETURN", "CREATE (d:D1 {k: 1}) RETURN " ++ EX ++ " AS e", TE, "54001");
    try testing.expectEqual(joined0 + 1, geode.execution.session_txn_replay_joined_total.load(.monotonic));
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (d:D1) RETURN d"));
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.a = 1");
    try expectCode(ga, s, "m1 failing SET", "MATCH (n:C) SET n.b = " ++ EX_LAST, TE, "54001");
    try testing.expectEqual(@as(usize, 0), fx.engineActive("default"));

    // m5: the COMMIT message answers 40000, as the COMMIT statement does.
    const req = try fx.encodeProto(ga, schema.CommitRequest{ .session_id = s });
    const resp = try fx.decodeProto(schema.CommitResponse, ga, try grpc.handleCommit(req, ga));
    try testing.expect(!resp.success);
    try testing.expect(resp.@"error" != null);
    try testing.expectEqualStrings("40000", resp.@"error".?.code);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.a IS NOT NULL OR n.b IS NOT NULL RETURN n"));

    try fx.begin(ga, s);
    try expectCode(ga, s, "m5 failing statement", "MATCH (n:C) SET n.b = " ++ EX_LAST, TE, "54001");
    try expectCode(ga, s, "m5 COMMIT statement", "COMMIT", null, "40000");
    try fx.expectRuns(ga, s, "MATCH (n:C) RETURN n");
}

test "SONNY-3348 r19 m2: a statement failing at a later PULL page aborts its transaction" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r19m2");
    try seedC(ga, s);

    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.p = 1");
    // The engine-direct node scan streams the rows; row 2's WHERE (the
    // marker, reached past `n.v < 2`) hits the limit while the stream builds
    // the rows its schema frame is typed from.
    const r = try runPaged(ga, s, "MATCH (n:C) WHERE n.v < 2 OR " ++ L ++ " = 'x' RETURN n.v AS v", TE, 1);
    if (r.code == null) std.debug.print("SONNY-3348 r19 m2: the streamed read ran ({d} rows)\n", .{r.rows});
    try testing.expect(r.code != null);
    // The transaction is aborted: the next statement is refused, and its
    // SET was rolled back.
    _ = try fx.expectRefused(ga, s, "MATCH (n:C) RETURN n", "25P02");
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.p IS NOT NULL RETURN n"));

    // A later page: 1500 rows, the limit on row 1400, pages of 16. The first
    // pages are answered, and the failing PULL aborts the transaction.
    try fx.expectRuns(ga, s, try forRange(ga, 1500, "CREATE (:PG {v: i})"));
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.p = 2");
    const late = try runPaged(ga, s, "MATCH (n:PG) WHERE n.v < 1400 OR " ++ L ++ " = 'x' RETURN n.v AS v", TE, 16);
    if (late.code == null or late.rows == 0) std.debug.print("SONNY-3348 r19 m2: the later-page read: code={s} rows={d}\n", .{ late.code orelse "ran", late.rows });
    try testing.expect(late.code != null);
    try testing.expect(late.rows > 0);
    _ = try fx.expectRefused(ga, s, "MATCH (n:C) RETURN n", "25P02");
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.p IS NOT NULL RETURN n"));
}
