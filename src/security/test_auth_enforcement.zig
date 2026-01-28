// CANARY: REQ=REQ-AUTH-ENFORCE-003; FEATURE="AuthEnforcement"; ASPECT=UnitTests; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// CRITICAL SECURITY TESTS: Verify that authentication is properly enforced
// These tests ensure that unauthenticated users CANNOT execute queries when auth is enabled

const std = @import("std");
const testing = std.testing;

// Import from the local security module
const user_management = @import("user_management.zig");
const Role = user_management.Role;
const Permission = user_management.Permission;

// ============================================================================
// CRITICAL SECURITY TESTS: Authentication enforcement at user_management level
// These tests verify the core permission checking logic that protects the database
// ============================================================================

// Test: hasPermission correctly denies Write to ReadOnly role
test "TestAuthEnforcement_hasPermission_ReadOnlyCannotWrite" {
    // ReadOnly role should NOT have Write permission
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
}

// Test: hasPermission correctly denies Schema to ReadOnly role
test "TestAuthEnforcement_hasPermission_ReadOnlyCannotSchema" {
    // ReadOnly role should NOT have Schema permission
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

// Test: hasPermission correctly allows Read to ReadOnly role
test "TestAuthEnforcement_hasPermission_ReadOnlyCanRead" {
    // ReadOnly role SHOULD have Read permission
    try testing.expect(user_management.hasPermission(.ReadOnly, .Read));
}

// Test: hasPermission correctly allows all to Admin role
test "TestAuthEnforcement_hasPermission_AdminHasAllPermissions" {
    // Admin role should have ALL permissions
    try testing.expect(user_management.hasPermission(.Admin, .Read));
    try testing.expect(user_management.hasPermission(.Admin, .Write));
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

// Test: hasPermission correctly allows Read and Write to ReadWrite role
test "TestAuthEnforcement_hasPermission_ReadWriteCanReadAndWrite" {
    // ReadWrite role should have Read and Write, but NOT Schema
    try testing.expect(user_management.hasPermission(.ReadWrite, .Read));
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

// Test: hasPermission correctly denies Write to User role
test "TestAuthEnforcement_hasPermission_UserCannotWrite" {
    // User role should NOT have Write permission
    try testing.expect(!user_management.hasPermission(.User, .Write));
}

// Test: hasPermission correctly denies Schema to User role
test "TestAuthEnforcement_hasPermission_UserCannotSchema" {
    // User role should NOT have Schema permission
    try testing.expect(!user_management.hasPermission(.User, .Schema));
}

// Test: hasPermission correctly allows Read to User role
test "TestAuthEnforcement_hasPermission_UserCanRead" {
    // User role SHOULD have Read permission
    try testing.expect(user_management.hasPermission(.User, .Read));
}

// ============================================================================
// Test: Auth enabled/disabled state transitions
// ============================================================================

test "TestAuthEnforcement_AuthStateTransitions" {
    // Save original state
    const original_state = user_management.isAuthEnabled();
    defer user_management.setAuthEnabled(original_state);

    // Initially, check state can be set
    user_management.setAuthEnabled(false);
    try testing.expect(!user_management.isAuthEnabled());

    // Enable auth
    user_management.setAuthEnabled(true);
    try testing.expect(user_management.isAuthEnabled());

    // Disable again
    user_management.setAuthEnabled(false);
    try testing.expect(!user_management.isAuthEnabled());
}

// ============================================================================
// Test: Role string conversions (defense against tampering)
// ============================================================================

test "TestAuthEnforcement_RoleFromString_ValidRoles" {
    // Valid role strings should parse correctly
    try testing.expect(Role.fromString("admin") == .Admin);
    try testing.expect(Role.fromString("Admin") == .Admin);
    try testing.expect(Role.fromString("ADMIN") == .Admin);

    try testing.expect(Role.fromString("user") == .User);
    try testing.expect(Role.fromString("User") == .User);

    try testing.expect(Role.fromString("readwrite") == .ReadWrite);
    try testing.expect(Role.fromString("ReadWrite") == .ReadWrite);

    try testing.expect(Role.fromString("readonly") == .ReadOnly);
    try testing.expect(Role.fromString("ReadOnly") == .ReadOnly);
}

test "TestAuthEnforcement_RoleFromString_InvalidRoles" {
    // Invalid role strings should return null (not escalate to Admin!)
    try testing.expect(Role.fromString("") == null);
    try testing.expect(Role.fromString("superadmin") == null);
    try testing.expect(Role.fromString("root") == null);
    try testing.expect(Role.fromString("administrator") == null);
    try testing.expect(Role.fromString("write") == null);
    try testing.expect(Role.fromString("read") == null);
    try testing.expect(Role.fromString("   admin") == null); // Leading space
    try testing.expect(Role.fromString("admin   ") == null); // Trailing space
}

// ============================================================================
// Test: Permission derivation from roles (comprehensive coverage)
// ============================================================================

test "TestAuthEnforcement_PermissionFromRole_Admin" {
    const perms = Permission.fromRole(.Admin);
    try testing.expectEqual(@as(usize, 3), perms.len);
    try testing.expect(perms[0] == .Read);
    try testing.expect(perms[1] == .Write);
    try testing.expect(perms[2] == .Schema);
}

test "TestAuthEnforcement_PermissionFromRole_ReadWrite" {
    const perms = Permission.fromRole(.ReadWrite);
    try testing.expectEqual(@as(usize, 2), perms.len);
    try testing.expect(perms[0] == .Read);
    try testing.expect(perms[1] == .Write);
}

test "TestAuthEnforcement_PermissionFromRole_User" {
    const perms = Permission.fromRole(.User);
    try testing.expectEqual(@as(usize, 1), perms.len);
    try testing.expect(perms[0] == .Read);
}

test "TestAuthEnforcement_PermissionFromRole_ReadOnly" {
    const perms = Permission.fromRole(.ReadOnly);
    try testing.expectEqual(@as(usize, 1), perms.len);
    try testing.expect(perms[0] == .Read);
}

// ============================================================================
// Comprehensive permission matrix test
// This ensures all role/permission combinations are correctly enforced
// ============================================================================

test "TestAuthEnforcement_ComprehensivePermissionMatrix" {
    // Matrix: [Role][Permission] -> expected result
    // Admin: Read=true, Write=true, Schema=true
    try testing.expect(user_management.hasPermission(.Admin, .Read) == true);
    try testing.expect(user_management.hasPermission(.Admin, .Write) == true);
    try testing.expect(user_management.hasPermission(.Admin, .Schema) == true);

    // ReadWrite: Read=true, Write=true, Schema=false
    try testing.expect(user_management.hasPermission(.ReadWrite, .Read) == true);
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write) == true);
    try testing.expect(user_management.hasPermission(.ReadWrite, .Schema) == false);

    // User: Read=true, Write=false, Schema=false
    try testing.expect(user_management.hasPermission(.User, .Read) == true);
    try testing.expect(user_management.hasPermission(.User, .Write) == false);
    try testing.expect(user_management.hasPermission(.User, .Schema) == false);

    // ReadOnly: Read=true, Write=false, Schema=false
    try testing.expect(user_management.hasPermission(.ReadOnly, .Read) == true);
    try testing.expect(user_management.hasPermission(.ReadOnly, .Write) == false);
    try testing.expect(user_management.hasPermission(.ReadOnly, .Schema) == false);
}

// ============================================================================
// Test: Role toString consistency (round-trip validation)
// ============================================================================

test "TestAuthEnforcement_RoleRoundTrip" {
    // Ensure toString -> fromString round-trips correctly
    const admin_str = Role.toString(.Admin);
    try testing.expect(Role.fromString(admin_str) == .Admin);

    const user_str = Role.toString(.User);
    try testing.expect(Role.fromString(user_str) == .User);

    const rw_str = Role.toString(.ReadWrite);
    try testing.expect(Role.fromString(rw_str) == .ReadWrite);

    const ro_str = Role.toString(.ReadOnly);
    try testing.expect(Role.fromString(ro_str) == .ReadOnly);
}
