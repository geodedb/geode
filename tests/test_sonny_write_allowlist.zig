// SONNY-3139, 3146, 3166, 3182, 3183, 3184, 3190 (Task W fix round 3): the
// write-shape ALLOWLIST.
//
// A statement that writes is accepted only in an allowlisted shape
// (`write_shape.shapes`); anything else is refused with 0A000 before anything
// is written. Rounds 1 and 2 refused the shapes known to be broken, and every
// review found more (a SELECT projection, a path DELETE in a plain persisted
// session, a statement the parser split without a `;`, a write inside an IN
// subquery or a CTE body, a variable the dispatcher bound shadowing a pattern
// variable or a client parameter, an unbound variable read as null, an
// OPTIONAL MATCH WHERE that filtered the whole row).
//
// This file verifies EVERY allowlisted shape in the four sessions the server
// runs (in-memory, plain persisted, tenant-scoped, RLS-policy): the rows it
// writes, their values, what it returns and a count; a persisted store is
// read back again after a checkpoint and a reload. Then a representative set
// of shapes the allowlist does not name, every refused case of the round-2
// review's probes (wfix2-review out/a-j) among them, is refused (0A000, or a
// syntax error for a statement boundary without `;`) with NOTHING written.
// Statements run as the server runs them: the whole program through
// `executeProgramWithContext`.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const execution = h.execution;
const Value = h.Value;
const Check = h.Check;

// ---------------------------------------------------------------------------
// Running a case.

/// A client parameter, evaluated as `RETURN <expr>` in the session.
const Param = struct { name: []const u8, expr: []const u8 };

const Case = struct {
    /// The allowlisted shape the case exercises (documentation; the
    /// table test below checks every shape has a case).
    shape: ?geode.execution.write_shape.ShapeId = null,
    /// Run first, as the session; each must succeed.
    setup: []const []const u8 = &.{},
    write: []const u8,
    /// Run the write this many times (a MERGE's second run matches).
    times: usize = 1,
    params: []const Param = &.{},
    /// What the first and the last run return (null: not checked).
    want_first: ?[]const []const u8 = null,
    want: ?[]const []const u8 = null,
    /// The write must fail with this error, and change nothing.
    refused: ?anyerror = null,
    checks: []const Check = &.{},
};

/// The statements' allocator. Not the session's arena: a transaction's undo
/// log is allocated with it and outlives the arena (it is freed with the
/// store). Not a leak-checked one: SONNY-3148's leak tests check that.
const stmt_alloc = std.heap.page_allocator;

/// Run `query` as the server runs a request: the whole program through
/// `executeProgramWithContext`, with the session's context installed.
fn runProgram(s: *h.Session, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, s.arena.allocator());
    defer parsed.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    return execution.executeProgramWithContext(allocator, &parsed.program, s.ctx);
}

fn bindParams(s: *h.Session, params: []const Param) !void {
    if (params.len == 0) return;
    const aa = s.arena.allocator();
    const names = try aa.alloc([]const u8, params.len);
    const values = try aa.alloc(Value, params.len);
    for (params, names, values) |p, *n, *v| {
        n.* = p.name;
        const text = try std.fmt.allocPrint(aa, "RETURN {s} AS v", .{p.expr});
        const r = try s.run(text);
        v.* = r.rows[0][0];
    }
    s.ctx.query_param_names = names;
    s.ctx.query_param_values = values;
}

fn expectRun(s: *h.Session, f: *h.Failures, stage: []const u8, c: Case, want: ?[]const []const u8) !void {
    const aa = s.arena.allocator();
    var result = runProgram(s, stmt_alloc, c.write) catch |err| {
        try f.add("[{s}] {s} | {s}: error {s}", .{ @tagName(s.mode), c.write, stage, @errorName(err) });
        return;
    };
    defer result.deinit(stmt_alloc);
    const w = want orelse return;
    const got = try h.renderRows(aa, result);
    const exp = try aa.dupe([]const u8, w);
    std.mem.sort([]const u8, exp, {}, lessThan);
    var same = got.len == exp.len;
    if (same) for (got, exp) |g, e| {
        if (!std.mem.eql(u8, g, e)) same = false;
    };
    if (!same) try f.add("[{s}] {s} | {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), c.write, stage, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A session whose transaction undo log is not allocated from its arena (the
/// first statement to use the log sets its allocator, and the arena is freed
/// before the store and its log are).
fn openSession(mode: h.Mode) !h.Session {
    var s = try h.Session.init(mode);
    errdefer s.deinit();
    _ = geode.txn_undo_log.getGlobalUndoLog(stmt_alloc);
    try s.seed();
    return s;
}

fn runCase(mode: h.Mode, c: Case, f: *h.Failures) !void {
    var s = try openSession(mode);
    defer s.deinit();
    const aa = s.arena.allocator();
    for (c.setup) |q| {
        var r = runProgram(&s, stmt_alloc, q) catch |err| {
            try f.add("[{s}] {s}: setup {s} failed: {s}", .{ @tagName(mode), c.write, q, @errorName(err) });
            return;
        };
        r.deinit(stmt_alloc);
    }
    try bindParams(&s, c.params);
    if (c.refused) |want_err| {
        if (runProgram(&s, stmt_alloc, c.write)) |r| {
            var result = r;
            const got = try h.renderRows(aa, result);
            result.deinit(stmt_alloc);
            try f.add("[{s}] {s}: expected error {s}, got {{{s}}}", .{ @tagName(mode), c.write, @errorName(want_err), try std.mem.join(aa, ",", got) });
        } else |err| if (err != want_err) {
            try f.add("[{s}] {s}: expected error {s}, got error {s}", .{ @tagName(mode), c.write, @errorName(want_err), @errorName(err) });
        }
    } else {
        var i: usize = 0;
        while (i < c.times) : (i += 1) {
            const want = if (i == 0 and c.want_first != null) c.want_first else if (i + 1 == c.times) c.want else null;
            try expectRun(&s, f, if (i == 0) "first run" else "last run", c, want);
        }
    }
    s.ctx.query_param_names = &.{};
    s.ctx.query_param_values = &.{};
    const checks = if (c.refused != null) &unchanged else c.checks;
    for (checks) |chk| try h.expectRows(&s, f, "effect", c.write, chk.query, chk.want);
    try h.checkOthersUntouched(&s, f, c.write, "others");
    if (mode != .in_memory and c.refused == null) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        for (checks) |chk| try h.expectRows(&s, f, "effect after reload", c.write, chk.query, chk.want);
        try h.checkOthersUntouched(&s, f, c.write, "others after reload");
    }
}

fn runCases(title: []const u8, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish(title);
}

// ---------------------------------------------------------------------------
// The checks.

/// The seed, untouched (every refused case).
const unchanged = [_]Check{
    .{ .query = "MATCH (n:G) WHERE n.t = 1 AND n.x IS NULL AND n.y IS NULL AND n.z IS NULL AND n.c IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (n) WHERE n.x IS NOT NULL OR n.y IS NOT NULL OR n.c IS NOT NULL OR n.k IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (x:X) WHERE x.u = 1 AND x.x IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (q:Q) WHERE q.x IS NULL AND q.z IS NULL RETURN q.i", .want = &.{ "0", "1", "2", "3" } },
    .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.z IS NULL AND r.c IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (n) RETURN count(*) AS c", .want = &.{"24"} },
    .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"0"} },
};

fn gx(comptime want: []const []const u8) [1]Check {
    return .{.{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN n.i, n.x", .want = want }};
}

const g_unwritten = Check{ .query = "MATCH (n:G) WHERE n.x IS NULL RETURN count(*) AS c", .want = &.{"10"} };

// ---------------------------------------------------------------------------
// Every allowlisted shape, in every session.

const statement_cases = [_]Case{
    // CREATE: go/oidc's W1 / W2 (a node, a RETURN), and a relationship.
    .{ .shape = .create_statement, .write = "CREATE (z:Z {k: 1, s: 'a'})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k, z.s", .want = &.{"1|a"} },
        .{ .query = "MATCH (n) RETURN count(*) AS c", .want = &.{"25"} },
    } },
    .{ .shape = .create_statement, .write = "CREATE (z:Z {k: 2}) RETURN z.k AS k", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"2"} },
    } },
    .{ .shape = .create_statement, .write = "CREATE (a:A {k: 1})-[:T {w: 2}]->(b:Z {k: 3})", .checks = &.{
        .{ .query = "MATCH (a:A)-[t:T]->(b:Z) RETURN a.k, t.w, b.k", .want = &.{"1|2|3"} },
        .{ .query = "MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"11"} },
    } },
    .{ .shape = .create_statement, .write = "CREATE (a:A {k: $k}), (b:Z {k: $k + 1})", .params = &.{.{ .name = "k", .expr = "7" }}, .checks = &.{
        .{ .query = "MATCH (a:A) RETURN a.k", .want = &.{"7"} },
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"8"} },
    } },
    // INSERT.
    .{ .shape = .insert_statement, .write = "INSERT (z:Z {k: 4})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"4"} },
    } },
    .{ .shape = .insert_statement, .write = "INSERT (a:A {k: 1})-[:T]->(b:Z {k: 5})", .checks = &.{
        .{ .query = "MATCH (a:A)-[:T]->(b:Z) RETURN a.k, b.k", .want = &.{"1|5"} },
    } },
    // MERGE: go/oidc's W4..W8 (a bare SET, ON CREATE ... RETURN, ON CREATE and
    // ON MATCH with a CASE, run twice), the relationship idiom, two chains.
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z', h: 1}) SET m.k = 2", .times = 2, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.h, m.k", .want = &.{"z|1|2"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z'})", .times = 2, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"z"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z'}) ON CREATE SET m.k = 1, m.won = true ON MATCH SET m.won = false RETURN m.won AS won", .times = 2, .want_first = &.{"true"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k, m.won", .want = &.{"z|1|false"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (t:M {g: 'z'}) ON CREATE SET t.s = 's1', t.v = false ON MATCH SET t.s = CASE WHEN t.v = true THEN t.s ELSE 's2' END RETURN t.v AS v", .times = 2, .want_first = &.{"false"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.s", .want = &.{"s2"} },
    } },
    // SONNY-3240 (round-3 review C3): verified, the secret is kept. The ON
    // MATCH SET read `t` as null, so the CASE always overwrote it.
    .{ .shape = .merge_statement, .setup = &.{"CREATE (:M {g: 'z', s: 's1', v: true})"}, .write = "MERGE (t:M {g: 'z'}) ON CREATE SET t.s = 's1', t.v = false ON MATCH SET t.s = CASE WHEN t.v = true THEN t.s ELSE 's2' END RETURN t.v AS v", .times = 2, .want_first = &.{"true"}, .want = &.{"true"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.s, m.v", .want = &.{"s1|true"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z'}) ON CREATE SET m.k = 1 RETURN m.k AS k", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.k", .want = &.{"1"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (a:A {k: 1}) MERGE (b:Z {k: 2}) MERGE (a)-[:T]->(b)", .times = 2, .checks = &.{
        .{ .query = "MATCH (a:A)-[:T]->(b:Z) RETURN a.k, b.k", .want = &.{"1|2"} },
        .{ .query = "MATCH (n) RETURN count(*) AS c", .want = &.{"26"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (a:A {k: 1}), (b:Z {k: 2}) ON CREATE SET b.x = 1", .checks = &.{
        .{ .query = "MATCH (b:Z) RETURN b.k, b.x", .want = &.{"2|1"} },
        .{ .query = "MATCH (a:A) RETURN a.k", .want = &.{"1"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z'}) RETURN count(m) AS c", .times = 2, .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"1"} },
    } },
    .{ .shape = .merge_statement, .write = "MERGE (m:M {g: 'z'}) ON CREATE SET m:Extra", .checks = &.{
        .{ .query = "MATCH (m:Extra) RETURN m.g", .want = &.{"z"} },
    } },
    // MATCH ... DELETE: go/oidc's W15..W18, DETACH, a relationship, a
    // variable-length relationship.
    .{ .shape = .delete_statement, .write = "MATCH (q:Q {i: 0}) DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (q:Q) WHERE q.i >= 2 OR q.name = 'q-0' DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{"1"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (q:Q {i: 0}) DELETE q RETURN q.name AS n, q.i AS i", .want = &.{"q-0|0"}, .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"3"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (q:Q) DELETE q RETURN count(*) AS c", .want = &.{"4"}, .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (n:G {i: 5}) DETACH DELETE n", .checks = &.{
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (x:X) RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G)-[:R]->(:X) WHERE n.i = 5 RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .shape = .delete_statement, .write = "MATCH (n:G), (m:G)-[r:R*1..1]->(x:X) WHERE n.i = 1 AND m.i = 5 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
    } },
};

test "allowlist: CREATE, INSERT, MERGE and MATCH ... DELETE statements write what they name, in every session" {
    try runCases("statements", &statement_cases);
}

const match_cases = [_]Case{
    // MATCH ... SET / REMOVE: go/oidc's W9..W14.
    .{ .shape = .match_set, .write = "MATCH (n:G {i: 5}) SET n.x = 1, n.y = 'a'", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN n.i, n.x, n.y", .want = &.{"5|1|a"} },
        g_unwritten_but(9),
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G {i: 5}) SET n.x = CASE WHEN n.x IS NULL THEN 1 ELSE n.x + 1 END RETURN n.x AS x", .times = 2, .want_first = &.{"1"}, .want = &.{"2"}, .checks = &gx(&.{"5|2"}) },
    .{ .shape = .match_set, .write = "MATCH (n:G {i: 5}) SET n.t = n.t + 1 RETURN n.t AS t, n.i AS i", .want = &.{"2|5"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t = 2 RETURN n.i", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i >= 7 AND n.t = 1 SET n.x = 1", .checks = &gx(&.{ "7|1", "8|1", "9|1" }) },
    .{ .shape = .match_set, .write = "MATCH (q:Q {i: 1}) WHERE q.name = 'q-1' SET q.x = 1 RETURN q.name AS n, q.x AS x", .want = &.{"q-1|1"}, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.x = 1 RETURN q.i", .want = &.{"1"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G {i: $i}) WHERE n.g = $g SET n.x = $v RETURN n.x AS x", .params = &.{ .{ .name = "i", .expr = "6" }, .{ .name = "g", .expr = "'b'" }, .{ .name = "v", .expr = "'pv'" } }, .want = &.{"pv"}, .checks = &gx(&.{"6|pv"}) },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i IN [2, 3] SET n.x = coalesce(n.x, 0) + n.i", .checks = &gx(&.{ "2|2", "3|3" }) },
    .{ .shape = .match_set, .write = "MATCH (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = n.i RETURN x.x AS x, n.i AS i", .want = &.{"5|5"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 5 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i >= 7 SET n.x = n.i RETURN sum(n.x) AS s", .want = &.{"24"}, .checks = &gx(&.{ "7|7", "8|8", "9|9" }) },
    .{ .shape = .match_set, .write = "MATCH (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 SET r.z = 1", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.z = 1 RETURN r.w", .want = &.{"w-5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G)-[:R]->(x:X)<-[:R]-(m:G) WHERE n.i = 5 SET m.x = 1", .checks = &gx(&.{"5|1"}) },
    .{ .shape = .match_set, .write = "MATCH (n:G)-[:R*1..1]->(x:X) WHERE n.i = 5 SET x.x = 1", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1, q.x = 2", .checks = &.{
        gx(&.{"5|1"})[0],
        .{ .query = "MATCH (q:Q) WHERE q.x = 2 RETURN q.i", .want = &.{"0"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G {i: 5}) SET n:Hit", .checks = &.{
        .{ .query = "MATCH (n:Hit) RETURN n.i", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .setup = &.{"MATCH (n:G {i: 5}) SET n:Hit"}, .write = "MATCH (n:G {i: 5}) REMOVE n:Hit, n.t", .checks = &.{
        .{ .query = "MATCH (n:Hit) RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{"5"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G {i: 5}) SET n = {i: 5, s: 'm'}", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.s = 'm' RETURN n.i, n.t, n.g", .want = &.{"5|null|null"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i >= 7 SET n.x = 1 RETURN count(*) AS c, sum(n.i) AS s", .want = &.{"3|24"}, .checks = &gx(&.{ "7|1", "8|1", "9|1" }) },
    .{ .shape = .match_set, .write = "MATCH (n:G) SET n.x = 1 RETURN n.i AS i ORDER BY i LIMIT 2", .want = &.{ "0", "1" }, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i >= 8 OPTIONAL MATCH (n)-[:R]->(x:X) SET x.x = 1 RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{ "8", "9" } },
    } },
    .{ .shape = .match_set, .write = "MATCH (n:G) WHERE n.i < 2 OPTIONAL MATCH (n)-[:NOPE]->(y) SET n.y = 1, y.y = 1 RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (n) WHERE n.y = 1 RETURN n.i", .want = &.{ "0", "1" } },
    } },
    .{ .shape = .match_set, .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = k", .checks = &gx(&.{"5|5"}) },
    .{ .shape = .match_set, .write = "WITH [5, 6] AS ids MATCH (n:G) WHERE n.i IN ids SET n.x = 1 RETURN count(*) AS c", .want = &.{"2"}, .checks = &gx(&.{ "5|1", "6|1" }) },
    .{ .shape = .match_set, .write = "WITH $m AS m MATCH (n:G) WHERE n.i = m.k SET n.x = m.v", .params = &.{.{ .name = "m", .expr = "{k: 5, v: 'mv'}" }}, .checks = &gx(&.{"5|mv"}) },
    .{ .shape = .match_set, .write = "WITH 5 AS k MATCH (n:G {i: k}) SET n.x = 1", .checks = &gx(&.{"5|1"}) },
    .{ .shape = .match_set, .write = "WITH 1 AS k WHERE k > 5 MATCH (n:G) SET n.x = 1", .checks = &.{g_unwritten} },
    .{ .shape = .match_set, .write = "WITH 5 AS k LIMIT 0 MATCH (n:G) WHERE n.i = k SET n.x = 1", .checks = &.{g_unwritten} },
    .{ .shape = .match_set, .write = "WITH 1 AS k WHERE k MATCH (n:G) SET n.x = 1", .checks = &.{g_unwritten} },
    .{ .shape = .match_set, .write = "WITH [5, 6, 5] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u SET n.x = coalesce(n.x, 0) + 1", .checks = &gx(&.{ "5|2", "6|1" }) },
    .{ .shape = .match_set, .write = "WITH $rows AS rows UNWIND rows AS r MATCH (n:G) WHERE n.i = r.id SET n.x = r.v RETURN n.i AS i", .params = &.{.{ .name = "rows", .expr = "[{id: 5, v: 'a'}, {id: 6, v: 'b'}]" }}, .want = &.{ "5", "6" }, .checks = &gx(&.{ "5|a", "6|b" }) },
    // MATCH ... [SET] DELETE (the query form).
    .{ .shape = .match_delete, .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    // SONNY-3384: DETACH DELETE after a SET, a REMOVE, a WITH or a CREATE
    // (a syntax error before the v0.8.23 reconciliation; on the r12 line
    // it parsed). Every clause runs, in order.
    .{ .shape = .match_delete, .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 DETACH DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
        .{ .query = "MATCH (q:Q) WHERE q.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .shape = .match_delete, .write = "MATCH (n:G) WHERE n.i = 5 SET n.z = 1 DETACH DELETE n", .checks = &.{
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (x:X) RETURN count(*) AS c", .want = &.{"10"} },
        .{ .query = "MATCH (n:G) WHERE n.z IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .shape = .match_with_write, .write = "MATCH (q:Q) WITH q WHERE q.i = 0 SET q.x = 1 DETACH DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    .{ .shape = .match_delete, .write = "MATCH (q:Q) WHERE q.i = 0 REMOVE q.name DETACH DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
        .{ .query = "MATCH (q:Q) WHERE q.name IS NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) DETACH DELETE n", .checks = &.{
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"1"} },
    } },
    .{ .shape = .match_delete, .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 SET n.z = 1 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G) WHERE n.z = 1 RETURN n.i", .want = &.{"5"} },
    } },
    .{ .shape = .match_delete, .write = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 SET n.z = 1 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G) WHERE n.z = 1 RETURN n.i", .want = &.{"5"} },
    } },
    .{ .shape = .match_delete, .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 SET n.z = 1, x.x = 2 DELETE r RETURN n.z AS z, x.x AS x", .want = &.{"1|2"}, .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (x:X) WHERE x.x = 2 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .shape = .match_delete, .write = "WITH 0 AS k MATCH (q:Q) WHERE q.i = k DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    .{ .shape = .match_delete, .write = "WITH [0, 1] AS l UNWIND l AS u MATCH (q:Q) WHERE q.i = u DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "2", "3" } },
    } },
    .{ .shape = .match_delete, .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[r:NOPE]->() DELETE r", .checks = &.{
        .{ .query = "MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"10"} },
    } },
    // MATCH ... CREATE: go/oidc's W3, a relationship between matched nodes,
    // one per row, with a SET, a DELETE, an initial WITH, an UNWIND.
    .{ .shape = .match_create, .write = "MATCH (n:G {i: 5}) WHERE CASE WHEN n.c IS NULL THEN 0 ELSE n.c END = 0 CREATE (z:Z {k: n.i}) RETURN z.k AS k", .want = &.{"5"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"5"} },
    } },
    .{ .shape = .match_create, .write = "MATCH (a:G {i: 5}), (b:Q {i: 0}) CREATE (a)-[:T {w: 1}]->(b)", .checks = &.{
        .{ .query = "MATCH (a:G)-[t:T]->(b:Q) RETURN a.i, t.w, b.i", .want = &.{"5|1|0"} },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G) WHERE n.i >= 7 CREATE (n)-[:T]->(:Z {k: n.i}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.k", .want = &.{ "7|7", "8|8", "9|9" } },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(z:Z) SET z.k = 5, n.x = 1", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, n.x, z.k", .want = &.{"5|1|5"} },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(z:Z) SET z.k = 5, n.x = 1 RETURN z.k AS k, n.x AS x", .want = &.{"5|1"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, n.x, z.k", .want = &.{"5|1|5"} },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 CREATE (n)-[:T]->(x) DELETE r", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(x:X) RETURN n.i, x.j", .want = &.{"5|5"} },
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
    } },
    .{ .shape = .match_create, .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = k CREATE (n)-[:T]->(:Z {k: k})", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.k", .want = &.{"5|5"} },
    } },
    .{ .shape = .match_create, .write = "WITH [5, 6] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u CREATE (n)-[:T]->(:Z {u: u})", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.u", .want = &.{ "5|5", "6|6" } },
    } },
    .{ .shape = .match_create, .write = "MATCH (n:G) WHERE n.i >= 8 OPTIONAL MATCH (n)-[:NOPE]->(y) CREATE (n)-[:T]->(:Z {k: n.i}) RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.k", .want = &.{ "8|8", "9|9" } },
    } },
    // MATCH ... MERGE.
    .{ .shape = .match_merge, .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } },
    } },
    .{ .shape = .match_merge, .write = "MATCH (n:G) MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } },
    } },
    .{ .shape = .match_merge, .write = "MATCH (a:G), (b:Q) WHERE a.i = 5 AND b.i = 0 MERGE (a)-[r:T]->(b) ON CREATE SET r.w = 1 ON MATCH SET r.w = 2", .times = 2, .checks = &.{
        .{ .query = "MATCH (:G)-[t:T]->(:Q) RETURN t.w", .want = &.{"2"} },
    } },
    .{ .shape = .match_merge, .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) ON CREATE SET m.k = n.i", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k", .want = &.{"z|5"} },
    } },
    .{ .shape = .match_merge, .write = "WITH 'z' AS g MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: g}) ON CREATE SET m.k = n.i", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k", .want = &.{"z|5"} },
    } },
    // MATCH ... WITH ... SET / REMOVE / DELETE.
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &gx(&.{ "7|1", "8|1", "9|1" }) },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WHERE n.i >= 7 WITH n AS m SET m.x = 1", .checks = &gx(&.{ "7|1", "8|1", "9|1" }) },
    .{ .shape = .match_with_write, .write = "MATCH (a:G), (q:Q) WITH DISTINCT a SET a.c = coalesce(a.c, 0) + 1", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.c = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WITH n GROUP BY n HAVING n.i > 7 SET n.x = 1", .checks = &gx(&.{ "8|1", "9|1" }) },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WITH n ORDER BY n.i DESC LIMIT 3 SET n.x = 1", .checks = &gx(&.{ "7|1", "8|1", "9|1" }) },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WITH n, n.i AS k WHERE k >= 8 SET n.x = k", .checks = &gx(&.{ "8|8", "9|9" }) },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WITH n AS m, n AS k WHERE m.i >= 8 SET k.x = 1", .checks = &gx(&.{ "8|1", "9|1" }) },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WHERE n.i >= 7 WITH n REMOVE n.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    .{ .shape = .match_with_write, .write = "MATCH (q:Q) WITH q WHERE q.i < 2 DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "2", "3" } },
    } },
    .{ .shape = .match_with_write, .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:NOPE]->(y) WITH n, y SET n.x = 1", .checks = &gx(&.{"5|1"}) },
    // MATCH ... WITH ... CREATE / MERGE.
    .{ .shape = .match_with_create, .write = "MATCH (n:G) WITH n WHERE n.i >= 7 CREATE (n)-[:T]->(:Z {k: n.i}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.k", .want = &.{ "7|7", "8|8", "9|9" } },
    } },
    .{ .shape = .match_with_create, .write = "MATCH (n:G) WITH DISTINCT n.g AS g CREATE (:Z {g: g})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.g", .want = &.{ "a", "b" } },
    } },
    .{ .shape = .match_with_merge, .write = "MATCH (n:G) WITH n WHERE n.i >= 7 MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"b"} },
    } },
    // CREATE ... [WITH] SET (the query form), an initial WITH, an UNWIND.
    .{ .shape = .create_then_set, .write = "CREATE (z:Z {k: 1}) WITH z SET z.k = 2", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"2"} },
    } },
    .{ .shape = .create_then_set, .write = "WITH 7 AS k CREATE (:Z {k: k})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"7"} },
    } },
    .{ .shape = .create_then_set, .write = "WITH {k: 3} AS props CREATE (z:Z) SET z = props", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"3"} },
    } },
    .{ .shape = .create_then_set, .write = "WITH $rows AS rows UNWIND rows AS r CREATE (:U {id: r.id, name: r.name})", .params = &.{.{ .name = "rows", .expr = "[{id: 1, name: 'a'}, {id: 2, name: 'b'}]" }}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.id, u.name", .want = &.{ "1|a", "2|b" } },
    } },
    // WITH ... MERGE.
    .{ .shape = .with_merge, .write = "WITH 'q' AS g MERGE (m:M {g: g}) ON CREATE SET m.k = g", .times = 2, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k", .want = &.{"q|q"} },
    } },
    .{ .shape = .with_merge, .write = "WITH 1 AS x WHERE x > 5 MERGE (m:M {g: 'never'})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"0"} },
    } },
};

fn g_unwritten_but(comptime n: usize) Check {
    return .{ .query = "MATCH (n:G) WHERE n.x IS NULL RETURN count(*) AS c", .want = &.{std.fmt.comptimePrint("{d}", .{n})} };
}

test "allowlist: every MATCH, WITH, CREATE and MERGE query shape writes what it names and returns what it wrote, in every session" {
    try runCases("query shapes", &match_cases);
}

const composed_cases = [_]Case{
    // FOR x IN <list> <an allowlisted part>.
    .{ .write = "FOR v IN [5, 6] MATCH (n:G) WHERE n.i = v SET n.x = v", .checks = &gx(&.{ "5|5", "6|6" }) },
    .{ .write = "FOR r IN $rows CREATE (:U {id: r.id})", .params = &.{.{ .name = "rows", .expr = "[{id: 1}, {id: 2}]" }}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.id", .want = &.{ "1", "2" } },
    } },
    .{ .write = "FOR u IN [5, 6] MERGE (m:M {g: u})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "5", "6" } },
    } },
    .{ .write = "WITH [5, 6] AS l FOR v IN l MATCH (n:G) WHERE n.i = v SET n.x = 1", .checks = &gx(&.{ "5|1", "6|1" }) },
    .{ .write = "WITH 5 AS k FOR v IN [1] MATCH (n:G) WHERE n.i = k SET n.x = v", .checks = &gx(&.{"5|1"}) },
    // PROFILE of an allowlisted shape.
    .{ .write = "PROFILE MATCH (n:G) WHERE n.i = 5 SET n.x = 1", .checks = &gx(&.{"5|1"}) },
    .{ .write = "PROFILE WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1", .checks = &gx(&.{"5|1"}) },
    .{ .write = "PROFILE WITH [5, 6] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u SET n.x = 1", .checks = &gx(&.{ "5|1", "6|1" }) },
    .{ .write = "PROFILE MERGE (m:M {g: 'z'}) ON CREATE SET m.k = 1", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k", .want = &.{"z|1"} },
    } },
    // UNION [ALL] of MATCH ... SET parts.
    .{ .write = "MATCH (n:G) WHERE n.i = 1 SET n.x = 1 RETURN n.i AS i UNION MATCH (q:Q) WHERE q.i = 1 SET q.x = 1 RETURN q.i AS i", .want = &.{"1"}, .checks = &.{
        gx(&.{"1|1"})[0],
        .{ .query = "MATCH (q:Q) WHERE q.x = 1 RETURN q.i", .want = &.{"1"} },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i = 2 RETURN n.i AS i UNION ALL MATCH (q:Q) WHERE q.i = 2 SET q.x = 1 RETURN q.i AS i", .want = &.{ "2", "2" }, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.x = 1 RETURN q.i", .want = &.{"2"} },
    } },
    // Programs: statements separated by ';', validated before any runs.
    .{ .write = "MATCH (n:G {i: 5}) SET n.x = 1; MATCH (q:Q {i: 0}) DELETE q; CREATE (:Z {k: 9})", .checks = &.{
        gx(&.{"5|1"})[0],
        .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"3"} },
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"9"} },
    } },
    .{ .write = "START TRANSACTION; MATCH (n:G {i: 5}) SET n.x = 1; MERGE (m:M {g: 'z'}) SET m.k = 1; COMMIT", .checks = &.{
        gx(&.{"5|1"})[0],
        .{ .query = "MATCH (m:M) RETURN m.k", .want = &.{"1"} },
    } },
    // SONNY-3384: PROFILE of MATCH ... SET ... DETACH DELETE runs it.
    .{ .write = "PROFILE MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 DETACH DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    // (ROLLBACK undoes what the transaction did; SONNY-3059.)
    .{ .write = "START TRANSACTION; CREATE (:Z {k: 1}); ROLLBACK", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    } },
};

test "allowlist: FOR, PROFILE, UNION and programs of allowlisted shapes, in every session" {
    try runCases("composed", &composed_cases);
}

// ---------------------------------------------------------------------------
// Refused, with nothing written.

const refused = error.WriteClauseNotApplied;
const syntax = error.UnexpectedToken;

/// Every refused case of the round-2 review's probes (wfix2-review cases
/// a-j), and the shapes the allowlist leaves out.
const refused_cases = [_]Case{
    // SONNY-3166: a statement boundary without ';' (review a: SPL1..SPL23,
    // e: TN11, PS2, i: DP9, PG1..PG3).
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 CREATE (n)-[:T]->(z:Z)", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (a:A) SET a.k = 1 CREATE (n)-[:T]->(b:B)", .refused = syntax },
    .{ .write = "MATCH (q:Q) DELETE q CREATE (w:W)", .refused = syntax },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 DETACH DELETE q CREATE (w:W {i: q.i})", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 MERGE (m:M {g: n.g})", .refused = syntax },
    // SONNY-6496 item 3: refused with 0A000 naming the shape (it was a
    // syntax error).
    .{ .write = "MERGE (m:M {g: 'z'}) CREATE (m)-[:T]->(z:Z)", .refused = error.UnsupportedQueryShape },
    .{ .write = "MATCH (n:G) WHERE n.i >= 8 SET n.x = 1 WITH n MATCH (n)-[:R]->(x:X) SET x.x = 1", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 WITH n SET n.y = 2", .refused = syntax },
    .{ .write = "MERGE (m:M {g: 'z'}) WITH m SET m.k = 1", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) SET z.k = 1 MERGE (m:M {g: n.g})", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 OPTIONAL MATCH (n)-[:R]->(x:X) SET x.x = 1", .refused = syntax },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 MATCH (n)-[:R]->(x:X) SET x.x = 1", .refused = syntax },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 MATCH (q:Q) DELETE q", .refused = syntax },
    // SONNY-3384: it parses now (DETACH DELETE after a SET); a path DELETE
    // is refused (SONNY-3146).
    .{ .write = "MATCH (n:G), p = (m:G)-[:R]->(x:X) WHERE n.i = 1 AND m.i = 5 SET n.z = 1 DETACH DELETE p", .refused = refused },
    .{ .write = "START TRANSACTION MATCH (n:G) WHERE n.i = 5 SET n.x = 1 WITH n SET n.y = 2 COMMIT", .refused = syntax },
    .{ .write = "MATCH (n:G {i: 5}) SET n.x = 1 MATCH (q:Q {i: 0}) SET q.x = 1", .refused = syntax },
    // A DELETE with no MATCH (SPL7, SPL8).
    .{ .write = "DETACH DELETE q", .refused = refused },
    .{ .write = "DELETE q", .refused = refused },
    // SONNY-3166: a program is validated before any statement runs: the
    // first statement's SET is not left behind by the second's refusal.
    .{ .write = "MATCH (n:G {i: 5}) SET n.x = 1; MATCH (q:Q) WITH q MATCH (q) DELETE q", .refused = refused },
    .{ .write = "MATCH (n:G {i: 5}) SET n.x = 1; DETACH DELETE q", .refused = refused },
    // SONNY-3139 (reopened): a SELECT projection (review b: SEL1..SEL7,
    // i: INS7, PS10, TN13, RL12).
    .{ .write = "WITH 1 AS one SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 RETURN q.i AS i UNION ALL SELECT 1 AS one MATCH (n:G) WHERE n.i = 5 SET n.x = 1 RETURN n.i AS i", .refused = refused },
    .{ .write = "CALL { SELECT 1 AS one MATCH (n:G) WHERE n.i = 5 SET n.x = 1 RETURN n } RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH 1 AS one SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(:Z)", .refused = refused },
    .{ .write = "WITH 1 AS one SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 REMOVE n.t", .refused = refused },
    .{ .write = "LET $z = 1 SELECT 1 AS one MATCH (n:G) WHERE n.i = 5 SET n.x = 1", .refused = refused },
    .{ .write = "WITH 1 AS one SELECT 2 AS two MATCH (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1", .refused = refused },
    // SONNY-3182: a write inside an expression, a subquery or a CTE body, in
    // a read too (review b, i: INS1..INS7, PRF6, CTE1..CTE3, TN10, RL9).
    .{ .write = "MATCH (n:G) WHERE n.i IN (MATCH (q:Q) SET q.c = coalesce(q.c, 0) + 1 RETURN q.i) RETURN count(*) AS c", .refused = refused },
    .{ .write = "RETURN 1 IN (CREATE (z:Z {k: 1}) DELETE z RETURN 1) AS b", .refused = refused },
    .{ .write = "RETURN 5 IN (MATCH (n:G) SET n.x = 1, nn.y = 2 RETURN n.i) AS b", .refused = refused },
    .{ .write = "RETURN 5 IN (WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1 RETURN n.i) AS b", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 RETURN n.i NOT IN (MATCH (q:Q) WHERE q.i = 0 DELETE q RETURN 0) AS b", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.y = 1 IN (MATCH (q:Q) SET q.x = 1 RETURN 1)", .refused = refused },
    .{ .write = "RETURN 5 IN (WITH 1 AS one SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 SET n.x = 1 RETURN n.i) AS b", .refused = refused },
    .{ .write = "PROFILE MATCH (n:G) WHERE n.i IN (MATCH (q:Q) SET q.c = coalesce(q.c, 0) + 1 RETURN q.i) RETURN count(*) AS c", .refused = refused },
    .{ .write = "MATCH (n:G {i: 5}) SET n.x = 1 RETURN 1 IN (MATCH (q:Q) DELETE q RETURN 1) AS b", .refused = refused },
    .{ .write = "MATCH (n:G {i: 1 IN (MATCH (q:Q) SET q.x = 1 RETURN 1)}) RETURN n", .refused = refused },
    .{ .write = "WITH w AS (MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i) MATCH (n:G) RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH w AS (CREATE (z:Z {k: 1}) DELETE z RETURN 1 AS i) MATCH (n:G) RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH w AS (MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i) RETURN w AS w", .refused = refused },
    .{ .write = "RETURN 1 IN (MATCH (q:Q) SET q.x = 1 RETURN q.i) AS b", .refused = refused },
    // UNION, INTERSECT and EXCEPT (review b: UNI2..UNI9; SONNY-3183 I1).
    .{ .write = "WITH 1 AS w FOR v IN [1] CREATE (:Z {k: v}) RETURN v AS i UNION ALL MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i", .refused = refused },
    .{ .write = "WITH 1 AS one UNWIND [1, 2] AS u CREATE (:Z {k: u}) RETURN u AS i UNION ALL MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i", .refused = refused },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i UNION ALL CALL { MATCH (n:G) WHERE n.i = 5 SET n.x = 1, zz.y = 1 RETURN n } RETURN n.i AS i", .refused = refused },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 RETURN q.i AS i UNION ALL WITH 1 AS w FOR v IN [1] CREATE (z:Z {k: v}) DELETE z RETURN v AS i", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 1 SET n.x = 1 RETURN n.i AS i INTERSECT MATCH (q:Q) WHERE q.i = 1 SET q.x = 1 RETURN q.i AS i", .refused = refused },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN 2 AS i EXCEPT MATCH (q:Q) WITH q MATCH (q) DELETE q RETURN 1 AS i", .refused = refused },
    .{ .write = "CREATE (z:Z {k: 7}) RETURN z.k AS k UNION SELECT z.k AS k", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 1 SET n.x = 1 RETURN n.i AS i UNION MATCH (n:G) WHERE n.i = 2 CREATE (n)-[:T]->(:Z) RETURN n.i AS i", .refused = refused },
    // CALL { }, VALUES and nesting (review b: NEST1, VAL1..VAL4; h: CS1..CS4).
    .{ .write = "CALL { CALL { MATCH (n:G) WHERE n.i = 5 SET n.x = 1 RETURN n } RETURN n } RETURN count(*) AS c", .refused = refused },
    .{ .write = "CALL { WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1 RETURN n } RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH 5 AS k CALL { WITH k MATCH (n:G) WHERE n.i = k SET n.x = 1 RETURN n } RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH 5 AS k CALL { MATCH (n:G) WHERE n.i = k SET n.x = 1 RETURN n } RETURN count(*) AS c", .refused = refused },
    .{ .write = "VALUES (5) AS (k) MATCH (n:G) WITH n, k WHERE n.i = k SET n.x = 1", .refused = refused },
    // SONNY-3184: EXISTS / COUNT and OPTIONAL MATCH forms (review b, i, j:
    // EXI1, EXI2, EXR2, EXR3; d: OPT2, OPT4, OPT6, OPT8; c: UW4; i: OPT6W).
    .{ .write = "MATCH (n:G) WHERE EXISTS { MATCH (n)-[:R]->(x:X) WHERE x.j >= 8 } SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE EXISTS { (n)-[:R]->(x:X) WHERE x.j >= 8 } SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WITH n WHERE EXISTS { MATCH (n)-[:R]->(x:X) WHERE x.j >= 8 } SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WITH n WHERE COUNT { (n)-[:R]->(:X) } > 0 AND n.i >= 8 SET n.x = 1", .refused = refused },
    .{ .write = "OPTIONAL MATCH (n:G) WHERE n.i = 99 SET n.x = 1 RETURN count(*) AS c", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:NOPE]->(y) CREATE (n)-[:T]->(y)", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:R]->(x:X) MERGE (x)-[:T]->(:Z)", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:R]->(x:X) OPTIONAL MATCH (x)<-[:R]-(m:G) SET m.y = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:R]->(x:X) OPTIONAL MATCH (x)<-[:R]-(m:G) WITH m SET m.y = 1", .refused = refused },
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) WHERE x.j > 100 SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (q:Q) OPTIONAL MATCH (n:G) WHERE n.i = q.i SET n.x = 1", .refused = refused },
    .{ .write = "WITH 1 AS one UNWIND [5, 99] AS u OPTIONAL MATCH (n:G) WHERE n.i = u SET n.x = 1", .refused = refused },
    // SONNY-6337 / SONNY-3184: an OPTIONAL MATCH's own WHERE after a MATCH's
    // WHERE parses now (each clause keeps its WHERE; it was a syntax error),
    // so the write gate refuses it, as it does the shape without the first
    // WHERE (two lines up).
    .{ .write = "MATCH (n:G) WHERE n.i = 5 OPTIONAL MATCH (n)-[:R]->(x:X) WHERE x.j > 100 SET n.x = 1", .refused = refused },
    // SONNY-3146 (reopened): a path DELETE (review d: DP1, DP2, DP4..DP7;
    // e: TN4, RL2, RL10, PS3; i: PS3, PS8, PS9, PS11; j: PS12..PS19).
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DELETE p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE p RETURN p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WITH p, n WHERE n.i = 5 SET n.z = 1 DELETE p", .refused = refused },
    .{ .write = "MATCH p = shortestPath((a:G)-[*]-(b:X)) WHERE a.i = 5 AND b.j = 5 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH (n:G), p = (m:G)-[:R]->(x:X) WHERE n.i = 1 AND m.i = 5 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R*1..2]->(x:X) WHERE n.i = 5 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH p = (q:Q) WHERE q.i = 0 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH p = (q:Q) WHERE q.i = 0 SET q.x = 1 DELETE p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 AND length(p) = 1 DETACH DELETE p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE p RETURN count(*) AS c", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE n, p", .refused = refused },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 SET n.x = 1", .refused = refused },
    // SONNY-3183 (I2, I3) and SONNY-3184: unbound variables, a name the
    // dispatcher binds shadowing a pattern variable or a client parameter
    // (review c: IW12, IW13, UW9; d: WS4; j: UB1..UB3).
    .{ .write = "WITH nosuch AS k MATCH (n:G) WHERE n.i = k SET n.x = 1", .refused = refused },
    .{ .write = "WITH nosuch AS l UNWIND l AS u CREATE (:U {u: u})", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.y = nosuch", .refused = refused },
    // SONNY-6496: n is not in scope after `WITH n AS m` (ISO/IEC 39075
    // 20.12 SR 8): refused with 42000 before the write shape is checked.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 WITH n AS m SET m.y = n.i", .refused = error.VariableNotInScope },
    // SONNY-3367 (round 4b-1c): a value (a WITH expression's alias, a FOR
    // variable) named as a node pattern is refused as a variable-kind
    // conflict (42000), before the write shape is checked.
    .{ .write = "WITH 5 AS n MATCH (n:G) WHERE n.i = 5 SET n.x = 1", .refused = error.VariableKindConflict },
    .{ .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = $k SET n.x = 1", .params = &.{.{ .name = "k", .expr = "7" }}, .refused = refused },
    .{ .write = "WITH [5] AS l UNWIND l AS n MATCH (n:G) SET n.x = 1", .refused = refused },
    .{ .write = "FOR n IN [5] MATCH (n:G) SET n.x = 1", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (n:G) WHERE nosuch.i = 5 SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z {k: nosuch.k})", .refused = refused },
    .{ .write = "MERGE (m:M {g: 'z'}) ON CREATE SET m.k = nosuch", .refused = refused },
    .{ .write = "MATCH (q:Q) WHERE nosuch = 1 DELETE q", .refused = refused },
    .{ .write = "WITH 5 AS k WHERE k > 1 FOR v IN [1] MATCH (n:G) WHERE n.i = k SET n.x = v", .refused = refused },
    // The shapes the allowlist leaves out (SONNY-3111).
    .{ .write = "MATCH (q:Q) WITH q MATCH (q) DELETE q", .refused = refused },
    .{ .write = "MATCH (n:G) WITH n MATCH (n)-[:R]->(x:X) SET x.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WITH n WITH n SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WITH * WHERE n.i >= 8 SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WITH n.g AS g, collect(n) AS ns GROUP BY g HAVING size(ns) > 3 CREATE (:Z {g: g})", .refused = refused },
    .{ .write = "WITH [5, 6, 7] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u WITH n WHERE n.i > 5 SET n.x = 1", .refused = refused },
    .{ .write = "WITH [5, 6, 7] AS l UNWIND l AS u MATCH (n:G) WHERE n.i = u SET n.x = 1 RETURN n.i AS i SKIP 0", .refused = refused },
    .{ .write = "WITH 1 AS one UNWIND [1, 2] AS u CREATE (:U {u: u}) RETURN count(*) AS c", .refused = refused },
    .{ .write = "WITH count(*) AS c MATCH (n:G) SET n.x = c", .refused = refused },
    .{ .write = "WITH 1 AS x WHERE x > 5 MATCH (n:G) SET n.x = 1 RETURN count(*) AS c", .refused = refused },
    .{ .write = "CREATE (z:Z {k: 1}) DELETE z", .refused = refused },
    .{ .write = "CREATE (a:A)-[r:T]->(b:B) SET r.w = 1", .refused = refused },
    .{ .write = "CREATE (z:Z {k: 1}) WITH z AS w SET w.k = 2", .refused = refused },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(z:Z) WITH z SET z.k = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) DELETE z", .refused = refused },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 MERGE (m:M {g: 'z'}) DELETE q", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (a:G) WHERE a.i = 5 MERGE (a)-[r:T]->(b:B {k: 1}) ON CREATE SET a.x = 1", .refused = refused },
    .{ .write = "MERGE (a:A {k: 1})-[r:T]->(b:B {k: 2}) ON CREATE SET a.x = 1, r.w = 2", .refused = refused },
    .{ .write = "MATCH (a:G), (x:X) WHERE a.i = 5 AND x.j = 6 MERGE (a)-[r:T]->(x) ON CREATE SET x.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) SET n.x = 1 CALL algo.pageRank.stream({iterations: 1}) YIELD nodeId, score RETURN count(*) AS c", .refused = refused },
    .{ .write = "MATCH (n:G) SET n.x = 1, nn.y = 2", .refused = refused },
    .{ .write = "MATCH (a:G)-[r:R]->(x:X) WHERE x.j = 9 WITH r SET r:Foo", .refused = refused },
    .{ .write = "MATCH (n:G)-[r*1..1]->(x:X) WHERE n.i = 5 SET r.k = 1", .refused = error.VariableLengthPathWrite },
    .{ .write = "LET $k = 5 MATCH (n:G) WHERE n.i = $k SET n.x = 1", .refused = refused },
    .{ .write = "PROFILE LET $k = 5 MATCH (n:G) WHERE n.i = $k SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 FILTER n.t = 1 SET n.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 LET k = n.i SET n.x = k", .refused = refused },
    .{ .write = "MATCH TRAIL (n:G)-[:R]->(x:X) WHERE n.i = 5 SET x.x = 1", .refused = refused },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN *", .refused = refused },
};

test "allowlist: every shape it leaves out, and every refused case of the review, is refused with nothing written" {
    try runCases("refused", &refused_cases);
}

// SONNY-3059: a rolled-back `SET n:L` kept its label postings, so no label is
// set or removed inside an explicit transaction.
test "allowlist: a label SET or REMOVE inside an explicit transaction runs, and ROLLBACK undoes it (SONNY-3059)" {
    // The v0823 line refused these while ROLLBACK undid only what a
    // transaction created; the r12 line's SONNY-3059 (round 18) undoes every
    // change, labels included, so the v0.8.23 reconciliation accepts them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        var s = try openSession(mode);
        defer s.deinit();
        const programs = [_][]const u8{
            "START TRANSACTION; MATCH (n:G {i: 5}) SET n:Hit; ROLLBACK",
            "START TRANSACTION; MATCH (n:G {i: 5}) REMOVE n:G; ROLLBACK",
            "START TRANSACTION; MERGE (m:M {g: 'z'}) ON CREATE SET m:Extra; ROLLBACK",
            "START TRANSACTION; MATCH (n:G {i: 6}) SET n:Kept; COMMIT",
        };
        for (programs) |p| {
            if (runProgram(&s, stmt_alloc, p)) |r| {
                var result = r;
                result.deinit(stmt_alloc);
            } else |err| {
                try f.add("[{s}] {s}: expected it to run, got {s}", .{ @tagName(mode), p, @errorName(err) });
            }
        }
        try h.expectRows(&s, &f, "effect", "label in a transaction", "MATCH (n:Hit) RETURN count(*) AS c", &.{"0"});
        try h.expectRows(&s, &f, "effect", "label in a transaction", "MATCH (n:G) RETURN count(*) AS c", &.{"10"});
        try h.expectRows(&s, &f, "effect", "label in a transaction", "MATCH (m:M) RETURN count(*) AS c", &.{"0"});
        try h.expectRows(&s, &f, "effect", "label in a transaction", "MATCH (m:Extra) RETURN count(*) AS c", &.{"0"});
        try h.expectRows(&s, &f, "effect", "label in a transaction", "MATCH (n:Kept) RETURN n.i", &.{"6"});
    }
    try f.finish("labels in a transaction");
}

// ---------------------------------------------------------------------------
// The table, the parser and the classifiers.

test "allowlist: every shape in the table has a verified case above" {
    const ws = geode.execution.write_shape;
    const all = [_][]const Case{ &statement_cases, &match_cases };
    for (std.meta.tags(ws.ShapeId)) |id| {
        var seen = false;
        for (all) |cases| for (cases) |c| {
            if (c.shape == id) seen = true;
        };
        if (!seen) {
            std.debug.print("allowlisted shape .{s} has no case in test_sonny_write_allowlist.zig\n", .{@tagName(id)});
            return error.ShapeNotVerified;
        }
    }
    // Every table row names an executor that is in the executor table.
    for (ws.shapes) |shape| _ = ws.declaration(shape.executor);
}

// SONNY-3166: the parser ends a statement only at ';' (or the end, or the
// '}' of a transaction body).
test "SONNY-3166: a statement boundary without ';' is a syntax error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const bad = [_][]const u8{
        // (`MATCH (q:Q) SET q.x = 1 DETACH DELETE q` is one statement since
        // SONNY-3384, merged in the v0.8.23 reconciliation.)
        "CREATE (x1:A), (x2:B) WITH x1, x2 SET x1.status = 'a' CREATE (x1)-[:DEPENDS_ON]->(x2)",
        "MATCH (n) RETURN n MATCH (m) RETURN m",
        "START TRANSACTION { MATCH (n) SET n.x = 1 MATCH (m) SET m.y = 2 }",
        "MATCH (n) SET n.x = 1 COMMIT",
    };
    for (bad) |src| {
        if (geode.parseGql(src, aa)) |parsed| {
            var p = parsed;
            p.deinit();
            std.debug.print("expected a syntax error for {s}\n", .{src});
            return error.BoundaryAccepted;
        } else |err| try testing.expectEqual(error.UnexpectedToken, err);
    }
    const good = [_]struct { src: []const u8, n: usize }{
        .{ .src = "MATCH (n) SET n.x = 1; MATCH (m) SET m.y = 2", .n = 2 },
        .{ .src = "MATCH (n) SET n.x = 1;", .n = 1 },
        .{ .src = "START TRANSACTION; MATCH (n) SET n.x = 1; COMMIT", .n = 3 },
        .{ .src = "START TRANSACTION { MATCH (n) SET n.x = 1; MATCH (m) SET m.y = 2 }", .n = 1 },
        .{ .src = "MERGE (a:A {k: 1}) MERGE (b:B {k: 2}) MERGE (a)-[:T]->(b)", .n = 1 },
        .{ .src = "CREATE (a:A) CREATE (b:B)", .n = 1 },
        .{ .src = "MATCH (n) SET n.x = 1 SET n.y = 2", .n = 1 },
    };
    for (good) |g| {
        var parsed = try geode.parseGql(g.src, aa);
        defer parsed.deinit();
        try testing.expectEqual(g.n, parsed.program.statements.len);
    }
}

// SONNY-3190: consecutive SET, REMOVE and CREATE clauses are appended to one
// list (rebuilding it per clause was quadratic: 32,000 SET clauses took 40 s
// and ~62 GB, before authorization), and a part carries at most 1024.
test "SONNY-3190: a 50,000-clause statement is refused quickly, with bounded memory" {
    const kinds = [_]struct { head: []const u8, clause: []const u8 }{
        .{ .head = "MATCH (n:G)", .clause = " SET n.x = 1" },
        .{ .head = "MATCH (n:G)", .clause = " REMOVE n.x" },
        .{ .head = "", .clause = " CREATE (:Z)" },
        .{ .head = "MATCH (n:G) SET n.x = 1 DELETE n", .clause = " CREATE (:Z)" },
        .{ .head = "", .clause = " MERGE (:Z {k: 1})" },
    };
    for (kinds) |k| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try text.appendSlice(testing.allocator, k.head);
        for (0..50_000) |_| try text.appendSlice(testing.allocator, k.clause);
        // The parser's arena, capped: a quadratic parse needs gigabytes.
        var buf = try testing.allocator.alloc(u8, 64 << 20);
        defer testing.allocator.free(buf);
        var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
        const t0 = nowNs();
        if (geode.parseGql(text.items, fba.allocator())) |parsed| {
            var p = parsed;
            p.deinit();
            std.debug.print("expected {s}... x50000 to be refused\n", .{k.clause});
            return error.ClauseCapMissing;
        } else |err| try testing.expectEqual(error.TooManyWriteClauses, err);
        try testing.expect(nowNs() - t0 < 5 * std.time.ns_per_s);
    }
    // 1024 clauses still parse.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "MATCH (n:G)");
    for (0..1024) |_| try text.appendSlice(testing.allocator, " SET n.x = 1");
    var parsed = try geode.parseGql(text.items, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1024), parsed.program.statements[0].Query.set_clauses.len);
}

// Zig 0.16: std.time.Timer is gone; clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// SONNY-3182: the lock and the read-only and cluster gates see a write
// inside an expression, a subquery or a CTE body.
test "SONNY-3182: isMutatingProgram classifies a write inside an expression or a CTE body as a write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const traits = geode.query_traits;
    const writes = [_][]const u8{
        "MATCH (n:G) WHERE n.i IN (MATCH (q:Q) SET q.c = 1 RETURN q.i) RETURN count(*) AS c",
        "RETURN 1 IN (CREATE (z:Z) RETURN 1) AS b",
        "MATCH (n:G) RETURN n.i NOT IN (MATCH (q:Q) DELETE q RETURN 0) AS b",
        "WITH w AS (MATCH (q:Q) SET q.x = 1 RETURN q.i AS i) MATCH (n:G) RETURN count(*) AS c",
        "MATCH (n:G {i: 1 IN (MATCH (q:Q) SET q.x = 1 RETURN 1)}) RETURN n",
        "FOR v IN [1 IN (MATCH (q:Q) SET q.x = 1 RETURN 1)] RETURN v",
        "VALUES (5) AS (k) MATCH (n:G) WITH n, k WHERE n.i = k SET n.x = 1",
    };
    for (writes) |src| {
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        if (!traits.isMutatingProgram(&parsed.program)) {
            std.debug.print("expected {s} to classify as mutating\n", .{src});
            return error.WriteClassifiedAsRead;
        }
    }
    const reads = [_][]const u8{
        "MATCH (n:G) WHERE n.i IN (MATCH (q:Q) RETURN q.i) RETURN count(*) AS c",
        "WITH w AS (MATCH (q:Q) RETURN q.i AS i) MATCH (n:G) RETURN count(*) AS c",
        "MATCH (n:G) RETURN n.i",
    };
    for (reads) |src| {
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        try testing.expect(!traits.isMutatingProgram(&parsed.program));
    }
}

// SONNY-3166: the write fast paths judge their shape by a compile-time walk
// over the AST's fields, and serve only an allowlisted statement.
test "allowlist: the fast-path shape gate refuses any field it does not name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const ws = geode.execution.write_shape;
    const Probe = struct { src: []const u8, ok: bool };
    const probes = [_]Probe{
        .{ .src = "MATCH (a:G {i: 1}), (b:G {i: 2}) CREATE (a)-[:T]->(b)", .ok = true },
        .{ .src = "MATCH (a:G {i: 1}), (b:G {i: 2}) WHERE a.t = 1 CREATE (a)-[:T]->(b)", .ok = false },
        .{ .src = "MATCH (a:G {i: 1}), (b:G {i: 2}) CREATE (a)-[:T]->(b) RETURN a", .ok = false },
        .{ .src = "WITH 1 AS one SELECT 2 AS two MATCH (a:G {i: 1}), (b:G {i: 2}) CREATE (a)-[:T]->(b)", .ok = false },
    };
    for (probes) |p| {
        var parsed = try geode.parseGql(p.src, aa);
        defer parsed.deinit();
        // SONNY-6383: the parser records every MATCH clause in
        // `match_clauses`, so the gate names it, as the bulk edge detectors
        // do (`bulk_ingest.matchEdgeSpec`), beside `plainMatchClauses`.
        const q = parsed.program.statements[0].Query;
        try testing.expectEqual(p.ok, ws.onlyFields(q, &.{ "match", "match_clauses", "create_pattern" }) and ws.plainMatchClauses(q));
        // A gate that does not name `match_clauses` serves no parsed MATCH.
        try testing.expect(!ws.onlyFields(q, &.{ "match", "create_pattern" }));
    }
    // The bulk detectors serve only what the validator accepts.
    var sel = try geode.parseGql("WITH 1 AS one SELECT 2 AS two MATCH (a:G {i: 1}), (b:G {i: 2}) CREATE (a)-[:T]->(b)", aa);
    defer sel.deinit();
    try testing.expect(geode.bulk_ingest.matchEdgeSpec(&sel.program) == null);
    var plain = try geode.parseGql("MATCH (a:G {i: 1}), (b:G {i: 2}) CREATE (a)-[:T]->(b)", aa);
    defer plain.deinit();
    try testing.expect(geode.bulk_ingest.matchEdgeSpec(&plain.program) != null);
    var merge = try geode.parseGql("MERGE (m:M {g: 'a'}) ON CREATE SET m.k = 1", aa);
    defer merge.deinit();
    try testing.expect(geode.bulk_ingest.matchSimpleNodeMergeSpec(&merge.program) != null);
}
