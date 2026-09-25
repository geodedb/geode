// SONNY-2743 regression: the transport handlers decide the lock, and whether
// the write-permission gate applies, over the WHOLE program.
//
// `query_traits.ProgramAnalysis` describes a program's LAST query. The QUIC
// handler took no lock when that query was store-free (`RETURN 1 AS c`), and
// since `is_mutation` was `needs_store_lock and isMutatingProgram(..)`, it
// skipped the write-permission gate as well: `CREATE (:X); RETURN 1 AS c`
// from a read-only principal wrote, with no lock held. Both handlers also
// skipped the gate for a program ending in EXPLAIN, and ran any program whose
// last query was a point read through the point-read view.
//
// Both handlers now take their decision from `query_traits.statementPlan` and
// run one write gate, `gps.writePermitted`. There is no in-process QUIC
// harness, so these tests drive those two functions (the exact code both
// handlers call), and the real gRPC Execute handler in process.
//
// CANARY: REQ=REQ-SONNY-2743-WHOLE-PROGRAM-GATE; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2743_whole_program_gate.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const query_traits = geode.query_traits;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const user_mgmt = geode.user_management;
const graph_store = geode.graph_store;
const Transport = query_traits.HandlerTransport;

const session_graph = graph_store.DEFAULT_GRAPH_NAME;
const both = [_]Transport{ .quic, .grpc };

/// Programs that change the store. Each ends in a store-free query, or has
/// the change after one; one prefixes the CLI's `USE GRAPH` of the session
/// graph.
const effectful = [_][]const u8{
    "CREATE (:X {v: 1}); RETURN 1 AS c",
    "MATCH (n:Seed) SET n.v = 2 RETURN n; RETURN 1 AS c",
    "MATCH (n:Seed) DELETE n; RETURN 1 AS c",
    "MERGE (:X {v: 3}); RETURN 1 AS c",
    "MATCH (n:Seed) REMOVE n.v RETURN n; RETURN 1 AS c",
    "CREATE GRAPH g2743; RETURN 1 AS c",
    "CREATE (:X); RETURN 1 + 1 AS c",
    "CREATE (:X); RETURN 'x' AS s",
    "RETURN 1 AS c; CREATE (:X)",
    "USE GRAPH default; CREATE (:X); RETURN 1 AS c",
};

fn planOf(query: []const u8, transport: Transport) !query_traits.StatementPlan {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    const analysis = query_traits.analyzeProgram(&parsed.program);
    return query_traits.statementPlan(&parsed.program, &analysis, session_graph, transport);
}

const Expect = struct {
    is_mutation: bool,
    needs_store_lock: bool,
    point_read: bool = false,
};

/// Collects every mismatch, so one run reports all of them.
const Failures = struct {
    count: usize = 0,

    fn expectPlan(self: *Failures, query: []const u8, transport: Transport, want: Expect) !void {
        const got = try planOf(query, transport);
        if (got.is_mutation == want.is_mutation and got.needs_store_lock == want.needs_store_lock and got.point_read == want.point_read) return;
        std.debug.print("{s} [{s}]: expected mutation={} lock={} point_read={}, got mutation={} lock={} point_read={}\n", .{
            query,                @tagName(transport),
            want.is_mutation,     want.needs_store_lock,
            want.point_read,      got.is_mutation,
            got.needs_store_lock, got.point_read,
        });
        self.count += 1;
    }

    fn check(self: *const Failures) !void {
        if (self.count > 0) return error.TestUnexpectedResult;
    }
};

test "SONNY-2743: a program that changes the store is gated and write-locked by both handlers, whatever its last query" {
    var f: Failures = .{};
    for (effectful) |query| {
        for (both) |t| try f.expectPlan(query, t, .{ .is_mutation = true, .needs_store_lock = true });
    }
    try f.check();
}

test "SONNY-2743: a program ending in EXPLAIN takes no lock, but a change beside it is still gated" {
    var f: Failures = .{};
    for (both) |t| {
        // The handlers only plan the EXPLAIN; nothing in the program runs.
        try f.expectPlan("CREATE (:X); EXPLAIN MATCH (n) RETURN n", t, .{ .is_mutation = true, .needs_store_lock = false });
        try f.expectPlan("EXPLAIN MATCH (n) RETURN n", t, .{ .is_mutation = false, .needs_store_lock = false });
    }
    try f.check();
}

test "SONNY-2743: only a program that does nothing else runs store-free or as a point read" {
    var f: Failures = .{};
    // Store-free: QUIC only, and only when the rest of the program at most
    // re-selects the session graph.
    try f.expectPlan("RETURN 1 AS c", .quic, .{ .is_mutation = false, .needs_store_lock = false });
    try f.expectPlan("USE GRAPH default; RETURN 1 AS c", .quic, .{ .is_mutation = false, .needs_store_lock = false });
    try f.expectPlan("USE GRAPH other; RETURN 1 AS c", .quic, .{ .is_mutation = false, .needs_store_lock = true });
    try f.expectPlan("MATCH (n:Seed) RETURN count(n) AS c; RETURN 1 AS d", .quic, .{ .is_mutation = false, .needs_store_lock = true });
    try f.expectPlan("RETURN 1 AS c", .grpc, .{ .is_mutation = false, .needs_store_lock = true });
    for (both) |t| {
        // Point read: the same rule.
        try f.expectPlan("MATCH (n:Seed {k: 1}) RETURN n", t, .{ .is_mutation = false, .needs_store_lock = true, .point_read = true });
        try f.expectPlan("USE GRAPH default; MATCH (n:Seed {k: 1}) RETURN n", t, .{ .is_mutation = false, .needs_store_lock = true, .point_read = true });
        try f.expectPlan("USE GRAPH other; MATCH (n:Seed {k: 1}) RETURN n", t, .{ .is_mutation = false, .needs_store_lock = true });
        try f.expectPlan("MATCH (n:Seed) RETURN n; MATCH (n:Seed {k: 1}) RETURN n", t, .{ .is_mutation = false, .needs_store_lock = true });
        try f.expectPlan("CREATE (:X); MATCH (n:Seed {k: 1}) RETURN n", t, .{ .is_mutation = true, .needs_store_lock = true });
    }
    try f.check();
}

fn testPrincipal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 1,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

test "SONNY-2743: the one write gate refuses a read-only principal and passes a writer" {
    const reader = testPrincipal("reader", &.{"ReadOnly"});
    const user = testPrincipal("user", &.{"User"});
    const read_write = testPrincipal("rw", &.{"ReadWrite"});
    const admin = testPrincipal("admin", &.{"Admin"});
    try testing.expect(!gps.writePermitted(testing.allocator, &reader));
    try testing.expect(!gps.writePermitted(testing.allocator, &user));
    try testing.expect(gps.writePermitted(testing.allocator, &read_write));
    try testing.expect(gps.writePermitted(testing.allocator, &admin));
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

/// `query` through the real gRPC Execute handler, in process.
fn grpcExecute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn countLabel(st: *graph_store.GraphStore, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, label) orelse return 0;
    return ids.len;
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
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

test "SONNY-2743: over gRPC a read-only session's changes are refused and the store is unchanged; its reads run; a writer's run under the write lock" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(&.{"CREATE (:Seed {v: 1, k: 1})"});
    const st = graph_store.getGlobalStore(testing.allocator);

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const reader = try sessions.createSession("reader", "", .ReadOnly, null, null, false, 0);
    const writer = try sessions.createSession("writer", "", .ReadWrite, null, null, false, 0);

    const nodes_before = st.getNodeCount();
    for (effectful) |query| {
        const resp = try grpcExecute(ga, reader, query);
        const err = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| e,
            else => {
                std.debug.print("{s}: a read-only session was not refused\n", .{query});
                return error.ExpectedRefusal;
            },
        };
        try testing.expectEqualStrings("42501", err.code);
        try testing.expect(std.mem.indexOf(u8, err.message, "Permission denied") != null);
    }
    // Nothing reached the store.
    try testing.expectEqual(nodes_before, st.getNodeCount());
    try testing.expectEqual(@as(usize, 1), countLabel(st, "Seed"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, "X"));
    try testing.expect(!st.graphExists("g2743"));
    {
        const seed_id = (st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Seed") orelse return error.SeedMissing)[0];
        const v = (st.getNodePtrHydrated(seed_id) orelse return error.SeedMissing).properties.get("v") orelse return error.PropertyLost;
        try testing.expectEqual(@as(i64, 1), v.Int);
    }

    // The same session's pure-read multi-statement program runs.
    {
        const resp = try grpcExecute(ga, reader, "MATCH (n:Seed) RETURN count(n) AS c; RETURN 1 AS d");
        switch (resp.payload orelse return error.MissingPayload) {
            .schema => {},
            .@"error" => |e| {
                std.debug.print("pure read refused: {s}\n", .{e.message});
                return error.ReadRefused;
            },
            else => return error.UnexpectedPayload,
        }
    }

    // A writer's program ending in a store-free query takes the write lock:
    // with the graph read-locked elsewhere, it waits, then runs.
    const held = graph_store.acquireGraphReadLock(graph_store.DEFAULT_GRAPH_NAME);
    var exec: Exec = .{ .ga = ga, .session_id = writer, .query = "CREATE (:X {v: 1}); RETURN 1 AS c" };
    const thread = std.Thread.spawn(.{}, Exec.go, .{&exec}) catch |err| {
        graph_store.releaseGraphLock(held);
        return err;
    };
    sleepMs(300);
    const finished_while_held = exec.done.load(.acquire);
    graph_store.releaseGraphLock(held);
    thread.join();
    try testing.expect(!finished_while_held);
    try testing.expect(exec.ok);
    try testing.expectEqual(@as(usize, 1), countLabel(st, "X"));
}
