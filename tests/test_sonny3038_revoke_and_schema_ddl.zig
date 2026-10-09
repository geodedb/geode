// SONNY-3038 (the two items for v0.8.23; the rest of the ticket is v0.8.24):
//
// 1. `geode.auth.revoke` reported "Revoked ..." when the durable revoke
//    failed (the persistence callback's error was logged and skipped), and
//    the privilege came back at the next start. It now fails the call
//    (`RevokeNotPersisted`, 58030). The failure is injected through the grant
//    persistence callbacks.
// 2. CREATE SCHEMA and DROP SCHEMA were ungated. They now need the schema
//    permission on the database (Admin, or a GPS FOR SCHEMA policy on `*`),
//    like index and constraint DDL (SONNY-3030).
//
// CANARY: REQ=REQ-SONNY-3038-REVOKE-DURABLE; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3038_revoke_and_schema_ddl.zig; OWNER=security; UPDATED=2026-09-27
// CANARY: REQ=REQ-SONNY-3038-SCHEMA-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3038_revoke_and_schema_ddl.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;
const auth_dispatch = geode.auth_dispatch;

// ---------------------------------------------------------------------------
// 1. geode.auth.revoke
// ---------------------------------------------------------------------------

var revoke_calls: usize = 0;

fn resolveUser(_: ?*anyopaque, username: []const u8) ?u64 {
    return if (std.mem.eql(u8, username, "alice")) 42 else null;
}

fn revokeFails(_: ?*anyopaque, _: u64, _: []const u8, _: u8) anyerror!bool {
    revoke_calls += 1;
    return error.InjectedRevokeWriteFailure;
}

fn revokeSucceeds(_: ?*anyopaque, _: u64, _: []const u8, _: u8) anyerror!bool {
    revoke_calls += 1;
    return true;
}

test "SONNY-3038: geode.auth.revoke fails (58030) when the revoke cannot be saved, and reports success only when it is" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer auth_dispatch.setGrantPersistCallbacks(.{});
    const ga = f.ga();
    const s = try f.session("revoker");

    auth_dispatch.setGrantPersistCallbacks(.{ .resolve_user_id_fn = &resolveUser, .revoke_fn = &revokeFails });
    revoke_calls = 0;
    _ = try fx.expectRefused(ga, s, "CALL geode.auth.revoke('READ', 'alice', 'g1')", "58030");
    try testing.expectEqual(@as(usize, 1), revoke_calls);
    // Every action of ALL is attempted; the failure still fails the call.
    revoke_calls = 0;
    _ = try fx.expectRefused(ga, s, "CALL geode.auth.revoke('ALL', 'alice', 'g1')", "58030");
    try testing.expectEqual(@as(usize, 3), revoke_calls);

    auth_dispatch.setGrantPersistCallbacks(.{ .resolve_user_id_fn = &resolveUser, .revoke_fn = &revokeSucceeds });
    try fx.expectRuns(ga, s, "CALL geode.auth.revoke('READ', 'alice', 'g1')");
}

// ---------------------------------------------------------------------------
// 2. CREATE / DROP SCHEMA
// ---------------------------------------------------------------------------

/// Authorization on, an Admin and a ReadWrite session, and FOR SCHEMA allow
/// policies on the graphs g1 and default (not on `*`).
const AuthFixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    cat: policy_catalog.PolicyCatalog,
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,
    admin: []const u8 = "",
    rw: []const u8 = "",

    fn init(self: *AuthFixture) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        const st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try st.createGraph("g1");
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("sch_admin", "", .Admin, null, null, false, 0);
        self.rw = try self.sessions.createSession("sch_rw", "", .ReadWrite, null, null, false, 0);
        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        const schema_action = [_]policy_catalog.Action{.schema};
        try self.cat.addPolicy(.{ .name = "schema_g1_3038", .scope_graph = "g1", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
        try self.cat.addPolicy(.{ .name = "schema_default_3038", .scope_graph = "default", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
        policy_catalog.setGlobalCatalog(&self.cat);
    }

    fn deinit(self: *AuthFixture) void {
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }
};

fn schemaExists(name: []const u8) !bool {
    const cat = try geode.execution.ensureCatalogInstance(testing.allocator);
    return cat.hasSchema(name);
}

test "SONNY-3038: CREATE and DROP SCHEMA need the schema permission on the database" {
    var f: AuthFixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.arena.allocator();

    // A FOR SCHEMA grant on some graphs is not enough, before or after the
    // schema exists.
    _ = try fx.expectRefused(ga, f.rw, "CREATE SCHEMA s3038", "42501");
    try testing.expect(!try schemaExists("s3038"));
    try fx.expectRuns(ga, f.admin, "CREATE SCHEMA s3038");
    try testing.expect(try schemaExists("s3038"));
    _ = try fx.expectRefused(ga, f.rw, "DROP SCHEMA s3038", "42501");
    _ = try fx.expectRefused(ga, f.rw, "DROP SCHEMA no_such_3038", "42501");
    try testing.expect(try schemaExists("s3038"));

    // One on `*` is.
    const schema_action = [_]policy_catalog.Action{.schema};
    try f.cat.addPolicy(.{ .name = "schema_all_3038", .scope_graph = "*", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
    try fx.expectRuns(ga, f.rw, "DROP SCHEMA s3038");
    try testing.expect(!try schemaExists("s3038"));
    try fx.expectRuns(ga, f.rw, "CREATE SCHEMA s3038b");
    try fx.expectRuns(ga, f.admin, "DROP SCHEMA s3038b");
}
