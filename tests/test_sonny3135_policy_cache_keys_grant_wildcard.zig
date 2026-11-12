// SONNY-3135 regression: the round 12 hardening items left for v0.8.24.
//
// N6. `RLSEngine.checkRowAccess` cached its decision under the caller's
//     graph and table strings (`PolicyCache.put` stored the borrowed
//     slices). `invalidate`, `get` and the eviction later read every cached
//     key, which for a library caller that had freed those strings was a
//     use-after-free read, and the entry could no longer be found. The cache
//     now keeps its own copy of each key and frees it when the entry goes.
//
// N7d. `geode.auth.grant(priv, user, '*')` stored a per-graph grant on a
//     graph literally named `*`. Per-graph grants are matched by the graph a
//     request is on, and a request on `*` matches no grant, so the call
//     reported "Granted" and conferred nothing (before the 2026-10 grant
//     rework a restart then turned it into a wildcard policy). It is refused
//     now (0A000), pointing at roles and `CREATE POLICY ... ON GRAPH *`.
//
// CANARY: REQ=REQ-SONNY-3135-POLICY-CACHE-GRANT-WILDCARD; FEATURE="RLS Expression Wiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3135_policy_cache_keys_grant_wildcard.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const auth = @import("geode_auth");
const harness = @import("node_scan_stream_harness.zig");

const RLSEngine = rls.RLSEngine;
const PolicyCache = rls.PolicyCache;
const user_mgmt = geode.user_management;
const execution = geode.execution;
const auth_dispatch = geode.auth_dispatch;

/// A heap copy of `s` the test frees (and overwrites first) as a library
/// caller would.
fn callerOwned(s: []const u8) ![]u8 {
    return testing.allocator.dupe(u8, s);
}

fn release(s: []u8) void {
    @memset(s, '#');
    testing.allocator.free(s);
}

test "SONNY-3135 N6: PolicyCache keeps its own copy of each key; the caller may free its strings" {
    var cache = try PolicyCache.init(testing.allocator);
    defer cache.deinit();

    const g = try callerOwned("g3135");
    const t = try callerOwned("Doc3135");
    try cache.put(.{ .graph = g, .table = t }, 9, .select, false);
    release(g);
    release(t);

    // Found with an equal key the caller made afresh.
    const got = cache.get(.{ .graph = "g3135", .table = "Doc3135" }, 9, .select);
    if (got == null) {
        std.debug.print("the cached decision was lost when the caller freed its key strings\n", .{});
        return error.CacheKeyBorrowed;
    }
    try testing.expectEqual(false, got.?);

    // Invalidated by an equal key, and gone.
    try cache.invalidate(.{ .graph = "g3135", .table = "Doc3135" });
    try testing.expectEqual(@as(?bool, null), cache.get(.{ .graph = "g3135", .table = "Doc3135" }, 9, .select));

    // Eviction frees the keys it drops (std.testing.allocator checks).
    cache.max_size = 2;
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| {
        const kg = try callerOwned(name);
        defer release(kg);
        try cache.put(.{ .graph = kg, .table = "T" }, 1, .select, true);
    }
    try testing.expect(cache.cache.count() <= 2);
    // Re-putting an existing key keeps one copy of it.
    try cache.put(.{ .graph = "d", .table = "T" }, 1, .select, false);
    try testing.expectEqual(@as(?bool, false), cache.get(.{ .graph = "d", .table = "T" }, 1, .select));
}

const role_user: auth.RoleId = 7;

test "SONNY-3135 N6: checkRowAccess with caller-owned graph and table strings caches a decision that outlives them" {
    var engine = try RLSEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.createPolicy(.{
        .id = 3135,
        .name = "p",
        .description = "SONNY-3135",
        .graph = "g3135",
        .table = "Doc3135",
        .operation = .all,
        .permissive = false,
        .roles = &.{role_user},
        .using_expr = .{ .raw = "row.team = 'a'", .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    });

    var row = std.StringHashMap(rls.Value).init(testing.allocator);
    defer row.deinit();
    try row.put("team", .{ .string = "b" });
    var user = auth.User{
        .id = 9,
        .username = "bob",
        .email = "bob@example.com",
        .password_hash = undefined,
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(testing.allocator),
    };
    defer user.attributes.deinit();
    var permissions = std.ArrayList(auth.PermissionId).empty;
    defer permissions.deinit(testing.allocator);
    const role = auth.Role{ .id = role_user, .name = "user", .description = "", .permissions = permissions, .created_at = 0, .is_system = false, .priority = 1, .parent_role = null };
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{role},
        .session_attributes = std.StringHashMap([]const u8).init(testing.allocator),
        .request_attributes = std.StringHashMap([]const u8).init(testing.allocator),
        .environment = .{ .timestamp = 0, .ip_address = "127.0.0.1", .user_agent = "test", .location = null, .device_id = null },
    };
    defer {
        context.session_attributes.deinit();
        context.request_attributes.deinit();
    }

    const g = try callerOwned("g3135");
    const t = try callerOwned("Doc3135");
    try testing.expect(!try engine.checkRowAccess(&row, .select, &context, g, t));
    release(g);
    release(t);

    if (engine.policy_cache.get(.{ .graph = "g3135", .table = "Doc3135" }, 9, .select) == null) {
        std.debug.print("checkRowAccess cached its decision under the caller's freed strings\n", .{});
        return error.CacheKeyBorrowed;
    }
    // A policy change on the table invalidates the cached decision.
    try engine.deletePolicy(3135);
    try testing.expectEqual(@as(?bool, null), engine.policy_cache.get(.{ .graph = "g3135", .table = "Doc3135" }, 9, .select));
}

// ---------------------------------------------------------------------------
// N7d. geode.auth.grant(..., '*')
// ---------------------------------------------------------------------------

var g_granted: std.ArrayList([]u8) = .empty;

fn resolveUserId(_: ?*anyopaque, username: []const u8) ?u64 {
    return if (std.mem.eql(u8, username, "alice3135")) 31 else null;
}

fn grantRecord(_: ?*anyopaque, _: u64, graph: []const u8, _: []const u8) anyerror!void {
    try g_granted.append(testing.allocator, try testing.allocator.dupe(u8, graph));
}

fn revokeOk(_: ?*anyopaque, _: u64, _: []const u8, _: u8) anyerror!bool {
    return true;
}

const World = struct {
    h: harness.Harness,
    auth_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        auth_dispatch.setGrantPersistCallbacks(.{ .resolve_user_id_fn = &resolveUserId, .grant_fn = &grantRecord, .revoke_fn = &revokeOk });
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root3135";
    }

    fn deinit(self: *World) void {
        for (g_granted.items) |s| testing.allocator.free(s);
        g_granted.deinit(testing.allocator);
        g_granted = .empty;
        auth_dispatch.setGrantPersistCallbacks(.{});
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    fn run(self: *World, q: []const u8) !void {
        var parsed = try geode.parseGqlOptions(q, testing.allocator, .{});
        defer parsed.deinit();
        var result = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.h.ctx);
        result.deinit(testing.allocator);
    }
};

test "SONNY-3135 N7d: geode.auth.grant on graph '*' is refused (0A000) and stores nothing; a named graph is granted" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    if (w.run("CALL geode.auth.grant('READ', 'alice3135', '*')")) |_| {
        std.debug.print("geode.auth.grant(..., '*') answered 00000 and stored a grant on {d} graph(s) named '*'\n", .{g_granted.items.len});
        return error.WildcardGrantAccepted;
    } else |err| {
        const code = geode.proto_util.mapError(err).code;
        if (!std.mem.eql(u8, code, "0A000")) std.debug.print("geode.auth.grant(..., '*'): {s} ({s}), want 0A000\n", .{ code, @errorName(err) });
        try testing.expectEqualStrings("0A000", code);
    }
    try testing.expectEqual(@as(usize, 0), g_granted.items.len);

    // A named graph is still granted.
    try w.run("CALL geode.auth.grant('READ', 'alice3135', 'g1')");
    try testing.expectEqual(@as(usize, 1), g_granted.items.len);
    try testing.expectEqualStrings("g1", g_granted.items[0]);
    // A literal '*' grant an older release stored can still be revoked.
    try w.run("CALL geode.auth.revoke('READ', 'alice3135', '*')");
}
