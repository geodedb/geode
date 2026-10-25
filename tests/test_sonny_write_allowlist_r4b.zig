// Task W fix round 4b-1 (SONNY-759, epic SONNY-738): the round-4a re-review's
// findings, in the four sessions the server runs (in-memory, plain persisted,
// tenant-scoped, RLS-policy), each statement run as the server runs a request
// (the whole program through `executeProgramWithContext`). The QUIC and gRPC
// arms are in test_sonny_write_allowlist_r4_transport.zig.
//
// - SONNY-3318 (C-1): a comma pattern binds every chain: a node-only chain
//   after a relationship chain was skipped (`MATCH (g)-[:R]->(x), (q:Q {i:
//   2}) SET q.c = 1` wrote nothing), a later chain read only its first hop,
//   ignored its relationship properties and re-bound a variable an earlier
//   chain bound; and the executor never aggregated.
// - SONNY-3319 (I-1): a SET that adds a label and writes a vector in one
//   clause checks the vector against the new label's index.
// - SONNY-3320 (I-2): chained MERGE actions fire on the last MERGE clause's
//   state.
// - SONNY-3322 (I-5): a CREATE's relationship variable is read by id after
//   every chain has inserted its edges.
// - SONNY-3248 (M-1, M-2, M-3): SKIP / LIMIT parameters; one SET clause
//   assigns a property once; a `LET $x` is scoped to its query.
// - SONNY-3244 (I-4): the nesting repros (round 14-16 fixes, merged from the r12 line).
// - Round 4b-1b (the round 4b-1 review): a variable named as two kinds of
//   element is refused (SONNY-3367, C-1); the comma join streams under the
//   read budget (SONNY-3368, I-1); every type of an alternation (I-5); a
//   refused SET writes nothing (I-2); a label SET checks the node's vectors
//   (I-4); LET chains, CALL bodies and window values (I-6, m-2, m-3); a
//   MERGE's RETURN map holds the store's relationship (m-4).
// - Round 4b-1c (the round 4b-1b re-review): `WITH *` and FOR carry each
//   variable's kind (SONNY-3367, I-A); the join's memory is flat and it
//   polls at every step (SONNY-3368, I-B, I-C); a named path walks every
//   type and is bound (SONNY-3318, I-D); a LET shadows a request parameter
//   on every path, windows read it, a CALL body's window applies, and two
//   MERGEs of one node are one SET target (SONNY-3248, I-E, m-a, m-b, m-c);
//   a comma join's FILTER and WITH stage (SONNY-3386).
//
// CANARY: REQ=REQ-SONNY-3318-MULTI-CHAIN-BINDING; FEATURE="MultiChainRelationshipMatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const execution = h.execution;
const Value = h.Value;
const Check = h.Check;

// ---------------------------------------------------------------------------
// Running a case (as test_sonny_write_allowlist_r4.zig does).

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
    for (c.checks) |chk| try h.expectRows(&s, f, "effect", c.write, chk.query, chk.want);
    try h.checkOthersUntouched(&s, f, c.write, "others");
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        for (c.checks) |chk| try h.expectRows(&s, f, "effect after reload", c.write, chk.query, chk.want);
        try h.checkOthersUntouched(&s, f, c.write, "others after reload");
    }
}

fn runCasesIn(title: []const u8, modes: []const h.Mode, cases: []const Case) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (modes) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish(title);
}

fn runCases(title: []const u8, cases: []const Case) !void {
    return runCasesIn(title, &h.all_modes, cases);
}

// ---------------------------------------------------------------------------
// SONNY-3318 (C-1): a comma pattern binds every chain.

/// Every `:Q`'s c, as `i|c` (the seed has none set).
const q_c = "MATCH (q:Q) WHERE q.c IS NOT NULL RETURN q.i, q.c";

const s3318_cases = [_]Case{
    // The review's repros: the read, and the write it fed.
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 2}) RETURN count(q) AS c, count(*) AS n", .want = &.{"10|10"} },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 2}) SET q.c = 1", .checks = &.{
        .{ .query = q_c, .want = &.{"2|1"} },
    } },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 2}) SET q.c = 2 RETURN q.i", .want = &.{ "2", "2", "2", "2", "2", "2", "2", "2", "2", "2" }, .checks = &.{
        .{ .query = q_c, .want = &.{"2|2"} },
    } },
    // Once per row: the ten rows each add one.
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 2}) SET q.c = coalesce(q.c, 0) + 1", .checks = &.{
        .{ .query = q_c, .want = &.{"2|10"} },
    } },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q) WHERE q.i = 1 SET q.c = 4", .checks = &.{
        .{ .query = q_c, .want = &.{"1|4"} },
    } },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 0}) DETACH DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q {i: 0}) SET g.c = 1", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.c = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    // The node-only chain first worked; it still does.
    .{ .write = "MATCH (q:Q {i: 3}), (g:G)-[:R]->(x:X) SET q.c = 3", .checks = &.{
        .{ .query = q_c, .want = &.{"3|3"} },
    } },
    .{ .write = "MATCH (g:G {i: 1})-[:R]->(x:X), (h:G {i: 2}) SET h.c = 5", .checks = &.{
        .{ .query = "MATCH (g:G) WHERE g.c IS NOT NULL RETURN g.i, g.c", .want = &.{"2|5"} },
    } },
    .{ .write = "MATCH (a:G {i: 1})-[:R]->(x:X), (b:G {i: 3})-[:R]->(y:X) SET b.c = 6, y.c = 6", .checks = &.{
        .{ .query = "MATCH (b:G {i: 3})-[:R]->(y:X) RETURN b.c, y.c", .want = &.{"6|6"} },
        .{ .query = "MATCH (n) WHERE n.c IS NOT NULL RETURN count(*) AS c", .want = &.{"2"} },
    } },
    // A later chain's far node bound by an earlier chain is the same node.
    .{ .write = "MATCH (g:G {i: 1})-[:R]->(x:X), (a:G)-[:R]->(x) RETURN a.i", .want = &.{"1"} },
    .{ .write = "MATCH (g:G {i: 1})-[:R]->(x:X), (y)-[r:R]->(x) RETURN count(*) AS n", .want = &.{"1"} },
    .{ .write = "MATCH (g:G {i: 1})-[:R]->(x:X), (g)-[:R]->(y:X) RETURN y.j", .want = &.{"1"} },
    // Every hop of a later chain, and its relationship's properties.
    .{ .write = "MATCH (q:Q {i: 1}), (g:G {i: 2})-[:R]->(x:X)-[:R]->(z) RETURN count(*) AS n", .want = &.{"0"} },
    .{ .write = "MATCH (g:G {i: 1})-[r:R {w: 'w-1'}]->(x:X), (h:G {i: 2})-[s:R {w: 'nope'}]->(y:X) RETURN count(*) AS n", .want = &.{"0"} },
    .{ .write = "MATCH (g:G {i: 1})-[r:R {w: 'w-1'}]->(x:X), (h:G {i: 2})-[s:R {w: 'w-2'}]->(y:X) RETURN s.w", .want = &.{"w-2"} },
    // An aggregate over a comma pattern.
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q) RETURN count(*) AS n, count(DISTINCT q) AS q", .want = &.{"40|4"} },
    .{ .write = "MATCH (g:G)-[:R]->(x:X), (q:Q) WHERE q.i < 2 RETURN q.i, count(*) AS n GROUP BY q.i", .want = &.{ "0|10", "1|10" } },
};

test "SONNY-3318: a comma pattern binds every chain, read and written, in every session" {
    try runCases("SONNY-3318", &s3318_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3319 (I-1): a label and a vector in one SET clause.

const vec_setup = [_][]const u8{
    "CREATE INDEX vidx ON VD (emb) USING HNSW WITH (metric = 'l2')",
    "CREATE (:VD {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})",
    "CREATE (:VO {id: 2})",
};

/// Nothing of the refused write stored: VD holds node 1 only, one vector in
/// the store, and a later SET on VD's vector runs (it crashed: the failed
/// index rebuild's name was logged after it was freed).
const vec_unchanged = [_]Check{
    .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
    .{ .query = "MATCH (n) WHERE n.emb IS NOT NULL RETURN count(*) AS c", .want = &.{"1"} },
    .{ .query = "MATCH (n:VD) WHERE n.id = 1 SET n.emb = vectorf32('[1.0, 1.0, 1.0, 1.0]') RETURN n.id", .want = &.{"1"} },
    .{ .query = "RETURN 1 AS alive", .want = &.{"1"} },
};

const s3319_cases = [_]Case{
    .{ .setup = &vec_setup, .write = "MATCH (n:VO) SET n:VD, n.emb = vectorf32('[9.0, 9.0]')", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "MATCH (n:VO) SET n:VD, n.emb = vectorf32('[9.0, 9.0]') RETURN n.id", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "MATCH (n:VO) SET n.emb = vectorf32('[9.0, 9.0]'), n:VD", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "MATCH (n:VO) SET n:VD SET n.emb = vectorf32('[9.0, 9.0]')", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "MERGE (n:VO {id: 2}) SET n:VD, n.emb = vectorf32('[9.0, 9.0]')", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "MERGE (n:VO {id: 2}) ON MATCH SET n:VD, n.emb = vectorf32('[9.0, 9.0]')", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    .{ .setup = &vec_setup, .write = "CREATE (n:VC {id: 4}) SET n:VD, n.emb = vectorf32('[9.0, 9.0]')", .refused = error.VectorDimensionMismatch, .checks = &vec_unchanged },
    // The right dimension is stored.
    .{ .setup = &vec_setup, .write = "MATCH (n:VO) SET n:VD, n.emb = vectorf32('[2.0, 2.0, 2.0, 2.0]')", .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{ "1", "2" } },
        .{ .query = "MATCH (n:VD) WHERE n.id = 2 SET n.emb = vectorf32('[3.0, 3.0, 3.0, 3.0]') RETURN n.id", .want = &.{"2"} },
    } },
};

/// `text` with `VD` and `vidx` numbered: the index manager and an in-memory
/// session's catalog outlive a session (and a run), so each case gets its
/// own label and index, tagged with this run's clock.
fn numbered(aa: std.mem.Allocator, text: []const u8, n: usize) ![]const u8 {
    const vd = try std.fmt.allocPrint(aa, "VD{d}x{d}", .{ n, runTag() });
    const idx = try std.fmt.allocPrint(aa, "vidx{d}x{d}", .{ n, runTag() });
    return std.mem.replaceOwned(u8, aa, try std.mem.replaceOwned(u8, aa, text, "VD", vd), "vidx", idx);
}

var run_tag: u64 = 0;

fn runTag() u64 {
    if (run_tag == 0) {
        run_tag = @intCast(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toNanoseconds());
    }
    return run_tag;
}

test "SONNY-3319: a vector SET beside a label SET is checked against the new label's index, and a later SET runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var f: h.Failures = .{ .arena = aa };
    var n: usize = 0;
    for ([_]h.Mode{ .in_memory, .persisted }) |mode| {
        for (s3319_cases) |c| {
            n += 1;
            const setup = try aa.alloc([]const u8, c.setup.len);
            for (c.setup, setup) |q, *out| out.* = try numbered(aa, q, n);
            const checks = try aa.alloc(Check, c.checks.len);
            for (c.checks, checks) |chk, *out| out.* = .{ .query = try numbered(aa, chk.query, n), .want = chk.want };
            var nc = c;
            nc.setup = setup;
            nc.checks = checks;
            nc.write = try numbered(aa, c.write, n);
            runCase(mode, nc, &f) catch |err| {
                try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), nc.write, @errorName(err) });
            };
        }
    }
    try f.finish("SONNY-3319");
}

// ---------------------------------------------------------------------------
// SONNY-3320 (I-2): chained MERGE actions belong to the last MERGE clause.

const w_ref = "MATCH (w:W) RETURN w.k, w.ref";
const w_m = "MATCH (w:W) RETURN w.k, w.m";

/// go/oidc's statements (origin/main), as test_sonny_write_allowlist_r4.zig.
const claim_jti = "MERGE (j:JTIClaim {tenant_id: 't1', jti: 'j1'}) ON CREATE SET j.expires_at = '2099-01-01T00:00:00.000000000Z', j.first_use = true ON MATCH SET j.first_use = CASE WHEN j.expires_at > '2026-09-28T00:00:00.000000000Z' THEN false ELSE true END, j.expires_at = '2099-01-01T00:00:00.000000000Z' RETURN j.first_use";
const totp_enroll = "MERGE (t:TOTPEnrollment {tenant_id: 't1', user_id: 'u1', recovery_generation: 0}) ON CREATE SET t.totp_secret_enc = 'enc-1', t.verified = false, t.created_at = 'c1', t.verified_at = '' ON MATCH SET t.totp_secret_enc = CASE WHEN t.verified = true THEN t.totp_secret_enc ELSE 'enc-2' END, t.created_at = CASE WHEN t.verified = true THEN t.created_at ELSE 'c2' END, t.verified_at = CASE WHEN t.verified = true THEN t.verified_at ELSE '' END RETURN t.verified";
const totp_mark_verified = "MATCH (t:TOTPEnrollment {tenant_id: 't1', user_id: 'u1', recovery_generation: 0, totp_secret_enc: 'enc-1'}) SET t.verified = true, t.verified_at = 'v1' RETURN t.user_id";

const s3320_cases = [_]Case{
    // The review's two data states: v0 matched and v1 created, the ON CREATE
    // fires (it was dropped); v0 created and v1 matched, it does not (it
    // wrote).
    .{ .setup = &.{"CREATE (:W {k: 1})"}, .write = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON CREATE SET v0.ref = v1.k + v0.k", .checks = &.{
        .{ .query = w_ref, .want = &.{ "1|3", "2|null" } },
    } },
    .{ .setup = &.{"CREATE (:W {k: 2})"}, .write = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON CREATE SET v0.ref = v1.k + v0.k", .checks = &.{
        .{ .query = w_ref, .want = &.{ "1|null", "2|null" } },
    } },
    // ON MATCH, the same two states.
    .{ .setup = &.{"CREATE (:W {k: 2})"}, .write = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON MATCH SET v0.m = 1", .checks = &.{
        .{ .query = w_m, .want = &.{ "1|1", "2|null" } },
    } },
    .{ .setup = &.{"CREATE (:W {k: 1})"}, .write = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON MATCH SET v0.m = 1", .checks = &.{
        .{ .query = w_m, .want = &.{ "1|null", "2|null" } },
    } },
    // Both, run twice: created, then matched.
    .{ .write = "MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON CREATE SET v1.m = 1 ON MATCH SET v1.m = v1.m + 1 RETURN v1.m", .times = 2, .want_first = &.{"1"}, .want = &.{"2"}, .checks = &.{
        .{ .query = w_m, .want = &.{ "1|null", "2|2" } },
    } },
    // A relationship clause last: its actions follow the relationship.
    .{ .write = "MERGE (a:W {k: 1}) MERGE (b:W {k: 2}) MERGE (a)-[r:T]->(b) ON CREATE SET a.ref = 1 ON MATCH SET a.ref = a.ref + 1", .times = 2, .checks = &.{
        .{ .query = w_ref, .want = &.{ "1|2", "2|null" } },
    } },
    // go/oidc's single-MERGE statements: ClaimJTI's first claim and replay...
    .{ .write = claim_jti, .times = 2, .want_first = &.{"true"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (j:JTIClaim) RETURN j.jti, j.first_use, j.expires_at", .want = &.{"j1|false|2099-01-01T00:00:00.000000000Z"} },
    } },
    // ... an expired one re-claimed...
    .{ .setup = &.{"CREATE (:JTIClaim {tenant_id: 't1', jti: 'j1', expires_at: '2000-01-01T00:00:00.000000000Z', first_use: false})"}, .write = claim_jti, .want = &.{"true"}, .checks = &.{
        .{ .query = "MATCH (j:JTIClaim) RETURN j.first_use, j.expires_at", .want = &.{"true|2099-01-01T00:00:00.000000000Z"} },
    } },
    // ... TOTP: an unverified enrollment restarts, a verified one is kept.
    .{ .write = totp_enroll, .times = 2, .want_first = &.{"false"}, .want = &.{"false"}, .checks = &.{
        .{ .query = "MATCH (t:TOTPEnrollment) RETURN t.totp_secret_enc, t.verified, t.created_at", .want = &.{"enc-2|false|c2"} },
    } },
    .{ .setup = &.{ totp_enroll, totp_mark_verified }, .write = totp_enroll, .times = 2, .want = &.{"true"}, .checks = &.{
        .{ .query = "MATCH (t:TOTPEnrollment) RETURN t.totp_secret_enc, t.verified, t.created_at, t.verified_at", .want = &.{"enc-1|true|c1|v1"} },
    } },
};

test "SONNY-3320: chained MERGE actions fire as the last MERGE clause created or matched, in every session" {
    try runCases("SONNY-3320", &s3320_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3322 (I-5): a relationship variable after many edge inserts. Run in a
// child process, on a 16 MiB thread, so a crash is reported, not the run's end.

const EdgeJob = struct {
    s: *h.Session,
    query: []const u8,
    /// Read after `query` (null: `query`'s own rows are checked).
    then: ?[]const u8 = null,
    want: []const u8,
    ok: bool = false,

    fn run(self: *EdgeJob) void {
        var first = runProgram(self.s, stmt_alloc, self.query) catch |err| {
            std.debug.print("  error {s}\n", .{@errorName(err)});
            return;
        };
        var result = if (self.then) |q| blk: {
            first.deinit(stmt_alloc);
            break :blk runProgram(self.s, stmt_alloc, q) catch |err| {
                std.debug.print("  then: error {s}\n", .{@errorName(err)});
                return;
            };
        } else first;
        defer result.deinit(stmt_alloc);
        const rows = h.renderRows(self.s.arena.allocator(), result) catch return;
        self.ok = rows.len == 1 and std.mem.eql(u8, rows[0], self.want);
        if (!self.ok) std.debug.print("  answered {d} row(s){s}{s}\n", .{ rows.len, if (rows.len > 0) ": " else "", if (rows.len > 0) rows[0] else "" });
    }

    fn entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
        const job: *EdgeJob = @ptrCast(@alignCast(arg.?));
        job.run();
        return null;
    }
};

const ChildOutcome = enum { right, wrong, crashed, failed };

fn runInChild(job: *EdgeJob, stack: usize) ChildOutcome {
    const pid = std.c.fork();
    if (pid < 0) return .failed;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        const page = std.heap.page_size_min;
        const raw = std.c.mmap(null, stack + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (raw == std.c.MAP_FAILED) std.c._exit(9);
        const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw));
        if (std.c.mprotect(@ptrCast(base), page, .{}) != 0) std.c._exit(9);
        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != .SUCCESS) std.c._exit(9);
        if (std.c.pthread_attr_setstack(&attr, @ptrCast(base + page), stack) != .SUCCESS) std.c._exit(9);
        var tid: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&tid, &attr, EdgeJob.entry, job) != .SUCCESS) std.c._exit(9);
        _ = std.c.pthread_join(tid, null);
        std.c._exit(if (job.ok) 0 else 1);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return .failed;
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) return .crashed;
    return switch (std.os.linux.W.EXITSTATUS(st)) {
        0 => .right,
        1 => .wrong,
        else => .failed,
    };
}

/// `<head>` then `chains` more relationship chains, each `<sep>` and
/// `chain` (its `{k}` the chain's number), then `<tail>`.
fn manyChains(aa: std.mem.Allocator, head: []const u8, sep: []const u8, chain: []const u8, chains: usize, tail: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(aa, head);
    for (1..chains + 1) |k| {
        try text.appendSlice(aa, sep);
        const number = try std.fmt.allocPrint(aa, "{d}", .{k});
        try text.appendSlice(aa, try std.mem.replaceOwned(u8, aa, chain, "{k}", number));
    }
    try text.appendSlice(aa, tail);
    return text.toOwnedSlice(aa);
}

test "SONNY-3322: a relationship variable reads its relationship after 150 and 600 more relationship chains" {
    const Form = struct { head: []const u8, sep: []const u8, chain: []const u8, tail: []const u8, then: ?[]const u8 = null, want: []const u8, max: usize = 600 };
    // Anonymous endpoints: the validator scopes at most 64 names.
    const create_chain = "(:V {k: {k}})-[:T {w: {k}}]->(:V {k: {k}})";
    const forms = [_]Form{
        // The review's repro.
        .{ .head = "CREATE (a0:V {k: 0})-[r:T {w: 3}]->(b0:V {k: 0})", .sep = ", ", .chain = create_chain, .tail = " RETURN r.w, type(r) AS t", .want = "3|T" },
        // The SET after the CREATE, and a later chain, read r.
        .{ .head = "CREATE (a0:V {k: 0})-[r:T {w: 3}]->(b0:V {k: 0})", .sep = ", ", .chain = create_chain, .tail = " SET a0.w = r.w RETURN a0.w", .want = "3" },
        .{ .head = "CREATE (a0:V {k: 0})-[r:T {w: 3}]->(b0:V {k: 0})", .sep = ", ", .chain = create_chain, .tail = ", (z:Z {w: r.w}) RETURN z.w", .want = "3" },
        .{ .head = "INSERT (a0:V {k: 0})-[r:T {w: 3}]->(b0:V {k: 0})", .sep = ", ", .chain = create_chain, .tail = ", (z:Z {w: r.w})", .then = "MATCH (z:Z) RETURN z.w", .want = "3" },
        // MERGE: three clauses a chain (at most 1024 clauses a part).
        // MERGE: each later clause merges one more relationship from a0 to a
        // node of its own (at most 1024 clauses a part; a relationship MERGE
        // matches on the endpoints and type, not the properties).
        .{ .head = "MERGE (a0:V {k: 0}) MERGE (b0:V {k: 0}) MERGE (a0)-[r:T {w: 3}]->(b0)", .sep = " ", .chain = "MERGE (a0)-[:T {w: {k}0}]->(:V {k: {k}})", .tail = " ON CREATE SET a0.w = r.w RETURN a0.w, r.w", .want = "3|3" },
    };
    var failures: usize = 0;
    for ([_]h.Mode{ .in_memory, .persisted }) |mode| {
        for ([_]usize{ 150, 600 }) |wanted| {
            for (forms) |form| {
                const chains = @min(wanted, form.max);
                var s = try h.Session.init(mode);
                defer s.deinit();
                _ = geode.txn_undo_log.getGlobalUndoLog(stmt_alloc);
                const query = try manyChains(s.arena.allocator(), form.head, form.sep, form.chain, chains, form.tail);
                var job: EdgeJob = .{ .s = &s, .query = query, .then = form.then, .want = form.want };
                const got = runInChild(&job, 16 << 20);
                if (got != .right) {
                    std.debug.print("[{s}] {s} ... x{d}{s}: {s}\n", .{ @tagName(mode), form.head[0..6], chains, form.tail, @tagName(got) });
                    failures += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// SONNY-3248 (M-1, M-2, M-3).

const s3248_cases = [_]Case{
    // M-1: a SKIP or LIMIT parameter windows a read and a write's RETURN.
    .{ .params = &.{.{ .name = "l", .expr = "2" }}, .write = "MATCH (n:G) WHERE n.i < 3 RETURN n.g LIMIT $l", .want = &.{ "a", "a" } },
    .{ .params = &.{.{ .name = "l", .expr = "2" }}, .write = "MATCH (n:G) RETURN n.i AS i ORDER BY i LIMIT $l", .want = &.{ "0", "1" } },
    .{ .params = &.{.{ .name = "l", .expr = "8" }}, .write = "MATCH (n:G) RETURN n.i AS i ORDER BY i SKIP $l", .want = &.{ "8", "9" } },
    .{ .params = &.{ .{ .name = "s", .expr = "1" }, .{ .name = "l", .expr = "2" } }, .write = "MATCH (n:G) RETURN n.i AS i ORDER BY i SKIP $s LIMIT $l", .want = &.{ "1", "2" } },
    .{
        .params = &.{.{ .name = "l", .expr = "2" }},
        .write = "MATCH (q:Q) SET q.z = 1 RETURN q.i AS i ORDER BY i LIMIT $l",
        .want = &.{ "0", "1" },
        .checks = &.{
            // The SET wrote every row; the LIMIT windows what it returns.
            .{ .query = "MATCH (q:Q) WHERE q.z = 1 RETURN count(*) AS c", .want = &.{"4"} },
        },
    },
    .{ .params = &.{.{ .name = "l", .expr = "2" }}, .write = "MATCH (g:G)-[:R]->(x:X) RETURN x.j AS j ORDER BY j LIMIT $l", .want = &.{ "0", "1" } },
    .{ .write = "MATCH (n:G) RETURN n.i AS i ORDER BY i SKIP 8", .want = &.{ "8", "9" } },
    // ... and one the statement's own LET defines.
    .{ .write = "LET $x = 3 MATCH (n:G) RETURN n.i AS i ORDER BY i LIMIT $x", .want = &.{ "0", "1", "2" } },
    .{ .write = "LET $x = 8 MATCH (n:G) RETURN n.i AS i ORDER BY i SKIP $x", .want = &.{ "8", "9" } },
    // M-2: one SET clause assigns a property of an element once.
    .{ .write = "MATCH (q:Q {i: 1}) SET q.a = 1, q.a = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.a IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (a:Q {i: 1}), (b:Q {i: 1}) SET a.c = 1, b.c = 2 RETURN a.c", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = q_c, .want = &.{} },
    } },
    .{ .write = "MATCH (q:Q) SET q.c = q.i, q.c = 9", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = q_c, .want = &.{} },
    } },
    .{ .write = "MATCH (q:Q {i: 1}) SET q = {c: 1}, q.d = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = q_c, .want = &.{} },
    } },
    .{ .write = "MERGE (z:Z {k: 1}) ON CREATE SET z.a = 1, z.a = 2", .refused = error.RepeatedSetTarget },
    .{ .write = "CREATE (z:Z {k: 1}) SET z.a = 1, z.a = 2", .refused = error.RepeatedSetTarget },
    // Different properties, different elements, or two clauses: allowed.
    .{ .write = "MATCH (a:Q {i: 1}), (b:Q {i: 2}) SET a.c = 1, b.c = 2", .checks = &.{
        .{ .query = q_c, .want = &.{ "1|1", "2|2" } },
    } },
    .{ .write = "MATCH (q:Q {i: 1}) SET q.c = 1 SET q.c = q.c + 1", .checks = &.{
        .{ .query = q_c, .want = &.{"1|2"} },
    } },
    .{ .write = "MATCH (q:Q {i: 1}) SET q:Extra, q.c = 5", .checks = &.{
        .{ .query = q_c, .want = &.{"1|5"} },
    } },
    // M-3: a LET defines its parameter for its own query, not the statement.
    .{ .write = "MATCH (q:Q) WHERE q.i IN (LET $z = 1 MATCH (k:Q) WHERE k.i = $z RETURN k.i) RETURN q.i, $z AS z", .refused = error.MissingParameter },
    .{ .write = "MATCH (q:Q) WHERE q.i IN (LET $z = 1 MATCH (k:Q) WHERE k.i = $z RETURN k.i) SET q.x = $z", .refused = error.MissingParameter, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    } },
    // Round 4b-1b (review I-E): an IN subquery reads an outer LET, as an
    // EXISTS body does. Both are evaluated by the server's evaluator, which
    // this in-process harness does not install: the transport test has them.
    .{ .write = "LET $y = 2 MATCH (q:Q {i: $y}) RETURN q.i", .want = &.{"2"} },
    // SESSION SET VALUE stores a session parameter no statement reads.
    .{ .write = "SESSION SET VALUE $sv = 3; MATCH (q:Q {i: $sv}) RETURN q.i", .refused = error.MissingParameter },
};

test "SONNY-3248: SKIP / LIMIT parameters, one assignment per property in a SET clause, LET scope, in every session" {
    try runCases("SONNY-3248", &s3248_cases);
}

// ---------------------------------------------------------------------------
// Round 4b-1b (the round 4b-1 review). Each case is the review's repro.

// SONNY-3367 (C-1): a variable is one kind of element. `(r)` after `-[r]->`
// bound every node of the graph beside the relationship r.
const every_node = "MATCH (n) RETURN count(*) AS c";

const c1_cases = [_]Case{
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x), (r) SET r.zz = 1", .refused = error.VariableKindConflict, .checks = &.{
        .{ .query = "MATCH (n) WHERE n.zz = 1 RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = "MATCH (g:G)-[e:R]->(x) WHERE e.zz = 1 RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x), (r) DETACH DELETE r", .refused = error.VariableKindConflict, .checks = &.{
        .{ .query = every_node, .want = &.{"24"} },
    } },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x), (r) RETURN r AS rr LIMIT 2", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x), (r) SET r.zz = 1 RETURN r AS rr", .refused = error.VariableKindConflict },
    // A node variable used as a relationship, and the other kinds.
    .{ .write = "MATCH (a:G {i: 1})-[:R]->(x), (y)-[a]->(z) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (a:G {i: 1})-[a]->(x) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (a:G {i: 1})-[r:R*1..1]->(x), (b)-[r]->(c) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH p = (a:G {i: 1})-[:R]->(x), (p) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH r MATCH (r) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH r AS s MATCH (s)-[:R]->(y) RETURN count(*) AS c", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) CREATE (r)-[:T]->(:K)", .refused = error.VariableKindConflict, .checks = &.{
        .{ .query = every_node, .want = &.{"24"} },
    } },
    .{ .write = "CREATE (a:K)-[r:T]->(b:K), (r)", .refused = error.VariableKindConflict, .checks = &.{
        .{ .query = every_node, .want = &.{"24"} },
    } },
    // One relationship variable in two chains is a join, as before.
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x), (y)-[r]->(z) RETURN y.i, z.j", .want = &.{"1|1"} },
};

test "SONNY-3367 (C-1): a variable named as two kinds of element is refused before anything runs, in every session" {
    try runCases("SONNY-3367", &c1_cases);
}

// SONNY-3368 (I-1): the comma join streams. The WHERE on a later chain and
// the window still give the right rows...
const i1_cases = [_]Case{
    .{ .write = "MATCH (a:G)-[:R]->(b), (c:G)-[:R]->(d) WHERE c.i = 9 AND a.i = 3 RETURN a.i, c.i LIMIT 1", .want = &.{"3|9"} },
    .{ .write = "MATCH (a:G)-[:R]->(b), (c:G)-[:R]->(d) WHERE c.i = a.i RETURN count(*) AS n", .want = &.{"10"} },
    .{ .write = "MATCH (a:G)-[:R]->(b), (c:G)-[:R]->(d) RETURN a.i LIMIT 3", .want = &.{ "0", "0", "0" } },
    .{ .write = "MATCH (a:G)-[:R]->(b), (c:G)-[:R]->(d) RETURN count(*) AS n", .want = &.{"100"} },
    .{ .write = "MATCH (a:G)-[:R]->(b), (c:G)-[:R]->(d) RETURN a.i AS i, c.i AS j ORDER BY i, j SKIP 98 LIMIT 5", .want = &.{ "9|8", "9|9" } },
    .{ .write = "MATCH (a:G {i: 2})-[:R]->(b), (q:Q) WHERE q.i > 1 SET q.c = a.i RETURN q.i", .want = &.{ "2", "3" }, .checks = &.{
        .{ .query = q_c, .want = &.{ "2|2", "3|2" } },
    } },
};

test "SONNY-3368 (I-1): a comma join with a WHERE, a window and a write answers as before, in every session" {
    try runCases("SONNY-3368", &i1_cases);
}

/// ... and holds what it keeps, not the product. Run in a child whose data
/// segment may grow by 2 GiB at most, so a regression fails the case instead
/// of the machine.
const CartJob = struct {
    s: *h.Session,
    ok: bool = false,

    fn check(self: *CartJob, query: []const u8, want: ?[]const []const u8, want_err: ?anyerror, max_ms: i64) bool {
        const start = monoMillis();
        var result = runProgram(self.s, stmt_alloc, query) catch |err| {
            if (want_err) |w| if (err == w) return true;
            std.debug.print("  {s}: error {s}\n", .{ query, @errorName(err) });
            return false;
        };
        defer result.deinit(stmt_alloc);
        const took = monoMillis() - start;
        if (want_err) |w| {
            std.debug.print("  {s}: answered {d} row(s); expected {s}\n", .{ query, result.rows.len, @errorName(w) });
            return false;
        }
        const rows = h.renderRows(self.s.arena.allocator(), result) catch return false;
        const w = want.?;
        var same = rows.len == w.len;
        if (same) for (rows, w) |g, e| {
            if (!std.mem.eql(u8, g, e)) same = false;
        };
        if (!same) std.debug.print("  {s}: answered {d} row(s){s}{s}\n", .{ query, rows.len, if (rows.len > 0) ", first " else "", if (rows.len > 0) rows[0] else "" });
        if (took > max_ms) std.debug.print("  {s}: took {d} ms (at most {d})\n", .{ query, took, max_ms });
        return same and took <= max_ms;
    }

    fn run(self: *CartJob) void {
        const cart = "MATCH (a:P)-[:E]->(b), (c:P)-[:E]->(d)";
        var ok = true;
        // `range(1, 1500)`'s pairs, as the store counts them.
        var counted = runProgram(self.s, stmt_alloc, "MATCH (p:P) RETURN count(*) AS n") catch return;
        const pairs = (h.renderRows(self.s.arena.allocator(), counted) catch return)[0];
        counted.deinit(stmt_alloc);
        // A 64 MiB read budget: the product (2.25 million bindings) is far
        // past it, what LIMIT 1 and the WHERE keep is far inside.
        geode.read_budget.setBudgetBytesForTest(64 << 20);
        defer geode.read_budget.setBudgetBytesForTest(0);
        ok = self.check(cart ++ " RETURN 1 AS one LIMIT 1", &.{"1"}, null, 10_000) and ok;
        // The WHERE is applied to each binding as the join completes it (2.25
        // million evaluated, 1,500 kept).
        ok = self.check(cart ++ " WHERE c.i = a.i RETURN count(*) AS n", &.{pairs}, null, 300_000) and ok;
        // The whole product is past the budget: 53200, not an OOM.
        ok = self.check(cart ++ " RETURN a.i, c.i", null, error.ReadQueryBudgetExceeded, 120_000) and ok;
        self.ok = ok;
    }
};

fn monoMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// The data segment the process holds now, in bytes (VmData).
fn dataSegmentBytes() usize {
    var buf: [8192]u8 = undefined;
    const fd = std.c.open("/proc/self/status", .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmData:")) continue;
        var parts = std.mem.tokenizeAny(u8, line[7..], " \tkB");
        const kb = std.fmt.parseInt(usize, parts.next() orelse return 0, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

test "SONNY-3368 (I-1): LIMIT 1 over two 1,500-pair chains is bounded, a WHERE streams, and the whole product answers the read budget's error" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    var setup = try runProgram(&s, stmt_alloc, "FOR i IN range(1, 1500) CREATE (:P {i: i})-[:E]->(:P2 {i: i})");
    setup.deinit(stmt_alloc);
    var job: CartJob = .{ .s = &s };
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var memory: ChildMemoryGuard = .{};
        memory.start(2 << 30) catch std.c._exit(9);
        job.run();
        memory.stop();
        std.c._exit(if (job.ok) 0 else 1);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) {
        std.debug.print("the join crashed (signal {d})\n", .{std.os.linux.W.TERMSIG(st)});
        return error.Crashed;
    }
    try testing.expectEqual(@as(u32, 0), std.os.linux.W.EXITSTATUS(st));
}

// SONNY-3318 (I-5): every type of `[:A|B]`, on the first hop too.
const s_edge = "MATCH (x:X {j: 1}) CREATE (x)-[:S]->(:Q {i: 5})";

const i5_cases = [_]Case{
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:S|R]->(b), (q:Q {i: 0}) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (q:Q {i: 0}), (a)-[:S|R]->(b) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a:X)-[:S|R]->(b), (q:Q {i: 0}) RETURN count(*) AS n", .want = &.{"1"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:S|R]->(b:Q), (q:Q {i: 0}) RETURN b.i", .want = &.{"5"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:R|R]->(b), (q:Q {i: 0}) RETURN count(*) AS n", .want = &.{"10"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:S|R]->(b)-[:S]->(c) RETURN a.i, c.i", .want = &.{"1|5"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a:G)-[:S|R]->(b)-[:S|R]->(c) RETURN count(*) AS n", .want = &.{"1"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a:G {i: 1})-[:S|R*1..2]->(c), (q:Q {i: 0}) RETURN count(*) AS n", .want = &.{"2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:S|R]->(b) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (g:G {i: 1})-[:S|R]->(x) OPTIONAL MATCH (x)-[:S|R]->(q) RETURN q.i", .want = &.{"5"} },
    // The review's silent write loss: the S target is written too.
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:R|S]->(b), (q:Q {i: 0}) SET b.tt = 1", .checks = &.{
        .{ .query = "MATCH (b) WHERE b.tt = 1 RETURN count(*) AS c", .want = &.{"11"} },
        .{ .query = "MATCH (b:Q) WHERE b.tt = 1 RETURN b.i", .want = &.{"5"} },
    } },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:R|S]->(b) SET b.tt = 2", .checks = &.{
        .{ .query = "MATCH (b) WHERE b.tt = 2 RETURN count(*) AS c", .want = &.{"11"} },
    } },
};

test "SONNY-3318 (I-5): the first hop of a comma or multi-hop pattern walks every type of an alternation, in every session" {
    try runCases("SONNY-3318 (I-5)", &i5_cases);
}

// SONNY-3248 (I-2): a refused SET writes nothing.
const w_count = "MATCH (w:W) RETURN count(*) AS c";

const i2_cases = [_]Case{
    // Refused before the CREATE or MERGE inserts anything.
    .{ .write = "CREATE (z:Z {k: 1}) SET z.a = 1, z.a = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (q:Q {i: 1}) CREATE (z:Z2) SET z.a = 1, z.a = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = "MATCH (z:Z2) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MERGE (a:W {k: 1}) ON CREATE SET a.x = 1, a.x = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = w_count, .want = &.{"0"} },
    } },
    .{ .write = "MERGE (a:W {k: 1}) SET a.x = 1, a.x = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = w_count, .want = &.{"0"} },
    } },
    .{ .write = "MERGE (a:W {k: 1}) ON CREATE SET a.x = 1, a.x = 2 RETURN a.x", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = w_count, .want = &.{"0"} },
    } },
    // Two SET clauses, or different properties: accepted.
    .{ .write = "MERGE (a:W {k: 1}) ON CREATE SET a.x = 1 SET a.x = a.x + 1 RETURN a.x", .want = &.{"2"} },
    .{ .write = "CREATE (z:Z {k: 1}) SET z.a = 1, z.b = 2 RETURN z.a, z.b", .want = &.{"1|2"} },
};

test "SONNY-3248 (I-2): a SET clause that assigns a property twice is refused before a CREATE or MERGE writes anything, in every session" {
    try runCases("SONNY-3248 (I-2)", &i2_cases);
}

// SONNY-3248 (I-6, m-2, m-3): window values; LET chains and CALL { } bodies.
const r4b1b_3248_cases = [_]Case{
    // m-2: a SKIP or LIMIT value that is no non-negative integer.
    .{ .params = &.{.{ .name = "l", .expr = "-1" }}, .write = "MATCH (n:G) RETURN n.i LIMIT $l", .refused = error.InvalidWindowParameter },
    .{ .params = &.{.{ .name = "l", .expr = "2.0" }}, .write = "MATCH (n:G) RETURN n.i LIMIT $l", .refused = error.InvalidWindowParameter },
    .{ .params = &.{.{ .name = "l", .expr = "'2'" }}, .write = "MATCH (n:G) RETURN n.i LIMIT $l", .refused = error.InvalidWindowParameter },
    .{ .params = &.{.{ .name = "s", .expr = "-3" }}, .write = "MATCH (n:G) RETURN n.i SKIP $s", .refused = error.InvalidWindowParameter },
    .{ .params = &.{.{ .name = "l", .expr = "-1" }}, .write = "MATCH (q:Q) SET q.c = 1 RETURN q.i LIMIT $l", .refused = error.InvalidWindowParameter, .checks = &.{
        .{ .query = q_c, .want = &.{} },
    } },
    .{ .write = "LET $x = -1 MATCH (n:G) RETURN n.i LIMIT $x", .refused = error.InvalidWindowParameter },
    .{ .write = "LET $x = 'a' MATCH (n:G) RETURN n.i SKIP $x", .refused = error.InvalidWindowParameter },
    .{ .params = &.{.{ .name = "l", .expr = "0" }}, .write = "MATCH (n:G) RETURN n.i LIMIT $l", .want = &.{} },
    // m-3: a WITH's LIMIT parameter.
    .{ .params = &.{.{ .name = "l", .expr = "3" }}, .write = "MATCH (n:G) WHERE n.i < 5 WITH n LIMIT $l RETURN n.g", .want = &.{ "a", "a", "a" } },
    .{ .params = &.{.{ .name = "l", .expr = "3" }}, .write = "MATCH (n:G) WITH n.i AS i ORDER BY i LIMIT $l RETURN i", .want = &.{ "0", "1", "2" } },
    // I-6: a LET reads the LETs before it; a CALL { } body reads the LETs
    // before the CALL.
    .{ .write = "LET $a = 2, $b = $a + 1 MATCH (n:G) WHERE n.i = $b RETURN n.i", .want = &.{"3"} },
    .{ .write = "LET $a = 2, $b = $a + 1 MATCH (n:G) RETURN n.i AS i ORDER BY i LIMIT $b", .want = &.{ "0", "1", "2" } },
    .{ .write = "LET $x = 2 CALL { MATCH (n:G) WHERE n.i = $x RETURN n.i AS k } RETURN k", .want = &.{"2"} },
    .{ .params = &.{.{ .name = "p", .expr = "4" }}, .write = "LET $x = $p MATCH (n:G) WHERE n.i = $x RETURN n.i", .want = &.{"4"} },
    // A LET does not see itself or the LETs after it.
    .{ .write = "LET $a = $b, $b = 1 MATCH (n:G) WHERE n.i = $a RETURN n.i", .refused = error.MissingParameter },
};

test "SONNY-3248 (round 4b-1 review): window values, LET chains and CALL bodies, in every session" {
    try runCases("SONNY-3248 (4b-1b)", &r4b1b_3248_cases);
}

// SONNY-3319 (I-4): a label SET checks the vectors the node already holds.
const i4_vec_cases = [_]Case{
    .{ .setup = &(vec_setup ++ [_][]const u8{"CREATE (:VO2 {id: 5, emb: vectorf32('[8.0, 8.0]')})"}), .write = "MATCH (n:VO2) SET n:VD", .refused = error.VectorDimensionMismatch, .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
    } },
    .{ .setup = &(vec_setup ++ [_][]const u8{"CREATE (:VO2 {id: 5, emb: vectorf32('[8.0, 8.0]')})"}), .write = "MATCH (n:VO2) SET n:VD RETURN n.id", .refused = error.VectorDimensionMismatch, .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
    } },
    .{ .setup = &(vec_setup ++ [_][]const u8{"CREATE (:VO2 {id: 5, emb: vectorf32('[8.0, 8.0]')})"}), .write = "MERGE (n:VO2 {id: 5}) ON MATCH SET n:VD", .refused = error.VectorDimensionMismatch, .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
    } },
    .{ .setup = &vec_setup, .write = "CREATE (n:VP {id: 3, emb: vectorf32('[9.0, 9.0]')}) SET n:VD", .refused = error.VectorDimensionMismatch, .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
        .{ .query = "MATCH (n:VP) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .setup = &vec_setup, .write = "MERGE (n:VP {id: 3}) ON CREATE SET n.emb = vectorf32('[9.0, 9.0]') SET n:VD", .refused = error.VectorDimensionMismatch, .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{"1"} },
        .{ .query = "MATCH (n:VP) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    // The right dimension is accepted.
    .{ .setup = &(vec_setup ++ [_][]const u8{"CREATE (:VO3 {id: 6, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})"}), .write = "MATCH (n:VO3) SET n:VD", .checks = &.{
        .{ .query = "MATCH (n:VD) RETURN n.id", .want = &.{ "1", "6" } },
    } },
};

test "SONNY-3319 (I-4): a label SET checks the node's vectors against the new label's index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var f: h.Failures = .{ .arena = aa };
    var n: usize = 1000;
    for ([_]h.Mode{ .in_memory, .persisted }) |mode| {
        for (i4_vec_cases) |c| {
            n += 1;
            const setup = try aa.alloc([]const u8, c.setup.len);
            for (c.setup, setup) |q, *out| out.* = try numbered(aa, q, n);
            const checks = try aa.alloc(Check, c.checks.len);
            for (c.checks, checks) |chk, *out| out.* = .{ .query = try numbered(aa, chk.query, n), .want = chk.want };
            var nc = c;
            nc.setup = setup;
            nc.checks = checks;
            nc.write = try numbered(aa, c.write, n);
            runCase(mode, nc, &f) catch |err| {
                try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), nc.write, @errorName(err) });
            };
        }
    }
    try f.finish("SONNY-3319 (I-4)");
}

// SONNY-3322 (m-4): a relationship in a map a MERGE returns is the store's.
test "SONNY-3322 (m-4): a MERGE's RETURN {rel: r} holds the store's relationship, not the scope's freed copy" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    // An arena: the map a RETURN builds is not freed with the result (a
    // separate, pre-existing leak), and this test is about the edge in it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var merged = try runProgram(&s, arena.allocator(), "MERGE (a:W {k: 1}) MERGE (a)-[r:T]->(b:W {k: 2}) RETURN {rel: r} AS m, r AS r");
    defer merged.deinit(arena.allocator());
    try testing.expectEqual(@as(usize, 1), merged.rows.len);
    const map = merged.rows[0][0];
    try testing.expect(map == .Map);
    const in_map = map.Map.get("rel") orelse return error.NoRel;
    try testing.expect(in_map == .Edge);
    const direct = merged.rows[0][1];
    try testing.expect(direct == .Edge);
    // Both are the store's edge (the RETURN's `r` was made resident by
    // SONNY-3322; the map's was the scope's copy, freed with the scope).
    try testing.expectEqual(@intFromPtr(direct.Edge), @intFromPtr(in_map.Edge));
    try testing.expectEqualStrings("T", in_map.Edge.label);
}

// ---------------------------------------------------------------------------
// Round 4b-1c (the round 4b-1b re-review). Each case is the re-review's repro.

// SONNY-3367 (I-A): `WITH *` passes every variable on with its kind, and a
// variable a WITH or FOR binds to a value is no element. `(r)` after `WITH
// *` bound every node of the graph beside the relationship r.
const c1c_cases = [_]Case{
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH * MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH * MATCH (r), (q:Q) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH * MATCH (a)-[g]->(b) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH p = (g:G {i: 1})-[:R]->(x) WITH * MATCH (p) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R*1..1]->(x) WITH * MATCH (a)-[r]->(b) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH * WITH * MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH * WITH r MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH r AS s WITH * MATCH (s) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1}) OPTIONAL MATCH (g)-[r:R]->(x) WITH * MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "FOR k IN [1] MATCH (g:G {i: 1})-[r:R]->(x) WITH * MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 2})-[r:R]->(x) WITH * MATCH (r) SET r.zz = 1", .refused = error.VariableKindConflict, .checks = &.{
        .{ .query = "MATCH (n) WHERE n.zz = 1 RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = every_node, .want = &.{"24"} },
    } },
    // A value in a pattern: a WITH expression's alias, a FOR variable.
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH r.w AS r MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1}) WITH 1 AS r MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G {i: 1}) WITH collect(g) AS l, g MATCH (l) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "FOR r IN [1, 2] MATCH (r) RETURN count(*) AS n", .refused = error.VariableKindConflict },
    .{ .write = "MATCH (g:G) WHERE g.i < 2 WITH collect(g) AS gs FOR n IN gs MATCH (n)-[:R]->(x) RETURN x.j AS j", .refused = error.VariableKindConflict },
    // Not refused: a node passed on as a node, a FOR value used as a value.
    .{ .write = "MATCH (g:G {i: 1}) WITH g AS h MATCH (h)-[:R]->(x) RETURN x.j AS j", .want = &.{"1"} },
    .{ .write = "FOR r IN [1, 2] MATCH (g:G {i: r}) RETURN g.i AS i", .want = &.{ "1", "2" } },
    .{ .write = "MATCH (g:G {i: 1})-[r:R]->(x) WITH r.w AS w RETURN w", .want = &.{"w-1"} },
};

test "SONNY-3367 (round 4b-1b I-A): WITH * and FOR carry each variable's kind, in every session" {
    try runCases("SONNY-3367 (4b-1c)", &c1c_cases);
}

// SONNY-3318 (I-D): a path variable walks every type of an alternation,
// and binds its path in the multi-chain executor (`length(p)` was 0 there).
const i5c_cases = [_]Case{
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)-[:S|R]->(b) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)-[:R|S]->(b) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)<-[:S|R]-(b) RETURN count(*) AS n", .want = &.{"11"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)-[:S|R]-(b) RETURN count(*) AS n", .want = &.{"22"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)-[e:S|R]->(b) RETURN type(e) AS t, count(*) AS n GROUP BY t", .want = &.{ "R|10", "S|1" } },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:S|R*1..2]->(c) RETURN count(*) AS n", .want = &.{"2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:R|S*1..2]->(c) RETURN length(p) AS l", .want = &.{ "1", "2" } },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a)-[:S|R]->(b) WHERE a.i = 1 RETURN length(p) AS l, size(nodes(p)) AS n", .want = &.{"1|2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:R]->(b)-[:S]->(c) RETURN length(p) AS l, size(nodes(p)) AS n, size(relationships(p)) AS r", .want = &.{"2|3|2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:R]->(b)-[:S*1..1]->(c) RETURN length(p) AS l", .want = &.{"2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:R]->(b), (q:Q {i: 0}) RETURN length(p) AS l", .want = &.{"1"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = (a:G {i: 1})-[:R]->(b) WHERE length(p) = 1 RETURN count(*) AS n", .want = &.{"1"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = shortestPath((a:G {i: 1})-[:S|R*]->(c:Q)) RETURN length(p) AS l", .want = &.{"2"} },
    .{ .setup = &.{s_edge}, .write = "MATCH p = shortestPath((a:G {i: 1})-[:R|S*]->(c:Q)) RETURN length(p) AS l", .want = &.{"2"} },
    // A path whose ends name one node is a cycle; the multi-chain executor
    // bound the right end over the left, so every walk from n matched.
    .{ .setup = &.{s_edge}, .write = "MATCH p = (n:G {i: 1})-[:S|R*]->(n) WHERE length(p) > 0 RETURN count(p) AS c", .want = &.{"0"} },
    .{ .setup = &.{ s_edge, "MATCH (g:G {i: 3}) CREATE (g)-[:S]->(g)" }, .write = "MATCH p = (n:G)-[:S|R]->(n) WHERE length(p) = 1 RETURN n.i", .want = &.{"3"} },
    // No executor binds a path on an OPTIONAL MATCH after the first pattern.
    .{ .setup = &.{s_edge}, .write = "MATCH (g:G {i: 1}) OPTIONAL MATCH p = (g)-[:S|R]->(x) RETURN count(p) AS n", .refused = error.OptionalPathVariable },
    .{ .setup = &.{s_edge}, .write = "MATCH (g:G {i: 1}) OPTIONAL MATCH (g)-[:S|R]->(x) RETURN count(x) AS n", .want = &.{"1"} },
};

test "SONNY-3318 (round 4b-1b I-D): a named path walks every type and binds its path, in every session" {
    try runCases("SONNY-3318 (4b-1c)", &i5c_cases);
}

// SONNY-3248 (I-E, m-a, m-b, m-c): a LET shadows a request parameter on
// every path; a WITH's or a CALL body's window reads it; a chained MERGE's
// two names for one node.
const l1c_cases = [_]Case{
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = 5 MATCH (n:G) WHERE n.i = $a RETURN n.i", .want = &.{"5"} },
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = $a + 1 MATCH (n:G) WHERE n.i = $a RETURN n.i", .want = &.{"2"} },
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = 7 MATCH (n:G {i: $a}) RETURN n.i", .want = &.{"7"} },
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = 3 MATCH (n:G) RETURN n.i AS i ORDER BY i LIMIT $a", .want = &.{ "0", "1", "2" } },
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = 3 MATCH (n:G) WITH n.i AS i ORDER BY i LIMIT $a RETURN i", .want = &.{ "0", "1", "2" } },
    .{ .params = &.{.{ .name = "a", .expr = "1" }}, .write = "LET $a = 8 MATCH (n:G) WITH n.i AS i ORDER BY i SKIP $a RETURN i", .want = &.{ "8", "9" } },
    // m-b: a LET's window value is checked on every path.
    .{ .write = "LET $w = -2 MATCH (n:G) WITH n LIMIT $w RETURN n.i", .refused = error.InvalidWindowParameter },
    .{ .write = "LET $w = -2 MATCH (n:G) WITH n SKIP $w RETURN n.i", .refused = error.InvalidWindowParameter },
    .{ .write = "LET $w = 'x' MATCH (n:G) WITH n LIMIT $w RETURN n.i", .refused = error.InvalidWindowParameter },
    // m-a: a CALL { } body's window.
    .{ .params = &.{.{ .name = "l", .expr = "2" }}, .write = "CALL { MATCH (n:G) RETURN n.i AS k ORDER BY k LIMIT $l } RETURN k", .want = &.{ "0", "1" } },
    .{ .params = &.{.{ .name = "l", .expr = "2" }}, .write = "CALL { MATCH (n:G) RETURN n.i AS k ORDER BY k SKIP $l LIMIT 1 } RETURN k", .want = &.{"2"} },
    .{ .write = "CALL { MATCH (n:G) RETURN n.i AS k ORDER BY k SKIP 2 LIMIT 1 } RETURN k", .want = &.{"2"} },
    .{ .write = "LET $x = 3 CALL { MATCH (n:G) RETURN n.i AS k ORDER BY k LIMIT $x } RETURN k", .want = &.{ "0", "1", "2" } },
    // m-c: two MERGEs of one node, one property set through both names.
    .{ .write = "MERGE (a:W1 {k: 1}) MERGE (b:W1 {k: 1}) SET a.x = 1, b.x = 2", .refused = error.RepeatedSetTarget, .checks = &.{
        .{ .query = "MATCH (n:W1) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MERGE (a:W1 {k: 1}) MERGE (b:W1 {k: 1}) SET a.x = 1, b.y = 2 RETURN a.x, b.y", .want = &.{"1|2"}, .checks = &.{
        .{ .query = "MATCH (n:W1) RETURN n.x, n.y", .want = &.{"1|2"} },
    } },
    .{ .write = "MERGE (a:W1 {k: 1}) MERGE (b:W1 {k: 2}) SET a.x = 1, b.x = 2", .checks = &.{
        .{ .query = "MATCH (n:W1) RETURN n.k, n.x", .want = &.{ "1|1", "2|2" } },
    } },
};

test "SONNY-3248 (round 4b-1b I-E, m-a, m-b, m-c): LET shadowing, window values, CALL bodies, MERGE aliases, in every session" {
    try runCases("SONNY-3248 (4b-1c)", &l1c_cases);
}

// SONNY-3386: a comma join's FILTER, and a WITH's ORDER BY, SKIP and LIMIT
// after it (FILTER was ignored; the WITH stage kept every binding).
const f3386_cases = [_]Case{
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) FILTER q.i = 3 AND g.i = 9 RETURN g.i", .want = &.{"9"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) FILTER q.i = 3 RETURN count(*) AS c", .want = &.{"10"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WHERE g.i > 5 FILTER q.i = 3 RETURN count(*) AS c", .want = &.{"4"} },
    .{ .write = "MATCH (g:G)-[:R]->(x)-[:NOPE*0..1]->(y) FILTER g.i = 3 RETURN count(*) AS c", .want = &.{"1"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g, q ORDER BY g.i DESC LIMIT 1 RETURN g.i", .want = &.{"9"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g, q SKIP 39 RETURN count(*) AS c", .want = &.{"1"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g.i AS gi, q.i AS qi ORDER BY gi DESC, qi ASC LIMIT 1 RETURN gi, qi", .want = &.{"9|0"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g, q ORDER BY g.i SKIP 38 RETURN g.i AS gi, q.i AS qi", .want = &.{ "9|2", "9|3" } },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g, q ORDER BY g.i DESC LIMIT 3 RETURN g.i AS gi ORDER BY gi LIMIT 1", .want = &.{"9"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH DISTINCT g RETURN count(*) AS c", .want = &.{"10"} },
    .{ .write = "MATCH (g:G)-[:R]->(x), (q:Q) WITH g, q WHERE q.i = 3 RETURN count(*) AS c", .want = &.{"10"} },
    // The old per-chain cap: LIMIT 1 over a two-hop chain whose first hop
    // read one binding only, before its second hop and the WHERE.
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:R]->(b)-[:S]->(c) RETURN c.i LIMIT 1", .want = &.{"5"} },
    .{ .setup = &.{s_edge}, .write = "MATCH (a)-[:R]->(b), (c:Q) WHERE c.i = 5 AND a.i = 1 RETURN a.i LIMIT 1", .want = &.{"1"} },
};

test "SONNY-3386: a comma join applies its FILTER and the WITH after it, in every session" {
    try runCases("SONNY-3386", &f3386_cases);
}

/// Linux can reset VmHWM. Darwin's kernel peak is lifetime-wide, so retaining
/// it is conservative: an earlier peak can fail the bound, never hide growth.
fn resetPeakRss() void {
    if (comptime @import("builtin").os.tag.isDarwin()) return;
    const fd = std.c.open("/proc/self/clear_refs", .{ .ACCMODE = .WRONLY });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, "5", 1);
}

fn statusBytes(field: []const u8) usize {
    if (comptime @import("builtin").os.tag.isDarwin()) {
        const memory = darwinMemory() catch @panic("could not measure Darwin process memory");
        if (std.mem.eql(u8, field, "VmRSS")) return memory.resident;
        if (std.mem.eql(u8, field, "VmHWM")) return memory.peak;
        @panic("unsupported Darwin process memory field");
    }
    var buf: [8192]u8 = undefined;
    const fd = std.c.open("/proc/self/status", .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var parts = std.mem.tokenizeAny(u8, line[field.len..], " \t:kB");
        const kb = std.fmt.parseInt(usize, parts.next() orelse return 0, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

const ResidentMemory = struct { resident: usize, peak: usize };

fn darwinMemory() !ResidentMemory {
    var info: std.c.task_vm_info = std.mem.zeroes(std.c.task_vm_info);
    var count: std.c.mach_msg_type_number_t = std.c.TASK.VM.INFO_COUNT;
    if (std.c.task_info(std.c.mach_task_self(), std.c.TASK.VM.INFO, @ptrCast(&info), &count) != .SUCCESS)
        return error.MemoryMeasurementFailed;
    const required = (@offsetOf(std.c.task_vm_info, "resident_size_peak") + @sizeOf(u64)) / @sizeOf(std.c.natural_t);
    if (count < required or info.resident_size == 0 or info.resident_size_peak < info.resident_size)
        return error.MemoryMeasurementFailed;
    return .{ .resident = @intCast(info.resident_size), .peak = @intCast(info.resident_size_peak) };
}

/// Keep runaway regressions inside the forked child's memory allowance.
/// Linux bounds anonymous allocations with RLIMIT_DATA. Darwin does not have
/// Linux's VmData accounting: monitor the real kernel resident peak instead,
/// including a final check so an allocation freed between samples is caught.
const ChildMemoryGuard = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    limit: usize = 0,

    fn start(self: *@This(), allowance: usize) !void {
        if (comptime @import("builtin").os.tag == .linux) {
            const have = dataSegmentBytes();
            if (have == 0) return error.MemoryMeasurementFailed;
            const cap = try std.math.add(usize, have, allowance);
            try std.posix.setrlimit(.DATA, .{ .cur = cap, .max = cap });
        } else if (comptime @import("builtin").os.tag.isDarwin()) {
            self.limit = try std.math.add(usize, (try darwinMemory()).resident, allowance);
            self.thread = try std.Thread.spawn(.{}, watch, .{self});
        } else return error.UnsupportedMemoryGuardPlatform;
    }

    fn check(self: *@This()) void {
        const memory = darwinMemory() catch std.c._exit(9);
        if (memory.peak > self.limit) {
            std.debug.print("child resident peak {d} exceeds memory limit {d}\n", .{ memory.peak, self.limit });
            std.c._exit(9);
        }
    }

    fn watch(self: *@This()) void {
        while (!self.done.load(.acquire)) {
            self.check();
            std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    fn stop(self: *@This()) void {
        if (comptime @import("builtin").os.tag.isDarwin()) {
            self.done.store(true, .release);
            self.thread.?.join();
            self.check();
        }
    }
};

test "child memory guard measures real memory and rejects an oversized allocation" {
    const resident = statusBytes("VmRSS");
    try testing.expect(resident > 0);
    try testing.expect(statusBytes("VmHWM") >= resident);
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        var memory: ChildMemoryGuard = .{};
        // A setup error has its own exit code; it must not satisfy the
        // expected memory-limit refusal below.
        memory.start(32 << 20) catch std.c._exit(8);
        _ = std.c.alarm(10);
        const size = 128 << 20;
        const raw = std.c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (raw == std.c.MAP_FAILED) std.c._exit(9);
        const bytes: [*]volatile u8 = @ptrCast(raw);
        // Fault in every page: a virtual reservation alone is not RSS.
        var offset: usize = 0;
        while (offset < size) : (offset += std.heap.page_size_min) bytes[offset] = 1;
        memory.stop();
        std.c._exit(0);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    try testing.expect(!std.os.linux.W.IFSIGNALED(st));
    try testing.expectEqual(@as(u32, 9), std.os.linux.W.EXITSTATUS(st));
}

/// Round 4b-1c: the join's memory is flat in the product, and every step
/// polls the budget and the cancel.
const BoundJob = struct {
    s: *h.Session,
    ok: bool = true,

    fn fail(self: *BoundJob, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  " ++ fmt ++ "\n", args);
        self.ok = false;
    }

    /// I-B: a WHERE that keeps no binding of the 2.25 million the join
    /// tries holds no memory for them.
    fn flat(self: *BoundJob) void {
        geode.read_budget.setBudgetBytesForTest(64 << 20);
        defer geode.read_budget.setBudgetBytesForTest(0);
        resetPeakRss();
        const before = statusBytes("VmRSS");
        if (before == 0) return self.fail("resident memory measurement unavailable", .{});
        const start = monoMillis();
        var r = runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P)-[:E]->(d) WHERE 1 = 2 RETURN a.i") catch |err| {
            return self.fail("WHERE 1 = 2: error {s}", .{@errorName(err)});
        };
        defer r.deinit(stmt_alloc);
        const took = monoMillis() - start;
        const peak = statusBytes("VmHWM");
        if (peak < before) return self.fail("peak memory measurement unavailable", .{});
        const grew = peak - before;
        if (r.rows.len != 0) self.fail("WHERE 1 = 2: {d} row(s)", .{r.rows.len});
        // 1,500 pairs: about 700 MB before the fix.
        if (grew > 128 << 20) self.fail("WHERE 1 = 2: the peak grew {d} MiB (at most 128)", .{grew >> 20});
        if (took > 240_000) self.fail("WHERE 1 = 2: took {d} ms", .{took});
    }

    /// I-C: a join whose last chain matches nothing ends at once; one whose
    /// last hop never matches is stopped by the stream's cancel.
    fn polled(self: *BoundJob) void {
        var start = monoMillis();
        var r = runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P), (d:P), (e:P {i: -1}) RETURN count(*) AS n") catch |err| {
            return self.fail("empty last chain: error {s}", .{@errorName(err)});
        };
        const rows = h.renderRows(self.s.arena.allocator(), r) catch &.{};
        r.deinit(stmt_alloc);
        if (rows.len != 1 or !std.mem.eql(u8, rows[0], "0")) self.fail("empty last chain: {d} row(s)", .{rows.len});
        if (monoMillis() - start > 1_000) self.fail("empty last chain: took {d} ms", .{monoMillis() - start});

        var cancel = std.atomic.Value(bool).init(false);
        geode.read_budget.setStreamCancelSource(&cancel);
        defer geode.read_budget.setStreamCancelSource(null);
        const Setter = struct {
            fn run(flag: *std.atomic.Value(bool)) void {
                std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(200), .awake) catch {};
                flag.store(true, .release);
            }
        };
        const t = std.Thread.spawn(.{}, Setter.run, .{&cancel}) catch return self.fail("spawn failed", .{});
        start = monoMillis();
        if (runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P), (d:P)-[:NOPE]->(z) RETURN a.i")) |got| {
            var res = got;
            res.deinit(stmt_alloc);
            self.fail("a join no binding completes: ran to the end, not cancelled", .{});
        } else |err| if (err != error.ReadQueryCancelled) self.fail("a join no binding completes: error {s}", .{@errorName(err)});
        t.join();
        // The cancel lands at 200 ms; the join stops at its next step.
        if (monoMillis() - start > 1_200) self.fail("a join no binding completes: stopped after {d} ms", .{monoMillis() - start});
    }
};

fn runBoundInChild(job: *BoundJob, comptime which: fn (*BoundJob) void) !void {
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var memory: ChildMemoryGuard = .{};
        memory.start(1 << 30) catch std.c._exit(9);
        // A regression that stops polling is killed, not waited for.
        _ = std.c.alarm(300);
        which(job);
        memory.stop();
        std.c._exit(if (job.ok) 0 else 1);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) {
        std.debug.print("the join was killed (signal {d})\n", .{std.os.linux.W.TERMSIG(st)});
        return error.Crashed;
    }
    try testing.expectEqual(@as(u32, 0), std.os.linux.W.EXITSTATUS(st));
}

test "SONNY-3368 (round 4b-1b I-B): a WHERE that keeps nothing over 2.25 million bindings holds flat memory" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    var setup = try runProgram(&s, stmt_alloc, "FOR i IN range(1, 1500) CREATE (:P {i: i})-[:E]->(:P2 {i: i})");
    setup.deinit(stmt_alloc);
    var job: BoundJob = .{ .s = &s };
    try runBoundInChild(&job, BoundJob.flat);
}

test "SONNY-3368 (round 4b-1b I-C): a join polls at every step: an empty last chain ends at once, a cancel stops one that completes nothing" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    var setup = try runProgram(&s, stmt_alloc, "FOR i IN range(1, 400) CREATE (:P {i: i})-[:E]->(:P2 {i: i})");
    setup.deinit(stmt_alloc);
    var job: BoundJob = .{ .s = &s };
    try runBoundInChild(&job, BoundJob.polled);
}

// ---------------------------------------------------------------------------
// SONNY-3244 (round-4a review I-4): statement nesting. The fix is round
// 14-16's (max_statement_nesting, stackHasRoom, max_expr_links and the 16 MiB
// admission thread), merged from fix/sonny-738-r12 in the v0.8.23
// reconciliation.

const NestJob = struct {
    s: *h.Session,
    query: []const u8,

    fn entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
        const job: *NestJob = @ptrCast(@alignCast(arg.?));
        // Refused or answered: either is fine; only a crash is not.
        var parsed = geode.parseGql(job.query, job.s.arena.allocator()) catch return null;
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&job.s.ctx);
        defer execution.popActiveContext(prev);
        var result = execution.executeProgramWithContext(stmt_alloc, &parsed.program, job.s.ctx) catch return null;
        result.deinit(stmt_alloc);
        return null;
    }
};

fn nestInChild(s: *h.Session, query: []const u8, stack: usize) bool {
    const pid = std.c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var job: NestJob = .{ .s = s, .query = query };
        const page = std.heap.page_size_min;
        const raw = std.c.mmap(null, stack + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (raw == std.c.MAP_FAILED) std.c._exit(9);
        const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw));
        if (std.c.mprotect(@ptrCast(base), page, .{}) != 0) std.c._exit(9);
        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != .SUCCESS) std.c._exit(9);
        if (std.c.pthread_attr_setstack(&attr, @ptrCast(base + page), stack) != .SUCCESS) std.c._exit(9);
        var tid: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&tid, &attr, NestJob.entry, &job) != .SUCCESS) std.c._exit(9);
        _ = std.c.pthread_join(tid, null);
        std.c._exit(0);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return false;
    const st: u32 = @bitCast(status);
    return !std.os.linux.W.IFSIGNALED(st) and std.os.linux.W.EXITSTATUS(st) == 0;
}

fn repeat(aa: std.mem.Allocator, prefix: []const u8, unit: []const u8, n: usize, suffix: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(aa, prefix);
    for (0..n) |_| try text.appendSlice(aa, unit);
    try text.appendSlice(aa, suffix);
    return text.toOwnedSlice(aa);
}

fn nestedIn(aa: std.mem.Allocator, depth: usize, parens: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try text.appendSlice(aa, "MATCH (m) WHERE m.i IN (");
    try text.appendSlice(aa, "RETURN ");
    for (0..parens) |_| try text.append(aa, '(');
    try text.append(aa, '1');
    for (0..parens) |_| try text.append(aa, ')');
    for (0..depth) |_| try text.appendSlice(aa, ") RETURN m.i");
    return text.toOwnedSlice(aa);
}

// The thread stacks are the ones a server request runs on since SONNY-3253
// (round 15): the QUIC admission threads take 8 MiB at least (16 MiB in a
// Debug build), the workers and gRPC connection threads 8 or 16 MiB. A
// 1 MiB thread, the admission threads' stack before then, cannot hold a
// Debug build's statement frames (about 0.3 MiB each) even for `RETURN 1`,
// so it is not a stack a request runs on any more and is not probed.
test "SONNY-3244 (I-4): nested statements and expressions are refused, never crash an 8 MiB or a 16 MiB thread" {
    var s = try h.Session.init(.in_memory);
    defer s.deinit();
    const aa = s.arena.allocator();
    const repros = [_][]const u8{
        try repeat(aa, "", "PROFILE ", 200, "RETURN 1 AS x"),
        try repeat(aa, "", "VALUES (1) AS (a) ", 200, "RETURN 1 AS x"),
        try repeat(aa, "", "EXPLAIN ", 100, "RETURN 1 AS x"),
        try repeat(aa, "", "EXPLAIN POLICY ", 100, "RETURN 1 AS x"),
        try repeat(aa, "", "START TRANSACTION { ", 100, "RETURN 1 AS x"),
        try repeat(aa, "RETURN ", "- ", 2000, "1 AS x"),
        try repeat(aa, "RETURN ", "1 + ", 4000, "1 AS x"),
        try nestedIn(aa, 8, 120),
        try nestedIn(aa, 10, 120),
    };
    var failures: usize = 0;
    for ([_]usize{ 8 << 20, 16 << 20 }) |stack| {
        for (repros) |q| {
            if (!nestInChild(&s, q, stack)) {
                std.debug.print("crashed on {d} MiB: {s}...\n", .{ stack >> 20, q[0..@min(q.len, 60)] });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
