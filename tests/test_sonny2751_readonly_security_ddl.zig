// SONNY-2751: a read-only request (`ExecuteRequest.read_only`) must refuse
// every statement that changes stored state, the security DDL included.
//
// The statement classifier (`query_traits.statementPlan`, through the one
// write walk in `execution/write_walk.zig`) counted CREATE / ALTER / DROP
// USER, CREATE / DROP ROLE, GRANT, REVOKE and CREATE / ALTER / DROP POLICY
// as reads, so the read-only floor both transports apply let an Admin
// session marked read-only create users, grant privileges and install
// policies. `CALL geode.auth.grant_list()`, which only reads, was the
// opposite: missing from the read-only procedure list, it counted as a
// change and a read-only request could not list grants.
//
// The statements run through the in-process gRPC Execute handler with
// authorization on, as an Admin session, with `read_only` set. The QUIC
// handler takes the same decision from the same `statementPlan`; the MCP
// read-only mode's classifier is covered by
// tests/test_sonny2751_readonly_security_ddl_mcp.zig.
//
// CANARY: REQ=REQ-SONNY-2751-READ-ONLY-SECURITY-DDL; FEATURE="ReadOnlyExecute"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2751_readonly_security_ddl.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;
const mgs = geode.multi_graph_security;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const READ: u8 = 0;
const HMAC_KEY = [_]u8{0x51} ** 32;

// ---------------------------------------------------------------------------
// The persistence callbacks, wired as server_init wires them
// ---------------------------------------------------------------------------

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

fn grantResolveUserId(ctx: ?*anyopaque, username: []const u8) ?u64 {
    return agmOf(ctx).findUserIdByName(username) catch null;
}

fn grantApply(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, actions: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.grantGraphPermissionsWriteThrough(&agm.hmac_key, mgs.getGlobalPolicy(), user_id, graph_name, actions);
}

fn grantRevoke(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!bool {
    const agm = agmOf(ctx);
    return agm.revokeGraphPermissionWriteThrough(&agm.hmac_key, mgs.getGlobalPolicy(), user_id, graph_name, action);
}

fn grantList(ctx: ?*anyopaque, allocator: std.mem.Allocator, user_id: u64) anyerror![]auth_dispatch.GrantEntry {
    const grants = try agmOf(ctx).listGraphGrantsForUser(allocator, user_id);
    defer allocator.free(grants);
    return auth_dispatch.grantEntriesFrom(allocator, grants);
}

fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

fn graphGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const agm = AuthGraphManager.getGlobal() orelse return false;
    const uid = (agm.findUserIdByName(username) catch null) orelse return false;
    const pol = mgs.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

// ---------------------------------------------------------------------------
// The deployment
// ---------------------------------------------------------------------------

/// Authorization on; graphs g1 and g2; a `__geode_security` store with users
/// alice and bob (alice holds READ on g2); a live grant table; a policy
/// catalog holding the allow policy `ro_keep`; an Admin session.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    pol: mgs.GraphRBACPolicy,
    cat: policy_catalog.PolicyCatalog,
    alice_id: u64 = 0,
    admin: []const u8 = "",
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,
    prev_pol: ?*mgs.GraphRBACPolicy,
    prev_check: @TypeOf(geode.execution.graph_grant_check_fn),

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        const st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try st.createGraph("g1");
        try st.createGraph("g2");
        _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, "g1");
        _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, graph_store.DEFAULT_GRAPH_NAME);

        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);
        self.alice_id = try self.agm.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash", false);
        _ = try self.agm.createUser(&HMAC_KEY, "bob", "bob@example.com", "not_a_real_hash", false);

        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);
        self.prev_check = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = &graphGrantCheck;
        try self.agm.grantGraphPermissionsWriteThrough(&HMAC_KEY, &self.pol, self.alice_id, "g2", &[_]u8{READ});

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        const write = [_]policy_catalog.Action{.write};
        try self.cat.addPolicyStrict(.{ .name = "ro_keep", .scope_graph = "g1", .actions = &write, .effect = .allow, .expression_source = "true", .enabled = true });

        auth_dispatch.setGrantPersistCallbacks(.{
            .ctx = @ptrCast(&self.agm),
            .resolve_user_id_fn = &grantResolveUserId,
            .grant_fn = &grantApply,
            .revoke_fn = &grantRevoke,
            .list_fn = &grantList,
        });
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "alice", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
        try user_mgmt.createUserWithHash(testing.allocator, "bob", "not_a_real_hash", "bob@example.com", .ReadOnly, false);
        user_mgmt.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root2751", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        user_mgmt.deinitUserStore();
        auth_dispatch.setGrantPersistCallbacks(.{});
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        geode.execution.graph_grant_check_fn = self.prev_check;
        mgs.setGlobalPolicy(self.prev_pol);
        self.pol.deinit();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// What the request could have changed, at one point in time.
    const Snapshot = struct {
        alice_role: user_mgmt.Role,
        alice_active: bool,
        alice_password: u64,
        bob_exists: bool,
        ro_new_exists: bool,
        ro_proc_exists: bool,
        sec_nodes: usize,
        sec_edges: usize,
        policies: usize,
        ro_keep_enabled: ?bool,
        ro_pol_exists: bool,
        alice_g2: bool,
        alice_g1: bool,
        data_nodes: usize,
        g_ro_exists: bool,
        g2_exists: bool,
    };

    fn snapshot(self: *World) Snapshot {
        const st = graph_store.getGlobalStore(testing.allocator);
        const alice = user_mgmt.getUser("alice").?;
        return .{
            .alice_role = alice.role,
            .alice_active = alice.active,
            .alice_password = std.hash.Wyhash.hash(0, alice.password_hash),
            .bob_exists = user_mgmt.getUser("bob") != null,
            .ro_new_exists = user_mgmt.getUser("ro_new") != null,
            .ro_proc_exists = user_mgmt.getUser("ro_proc") != null,
            .sec_nodes = self.sec_store.getNodeCount(),
            .sec_edges = self.sec_store.getEdgeCount(),
            .policies = self.cat.listPolicies().len,
            .ro_keep_enabled = if (self.policy("ro_keep")) |p| p.enabled else null,
            .ro_pol_exists = self.policy("ro_pol") != null,
            .alice_g2 = self.pol.hasGraphGrant(self.alice_id, "g2", READ),
            .alice_g1 = self.pol.hasGraphGrant(self.alice_id, "g1", READ),
            .data_nodes = st.getNodeCount(),
            .g_ro_exists = st.graphExists("g_ro"),
            .g2_exists = st.graphExists("g2"),
        };
    }

    fn policy(self: *World, name: []const u8) ?*const policy_catalog.Policy {
        for (self.cat.listPolicies()) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

fn executeReadOnly(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try fx.encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty, .read_only = true });
    return fx.decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

/// `query`, sent read-only, is refused by the read-only floor: 42501 with
/// the floor's message, not some later error.
fn expectReadOnlyRefusal(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try executeReadOnly(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            if (!std.mem.eql(u8, e.code, "42501") or std.mem.indexOf(u8, e.message, "Read-only request") == null) {
                std.debug.print("read-only `{s}`: refused {s} '{s}', not by the read-only floor\n", .{ query, e.code, e.message });
                return error.NotRefusedByReadOnlyFloor;
            }
        },
        else => {
            std.debug.print("read-only `{s}`: ran\n", .{query});
            return error.ReadOnlyRequestRan;
        },
    }
}

fn expectReadOnlyRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try executeReadOnly(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("read-only `{s}`: refused {s} '{s}'\n", .{ query, e.code, e.message });
            return error.ReadOnlyReadRefused;
        },
        else => {},
    }
}

/// Every statement that changes stored security state.
const security_ddl = [_][]const u8{
    "CREATE USER ro_new SET PASSWORD 'Ro-Passw0rd-1' ROLE readonly",
    "ALTER USER alice SET PASSWORD 'Ro-Passw0rd-2'",
    "ALTER USER alice SET ROLE readwrite",
    "ALTER USER alice DISABLE",
    "ALTER USER alice ENABLE",
    "DROP USER bob",
    "DROP USER IF EXISTS nobody",
    "CREATE ROLE ro_role SET DESCRIPTION 'x'",
    "DROP ROLE IF EXISTS ro_role",
    "GRANT ROLE readwrite TO alice",
    "GRANT READ ON GRAPH g1 TO alice",
    "GRANT ALL ON GRAPH g1 TO alice",
    "REVOKE READ ON GRAPH g2 FROM alice",
    "CREATE POLICY ro_pol ON GRAPH * FOR READ",
    "ALTER POLICY ro_keep RENAME TO ro_moved",
    "ALTER POLICY ro_keep SET ENABLED false",
    "DROP POLICY ro_keep",
    "DROP POLICY IF EXISTS ro_keep",
};

/// Every other kind of change, and the procedures that change something
/// (an unknown procedure counts as one: fail closed).
const other_changes = [_][]const u8{
    "CREATE (:RO {v: 1})",
    "INSERT (:RO {v: 2})",
    "MERGE (:RO {k: 1})",
    "MATCH (n:C) SET n.v = 1",
    "MATCH (n:C) REMOVE n.v",
    "MATCH (n:C) DETACH DELETE n",
    "MATCH (n:C) WITH n MATCH (m:C) SET m.w = 1",
    "PROFILE CREATE (:RO {v: 3})",
    "CREATE GRAPH g_ro",
    "DROP GRAPH g2",
    "CREATE INDEX ro_idx FOR (n:C) ON (n.v)",
    "CALL geode.auth.user_create('ro_proc', 'Ro-Passw0rd-3')",
    "CALL geode.auth.grant('alice', 'g1', 'READ')",
    "CALL geode.auth.policy_delete('ro_keep')",
    "CALL geode.ts.insert(1, 'm', 1, 1)",
    "CALL geode.fts.rebuild('ro_fts')",
    "CALL geode.tenant.create('ro_tenant')",
    "CALL geode.no_such.procedure()",
    "BACKUP TO '/tmp/sonny2751.bak'",
};

/// Reads, and statements that change only the session.
/// SHOW USERS and `geode.auth.user_list` are in `user_list_reads`.
const reads = [_][]const u8{
    "SHOW ROLES",
    "SHOW GRANTS",
    "SHOW GRANTS FOR alice",
    "SHOW PERMISSIONS",
    "SHOW PERMISSIONS FOR alice",
    "SHOW POLICIES",
    "CALL geode.auth.grant_list('alice')",
    "CALL geode.auth.policy_list()",
    "CALL geode.auth.role_list()",
    "CALL geode.auth.user_permissions('alice')",
    "MATCH (n:C) RETURN count(n) AS c",
    "RETURN 1 AS x",
    "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c",
    "SESSION SET PROPERTY GRAPH g1",
    "EXPLAIN MATCH (n:C) RETURN n",
    "EXPLAIN POLICY FOR MATCH (n:C) RETURN n",
};

test "SONNY-2751: a read-only Admin request refuses every security DDL statement, and nothing changes in memory or in __geode_security" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const before = w.snapshot();
    for (security_ddl) |q| {
        try expectReadOnlyRefusal(ga, w.admin, q);
        try testing.expectEqualDeep(before, w.snapshot());
    }
    // A user's own password change: the handlers take it from the raw text,
    // before the parser (GAP-0284), so it never reached the read-only floor.
    const alice = try w.sessions.createSession("alice", "", .ReadOnly, null, null, false, 0);
    try expectReadOnlyRefusal(ga, alice, "ALTER USER alice SET PASSWORD 'Correct-Horse-Battery-Staple-2751'");
    try testing.expectEqualDeep(before, w.snapshot());
    try w.agm.verifyChain(&HMAC_KEY);
    try testing.expect(user_mgmt.getUser("ro_new") == null);
    try testing.expect(w.policy("ro_keep") != null);
    try testing.expect(w.policy("ro_pol") == null);
}

test "SONNY-2751: a read-only request refuses every data, schema, procedure and backup change, an unknown procedure included" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const before = w.snapshot();
    for (other_changes) |q| {
        try expectReadOnlyRefusal(ga, w.admin, q);
        try testing.expectEqualDeep(before, w.snapshot());
    }
}

test "SONNY-2751: a read-only request still runs every read: SHOW, the read-only auth procedures, MATCH, session statements, EXPLAIN" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const before = w.snapshot();
    for (reads) |q| try expectReadOnlyRuns(ga, w.admin, q);
    try testing.expectEqualDeep(before, w.snapshot());
}

/// The user listing. `user_management.listUsers` handed `handleUserList` a
/// snapshot allocated with the user store's allocator that nothing freed (a
/// separate defect, reported with SONNY-2751 and fixed by SONNY-6312). The
/// store runs on smp_allocator in this test: what is checked is that a
/// read-only request may list users.
const user_list_reads = [_][]const u8{
    "SHOW USERS",
    "CALL geode.auth.user_list()",
};

test "SONNY-2751: a read-only request still lists users" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    user_mgmt.deinitUserStore();
    try user_mgmt.initUserStore(std.heap.smp_allocator);
    try user_mgmt.createUserWithHash(std.heap.smp_allocator, "alice", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
    for (user_list_reads) |q| try expectReadOnlyRuns(ga, w.admin, q);
}

test "SONNY-2751: without read_only the same Admin runs the security DDL (the refusal is the floor's)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "CREATE USER ro_new SET PASSWORD 'Ro-Passw0rd-1' ROLE readonly");
    try testing.expect(user_mgmt.getUser("ro_new") != null);
    try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");
    try testing.expect(w.pol.hasGraphGrant(w.alice_id, "g1", READ));
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.grant_list('alice')");
}

test "SONNY-2751: QUIC and gRPC take the read-only decision from the same plan: every change counts, no read does" {
    const D = graph_store.DEFAULT_GRAPH_NAME;
    const Want = struct { q: []const u8, changes: bool };
    var cases = std.ArrayList(Want).empty;
    defer cases.deinit(testing.allocator);
    for (security_ddl) |q| try cases.append(testing.allocator, .{ .q = q, .changes = true });
    for (other_changes) |q| try cases.append(testing.allocator, .{ .q = q, .changes = true });
    for (reads) |q| try cases.append(testing.allocator, .{ .q = q, .changes = false });
    for (user_list_reads) |q| try cases.append(testing.allocator, .{ .q = q, .changes = false });
    for (cases.items) |c| {
        var parsed = try geode.parseGql(c.q, testing.allocator);
        defer parsed.deinit();
        const analysis = geode.query_traits.analyzeRequest(&parsed.program);
        for ([_]geode.query_traits.HandlerTransport{ .quic, .grpc }) |t| {
            const plan = geode.query_traits.statementPlan(&parsed.program, &analysis, D, D, t);
            if (plan.changes_state != c.changes) {
                std.debug.print("{s} `{s}`: changes_state={}, want {}\n", .{ @tagName(t), c.q, plan.changes_state, c.changes });
                return error.WrongClassification;
            }
        }
        try testing.expectEqual(c.changes, geode.query_traits.changesStoredState(&parsed.program));
    }
}

test "SONNY-2751: the security DDL is not a data change: no write lock, no write gate" {
    const D = graph_store.DEFAULT_GRAPH_NAME;
    for (security_ddl) |q| {
        var parsed = try geode.parseGql(q, testing.allocator);
        defer parsed.deinit();
        const analysis = geode.query_traits.analyzeRequest(&parsed.program);
        const plan = geode.query_traits.statementPlan(&parsed.program, &analysis, D, D, .grpc);
        try testing.expect(!plan.is_mutation);
        try testing.expect(plan.actions.security);
        try testing.expect(!geode.query_traits.isMutatingProgram(&parsed.program));
    }
}
