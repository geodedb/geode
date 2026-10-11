// Fail-closed default role (2026-10).
//
// A user whose record carries no built-in role (no HAS_ROLE edge to one, not
// a superuser) used to resolve to `readwrite` (`role_resolver
// .authRoleFromRecord`): read and write on every graph, the default graph
// included, with no grant at all. That failed open.
//
// Now such a user resolves to `Role.None`: no global read, write, schema or
// admin. On a graph it holds a per-graph grant on it gets that grant's
// privileges there (grants work as granted, as docs/GQL_AUTH_DDL.md
// documents for every role), and nothing anywhere else. The handlers enforce
// it with `gps.writePermittedOn` (write on the graph the program changes) and
// `session_graph.programReadPermitted` (read on every graph the program
// touches), besides the existing `bind_graph` check.
//
// The gRPC tests run real programs through the in-process gRPC Execute
// handler with a session whose role is the one `resolveRoleFromGraph` gives a
// planted user, so they fail on the old fallback (readwrite: every read and
// write runs) and pass on the new one.
//
// CANARY: REQ=REQ-SEC-DEFAULT-ROLE-FAIL-CLOSED; FEATURE="FailClosedDefaultRole"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_default_role_fail_closed.zig; OWNER=security; UPDATED=2026-10-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const user_storage = @import("user_storage");
const harness = @import("node_scan_stream_harness.zig");

const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const role_resolver = geode.security.role_resolver;
const session_graph = geode.execution.session_graph;
const user_mgmt = geode.user_management;
const graph_store = geode.graph_store;
const Role = user_mgmt.Role;

const SECURITY_GRAPH = "__geode_security";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn makeRecord(username: []const u8, is_superuser: bool) user_storage.UserStorageBackend.UserRecord {
    var rec = std.mem.zeroes(user_storage.UserStorageBackend.UserRecord);
    rec.id = 1;
    rec.is_superuser = is_superuser;
    rec.is_active = true;
    const copy_len = @min(username.len, rec.username.len);
    @memcpy(rec.username[0..copy_len], username[0..copy_len]);
    rec.username_len = @intCast(copy_len);
    return rec;
}

/// A :User node in the security graph, with a HAS_ROLE edge to `role_name`
/// when it is given, and none (no stored role) when it is null.
fn plantUser(store: *graph_store.GraphStore, username: []const u8, role_name: ?[]const u8) !void {
    const uid = try store.createNodeWithGraph(&[_][]const u8{"User"}, SECURITY_GRAPH);
    try store.setNodeProperty(uid, "username", .{ .String = username });
    const name = role_name orelse return;
    const rid = try store.createNodeWithGraph(&[_][]const u8{"Role"}, SECURITY_GRAPH);
    try store.setNodeProperty(rid, "name", .{ .String = name });
    _ = try store.createEdgeWithGraph(uid, rid, "HAS_ROLE", SECURITY_GRAPH);
}

/// The role the persistent resolver gives `username` (planted beforehand).
fn resolvedRole(store: *graph_store.GraphStore, username: []const u8) Role {
    return role_resolver.resolveRoleFromGraph(store, makeRecord(username, false));
}

/// Per-graph grants (`GraphRBACPolicy` action codes: 0=read, 1=write,
/// 2=schema), served to gps through `execution.graph_grant_check_fn`.
const Grant = struct { user: []const u8, graph: []const u8, action: u8 };
const grants = [_]Grant{
    .{ .user = "nora_read", .graph = "g1", .action = 0 },
    .{ .user = "nora_write", .graph = "g1", .action = 0 },
    .{ .user = "nora_write", .graph = "g1", .action = 1 },
};

fn grantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    for (grants) |g| {
        if (g.action == action and std.mem.eql(u8, g.user, username) and std.mem.eql(u8, g.graph, graph_name)) return true;
    }
    return false;
}

fn testPrincipal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = null,
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

fn decideKind(p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !gps.PolicyDecisionKind {
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return (try gps.decide(testing.allocator, &req)).kind;
}

fn countIn(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
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

/// `query` through the real gRPC Execute handler, in process. Null when it
/// ran; the SQLSTATE when it was refused.
fn grpcOutcome(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?[]const u8 {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => null,
    };
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    if (try grpcOutcome(ga, session_id, query)) |code| {
        std.debug.print("expected `{s}` to run, refused with {s}\n", .{ query, code });
        return error.ExpectedToRun;
    }
}

fn expectDenied(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const code = (try grpcOutcome(ga, session_id, query)) orelse {
        std.debug.print("expected `{s}` to be refused (42501), it ran\n", .{query});
        return error.ExpectedRefusal;
    };
    try testing.expectEqualStrings("42501", code);
}

/// An in-process deployment with auth on, the grant table above, graphs
/// `default` (one :Seed), `g1` (one :C) and `g2` (one :C), and the planted
/// security graph users.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    auth_was_enabled: bool,
    prev_grant_fn: ?*const fn ([]const u8, []const u8, u8) bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        try self.h.seed(&.{"CREATE (:Seed {v: 1})"});
        const st = graph_store.getGlobalStore(testing.allocator);
        for ([_][]const u8{ "g1", "g2" }) |g| {
            _ = try st.createGraph(g);
            _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, g);
        }
        try plantUser(st, "nora", null);
        try plantUser(st, "nora_read", null);
        try plantUser(st, "nora_write", null);
        try plantUser(st, "rita", "readwrite");
        try plantUser(st, "otto", "readonly");

        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.prev_grant_fn = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = &grantCheck;

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        geode.execution.graph_grant_check_fn = self.prev_grant_fn;
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// A gRPC session for `username` with the role the persistent resolver
    /// gives it, on `graph` (null: the default graph).
    fn session(self: *World, username: []const u8, graph: ?[]const u8) ![]const u8 {
        const role = resolvedRole(graph_store.getGlobalStore(testing.allocator), username);
        return self.sessions.createSession(username, "", role, null, graph, false, 0);
    }

    fn sessionAs(self: *World, username: []const u8, role: Role, graph: ?[]const u8) ![]const u8 {
        return self.sessions.createSession(username, "", role, null, graph, false, 0);
    }
};

// ---------------------------------------------------------------------------
// Role resolution
// ---------------------------------------------------------------------------

test "a user with no stored role resolves to a role with no global permission, not readwrite" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const role = resolvedRole(graph_store.getGlobalStore(testing.allocator), "nora");
    try testing.expect(role != .ReadWrite);
    try testing.expect(!user_mgmt.hasPermission(role, .Read));
    try testing.expect(!user_mgmt.hasPermission(role, .Write));
    try testing.expect(!user_mgmt.hasPermission(role, .Schema));
    try testing.expectEqual(Role.None, role);
    // The record-only fallback (no graph to consult) is the same.
    try testing.expectEqual(Role.None, role_resolver.authRoleFromRecord(makeRecord("nora", false)));
    // `none` is the absence of a role, not one an operator can assign.
    try testing.expectEqual(@as(?Role, null), Role.fromString("none"));
}

test "the bootstrap admin and explicitly assigned roles resolve as before" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    // Bootstrap admin: a superuser record, no HAS_ROLE edge needed.
    try testing.expectEqual(Role.Admin, role_resolver.resolveRoleFromGraph(st, makeRecord("geode", true)));
    try testing.expectEqual(Role.Admin, role_resolver.authRoleFromRecord(makeRecord("geode", true)));
    try plantUser(st, "ada", "admin");
    try testing.expectEqual(Role.Admin, resolvedRole(st, "ada"));
    try testing.expectEqual(Role.ReadWrite, resolvedRole(st, "rita"));
    try testing.expectEqual(Role.ReadOnly, resolvedRole(st, "otto"));
}

// ---------------------------------------------------------------------------
// Decisions (gps)
// ---------------------------------------------------------------------------

test "gps: a user with no stored role and no grant gets no read, write, schema, bind or admin" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const role = resolvedRole(graph_store.getGlobalStore(testing.allocator), "nora");
    const p = testPrincipal("nora", &[_][]const u8{@tagName(role)});

    try testing.expect(try decideKind(&p, .read, .{ .database = {} }) != .allow);
    try testing.expect(try decideKind(&p, .write, .{ .database = {} }) != .allow);
    try testing.expect(try decideKind(&p, .read, .{ .graph = "g1" }) != .allow);
    try testing.expect(try decideKind(&p, .write, .{ .graph = "g1" }) != .allow);
    try testing.expect(try decideKind(&p, .schema, .{ .graph = "g1" }) != .allow);
    try testing.expect(try decideKind(&p, .bind_graph, .{ .graph = "g1" }) != .allow);
    try testing.expect(try decideKind(&p, .admin_user, .{ .database = {} }) != .allow);
    try testing.expect(try decideKind(&p, .admin_tenant, .{ .database = {} }) != .allow);
    try testing.expect(!gps.writePermitted(testing.allocator, &p));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &p, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &p, graph_store.DEFAULT_GRAPH_NAME));
    try testing.expect(!gps.graphReadPermitted(testing.allocator, &p, graph_store.DEFAULT_GRAPH_NAME));
}

test "gps: a READ grant gives a user with no stored role read and bind on that graph only, and no write" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const role = resolvedRole(graph_store.getGlobalStore(testing.allocator), "nora_read");
    const p = testPrincipal("nora_read", &[_][]const u8{@tagName(role)});

    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&p, .bind_graph, .{ .graph = "g1" }));
    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&p, .read, .{ .graph = "g1" }));
    try testing.expect(gps.graphReadPermitted(testing.allocator, &p, "g1"));
    try testing.expect(try decideKind(&p, .write, .{ .graph = "g1" }) != .allow);
    try testing.expect(!gps.writePermittedOn(testing.allocator, &p, "g1"));
    try testing.expect(!gps.writePermitted(testing.allocator, &p));
    try testing.expect(!gps.graphReadPermitted(testing.allocator, &p, "g2"));
    try testing.expect(try decideKind(&p, .bind_graph, .{ .graph = "g2" }) != .allow);
}

test "gps: a WRITE grant lets a user with no stored role write that graph only (grants work as granted)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const role = resolvedRole(graph_store.getGlobalStore(testing.allocator), "nora_write");
    const p = testPrincipal("nora_write", &[_][]const u8{@tagName(role)});

    try testing.expect(gps.writePermittedOn(testing.allocator, &p, "g1"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &p, "g2"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &p, graph_store.DEFAULT_GRAPH_NAME));
    // No database-wide write and no schema from a WRITE grant.
    try testing.expect(!gps.writePermitted(testing.allocator, &p));
    try testing.expect(try decideKind(&p, .schema, .{ .graph = "g1" }) != .allow);
}

test "gps: explicitly-roled principals are not grant-only and their gates are unchanged" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const rw = testPrincipal("rita", &.{"ReadWrite"});
    const ro = testPrincipal("otto", &.{"ReadOnly"});
    const user = testPrincipal("uma", &.{"User"});
    const admin = testPrincipal("ada", &.{"Admin"});
    for ([_]*const principal_mod.Principal{ &rw, &ro, &user, &admin }) |p| {
        try testing.expect(!gps.isGrantOnly(p));
        // The new gates defer to the old ones for every builtin role.
        try testing.expectEqual(gps.writePermitted(testing.allocator, p), gps.writePermittedOn(testing.allocator, p, "g2"));
        try testing.expect(gps.graphReadPermitted(testing.allocator, p, "g2"));
    }
    try testing.expect(gps.writePermittedOn(testing.allocator, &rw, "g2"));
    try testing.expect(gps.writePermittedOn(testing.allocator, &admin, "g2"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &ro, "g2"));
    try testing.expect(!gps.writePermittedOn(testing.allocator, &user, "g2"));
    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&rw, .read, .{ .database = {} }));
    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&ro, .read, .{ .database = {} }));
    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&admin, .admin_tenant, .{ .database = {} }));
    try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(&admin, .bind_graph, .{ .graph = "g2" }));
}

test "session_graph.programReadPermitted: a no-role user needs a READ grant on every graph the program reads" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const none = testPrincipal("nora_read", &[_][]const u8{@tagName(Role.None)});
    const rw = testPrincipal("rita", &.{"ReadWrite"});
    const D = graph_store.DEFAULT_GRAPH_NAME;
    const Case = struct { q: []const u8, none_ok: bool };
    const cases = [_]Case{
        .{ .q = "MATCH (n) RETURN count(n) AS c", .none_ok = false },
        .{ .q = "USE GRAPH g1; MATCH (n) RETURN count(n) AS c", .none_ok = true },
        .{ .q = "USE GRAPH g1; MATCH (n) RETURN n; USE GRAPH g2; MATCH (n) RETURN n", .none_ok = false },
        .{ .q = "RETURN 1 AS c", .none_ok = true }, // reads no store
        .{ .q = "RETURN 1 AS c; MATCH (n) RETURN n", .none_ok = false },
        .{ .q = "USE GRAPH g1", .none_ok = true }, // no data touched; bind_graph decides
    };
    for (cases) |c| {
        var parsed = try geode.parseGql(c.q, testing.allocator);
        defer parsed.deinit();
        const analysis = geode.query_traits.analyzeProgram(&parsed.program);
        const got = try session_graph.programReadPermitted(testing.allocator, &none, &parsed.program, &analysis, D, D);
        if (got != c.none_ok) {
            std.debug.print("{s}: expected {}, got {}\n", .{ c.q, c.none_ok, got });
            return error.WrongDecision;
        }
        try testing.expect(try session_graph.programReadPermitted(testing.allocator, &rw, &parsed.program, &analysis, D, D));
    }
}

// ---------------------------------------------------------------------------
// End to end: the gRPC Execute handler
// ---------------------------------------------------------------------------

test "gRPC: a user with no stored role and no grant can neither read nor write any graph" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const s = try w.session("nora", null);
    const st = graph_store.getGlobalStore(testing.allocator);
    const nodes_before = st.getNodeCount();

    try expectDenied(ga, s, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectDenied(ga, s, "CREATE (:X {v: 1})");
    try expectDenied(ga, s, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c");
    try expectDenied(ga, s, "USE GRAPH g1; CREATE (:X)");
    try expectDenied(ga, s, "CREATE GRAPH g_nora");
    try expectRuns(ga, s, "RETURN 1 AS c"); // reads no store
    try testing.expectEqual(nodes_before, st.getNodeCount());
    try testing.expect(!st.graphExists("g_nora"));

    // A session bound to g1 some other way still cannot touch it.
    const s1 = try w.session("nora", "g1");
    try expectDenied(ga, s1, "MATCH (n:C) RETURN count(n) AS c");
    try expectDenied(ga, s1, "CREATE (:X)");
    try testing.expectEqual(nodes_before, st.getNodeCount());
}

test "gRPC: a user with no stored role reads a graph it holds READ on, and cannot write it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const s = try w.session("nora_read", null);
    const st = graph_store.getGlobalStore(testing.allocator);
    const nodes_before = st.getNodeCount();

    // No grant on the default graph (where the session starts) or on g2.
    try expectDenied(ga, s, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectDenied(ga, s, "USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c");
    // The READ grant on g1. A USE GRAPH in a program moves the session.
    try expectRuns(ga, s, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c");
    try expectDenied(ga, s, "USE GRAPH g1; CREATE (:X)");
    try expectDenied(ga, s, "CREATE (:X)");
    try testing.expectEqual(nodes_before, st.getNodeCount());
}

test "gRPC: a user with no stored role writes only the graph it holds WRITE on" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const st = graph_store.getGlobalStore(testing.allocator);

    const s = try w.session("nora_write", null);
    try expectDenied(ga, s, "CREATE (:W {v: 2})"); // default graph
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:W {v: 1})");
    try testing.expectEqual(@as(usize, 1), countIn(st, "g1", "W"));
    // A session that starts on g2 (no grant there) cannot write it either.
    const s2 = try w.session("nora_write", "g2");
    try expectDenied(ga, s2, "CREATE (:W {v: 3})");
    try testing.expectEqual(@as(usize, 0), countIn(st, "g2", "W"));
    try testing.expectEqual(@as(usize, 0), countIn(st, graph_store.DEFAULT_GRAPH_NAME, "W"));
}

test "gRPC: explicitly-roled users and the admin are unchanged" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    // readwrite (stored role): reads and writes the default graph, and binds
    // any graph in a single-tenant deployment.
    const rw = try w.session("rita", null);
    try expectRuns(ga, rw, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectRuns(ga, rw, "CREATE (:R {v: 1})");
    try expectRuns(ga, rw, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c");

    // readonly (stored role): reads the default graph, cannot write.
    const ro = try w.session("otto", null);
    try expectRuns(ga, ro, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectDenied(ga, ro, "CREATE (:O {v: 1})");

    // Admin (the bootstrap admin's role): everything, graph DDL included.
    const admin = try w.sessionAs("geode", role_resolver.authRoleFromRecord(makeRecord("geode", true)), null);
    try expectRuns(ga, admin, "MATCH (n:Seed) RETURN count(n) AS c");
    try expectRuns(ga, admin, "CREATE (:A {v: 1})");
    try expectRuns(ga, admin, "CREATE GRAPH g_admin");
    try expectRuns(ga, admin, "USE GRAPH g2; CREATE (:A {v: 2})");
}
