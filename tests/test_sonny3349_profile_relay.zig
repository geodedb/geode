// SONNY-3349 regression (round 17): the limit relay covers PROFILE and the
// node scan's materialization.
//
// - PROFILE runs its query through `planned_read_runtime.executeProfiledIfSupported`,
//   outside `execution.executeStatementWithContext`, whose scope the relay
//   is (round 16 review, probe P2). A limit a caller swallowed became the
//   profile's rows: `PROFILE MATCH (n:C) WHERE EXISTS { ... <54001> ... }
//   RETURN n.v` answered 00000, and `PROFILE MATCH (n:C) SET n.z = EXISTS {
//   ... }` answered 00000 and wrote `n.z`. The profiled run opens the scope
//   now, fails with what it recorded, and (SONNY-3348) writes nothing.
// - `node_scan_stream` skipped a row whose materialization failed, as for a
//   node deleted under the scan, whatever the error: an out of memory became
//   a missing row, in the paging scan, the filtered count, and the
//   WHERE + LIMIT enumeration. An out of memory fails the query now.
//
// CANARY: REQ=REQ-SONNY-3349-PROFILE-RELAY; FEATURE="ExpressionEvaluator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3349_profile_relay.zig; OWNER=eval; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const harness = @import("node_scan_stream_harness.zig");

const eval = geode.eval;
const node_scan_stream = geode.node_scan_stream;

/// Where the evaluator's test seam fails (`eval.test_force_limit_marker`).
const L = "'" ++ eval.test_force_limit_marker ++ "'";

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    force: ?eval.EvalError = null,
    tag: []const u8 = "-",
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
        const payload = resp.payload orelse return error.MissingPayload;
        self.tag = @tagName(payload);
        switch (payload) {
            .@"error" => |e| {
                self.code = e.code;
                return;
            },
            .profile => |p| {
                var max_rows: u64 = 0;
                for (p.ops.items) |op| max_rows = @max(max_rows, op.rows);
                self.rows = @intCast(max_rows);
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |pg| self.rows = pg.rows.items.len,
            .@"error" => |e| self.code = e.code,
            else => return error.UnexpectedPayload,
        }
    }
};

fn runOn(ga: std.mem.Allocator, session: []const u8, query: []const u8, force: ?eval.EvalError) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query, .force = force };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Run.go, .{&r});
    t.join();
    std.debug.print("SONNY-3349: force={s} -> {s} code={s} err={s} rows={d} :: {s}\n", .{
        if (force) |e| @errorName(e) else "none",
        r.tag,
        r.code orelse "-",
        if (r.err) |e| @errorName(e) else "-",
        r.rows,
        query,
    });
    return r;
}

fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query, null);
    if (r.err) |e| return e;
    if (r.code != null) return error.QueryFailed;
    return r.rows;
}

test "SONNY-3349: PROFILE of a query whose limit a caller swallowed answers the limit, not a profile (round 16 probe P2)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3349a");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");

    const exists_q = "PROFILE MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v = n.v AND " ++ L ++ " = 'x' } RETURN n.v AS v";
    // Unforced, a profile.
    const plain = try runOn(ga, s, exists_q, null);
    try testing.expectEqualStrings("profile", plain.tag);

    try testing.expectEqualStrings("54001", (try runOn(ga, s, exists_q, error.ExpressionTooDeep)).code orelse "ran");
    try testing.expectEqualStrings("54001", (try runOn(ga, s, "PROFILE MATCH (n:C) RETURN COUNT { MATCH (m:C) WHERE " ++ L ++ " = 'x' } AS v", error.ExpressionTooDeep)).code orelse "ran");
    for ([_]eval.EvalError{ error.OutOfMemory, error.ReadQueryBudgetExceeded }) |forced| {
        const r = try runOn(ga, s, exists_q, forced);
        try testing.expect(r.code != null or r.err != null);
    }
    // An IN type error a subquery swallowed (22000).
    try testing.expectEqualStrings("22000", (try runOn(ga, s, "PROFILE MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v IN 5 } RETURN n.v AS v", null)).code orelse "ran");

    // A PROFILE'd change decided by the limit answers it and writes nothing
    // (SONNY-3348).
    try testing.expectEqualStrings("54001", (try runOn(ga, s, "PROFILE MATCH (n:C) SET n.z = (" ++ L ++ " = 'x') RETURN n.v AS v", error.ExpressionTooDeep)).code orelse "ran");
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.z IS NOT NULL RETURN n.z AS z"));
    const oom = try runOn(ga, s, "PROFILE MATCH (n:C) SET n.z = (" ++ L ++ " = 'x') RETURN n.v AS v", error.OutOfMemory);
    try testing.expect(oom.code != null or oom.err != null);
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:C) WHERE n.z IS NOT NULL RETURN n.z AS z"));

    // Unforced, the PROFILE'd change runs and writes every row.
    try testing.expectEqualStrings("profile", (try runOn(ga, s, "PROFILE MATCH (n:C) SET n.z = (" ++ L ++ " = 'x') RETURN n.v AS v", null)).tag);
    try testing.expectEqual(@as(usize, 3), try rowsOf(ga, s, "MATCH (n:C) WHERE n.z = false RETURN n.z AS z"));
}

/// Page `stream` to its end; the rows served.
fn drain(stream: *node_scan_stream.NodeScanStream, allocator: std.mem.Allocator) !usize {
    var rows: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > harness.many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, 0);
        defer page.result.deinit(allocator);
        rows += page.result.rows.len;
        if (page.final) break;
    }
    return rows;
}

fn scanRows(h: *harness.Harness, src: []const u8) !usize {
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    var stream = try harness.openStream(h, testing.allocator, &qa, src);
    defer stream.deinit();
    return drain(&stream, testing.allocator);
}

test "SONNY-3349: an out of memory materializing a node fails the node scan; a node gone under it is still skipped" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    const shapes = [_][]const u8{
        // The paging scan, projected (materializeNodeProjected) and whole.
        "MATCH (n:M) RETURN n.s, n.i",
        "MATCH (n:M) RETURN n",
        // The filtered count.
        "MATCH (n:M) WHERE n.i >= 0 RETURN count(n)",
        // WHERE + LIMIT: the bounded enumeration (slotMatchesPredicate).
        "MATCH (n:M) WHERE n.i >= 0 RETURN n.s LIMIT 5",
    };
    for (shapes) |src| {
        const plain = try scanRows(&h, src);
        try testing.expect(plain > 0);

        node_scan_stream.test_materialize_error = error.OutOfMemory;
        const oom = scanRows(&h, src);
        node_scan_stream.test_materialize_error = null;
        std.debug.print("SONNY-3349 scan: {s}: plain rows={d}, forced OutOfMemory -> {s}\n", .{ src, plain, if (oom) |_| "rows" else |e| @errorName(e) });
        try testing.expectError(error.OutOfMemory, oom);

        // A node deleted under the scan is skipped, as before.
        node_scan_stream.test_materialize_error = error.NodeNotFound;
        const gone = scanRows(&h, src);
        node_scan_stream.test_materialize_error = null;
        std.debug.print("SONNY-3349 scan: {s}: forced NodeNotFound -> {s}\n", .{ src, if (gone) |_| "ok" else |e| @errorName(e) });
        _ = try gone;
    }
}
