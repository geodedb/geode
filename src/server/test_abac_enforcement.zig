// Test suite for ABAC enforcement wiring in server execution
// CANARY: REQ=REQ-ABAC-WIRE-TEST-001; FEATURE="ABAC Enforcement Tests"; ASPECT=Testing; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=server; UPDATED=2026-01-25
//         ASPECT=TESTING; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Unit tests for SecurityManager initialization and ABAC enforcement

const std = @import("std");
const testing = std.testing;
const server_init = @import("server_init.zig");
const server_state = @import("server_state.zig");
const geode_auth = @import("geode_auth");

// CANARY: REQ=REQ-ABAC-WIRE-TEST-002; FEATURE="ABAC Enforcement Tests"; ASPECT=SecurityInit; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: SecurityManager initialization succeeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    // Initialize SecurityManager directly
    var sm = try server_init.initializeSecurityManager(ally);
    defer sm.deinit();

    // Verify default user was created (initialization succeeds)
    // Default user should be user_id 1 (admin)
    const user = sm.users.get(1);
    try testing.expect(user != null);
    if (user) |u| {
        try testing.expect(std.mem.eql(u8, u.username, "admin"));
    }
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-003; FEATURE="ABAC Enforcement Tests"; ASPECT=EnvConfig; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: EnvironmentConfig includes abac_enabled field" {
    const config = server_init.EnvironmentConfig{};

    // Default should be false
    try testing.expect(!config.abac_enabled);

    // Verify field is accessible and settable
    var config2 = server_init.EnvironmentConfig{};
    config2.abac_enabled = true;
    try testing.expect(config2.abac_enabled);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-004; FEATURE="ABAC Enforcement Tests"; ASPECT=InitContext; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: InitContext includes SecurityManager fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create minimal InitContext to verify fields exist
    const ctx = server_init.InitContext{
        .wal = undefined,
        .env_config = server_init.EnvironmentConfig{},
        .security_manager = null,
        .security_manager_storage = null,
    };

    // Verify fields are accessible
    try testing.expect(ctx.security_manager == null);
    try testing.expect(ctx.security_manager_storage == null);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-005; FEATURE="ABAC Enforcement Tests"; ASPECT=ServerState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: ServerState includes security_manager field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    // Create ServerState to verify security_manager field
    var state = server_state.ServerState{
        .allocator = ally,
        .session_config = server_state.SessionConfiguration.init(ally),
    };

    // Default should be null
    try testing.expect(state.security_manager == null);
    try testing.expect(state.current_user_id == null);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-006; FEATURE="ABAC Enforcement Tests"; ASPECT=Authorization; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: SecurityManager authorize function works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var sm = try geode_auth.SecurityManager.init(ally);
    defer sm.deinit();

    // Default admin user should exist (user_id 1)
    // Admin is superuser, so should authorize any action
    const authorized = try sm.authorize(1, "any_resource", .read);
    try testing.expect(authorized);

    // Non-existent user should fail
    const result = sm.authorize(999, "any_resource", .read);
    try testing.expectError(error.UserNotFound, result);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-007; FEATURE="ABAC Enforcement Tests"; ASPECT=RBAC; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: RBAC permission checks work through SecurityManager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var sm = try geode_auth.SecurityManager.init(ally);
    defer sm.deinit();

    // Create a non-superuser
    const test_user = try sm.createUser("testuser", "test@example.com", "password");
    const user_id = test_user.id;

    // Create a role with read permission on "graphs"
    const role = try sm.createRole("reader", "Read-only access");
    const perm = try sm.createPermission("read_graphs", "graphs", .read);
    try sm.grantPermission(role.id, perm.id);
    try sm.assignRole(user_id, role.id);

    // Should be authorized for read on graphs
    const read_auth = try sm.authorize(user_id, "graphs", .read);
    try testing.expect(read_auth);

    // Should not be authorized for write on graphs (no permission)
    const write_auth = try sm.authorize(user_id, "graphs", .create);
    try testing.expect(!write_auth);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-008; FEATURE="ABAC Enforcement Tests"; ASPECT=ABAC; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: ABAC policy evaluation works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var sm = try geode_auth.SecurityManager.init(ally);
    defer sm.deinit();

    // Create a non-superuser with department attribute
    const test_user = try sm.createUser("analyst", "analyst@example.com", "password");
    const user_id = test_user.id;

    // Add attribute to user
    try test_user.attributes.put("department", "engineering");

    // Create ABAC policy allowing engineering department to read reports
    var subjects_arr = [_]geode_auth.AttributeCondition{.{
        .attribute = "department",
        .operator = .equals,
        .value = .{ .string = "engineering" },
    }};
    var resources_arr = [_]geode_auth.AttributeCondition{.{
        .attribute = "name",
        .operator = .equals,
        .value = .{ .string = "reports" },
    }};
    var actions_arr = [_]geode_auth.Action{.read};

    const policy = geode_auth.ABACPolicy{
        .id = 1,
        .name = "engineering_reports",
        .description = "Engineering can read reports",
        .subjects = subjects_arr[0..],
        .resources = resources_arr[0..],
        .actions = actions_arr[0..],
        .conditions = &.{},
        .effect = .allow,
        .priority = 100,
        .enabled = true,
    };

    try sm.createABACPolicy(policy);

    // Should be authorized for read on reports via ABAC policy
    const authorized = try sm.authorize(user_id, "reports", .read);
    try testing.expect(authorized);
}

// CANARY: REQ=REQ-ABAC-WIRE-TEST-009; FEATURE="ABAC Enforcement Tests"; ASPECT=DenyPriority; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
test "GAP-0165: ABAC deny takes priority over allow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var sm = try geode_auth.SecurityManager.init(ally);
    defer sm.deinit();

    // Create a non-superuser
    const test_user = try sm.createUser("restricted", "restricted@example.com", "password");
    const user_id = test_user.id;

    try test_user.attributes.put("clearance", "low");

    // Create allow policy for all users on public resource
    var subjects_allow = [_]geode_auth.AttributeCondition{};
    var resources_allow = [_]geode_auth.AttributeCondition{.{
        .attribute = "name",
        .operator = .equals,
        .value = .{ .string = "secrets" },
    }};
    var actions_allow = [_]geode_auth.Action{.read};

    const allow_policy = geode_auth.ABACPolicy{
        .id = 1,
        .name = "allow_secrets",
        .description = "Allow reading secrets",
        .subjects = subjects_allow[0..],
        .resources = resources_allow[0..],
        .actions = actions_allow[0..],
        .conditions = &.{},
        .effect = .allow,
        .priority = 50,
        .enabled = true,
    };

    // Create deny policy for low clearance users
    var subjects_deny = [_]geode_auth.AttributeCondition{.{
        .attribute = "clearance",
        .operator = .equals,
        .value = .{ .string = "low" },
    }};

    const deny_policy = geode_auth.ABACPolicy{
        .id = 2,
        .name = "deny_low_clearance",
        .description = "Deny low clearance from secrets",
        .subjects = subjects_deny[0..],
        .resources = resources_allow[0..],
        .actions = actions_allow[0..],
        .conditions = &.{},
        .effect = .deny,
        .priority = 100,
        .enabled = true,
    };

    try sm.createABACPolicy(allow_policy);
    try sm.createABACPolicy(deny_policy);

    // Should be denied due to deny policy taking priority
    const authorized = try sm.authorize(user_id, "secrets", .read);
    try testing.expect(!authorized);
}
