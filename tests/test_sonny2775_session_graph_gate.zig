// SONNY-2775 regression: every change of a session's graph goes through one
// gate (`execution.session_graph`), which checks the graph permission
// (bind_graph) and that the graph exists.
//
// SESSION SET [PROPERTY] GRAPH stored any name as given. A user that USE GRAPH
// refused (`bind_graph`) could switch with it and read or write the graph.
// It did not check that the graph exists, it let a DSN-bound session leave
// its graph, and it created the test graphs G1 and G2 in production. It also
// stored the name with the request's allocator, which is not the session's.
// SESSION RESET freed the session's fields with the request's allocator, and
// took a DSN-bound session off its graph.
//
// Every test runs under the leak-checking testing allocator; the requests use
// an arena of their own, as the handlers' requests do, so a session field
// stored with the request's allocator is freed with the wrong one (a panic).
//
// CANARY: REQ=REQ-SONNY-2775-SESSION-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2775_session_graph_gate.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const session_graph = execution.session_graph;
const graph_store = geode.graph_store;
const principal_mod = geode.security.principal;
const user_mgmt = geode.user_management;

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
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

fn readerPrincipal() principal_mod.Principal {
    return principal("reader", &.{"ReadOnly"});
}

fn adminPrincipal() principal_mod.Principal {
    return principal("root", &.{"Admin"});
}

/// A session as a handler holds it: its own allocator (the testing one), a
/// graph binding, and the principal each request runs as.
const Session = struct {
    state: execution.SessionState,
    bound: bool = false,
    as: ?*const principal_mod.Principal,

    fn init(as: ?*const principal_mod.Principal) Session {
        return .{ .state = execution.SessionState.init(testing.allocator), .as = as };
    }

    fn deinit(self: *Session) void {
        self.state.deinit();
    }

    /// `query` as one request, with an arena of its own.
    fn run(self: *Session, h: *harness.Harness, query: []const u8) !void {
        var request = std.heap.ArenaAllocator.init(testing.allocator);
        defer request.deinit();
        const ra = request.allocator();
        var parsed = try geode.parseGql(query, ra);
        defer parsed.deinit();
        var ctx = h.ctx;
        ctx.session_state = &self.state;
        ctx.principal = self.as;
        ctx.graph_bound = self.bound;
        var result = try execution.executeProgramWithContext(ra, &parsed.program, ctx);
        result.deinit(ra);
    }

    fn graph(self: *const Session) []const u8 {
        return self.state.graph orelse graph_store.DEFAULT_GRAPH_NAME;
    }
};

const switches = [_][]const u8{
    "USE GRAPH hr",
    "USE hr",
    "SESSION SET GRAPH hr",
    "SESSION SET PROPERTY GRAPH hr",
    "SESSION SET GRAPH = 'hr'",
    "SESSION SET PROPERTY GRAPH \"hr\"",
};

/// A graph `hr` with one node.
fn seedHr() !*graph_store.GraphStore {
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("hr");
    var labels = [_][]const u8{"Secret"};
    const n = try st.createNodeWithGraph(&labels, "hr");
    try st.setNodeProperty(n, "v", .{ .Int = 42 });
    return st;
}

test "SONNY-2775: a user refused a graph cannot switch to it by any statement; RESET and the home and current names stay home" {
    const reader = readerPrincipal();
    const admin = adminPrincipal();
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    _ = try seedHr();

    var s = Session.init(&reader);
    defer s.deinit();
    for (switches) |query| {
        testing.expectError(error.Unauthorized, s.run(&h, query)) catch |err| {
            std.debug.print("{s}: a ReadOnly user switched to hr\n", .{query});
            return err;
        };
        try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, s.graph());
    }
    // Nothing after a refused switch runs on hr.
    try testing.expectError(error.Unauthorized, s.run(&h, "SESSION SET PROPERTY GRAPH hr; MATCH (n:Secret) RETURN n.v AS v"));

    // Neither SESSION RESET nor the home and current graph names reach hr:
    // they stay on (or go back to) the default graph, which every session
    // starts on and anyone may bind.
    const home = [_][]const u8{
        "SESSION RESET",
        "SESSION RESET GRAPH",
        "SESSION RESET ALL CHARACTERISTICS",
        "SESSION CLOSE",
        "SESSION SET GRAPH HOME_GRAPH",
        "SESSION SET PROPERTY GRAPH CURRENT_PROPERTY_GRAPH",
        "USE GRAPH CURRENT_GRAPH",
        "USE GRAPH default",
    };
    for (home) |query| {
        try s.run(&h, query);
        try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, s.graph());
    }

    // An Admin switches by every form, and back.
    var a = Session.init(&admin);
    defer a.deinit();
    for (switches) |query| {
        try a.run(&h, query);
        try testing.expectEqualStrings("hr", a.graph());
        try a.run(&h, "SESSION RESET GRAPH");
        try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, a.graph());
    }
    try a.run(&h, "USE GRAPH hr; SESSION SET GRAPH CURRENT_GRAPH");
    try testing.expectEqualStrings("hr", a.graph());
    try a.run(&h, "SESSION SET PROPERTY GRAPH HOME_PROPERTY_GRAPH");
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, a.graph());
}

test "SONNY-2775: a graph that does not exist is 3F000, the session stays, and G1 and G2 are not created" {
    const admin = adminPrincipal();
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = try seedHr();
    const nodes_before = st.getNodeCount();

    // With no principal (in process) and as an Admin, who may bind anything.
    for ([_]?*const principal_mod.Principal{ null, &admin }) |as| {
        var s = Session.init(as);
        defer s.deinit();
        try s.run(&h, "USE GRAPH hr");
        for ([_][]const u8{ "USE GRAPH nosuch", "SESSION SET GRAPH nosuch", "SESSION SET PROPERTY GRAPH nosuch", "SESSION SET PROPERTY GRAPH G1", "SESSION SET PROPERTY GRAPH G2", "SESSION SET GRAPH \"G1\"" }) |query| {
            testing.expectError(error.GraphNotFound, s.run(&h, query)) catch |err| {
                std.debug.print("{s}: expected GraphNotFound\n", .{query});
                return err;
            };
            try testing.expectEqualStrings("hr", s.graph());
        }
    }
    try testing.expect(!st.graphExists("nosuch"));
    try testing.expect(!st.graphExists("G1"));
    try testing.expect(!st.graphExists("G2"));
    try testing.expectEqual(nodes_before, st.getNodeCount());
}

test "SONNY-2775: a DSN-bound session stays on its graph: no switch, and RESET and CLOSE keep it" {
    const admin = adminPrincipal();
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = try seedHr();
    try st.createGraph("ops");

    var s = Session.init(&admin);
    defer s.deinit();
    try session_graph.set(&s.state, "ops");
    s.bound = true;
    for (switches) |query| {
        try testing.expectError(error.GraphBound, s.run(&h, query));
        try testing.expectEqualStrings("ops", s.graph());
    }
    for ([_][]const u8{ "USE GRAPH ops", "SESSION SET GRAPH ops", "SESSION RESET", "SESSION RESET GRAPH", "SESSION RESET ALL CHARACTERISTICS", "SESSION CLOSE", "SESSION SET GRAPH HOME_GRAPH" }) |query| {
        try s.run(&h, query);
        try testing.expectEqualStrings("ops", s.graph());
    }
}

test "SONNY-2775: what SESSION SET stores belongs to the session, whatever allocator the request used" {
    const admin = adminPrincipal();
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    _ = try seedHr();

    var s = Session.init(&admin);
    defer s.deinit();
    const program = [_][]const u8{
        "SESSION SET PROPERTY GRAPH hr",
        "SESSION SET TIME ZONE 'UTC'",
        "SESSION SET SCHEMA reports",
        "SESSION SET VALUE $limit = 10",
        "SESSION SET VALUE $limit = 20",
        "SESSION SET VALUE IF NOT EXISTS $limit = 30",
        "SESSION SET VALUE $other = 1",
        "SESSION RESET PARAMETER $other",
        "SESSION SET TIME ZONE 'Europe/Paris'",
        "USE GRAPH default",
        "SESSION SET GRAPH hr",
    };
    // Each statement in a request of its own: the request's arena is gone
    // before the next one reads the session.
    for (program) |query| try s.run(&h, query);
    try testing.expectEqualStrings("hr", s.graph());
    try testing.expectEqualStrings("Europe/Paris", s.state.timezone.?);
    try testing.expectEqualStrings("reports", s.state.schema.?);
    try testing.expectEqualStrings("20", s.state.parameters.get("limit").?);
    try testing.expect(s.state.parameters.get("other") == null);

    // A reset frees them with the session's allocator.
    try s.run(&h, "SESSION RESET");
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, s.graph());
    try testing.expect(s.state.timezone == null and s.state.schema == null);
    try testing.expectEqual(@as(u32, 0), s.state.parameters.count());
    // Set again; `deinit` frees them.
    try s.run(&h, "SESSION SET GRAPH hr; SESSION SET VALUE $x = 1; SESSION SET TIME ZONE 'UTC'");
}

test "SONNY-2775: HELLO's bind check is the same gate" {
    const reader = readerPrincipal();
    const admin = adminPrincipal();
    try testing.expect(session_graph.mayBind(null, "hr"));
    try testing.expect(session_graph.mayBind(&reader, graph_store.DEFAULT_GRAPH_NAME));
    try testing.expect(!session_graph.mayBind(&reader, "hr"));
    try testing.expect(session_graph.mayBind(&admin, "hr"));
}

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader_io: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader_io, allocator);
}

fn grpcExecute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn expectRefused(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !void {
    const resp = try grpcExecute(ga, session_id, query);
    const err = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
            return error.ExpectedRefusal;
        },
    };
    testing.expectEqualStrings(code, err.code) catch |e| {
        std.debug.print("{s}: {s} {s}\n", .{ query, err.code, err.message });
        return e;
    };
}

test "SONNY-2775: over gRPC a ReadOnly session cannot switch to a graph it may not bind, by any statement" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = try seedHr();

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
    const ro = try sessions.createSession("reader", "", .ReadOnly, null, null, false, 0);
    const root = try sessions.createSession("root", "", .Admin, null, null, false, 0);

    for (switches) |switch_stmt| {
        var buf: [128]u8 = undefined;
        const query = try std.fmt.bufPrint(&buf, "{s}; MATCH (n:Secret) RETURN n.v AS v", .{switch_stmt});
        try expectRefused(ga, ro, query, "42501");
    }
    // The session is still on `default`, where there is no Secret.
    {
        const resp = try grpcExecute(ga, ro, "MATCH (n:Secret) RETURN count(n) AS c");
        switch (resp.payload orelse return error.MissingPayload) {
            .schema => {},
            .@"error" => |e| {
                std.debug.print("read refused: {s}\n", .{e.message});
                return error.ReadRefused;
            },
            else => return error.UnexpectedPayload,
        }
        const entry = sessions.getEntry(ro) orelse return error.SessionMissing;
        try testing.expect(entry.state.exec_session.?.graph == null);
    }

    // A graph that does not exist is 3F000, and G1 is not created.
    try expectRefused(ga, root, "SESSION SET PROPERTY GRAPH nosuch; RETURN 1 AS c", "3F000");
    try expectRefused(ga, root, "SESSION SET PROPERTY GRAPH G1; MATCH (n) RETURN count(n) AS c", "3F000");
    try testing.expect(!st.graphExists("G1"));
}
