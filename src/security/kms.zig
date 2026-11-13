const std = @import("std");

const external_kms = @import("external_kms_client.zig");
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

// SONNY-6448: there is no `local_dev` provider. Its wrapping key was
// HKDF(key id), and a wrapped key carries its key id, so anyone holding one
// could unwrap it; nothing in the product used it (KMS wiring is SONNY-6380).
pub const KMSProviderType = enum {
    external_kms, // External deterministic KMS client
    vault_transit, // HashiCorp Vault Transit (implemented)
    aws_kms, // AWS KMS (future)
    azure_kv, // Azure Key Vault (future)

    /// Check if this provider type is safe for production use
    /// CANARY: REQ=REQ-GQL-KMS-PRODSAFE-001; FEATURE="Production KMS Safety Check"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-12
    pub fn isProductionSafe(self: KMSProviderType) bool {
        return switch (self) {
            .external_kms => false, // Simulated - no real external service
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
    endpoint: ?[]const u8 = null, // Reported by getProviderInfo
    auth_token: ?[]const u8 = null, // For authenticated providers
    master_key_id: ?[]const u8 = null, // Optional explicit master key ID
    vault_addr: ?[]const u8 = null, // Vault server address
    vault_key_path: ?[]const u8 = null, // Vault key storage path
};

pub const KMSProvider = struct {
    config: KMSConfig,
    allocator: std.mem.Allocator,
    external_client: ?external_kms.Client = null,

    /// Initialize KMS provider with production safety check
    /// CANARY: REQ=REQ-GQL-KMS-PRODSAFE-002; FEATURE="KMS Provider Init Safety"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-12
    pub fn init(allocator: std.mem.Allocator, config: KMSConfig) !KMSProvider {
        // Production safety: block non-production-safe providers in release builds
        if (is_production_build and !config.provider_type.isProductionSafe()) {
            log.err("BLOCKED: Non-production-safe KMS provider in production build. " ++
                "Configure vault_transit, aws_kms or azure_kv.", &.{
                Attr.string("provider_type", @tagName(config.provider_type)),
            });
            return error.UnsafeKMSProvider;
        }

        return KMSProvider{
            .config = config,
            .allocator = allocator,
            .external_client = null,
        };
    }

    /// Verify provider is safe for production use (can be called explicitly)
    pub fn verifyProductionSafe(self: *const KMSProvider) !void {
        if (!self.config.provider_type.isProductionSafe()) {
            return error.NonProductionSafeProvider;
        }
    }

    pub fn deinit(self: *KMSProvider) void {
        _ = self;
    }

    /// Returns a stable master key identifier
    pub fn fetchActiveMasterKey(self: *KMSProvider) !MasterKeyId {
        if (self.config.master_key_id) |id| {
            return id;
        }

        return switch (self.config.provider_type) {
            .external_kms => {
                const seed_str = self.config.seed orelse return error.MissingSeed;
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "external-kms-{x}", .{seed_str}) catch return error.BufferTooSmall;
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
        // Free key_id if it was dynamically allocated (external_kms without custom master_key_id)
        const needs_free = self.config.master_key_id == null and
            self.config.provider_type == .external_kms;
        defer if (needs_free) self.allocator.free(key_id);

        const result = switch (self.config.provider_type) {
            .external_kms => try self.wrapExternalKMS(key_id, plaintext),
            else => error.UnsupportedProvider,
        };
        return result;
    }

    /// Unwrap (decrypt) a wrapped data key
    pub fn unwrapDataKey(self: *KMSProvider, wrapped: WrappedKey) ![]u8 {
        return switch (self.config.provider_type) {
            .external_kms => self.unwrapExternalKMS(wrapped),
            else => error.UnsupportedProvider,
        };
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

    // SONNY-2441: the remote_kms provider is gone. Its wrap ignored the key
    // it was given and returned one the remote KMS generated (the remote
    // protocol has GENERATE and UNWRAP, no WRAP), so unwrap(wrap(k)) was not
    // k, and nothing called it. The remote KMS client (kms_remote.zig) is
    // driven directly by test-remote-kms.

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
pub fn externalKMSProvider(allocator: std.mem.Allocator, seed: u64) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .external_kms, .seed = seed });
}

pub fn vaultKMSProvider(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) !KMSProvider {
    return KMSProvider.init(allocator, KMSConfig{ .provider_type = .vault_transit, .vault_addr = vault_addr, .auth_token = vault_token, .vault_key_path = key_path });
}

// SONNY-6453: the inline tests that lived here could run in no step (this
// file's import closure pulls in external_kms_client.zig's Vault tests, which
// do not compile under Zig 0.16); they are in tests/test_kms_provider.zig
// (`zig build test-kms-provider`).
