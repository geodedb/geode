// CANARY: REQ=REQ-SONNY-6312; FEATURE="Auth list ownership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6312_user_list_ownership.zig; OWNER=security; UPDATED=2026-11-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const users = geode.user_management;
const Harness = @import("support/auth_procedure_harness.zig").Harness;

fn run(h: *Harness, allocator: std.mem.Allocator, query: []const u8) !geode.execution.ExecutionResult {
    var parse_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer parse_arena.deinit();
    var parsed = try geode.parseGql(query, parse_arena.allocator());
    defer parsed.deinit();
    return geode.execution.executeStatementWithContext(allocator, parsed.program.statements[0], .{
        .catalog = h.catalog,
        .role = .Admin,
        .user = "operator",
    });
}

fn freeSnapshot(allocator: std.mem.Allocator, snapshot: []const users.User) void {
    for (snapshot) |user| {
        var owned = user;
        owned.deinit(allocator);
    }
    allocator.free(snapshot);
}

test "SONNY-6312 caller snapshot owns strings independently of deleted users" {
    var h = try Harness.init();
    defer h.deinit();
    const snapshot = try users.listUsersAlloc(testing.allocator);
    var owns_strings = false;
    defer {
        if (owns_strings) freeSnapshot(testing.allocator, snapshot) else testing.allocator.free(snapshot);
    }
    try testing.expectEqual(@as(usize, 2), snapshot.len);
    for (snapshot) |user| {
        const cached = users.getUser(user.username) orelse return error.UserMissing;
        try testing.expect(user.username.ptr != cached.username.ptr);
        try testing.expect(user.email.ptr != cached.email.ptr);
        try testing.expect(user.password_hash.ptr != cached.password_hash.ptr);
    }
    owns_strings = true;
    try users.deleteUser("alice");
    try users.deleteUser("bob");
    for (snapshot) |user| {
        try testing.expect(std.mem.eql(u8, user.username, "alice") or std.mem.eql(u8, user.username, "bob"));
        try testing.expect(std.mem.endsWith(u8, user.email, "@example.test"));
        try testing.expectEqualStrings("unused-test-hash", user.password_hash);
    }
}

test "SONNY-6312 SHOW USERS results survive DROP USER and repeated calls leak nothing" {
    var h = try Harness.init();
    defer h.deinit();
    for (0..64) |i| {
        var result = try run(&h, testing.allocator, if (i % 2 == 0) "SHOW USERS" else "CALL geode.auth.user_list()");
        defer result.deinit(testing.allocator);
        try testing.expect(result.owns_value_memory);
        try testing.expectEqual(@as(usize, 2), result.rows.len);
    }
    var retained = try run(&h, testing.allocator, "SHOW USERS");
    defer retained.deinit(testing.allocator);
    var deleted = try h.run("DROP USER bob", .Admin, "operator");
    defer deleted.deinit(h.arena.allocator());
    var found = false;
    for (retained.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, "bob")) {
            try testing.expectEqualStrings("bob@example.test", row[1].Str);
            found = true;
        }
    }
    try testing.expect(found);
}

const Mutator = struct {
    h: *Harness,
    start: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    fn worker(self: *Mutator) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        self.mutate() catch {
            self.failed.store(true, .release);
        };
    }
    fn mutate(self: *Mutator) !void {
        for (0..256) |_| {
            try users.createUserWithHash(testing.allocator, "volatile_user", "unused-test-hash", "volatile@example.test", .User, false);
            var request = std.heap.ArenaAllocator.init(testing.allocator);
            defer request.deinit();
            var result = try run(self.h, request.allocator(), "DROP USER volatile_user");
            result.deinit(request.allocator());
        }
    }
};

test "SONNY-6312 concurrent SHOW USERS and DROP USER use request owned rows" {
    var h = try Harness.init();
    defer h.deinit();
    // Refuse a known borrowed result before starting the destructive stress.
    var probe = try run(&h, testing.allocator, "SHOW USERS");
    defer probe.deinit(testing.allocator);
    try testing.expect(probe.owns_value_memory);
    var mutator = Mutator{ .h = &h };
    const thread = try std.Thread.spawn(.{}, Mutator.worker, .{&mutator});
    var joined = false;
    defer if (!joined) thread.join();
    mutator.start.store(true, .release);
    for (0..512) |i| {
        var result = try run(&h, testing.allocator, if (i % 2 == 0) "SHOW USERS" else "CALL geode.auth.user_list()");
        defer result.deinit(testing.allocator);
        for (result.rows) |row| {
            const name = row[0].Str;
            try testing.expect(std.mem.eql(u8, name, "alice") or std.mem.eql(u8, name, "bob") or std.mem.eql(u8, name, "volatile_user"));
            try testing.expect(std.mem.endsWith(u8, row[1].Str, "@example.test"));
        }
    }
    thread.join();
    joined = true;
    try testing.expect(!mutator.failed.load(.acquire));
}

fn clearTestRoleCache() void {
    const dispatch = geode.auth_dispatch;
    if (dispatch.g_custom_roles_init) {
        dispatch.g_custom_roles.deinit();
        dispatch.g_custom_roles_init = false;
    }
}

test "SONNY-6312 role list owns custom names after DROP ROLE" {
    var h = try Harness.init();
    defer h.deinit();
    defer clearTestRoleCache();
    var created = try h.run("CREATE ROLE temporary_role", .Admin, "operator");
    defer created.deinit(h.arena.allocator());
    var listed = try run(&h, testing.allocator, "CALL geode.auth.role_list()");
    defer listed.deinit(testing.allocator);
    try testing.expect(listed.owns_value_memory);
    var deleted = try h.run("DROP ROLE temporary_role", .Admin, "operator");
    defer deleted.deinit(h.arena.allocator());
    var found = false;
    for (listed.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, "temporary_role")) found = true;
    }
    try testing.expect(found);
}

fn snapshotAllocationFailure(allocator: std.mem.Allocator) !void {
    const snapshot = try users.listUsersAlloc(allocator);
    defer users.freeUsersSnapshot(allocator, snapshot);
    try testing.expectEqual(@as(usize, 2), snapshot.len);
}

fn resultAllocationFailure(allocator: std.mem.Allocator, h: *Harness, query: []const u8) !void {
    var result = try run(h, allocator, query);
    defer result.deinit(allocator);
    try testing.expect(result.rows.len > 0);
}

test "SONNY-6312 every snapshot and user or role list allocation failure cleans up" {
    var h = try Harness.init();
    defer h.deinit();
    defer clearTestRoleCache();
    var created = try h.run("CREATE ROLE allocated_role", .Admin, "operator");
    defer created.deinit(h.arena.allocator());
    try testing.checkAllAllocationFailures(testing.allocator, snapshotAllocationFailure, .{});
    try testing.checkAllAllocationFailures(testing.allocator, resultAllocationFailure, .{ &h, "SHOW USERS" });
    try testing.checkAllAllocationFailures(testing.allocator, resultAllocationFailure, .{ &h, "CALL geode.auth.role_list()" });
}

test "SONNY-6312 sibling policy list retains owned data and unsupported lists refuse" {
    var h = try Harness.init();
    defer h.deinit();
    const policies = geode.security.policy_catalog;
    var catalog = policies.PolicyCatalog.init(testing.allocator);
    defer catalog.deinit();
    policies.setGlobalCatalog(&catalog);
    defer policies.clearGlobalCatalog();
    try catalog.addPolicyStrict(.{ .name = "temporary_policy", .scope_graph = "*", .actions = &.{.read}, .effect = .allow, .expression_source = "true", .enabled = true });
    var listed = try run(&h, testing.allocator, "CALL geode.auth.policy_list()");
    defer listed.deinit(testing.allocator);
    try testing.expect(listed.owns_value_memory);
    var deleted = try h.run("DROP POLICY temporary_policy", .Admin, "operator");
    defer deleted.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), listed.rows.len);
    try testing.expectEqualStrings("temporary_policy", listed.rows[0][0].Str);
    try testing.expectEqualStrings("*", listed.rows[0][1].Str);
    try testing.expectError(error.ApiKeysUnsupported, h.run("CALL geode.auth.apikey_list()", .Admin, "operator"));
    try testing.expectError(error.UnknownProcedure, h.run("CALL geode.auth.grant_list()", .Admin, "operator"));
}
