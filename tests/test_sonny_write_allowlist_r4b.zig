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
// - SONNY-3244 (I-4): the nesting repros, off until round 14-16 merges.
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
        var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        run_tag = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
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
