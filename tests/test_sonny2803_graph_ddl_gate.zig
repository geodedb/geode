// SONNY-2803 regression: graph DDL needs the schema permission on the graph
// it changes.
//
// The only gate for a program that changes the store was the handlers' write
// gate, `gps.writePermitted`: write on the database. The executor's CREATE
// GRAPH, DROP GRAPH and index and constraint DDL checked no principal and no
// graph. So a ReadWrite user refused `USE GRAPH g1` (strict tenancy) could
// `DROP GRAPH g1` (review probe R8-E), and ReadWrite, which has no Schema
// permission (TestAuthz_ReadWrite_CannotDropGraph), could create and drop any
// graph, index or constraint.
//
// Now each of them needs `decide(schema, graph)` and `bind_graph` on the
// graph it changes (`execution.session_graph.maySchema`), checked before the
// graph's (or the index's) existence: 42501 either way for a caller refused.
// Schema is Admin's builtin permission; a GPS policy `FOR SCHEMA` on a graph
// grants it on that graph.
//
// CANARY: REQ=REQ-SONNY-2803-GRAPH-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2803_graph_ddl_gate.zig; OWNER=security; UPDATED=2026-09-26

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
const policy_catalog = geode.security.policy_catalog;

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

fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

fn indexExists(name: []const u8) !bool {
    const cat = try geode.execution.ensureCatalogInstance(testing.allocator);
    var it = cat.indexes.valueIterator();
    while (it.next()) |info| {
        if (std.mem.eql(u8, info.name, name)) return true;
    }
    return false;
}

/// An in-process gRPC server with authorization on: graphs g1 (two :Payroll
/// nodes) and g2, and sessions for an Admin, a ReadWrite and a ReadOnly user.
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
    ro: []const u8 = "",

    fn init(self: *Fixture, strict: bool) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        self.st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try self.st.createGraph("g1");
        try self.st.createGraph("g2");
        var labels = [_][]const u8{"Payroll"};
        _ = try self.st.createNodeWithGraph(&labels, "g1");
        _ = try self.st.createNodeWithGraph(&labels, "g1");
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_all_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(strict);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("ddl_admin", "", .Admin, null, null, false, 0);
        self.rw = try self.sessions.createSession("ddl_rw", "", .ReadWrite, null, null, false, 0);
        self.ro = try self.sessions.createSession("ddl_ro", "", .ReadOnly, null, null, false, 0);
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

test "SONNY-2803: a ReadWrite user refused a graph cannot drop it, and learns nothing about graphs that do not exist (R8-E)" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const ga = f.ga();

    // Strict tenancy: no grant, no bind.
    try expectCode(ga, f.rw, "USE GRAPH g1; MATCH (n) RETURN count(n) AS c", "42501");
    try expectCode(ga, f.rw, "DROP GRAPH g1", "42501");
    try testing.expect(f.st.graphExists("g1"));
    try testing.expectEqual(@as(usize, 2), countLabel(f.st, "g1", "Payroll"));
    // Permission comes before existence: the same answer for a graph that
    // does not exist, and for one to create.
    try expectCode(ga, f.rw, "DROP GRAPH nosuch2803", "42501");
    try expectCode(ga, f.rw, "DROP GRAPH IF EXISTS nosuch2803", "42501");
    try expectCode(ga, f.rw, "CREATE GRAPH g2803", "42501");
    try testing.expect(!f.st.graphExists("g2803"));

    // ReadOnly: the write gate refuses before the DDL gate.
    try expectCode(ga, f.ro, "DROP GRAPH g2", "42501");
    try testing.expect(f.st.graphExists("g2"));

    // Admin may, and gets 3F000 for a graph that does not exist.
    try expectCode(ga, f.admin, "DROP GRAPH nosuch2803", "3F000");
    try expectRuns(ga, f.admin, "CREATE GRAPH g2803");
    try testing.expect(f.st.graphExists("g2803"));
    try expectRuns(ga, f.admin, "DROP GRAPH g2803");
    try testing.expect(!f.st.graphExists("g2803"));
}

test "SONNY-2803: ReadWrite, which may bind every graph in a single-tenant deployment, still needs the schema permission for graph, index and constraint DDL" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    const ga = f.ga();

    // The user may bind g1 and write to it...
    try expectRuns(ga, f.rw, "USE GRAPH g1; CREATE (:Payroll {k: 3})");
    try expectRuns(ga, f.rw, "USE GRAPH default");
    // ...but not change its schema.
    try expectCode(ga, f.rw, "DROP GRAPH g1", "42501");
    try testing.expect(f.st.graphExists("g1"));
    try expectCode(ga, f.rw, "CREATE GRAPH g2803", "42501");
    try testing.expect(!f.st.graphExists("g2803"));
    try expectCode(ga, f.rw, "USE GRAPH g1; CREATE INDEX payroll_k_2803 FOR (n:Payroll) ON (n.k)", "42501");
    try testing.expect(!try indexExists("payroll_k_2803"));
    try expectCode(ga, f.rw, "USE GRAPH g1; CREATE CONSTRAINT payroll_k_unique FOR (n:Payroll) REQUIRE n.k IS UNIQUE", "42501");

    // The Admin creates an index; the ReadWrite user cannot drop it, nor
    // probe index names (the same answer for one that does not exist).
    try expectRuns(ga, f.admin, "CREATE INDEX payroll_k_2803 FOR (n:Payroll) ON (n.k)");
    try testing.expect(try indexExists("payroll_k_2803"));
    try expectCode(ga, f.rw, "DROP INDEX payroll_k_2803", "42501");
    try expectCode(ga, f.rw, "DROP INDEX no_such_index_2803", "42501");
    try testing.expect(try indexExists("payroll_k_2803"));
    try expectRuns(ga, f.admin, "DROP INDEX payroll_k_2803");
    try testing.expect(!try indexExists("payroll_k_2803"));
}

test "SONNY-2803: a GPS policy FOR SCHEMA on one graph lets a non-admin change that graph, and no other" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    const ga = f.ga();

    // An allow policy `FOR SCHEMA` on g1, for everyone (USING true).
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    const schema_action = [_]policy_catalog.Action{.schema};
    try cat.addPolicy(.{
        .name = "schema_g1_2803",
        .scope_graph = "g1",
        .actions = &schema_action,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    try expectCode(ga, f.rw, "DROP GRAPH g2", "42501");
    try testing.expect(f.st.graphExists("g2"));
    try expectRuns(ga, f.rw, "DROP GRAPH g1");
    try testing.expect(!f.st.graphExists("g1"));
}
