// SONNY-2749 regression: a program's writes run under the write lock of the
// graph they write, not the session graph's.
//
// The QUIC and gRPC handlers locked the session's graph: QUIC the copy it
// syncs after a request that succeeds, gRPC always `default`, because it never
// synced `state.current_graph`. A USE GRAPH or SESSION SET PROPERTY GRAPH in
// the program moves the executor to another graph. So `USE GRAPH g2; MERGE
// (:K {id: 1})` wrote g2 holding another graph's write lock, beside writers
// that held g2's, and two MERGEs of one key could both miss and both insert.
// `query_traits.statementPlan` now names the graph the program's statements
// run on (`lock_graph`, from `programGraph`), and a program that changes data
// on more than one graph is refused with 0A000 (`spans_graphs`).
//
// There is no in-process QUIC harness. These tests drive `statementPlan` and
// `graph_store.acquireProgramWriteLockCancelable` (the calls both handlers
// make) with the real executor, and the real gRPC Execute handler.
//
// CANARY: REQ=REQ-SONNY-2749-PROGRAM-GRAPH-LOCK; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2749_program_graph_lock.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const query_traits = geode.query_traits;
const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const default_graph = graph_store.DEFAULT_GRAPH_NAME;

fn planOf(query: []const u8, session_graph: []const u8) !struct { lock_graph: []const u8, spans_graphs: bool, needs_store_lock: bool, self_locking: bool } {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    const analysis = query_traits.analyzeProgram(&parsed.program);
    const plan = query_traits.statementPlan(&parsed.program, &analysis, session_graph, default_graph, .quic);
    // `lock_graph` may point into the program; resolve it to a static name.
    const names = [_][]const u8{ "default", "g2", "g3", "g9" };
    const lock_graph: []const u8 = for (names) |n| {
        if (std.mem.eql(u8, n, plan.lock_graph)) break n;
    } else "?";
    return .{ .lock_graph = lock_graph, .spans_graphs = plan.spans_graphs, .needs_store_lock = plan.needs_store_lock, .self_locking = plan.self_locking };
}

test "SONNY-2749: the lock is on the graph the program's statements run on" {
    const Case = struct { query: []const u8, session: []const u8, lock: []const u8, spans: bool = false };
    const cases = [_]Case{
        .{ .query = "MERGE (:K {id: 1})", .session = "default", .lock = "default" },
        .{ .query = "USE GRAPH g2; MERGE (:K {id: 1})", .session = "default", .lock = "g2" },
        .{ .query = "SESSION SET PROPERTY GRAPH g2; CREATE (:X)", .session = "default", .lock = "g2" },
        // The CLI's -g shape: USE GRAPH of the session's own graph.
        .{ .query = "USE GRAPH default; CREATE (:X)", .session = "default", .lock = "default" },
        .{ .query = "USE GRAPH g2; CREATE (:X)", .session = "g2", .lock = "g2" },
        // SESSION RESET back to the default graph, or not.
        .{ .query = "USE GRAPH g2; SESSION RESET GRAPH; CREATE (:X)", .session = "g3", .lock = "default" },
        .{ .query = "USE GRAPH g2; SESSION RESET; CREATE (:X)", .session = "g3", .lock = "default" },
        .{ .query = "USE GRAPH g2; SESSION RESET ALL PARAMETERS; CREATE (:X)", .session = "g3", .lock = "g2" },
        // A read after USE GRAPH reads that graph.
        .{ .query = "USE GRAPH g2; MATCH (n) RETURN n", .session = "default", .lock = "g2" },
        // Writes on more than one graph are refused; reads fall back.
        .{ .query = "CREATE (:X); USE GRAPH g2; CREATE (:Y)", .session = "default", .lock = "default", .spans = true },
        .{ .query = "USE GRAPH g2; MATCH (n) RETURN n; USE GRAPH g3; CREATE (:X)", .session = "default", .lock = "default", .spans = true },
        // SONNY-3028: CREATE and DROP GRAPH run on the graph they name.
        .{ .query = "CREATE GRAPH g9; USE GRAPH g9; CREATE (:X)", .session = "default", .lock = "g9" },
        .{ .query = "DROP GRAPH g2", .session = "default", .lock = "g2" },
        .{ .query = "CREATE (:X); DROP GRAPH g2", .session = "default", .lock = "default", .spans = true },
        .{ .query = "MATCH (n) RETURN n; USE GRAPH g2; MATCH (m) RETURN m", .session = "default", .lock = "default" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try planOf(c.query, c.session);
        if (!std.mem.eql(u8, got.lock_graph, c.lock) or got.spans_graphs != c.spans) {
            std.debug.print("{s} (session {s}): expected lock {s} spans={}, got lock {s} spans={}\n", .{ c.query, c.session, c.lock, c.spans, got.lock_graph, got.spans_graphs });
            failures += 1;
        }
    }
    // The backfill still runs holding no lock (SONNY-2733), and is not refused.
    const backfill = try planOf("CALL geode.tenant.backfill_edge_tags()", "default");
    if (!backfill.self_locking or backfill.needs_store_lock or backfill.spans_graphs) failures += 1;
    try testing.expectEqual(@as(usize, 0), failures);
}

/// One program, run as a transport handler runs a mutation: its statement
/// plan names the graph to lock, that graph's write lock is held, and the
/// executor runs the program in a session that starts on `session_graph`.
const Writer = struct {
    catalog: @FieldType(execution.ExecutionContext, "catalog"),
    session_graph: []const u8,
    query: []const u8,
    go: *std.atomic.Value(bool),
    err: ?anyerror = null,

    fn run(self: *Writer) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *Writer) !void {
        const allocator = testing.allocator;
        var parsed = try geode.parseGql(self.query, allocator);
        defer parsed.deinit();
        const analysis = query_traits.analyzeProgram(&parsed.program);
        const plan = query_traits.statementPlan(&parsed.program, &analysis, self.session_graph, default_graph, .quic);
        if (!plan.is_mutation or !plan.needs_store_lock) return error.NotAWrite;

        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        session.graph = try allocator.dupe(u8, self.session_graph);
        const ctx = execution.ExecutionContext{ .catalog = self.catalog, .session_state = &session };

        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        const lock = try graph_store.acquireProgramWriteLockCancelable(plan.lock_graph, self.session_graph, std.math.maxInt(u64));
        defer graph_store.releaseGraphLock(lock);
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var result = try execution.executeProgramWithContext(arena.allocator(), &parsed.program, ctx);
        result.deinit(arena.allocator());
    }
};

fn countKeyed(st: *graph_store.GraphStore, graph: []const u8, label: []const u8, key: i64) !usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    var n: usize = 0;
    for (ids) |id| {
        const node = (try st.getNodePtrHydratedChecked(id)) orelse continue;
        const v = node.properties.get("id") orelse continue;
        if (v == .Int and v.Int == key) n += 1;
    }
    return n;
}

test "SONNY-2749: programs that MERGE one key into g2 from different session graphs make one node" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g2");
    const catalog = try execution.ensureCatalogInstance(testing.allocator);

    // Each round races four writers on one new key: two start on `default`
    // and switch to g2 in the program, two start on g2. Before the fix the
    // first two held `default`'s write lock while the other two held g2's,
    // and their MERGEs ran together.
    const rounds = 150;
    var duplicated: usize = 0;
    var buf: [4][64]u8 = undefined;
    for (0..rounds) |round| {
        const key: i64 = @intCast(round);
        var go: std.atomic.Value(bool) = .init(false);
        var writers = [_]Writer{
            .{ .catalog = catalog, .session_graph = "default", .query = try std.fmt.bufPrint(&buf[0], "USE GRAPH g2; MERGE (:K {{id: {d}}})", .{key}), .go = &go },
            .{ .catalog = catalog, .session_graph = "g2", .query = try std.fmt.bufPrint(&buf[1], "MERGE (:K {{id: {d}}})", .{key}), .go = &go },
            .{ .catalog = catalog, .session_graph = "default", .query = try std.fmt.bufPrint(&buf[2], "USE GRAPH g2; MERGE (:K {{id: {d}}})", .{key}), .go = &go },
            .{ .catalog = catalog, .session_graph = "g2", .query = try std.fmt.bufPrint(&buf[3], "MERGE (:K {{id: {d}}})", .{key}), .go = &go },
        };
        var threads: [writers.len]std.Thread = undefined;
        var spawned: usize = 0;
        // On an early return, release the writers before joining them.
        defer {
            go.store(true, .release);
            for (threads[0..spawned]) |t| t.join();
        }
        for (&writers) |*w| {
            threads[spawned] = try std.Thread.spawn(.{}, Writer.run, .{w});
            spawned += 1;
        }
        go.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
        spawned = 0;
        for (writers) |w| {
            if (w.err) |err| return err;
        }
        if (try countKeyed(st, "g2", "K", key) != 1) duplicated += 1;
        try testing.expectEqual(@as(usize, 0), try countKeyed(st, default_graph, "K", key));
    }
    if (duplicated > 0) std.debug.print("{d} of {d} keys were created more than once in g2\n", .{ duplicated, rounds });
    try testing.expectEqual(@as(usize, 0), duplicated);
}

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

fn grpcExecute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

/// One gRPC Execute on its own thread.
const Exec = struct {
    ga: std.mem.Allocator,
    session_id: []const u8,
    query: []const u8,
    ok: bool = false,
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *Exec) void {
        if (grpcExecute(self.ga, self.session_id, self.query)) |resp| {
            self.ok = resp.payload != null and resp.payload.? == .schema;
        } else |_| {}
        self.done.store(true, .release);
    }
};

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// Run `query` on its own thread while `graph` is read-locked here. True when
/// it finished before the lock was released: it did not wait for `graph`.
fn ranPastReadLock(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, graph: []const u8, ok: *bool) !bool {
    const held = graph_store.acquireGraphReadLock(graph);
    var exec: Exec = .{ .ga = ga, .session_id = session_id, .query = query };
    const thread = std.Thread.spawn(.{}, Exec.go, .{&exec}) catch |err| {
        graph_store.releaseGraphLock(held);
        return err;
    };
    sleepMs(300);
    const finished = exec.done.load(.acquire);
    graph_store.releaseGraphLock(held);
    thread.join();
    ok.* = exec.ok;
    return finished;
}

fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

fn expectError(resp: schema.ExecutionResponse, code: []const u8) !void {
    const err = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => return error.ExpectedError,
    };
    try testing.expectEqualStrings(code, err.code);
}

test "SONNY-2749: over gRPC a write takes the lock of the graph it writes; several graphs are refused; the -g shape runs" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g2");
    try h.seed(&.{"CREATE (:Seed)"});

    // An anonymous session, allowed everything: locking is under test.
    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    const allow_all_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(allow_all_was);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const on_default = try sessions.createSession("", "", null, null, null, false, 0);
    const moving = try sessions.createSession("", "", null, null, null, false, 0);

    var ok = false;
    // A write after USE GRAPH g2 waits for g2's lock, then lands in g2.
    try testing.expect(!try ranPastReadLock(ga, moving, "USE GRAPH g2; CREATE (:X)", "g2", &ok));
    try testing.expect(ok);
    try testing.expectEqual(@as(usize, 1), countLabel(st, "g2", "X"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, default_graph, "X"));

    // The session is on g2 now, so a plain write locks g2 too (gRPC used to
    // lock `default` whatever graph the session was on).
    try testing.expect(!try ranPastReadLock(ga, moving, "CREATE (:Y)", "g2", &ok));
    try testing.expect(ok);
    try testing.expectEqual(@as(usize, 1), countLabel(st, "g2", "Y"));

    // Writes on two graphs in one request are refused, and nothing is written.
    try expectError(try grpcExecute(ga, moving, "CREATE (:Z); USE GRAPH default; CREATE (:Z)"), "0A000");
    try testing.expectEqual(@as(usize, 0), countLabel(st, "g2", "Z"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, default_graph, "Z"));

    // The CLI's -g shape: USE GRAPH of the session's own graph, then writes.
    {
        const resp = try grpcExecute(ga, on_default, "USE GRAPH default; CREATE (:W)");
        try testing.expect(resp.payload != null and resp.payload.? == .schema);
        try testing.expectEqual(@as(usize, 1), countLabel(st, default_graph, "W"));
    }

    // A graph that does not exist is not created by taking its lock.
    try expectError(try grpcExecute(ga, on_default, "USE GRAPH nosuch2749; CREATE (:V)"), "3F000");
    try testing.expect(!st.graphExists("nosuch2749"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, default_graph, "V"));
}
