// SONNY-2804 regression: geode.storage.stats and geode.storage.integrity take
// the graph gate.
//
// Both took a graph name from their first argument and asked the storage
// adapter directly. They are classified read-only, so no gate applied beyond
// `decide(read, procedure)`: no internal-graph refusal and no bind_graph. So
// (review probes R8-E and R8-F):
// - a ReadWrite user refused `USE GRAPH g1` read g1's node, edge and page
//   counts and its WAL position;
// - a graph that does not exist answered 42883, an existence oracle;
// - `__geode_*` graphs, the security graph included, answered too.
//
// Now the graph a call names goes through the gate every other way of
// reaching a graph takes: an internal graph is refused (42501, Admin
// included), then binding it (`session_graph.mayBind`, 42501), and only then
// whether it exists (3F000).
//
// CANARY: REQ=REQ-SONNY-2804-STORAGE-PROC-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2804_storage_procs_gate.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;

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

fn execute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

fn expectCode(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    const err = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
            return error.ExpectedRefusal;
        },
    };
    if (!std.mem.eql(u8, code, err.code)) std.debug.print("{s}: {s} {s}\n", .{ query, err.code, err.message });
    try testing.expectEqualStrings(code, err.code);
}

/// An in-process gRPC server with authorization on: graphs g1 and
/// `__geode_probe` (an internal name), and sessions for an Admin and a
/// ReadWrite user.
const Fixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    st: *graph_store.GraphStore,
    auth_was_enabled: bool,
    allow_all_was: bool,
    strict_was: bool,
    admin: []const u8 = "",
    rw: []const u8 = "",

    fn init(self: *Fixture, strict: bool) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        self.st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try self.st.createGraph("g1");
        try self.st.createGraph("__geode_probe");
        var payroll = [_][]const u8{"Payroll"};
        _ = try self.st.createNodeWithGraph(&payroll, "g1");
        var secretish = [_][]const u8{"Secretish"};
        _ = try self.st.createNodeWithGraph(&secretish, "__geode_probe");
        // A graph has storage statistics once something is stored in it.
        var other = [_][]const u8{"Other"};
        _ = try self.st.createNodeWithGraph(&other, "default");
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_all_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(strict);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("stats_admin", "", .Admin, null, null, false, 0);
        self.rw = try self.sessions.createSession("stats_rw", "", .ReadWrite, null, null, false, 0);
    }

    fn deinit(self: *Fixture) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_all_was);
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        self.h.deinit();
    }

    fn ga(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

test "SONNY-2804: a user refused a graph reads none of its storage metadata, and no graph's existence (R8-E)" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const ga = f.ga();

    try expectCode(ga, f.rw, "USE GRAPH g1", "42501");
    try expectCode(ga, f.rw, "CALL geode.storage.stats('g1')", "42501");
    try expectCode(ga, f.rw, "CALL geode.storage.integrity('g1')", "42501");
    // Permission before existence: no oracle.
    try expectCode(ga, f.rw, "CALL geode.storage.stats('nosuch2804')", "42501");
    try expectCode(ga, f.rw, "CALL geode.storage.integrity('nosuch2804')", "42501");
    // The default graph is every session's.
    try expectRuns(ga, f.rw, "CALL geode.storage.stats()");
    try expectRuns(ga, f.rw, "CALL geode.storage.stats('default')");

    // The Admin reads g1, and gets 3F000 for a graph that does not exist.
    try expectRuns(ga, f.admin, "CALL geode.storage.stats('g1')");
    try expectRuns(ga, f.admin, "CALL geode.storage.integrity('g1')");
    try expectCode(ga, f.admin, "CALL geode.storage.stats('nosuch2804')", "3F000");
}

test "SONNY-2804: no one reads an internal graph's storage metadata (R8-F), and a user who may bind a graph reads its own" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    const ga = f.ga();

    for ([_][]const u8{ f.admin, f.rw }) |s| {
        try expectCode(ga, s, "CALL geode.storage.stats('__geode_probe')", "42501");
        try expectCode(ga, s, "CALL geode.storage.integrity('__geode_probe')", "42501");
        try expectCode(ga, s, "CALL geode.storage.stats('__geode_security')", "42501");
    }
    // Single-tenant: ReadWrite may bind g1, so it may read g1's metadata.
    try expectRuns(ga, f.rw, "CALL geode.storage.stats('g1')");
    try expectRuns(ga, f.rw, "CALL geode.storage.integrity('g1')");
}
