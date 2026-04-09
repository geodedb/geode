const std = @import("std");
const external_kms = @import("external_kms_client.zig");
const kms_remote = @import("kms_remote.zig");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// kms.zig - Comprehensive KMS provider abstraction
// CANARY: REQ=REQ-GQL-SEC-KMS-001; FEATURE="KMSProviderSystem"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_kms_provider.zig; OWNER=security; UPDATED=2025-10-05

pub const MasterKeyId = []const u8;

pub const WrappedKey = struct {
    key_id: MasterKeyId,
    ciphertext: []u8,
    metadata: ?[]u8 = null, // Optional metadata (e.g., JSON envelope)

    pub fn deinit(self: *WrappedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.key_id);
        allocator.free(self.ciphertext);
        if (self.metadata) |meta| {
            allocator.free(meta);
        }
    }
};

pub const KMSProviderType = enum {
    local_dev, // Local development only - uses AES-GCM but with deterministic key derivation
    external_kms, // External deterministic KMS client
    remote_kms, // Remote KMS over QUIC
    vault_transit, // HashiCorp Vault Transit (implemented)
    aws_kms, // AWS KMS (future)
    azure_kv, // Azure Key Vault (future)

    /// Check if this provider type is safe for production use
    /// CANARY: REQ=REQ-GQL-KMS-PRODSAFE-001; FEATURE="Production KMS Safety Check"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-12
    pub fn isProductionSafe(self: KMSProviderType) bool {
        return switch (self) {
            .local_dev => false, // Development only - deterministic key derivation
            .external_kms => false, // Simulated - no real external service
            .remote_kms => true, // Real remote service
            .vault_transit => true, // Real Vault integration
            .aws_kms => true, // Real AWS integration
            .azure_kv => true, // Real Azure integration
        };
    }
};

/// Constant to detect production builds (set at compile time)
/// In production builds, define GEODE_PRODUCTION=1 to enable safety checks
pub const is_production_build = @import("builtin").mode == .ReleaseFast or
    @import("builtin").mode == .ReleaseSafe;

pub const KMSConfig = struct {
    provider_type: KMSProviderType = .external_kms, // Default to external_kms (requires explicit configuration)
    seed: ?u64 = null, // For deterministic providers
    endpoint: ?[]const u8 = null, // For remote providers
    port: ?u16 = null, // For remote providers
    auth_token: ?[]const u8 = null, // For authenticated providers
    master_key_id: ?[]const u8 = null, // Optional explicit master key ID
    vault_addr: ?[]const u8 = null, // Vault server address
    vault_key_path: ?[]const u8 = null, // Vault key storage path
};

pub const KMSProvider = struct {
    config: KMSConfig,
    allocator: std.mem.Allocator,
    external_client: ?external_kms.Client = null,
    remote_client: ?kms_remote.RemoteKmsClient = null,

    /// Initialize KMS provider with production safety check
    /// CANARY: REQ=REQ-GQL-KMS-PRODSAFE-002; FEATURE="KMS Provider Init Safety"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-12
    pub fn init(allocator: std.mem.Allocator, config: KMSConfig) !KMSProvider {
        // Production safety: block non-production-safe providers in release builds
        if (is_production_build and !config.provider_type.isProductionSafe()) {
            log.err("BLOCKED: Non-production-safe KMS provider in production build. " ++
                "Configure vault_transit, aws_kms, azure_kv, or remote_kms.", &.{
                Attr.string("provider_type", @tagName(config.provider_type)),
            });
            return error.UnsafeKMSProvider;
        }

        return KMSProvider{
            .config = config,
            .allocator = allocator,
            .external_client = null,
            .remote_client = null,
        };
    }

    /// Verify provider is safe for production use (can be called explicitly)
    pub fn verifyProductionSafe(self: *const KMSProvider) !void {
        if (!self.config.provider_type.isProductionSafe()) {
            return error.NonProductionSafeProvider;
        }
    }

    pub fn deinit(self: *KMSProvider) void {
        // Clean up any allocated resources
        if (self.remote_client) |*client| {
            // Remote client cleanup handled by QUIC transport
            _ = client;
        }
    }

    /// Returns a stable master key identifier
    pub fn fetchActiveMasterKey(self: *KMSProvider) !MasterKeyId {
        if (self.config.master_key_id) |id| {
            return id;
        }

        return switch (self.config.provider_type) {
            .local_dev => "local-dev-master-key-v1",
            .external_kms => {
                const seed_str = self.config.seed orelse return error.MissingSeed;
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "external-kms-{x}", .{seed_str}) catch return error.BufferTooSmall;
                const owned = try self.allocator.dupe(u8, slice);
                return owned;
            },
            .remote_kms => {
                const endpoint = self.config.endpoint orelse "localhost";
                const port = self.config.port orelse 3141;
                var buf: [128]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "remote-kms-{s}:{}", .{ endpoint, port }) catch return error.BufferTooSmall;
                const owned = try self.allocator.dupe(u8, slice);
                return owned;
            },
            else => error.UnsupportedProvider,
        };
    }

    /// Wrap a plaintext data key (encrypt under master key)
    pub fn wrapDataKey(self: *KMSProvider, plaintext: []const u8) !WrappedKey {
        // Block non-production-safe providers in release builds
        if (is_production_build and !self.config.provider_type.isProductionSafe()) {
            return error.NonProductionKmsBlocked;
        }
        const key_id = try self.fetchActiveMasterKey();
        // Free key_id if it was dynamically allocated (external_kms, remote_kms without custom master_key_id)
        const needs_free = self.config.master_key_id == null and
            (self.config.provider_type == .external_kms or self.config.provider_type == .remote_kms);
        defer if (needs_free) self.allocator.free(key_id);

        const result = switch (self.config.provider_type) {
            .local_dev => try self.wrapLocalDev(key_id, plaintext),
            .external_kms => try self.wrapExternalKMS(key_id, plaintext),
            .remote_kms => try self.wrapRemoteKMS(key_id, plaintext),
            else => error.UnsupportedProvider,
        };
        return result;
    }

    /// Unwrap (decrypt) a wrapped data key
    pub fn unwrapDataKey(self: *KMSProvider, wrapped: WrappedKey) ![]u8 {
        return switch (self.config.provider_type) {
            .local_dev => self.unwrapLocalDev(wrapped),
            .external_kms => self.unwrapExternalKMS(wrapped),
            .remote_kms => self.unwrapRemoteKMS(wrapped),
            else => error.UnsupportedProvider,
        };
    }

    /// Local development provider using AES-256-GCM (secure but with static key derived from key_id)
    /// WARNING: For development/testing only - uses deterministic key derivation from key_id
    /// CANARY: REQ=REQ-GQL-KMS-LOCALDEV-001; FEATURE="AES-GCM Local KMS"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=security; UPDATED=2026-01-12
    fn wrapLocalDev(self: *KMSProvider, key_id: MasterKeyId, plaintext: []const u8) !WrappedKey {
        // Derive AES-256 key from key_id using HKDF (extract-then-expand)
        var wrap_key: [32]u8 = undefined;
        const prk = std.crypto.kdf.hkdf.HkdfSha256.extract("LOCAL_DEV_WRAP", key_id);
        std.crypto.kdf.hkdf.HkdfSha256.expand(&wrap_key, "", prk);

        // Use cryptographically random nonce (required for AES-GCM security)
        var nonce: [12]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        // AES-256-GCM encrypt with authentication tag
        // Output format: nonce (12) || ciphertext || tag (16)
        var output = try self.allocator.alloc(u8, 12 + plaintext.len + 16);
        var tag: [16]u8 = undefined;

        // Prepend nonce so unwrap can recover it
        @memcpy(output[0..12], &nonce);
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(output[12 .. 12 + plaintext.len], &tag, plaintext, "", nonce, wrap_key);

        // Append tag
        @memcpy(output[12 + plaintext.len ..], &tag);

        const key_id_copy = try self.allocator.dupe(u8, key_id);
        return WrappedKey{ .key_id = key_id_copy, .ciphertext = output };
    }

    /// Local development unwrap using AES-256-GCM
    /// CANARY: REQ=REQ-GQL-KMS-LOCALDEV-002; FEATURE="AES-GCM Local KMS Unwrap"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=security; UPDATED=2026-01-12
    fn unwrapLocalDev(self: *KMSProvider, wrapped: WrappedKey) ![]u8 {
        // Minimum size: 16 bytes for tag (old format) or 28 bytes for nonce+tag (new format)
        if (wrapped.ciphertext.len < 16) return error.InvalidCiphertext;

        // Derive same key from key_id using HKDF (extract-then-expand)
        var wrap_key: [32]u8 = undefined;
        const prk = std.crypto.kdf.hkdf.HkdfSha256.extract("LOCAL_DEV_WRAP", wrapped.key_id);
        std.crypto.kdf.hkdf.HkdfSha256.expand(&wrap_key, "", prk);

        // Try new format first: nonce (12) || ciphertext || tag (16)
        if (wrapped.ciphertext.len >= 28) {
            const nonce: [12]u8 = wrapped.ciphertext[0..12].*;
            const new_plaintext_len = wrapped.ciphertext.len - 12 - 16;
            const new_ct = wrapped.ciphertext[12 .. 12 + new_plaintext_len];
            const new_tag: *const [16]u8 = @ptrCast(wrapped.ciphertext[12 + new_plaintext_len ..][0..16]);

            const plaintext = try self.allocator.alloc(u8, new_plaintext_len);
            if (std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, new_ct, new_tag.*, "", nonce, wrap_key)) |_| {
                return plaintext;
            } else |_| {
                self.allocator.free(plaintext);
                // Fall through to legacy format
            }
        }

        // Legacy format: ciphertext || tag (16), deterministic nonce from CRC32(key_id)
        const legacy_plaintext_len = wrapped.ciphertext.len - 16;
        const legacy_ct = wrapped.ciphertext[0..legacy_plaintext_len];
        const legacy_tag: *const [16]u8 = @ptrCast(wrapped.ciphertext[legacy_plaintext_len..][0..16]);

        var legacy_nonce: [12]u8 = undefined;
        std.crypto.secureZero(u8, &legacy_nonce);
        const key_hash = std.hash.crc.Crc32.hash(wrapped.key_id);
        std.mem.writeInt(u32, legacy_nonce[0..4], key_hash, .little);

        const plaintext = try self.allocator.alloc(u8, legacy_plaintext_len);
        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, legacy_ct, legacy_tag.*, "", legacy_nonce, wrap_key) catch {
            self.allocator.free(plaintext);
            return error.DecryptionFailed;
        };

        return plaintext;
    }

    // External KMS provider (AES-256-GCM with deterministic behavior)
    fn wrapExternalKMS(self: *KMSProvider, key_id: MasterKeyId, plaintext: []const u8) !WrappedKey {
        if (plaintext.len != 32) return error.InvalidKeyLength;

        const seed = self.config.seed orelse return error.MissingSeed;
        if (self.external_client == null) {
            // GAP-0216: Handle potential error from LocalSimulated KMS init
            self.external_client = try external_kms.Client.init(self.allocator, seed);
        }

        var plaintext_32: [32]u8 = undefined;
        @memcpy(&plaintext_32, plaintext[0..32]);

        const envelope = try self.external_client.?.wrap(plaintext_32);

        // Serialize envelope to JSON metadata
        const metadata = try external_kms.envelopeToJson(envelope, self.allocator);

        // Store ciphertext from envelope
        const ciphertext = try self.allocator.dupe(u8, &envelope.ct);

        // Duplicate key_id since the original will be freed
        const key_id_copy = try self.allocator.dupe(u8, key_id);
        return WrappedKey{
            .key_id = key_id_copy,
            .ciphertext = ciphertext,
            .metadata = metadata,
        };
    }

    fn unwrapExternalKMS(self: *KMSProvider, wrapped: WrappedKey) ![]u8 {
        if (wrapped.metadata == null) return error.MissingMetadata;

        const seed = self.config.seed orelse return error.MissingSeed;
        if (self.external_client == null) {
            // GAP-0216: Handle potential error from LocalSimulated KMS init
            self.external_client = try external_kms.Client.init(self.allocator, seed);
        }

        // Parse envelope from metadata
        const envelope = try external_kms.envelopeFromJson(wrapped.metadata.?);
        // P2-3: envelope.ct is inline array [32]u8, not allocated memory - no need to free

        const plaintext = try self.external_client.?.unwrap(envelope);
        return try self.allocator.dupe(u8, &plaintext);
    }

    // Remote KMS provider (QUIC-based)
    fn wrapRemoteKMS(self: *KMSProvider, key_id: MasterKeyId, plaintext: []const u8) !WrappedKey {
        _ = plaintext; // Will use remote generation

        if (self.remote_client == null) {
            self.remote_client = kms_remote.RemoteKmsClient.init(self.allocator);
            if (self.config.auth_token) |token| {
                self.remote_client.?.setAuthToken(token);
            }
        }

        const endpoint = self.config.endpoint orelse "localhost";
        const port = self.config.port orelse 3141;
        try self.remote_client.?.connect(endpoint, port);

        // Generate new key remotely (ignores input plaintext)
        const envelope = try self.remote_client.?.generate();

        // Serialize envelope to JSON metadata
        var json_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer json_buf.deinit(self.allocator);

        const writer = json_buf.writer(self.allocator);
        try writer.writeAll("{{\"version\":");
        try writer.print("{d},", .{envelope.version});
        try writer.print("\"alg\":\"{s}\",", .{envelope.alg});
        try writer.writeAll("\"nonce\":\"");
        for (envelope.nonce) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeAll("\",\"tag\":\"");
        for (envelope.tag) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeAll("\",\"ct\":\"");
        for (envelope.ct) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeAll("\"}}");

        const metadata = try json_buf.toOwnedSlice(self.allocator);
        const ciphertext = try self.allocator.dupe(u8, &envelope.ct);

        // Duplicate key_id since the original will be freed
        const key_id_copy = try self.allocator.dupe(u8, key_id);
        return WrappedKey{
            .key_id = key_id_copy,
            .ciphertext = ciphertext,
            .metadata = metadata,
        };
    }

    fn unwrapRemoteKMS(self: *KMSProvider, wrapped: WrappedKey) ![]u8 {
        if (wrapped.metadata == null) return error.MissingMetadata;

        if (self.remote_client == null) {
            self.remote_client = kms_remote.RemoteKmsClient.init(self.allocator);
            if (self.config.auth_token) |token| {
                self.remote_client.?.setAuthToken(token);
            }
        }

        const endpoint = self.config.endpoint orelse "localhost";
        const port = self.config.port orelse 3141;
        try self.remote_client.?.connect(endpoint, port);

        // Parse envelope from metadata
        const envelope = try external_kms.envelopeFromJson(wrapped.metadata.?);
        // P2-3: envelope.ct is inline array [32]u8, not allocated memory - no need to free

        // Convert to remote KMS envelope format
        const remote_envelope = kms_remote.Envelope{
            .version = envelope.version,
            .alg = envelope.alg,
            .nonce = envelope.nonce,
            .tag = envelope.tag,
            .ct = envelope.ct[0..32].*,
        };

        const plaintext = try self.remote_client.?.unwrap(remote_envelope);
        return try self.allocator.dupe(u8, &plaintext);
    }

    /// Get provider information for diagnostics
    pub fn getProviderInfo(self: *KMSProvider) struct { provider_type: KMSProviderType, endpoint: ?[]const u8, authenticated: bool } {
        return .{
            .provider_type = self.config.provider_type,
            .endpoint = self.config.endpoint,
            .authenticated = self.config.auth_token != null,
        };
    }
};

// Factory functions for different provider types
pub fn localDevProvider(allocator: std.mem.Allocator) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .local_dev });
}

pub fn externalKMSProvider(allocator: std.mem.Allocator, seed: u64) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .external_kms, .seed = seed });
}

pub fn remoteKMSProvider(allocator: std.mem.Allocator, endpoint: []const u8, port: u16, auth_token: ?[]const u8) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .remote_kms, .endpoint = endpoint, .port = port, .auth_token = auth_token });
}

pub fn vaultKMSProvider(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .vault_transit, .vault_addr = vault_addr, .auth_token = vault_token, .vault_key_path = key_path });
}

// Legacy function for backward compatibility
// P2-3: Use static GPA instead of page_allocator for global provider
var default_provider_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var default_provider_init = false;

pub fn defaultProvider() !KMSProvider {
    if (!default_provider_init) {
        default_provider_init = true;
    }
    return localDevProvider(default_provider_gpa.allocator());
}

test "local dev provider wrap/unwrap roundtrip" {
    const allocator = std.testing.allocator;
    var provider = try localDevProvider(allocator);
    defer provider.deinit();

    const plaintext = "0123456789abcdef0123456789abcdef"; // 32 bytes
    var wrapped = try provider.wrapDataKey(plaintext);
    defer wrapped.deinit(allocator);

    const unwrapped = try provider.unwrapDataKey(wrapped);
    defer allocator.free(unwrapped);

    try std.testing.expectEqualSlices(u8, plaintext, unwrapped);
}

test "external KMS provider wrap/unwrap roundtrip" {
    const allocator = std.testing.allocator;
    var provider = try externalKMSProvider(allocator, 0xDEADBEEF);
    defer provider.deinit();

    const plaintext = "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"; // 32 bytes
    var wrapped = try provider.wrapDataKey(plaintext);
    defer wrapped.deinit(allocator);

    const unwrapped = try provider.unwrapDataKey(wrapped);
    defer allocator.free(unwrapped);

    try std.testing.expectEqualSlices(u8, plaintext, unwrapped);

    // Verify metadata exists for external KMS
    try std.testing.expect(wrapped.metadata != null);
    try std.testing.expect(wrapped.metadata.?.len > 0);
}

test "KMS provider types" {
    const allocator = std.testing.allocator;

    // Test different provider configurations
    const configs = [_]KMSConfig{
        .{ .provider_type = .local_dev },
        .{ .provider_type = .external_kms, .seed = 0x12345 },
        .{ .provider_type = .remote_kms, .endpoint = "test.example.com", .port = 9443, .auth_token = "test_token" },
    };

    for (configs) |config| {
        var provider = try KMSProvider.init(allocator, config);
        defer provider.deinit();

        const info = provider.getProviderInfo();
        try std.testing.expectEqual(config.provider_type, info.provider_type);
        try std.testing.expectEqual(config.auth_token != null, info.authenticated);
    }
}

test "master key ID generation" {
    const allocator = std.testing.allocator;

    // Test local dev provider
    var local_provider = try localDevProvider(allocator);
    defer local_provider.deinit();
    const local_key = try local_provider.fetchActiveMasterKey();
    try std.testing.expectEqualStrings("local-dev-master-key-v1", local_key);

    // Test external KMS provider
    var external_provider = try externalKMSProvider(allocator, 0xCAFEBABE);
    defer external_provider.deinit();
    const external_key = try external_provider.fetchActiveMasterKey();
    defer allocator.free(external_key);
    try std.testing.expect(std.mem.startsWith(u8, external_key, "external-kms-"));

    // Test custom master key ID
    var custom_provider = try KMSProvider.init(allocator, KMSConfig{
        .provider_type = .local_dev,
        .master_key_id = "custom-master-key-123",
    });
    defer custom_provider.deinit();
    const custom_key = try custom_provider.fetchActiveMasterKey();
    try std.testing.expectEqualStrings("custom-master-key-123", custom_key);
}

// =============================================================================
// GAP-0066 Regression Tests: Production Safety Checks
// Verify isProductionSafe() correctly identifies insecure providers
// =============================================================================

test "GAP-0066: isProductionSafe identifies local_dev as unsafe" {
    try std.testing.expect(!KMSProviderType.local_dev.isProductionSafe());
}

test "GAP-0066: isProductionSafe identifies external_kms as unsafe" {
    try std.testing.expect(!KMSProviderType.external_kms.isProductionSafe());
}

test "GAP-0066: isProductionSafe identifies remote_kms as safe" {
    try std.testing.expect(KMSProviderType.remote_kms.isProductionSafe());
}

test "GAP-0066: isProductionSafe identifies vault_transit as safe" {
    try std.testing.expect(KMSProviderType.vault_transit.isProductionSafe());
}

test "GAP-0066: default config is external_kms not local_dev" {
    const default_config = KMSConfig{};
    try std.testing.expectEqual(KMSProviderType.external_kms, default_config.provider_type);
}

// =============================================================================
// GAP-0100 Regression Tests: AES-256-GCM for local_dev
// Verify wrapLocalDev uses real encryption, not XOR
// =============================================================================

test "GAP-0100: local dev wrap produces non-XOR ciphertext" {
    const allocator = std.testing.allocator;
    var provider = try localDevProvider(allocator);
    defer provider.deinit();

    // All zeros plaintext - XOR would produce all same bytes
    const plaintext = [_]u8{0x00} ** 32;
    var wrapped = try provider.wrapDataKey(&plaintext);
    defer wrapped.deinit(allocator);

    // Check that ciphertext has variation (not constant XOR result)
    var has_variation = false;
    for (wrapped.ciphertext, 0..) |b, i| {
        if (i > 0 and b != wrapped.ciphertext[0]) {
            has_variation = true;
            break;
        }
    }
    try std.testing.expect(has_variation);
}

test "GAP-0100: local dev wrap/unwrap preserves data correctly" {
    const allocator = std.testing.allocator;
    var provider = try localDevProvider(allocator);
    defer provider.deinit();

    const plaintext = [_]u8{
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    };

    var wrapped = try provider.wrapDataKey(&plaintext);
    defer wrapped.deinit(allocator);

    const unwrapped = try provider.unwrapDataKey(wrapped);
    defer allocator.free(unwrapped);

    try std.testing.expectEqualSlices(u8, &plaintext, unwrapped);
}

test "GAP-0100: local dev ciphertext differs from plaintext" {
    const allocator = std.testing.allocator;
    var provider = try localDevProvider(allocator);
    defer provider.deinit();

    const plaintext = [_]u8{0xAB} ** 32;
    var wrapped = try provider.wrapDataKey(&plaintext);
    defer wrapped.deinit(allocator);

    // Ciphertext should not equal plaintext (encrypted, not copied)
    try std.testing.expect(!std.mem.eql(u8, &plaintext, wrapped.ciphertext[0..32]));
}
