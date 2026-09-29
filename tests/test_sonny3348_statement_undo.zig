// SONNY-3348 round 18: statement atomicity (the round 17 review's C1, I1, I2)
// and SONNY-3059 (ROLLBACK undoes every change, not only CREATEs).
//
// Round 17's write fence stopped the writes made after a swallowed limit was
// recorded, and left the ones made before it: the rows before the limit's
// row, a SET before a RETURN or an ORDER BY that hit it, a REMOVE before a
// WITH the legacy executor evaluates late, the point-write fast path (whose
// only expression is its RETURN), MERGE, FOR, PROFILE. Inside an explicit
// transaction the session then left the transaction and autocommitted, and
// the fence turned a `START TRANSACTION { ... }` body's rollback into a
// no-op.
//
// A failed statement now leaves nothing: the store records what each write
// changes (`statement_undo`), and a statement that fails replays the record
// before it answers. A failed statement aborts its explicit transaction,
// which refuses everything but ROLLBACK (25P02) until the client ends it.
// Every statement's record joins its transaction's undo log, so ROLLBACK
// undoes SET, REMOVE, labels, DELETE and MATCH ... CREATE too.
//
// The round 17 reviewer's probe matrix, through the real gRPC handler in
// process, with the evaluator's test seam (`eval.test_force_limit_error`)
// failing the marker literal on one row only (CASE gates it).
//
// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=StatementUndoRegression; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=execution; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const eval = geode.eval;
const execution = geode.execution;

const L = "'" ++ eval.test_force_limit_marker ++ "'";
/// Swallowed into false (EXISTS) or 0 (COUNT { }).
const EX = "EXISTS { MATCH (m:C) WHERE " ++ L ++ " = 'x' }";
const CNT = "COUNT { MATCH (m:C) WHERE " ++ L ++ " = 'x' }";
/// The limit on the last row only (v = 2; the scan order is v = 0, 1, 2).
const EX_LAST = "CASE WHEN n.v = 2 THEN " ++ EX ++ " ELSE true END";
const CNT_LAST = "CASE WHEN n.v = 2 THEN " ++ CNT ++ " ELSE 0 END";

const TE = error.ExpressionTooDeep;
const OOM = error.OutOfMemory;

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

/// The rows `query` answers; it must run.
fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query, null);
    if (r.err) |e| return e;
    if (r.code) |c| {
        std.debug.print("SONNY-3348 r18: {s} refused {s}\n", .{ query, c });
        return error.QueryFailed;
    }
    return r.rows;
}

/// `query`, failing with `force` (null: an error of its own), is refused
/// with `code` (null: any error), and afterwards `check` answers `clean` rows.
fn expectAtomic(ga: std.mem.Allocator, s: []const u8, name: []const u8, query: []const u8, force: ?eval.EvalError, code: ?[]const u8, check: []const u8, clean: usize) !void {
    const r = try runOn(ga, s, query, force);
    const left = try rowsOf(ga, s, check);
    const failed = r.code != null or r.err != null;
    const code_ok = if (code) |c| (r.code != null and std.mem.eql(u8, c, r.code.?)) else failed;
    if (!failed or !code_ok or left != clean) {
        std.debug.print("SONNY-3348 r18 {s}: code={s} err={s} rows={d} | check={d} clean={d}\n   q: {s}\n", .{
            name, r.code orelse "ran", if (r.err) |e| @errorName(e) else "-", r.rows, left, clean, query,
        });
    }
    try testing.expect(failed);
    try testing.expect(code_ok);
    try testing.expectEqual(clean, left);
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0, x: 1, y: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1, x: 1, y: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2, x: 1, y: 1})");
    try fx.expectRuns(ga, s, "CREATE (:X {k: 1})-[:R {p: 7}]->(:Y {k: 1})");
    try fx.expectRuns(ga, s, "CREATE (:X {k: 2})");
    try fx.expectRuns(ga, s, "CREATE (:X {k: 3})");
    try fx.expectRuns(ga, s, "CREATE (:P {name: 'a'})");
}

test "SONNY-3348 r18: autocommit, the legacy MATCH executor: a limit on the last row leaves no earlier row written" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18a");
    try seed(ga, s);

    const replays0 = geode.statement_undo.replayed_statements_total.load(.monotonic); // statement_undo
    try expectAtomic(ga, s, "A1 SET multi-row 54001", "MATCH (n:C) SET n.w = " ++ EX_LAST, TE, "54001", "MATCH (n:C) WHERE n.w IS NOT NULL RETURN n", 0);
    // Rows 0 and 1 were written, and the record undid them.
    try testing.expect(geode.statement_undo.replayed_statements_total.load(.monotonic) > replays0); // statement_undo
    try expectAtomic(ga, s, "A1c SET multi-row OOM", "MATCH (n:C) SET n.wo = " ++ EX_LAST, OOM, null, "MATCH (n:C) WHERE n.wo IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A1d SET multi-row IN type error", "MATCH (n:C) SET n.wi = CASE WHEN n.v = 2 THEN EXISTS { MATCH (m:C) WHERE m.v IN 5 } ELSE true END", null, "22000", "MATCH (n:C) WHERE n.wi IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A1e SET multi-row 1/0 (any error)", "MATCH (n:C) SET n.wz = CASE WHEN n.v = 2 THEN 1 / 0 ELSE 1 END", null, null, "MATCH (n:C) WHERE n.wz IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A11 SET label multi-row", "MATCH (n:C) SET n:Lb, n.lw = " ++ EX_LAST, TE, "54001", "MATCH (n:Lb) RETURN n", 0);
    try expectAtomic(ga, s, "A3 WITH <limit> then REMOVE", "MATCH (n:C) WITH n, " ++ EX ++ " AS e REMOVE n.x", TE, "54001", "MATCH (n:C) WHERE n.x = 1 RETURN n", 3);
    try expectAtomic(ga, s, "A3b WITH <limit> then SET", "MATCH (n:C) WITH n, " ++ EX ++ " AS e SET n.ws = 1", TE, "54001", "MATCH (n:C) WHERE n.ws IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A4 SET then RETURN <limit>", "MATCH (n:C) SET n.r = 1 RETURN " ++ EX ++ " AS e", TE, "54001", "MATCH (n:C) WHERE n.r IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A4b SET then RETURN <limit> OOM", "MATCH (n:C) SET n.ro = 1 RETURN " ++ EX ++ " AS e", OOM, null, "MATCH (n:C) WHERE n.ro IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "A4c SET then ORDER BY <limit>", "MATCH (n:C) SET n.ob = 1 RETURN n.v AS v ORDER BY " ++ CNT, TE, "54001", "MATCH (n:C) WHERE n.ob IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "B7 REMOVE then RETURN <limit> on the last row", "MATCH (n:C) REMOVE n.y RETURN " ++ EX_LAST ++ " AS e", TE, "54001", "MATCH (n:C) WHERE n.y = 1 RETURN n", 3);
    // A retry after the failure applies once.
    const q = "MATCH (n:C) SET n.cnt = coalesce(n.cnt, 0) + 1, n.e = " ++ EX_LAST;
    try expectAtomic(ga, s, "retry: the failing run", q, TE, "54001", "MATCH (n:C) WHERE n.cnt IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "retry: the failing run (OOM)", q, OOM, null, "MATCH (n:C) WHERE n.cnt IS NOT NULL RETURN n", 0);
    const retry = try runOn(ga, s, q, null);
    try testing.expect(retry.code == null and retry.err == null);
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.cnt = 1 RETURN n"));
    // The data the failed statements touched is as it was.
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.x = 1 AND n.y = 1 RETURN n"));
}

test "SONNY-3348 r18: autocommit, CREATE, MATCH ... CREATE, FOR, MERGE, DELETE and the point-write fast path" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18b");
    try seed(ga, s);

    try expectAtomic(ga, s, "A5 CREATE then RETURN <limit>", "CREATE (d:D {k: 1}) RETURN " ++ EX ++ " AS e", TE, "54001", "MATCH (d:D) RETURN d", 0);
    try expectAtomic(ga, s, "A7 MATCH CREATE multi-row", "MATCH (n:C) CREATE (:E {v: n.v, w: " ++ CNT_LAST ++ "})", TE, "54001", "MATCH (e:E) RETURN e", 0);
    try expectAtomic(ga, s, "A7b MATCH CREATE edge multi-row", "MATCH (n:C) CREATE (n)-[:RE {w: " ++ CNT_LAST ++ "}]->(:E2)", TE, "54001", "MATCH (e:E2) RETURN e", 0);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (:C)-[r:RE]->() RETURN r"));
    try expectAtomic(ga, s, "B9 FOR CREATE", "FOR i IN [1, 2, 3] CREATE (:U2 {i: i, w: CASE WHEN i = 3 THEN " ++ CNT ++ " ELSE 0 END})", TE, "54001", "MATCH (u:U2) RETURN u", 0);
    try expectAtomic(ga, s, "B6 MERGE ON CREATE SET multi-row", "MATCH (n:C) MERGE (m:M3 {k: n.v}) ON CREATE SET m.w = " ++ EX_LAST, TE, "54001", "MATCH (m:M3) RETURN m", 0);
    try expectAtomic(ga, s, "B6b MERGE key multi-row", "MATCH (n:C) MERGE (m:M4 {k: n.v, w: " ++ CNT_LAST ++ "})", TE, "54001", "MATCH (m:M4) RETURN m", 0);
    try expectAtomic(ga, s, "A9b MERGE ON MATCH SET multi-row", "MATCH (c:C) MERGE (n:C {v: c.v}) ON MATCH SET n.mm = CASE WHEN c.v = 2 THEN " ++ EX ++ " ELSE true END", TE, "54001", "MATCH (n:C) WHERE n.mm IS NOT NULL RETURN n", 0);

    // A DELETE refused for a node with an edge (the last Q): no Q is gone.
    try fx.expectRuns(ga, s, "CREATE (:Q {k: 1})");
    try fx.expectRuns(ga, s, "CREATE (:Q {k: 2})");
    try fx.expectRuns(ga, s, "CREATE (:Q {k: 3})-[:QR {p: 1}]->(:Y2)");
    try expectAtomic(ga, s, "D1 DELETE of a node with an edge, after two without", "MATCH (q:Q) DELETE q", null, null, "MATCH (q:Q) RETURN q", 3);
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (:Q {k: 3})-[r:QR]->(:Y2) WHERE r.p = 1 RETURN r"));
    try expectAtomic(ga, s, "A14 DELETE then RETURN <limit>", "MATCH (x:X) WHERE x.k = 2 DETACH DELETE x RETURN " ++ CNT ++ " AS c", TE, "54001", "MATCH (x:X) RETURN x", 3);

    // The point-write fast path: its only expression is the RETURN.
    const pw0 = execution.getPointWriteFastPathTotal();
    try expectAtomic(ga, s, "A13 point write then RETURN <limit>", "MATCH (p:P) WHERE p.name = 'a' SET p.pw = 1 RETURN " ++ EX ++ " AS e", TE, "54001", "MATCH (p:P) WHERE p.pw IS NOT NULL RETURN p", 0);
    try expectAtomic(ga, s, "A13b point write then RETURN <limit> OOM", "MATCH (p:P) WHERE p.name = 'a' SET p.pw2 = 1 RETURN p.name AS n, " ++ CNT ++ " AS c", OOM, null, "MATCH (p:P) WHERE p.pw2 IS NOT NULL RETURN p", 0);
    try expectAtomic(ga, s, "A13c point write REMOVE then RETURN <limit>", "MATCH (p:P) WHERE p.name = 'a' REMOVE p.name RETURN " ++ CNT ++ " AS c", TE, "54001", "MATCH (p:P) WHERE p.name = 'a' RETURN p", 1);
    // The probes above took the fast path (they are the shape it serves).
    try testing.expect(execution.getPointWriteFastPathTotal() > pw0);
}

test "SONNY-3348 r18: PROFILE'd statements that fail change nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18p");
    try seed(ga, s);

    try expectAtomic(ga, s, "P1 PROFILE SET multi-row", "PROFILE MATCH (n:C) SET n.pw = " ++ EX_LAST ++ " RETURN n.v AS v", TE, "54001", "MATCH (n:C) WHERE n.pw IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "P2 PROFILE SET then RETURN <limit>", "PROFILE MATCH (n:C) SET n.pr = 1 RETURN " ++ EX ++ " AS e", TE, "54001", "MATCH (n:C) WHERE n.pr IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "P2b PROFILE SET then RETURN <limit> OOM", "PROFILE MATCH (n:C) SET n.po = 1 RETURN " ++ EX ++ " AS e", OOM, null, "MATCH (n:C) WHERE n.po IS NOT NULL RETURN n", 0);
    try expectAtomic(ga, s, "P3 PROFILE CREATE then RETURN <limit>", "PROFILE CREATE (d:PD {k: 1}) RETURN " ++ EX ++ " AS e", TE, "54001", "MATCH (d:PD) RETURN d", 0);
}

test "SONNY-3348 r18 (I1): a START TRANSACTION body's rollback is not fenced off" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18w");
    try seed(ga, s);

    try expectAtomic(ga, s, "W0b body, 1/0 in the 2nd statement", "START TRANSACTION { CREATE (:TZ {k: 1}); CREATE (:TZ2 {w: 1 / 0}) }", null, null, "MATCH (t:TZ) RETURN t", 0);
    try expectAtomic(ga, s, "W1 body, a propagated 54001 in the 2nd CREATE", "START TRANSACTION { CREATE (:TE {k: 1}); CREATE (:TE2 {w: " ++ L ++ "}) }", TE, "54001", "MATCH (t:TE) RETURN t", 0);
    try expectAtomic(ga, s, "W1b body, a propagated OOM in the 2nd CREATE", "START TRANSACTION { CREATE (:TO {k: 1}); CREATE (:TO2 {w: " ++ L ++ "}) }", OOM, null, "MATCH (t:TO) RETURN t", 0);
    try expectAtomic(ga, s, "W2 body, a swallowed 54001 in the 2nd statement", "START TRANSACTION { CREATE (:TD {k: 1}); MATCH (n:C) SET n.td = " ++ EX_LAST ++ " }", TE, "54001", "MATCH (t:TD) RETURN t", 0);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.td IS NOT NULL RETURN n"));
    // A statement outside the body's allowed kinds (DELETE) rolls the body
    // back, and leaves no transaction open on the session.
    try expectAtomic(ga, s, "W3 body, a DELETE (refused in a body)", "START TRANSACTION { CREATE (:TW {k: 1}); MATCH (x:X) DETACH DELETE x }", null, null, "MATCH (t:TW) RETURN t", 0);
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (x:X) RETURN x"));
    // Unforced, the body commits.
    const ok = try runOn(ga, s, "START TRANSACTION { CREATE (:TC {k: 1}); MATCH (n:C) SET n.tc = 1 }", null);
    try testing.expect(ok.code == null and ok.err == null);
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (t:TC) RETURN t"));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.tc = 1 RETURN n"));
}

/// In an explicit transaction: `query` fails, the next statement is refused
/// (25P02, the session does not fall back to autocommit), `end` (COMMIT or
/// ROLLBACK) ends the transaction, and `check` answers `clean` rows.
fn expectTxnAborts(ga: std.mem.Allocator, s: []const u8, name: []const u8, pre: []const []const u8, query: []const u8, force: eval.EvalError, end_with_commit: bool, check: []const u8, clean: usize) !void {
    try fx.begin(ga, s);
    for (pre) |p| try fx.expectRuns(ga, s, p);
    const r = try runOn(ga, s, query, force);
    if (r.code == null and r.err == null) {
        std.debug.print("SONNY-3348 r18 {s}: the statement ran\n", .{name});
        return error.TestUnexpectedResult;
    }
    // Aborted: refused until the transaction ends; never autocommitted.
    _ = try fx.expectRefused(ga, s, "CREATE (:After {k: 1})", "25P02");
    _ = try fx.expectRefused(ga, s, "MATCH (n:C) RETURN n", "25P02");
    // BEGIN is refused too.
    try testing.expectError(error.BeginRefused, fx.begin(ga, s));
    if (end_with_commit) {
        try testing.expect(!(try fx.commit(ga, s)));
    } else {
        try testing.expect(try fx.rollback(ga, s));
    }
    const left = try rowsOf(ga, s, check);
    if (left != clean) std.debug.print("SONNY-3348 r18 {s}: check={d} clean={d}\n", .{ name, left, clean });
    try testing.expectEqual(clean, left);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:After) RETURN a"));
}

test "SONNY-3348 r18 (I2): a failed statement aborts its explicit transaction; only ROLLBACK or COMMIT ends it, and nothing of it stays" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18t");
    try seed(ga, s);

    try expectTxnAborts(ga, s, "T1 SET multi-row, COMMIT", &.{}, "MATCH (n:C) SET n.t1 = " ++ EX_LAST, TE, true, "MATCH (n:C) WHERE n.t1 IS NOT NULL RETURN n", 0);
    try expectTxnAborts(ga, s, "T1b SET multi-row OOM, ROLLBACK", &.{}, "MATCH (n:C) SET n.t1o = " ++ EX_LAST, OOM, false, "MATCH (n:C) WHERE n.t1o IS NOT NULL RETURN n", 0);
    // SONNY-3059: an earlier good SET of the transaction is undone too.
    try expectTxnAborts(ga, s, "T2 a good SET, then a failing statement, ROLLBACK", &.{"MATCH (n:C) SET n.t2 = 1"}, "MATCH (n:C) SET n.t2b = " ++ EX, TE, false, "MATCH (n:C) WHERE n.t2 IS NOT NULL RETURN n", 0);
    try expectTxnAborts(ga, s, "T3 CREATE, then MATCH CREATE multi-row, ROLLBACK", &.{"CREATE (:T3a {k: 1})"}, "MATCH (n:C) CREATE (:T3 {v: n.v, w: " ++ CNT_LAST ++ "})", TE, false, "MATCH (t:T3) RETURN t", 0);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (t:T3a) RETURN t"));
    try expectTxnAborts(ga, s, "T4 DETACH DELETE, then a failing statement, COMMIT", &.{"MATCH (x:X) WHERE x.k = 1 DETACH DELETE x"}, "MATCH (n:C) SET n.t4 = " ++ EX, TE, true, "MATCH (x:X) RETURN x", 3);
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (x:X {k: 1})-[r:R]->(:Y) WHERE r.p = 7 RETURN r"));
    try expectTxnAborts(ga, s, "T6 WITH <limit> REMOVE, ROLLBACK", &.{}, "MATCH (n:C) WITH n, " ++ EX ++ " AS e REMOVE n.x", TE, false, "MATCH (n:C) WHERE n.x = 1 RETURN n", 3);
    try expectTxnAborts(ga, s, "T7 SET then RETURN <limit>, COMMIT", &.{}, "MATCH (n:C) SET n.t7 = 1 RETURN " ++ EX ++ " AS e", TE, true, "MATCH (n:C) WHERE n.t7 IS NOT NULL RETURN n", 0);

    // A COMMIT or ROLLBACK statement ends it as the RPCs do.
    try fx.begin(ga, s);
    _ = try runOn(ga, s, "MATCH (n:C) SET n.t8 = " ++ EX, TE);
    _ = try fx.expectRefused(ga, s, "CREATE (:After {k: 2})", "25P02");
    _ = try fx.expectRefused(ga, s, "COMMIT", "40000");
    try fx.expectRuns(ga, s, "CREATE (:Free {k: 1})");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:Free) RETURN a"));
    try fx.begin(ga, s);
    _ = try runOn(ga, s, "MATCH (n:C) SET n.t9 = " ++ EX, TE);
    try fx.expectRuns(ga, s, "ROLLBACK");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.t8 IS NOT NULL OR n.t9 IS NOT NULL RETURN n"));

    // The session serves on, in and out of a transaction.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:T {k: 2})");
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (t:T) RETURN t"));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.x = 1 AND n.y = 1 RETURN n"));
}

test "SONNY-3059: ROLLBACK undoes SET, REMOVE, labels, DETACH DELETE, MATCH ... CREATE and MERGE ON MATCH" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("r18u");
    try seed(ga, s);

    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.s = 1, n.x = 2");
    try fx.expectRuns(ga, s, "MATCH (n:C) REMOVE n.y");
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n:Lab");
    try fx.expectRuns(ga, s, "MATCH (x:X) WHERE x.k = 1 DETACH DELETE x");
    try fx.expectRuns(ga, s, "MATCH (n:C) CREATE (:W {v: n.v})");
    try fx.expectRuns(ga, s, "MERGE (p:P {name: 'a'}) ON MATCH SET p.m = 1");
    try fx.expectRuns(ga, s, "MATCH (y:Y) SET y:Tmp REMOVE y:Y");
    try testing.expect(try fx.rollback(ga, s));

    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.s IS NOT NULL RETURN n"));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.x = 1 AND n.y = 1 RETURN n"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:Lab) RETURN n"));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (x:X) RETURN x"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (x:X {k: 1})-[r:R]->(y:Y {k: 1}) WHERE r.p = 7 RETURN r"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (w:W) RETURN w"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (p:P) WHERE p.m IS NOT NULL RETURN p"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (t:Tmp) RETURN t"));

    // And COMMIT keeps them.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "MATCH (n:C) SET n.s = 1");
    try fx.expectRuns(ga, s, "MATCH (x:X) WHERE x.k = 3 DETACH DELETE x");
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.s = 1 RETURN n"));
    try testing.expectEqual(@as(usize, 2), try rowsOf(ga, s, "MATCH (x:X) RETURN x"));
}
