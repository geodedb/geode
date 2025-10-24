const std = @import("std");
const testing = std.testing;
const tde_kms = @import("../src/security/tde_kms_integration.zig");
const kms = @import("../src/security/kms.zig");

// CANARY: REQ=REQ-GQL-TDE-KMS-001; FEATURE="TDEKMSIntegration"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_KMS_001_ComprehensiveTDEKMS; OWNER=security; UPDATED=2025-10-05

test "TestCANARY_REQ_GQL_TDE_KMS_001_ComprehensiveTDEKMS" {
    const allocator = testing.allocator;

    // Test TDE with local dev KMS provider
    {
        var manager = tde_kms.TDEKeyManager.init(allocator);
        defer manager.deinit();

        // Enable TDE for testing
        const flags_mod = @import("../src/util/feature_flags.zig");
        flags_mod.global().tde.enableForTests();
        defer flags_mod.global().tde.disableForTests();

        // Initialize with local dev KMS
        try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .local_dev });

        // Verify initialization
        const status = manager.getStatus();
        try testing.expect(status.loaded);
        try testing.expect(status.key_id != null);
        try testing.expectEqual(kms.KMSProviderType.local_dev, status.provider_type.?);

        // Test key retrieval
        const data_key = try manager.getDataKey();
        const wal_key = try manager.getWALKey();

        // Keys should be different
        try testing.expect(!std.mem.eql(u8, &data_key, &wal_key));
    }

    // Test TDE with external KMS provider
    {
        var manager = tde_kms.TDEKeyManager.init(allocator);
        defer manager.deinit();

        const flags_mod = @import("../src/util/feature_flags.zig");
        flags_mod.global().tde.enableForTests();
        defer flags_mod.global().tde.disableForTests();

        const seed = 0xDEADBEEFCAFEBABE;
        try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .external_kms, .seed = seed });

        const status = manager.getStatus();
        try testing.expect(status.loaded);
        try testing.expectEqual(kms.KMSProviderType.external_kms, status.provider_type.?);

        // Test operations
        var ops = tde_kms.TDEOperations.init(&manager);

        const plaintext = "test data for encryption with external KMS";
        const aad = "additional authenticated data";

        var encrypted = try ops.encryptData(allocator, plaintext, aad);
        defer encrypted.deinit(allocator);

        const decrypted = try ops.decryptData(allocator, encrypted, aad);
        defer allocator.free(decrypted);

        try testing.expectEqualSlices(u8, plaintext, decrypted);
    }
}

test "TDE KMS key rotation" {
    const allocator = testing.allocator;

    var manager = tde_kms.TDEKeyManager.init(allocator);
    defer manager.deinit();

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    // Initialize with external KMS
    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .external_kms, .seed = 0x1234567890ABCDEF });

    // Get initial keys
    const initial_data_key = try manager.getDataKey();
    const initial_wal_key = try manager.getWALKey();
    const initial_status = manager.getStatus();

    // Wait a moment to ensure timestamp difference
    std.time.sleep(1000000); // 1ms

    // Rotate keys
    try manager.rotateKeys();

    // Get new keys
    const new_data_key = try manager.getDataKey();
    const new_wal_key = try manager.getWALKey();
    const new_status = manager.getStatus();

    // Keys should be different after rotation
    try testing.expect(!std.mem.eql(u8, &initial_data_key, &new_data_key));
    try testing.expect(!std.mem.eql(u8, &initial_wal_key, &new_wal_key));

    // Status should reflect rotation
    try testing.expect(new_status.last_rotation.? > initial_status.last_rotation.?);
}

test "TDE operations data vs WAL encryption" {
    const allocator = testing.allocator;

    var manager = tde_kms.TDEKeyManager.init(allocator);
    defer manager.deinit();

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .local_dev });

    var ops = tde_kms.TDEOperations.init(&manager);

    const plaintext = "sensitive database page content";
    const aad = "page_metadata";

    // Encrypt same data with both data and WAL keys
    var data_encrypted = try ops.encryptData(allocator, plaintext, aad);
    defer data_encrypted.deinit(allocator);

    var wal_encrypted = try ops.encryptWAL(allocator, plaintext, aad);
    defer wal_encrypted.deinit(allocator);

    // Ciphertexts should be different (different keys)
    try testing.expect(!std.mem.eql(u8, data_encrypted.ciphertext, wal_encrypted.ciphertext));

    // Both should decrypt correctly with their respective methods
    const data_decrypted = try ops.decryptData(allocator, data_encrypted, aad);
    defer allocator.free(data_decrypted);

    const wal_decrypted = try ops.decryptWAL(allocator, wal_encrypted, aad);
    defer allocator.free(wal_decrypted);

    try testing.expectEqualSlices(u8, plaintext, data_decrypted);
    try testing.expectEqualSlices(u8, plaintext, wal_decrypted);
}

test "TDE environment variable fallback" {
    const allocator = testing.allocator;

    // Set test TDE key
    try std.process.setEnvVar("GEODE_TDE_KEY", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

    var manager = tde_kms.TDEKeyManager.init(allocator);
    defer manager.deinit();

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    // Initialize with environment variable
    try manager.initializeWithEnv();

    const status = manager.getStatus();
    try testing.expect(status.loaded);
    try testing.expectEqualStrings("env-tde-key", status.key_id.?);
    try testing.expect(status.provider_type == null); // Environment mode

    // Test encryption/decryption works
    var ops = tde_kms.TDEOperations.init(&manager);

    const plaintext = "test environment TDE";
    const aad = "env_test";

    var encrypted = try ops.encryptData(allocator, plaintext, aad);
    defer encrypted.deinit(allocator);

    const decrypted = try ops.decryptData(allocator, encrypted, aad);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "TDE factory functions" {
    const allocator = testing.allocator;

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    // Test local dev TDE factory
    {
        var local_tde = try tde_kms.createLocalDevTDE(allocator);
        defer local_tde.deinit();

        const status = local_tde.getStatus();
        try testing.expect(status.loaded);
        try testing.expectEqual(kms.KMSProviderType.local_dev, status.provider_type.?);
    }

    // Test external KMS TDE factory
    {
        var external_tde = try tde_kms.createExternalKMSTDE(allocator, 0xFEEDFACE);
        defer external_tde.deinit();

        const status = external_tde.getStatus();
        try testing.expect(status.loaded);
        try testing.expectEqual(kms.KMSProviderType.external_kms, status.provider_type.?);
    }

    // Test environment TDE factory
    {
        try std.process.setEnvVar("GEODE_TDE_KEY", "deadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabe");
        defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

        var env_tde = try tde_kms.createEnvTDE(allocator);
        defer env_tde.deinit();

        const status = env_tde.getStatus();
        try testing.expect(status.loaded);
        try testing.expect(status.provider_type == null);
    }
}

test "TDE error handling" {
    const allocator = testing.allocator;

    // Test with TDE disabled
    {
        var manager = tde_kms.TDEKeyManager.init(allocator);
        defer manager.deinit();

        // TDE should be disabled by default
        const result = manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .local_dev });
        try testing.expectError(error.TDENotEnabled, result);
    }

    // Test invalid environment key
    {
        try std.process.setEnvVar("GEODE_TDE_KEY", "invalid_short_key");
        defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

        var manager = tde_kms.TDEKeyManager.init(allocator);
        defer manager.deinit();

        const flags_mod = @import("../src/util/feature_flags.zig");
        flags_mod.global().tde.enableForTests();
        defer flags_mod.global().tde.disableForTests();

        const result = manager.initializeWithEnv();
        try testing.expectError(error.InvalidTDEKey, result);
    }

    // Test operations on uninitialized manager
    {
        var manager = tde_kms.TDEKeyManager.init(allocator);
        defer manager.deinit();

        const data_key_result = manager.getDataKey();
        try testing.expectError(error.TDENotInitialized, data_key_result);

        const wal_key_result = manager.getWALKey();
        try testing.expectError(error.TDENotInitialized, wal_key_result);
    }
}

test "TDE cross-provider determinism" {
    const allocator = testing.allocator;

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    const seed = 0xDEADBEEFCAFEBABE;

    // Create two managers with same external KMS seed
    var manager1 = tde_kms.TDEKeyManager.init(allocator);
    defer manager1.deinit();

    var manager2 = tde_kms.TDEKeyManager.init(allocator);
    defer manager2.deinit();

    try manager1.initializeWithKMS(kms.KMSConfig{ .provider_type = .external_kms, .seed = seed });

    try manager2.initializeWithKMS(kms.KMSConfig{ .provider_type = .external_kms, .seed = seed });

    // Same seed should produce same keys (deterministic KMS)
    const data_key1 = try manager1.getDataKey();
    const data_key2 = try manager2.getDataKey();

    try testing.expectEqualSlices(u8, &data_key1, &data_key2);

    const wal_key1 = try manager1.getWALKey();
    const wal_key2 = try manager2.getWALKey();

    try testing.expectEqualSlices(u8, &wal_key1, &wal_key2);
}

test "TDE large scale encryption performance" {
    const allocator = testing.allocator;

    var manager = tde_kms.TDEKeyManager.init(allocator);
    defer manager.deinit();

    const flags_mod = @import("../src/util/feature_flags.zig");
    flags_mod.global().tde.enableForTests();
    defer flags_mod.global().tde.disableForTests();

    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .local_dev });

    var ops = tde_kms.TDEOperations.init(&manager);

    // Test with various data sizes
    const test_sizes = [_]usize{ 1024, 4096, 16384, 65536 }; // 1KB to 64KB

    for (test_sizes) |size| {
        const plaintext = try allocator.alloc(u8, size);
        defer allocator.free(plaintext);

        // Fill with test pattern
        for (plaintext, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast(i % 256));
        }

        const aad = "performance_test";

        var encrypted = try ops.encryptData(allocator, plaintext, aad);
        defer encrypted.deinit(allocator);

        const decrypted = try ops.decryptData(allocator, encrypted, aad);
        defer allocator.free(decrypted);

        try testing.expectEqualSlices(u8, plaintext, decrypted);
    }
}
