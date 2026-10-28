// Task W fix round 4a (SONNY-738): the round-3 re-review's Critical and
// blocking findings, in the four sessions the server runs (in-memory, plain
// persisted, tenant-scoped, RLS-policy), statements run as the server runs a
// request (the whole program through `executeProgramWithContext`).
//
// - C1 (SONNY-3139, 3182, 3184): the planned runtime declines a query that
//   writes, and the program a PROFILE carries is validated before it runs
//   (`execution.validateProgramShapes`; the QUIC and gRPC arms are in
//   test_sonny_write_allowlist_r4_transport.zig).
// - C2 (SONNY-3182): a write one level down (a nested query's initial WITH
//   or its WHERE, a CTE body, an IN subquery of an IN subquery) is refused
//   and classified as a write: ONE iterative walk (`write_walk.zig`).
// - C3 (SONNY-3240): MERGE actions, a trailing SET and later CREATE / MERGE /
//   INSERT chains read the statement's own variables; go/oidc's ClaimJTI and
//   TOTP statements; the validator's scope is what the executors bind.
// - I2 (SONNY-3242): every value of one SET clause is evaluated before its
//   assignments, with or without a RETURN.
// - I8 (SONNY-3244): the parser's limits (statements, memory, query nesting).
// - I11 (SONNY-3247): an unsupplied parameter is refused (42P02), nothing
//   written.
//
// CANARY: REQ=REQ-SONNY-3240-WRITE-SCOPE; FEATURE="WriteScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const execution = h.execution;
const Value = h.Value;
const Check = h.Check;

// ---------------------------------------------------------------------------
// Running a case (as tests/test_sonny_write_allowlist.zig does).

const Param = struct { name: []const u8, expr: []const u8 };

const Case = struct {
    setup: []const []const u8 = &.{},
    write: []const u8,
    times: usize = 1,
    params: []const Param = &.{},
    want_first: ?[]const []const u8 = null,
    want: ?[]const []const u8 = null,
    refused: ?anyerror = null,
    checks: []const Check = &.{},
};

const stmt_alloc = std.heap.page_allocator;

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

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

fn openSession(mode: h.Mode) !h.Session {
    var s = try h.Session.init(mode);
    errdefer s.deinit();
    _ = geode.txn_undo_log.getGlobalUndoLog(stmt_alloc);
    try s.seed();
    return s;
}

/// The seed, untouched.
const unchanged = [_]Check{
    .{ .query = "MATCH (n:G) WHERE n.t = 1 AND n.x IS NULL AND n.y IS NULL AND n.z IS NULL AND n.c IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (n) WHERE n.x IS NOT NULL OR n.y IS NOT NULL OR n.c IS NOT NULL OR n.k IS NOT NULL OR n.hit IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (q:Q) WHERE q.x IS NULL RETURN q.i, q.name", .want = &.{ "0|q-0", "1|q-1", "2|q-2", "3|q-3" } },
    .{ .query = "MATCH ()-[r]->() RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (n) RETURN count(*) AS c", .want = &.{"24"} },
};

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
    const checks = if (c.refused != null and c.setup.len == 0) &unchanged else c.checks;
    for (checks) |chk| try h.expectRows(&s, f, "effect", c.write, chk.query, chk.want);
    try h.checkOthersUntouched(&s, f, c.write, "others");
    if (mode != .in_memory) {
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
// C3 (SONNY-3240): a statement reads its own variables.

/// go/oidc's statements (origin/main 2466e86f), with the values its driver
/// substitutes for `?` (it writes them into the text as literals).
const claim_jti = "MERGE (j:JTIClaim {tenant_id: 't1', jti: 'j1'}) ON CREATE SET j.expires_at = '2099-01-01T00:00:00.000000000Z', j.first_use = true ON MATCH SET j.first_use = CASE WHEN j.expires_at > '2026-09-28T00:00:00.000000000Z' THEN false ELSE true END, j.expires_at = '2099-01-01T00:00:00.000000000Z' RETURN j.first_use";
const totp_enroll = "MERGE (t:TOTPEnrollment {tenant_id: 't1', user_id: 'u1', recovery_generation: 0}) ON CREATE SET t.totp_secret_enc = 'enc-1', t.verified = false, t.created_at = 'c1', t.verified_at = '' ON MATCH SET t.totp_secret_enc = CASE WHEN t.verified = true THEN t.totp_secret_enc ELSE 'enc-2' END, t.created_at = CASE WHEN t.verified = true THEN t.created_at ELSE 'c2' END, t.verified_at = CASE WHEN t.verified = true THEN t.verified_at ELSE '' END RETURN t.verified";
const totp_mark_verified = "MATCH (t:TOTPEnrollment {tenant_id: 't1', user_id: 'u1', recovery_generation: 0, totp_secret_enc: 'enc-1'}) SET t.verified = true, t.verified_at = 'v1' RETURN t.user_id";

const c3_cases = [_]Case{
    // The review's repros.
    .{ .write = "MERGE (z:Z {k: 1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n + 1 RETURN z.n AS n", .times = 3, .want_first = &.{"0"}, .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k, z.n", .want = &.{"1|2"} },
    } },
    .{ .write = "MERGE (z:Z2 {k: 1}) SET z.n = coalesce(z.n, -1) + 1 RETURN z.n AS n", .times = 3, .want_first = &.{"0"}, .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z2) RETURN z.n", .want = &.{"2"} },
    } },
    .{ .write = "MERGE (z:Z2 {k: 1}) SET z.n = coalesce(z.n, -1) + 1", .times = 3, .checks = &.{
        .{ .query = "MATCH (z:Z2) RETURN z.n", .want = &.{"2"} },
    } },
    .{ .write = "CREATE (a:Z {k: 1}), (b:Z {k: a.k + 1})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "1", "2" } },
    } },
    .{ .write = "CREATE (a:Z {k: 1}), (b:Z {k: a.k + 1}) RETURN b.k AS k", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "1", "2" } },
    } },
    .{ .write = "INSERT (a:Z {k: 1}), (b:Z {k: a.k + 1})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "1", "2" } },
    } },
    .{ .write = "MERGE (a:A {k: 1}) MERGE (b:B {k: a.k + 1})", .times = 2, .checks = &.{
        .{ .query = "MATCH (b:B) RETURN b.k", .want = &.{"2"} },
        .{ .query = "MATCH (a:A) RETURN a.k", .want = &.{"1"} },
    } },
    .{ .write = "MERGE (a:A {k: 1}) MERGE (b:Z {k: a.k + 1}) MERGE (a)-[r:T]->(b) ON CREATE SET r.w = a.k + b.k ON MATCH SET r.w = r.w * 10", .times = 2, .checks = &.{
        .{ .query = "MATCH (a:A)-[r:T]->(b:Z) RETURN a.k, r.w, b.k", .want = &.{"1|30|2"} },
    } },
    .{ .write = "MATCH (n:G) MERGE (m:M {g: n.g}) ON CREATE SET m.c = 1 ON MATCH SET m.c = m.c + 1", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.c", .want = &.{ "a|5", "b|5" } },
    } },
    .{ .write = "MATCH (n:G {i: 5}) CREATE (a:Z {k: n.i}), (b:Z {k: a.k + 1})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "5", "6" } },
    } },
    .{ .write = "MERGE (z:Z {k: 1}) ON CREATE SET z.m = z.k + 1 RETURN z.m AS m", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.m", .want = &.{"2"} },
    } },
    // go/oidc ClaimJTI: the first claim, then a replay.
    .{ .write = claim_jti, .times = 2, .want_first = &.{"true"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (j:JTIClaim) RETURN j.jti, j.first_use, j.expires_at", .want = &.{"j1|false|2099-01-01T00:00:00.000000000Z"} },
    } },
    // ... and the re-claim of an expired one.
    .{ .setup = &.{"CREATE (:JTIClaim {tenant_id: 't1', jti: 'j1', expires_at: '2000-01-01T00:00:00.000000000Z', first_use: false})"}, .write = claim_jti, .want = &.{"true"}, .checks = &.{
        .{ .query = "MATCH (j:JTIClaim) RETURN j.first_use, j.expires_at", .want = &.{"true|2099-01-01T00:00:00.000000000Z"} },
    } },
    // go/oidc TOTP: an unverified enrollment is restarted...
    .{ .write = totp_enroll, .times = 2, .want_first = &.{"false"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (t:TOTPEnrollment) RETURN t.totp_secret_enc, t.verified, t.created_at", .want = &.{"enc-2|false|c2"} },
    } },
    // ... a verified secret is never overwritten.
    .{ .setup = &.{ totp_enroll, totp_mark_verified }, .write = totp_enroll, .times = 2, .want = &.{"true"}, .checks = &.{
        .{ .query = "MATCH (t:TOTPEnrollment) RETURN t.totp_secret_enc, t.verified, t.created_at, t.verified_at", .want = &.{"enc-1|true|c1|v1"} },
    } },
    // A variable the pattern binds, in a later chain's endpoint and relationship.
    .{ .write = "CREATE (a:A {k: 1}), (a)-[r:T {w: a.k}]->(b:Z {k: a.k + 5})", .checks = &.{
        .{ .query = "MATCH (a:A)-[r:T]->(b:Z) RETURN a.k, r.w, b.k", .want = &.{"1|1|6"} },
    } },
};

test "C3: MERGE actions, a trailing SET and later CREATE, INSERT and MERGE chains read the statement's own variables, in every session" {
    try runCases("C3", &c3_cases);
}

// CANARY: REQ=REQ-SONNY-3240-WRITE-SCOPE; FEATURE="WriteScope"; ASPECT=ScopeCorrespondence; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
// C3: the validator's scope is exactly what the executors bind. For each
// write form, chain `j` of a three-chain pattern names chain `i`'s variable
// (`v<i>.k`, which holds i + 1): the validator accepts it only when i < j,
// and then the executor stores i + 1 (never null); otherwise it is refused
// with nothing written. The SET after a CREATE, the MERGE actions and the
// RETURN name every variable, and read what it holds.
const Form = struct {
    name: []const u8,
    /// `{c0}`, `{c1}`, `{c2}`: the chains; each `(v<i>:W {k: <i+1>, ref: <ref>})`.
    head: []const u8,
    sep: []const u8 = ", ",
    tail: []const u8 = "",
};

const forms = [_]Form{
    .{ .name = "CREATE", .head = "CREATE " },
    .{ .name = "INSERT", .head = "INSERT " },
    .{ .name = "MERGE", .head = "MERGE ", .sep = " MERGE " },
    .{ .name = "MATCH ... CREATE", .head = "MATCH (n:G {i: 5}) CREATE " },
    .{ .name = "WITH ... CREATE", .head = "WITH 5 AS five CREATE " },
};

fn formStatement(aa: std.mem.Allocator, form: Form, j: usize, i: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(aa, form.head);
    for (0..3) |c| {
        if (c > 0) try text.appendSlice(aa, form.sep);
        if (c == j) {
            try text.print(aa, "(v{d}:W {{k: {d}, ref: v{d}.k}})", .{ c, c + 1, i });
        } else {
            try text.print(aa, "(v{d}:W {{k: {d}}})", .{ c, c + 1 });
        }
    }
    try text.appendSlice(aa, form.tail);
    return text.toOwnedSlice(aa);
}

test "C3: the validator's write scope is what the executors bind, for every write form, in every session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    var f: h.Failures = .{ .arena = ta };
    for (h.all_modes) |mode| {
        for (forms) |form| {
            for (0..3) |j| {
                for (0..3) |i| {
                    var s = try openSession(mode);
                    defer s.deinit();
                    const aa = s.arena.allocator();
                    const stmt = try formStatement(aa, form, j, i);
                    var parsed = try geode.parseGql(stmt, aa);
                    const accepted = if (geode.execution.write_shape.validateProgram(&parsed.program, false)) |_| true else |_| false;
                    parsed.deinit();
                    const want_accepted = i < j;
                    if (accepted != want_accepted) {
                        try f.add("[{s}] {s}: the validator {s} it (chain {d} names chain {d}'s variable)", .{ @tagName(mode), stmt, if (accepted) "accepted" else "refused", j, i });
                        continue;
                    }
                    if (runProgram(&s, stmt_alloc, stmt)) |r| {
                        var result = r;
                        result.deinit(stmt_alloc);
                        if (!accepted) try f.add("[{s}] {s}: refused by the validator, but ran", .{ @tagName(mode), stmt });
                    } else |err| if (accepted) try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), stmt, @errorName(err) });
                    const want: []const []const u8 = if (accepted) &.{try std.fmt.allocPrint(ta, "{d}", .{i + 1})} else &.{};
                    try h.expectRows(&s, &f, "the reference", stmt, "MATCH (w:W) WHERE w.ref IS NOT NULL RETURN w.ref", want);
                    try h.expectRows(&s, &f, "nothing null", stmt, "MATCH (w:W) WHERE w.k IS NULL RETURN count(*) AS c", &.{"0"});
                }
            }
        }
        // Every variable in the SET after a CREATE, the MERGE actions and
        // the RETURN.
        const all_scope = [_]struct { stmt: []const u8, want: []const u8 }{
            .{ .stmt = "CREATE (v0:W {k: 1}), (v1:W {k: 2}) SET v0.ref = v1.k + v0.k RETURN v0.ref AS r", .want = "3" },
            .{ .stmt = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON CREATE SET v0.ref = v1.k + v0.k RETURN v0.ref AS r", .want = "3" },
            .{ .stmt = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) SET v1.ref = v0.k * 10 + v1.k RETURN v1.ref AS r", .want = "12" },
            .{ .stmt = "MATCH (n:G {i: 5}) MERGE (v0:W {k: n.i}) ON CREATE SET v0.ref = v0.k + n.i RETURN v0.ref AS r", .want = "10" },
        };
        for (all_scope) |c| {
            var s = try openSession(mode);
            defer s.deinit();
            try h.expectRows(&s, &f, "returns", c.stmt, c.stmt, &.{c.want});
            try h.expectRows(&s, &f, "stored", c.stmt, "MATCH (w:W) WHERE w.ref IS NOT NULL RETURN w.ref", &.{c.want});
        }
    }
    try f.finish("C3 scope correspondence");
}

// ---------------------------------------------------------------------------
// I2 (SONNY-3242): SET semantics, with and without a RETURN.

const set_setup = [_][]const u8{"MATCH (q:Q {i: 1}) SET q.a = 5, q.b = 7"};

fn qab(comptime want: []const u8) []const Check {
    return &.{.{ .query = "MATCH (q:Q {i: 1}) RETURN q.a, q.b", .want = &.{want} }};
}

const i2_cases = [_]Case{
    // One clause: every value against the row before it.
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = 1, q.b = q.a", .checks = qab("1|5") },
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = 1, q.b = q.a RETURN q.a AS a, q.b AS b", .want = &.{"1|5"}, .checks = qab("1|5") },
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = q.b, q.b = q.a", .checks = qab("7|5") },
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = q.b, q.b = q.a RETURN q.a AS a, q.b AS b", .want = &.{"7|5"}, .checks = qab("7|5") },
    // Two clauses: the second reads what the first wrote.
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = 1 SET q.b = q.a", .checks = qab("1|1") },
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = 1 SET q.b = q.a RETURN q.a AS a, q.b AS b", .want = &.{"1|1"}, .checks = qab("1|1") },
    // Over a relationship, a hop and a WITH.
    .{ .setup = &.{"MATCH (:G {i: 5})-[r:R]->(:X) SET r.a = 5, r.b = 7"}, .write = "MATCH (:G {i: 5})-[r:R]->(:X) SET r.a = r.b, r.b = r.a", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.a IS NOT NULL RETURN r.a, r.b", .want = &.{"7|5"} },
    } },
    .{ .setup = &.{"MATCH (:G {i: 5})-[r:R]->(:X) SET r.a = 5, r.b = 7"}, .write = "MATCH (:G {i: 5})-[r:R]->(:X) SET r.a = r.b, r.b = r.a RETURN r.a AS a, r.b AS b", .want = &.{"7|5"}, .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.a IS NOT NULL RETURN r.a, r.b", .want = &.{"7|5"} },
    } },
    .{ .setup = &.{"MATCH (n:G {i: 5})-[:R]->(x:X) SET n.a = 5, x.b = 7"}, .write = "MATCH (n:G {i: 5})-[:R]->(x:X) SET n.a = x.b, x.b = n.a", .checks = &.{
        .{ .query = "MATCH (n:G {i: 5})-[:R]->(x:X) RETURN n.a, x.b", .want = &.{"7|5"} },
    } },
    .{ .setup = &set_setup, .write = "MATCH (q:Q) WITH q WHERE q.i = 1 SET q.a = q.b, q.b = q.a", .checks = qab("7|5") },
    .{ .setup = &set_setup, .write = "MATCH (q:Q), (n:G {i: 5}) WHERE q.i = 1 SET q.a = q.b, q.b = q.a", .checks = qab("7|5") },
    // A MERGE's ON MATCH SET, and a CREATE's SET.
    .{ .write = "MERGE (m:M {g: 's'}) ON CREATE SET m.a = 1, m.b = 2 ON MATCH SET m.a = m.b, m.b = m.a RETURN m.a AS a, m.b AS b", .times = 2, .want_first = &.{"1|2"}, .want = &.{"2|1"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.a, m.b", .want = &.{"2|1"} },
    } },
    .{ .write = "MERGE (m:M {g: 's'}) ON CREATE SET m.a = 1 SET m.b = m.a", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.a, m.b", .want = &.{"1|1"} },
    } },
    .{ .write = "CREATE (z:Z {a: 1, b: 2}) SET z.a = z.b, z.b = z.a", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.a, z.b", .want = &.{"2|1"} },
    } },
    .{ .write = "CREATE (z:Z {a: 1, b: 2}) SET z.a = z.b, z.b = z.a RETURN z.a AS a, z.b AS b", .want = &.{"2|1"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.a, z.b", .want = &.{"2|1"} },
    } },
    // go/oidc: a RETURN after SET still shows the values written.
    .{ .setup = &set_setup, .write = "MATCH (q:Q {i: 1}) SET q.a = q.a + 1 RETURN q.a AS a", .want = &.{"6"}, .checks = qab("6|7") },
};

test "I2: every value of a SET clause is evaluated before its assignments, with or without a RETURN, in every session" {
    try runCases("I2", &i2_cases);
}

// ---------------------------------------------------------------------------
// I11 (SONNY-3247): an unsupplied parameter.

const missing = error.MissingParameter;

const i11_cases = [_]Case{
    .{ .write = "MATCH (q:Q {i: 1}) SET q.name = $nosuch", .refused = missing },
    .{ .write = "MATCH (q:Q) WHERE q.i = $nosuch SET q.x = 1", .refused = missing },
    .{ .write = "MATCH (q:Q) SET q.x = 1 RETURN q.i AS i ORDER BY i LIMIT $nosuch", .refused = missing },
    .{ .write = "MATCH (q:Q) SET q.x = 1 RETURN q.i AS i ORDER BY i SKIP $nosuch", .refused = missing },
    .{ .write = "MATCH (q:Q) WITH q ORDER BY q.i LIMIT $nosuch SET q.x = 1", .refused = missing },
    .{ .write = "MATCH (q:Q) RETURN q.i AS i ORDER BY i LIMIT $nosuch", .refused = missing },
    .{ .write = "CREATE (z:Z {k: $nosuch})", .refused = missing },
    .{ .write = "MATCH (n:G {i: 5}) CREATE (n)-[:T]->(:Z {k: $nosuch})", .refused = missing },
    .{ .write = "MERGE (m:M {g: $nosuch})", .refused = missing },
    .{ .write = "MERGE (m:M {g: 'a'}) ON CREATE SET m.k = $nosuch", .refused = missing },
    .{ .write = "MATCH (q:Q) WHERE q.i IN (MATCH (n:G) WHERE n.i = $nosuch RETURN n.i) SET q.x = 1", .refused = missing },
    .{ .write = "MATCH (q:Q) WHERE q.i IN (MATCH (n:G) WHERE n.i = $nosuch RETURN n.i) RETURN q.i", .refused = missing },
    .{ .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = $k SET n.x = 1", .refused = missing },
    .{ .write = "MATCH (q:Q {i: $i}) SET q.x = $v", .params = &.{.{ .name = "i", .expr = "1" }}, .refused = missing },
    .{ .write = "RETURN $2 AS x", .params = &.{.{ .name = "1", .expr = "10" }}, .refused = missing },
    // Supplied, and defined by LET: they run.
    .{ .write = "MATCH (q:Q {i: $i}) SET q.x = $v", .params = &.{ .{ .name = "i", .expr = "1" }, .{ .name = "v", .expr = "3" } }, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.x IS NOT NULL RETURN q.i, q.x", .want = &.{"1|3"} },
    } },
    .{ .write = "LET $w = 2 MATCH (q:Q) WHERE q.i = $w RETURN q.name AS n", .want = &.{"q-2"}, .checks = &.{} },
};

test "I11: an unsupplied parameter is refused with nothing written, in every session" {
    try runCases("I11", &i11_cases);
}

// ---------------------------------------------------------------------------
// C2 (SONNY-3182): a write one level down.

const refused = error.WriteClauseNotApplied;

const c2_writes = [_][]const u8{
    // The review's repro: a write in the initial WITH of an IN subquery.
    "MATCH (n:G) WHERE n.i IN (WITH (1 IN (MATCH (w:Q) SET w.hit = coalesce(w.hit, 0) + 1 RETURN 1)) AS b MATCH (m:G) WITH m RETURN m.i) RETURN count(*) AS c",
    // ... in its initial WHERE.
    "MATCH (n:G) WHERE n.i IN (WITH 1 AS b WHERE 1 IN (MATCH (w:Q) SET w.hit = 1 RETURN 1) MATCH (m:G) RETURN m.i) RETURN count(*) AS c",
    // ... in a CTE body's initial WITH.
    "WITH w AS (WITH (1 IN (MATCH (q:Q) SET q.hit = 1 RETURN 1)) AS b MATCH (m:G) RETURN m.i AS i) MATCH (n:G) RETURN count(*) AS c",
    // ... two levels down, and a hidden CREATE.
    "MATCH (n:G) WHERE n.i IN (MATCH (m:G) WHERE m.i IN (MATCH (w:Q) SET w.hit = 1 RETURN w.i) RETURN m.i) RETURN count(*) AS c",
    "MATCH (n:G) WHERE n.i IN (WITH (1 IN (CREATE (z:Z {k: 1}) RETURN 1)) AS b MATCH (m:G) RETURN m.i) RETURN count(*) AS c",
    // ... behind a write the allowlist accepts.
    "MATCH (n:G {i: 5}) WHERE n.i IN (WITH (1 IN (MATCH (w:Q) SET w.hit = 1 RETURN 1)) AS b MATCH (m:G) RETURN m.i) SET n.x = 1",
    // ... a UNION's part.
    "MATCH (n:G) RETURN n.i AS i UNION MATCH (m:G) WHERE m.i IN (WITH (1 IN (MATCH (w:Q) SET w.hit = 1 RETURN 1)) AS b MATCH (x:G) RETURN x.i) RETURN m.i AS i",
};

test "C2: a write one level down is refused with nothing written and classified as a write, in every session" {
    var cases: [c2_writes.len]Case = undefined;
    for (c2_writes, &cases) |w, *c| c.* = .{ .write = w, .refused = refused };
    try runCases("C2", &cases);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (c2_writes) |src| {
        var parsed = try geode.parseGql(src, arena.allocator());
        defer parsed.deinit();
        if (!geode.query_traits.isMutatingProgram(&parsed.program)) {
            std.debug.print("classified as a read: {s}\n", .{src});
            return error.WriteClassifiedAsRead;
        }
        // As a UNION arm that may be re-run sees it (`set_operations.queryIsReadOnly`).
        for (parsed.program.statements) |*stmt| if (stmt.* == .Query) {
            try testing.expect(geode.execution.write_walk.queryWrites(&stmt.Query, .{ .calls = .any }));
        };
    }
    // Reads stay reads. (A CALL, CALL { } or FOR inside an IN subquery or a
    // CTE body still counts as a write: round-3 review M1, round 4b.)
    const reads = [_][]const u8{
        "MATCH (n:G) WHERE n.i IN (WITH 1 AS b MATCH (m:G) RETURN m.i) RETURN count(*) AS c",
        "WITH w AS (WITH 1 AS b MATCH (m:G) RETURN m.i AS i) MATCH (n:G) RETURN count(*) AS c",
    };
    for (reads) |src| {
        var parsed = try geode.parseGql(src, arena.allocator());
        defer parsed.deinit();
        try testing.expect(!geode.query_traits.isMutatingProgram(&parsed.program));
        try geode.execution.write_shape.validateProgram(&parsed.program, false);
    }
}

test "C2 / I8: the one walk is iterative: an OR chain as long as the parser takes, with a write at the bottom, is walked without recursing" {
    // A Debug frame per level overflowed the thread at about 5,000 terms
    // (exprIsReadOnly); the write-shape validator's own walks recursed too.
    // Since SONNY-3181 (merged from the r12 line) the parser refuses an
    // expression of more than `max_expr_links` (4096) operator links, so the
    // walk is driven with the longest chain it takes: 1,300 terms of three
    // links each (`OR`, `=`, `.i`). 20,000 terms are refused at the parse.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "MATCH (n:G) WHERE n.i = 0");
    for (1..20_000) |i| try text.print(testing.allocator, " OR n.i = {d}", .{i});
    try text.appendSlice(testing.allocator, " SET n.x = 1");
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        if (geode.parseGql(text.items, arena.allocator())) |p| {
            var too_long = p;
            too_long.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    text.clearRetainingCapacity();
    try text.appendSlice(testing.allocator, "MATCH (n:G) WHERE n.i = 0");
    for (1..1_300) |i| try text.print(testing.allocator, " OR n.i = {d}", .{i});
    const read_len = text.items.len;
    try text.appendSlice(testing.allocator, " SET n.x = 1");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try geode.parseGql(text.items, arena.allocator());
    defer parsed.deinit();
    try geode.execution.write_shape.validateProgram(&parsed.program, false);
    try testing.expect(geode.query_traits.isMutatingProgram(&parsed.program));
    // The same, with a write buried at the end of the chain.
    text.shrinkRetainingCapacity(read_len);
    try text.appendSlice(testing.allocator, " OR n.i IN (MATCH (q:Q) SET q.hit = 1 RETURN q.i) RETURN count(*) AS c");
    var hidden = try geode.parseGql(text.items, arena.allocator());
    defer hidden.deinit();
    try testing.expectError(error.WriteClauseNotApplied, geode.execution.write_shape.validateProgram(&hidden.program, false));
    try testing.expect(geode.query_traits.isMutatingProgram(&hidden.program));
    const stmt = &hidden.program.statements[0];
    try testing.expect(geode.execution.write_walk.queryWrites(&stmt.Query, .{ .calls = .any }));
    try testing.expect(geode.execution.write_walk.exprWrites(&stmt.Query.where_clause.?, .{ .calls = .any }));
}

// ---------------------------------------------------------------------------
// C1 (SONNY-3139, 3182, 3184): PROFILE, in the engine.

const profile_repros = [_][]const u8{
    "PROFILE WITH 1 AS one SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 SET n.x = 1",
    "PROFILE MATCH (n:G) WHERE n.i IN (MATCH (q:Q) SET q.c = coalesce(q.c, 0) + 1 RETURN q.i) RETURN count(*) AS c",
    "PROFILE MATCH (n:G) SET n.x = 1, nn.y = 2",
    "PROFILE MATCH (a:G) WHERE a.i = 5 MERGE (a)-[r:T]->(b:B {k: 1}) ON CREATE SET b.x = 1",
    "PROFILE WITH 1 AS one UNWIND [5, 99] AS u OPTIONAL MATCH (n:G) WHERE n.i = u SET n.x = 1",
};

test "C1: the planned runtime declines a query that writes, and a PROFILE'd write outside the allowlist is refused before it runs, in every session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        for (profile_repros) |src| {
            var s = try openSession(mode);
            defer s.deinit();
            const aa = s.arena.allocator();
            var parsed = try geode.parseGql(src, aa);
            defer parsed.deinit();
            // The transports' first step now.
            if (execution.validateProgramShapes(&parsed.program, s.ctx)) |_| {
                try f.add("[{s}] {s}: validated", .{ @tagName(mode), src });
            } else |_| {}
            // The planned runtime, as the transports' arm called it.
            var q = parsed.program.statements[0].Profile.query.Query;
            const prev = execution.pushActiveContext(&s.ctx);
            if (geode.planned_read_runtime.executeProfiledIfSupported(stmt_alloc, &q, s.ctx, &.{}, &.{}, true)) |maybe| {
                if (maybe) |planned| {
                    var owned = planned;
                    owned.deinitMetadata(stmt_alloc);
                    owned.result.deinit(stmt_alloc);
                    try f.add("[{s}] {s}: the planned runtime ran it", .{ @tagName(mode), src });
                }
            } else |err| try f.add("[{s}] {s}: planned runtime error {s}", .{ @tagName(mode), src, @errorName(err) });
            execution.popActiveContext(prev);
            // Through the engine's own PROFILE.
            if (runProgram(&s, stmt_alloc, src)) |r| {
                var result = r;
                result.deinit(stmt_alloc);
                try f.add("[{s}] {s}: ran", .{ @tagName(mode), src });
            } else |_| {}
            try h.expectRows(&s, &f, "nothing written", src, "MATCH (n) WHERE n.x IS NOT NULL OR n.y IS NOT NULL OR n.c IS NOT NULL RETURN count(*) AS c", &.{"0"});
            try h.expectRows(&s, &f, "nothing created", src, "MATCH (n) RETURN count(*) AS c", &.{"24"});
        }
        // An allowlisted PROFILE'd write still runs, once.
        var s = try openSession(mode);
        defer s.deinit();
        if (runProgram(&s, stmt_alloc, "PROFILE MATCH (n:G) WHERE n.i = 5 SET n.x = 1")) |r| {
            var result = r;
            result.deinit(stmt_alloc);
        } else |err| try f.add("[{s}] PROFILE MATCH ... SET: error {s}", .{ @tagName(mode), @errorName(err) });
        try h.expectRows(&s, &f, "written", "PROFILE MATCH ... SET", "MATCH (n:G) WHERE n.x = 1 RETURN n.i", &.{"5"});
    }
    try f.finish("C1 (engine)");
}

// ---------------------------------------------------------------------------
// I8 (SONNY-3244): the parser's limits.

fn repeat(allocator: std.mem.Allocator, head: []const u8, unit: []const u8, n: usize, tail: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, head);
    for (0..n) |_| try text.appendSlice(allocator, unit);
    try text.appendSlice(allocator, tail);
    return text.toOwnedSlice(allocator);
}

/// An allocator that counts the most bytes it held at once.
const Counting = struct {
    child: std.mem.Allocator,
    held: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(self: *Counting, add: usize, sub: usize) void {
        self.held = self.held + add - sub;
        self.peak = @max(self.peak, self.held);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.note(len, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(mem, a, new_len, ra)) return false;
        self.note(new_len, mem.len);
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(mem, a, new_len, ra) orelse return null;
        self.note(new_len, mem.len);
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
        self.note(0, mem.len);
    }
};

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn expectParseCode(src: []const u8, code: []const u8, peak_limit: usize) !void {
    var counting: Counting = .{ .child = std.heap.page_allocator };
    const t0 = nowNs();
    var outcome = try geode.parseGqlOutcome(src, counting.allocator(), .{});
    defer outcome.deinit();
    const elapsed = nowNs() - t0;
    switch (outcome) {
        .Ok => {
            std.debug.print("parsed; expected {s} for {d} bytes\n", .{ code, src.len });
            return error.LimitMissing;
        },
        .Err => |e| {
            if (!std.mem.eql(u8, e.code, code)) std.debug.print("{s}: {s}\n", .{ e.code, e.msg });
            try testing.expectEqualStrings(code, e.code);
        },
    }
    if (counting.peak > peak_limit or elapsed > 10 * std.time.ns_per_s) {
        std.debug.print("peak {d} bytes, {d} ms\n", .{ counting.peak, elapsed / std.time.ns_per_ms });
        return error.Unbounded;
    }
}

test "I8: more than 1024 statements, or more than 64 MiB of parser memory, are refused (54000) quickly, with bounded memory" {
    const ta = testing.allocator;
    // The review's 25,000 `MATCH ... SET ...;` statements (741 MB before).
    const many = try repeat(ta, "", "MATCH (n:G) SET n.x = 1;", 25_000, "");
    defer ta.free(many);
    try expectParseCode(many, "54000", 96 << 20);
    // 1,025 statements, nested in a transaction body too.
    const over = try repeat(ta, "", "RETURN 1;", 1025, "");
    defer ta.free(over);
    try expectParseCode(over, "54000", 96 << 20);
    const body = try repeat(ta, "START TRANSACTION { ", "RETURN 1; ", 1100, "}");
    defer ta.free(body);
    try expectParseCode(body, "54000", 96 << 20);
    // One statement over 64 MiB: a 3,000,000-element list.
    const big = try repeat(ta, "RETURN [", "1,", 3_000_000, "1] AS l");
    defer ta.free(big);
    try expectParseCode(big, "54000", 256 << 20);
    // 1,024 statements parse.
    const ok = try repeat(ta, "", "RETURN 1;", 1024, "");
    defer ta.free(ok);
    var parsed = try geode.parseGql(ok, ta);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1024), parsed.program.statements.len);
}

// The nesting shapes that recurse through parseQuery.
const Nest = struct { name: []const u8, head: []const u8 = "", open: []const u8, core: []const u8, close: []const u8 = "", tail: []const u8 = "" };

const nests = [_]Nest{
    .{ .name = "WITH chain", .open = "WITH 1 AS a ", .core = "RETURN a" },
    .{ .name = "MATCH ... WITH chain", .open = "MATCH (n) WITH n ", .core = "RETURN n" },
    .{ .name = "CALL subquery", .open = "CALL { ", .core = "RETURN 1 AS x", .close = " } RETURN x" },
    .{ .name = "IN subquery", .open = "MATCH (m) WHERE m.i IN (", .core = "RETURN 1", .close = ") RETURN m.i" },
    .{ .name = "FOR body", .head = "WITH 1 AS a ", .open = "FOR x IN [1] MATCH (n) WITH n ", .core = "RETURN 1" },
};

fn nestText(allocator: std.mem.Allocator, n: Nest, depth: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, n.head);
    for (0..depth) |_| try text.appendSlice(allocator, n.open);
    try text.appendSlice(allocator, n.core);
    for (0..depth) |_| try text.appendSlice(allocator, n.close);
    try text.appendSlice(allocator, n.tail);
    return text.toOwnedSlice(allocator);
}

const Outcome = enum { parsed, refused_nesting, refused_other, crashed, failed };

const ParseJob = struct {
    query: []const u8,
    outcome: Outcome = .failed,

    fn run(self: *ParseJob) void {
        var out = geode.parseGqlOutcome(self.query, std.heap.page_allocator, .{}) catch {
            self.outcome = .failed;
            return;
        };
        defer out.deinit();
        self.outcome = switch (out) {
            .Ok => .parsed,
            .Err => |e| if (std.mem.eql(u8, e.code, "54001")) .refused_nesting else .refused_other,
        };
    }
};

fn parseEntry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job: *ParseJob = @ptrCast(@alignCast(arg.?));
    job.run();
    return null;
}

/// Run `job` on a thread whose stack is exactly `stack` bytes: a mapping of
/// its own, with a guard page below. `std.Thread.spawn` asks glibc for a stack
/// of at least that size, and glibc hands back a larger cached one when an
/// earlier thread left it, so a test that ran after others parsed on more
/// stack than it named.
fn runOnExactStack(stack: usize, job: *ParseJob) bool {
    const page = std.heap.page_size_min;
    const raw = std.c.mmap(null, stack + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (raw == std.c.MAP_FAILED) return false;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw));
    if (std.c.mprotect(@ptrCast(base), page, .{}) != 0) return false;
    var attr: std.c.pthread_attr_t = undefined;
    if (std.c.pthread_attr_init(&attr) != .SUCCESS) return false;
    defer _ = std.c.pthread_attr_destroy(&attr);
    if (std.c.pthread_attr_setstack(&attr, @ptrCast(base + page), stack) != .SUCCESS) return false;
    var tid: std.c.pthread_t = undefined;
    if (std.c.pthread_create(&tid, &attr, parseEntry, job) != .SUCCESS) return false;
    _ = std.c.pthread_join(tid, null);
    return true;
}

/// Parse `query` in a child process on a thread with a `stack`-byte stack,
/// so a stack overflow is reported rather than ending the run.
fn parseInChild(query: []const u8, stack: usize) Outcome {
    const pid = std.c.fork();
    if (pid < 0) return .failed;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var job: ParseJob = .{ .query = query };
        if (!runOnExactStack(stack, &job)) std.c._exit(9);
        std.c._exit(@intFromEnum(job.outcome));
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return .failed;
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) return .crashed;
    const code = std.os.linux.W.EXITSTATUS(st);
    if (code > @intFromEnum(Outcome.failed)) return .failed;
    return @enumFromInt(code);
}

test "I8: queries nest at most 10 deep (54001); deeper nesting never crashes an 8 MiB or a 16 MiB thread" {
    const ta = testing.allocator;
    const Parser = geode.gql.parser.Parser;
    try testing.expectEqual(@as(u16, 10), Parser.max_query_nesting);
    var failures: usize = 0;
    for (nests) |n| {
        for ([_]usize{ 8 << 20, 16 << 20 }) |stack| {
            for ([_]usize{ 1, 5, 8, 12, 16, 20, 30, 60, 100, 1000, 10_000 }) |depth| {
                const src = try nestText(ta, n, depth);
                defer ta.free(src);
                const got = parseInChild(src, stack);
                // Up to 8 levels parse in every shape (a FOR body or a WITH
                // chain after a WITH counts the outer query too); from 12 on,
                // every shape is refused as nested too deep, never crashed.
                const ok = if (depth <= 8) got == .parsed else if (depth >= 12) got == .refused_nesting else (got == .parsed or got == .refused_nesting);
                if (!ok) {
                    std.debug.print("{s} x{d} on {d} MiB: {s}\n", .{ n.name, depth, stack >> 20, @tagName(got) });
                    failures += 1;
                }
            }
        }
    }
    // The limit exactly: a WITH chain of 10 parts parses, 11 is refused.
    for ([_]struct { usize, Outcome }{ .{ 10, .parsed }, .{ 11, .refused_nesting } }) |c| {
        const src = try nestText(ta, nests[0], c[0]);
        defer ta.free(src);
        const got = parseInChild(src, 8 << 20);
        if (got != c[1]) {
            std.debug.print("WITH chain x{d}: {s}, expected {s}\n", .{ c[0], @tagName(got), @tagName(c[1]) });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
