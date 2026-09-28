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
