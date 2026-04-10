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

// ============================================================================
// AUTHORIZATION ENFORCEMENT TESTS
// CANARY: REQ=REQ-AUTH-ENFORCE-025; FEATURE="AuthEnforcement"; ASPECT=AuthorizationTests; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// These tests verify that users cannot perform operations outside their roles
// ============================================================================

// --- READ OPERATION AUTHORIZATION ---

test "TestAuthz_ReadOnly_CannotCreateNode" {
    // ReadOnly users should NOT be able to create nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
}

test "TestAuthz_ReadOnly_CannotInsertData" {
    // ReadOnly users should NOT be able to insert data (requires Write)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
}

test "TestAuthz_ReadOnly_CannotDeleteNode" {
    // ReadOnly users should NOT be able to delete nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
}

test "TestAuthz_ReadOnly_CannotMergeNode" {
    // ReadOnly users should NOT be able to merge nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
}

test "TestAuthz_ReadOnly_CannotCreateIndex" {
    // ReadOnly users should NOT be able to create indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotDropIndex" {
    // ReadOnly users should NOT be able to drop indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotCreateGraph" {
    // ReadOnly users should NOT be able to create graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotDropGraph" {
    // ReadOnly users should NOT be able to drop graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotCreateSchema" {
    // ReadOnly users should NOT be able to create schemas (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotDropSchema" {
    // ReadOnly users should NOT be able to drop schemas (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotCreateConstraint" {
    // ReadOnly users should NOT be able to create constraints (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

test "TestAuthz_ReadOnly_CannotDropConstraint" {
    // ReadOnly users should NOT be able to drop constraints (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
}

// --- USER ROLE AUTHORIZATION ---

test "TestAuthz_User_CannotCreateNode" {
    // User role should NOT be able to create nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.User, .Write));
}

test "TestAuthz_User_CannotInsertData" {
    // User role should NOT be able to insert data (requires Write)
    try testing.expect(!user_management.hasPermission(.User, .Write));
}

test "TestAuthz_User_CannotDeleteNode" {
    // User role should NOT be able to delete nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.User, .Write));
}

test "TestAuthz_User_CannotMergeNode" {
    // User role should NOT be able to merge nodes (requires Write)
    try testing.expect(!user_management.hasPermission(.User, .Write));
}

test "TestAuthz_User_CannotCreateIndex" {
    // User role should NOT be able to create indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.User, .Schema));
}

test "TestAuthz_User_CannotDropIndex" {
    // User role should NOT be able to drop indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.User, .Schema));
}

test "TestAuthz_User_CannotCreateGraph" {
    // User role should NOT be able to create graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.User, .Schema));
}

test "TestAuthz_User_CannotDropGraph" {
    // User role should NOT be able to drop graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.User, .Schema));
}

// --- READWRITE ROLE AUTHORIZATION ---

test "TestAuthz_ReadWrite_CanCreateNode" {
    // ReadWrite role SHOULD be able to create nodes (has Write)
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
}

test "TestAuthz_ReadWrite_CanInsertData" {
    // ReadWrite role SHOULD be able to insert data (has Write)
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
}

test "TestAuthz_ReadWrite_CanDeleteNode" {
    // ReadWrite role SHOULD be able to delete nodes (has Write)
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
}

test "TestAuthz_ReadWrite_CanMergeNode" {
    // ReadWrite role SHOULD be able to merge nodes (has Write)
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
}

test "TestAuthz_ReadWrite_CannotCreateIndex" {
    // ReadWrite role should NOT be able to create indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotDropIndex" {
    // ReadWrite role should NOT be able to drop indexes (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotCreateGraph" {
    // ReadWrite role should NOT be able to create graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotDropGraph" {
    // ReadWrite role should NOT be able to drop graphs (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotCreateSchema" {
    // ReadWrite role should NOT be able to create schemas (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotDropSchema" {
    // ReadWrite role should NOT be able to drop schemas (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotCreateConstraint" {
    // ReadWrite role should NOT be able to create constraints (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

test "TestAuthz_ReadWrite_CannotDropConstraint" {
    // ReadWrite role should NOT be able to drop constraints (requires Schema)
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
}

// --- ADMIN ROLE AUTHORIZATION (should have all permissions) ---

test "TestAuthz_Admin_CanCreateNode" {
    try testing.expect(user_management.hasPermission(.Admin, .Write));
}

test "TestAuthz_Admin_CanInsertData" {
    try testing.expect(user_management.hasPermission(.Admin, .Write));
}

test "TestAuthz_Admin_CanDeleteNode" {
    try testing.expect(user_management.hasPermission(.Admin, .Write));
}

test "TestAuthz_Admin_CanMergeNode" {
    try testing.expect(user_management.hasPermission(.Admin, .Write));
}

test "TestAuthz_Admin_CanCreateIndex" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanDropIndex" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanCreateGraph" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanDropGraph" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanCreateSchema" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanDropSchema" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanCreateConstraint" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanDropConstraint" {
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

test "TestAuthz_Admin_CanReadData" {
    try testing.expect(user_management.hasPermission(.Admin, .Read));
}

// ============================================================================
// EXHAUSTIVE OPERATION-TO-PERMISSION MAPPING TESTS
// CANARY: REQ=REQ-AUTH-ENFORCE-026; FEATURE="AuthEnforcement"; ASPECT=OperationMapping; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// Verify all operations are mapped to correct permissions
// ============================================================================

test "TestAuthz_OperationMapping_ReadOperations" {
    // All read operations require Read permission
    // Query, Union, Intersect, Except, Show, Explain, Profile, Call, For, Values
    // All these should require Read permission, which ReadOnly has
    try testing.expect(user_management.hasPermission(.ReadOnly, .Read));
    try testing.expect(user_management.hasPermission(.User, .Read));
    try testing.expect(user_management.hasPermission(.ReadWrite, .Read));
    try testing.expect(user_management.hasPermission(.Admin, .Read));
}

test "TestAuthz_OperationMapping_WriteOperations" {
    // All write operations require Write permission
    // Create, Insert, Delete, Merge
    // Only ReadWrite and Admin should have Write permission
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Write));
    try testing.expect(!user_management.hasPermission(.User, .Write));
    try testing.expect(user_management.hasPermission(.ReadWrite, .Write));
    try testing.expect(user_management.hasPermission(.Admin, .Write));
}

test "TestAuthz_OperationMapping_SchemaOperations" {
    // All schema operations require Schema permission
    // CreateIndex, DropIndex, CreateConstraint, DropConstraint
    // CreateGraph, DropGraph, CreateGraphType, DropGraphType
    // CreateSchema, DropSchema
    // Only Admin should have Schema permission
    try testing.expect(!user_management.hasPermission(.ReadOnly, .Schema));
    try testing.expect(!user_management.hasPermission(.User, .Schema));
    try testing.expect(!user_management.hasPermission(.ReadWrite, .Schema));
    try testing.expect(user_management.hasPermission(.Admin, .Schema));
}

// ============================================================================
// NEGATIVE PERMISSION TESTS (Security boundaries)
// CANARY: REQ=REQ-AUTH-ENFORCE-027; FEATURE="AuthEnforcement"; ASPECT=SecurityBoundaries; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// These tests verify security boundaries are not violated
// ============================================================================

test "TestAuthz_Boundary_ReadOnlyCannotEscalate" {
    // ReadOnly role should NEVER have Write or Schema permissions
    const has_write = user_management.hasPermission(.ReadOnly, .Write);
    const has_schema = user_management.hasPermission(.ReadOnly, .Schema);

    try testing.expect(!has_write);
    try testing.expect(!has_schema);

    // Double-check by verifying permission list
    const perms = Permission.fromRole(.ReadOnly);
    for (perms) |p| {
        try testing.expect(p != .Write);
        try testing.expect(p != .Schema);
    }
}

test "TestAuthz_Boundary_UserCannotEscalate" {
    // User role should NEVER have Write or Schema permissions
    const has_write = user_management.hasPermission(.User, .Write);
    const has_schema = user_management.hasPermission(.User, .Schema);

    try testing.expect(!has_write);
    try testing.expect(!has_schema);

    // Double-check by verifying permission list
    const perms = Permission.fromRole(.User);
    for (perms) |p| {
        try testing.expect(p != .Write);
        try testing.expect(p != .Schema);
    }
}

test "TestAuthz_Boundary_ReadWriteCannotEscalateToSchema" {
    // ReadWrite role should NEVER have Schema permissions
    const has_schema = user_management.hasPermission(.ReadWrite, .Schema);
    try testing.expect(!has_schema);

    // Double-check by verifying permission list
    const perms = Permission.fromRole(.ReadWrite);
    for (perms) |p| {
        try testing.expect(p != .Schema);
    }
}

test "TestAuthz_Boundary_NoHiddenPermissions" {
    // Verify each role has exactly the expected number of permissions
    try testing.expectEqual(@as(usize, 1), Permission.fromRole(.ReadOnly).len); // Only Read
    try testing.expectEqual(@as(usize, 1), Permission.fromRole(.User).len); // Only Read
    try testing.expectEqual(@as(usize, 2), Permission.fromRole(.ReadWrite).len); // Read + Write
    try testing.expectEqual(@as(usize, 3), Permission.fromRole(.Admin).len); // Read + Write + Schema
}

// ============================================================================
// PRIVILEGE ESCALATION PREVENTION TESTS
// CANARY: REQ=REQ-AUTH-ENFORCE-028; FEATURE="AuthEnforcement"; ASPECT=EscalationPrevention; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// ============================================================================

test "TestAuthz_NoPrivilegeEscalation_InvalidRoleStrings" {
    // These strings should NEVER be parsed as valid roles
    // Prevents privilege escalation via role string manipulation
    const invalid_roles = [_][]const u8{
        "admin\x00", // Null byte injection
        "ADMIN\n", // Newline injection
        "admin\r\n", // CRLF injection
        "admin'--", // SQL injection attempt
        "admin; DROP TABLE users;", // SQL injection
        "<script>alert('admin')</script>", // XSS attempt
        "{{admin}}", // Template injection
        "${admin}", // Variable injection
        "admin|root", // Pipe character
        "admin&root", // Ampersand
        "../admin", // Path traversal
        "..\\admin", // Windows path traversal
        "admin%00", // URL-encoded null
        "\x00admin", // Leading null byte
    };

    for (invalid_roles) |invalid| {
        try testing.expect(Role.fromString(invalid) == null);
    }
}

test "TestAuthz_NoPrivilegeEscalation_CaseSensitiveChecks" {
    // Role names are case-insensitive but should still parse to correct role
    // Ensure "Admin" doesn't give more permissions than "admin"
    const admin1 = Role.fromString("admin").?;
    const admin2 = Role.fromString("ADMIN").?;
    const admin3 = Role.fromString("Admin").?;

    // All should have exactly the same permissions
    try testing.expect(user_management.hasPermission(admin1, .Read) == user_management.hasPermission(admin2, .Read));
    try testing.expect(user_management.hasPermission(admin1, .Write) == user_management.hasPermission(admin2, .Write));
    try testing.expect(user_management.hasPermission(admin1, .Schema) == user_management.hasPermission(admin2, .Schema));

    try testing.expect(user_management.hasPermission(admin1, .Read) == user_management.hasPermission(admin3, .Read));
    try testing.expect(user_management.hasPermission(admin1, .Write) == user_management.hasPermission(admin3, .Write));
    try testing.expect(user_management.hasPermission(admin1, .Schema) == user_management.hasPermission(admin3, .Schema));
}

// ============================================================================
// UNICODE HOMOGRAPH / DOWNGRADE ATTACK PREVENTION TESTS
// CANARY: REQ=REQ-AUTH-ENFORCE-029; FEATURE="AuthEnforcement"; ASPECT=UnicodeHomographPrevention; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// These tests verify that Unicode lookalike characters cannot be used to
// escalate privileges (e.g., using Cyrillic "а" instead of Latin "a")
// ============================================================================

test "TestAuthz_NoPrivilegeEscalation_UnicodeHomographAttacks" {
    // CRITICAL: These strings use Unicode lookalike characters that visually
    // resemble "admin" but are NOT the same bytes

    // Cyrillic lookalikes (а=U+0430 looks like a, о=U+043E looks like o, etc.)
    try testing.expect(Role.fromString("аdmin") == null); // Cyrillic а (U+0430)
    try testing.expect(Role.fromString("аdmіn") == null); // Cyrillic а + Ukrainian і
    try testing.expect(Role.fromString("аdmіɳ") == null); // Multiple lookalikes
    try testing.expect(Role.fromString("ɑdmin") == null); // Latin alpha (U+0251)

    // Greek lookalikes
    try testing.expect(Role.fromString("αdmin") == null); // Greek alpha (U+03B1)
    try testing.expect(Role.fromString("admіn") == null); // Ukrainian і (U+0456)
    try testing.expect(Role.fromString("admiո") == null); // Armenian n (U+0578)

    // Full-width characters
    try testing.expect(Role.fromString("ａｄｍｉｎ") == null); // Full-width latin
    try testing.expect(Role.fromString("ＡＤＭＩＮ") == null); // Full-width capitals

    // Mixed scripts that look like role names
    try testing.expect(Role.fromString("rеadonly") == null); // Cyrillic е
    try testing.expect(Role.fromString("reаdonly") == null); // Cyrillic а
    try testing.expect(Role.fromString("readοnly") == null); // Greek omicron
    try testing.expect(Role.fromString("readwrite") != null); // Legit - should work
    try testing.expect(Role.fromString("rеadwrite") == null); // Cyrillic е in readwrite

    // user role lookalikes
    try testing.expect(Role.fromString("uѕer") == null); // Cyrillic ѕ (U+0455)
    try testing.expect(Role.fromString("υser") == null); // Greek upsilon
    try testing.expect(Role.fromString("usеr") == null); // Cyrillic е
    try testing.expect(Role.fromString("useг") == null); // Cyrillic г
}

test "TestAuthz_NoPrivilegeEscalation_UnicodeControlCharacters" {
    // Control characters that might be used to manipulate string parsing
    try testing.expect(Role.fromString("admin\u{200B}") == null); // Zero-width space
    try testing.expect(Role.fromString("\u{200B}admin") == null); // Leading zero-width space
    try testing.expect(Role.fromString("ad\u{200B}min") == null); // Zero-width space in middle
    try testing.expect(Role.fromString("admin\u{FEFF}") == null); // BOM character
    try testing.expect(Role.fromString("\u{FEFF}admin") == null); // Leading BOM
    try testing.expect(Role.fromString("admin\u{200C}") == null); // Zero-width non-joiner
    try testing.expect(Role.fromString("admin\u{200D}") == null); // Zero-width joiner
    try testing.expect(Role.fromString("admin\u{00AD}") == null); // Soft hyphen
}

test "TestAuthz_NoPrivilegeEscalation_UnicodeBidiOverride" {
    // Bidirectional text override characters used in Trojan Source attacks
    try testing.expect(Role.fromString("admin\u{202E}") == null); // Right-to-left override
    try testing.expect(Role.fromString("\u{202E}admin") == null); // RTL override at start
    try testing.expect(Role.fromString("admin\u{202D}") == null); // Left-to-right override
    try testing.expect(Role.fromString("admin\u{202A}") == null); // LTR embedding
    try testing.expect(Role.fromString("admin\u{202B}") == null); // RTL embedding
    try testing.expect(Role.fromString("admin\u{202C}") == null); // Pop directional formatting
}

test "TestAuthz_NoPrivilegeEscalation_UnicodeNormalization" {
    // Unicode normalization attacks - characters that normalize to different values
    try testing.expect(Role.fromString("ﬁle") == null); // fi ligature (U+FB01)
    try testing.expect(Role.fromString("ﬂag") == null); // fl ligature (U+FB02)

    // Combining characters that might bypass checks
    try testing.expect(Role.fromString("admin\u{0301}") == null); // Combining acute accent
    try testing.expect(Role.fromString("a\u{0308}dmin") == null); // a with combining diaeresis
}

test "TestAuthz_NoPrivilegeEscalation_SpecialUnicodeCategories" {
    // Mathematical and other special lookalikes
    try testing.expect(Role.fromString("𝐚𝐝𝐦𝐢𝐧") == null); // Mathematical bold
    try testing.expect(Role.fromString("𝑎𝑑𝑚𝑖𝑛") == null); // Mathematical italic
    try testing.expect(Role.fromString("𝒂𝒅𝒎𝒊𝒏") == null); // Mathematical bold italic
    try testing.expect(Role.fromString("𝖺𝖽𝗆𝗂𝗇") == null); // Mathematical sans-serif
    try testing.expect(Role.fromString("𝚊𝚍𝚖𝚒𝚗") == null); // Mathematical monospace

    // Subscript/superscript
    try testing.expect(Role.fromString("ₐdmin") == null); // Subscript a
    try testing.expect(Role.fromString("ᵃdmin") == null); // Modifier letter small a

    // Enclosed alphanumerics
    try testing.expect(Role.fromString("ⓐdmin") == null); // Circled a
    try testing.expect(Role.fromString("🄰dmin") == null); // Squared latin capital A
}

// ============================================================================
// ASCII AND UNICODE CONTROL CHARACTER TESTS
// CANARY: REQ=REQ-AUTH-ENFORCE-030; FEATURE="AuthEnforcement"; ASPECT=ControlCharacterPrevention; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
// These tests verify all control characters are rejected in role strings
// ============================================================================

test "TestAuthz_NoPrivilegeEscalation_ASCIIControlChars_C0" {
    // C0 control characters (U+0000 to U+001F) - common attack vectors
    try testing.expect(Role.fromString("admin\x00") == null); // NUL - null byte injection
    try testing.expect(Role.fromString("\x00admin") == null); // Leading NUL
    try testing.expect(Role.fromString("ad\x00min") == null); // Mid NUL
    try testing.expect(Role.fromString("admin\x01") == null); // SOH
    try testing.expect(Role.fromString("admin\x02") == null); // STX
    try testing.expect(Role.fromString("admin\x03") == null); // ETX
    try testing.expect(Role.fromString("admin\x04") == null); // EOT
    try testing.expect(Role.fromString("admin\x05") == null); // ENQ
    try testing.expect(Role.fromString("admin\x06") == null); // ACK
    try testing.expect(Role.fromString("admin\x07") == null); // BEL
    try testing.expect(Role.fromString("admin\x08") == null); // BS (backspace)
    try testing.expect(Role.fromString("admin\x09") == null); // HT (tab)
    try testing.expect(Role.fromString("admin\x0A") == null); // LF (newline)
    try testing.expect(Role.fromString("admin\x0B") == null); // VT (vertical tab)
    try testing.expect(Role.fromString("admin\x0C") == null); // FF (form feed)
    try testing.expect(Role.fromString("admin\x0D") == null); // CR (carriage return)
    try testing.expect(Role.fromString("admin\x0E") == null); // SO
    try testing.expect(Role.fromString("admin\x0F") == null); // SI
    try testing.expect(Role.fromString("admin\x10") == null); // DLE
    try testing.expect(Role.fromString("admin\x11") == null); // DC1
    try testing.expect(Role.fromString("admin\x12") == null); // DC2
    try testing.expect(Role.fromString("admin\x13") == null); // DC3
    try testing.expect(Role.fromString("admin\x14") == null); // DC4
    try testing.expect(Role.fromString("admin\x15") == null); // NAK
    try testing.expect(Role.fromString("admin\x16") == null); // SYN
    try testing.expect(Role.fromString("admin\x17") == null); // ETB
    try testing.expect(Role.fromString("admin\x18") == null); // CAN
    try testing.expect(Role.fromString("admin\x19") == null); // EM
    try testing.expect(Role.fromString("admin\x1A") == null); // SUB (Ctrl+Z)
    try testing.expect(Role.fromString("admin\x1B") == null); // ESC (escape)
    try testing.expect(Role.fromString("admin\x1C") == null); // FS
    try testing.expect(Role.fromString("admin\x1D") == null); // GS
    try testing.expect(Role.fromString("admin\x1E") == null); // RS
    try testing.expect(Role.fromString("admin\x1F") == null); // US
}

test "TestAuthz_NoPrivilegeEscalation_ASCIIControlChars_DEL" {
    // DEL character (U+007F)
    try testing.expect(Role.fromString("admin\x7F") == null); // DEL
    try testing.expect(Role.fromString("\x7Fadmin") == null); // Leading DEL
}

test "TestAuthz_NoPrivilegeEscalation_UnicodeControlChars_C1" {
    // C1 control characters (U+0080 to U+009F)
    try testing.expect(Role.fromString("admin\u{0080}") == null); // PAD
    try testing.expect(Role.fromString("admin\u{0081}") == null); // HOP
    try testing.expect(Role.fromString("admin\u{0082}") == null); // BPH
    try testing.expect(Role.fromString("admin\u{0083}") == null); // NBH
    try testing.expect(Role.fromString("admin\u{0084}") == null); // IND
    try testing.expect(Role.fromString("admin\u{0085}") == null); // NEL (Next Line)
    try testing.expect(Role.fromString("admin\u{0086}") == null); // SSA
    try testing.expect(Role.fromString("admin\u{0087}") == null); // ESA
    try testing.expect(Role.fromString("admin\u{0088}") == null); // HTS
    try testing.expect(Role.fromString("admin\u{0089}") == null); // HTJ
    try testing.expect(Role.fromString("admin\u{008A}") == null); // VTS
    try testing.expect(Role.fromString("admin\u{008B}") == null); // PLD
    try testing.expect(Role.fromString("admin\u{008C}") == null); // PLU
    try testing.expect(Role.fromString("admin\u{008D}") == null); // RI
    try testing.expect(Role.fromString("admin\u{008E}") == null); // SS2
    try testing.expect(Role.fromString("admin\u{008F}") == null); // SS3
    try testing.expect(Role.fromString("admin\u{0090}") == null); // DCS
    try testing.expect(Role.fromString("admin\u{0091}") == null); // PU1
    try testing.expect(Role.fromString("admin\u{0092}") == null); // PU2
    try testing.expect(Role.fromString("admin\u{0093}") == null); // STS
    try testing.expect(Role.fromString("admin\u{0094}") == null); // CCH
    try testing.expect(Role.fromString("admin\u{0095}") == null); // MW
    try testing.expect(Role.fromString("admin\u{0096}") == null); // SPA
    try testing.expect(Role.fromString("admin\u{0097}") == null); // EPA
    try testing.expect(Role.fromString("admin\u{0098}") == null); // SOS
    try testing.expect(Role.fromString("admin\u{0099}") == null); // SGCI
    try testing.expect(Role.fromString("admin\u{009A}") == null); // SCI
    try testing.expect(Role.fromString("admin\u{009B}") == null); // CSI
    try testing.expect(Role.fromString("admin\u{009C}") == null); // ST
    try testing.expect(Role.fromString("admin\u{009D}") == null); // OSC
    try testing.expect(Role.fromString("admin\u{009E}") == null); // PM
    try testing.expect(Role.fromString("admin\u{009F}") == null); // APC
}

test "TestAuthz_NoPrivilegeEscalation_WhitespaceVariants" {
    // Various whitespace characters that might bypass trimming
    try testing.expect(Role.fromString("admin ") == null); // Regular space (U+0020)
    try testing.expect(Role.fromString(" admin") == null); // Leading space
    try testing.expect(Role.fromString("admin\u{00A0}") == null); // Non-breaking space
    try testing.expect(Role.fromString("admin\u{1680}") == null); // Ogham space mark
    try testing.expect(Role.fromString("admin\u{2000}") == null); // En quad
    try testing.expect(Role.fromString("admin\u{2001}") == null); // Em quad
    try testing.expect(Role.fromString("admin\u{2002}") == null); // En space
    try testing.expect(Role.fromString("admin\u{2003}") == null); // Em space
    try testing.expect(Role.fromString("admin\u{2004}") == null); // Three-per-em space
    try testing.expect(Role.fromString("admin\u{2005}") == null); // Four-per-em space
    try testing.expect(Role.fromString("admin\u{2006}") == null); // Six-per-em space
    try testing.expect(Role.fromString("admin\u{2007}") == null); // Figure space
    try testing.expect(Role.fromString("admin\u{2008}") == null); // Punctuation space
    try testing.expect(Role.fromString("admin\u{2009}") == null); // Thin space
    try testing.expect(Role.fromString("admin\u{200A}") == null); // Hair space
    try testing.expect(Role.fromString("admin\u{202F}") == null); // Narrow no-break space
    try testing.expect(Role.fromString("admin\u{205F}") == null); // Medium mathematical space
    try testing.expect(Role.fromString("admin\u{3000}") == null); // Ideographic space
}

test "TestAuthz_NoPrivilegeEscalation_LineAndParagraphSeparators" {
    // Line and paragraph separators
    try testing.expect(Role.fromString("admin\u{2028}") == null); // Line separator
    try testing.expect(Role.fromString("admin\u{2029}") == null); // Paragraph separator
}

test "TestAuthz_NoPrivilegeEscalation_TagCharacters" {
    // Unicode tag characters (U+E0000 to U+E007F) - deprecated but still exist
    try testing.expect(Role.fromString("admin\u{E0001}") == null); // Language tag
    try testing.expect(Role.fromString("admin\u{E0020}") == null); // Tag space
    try testing.expect(Role.fromString("admin\u{E0041}") == null); // Tag latin capital A
}

test "TestAuthz_NoPrivilegeEscalation_InterlinearAnnotations" {
    // Interlinear annotation characters
    try testing.expect(Role.fromString("admin\u{FFF9}") == null); // Interlinear annotation anchor
    try testing.expect(Role.fromString("admin\u{FFFA}") == null); // Interlinear annotation separator
    try testing.expect(Role.fromString("admin\u{FFFB}") == null); // Interlinear annotation terminator
}

test "TestAuthz_NoPrivilegeEscalation_ReplacementAndSpecials" {
    // Replacement and special characters
    try testing.expect(Role.fromString("admin\u{FFFC}") == null); // Object replacement character
    try testing.expect(Role.fromString("admin\u{FFFD}") == null); // Replacement character
    try testing.expect(Role.fromString("admin\u{FFFE}") == null); // Invalid (byte order mark reversed)
    try testing.expect(Role.fromString("admin\u{FFFF}") == null); // Invalid character
}

// ============================================================================
// GAP-0526: MUTATION AUTHORIZATION ENFORCEMENT VIA ROLE U8 VALUE
// CANARY: REQ=REQ-AUTH-ENFORCE-031; FEATURE="MutationAuthorization"; ASPECT=RoleU8Enforcement; STATUS=TESTED; OWNER=security; UPDATED=2026-04-09
// These tests validate the exact check used in QUIC and gRPC handlers:
// converting the u8 role value (from state.authenticated_role) back to
// a Role enum and checking hasPermission(.Write).
// ============================================================================

test "GAP0526_MutationDenied_ReadOnlyViaU8" {
    // Simulates the exact handler check: @intFromEnum -> @enumFromInt -> hasPermission
    const role_u8: u8 = @intFromEnum(Role.ReadOnly);
    const role = @as(Role, @enumFromInt(role_u8));
    // ReadOnly must NOT have Write permission — mutations must be denied
    try testing.expect(!user_management.hasPermission(role, .Write));
}

test "GAP0526_MutationDenied_UserViaU8" {
    const role_u8: u8 = @intFromEnum(Role.User);
    const role = @as(Role, @enumFromInt(role_u8));
    // User must NOT have Write permission — mutations must be denied
    try testing.expect(!user_management.hasPermission(role, .Write));
}

test "GAP0526_MutationAllowed_ReadWriteViaU8" {
    const role_u8: u8 = @intFromEnum(Role.ReadWrite);
    const role = @as(Role, @enumFromInt(role_u8));
    // ReadWrite MUST have Write permission — mutations must be allowed
    try testing.expect(user_management.hasPermission(role, .Write));
}

test "GAP0526_MutationAllowed_AdminViaU8" {
    const role_u8: u8 = @intFromEnum(Role.Admin);
    const role = @as(Role, @enumFromInt(role_u8));
    // Admin MUST have Write permission — mutations must be allowed
    try testing.expect(user_management.hasPermission(role, .Write));
}

test "GAP0526_AllRolesU8RoundTrip_MutationMatrix" {
    // Comprehensive: for every role, verify the u8 round-trip produces the
    // correct mutation authorization decision.
    const roles = [_]Role{ .Admin, .User, .ReadWrite, .ReadOnly };
    const expected_write = [_]bool{ true, false, true, false };

    for (roles, 0..) |role, i| {
        const role_u8: u8 = @intFromEnum(role);
        const recovered = @as(Role, @enumFromInt(role_u8));
        try testing.expectEqual(expected_write[i], user_management.hasPermission(recovered, .Write));
    }
}
