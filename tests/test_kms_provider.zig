const std = @import("std");
const testing = std.testing;
const kms = @import("security/kms");

// CANARY: REQ=REQ-GQL-SEC-KMS-001; FEATURE="KMSProviderSystem"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KMS_001_ComprehensiveKMSProvider; OWNER=security; UPDATED=2025-10-05

test "TestCANARY_REQ_GQL_SEC_KMS_001_ComprehensiveKMSProvider" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    // The provider KMSProvider implements (SONNY-2441 removed remote_kms,
    // SONNY-6448 local_dev).
    const provider_configs = [_]kms.KMSConfig{
        .{ .provider_type = .external_kms, .seed = 0x123456789ABCDEF0 },
    };

    for (provider_configs) |config| {
        var provider = try kms.KMSProvider.init(allocator, config);
        defer provider.deinit();

        // Test provider info
        const info = provider.getProviderInfo();
        try testing.expectEqual(config.provider_type, info.provider_type);
        try testing.expectEqual(config.auth_token != null, info.authenticated);

        // Test master key ID generation
        const master_key_id = try provider.fetchActiveMasterKey();
        try testing.expect(master_key_id.len > 0);

        defer allocator.free(master_key_id);
        try testing.expect(std.mem.startsWith(u8, master_key_id, "external-kms-"));
    }
}

test "KMS external provider deterministic behavior" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Same seed: the same wrapping key
    var provider1 = try kms.externalKMSProvider(allocator, 0xDEADBEEFCAFEBABE);
    defer provider1.deinit();

    var provider2 = try kms.externalKMSProvider(allocator, 0xDEADBEEFCAFEBABE);
    defer provider2.deinit();

    const plaintext = "test_deterministic_behavior_32b!"; // 32 bytes

    var wrapped1 = try provider1.wrapDataKey(plaintext);
    defer wrapped1.deinit(allocator);

    var wrapped2 = try provider2.wrapDataKey(plaintext);
    defer wrapped2.deinit(allocator);

    // Each wrap draws a fresh random nonce (GAP-0017/GAP-0069), so two
    // wraps of the same key differ; a repeated nonce under one key would
    // break AES-GCM.
    try testing.expect(!std.mem.eql(u8, wrapped1.metadata.?, wrapped2.metadata.?));

    // The seed determines the key: each provider unwraps the other's wrap.
    const unwrapped1 = try provider1.unwrapDataKey(wrapped2);
    defer allocator.free(unwrapped1);

    const unwrapped2 = try provider2.unwrapDataKey(wrapped1);
    defer allocator.free(unwrapped2);

    try testing.expectEqualSlices(u8, plaintext, unwrapped1);
    try testing.expectEqualSlices(u8, plaintext, unwrapped2);
}

test "KMS external provider different seeds" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    var provider1 = try kms.externalKMSProvider(allocator, 0x1111111111111111);
    defer provider1.deinit();

    var provider2 = try kms.externalKMSProvider(allocator, 0x2222222222222222);
    defer provider2.deinit();

    const plaintext = "same_plaintext_different_seed_32"; // 32 bytes

    var wrapped1 = try provider1.wrapDataKey(plaintext);
    defer wrapped1.deinit(allocator);

    var wrapped2 = try provider2.wrapDataKey(plaintext);
    defer wrapped2.deinit(allocator);

    // Different seeds should produce different ciphertexts
    try testing.expect(!std.mem.eql(u8, wrapped1.ciphertext, wrapped2.ciphertext));
    try testing.expect(!std.mem.eql(u8, wrapped1.metadata.?, wrapped2.metadata.?));

    // But both should unwrap to original plaintext
    const unwrapped1 = try provider1.unwrapDataKey(wrapped1);
    defer allocator.free(unwrapped1);

    const unwrapped2 = try provider2.unwrapDataKey(wrapped2);
    defer allocator.free(unwrapped2);

    try testing.expectEqualSlices(u8, plaintext, unwrapped1);
    try testing.expectEqualSlices(u8, plaintext, unwrapped2);
}

test "KMS metadata handling" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    const plaintext = "metadata_test_key_12345678901234"; // 32 bytes

    // External KMS provider (has metadata)
    var external_provider = try kms.externalKMSProvider(allocator, 0xFEEDFACEDEADBEEF);
    defer external_provider.deinit();

    var external_wrapped = try external_provider.wrapDataKey(plaintext);
    defer external_wrapped.deinit(allocator);

    try testing.expect(external_wrapped.metadata != null);
    try testing.expect(external_wrapped.metadata.?.len > 0);

    // Verify metadata contains expected JSON fields
    const metadata = external_wrapped.metadata.?;
    try testing.expect(std.mem.indexOf(u8, metadata, "\"version\":") != null);
    try testing.expect(std.mem.indexOf(u8, metadata, "\"alg\":\"AES-256-GCM\"") != null);
    try testing.expect(std.mem.indexOf(u8, metadata, "\"nonce\":") != null);
    try testing.expect(std.mem.indexOf(u8, metadata, "\"tag\":") != null);
    try testing.expect(std.mem.indexOf(u8, metadata, "\"ct\":") != null);
}

test "KMS error handling" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Test invalid key length for external KMS
    var external_provider = try kms.externalKMSProvider(allocator, 0x4242424242424242);
    defer external_provider.deinit();

    const short_plaintext = "too_short"; // Less than 32 bytes
    const result = external_provider.wrapDataKey(short_plaintext);
    try testing.expectError(error.InvalidKeyLength, result);

    // Test missing metadata for unwrapping
    const invalid_wrapped = kms.WrappedKey{
        .key_id = "test-key",
        .ciphertext = try allocator.alloc(u8, 32),
        .metadata = null,
    };
    defer allocator.free(invalid_wrapped.ciphertext);

    const unwrap_result = external_provider.unwrapDataKey(invalid_wrapped);
    try testing.expectError(error.MissingMetadata, unwrap_result);
}

test "KMS factory functions" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Test externalKMSProvider factory
    const seed = 0x1337C0DE;
    var external = try kms.externalKMSProvider(allocator, seed);
    defer external.deinit();
    try testing.expectEqual(kms.KMSProviderType.external_kms, external.config.provider_type);
    try testing.expectEqual(seed, external.config.seed.?);
}

test "KMS custom master key ID" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    const custom_key_id = "custom-enterprise-key-2025";
    var provider = try kms.KMSProvider.init(allocator, kms.KMSConfig{
        .provider_type = .external_kms,
        .seed = 0xC0570A,
        .master_key_id = custom_key_id,
    });
    defer provider.deinit();

    const fetched_key_id = try provider.fetchActiveMasterKey();
    try testing.expectEqualStrings(custom_key_id, fetched_key_id);

    // Verify it's used in wrapping
    const plaintext = "test_custom_key_id_1234567890123"; // 32 bytes
    var wrapped = try provider.wrapDataKey(plaintext);
    defer wrapped.deinit(allocator);

    try testing.expectEqualStrings(custom_key_id, wrapped.key_id);
}

test "KMS cross-provider compatibility" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Test that providers with same seed produce compatible results
    const seed = 0xABCDEF0123456789;

    var provider1 = try kms.externalKMSProvider(allocator, seed);
    defer provider1.deinit();

    var provider2 = try kms.externalKMSProvider(allocator, seed);
    defer provider2.deinit();

    const plaintext = "cross_provider_compatibility_32b"; // 32 bytes

    // Wrap with provider1
    var wrapped = try provider1.wrapDataKey(plaintext);
    defer wrapped.deinit(allocator);

    // Unwrap with provider2 (should work)
    const unwrapped = try provider2.unwrapDataKey(wrapped);
    defer allocator.free(unwrapped);

    try testing.expectEqualSlices(u8, plaintext, unwrapped);
}

test "KMS large scale operations" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const allocator = testing.allocator;
    var provider = try kms.externalKMSProvider(allocator, 0x1122334455667788);
    defer provider.deinit();

    const num_operations = 10;
    var wrapped_keys: [num_operations]kms.WrappedKey = undefined;
    var plaintexts: [num_operations][32]u8 = undefined;

    // Generate and wrap multiple keys
    for (0..num_operations) |i| {
        // Generate unique plaintext
        for (0..32) |j| {
            plaintexts[i][j] = @as(u8, @intCast((i * 32 + j) % 256));
        }

        wrapped_keys[i] = try provider.wrapDataKey(&plaintexts[i]);
    }

    // Unwrap and verify all keys
    for (0..num_operations) |i| {
        const unwrapped = try provider.unwrapDataKey(wrapped_keys[i]);
        defer allocator.free(unwrapped);

        try testing.expectEqualSlices(u8, &plaintexts[i], unwrapped);

        // Clean up wrapped key
        wrapped_keys[i].deinit(allocator);
    }
}

// SONNY-6453: moved from src/security/kms.zig, whose inline tests ran in no
// step (the ones test_kms_provider.zig did not already cover).
test "KMS provider types report their configuration (external_kms, vault_transit)" {
    // SONNY-6775: a release build refuses external_kms (UnsafeKMSProvider, by
    // design); this test needs a Debug build to construct one.
    if (kms.is_production_build) return error.SkipZigTest;
    const configs = [_]kms.KMSConfig{
        .{ .provider_type = .external_kms, .seed = 0x12345 },
        .{ .provider_type = .vault_transit, .endpoint = "https://vault.example.com", .auth_token = "test_token" },
    };
    for (configs) |config| {
        var provider = try kms.KMSProvider.init(testing.allocator, config);
        defer provider.deinit();
        const info = provider.getProviderInfo();
        try testing.expectEqual(config.provider_type, info.provider_type);
        try testing.expectEqual(config.auth_token != null, info.authenticated);
    }
}

test "GAP-0066: isProductionSafe identifies external_kms as unsafe and vault_transit as safe" {
    try testing.expect(!kms.KMSProviderType.external_kms.isProductionSafe());
    try testing.expect(kms.KMSProviderType.vault_transit.isProductionSafe());
}

test "GAP-0066: default config is external_kms" {
    const default_config = kms.KMSConfig{};
    try testing.expectEqual(kms.KMSProviderType.external_kms, default_config.provider_type);
}

test "SONNY-6775: a release build refuses the non-production external_kms provider" {
    if (!kms.is_production_build) return error.SkipZigTest;
    try testing.expectError(error.UnsafeKMSProvider, kms.KMSProvider.init(testing.allocator, .{ .provider_type = .external_kms, .seed = 1 }));
}
