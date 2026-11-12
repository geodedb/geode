// SONNY-1333: a GRANT, REVOKE or CREATE USER whose write to the HMAC-chained
// `__geode_security` graph fails must answer an error and leave the live
// authorization state consistent with what is stored; and `SHOW GRANTS
// [FOR <user>]` must show a user's per-graph grants so a grant can be checked
// after the fact.
//
// Before the fix:
//   - `geode.auth.grant` (and `GRANT ... ON GRAPH`) logged a failed save and
//     answered "Granted ...". A save that failed before the live table was
//     updated granted nothing although the statement said it had; one that
//     failed after the store write (the live-table insert) left a stored grant
//     the session did not have, which appeared at the next start.
//   - `REVOKE` whose save failed answered 58030 but left the privilege in
//     force until the restart.
//   - `CREATE USER` whose save failed answered "created <user>": the user
//     could log in until the restart, then was gone.
//   - `SHOW GRANTS` needed FOR, and listed only policies, never a GRANT.
//
// The failures are injected as one failed allocation, at every allocation in
// turn, under the `__geode_security` AuthGraphManager (its record maps, the
// HMAC chain seal, the user cache) or under the live grant table
// (GraphRBACPolicy), and the
// statements run through the in-process gRPC Execute handler with
// authorization on. The persistence callbacks are wired to the real
// AuthGraphManager and GraphRBACPolicy the way `server_init` wires them.
//
// CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
// CANARY: REQ=REQ-SONNY-1333-SHOW-GRANTS; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11

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
const WRITE: u8 = 1;
const SCHEMA: u8 = 2;

const HMAC_KEY = [_]u8{0x13} ** 32;

// ---------------------------------------------------------------------------
// Fault injection: one allocation fails, the rest succeed
// ---------------------------------------------------------------------------

/// Fails exactly one allocation, the `offset`-th after `arm`, and lets every
/// other one through (std.testing.FailingAllocator keeps failing once it
/// starts, which no undo can survive). A transient failure: what a full disk,
/// a lost WAL write or a short-lived memory shortage looks like to the caller.
const OneFailure = struct {
    inner: std.mem.Allocator,
    count: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    failed: bool = false,

    fn allocator(self: *OneFailure) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn arm(self: *OneFailure, offset: usize) void {
        self.fail_at = self.count + offset;
        self.failed = false;
    }

    fn disarm(self: *OneFailure) void {
        self.fail_at = std.math.maxInt(usize);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        if (!self.failed and self.count == self.fail_at) {
            self.failed = true;
            return null;
        }
        self.count += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

// ---------------------------------------------------------------------------
// The persistence callbacks, wired as server_init wires them
// ---------------------------------------------------------------------------

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.grantResolveUserId`.
fn grantResolveUserId(ctx: ?*anyopaque, username: []const u8) ?u64 {
    return agmOf(ctx).findUserIdByName(username) catch null;
}

/// `server_init.grantApply`.
fn grantApply(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, actions: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.grantGraphPermissionsWriteThrough(&agm.hmac_key, mgs.getGlobalPolicy(), user_id, graph_name, actions);
}

/// `server_init.grantRevoke`.
fn grantRevoke(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!bool {
    const agm = agmOf(ctx);
    return agm.revokeGraphPermissionWriteThrough(&agm.hmac_key, mgs.getGlobalPolicy(), user_id, graph_name, action);
}

/// `server_init.grantList`.
fn grantList(ctx: ?*anyopaque, allocator: std.mem.Allocator, user_id: u64) anyerror![]auth_dispatch.GrantEntry {
    const grants = try agmOf(ctx).listGraphGrantsForUser(allocator, user_id);
    defer allocator.free(grants);
    return auth_dispatch.grantEntriesFrom(allocator, grants);
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

/// `server_init.graphGrantCheck`.
fn graphGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const agm = AuthGraphManager.getGlobal() orelse return false;
    const uid = (agm.findUserIdByName(username) catch null) orelse return false;
    const pol = mgs.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

// ---------------------------------------------------------------------------
// The deployment
// ---------------------------------------------------------------------------

/// Authorization on, graphs g1 and g2, a `__geode_security` store and a live
/// grant table each under a OneFailure, users alice and bob (readonly: only a
/// grant lets them bind g1 or g2), and an Admin session.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_fail: OneFailure,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    live_fail: OneFailure,
    pol: mgs.GraphRBACPolicy,
    cat: policy_catalog.PolicyCatalog,
    alice_id: u64 = 0,
    bob_id: u64 = 0,
    admin: []const u8 = "",
    alice: []const u8 = "",
    bob: []const u8 = "",
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,
    prev_pol: ?*mgs.GraphRBACPolicy,
    prev_check: @TypeOf(geode.execution.graph_grant_check_fn),

    /// `inner`: the allocator under the AuthGraphManager and the live table.
    /// The failure goes into the manager's own memory (its record maps, the
    /// chain seal, the user cache), not into the GraphStore under it: a
    /// GraphStore node create or delete that fails part way leaves a
    /// half-built node that a later delete or teardown crashes on (not this
    /// ticket; see the SONNY-1333 report).
    fn init(self: *World, inner: std.mem.Allocator) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        const st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try st.createGraph("g1");
        try st.createGraph("g2");
        _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, "g1");

        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);

        self.sec_fail = .{ .inner = inner };
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(self.sec_fail.allocator(), &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);
        self.alice_id = try self.agm.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash", false);
        self.bob_id = try self.agm.createUser(&HMAC_KEY, "bob", "bob@example.com", "not_a_real_hash", false);

        self.live_fail = .{ .inner = inner };
        self.pol = mgs.GraphRBACPolicy.init(self.live_fail.allocator());
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);
        self.prev_check = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = &graphGrantCheck;
        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);

        auth_dispatch.setGrantPersistCallbacks(.{
            .ctx = @ptrCast(&self.agm),
            .resolve_user_id_fn = &grantResolveUserId,
            .grant_fn = &grantApply,
            .revoke_fn = &grantRevoke,
            .list_fn = &grantList,
        });
        // The in-memory user store is created by its first user with that
        // user's allocator; CREATE USER would create it in a request arena.
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        user_mgmt.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root1333", "", .Admin, null, null, false, 0);
        self.alice = try self.sessions.createSession("alice", "", .ReadOnly, null, null, false, 0);
        self.bob = try self.sessions.createSession("bob", "", .ReadOnly, null, null, false, 0);
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

    fn live(self: *World, uid: u64, graph: []const u8, action: u8) bool {
        return self.pol.hasGraphGrant(uid, graph, action);
    }

    /// What the next start loads: the stored grants.
    fn stored(self: *World, uid: u64, graph: []const u8, action: u8) !bool {
        const grants = try self.agm.listGraphGrants(testing.allocator);
        defer testing.allocator.free(grants);
        for (grants) |g| {
            if (g.user_id == uid and g.action == action and std.mem.eql(u8, g.getGraphName(), graph)) return true;
        }
        return false;
    }

    /// Memory and store agree on (uid, graph, action), and say `want`; the
    /// chain the next start verifies is intact.
    fn expectHeld(self: *World, uid: u64, graph: []const u8, action: u8, want: bool) !void {
        const l = self.live(uid, graph, action);
        const s = try self.stored(uid, graph, action);
        if (l != want or s != want) {
            std.debug.print("grant (user {d}, {s}, action {d}): live={}, stored={}, want {}\n", .{ uid, graph, action, l, s, want });
            return error.GrantStateWrong;
        }
        try self.agm.verifyChain(&HMAC_KEY);
    }
};

/// The rows a statement returned, each value a string or null; error.Refused
/// (with the SQLSTATE printed) when it was refused.
fn queryRows(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) ![]const []const ?[]const u8 {
    const resp = try fx.execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: refused {s} {s}\n", .{ query, e.code, e.message });
            return error.Refused;
        },
        else => {},
    }
    var out = std.ArrayList([]const ?[]const u8).empty;
    var pulls: usize = 0;
    while (pulls < 32) : (pulls += 1) {
        const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const presp = pull.response orelse return error.MissingPayload;
        const page = switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            else => return error.UnexpectedPayload,
        };
        for (page.rows.items) |row| {
            const vals = try ga.alloc(?[]const u8, row.values.items.len);
            for (row.values.items, 0..) |v, i| {
                vals[i] = if (v.kind) |k| switch (k) {
                    .string_val => |s| s.value,
                    else => null,
                } else null;
            }
            try out.append(ga, vals);
        }
        if (page.final) return out.toOwnedSlice(ga);
    }
    return error.PullNeverFinished;
}

/// The (graph, actions) of the per-graph GRANT rows of a SHOW GRANTS result
/// (policy_name null).
fn grantRows(rows: []const []const ?[]const u8) !std.ArrayList([2][]const u8) {
    var out = std.ArrayList([2][]const u8).empty;
    for (rows) |r| {
        if (r.len != 5) return error.WrongColumnCount;
        if (r[0] != null) continue;
        try out.append(testing.allocator, .{ r[1].?, r[2].? });
    }
    return out;
}

// ---------------------------------------------------------------------------
// GRANT
// ---------------------------------------------------------------------------

test "SONNY-1333: a GRANT whose save fails answers 58030 and grants nothing, in memory or in the store; a retry succeeds" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        const ga = w.ga();

        w.sec_fail.arm(offset);
        const code = try fx.outcome(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();

        if (code) |c| {
            try testing.expect(induced);
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            try w.expectHeld(w.alice_id, "g1", READ, false);
            // alice cannot use what the statement did not grant.
            _ = try fx.expectRefused(ga, w.alice, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c", "42501");
            try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");
        }
        // Whatever it answered last, a GRANT that succeeded is held, in memory
        // and in the store, and works.
        try w.expectHeld(w.alice_id, "g1", READ, true);
        try fx.expectRuns(ga, w.alice, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c");
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}

test "SONNY-1333: a GRANT ALL whose save fails part way grants none of the three, and keeps a grant held before" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        const ga = w.ga();
        try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");

        w.sec_fail.arm(offset);
        const code = try fx.outcome(ga, w.admin, "GRANT ALL ON GRAPH g1 TO alice");
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();

        if (code) |c| {
            try testing.expect(induced);
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            try w.expectHeld(w.alice_id, "g1", READ, true);
            try w.expectHeld(w.alice_id, "g1", WRITE, false);
            try w.expectHeld(w.alice_id, "g1", SCHEMA, false);
            _ = try fx.expectRefused(ga, w.alice, "USE GRAPH g1; CREATE (:W {v: 1})", "42501");
            continue;
        }
        for ([_]u8{ READ, WRITE, SCHEMA }) |a| try w.expectHeld(w.alice_id, "g1", a, true);
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}

test "SONNY-1333: a GRANT whose live-table update fails answers 58030 and leaves nothing stored to appear at the next start" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        const ga = w.ga();

        w.live_fail.arm(offset);
        const code = try fx.outcome(ga, w.admin, "GRANT ALL ON GRAPH g1 TO alice");
        const induced = w.live_fail.failed;
        w.live_fail.disarm();

        if (code) |c| {
            try testing.expect(induced);
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            for ([_]u8{ READ, WRITE, SCHEMA }) |a| try w.expectHeld(w.alice_id, "g1", a, false);
            continue;
        }
        for ([_]u8{ READ, WRITE, SCHEMA }) |a| try w.expectHeld(w.alice_id, "g1", a, true);
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}

// ---------------------------------------------------------------------------
// REVOKE
// ---------------------------------------------------------------------------

test "SONNY-1333: a REVOKE whose save fails answers 58030 and the privilege stops at once" {
    // A seal that fails after the record went is sealed again in the same
    // call (the revoke is then saved, and succeeds); the 58030 path is a
    // record that could not be removed (SONNY-3038 injects that one).
    var offset: usize = 0;
    var failures: usize = 0;
    var induced_any = false;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        const ga = w.ga();
        try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");
        try fx.expectRuns(ga, w.alice, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c");

        w.sec_fail.arm(offset);
        const code = try fx.outcome(ga, w.admin, "REVOKE READ ON GRAPH g1 FROM alice");
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();
        induced_any = induced_any or induced;

        // Either way alice has lost READ on g1 now.
        try testing.expect(!w.live(w.alice_id, "g1", READ));
        _ = try fx.expectRefused(ga, w.alice, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c", "42501");
        if (code) |c| {
            try testing.expect(induced);
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            // The retry removes what the failed save left stored.
            try fx.expectRuns(ga, w.admin, "REVOKE READ ON GRAPH g1 FROM alice");
        }
        try w.expectHeld(w.alice_id, "g1", READ, false);
        if (!induced) break;
    }
    try testing.expect(induced_any);
}

// ---------------------------------------------------------------------------
// CREATE USER
// ---------------------------------------------------------------------------

test "SONNY-1333: a CREATE USER whose save fails answers an error status and creates no user; a retry succeeds" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        const ga = w.ga();

        w.sec_fail.arm(offset);
        const rows = try queryRows(ga, w.admin, "CREATE USER carol SET PASSWORD 'Carol Grant Persist Passphrase'");
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();
        try testing.expectEqual(@as(usize, 1), rows.len);
        const status = rows[0][0].?;

        if (std.mem.startsWith(u8, status, "error")) {
            try testing.expect(induced);
            failures += 1;
            // No user in memory (no login) and none stored.
            try testing.expect(user_mgmt.getUser("carol") == null);
            try testing.expect((try w.agm.findUserIdByName("carol")) == null);
            try w.agm.verifyChain(&HMAC_KEY);
            const again = try queryRows(ga, w.admin, "CREATE USER carol SET PASSWORD 'Carol Grant Persist Passphrase'");
            try testing.expectEqualStrings("created carol", again[0][0].?);
        } else {
            try testing.expectEqualStrings("created carol", status);
        }
        try testing.expect(user_mgmt.getUser("carol") != null);
        try testing.expect((try w.agm.findUserIdByName("carol")) != null);
        try w.agm.verifyChain(&HMAC_KEY);
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}

// ---------------------------------------------------------------------------
// SHOW GRANTS
// ---------------------------------------------------------------------------

test "SONNY-1333: SHOW GRANTS [FOR <user>] lists the stored per-graph grants; a non-admin sees only its own" {
    var w: World = undefined;
    try w.init(testing.allocator);
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g1 TO alice");
    try fx.expectRuns(ga, w.admin, "GRANT WRITE ON GRAPH g1 TO alice");
    try fx.expectRuns(ga, w.admin, "GRANT READ ON GRAPH g2 TO bob");

    // An admin, for alice: her two grants on g1, not bob's.
    {
        var g = try grantRows(try queryRows(ga, w.admin, "SHOW GRANTS FOR alice"));
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), g.items.len);
        try testing.expectEqualStrings("g1", g.items[0][0]);
        try testing.expectEqualStrings("read, write", g.items[0][1]);
    }
    // alice, for herself, with and without FOR.
    for ([_][]const u8{ "SHOW GRANTS", "SHOW GRANTS FOR alice" }) |q| {
        var g = try grantRows(try queryRows(ga, w.alice, q));
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), g.items.len);
        try testing.expectEqualStrings("g1", g.items[0][0]);
        try testing.expectEqualStrings("read, write", g.items[0][1]);
    }
    // alice cannot list bob's grants (nor bob alice's).
    _ = try fx.expectRefused(ga, w.alice, "SHOW GRANTS FOR bob", "42501");
    _ = try fx.expectRefused(ga, w.bob, "SHOW GRANTS FOR alice", "42501");
    _ = try fx.expectRefused(ga, w.alice, "CALL geode.auth.grant_list('bob')", "42501");
    {
        var g = try grantRows(try queryRows(ga, w.bob, "SHOW GRANTS"));
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), g.items.len);
        try testing.expectEqualStrings("g2", g.items[0][0]);
        try testing.expectEqualStrings("read", g.items[0][1]);
    }

    // After a REVOKE the row shows what is left.
    try fx.expectRuns(ga, w.admin, "REVOKE WRITE ON GRAPH g1 FROM alice");
    {
        var g = try grantRows(try queryRows(ga, w.alice, "SHOW GRANTS"));
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), g.items.len);
        try testing.expectEqualStrings("read", g.items[0][1]);
    }
    // A user with no grant: no grant rows.
    try fx.expectRuns(ga, w.admin, "REVOKE READ ON GRAPH g1 FROM alice");
    {
        var g = try grantRows(try queryRows(ga, w.alice, "SHOW GRANTS"));
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), g.items.len);
    }
}
