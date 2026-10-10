const std = @import("std");
const geode = @import("geode");
const fle_key_manager = geode.fle_key_manager;
const fle_key_types = geode.fle_key_types;
// const fle_commands = geode.fle_commands; // Not used directly in this test yet

// libc setenv shim (Zig 0.16 removed std.posix.setenv): the FLE key manager
// reads GEODE_MASTER_KEY via std.c.getenv and fails closed without it.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// 32-byte secret (hex) for the FLE master key -- test-only, never a real secret.
const TEST_MASTER_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; // gitleaks:allow — deterministic test key fixture

test "FLE complete lifecycle" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // SONNY-2394: this lifecycle test never supplied a master key, so it only
    // ever passed with an ambient GEODE_MASTER_KEY; the sharded pre-push/CI
    // gate deliberately sets none (fail-closed production requirement,
    // unchanged). Install a deterministic test key -- the pattern the other
    // FLE suites use (tests/test_gap0854_fle_chain.zig) -- and restore the
    // caller's environment afterwards. Key rotation below is in-memory only.
    const saved_key: ?[:0]u8 = if (std.c.getenv("GEODE_MASTER_KEY")) |v| try allocator.dupeZ(u8, std.mem.span(v)) else null;
    defer if (saved_key) |v| {
        _ = setenv("GEODE_MASTER_KEY", v.ptr, 1);
        allocator.free(v);
    } else {
        _ = unsetenv("GEODE_MASTER_KEY");
    };
    try std.testing.expect(setenv("GEODE_MASTER_KEY", TEST_MASTER_KEY_HEX, 1) == 0);

    // 1. Init Manager
    const manager = try fle_key_manager.initFromEnv(allocator);
    defer manager.deinit();

    // 2. Derive initial keys
    // This implicitly tests derivation logic
    const key_ids = fle_key_types.KeyIds{
        .tenant = "tenant1",
        .schema = "Person",
        .field = "ssn",
        .version = 1,
    };
    // getFEK should succeed for version 1
    const fek1 = try manager.getFEK(key_ids);
    // Ensure we got a valid key (32 bytes)
    try std.testing.expectEqual(@as(usize, 32), fek1.len);

    // 3. Rotate FEK
    // This simulates the CLI command `geode fle rotate-key tenant1 fek Person ssn`
    const new_ver = try manager.rotateFEK("tenant1", "Person", "ssn");
    // In the current local simulation, it should return 2 (assuming start at 1)
    // If manager.zig defaults to returning current+1, and current defaults to 1.
    try std.testing.expect(new_ver > 1);

    // 4. Verify we can get the new key
    const key_ids_2 = fle_key_types.KeyIds{
        .tenant = "tenant1",
        .schema = "Person",
        .field = "ssn",
        .version = new_ver,
    };
    const fek2 = try manager.getFEK(key_ids_2);
    try std.testing.expectEqual(@as(usize, 32), fek2.len);

    // Ensure keys are different (rotation actually changed something in derivation path or random)
    // Note: Since FEK depends on HKDF(SK, field, version), changing version MUST change FEK
    try std.testing.expect(!std.mem.eql(u8, &fek1, &fek2));

    // 5. Rewrap SK
    // `geode fle rotate-key tenant1 sk Person`
    try fle_key_manager.rewrapSchemaKey(allocator, manager, "tenant1", "Person");

    // 6. Rewrap TRK
    // `geode fle rotate-key tenant1 trk`
    try fle_key_manager.rewrapTenantRootKey(allocator, manager, "tenant1");

    // 7. Verify post-rotation derivation still works
    // After TRK/SK rewrap, getFEK should still work (it derives from new/current defaults)
    const fek3 = try manager.getFEK(key_ids_2);
    try std.testing.expectEqual(@as(usize, 32), fek3.len);
}
