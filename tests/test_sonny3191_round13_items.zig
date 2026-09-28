// SONNY-3191 regression: the round 13 review's remaining items, and
// SONNY-3122's read-path graph lookup.
//
// - N-4: a session's own graph hold (SONNY-3134) outlived its COMMIT or
//   ROLLBACK statement to the end of the program, so `COMMIT; DROP GRAPH g`
//   answered 55006. The executor now lets the hold go where the statement ends
//   the transaction (`graph_store.releaseThreadTxnHold`).
// - N-5: under overload the QUIC connection admission thread runs a
//   connection's first stream itself, on a 1 MiB stack, where a plain MATCH
//   got "nesting too deep" (a segfault in Debug). It now has a request
//   thread's stack (`stack_guard.request_thread_stack_bytes`, 16 MiB).
// - N-6: a Debug build refuses WITH chains past about 25 levels on an 8 MiB
//   thread (the frames are several times a release build's); documented, and
//   pinned here: refused cleanly in Debug, parsed in a release build.
// - N-7: CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, HOME_GRAPH and
//   HOME_PROPERTY_GRAPH are reserved: CREATE and DROP GRAPH of them answer
//   42939, and the store refuses to create one.
// - SONNY-3122: `planned_read_runtime.edgeTypeName` looks a graph up and pins
//   it, instead of `getOrCreateGraph` on a read path.
//
// CANARY: REQ=REQ-SONNY-3191-ROUND13-ITEMS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3191_round13_items.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

/// The QUIC connection admission thread's stack (main.zig).
const admission_stack: usize = geode.stack_guard.request_thread_stack_bytes;

// ---------------------------------------------------------------------------
// N-4
// ---------------------------------------------------------------------------

test "SONNY-3191 N-4: over gRPC COMMIT or ROLLBACK then DROP GRAPH (or CREATE OR REPLACE GRAPH) of the transaction's graph runs in one program" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const b = try f.session("n4b");
    const Case = struct { program: []const u8, dropped: bool, kept_b: usize };
    const cases = [_]Case{
        .{ .program = "COMMIT; DROP GRAPH g8", .dropped = true, .kept_b = 0 },
        .{ .program = "ROLLBACK; DROP GRAPH g8", .dropped = true, .kept_b = 0 },
        .{ .program = "COMMIT; CREATE OR REPLACE GRAPH g8", .dropped = false, .kept_b = 0 },
        .{ .program = "COMMIT; DROP GRAPH IF EXISTS g8", .dropped = true, .kept_b = 0 },
    };
    for (cases) |c| {
        if (!f.st.graphExists("g8")) try f.st.createGraph("g8");
        const uuid0 = (try ad.lookupManagedGraph("g8")).uuid;
        try fx.expectRuns(ga, b, "USE GRAPH g8");
        try fx.begin(ga, b);
        try fx.expectRuns(ga, b, "CREATE (:B {v: 1})");
        try testing.expect(graph_store.graphHeldByTxn("g8"));
        fx.expectRuns(ga, b, c.program) catch |err| {
            std.debug.print("{s}: refused\n", .{c.program});
            return err;
        };
        try testing.expect(!graph_store.graphHeldByTxn("g8"));
        try testing.expectEqual(!c.dropped, f.st.graphExists("g8"));
        if (!c.dropped) {
            // Replaced: a new graph, without the transaction's node.
            try testing.expect(!std.mem.eql(u8, &uuid0, &(try ad.lookupManagedGraph("g8")).uuid));
            try testing.expectEqual(c.kept_b, fx.countLabel(f.st, "g8", "B"));
        }
        const e = f.sessions.getEntry(b) orelse return error.SessionMissing;
        try testing.expect(!e.state.in_txn);
        try fx.expectRuns(ga, b, "USE GRAPH default");
    }
    // Another session's open transaction still holds the graph: 55006.
    if (!f.st.graphExists("g8")) try f.st.createGraph("g8");
    const c = try f.session("n4c");
    try fx.expectRuns(ga, c, "USE GRAPH g8");
    try fx.begin(ga, c);
    try fx.expectRuns(ga, c, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, b, "USE GRAPH g8");
    try fx.begin(ga, b);
    try fx.expectRuns(ga, b, "CREATE (:B {v: 1})");
    _ = try fx.expectRefused(ga, b, "COMMIT; DROP GRAPH g8", "55006");
    try testing.expect(f.st.graphExists("g8"));
    try testing.expect(try fx.rollback(ga, c));
    try testing.expect(!graph_store.graphHeldByTxn("g8"));
    try fx.expectRuns(ga, b, "USE GRAPH default");
    try fx.expectRuns(ga, b, "DROP GRAPH g8");
}

test "SONNY-3191 N-4: over QUIC COMMIT; DROP GRAPH of the transaction's graph runs in one program" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3191-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    var b = try util.QuicProtoClient.connect(allocator, addr);
    defer b.deinit();
    var hb = try b.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hb.deinit(allocator);
    for ([_][]const u8{ "COMMIT; DROP GRAPH g8", "ROLLBACK; DROP GRAPH g8" }) |program| {
        try quicOk(&b, allocator, "CREATE GRAPH g8");
        try quicOk(&b, allocator, "USE GRAPH g8");
        var begun = try b.begin(allocator);
        begun.deinit(allocator);
        try quicOk(&b, allocator, "CREATE (:B {v: 1})");
        try quicOk(&b, allocator, program);
        try quicOk(&b, allocator, "USE GRAPH default");
        try testing.expectEqualStrings("3F000", (try quicCode(&b, allocator, "USE GRAPH g8")) orelse "ran");
    }
}

var code_buf: [16]u8 = undefined;

fn quicCode(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !?[]const u8 {
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
    defer r.deinit(allocator);
    const code = r.error_code orelse return null;
    std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
    const n = @min(code.len, code_buf.len);
    @memcpy(code_buf[0..n], code[0..n]);
    return code_buf[0..n];
}

fn quicOk(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    if (try quicCode(c, allocator, q)) |_| return error.QueryFailed;
}

// ---------------------------------------------------------------------------
// N-5
// ---------------------------------------------------------------------------

const Rpc = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    code: ?[]const u8 = null,
    err: ?anyerror = null,

    fn run(self: *Rpc) void {
        self.code = fx.outcome(self.ga, self.session, self.query) catch |e| {
            self.err = e;
            return;
        };
    }
};

test "SONNY-3191 N-5: a plain MATCH, and the queries a first stream carries, run on the QUIC admission thread's stack" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("n5");
    try fx.expectRuns(ga, s, "CREATE (:Person {name: 'x', age: 40})");
    std.debug.print("admission thread stack: {d} KiB\n", .{admission_stack / 1024});
    const qs = [_][]const u8{
        "MATCH (n:Person) WHERE n.age > 30 AND n.name = 'x' RETURN n.name ORDER BY n.name LIMIT 10",
        "MATCH (n) RETURN count(n) AS c",
        "CREATE (:Person {name: 'y', age: 20})",
        "MATCH (n:Person {name: 'y'}) SET n.age = 21",
        "EXPLAIN MATCH (n:Person) RETURN n",
    };
    for (qs) |q| {
        var rpc: Rpc = .{ .ga = ga, .session = s, .query = q };
        const t = try std.Thread.spawn(.{ .stack_size = admission_stack }, Rpc.run, .{&rpc});
        t.join();
        if (rpc.err) |e| return e;
        std.debug.print("{s} -> {s}\n", .{ q, rpc.code orelse "ran" });
        try testing.expect(rpc.code == null);
    }
}

// ---------------------------------------------------------------------------
// N-6
// ---------------------------------------------------------------------------

const Outcome = enum { parsed, refused, crashed, failed };

const ParseJob = struct {
    query: []const u8,
    outcome: Outcome = .failed,

    fn run(self: *ParseJob) void {
        var out = geode.parseGqlOutcome(self.query, std.heap.smp_allocator, .{}) catch {
            self.outcome = .failed;
            return;
        };
        defer out.deinit();
        self.outcome = switch (out) {
            .Ok => .parsed,
            .Err => .refused,
        };
    }
};

fn parseInChild(query: []const u8, stack: usize) Outcome {
    const pid = std.c.fork();
    if (pid < 0) return .failed;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var job: ParseJob = .{ .query = query };
        const t = std.Thread.spawn(.{ .stack_size = stack }, ParseJob.run, .{&job}) catch std.c._exit(3);
        t.join();
        std.c._exit(switch (job.outcome) {
            .parsed => 0,
            .refused => 1,
            .crashed, .failed => 3,
        });
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return .failed;
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) return .crashed;
    return switch (std.os.linux.W.EXITSTATUS(st)) {
        0 => .parsed,
        1 => .refused,
        else => .failed,
    };
}

test "SONNY-3191 N-6: a WITH chain of 64 parses on an 8 MiB thread in a release build; a Debug build refuses it cleanly (its documented limit), and takes 20" {
    const allocator = testing.allocator;
    for ([_]usize{ 20, 64 }) |d| {
        var q = std.ArrayList(u8).empty;
        defer q.deinit(allocator);
        var i: usize = 0;
        while (i < d) : (i += 1) try q.appendSlice(allocator, "WITH 1 AS a ");
        try q.appendSlice(allocator, "RETURN a");
        const o = parseInChild(q.items, 8 * 1024 * 1024);
        std.debug.print("WITH chain {d} on 8 MiB ({s}): {s}\n", .{ d, @tagName(builtin.mode), @tagName(o) });
        try testing.expect(o != .crashed and o != .failed);
        if (d == 20 or builtin.mode != .Debug) try testing.expectEqual(Outcome.parsed, o);
    }
}

// ---------------------------------------------------------------------------
// N-7
// ---------------------------------------------------------------------------

test "SONNY-3191 N-7: CREATE and DROP GRAPH of CURRENT_GRAPH, HOME_GRAPH and their PROPERTY forms answer 42939, and the store creates no such graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("n7");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const names = [_][]const u8{ "CURRENT_GRAPH", "HOME_GRAPH", "current_property_graph", "Home_Property_Graph" };
    var buf: [96]u8 = undefined;
    for (names) |n| {
        _ = try fx.expectRefused(ga, s, try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{n}), "42939");
        _ = try fx.expectRefused(ga, s, try std.fmt.bufPrint(&buf, "CREATE OR REPLACE GRAPH {s}", .{n}), "42939");
        _ = try fx.expectRefused(ga, s, try std.fmt.bufPrint(&buf, "DROP GRAPH {s}", .{n}), "42939");
        _ = try fx.expectRefused(ga, s, try std.fmt.bufPrint(&buf, "DROP GRAPH IF EXISTS {s}", .{n}), "42939");
        try testing.expect(!f.st.graphExists(n));
        // Nor did the statement's graph lock create it in the engine.
        try testing.expect(!ad.graphExists(n));
        try testing.expectError(error.ReservedGraphName, f.st.createGraph(n));
    }
    // From a session on g1, DROP GRAPH CURRENT_GRAPH drops nothing.
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    _ = try fx.expectRefused(ga, s, "DROP GRAPH CURRENT_GRAPH", "42939");
    try testing.expect(f.st.graphExists("g1"));
    // USE GRAPH of them still selects the current and home graphs.
    try fx.expectRuns(ga, s, "USE GRAPH CURRENT_GRAPH");
    try fx.expectRuns(ga, s, "USE GRAPH HOME_GRAPH");
    // Other names are unaffected.
    try fx.expectRuns(ga, s, "CREATE GRAPH current_graph_2");
    try fx.expectRuns(ga, s, "DROP GRAPH current_graph_2");
}

// ---------------------------------------------------------------------------
// SONNY-3122
// ---------------------------------------------------------------------------

test "SONNY-3122: a read resolves edge type names from the graph it reads (looked up and pinned), and creates no graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("t3122");
    try fx.expectRuns(ga, s, "USE GRAPH g2");
    try fx.expectRuns(ga, s, "CREATE (:A {v: 1})-[:KNOWS]->(:A {v: 2})");
    const graphs_before = f.st.graphs.count();
    const resp = try fx.execute(ga, s, "MATCH (a:A)-[r]->(b:A) RETURN type(r) AS t");
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("type(r): {s} {s}\n", .{ e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
    try testing.expectEqual(graphs_before, f.st.graphs.count());
}

// ---------------------------------------------------------------------------
// SONNY-3191, seen in code: the policy expression parser's bounds
// ---------------------------------------------------------------------------

test "SONNY-3191: a policy expression nested past 64 parentheses or with more than 1024 AND/OR links is refused, not a stack overflow" {
    const allocator = testing.allocator;
    const pe = geode.security.policy_expression;
    const Case = struct { open: []const u8, core: []const u8, close: []const u8, sep: []const u8, n: usize, ok: bool };
    const cases = [_]Case{
        .{ .open = "(", .core = "true", .close = ")", .sep = "", .n = 64, .ok = true },
        .{ .open = "(", .core = "true", .close = ")", .sep = "", .n = 65, .ok = false },
        .{ .open = "(", .core = "true", .close = ")", .sep = "", .n = 100_000, .ok = false },
        .{ .open = "", .core = "true", .close = "", .sep = " AND true", .n = 1024, .ok = true },
        .{ .open = "", .core = "true", .close = "", .sep = " OR true", .n = 1025, .ok = false },
        .{ .open = "", .core = "true", .close = "", .sep = " AND true", .n = 1_000_000, .ok = false },
    };
    for (cases) |c| {
        var q = std.ArrayList(u8).empty;
        defer q.deinit(allocator);
        var i: usize = 0;
        while (i < c.n and c.open.len > 0) : (i += 1) try q.appendSlice(allocator, c.open);
        try q.appendSlice(allocator, c.core);
        i = 0;
        while (i < c.n and c.close.len > 0) : (i += 1) try q.appendSlice(allocator, c.close);
        i = 0;
        while (i < c.n and c.sep.len > 0) : (i += 1) try q.appendSlice(allocator, c.sep);
        if (pe.compileExpression(allocator, q.items)) |compiled| {
            var ce = compiled;
            defer ce.deinit();
            try testing.expect(c.ok);
            try testing.expect(pe.evaluate(&ce, .{ .current_user = null, .current_tenant = null, .current_graph = null, .resource_label = null }));
        } else |err| {
            std.debug.print("policy expression ({d}): {s}\n", .{ c.n, @errorName(err) });
            try testing.expect(!c.ok);
        }
    }
}
