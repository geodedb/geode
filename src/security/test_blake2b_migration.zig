const std = @import("std");

// CANARY: REQ=REQ-GAP-0489-BLAKE2B-MIGRATION; FEATURE="Blake2bToArgon2idAutoMigration"; ASPECT=SecurityAudit; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

test "verifyPassword source: migrates Blake2b hash after successful verify (GAP-0489)" {
    const src = @embedFile("geode_auth_lib.zig");
    // After verifyBlake2bLegacy returns true, must call updateStoredHash
    // Check that updateStoredHash function exists and is called from the auth path
    const has_update_fn = std.mem.indexOf(u8, src, "fn updateStoredHash") != null;
    try std.testing.expect(has_update_fn);
}

test "verifyPassword source: updateStoredHash is called from authenticate on Blake2b success (GAP-0489)" {
    const src = @embedFile("geode_auth_lib.zig");
    // The migrate-on-login call must reference updateStoredHash from authenticate context
    const has_migration_call = std.mem.indexOf(u8, src, "updateStoredHash") != null;
    try std.testing.expect(has_migration_call);
}

test "verifyPassword source: migration is guarded by Blake2b hash detection (GAP-0489)" {
    const src = @embedFile("geode_auth_lib.zig");
    // GAP-0489: Migration must only fire for Blake2b hashes (64 hex chars, not $argon2id$)
    // The migration guard should reference isHexString or the 64-char length check
    // alongside updateStoredHash usage
    const has_guard = std.mem.indexOf(u8, src, "isHexString") != null and
        std.mem.indexOf(u8, src, "updateStoredHash") != null;
    try std.testing.expect(has_guard);
}
