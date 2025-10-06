const std = @import("std");
const testing = std.testing;
const kms = @import("../src/security/kms.zig");

// CANARY: REQ=REQ-GQL-SEC-KMS-001; FEATURE="KMSProviderSystem"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KMS_001_ComprehensiveKMSProvider; OWNER=security; UPDATED=2025-10-05

test "TestCANARY_REQ_GQL_SEC_KMS_001_ComprehensiveKMSProvider" {
    const allocator = testing.allocator;
    
    // Test all three provider types
    const provider_configs = [_]kms.KMSConfig{
        .{ .provider_type = .local_dev },
        .{ .provider_type = .external_kms, .seed = 0x123456789ABCDEF0 },
        .{ .provider_type = .remote_kms, .endpoint = "localhost", .port = 3141, .auth_token = "test_token" },
    };
    
    for (provider_configs) |config| {
        var provider = kms.KMSProvider.init(allocator, config);
        defer provider.deinit();
        
        // Test provider info
        const info = provider.getProviderInfo();
        try testing.expectEqual(config.provider_type, info.provider_type);
        try testing.expectEqual(config.auth_token != null, info.authenticated);
        
        // Test master key ID generation
        if (config.provider_type != .remote_kms) { // Skip remote for unit tests
            const master_key_id = try provider.fetchActiveMasterKey();
            try testing.expect(master_key_id.len > 0);
            
            if (config.provider_type == .local_dev) {
                try testing.expectEqualStrings("local-dev-master-key-v1", master_key_id);
            } else if (config.provider_type == .external_kms) {
                defer allocator.free(master_key_id);
                try testing.expect(std.mem.startsWith(u8, master_key_id, "external-kms-"));
            }
        }
    }
}

test "KMS local dev provider security warning" {
    const allocator = testing.allocator;
    var provider = kms.localDevProvider(allocator);
    defer provider.deinit();
    
    const plaintext1 = "test_data_key_12345678901234567890"; // 32 bytes
    const plaintext2 = "different_key_098765432109876543"; // 32 bytes
    
    var wrapped1 = try provider.wrapDataKey(plaintext1);
    defer wrapped1.deinit(allocator);
    
    var wrapped2 = try provider.wrapDataKey(plaintext2);
    defer wrapped2.deinit(allocator);
    
    // Different plaintexts should produce different ciphertexts
    try testing.expect(!std.mem.eql(u8, wrapped1.ciphertext, wrapped2.ciphertext));
    
    // Verify unwrapping works correctly
    const unwrapped1 = try provider.unwrapDataKey(wrapped1);
    defer allocator.free(unwrapped1);
    
    const unwrapped2 = try provider.unwrapDataKey(wrapped2);
    defer allocator.free(unwrapped2);
    
    try testing.expectEqualSlices(u8, plaintext1, unwrapped1);
    try testing.expectEqualSlices(u8, plaintext2, unwrapped2);
}

test "KMS external provider deterministic behavior" {
    const allocator = testing.allocator;
    
    // Same seed should produce same results
    var provider1 = kms.externalKMSProvider(allocator, 0xDEADBEEFCAFEBABE);
    defer provider1.deinit();
    
    var provider2 = kms.externalKMSProvider(allocator, 0xDEADBEEFCAFEBABE);
    defer provider2.deinit();
    
    const plaintext = "test_deterministic_behavior_32b"; // 32 bytes
    
    var wrapped1 = try provider1.wrapDataKey(plaintext);
    defer wrapped1.deinit(allocator);
    
    var wrapped2 = try provider2.wrapDataKey(plaintext);
    defer wrapped2.deinit(allocator);
    
    // Same seed + same plaintext should produce identical results
    try testing.expectEqualSlices(u8, wrapped1.ciphertext, wrapped2.ciphertext);
    try testing.expectEqualSlices(u8, wrapped1.metadata.?, wrapped2.metadata.?);
    
    // Verify both unwrap to original plaintext
    const unwrapped1 = try provider1.unwrapDataKey(wrapped1);
    defer allocator.free(unwrapped1);
    
    const unwrapped2 = try provider2.unwrapDataKey(wrapped2);
    defer allocator.free(unwrapped2);
    
    try testing.expectEqualSlices(u8, plaintext, unwrapped1);
    try testing.expectEqualSlices(u8, plaintext, unwrapped2);
}

test "KMS external provider different seeds" {
    const allocator = testing.allocator;
    
    var provider1 = kms.externalKMSProvider(allocator, 0x1111111111111111);
    defer provider1.deinit();
    
    var provider2 = kms.externalKMSProvider(allocator, 0x2222222222222222);
    defer provider2.deinit();
    
    const plaintext = "same_plaintext_different_seeds_32"; // 32 bytes
    
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
    const allocator = testing.allocator;
    
    // Test local dev provider (no metadata)
    var local_provider = kms.localDevProvider(allocator);
    defer local_provider.deinit();
    
    const plaintext = "metadata_test_key_123456789012345"; // 32 bytes
    var local_wrapped = try local_provider.wrapDataKey(plaintext);
    defer local_wrapped.deinit(allocator);
    
    try testing.expect(local_wrapped.metadata == null);
    
    // Test external KMS provider (has metadata)
    var external_provider = kms.externalKMSProvider(allocator, 0xFEEDFACEDEADBEEF);
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
    const allocator = testing.allocator;
    
    // Test invalid key length for external KMS
    var external_provider = kms.externalKMSProvider(allocator, 0x4242424242424242);
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
    const allocator = testing.allocator;
    
    // Test localDevProvider factory
    var local = kms.localDevProvider(allocator);
    defer local.deinit();
    try testing.expectEqual(kms.KMSProviderType.local_dev, local.config.provider_type);
    
    // Test externalKMSProvider factory
    const seed = 0x1337C0DE;
    var external = kms.externalKMSProvider(allocator, seed);
    defer external.deinit();
    try testing.expectEqual(kms.KMSProviderType.external_kms, external.config.provider_type);
    try testing.expectEqual(seed, external.config.seed.?);
    
    // Test remoteKMSProvider factory
    const endpoint = "kms.example.com";
    const port = 9443;
    const auth_token = "secure_token_123";
    var remote = kms.remoteKMSProvider(allocator, endpoint, port, auth_token);
    defer remote.deinit();
    try testing.expectEqual(kms.KMSProviderType.remote_kms, remote.config.provider_type);
    try testing.expectEqualStrings(endpoint, remote.config.endpoint.?);
    try testing.expectEqual(port, remote.config.port.?);
    try testing.expectEqualStrings(auth_token, remote.config.auth_token.?);
    
    // Test defaultProvider legacy function
    var default = kms.defaultProvider();
    defer default.deinit();
    try testing.expectEqual(kms.KMSProviderType.local_dev, default.config.provider_type);
}

test "KMS custom master key ID" {
    const allocator = testing.allocator;
    
    const custom_key_id = "custom-enterprise-key-2025";
    var provider = kms.KMSProvider.init(allocator, kms.KMSConfig{
        .provider_type = .local_dev,
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
    const allocator = testing.allocator;
    
    // Test that providers with same seed produce compatible results
    const seed = 0xABCDEF0123456789;
    
    var provider1 = kms.externalKMSProvider(allocator, seed);
    defer provider1.deinit();
    
    var provider2 = kms.externalKMSProvider(allocator, seed);
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
    const allocator = testing.allocator;
    var provider = kms.externalKMSProvider(allocator, 0x1122334455667788);
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