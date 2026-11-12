// CANARY: REQ=REQ-SONNY-6292-CUSTOM-ROLE-MEMBERSHIP; FEATURE="Custom role membership refusal"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6292_custom_role_refusal.zig; OWNER=security; UPDATED=2026-11-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const dispatch = geode.auth_dispatch;
const users = geode.user_management;
const AuthGraphManager = @import("auth_graph_manager").AuthGraphManager;
const Harness = @import("support/auth_procedure_harness.zig").Harness;
const key = [_]u8{0x62} ** 32;

// These callbacks delegate to real security-graph persistence, as server startup
// does. No fabricated database results or replacement authorization engine.
const Fixture = struct {
    h: Harness,
    manager: AuthGraphManager,
    manager_live: bool,

    fn init(self: *Fixture) !void {
        self.manager_live = false;
        self.h = try Harness.init();
        errdefer self.h.deinit();
        self.manager = try AuthGraphManager.init(testing.allocator, geode.graph_store.getGlobalStore(testing.allocator));
        self.manager_live = true;
        dispatch.setRolePersistCallbacks(.{ .ctx = self, .create_fn = create, .remove_fn = remove, .find_id_fn = find, .list_fn = list });
        dispatch.hydrateCustomRolesFromGraph(self.h.arena.allocator());
    }

    fn clearRoleCache() void {
        if (dispatch.g_custom_roles_init) {
            dispatch.g_custom_roles.deinit();
            dispatch.g_custom_roles_init = false;
        }
        // Clean up the original implementation too, so the red regression run
        // reports its behavioral failure rather than leaked fixture memory.
        if (comptime @hasDecl(dispatch, "g_custom_role_members_init")) {
            if (dispatch.g_custom_role_members_init) {
                dispatch.g_custom_role_members.deinit();
                dispatch.g_custom_role_members_init = false;
            }
        }
    }

    fn deinit(self: *Fixture) void {
        dispatch.setRolePersistCallbacks(.{});
        clearRoleCache();
        if (self.manager_live) self.manager.deinit();
        self.h.deinit();
    }

    fn restartAuth(self: *Fixture) !void {
        try self.manager.verifyChain(&key);
        try geode.graph_store.getGlobalStore(testing.allocator).saveToFile();
        self.manager.deinit();
        self.manager_live = false;
        clearRoleCache();
        geode.execution.cleanupCatalogInstance();
        geode.graph_store.deinitGlobalStore();
        const store = try geode.graph_store.initGlobalStore(testing.allocator, self.h.data_dir);
        self.h.catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
        self.manager = try AuthGraphManager.init(testing.allocator, store);
        self.manager_live = true;
        try self.manager.verifyChain(&key);
        dispatch.hydrateCustomRolesFromGraph(self.h.arena.allocator());
    }

    fn from(ctx: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn create(ctx: ?*anyopaque, name: []const u8, description: []const u8) !u64 {
        return from(ctx).manager.createRole(&key, name, description);
    }

    fn remove(ctx: ?*anyopaque, id: u64) !void {
        try from(ctx).manager.removeRole(&key, id);
    }

    fn find(ctx: ?*anyopaque, name: []const u8) !?u64 {
        return from(ctx).manager.findRoleIdByName(name);
    }

    fn list(ctx: ?*anyopaque, allocator: std.mem.Allocator) ![]dispatch.RoleEntry {
        var entries: std.ArrayList(dispatch.RoleEntry) = .empty;
        errdefer entries.deinit(allocator);
        var it = from(ctx).manager.storage.roleIterator();
        while (it.next()) |record| {
            try entries.append(allocator, .{ .id = record.id, .name = record.getName(), .description = record.getDescription() });
        }
        return entries.toOwnedSlice(allocator);
    }

    fn exec(self: *Fixture, query: []const u8) !void {
        var result = try self.h.run(query, .Admin, "operator");
        result.deinit(self.h.arena.allocator());
    }

    fn bobWrite(self: *Fixture) !void {
        const bob = users.getUser("bob") orelse return error.TestUserMissing;
        // The transport checks the canonical permission gate before invoking
        // the inner statement executor. Exercise that same real decision here.
        try geode.execution.checkPermission(.{ .catalog = self.h.catalog, .role = bob.role, .user = bob.username }, .Write);
        var result = try self.h.run("CREATE (:RoleProbe)", bob.role, bob.username);
        result.deinit(self.h.arena.allocator());
    }
};

test "SONNY-6292: custom GRANT, ALTER and direct assignment refuse without changing permissions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.exec("CREATE ROLE analyst");
    try testing.expectError(error.Unauthorized, f.bobWrite());
    for ([_][]const u8{
        "GRANT ROLE analyst TO bob",
        "ALTER USER bob SET ROLE analyst",
        "CALL geode.auth.user_assign_role('bob', 'analyst')",
    }) |query| {
        try testing.expectError(error.CustomRoleMembershipUnsupported, f.exec(query));
        try testing.expectEqual(users.Role.ReadOnly, users.getUser("bob").?.role);
        try testing.expectError(error.Unauthorized, f.bobWrite());
    }
    try testing.expectEqualStrings("0A000", geode.proto_util.mapError(error.CustomRoleMembershipUnsupported).code);
    try testing.expectError(error.UnknownRole, f.exec("GRANT ROLE missing TO bob"));
    try f.exec("GRANT ROLE readwrite TO bob");
    try testing.expectEqual(users.Role.ReadWrite, users.getUser("bob").?.role);
    try f.bobWrite();
}

test "SONNY-6292: dropping and recreating a role cannot resurrect an assignment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.exec("CREATE ROLE analyst");
    try testing.expectError(error.CustomRoleMembershipUnsupported, f.exec("GRANT ROLE analyst TO bob"));
    try f.exec("DROP ROLE analyst");
    try testing.expect((try f.manager.findRoleIdByName("analyst")) == null);
    try f.exec("CREATE ROLE analyst");
    try testing.expectError(error.CustomRoleMembershipUnsupported, f.exec("GRANT ROLE analyst TO bob"));
    try testing.expectError(error.Unauthorized, f.bobWrite());
    try f.manager.verifyChain(&key);
}

test "SONNY-6292: durable storage reopen and role rehydration preserve refused membership" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.exec("CREATE ROLE analyst");
    try testing.expectError(error.CustomRoleMembershipUnsupported, f.exec("GRANT ROLE analyst TO bob"));
    try f.restartAuth();
    try testing.expect(dispatch.g_custom_roles.contains("analyst"));
    try testing.expect((try f.manager.findRoleIdByName("analyst")) != null);
    try testing.expectError(error.CustomRoleMembershipUnsupported, f.exec("GRANT ROLE analyst TO bob"));
    try testing.expectEqual(users.Role.ReadOnly, users.getUser("bob").?.role);
    try testing.expectError(error.Unauthorized, f.bobWrite());
}
