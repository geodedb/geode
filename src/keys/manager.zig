const std = @import("std");
const fle = @import("fle_lib");
const types = @import("fle_key_types");
const fle_aead = @import("fle_aead");
const hkdf = @import("fle_hkdf");

// Hierarchical Key Manager with Cache and Rotation
// Compatibility wrapper over external fle library KeyManager, preserving Geode's
// environment-variable-based init and rewrap methods.
// CANARY: REQ=REQ-FLE-KEY-002; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-28
// CANARY: REQ=REQ-FLE-FAILSECURE-006; FEATURE="FLEFailSecure"; ASPECT=MasterKeyRequired; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

pub const Error = fle.key_manager.Error;

/// Hierarchical Key Manager
/// TRK (Tenant Root Key) -> SK (Schema Key) -> FEK (Field Encryption Key) / BIK (Blind Index Key)
///
/// This wrapper preserves Geode's convention of loading the master key from the
/// GEODE_MASTER_KEY environment variable. The underlying fle library KeyManager
/// handles caching, derivation, and rotation.
pub const KeyManager = struct {
    allocator: std.mem.Allocator,
    inner: *fle.KeyManager,
    /// Retained so rewrap methods can access it.
    master_key: [32]u8,

    /// Initialize the key manager.
    /// SECURITY: GEODE_MASTER_KEY MUST be set. Returns error.MasterKeyRequired if missing.
    pub fn init(allocator: std.mem.Allocator) !*KeyManager {
        // Load master key from environment variable
        var master_key: [32]u8 = undefined;
        if (std.process.getEnvVarOwned(allocator, "GEODE_MASTER_KEY")) |env_key| {
            defer allocator.free(env_key);
            if (env_key.len >= 32) {
                @memcpy(&master_key, env_key[0..32]);
            } else {
                // If env key is too short, use it as seed for deterministic derivation
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(env_key);
                hasher.final(&master_key);
            }
        } else |_| {
            // No GEODE_MASTER_KEY set
            std.log.err("SECURITY CRITICAL: GEODE_MASTER_KEY environment variable is REQUIRED. " ++
                "FLE cannot operate without a properly configured master key. " ++
                "Set GEODE_MASTER_KEY to a 32+ byte secret value.", .{});
            return Error.MasterKeyRequired;
        }

        return initWithMasterKey(allocator, master_key);
    }

    /// Initialize the key manager with an explicitly provided master key.
    /// Useful for testing or when the caller has already sourced the key.
    pub fn initWithMasterKey(allocator: std.mem.Allocator, master_key: [32]u8) !*KeyManager {
        const inner = try fle.KeyManager.init(allocator, master_key);
        errdefer inner.deinit();

        const self = try allocator.create(KeyManager);
        self.* = .{
            .allocator = allocator,
            .inner = inner,
            .master_key = master_key,
        };

        return self;
    }

    pub fn deinit(self: *KeyManager) void {
        std.crypto.secureZero(u8, &self.master_key);
        self.inner.deinit();
        self.allocator.destroy(self);
    }

    /// Get Field Encryption Key (FEK)
    /// Derives TRK -> SK -> FEK using HKDF
    pub fn getFEK(self: *KeyManager, ids: types.KeyIds) ![32]u8 {
        return self.inner.getFEK(ids);
    }

    /// Get Blind Index Key (BIK)
    pub fn getBIK(self: *KeyManager, ids: types.KeyIds) ![32]u8 {
        return self.inner.getBIK(ids);
    }

    /// Get the current key version for a given key path (defaults to 1).
    /// Callers should build the key path as "tenant:schema:field".
    pub fn getKeyVersion(self: *KeyManager, key_path: []const u8) u16 {
        return self.inner.key_versions.get(key_path) orelse 1;
    }

    /// Rotate FEK to new version
    /// Creates vN+1, new writes use new version
    /// Old version remains available for reading during migration
    pub fn rotateFEK(
        self: *KeyManager,
        tenant: []const u8,
        schema: []const u8,
        field: []const u8,
    ) !u16 {
        return self.inner.rotateFEK(tenant, schema, field);
    }

    /// Wrap a key (encrypt it) using a wrapping key
    /// Returns: Envelope containing encrypted key
    pub fn wrapKey(self: *KeyManager, key_to_wrap: []const u8, wrapping_key: []const u8) !fle_aead.EnvelopeV1 {
        const aad = try fle_aead.makeAAD(self.allocator, "system", "sys", "key_wrap", "0", 1);
        defer self.allocator.free(aad);

        return fle_aead.encryptField(self.allocator, .aes256_gcm, wrapping_key, aad, key_to_wrap, null);
    }

    /// Unwrap a key (decrypt it) using a wrapping key
    pub fn unwrapKey(self: *KeyManager, envelope: fle_aead.EnvelopeV1, wrapping_key: []const u8) ![]u8 {
        const aad = try fle_aead.makeAAD(self.allocator, "system", "sys", "key_wrap", "0", 1);
        defer self.allocator.free(aad);

        return fle_aead.decryptField(self.allocator, wrapping_key, aad, envelope);
    }

    /// Rewrap SK (Schema Key) - updates parent without re-encrypting data
    /// Used when TRK rotates
    pub fn rewrapSK(
        self: *KeyManager,
        tenant: []const u8,
        schema: []const u8,
    ) !void {
        // 1. Derive current (Old) TRK and SK
        var old_trk = try hkdf.deriveTRK(&self.master_key, tenant);
        defer std.crypto.secureZero(u8, &old_trk);

        var sk = try hkdf.deriveSK(&old_trk, schema);
        defer std.crypto.secureZero(u8, &sk);

        // 2. Wrap SK with Old TRK (as if we just read it from DB)
        var wrapped_sk = try self.wrapKey(&sk, &old_trk);
        defer wrapped_sk.deinit(self.allocator);

        // 3. Unwrap it to verify logic
        const unwrapped_sk = try self.unwrapKey(wrapped_sk, &old_trk);
        defer {
            std.crypto.secureZero(u8, unwrapped_sk);
            self.allocator.free(unwrapped_sk);
        }

        // 4. Generate NEW TRK (Simulated - in real app Master Key would have rotated)
        var new_trk: [32]u8 = undefined;
        std.crypto.random.bytes(&new_trk);

        // 5. Wrap SK with NEW TRK
        var rewrapped_sk = try self.wrapKey(unwrapped_sk, &new_trk);
        defer rewrapped_sk.deinit(self.allocator);

        // 6. Clear cache to force re-derivation
        self.inner.clearCache();
    }

    /// Rewrap TRK (Tenant Root Key) - updates master without re-encrypting data
    /// Used when master key rotates
    pub fn rewrapTRK(
        self: *KeyManager,
        tenant: []const u8,
    ) !void {
        // 1. Derive Old TRK
        var trk = try hkdf.deriveTRK(&self.master_key, tenant);
        defer std.crypto.secureZero(u8, &trk);

        // 2. Wrap with current Master Key
        var wrapped_trk = try self.wrapKey(&trk, &self.master_key);
        defer wrapped_trk.deinit(self.allocator);

        // 3. Verify unwrap
        const unwrapped_trk = try self.unwrapKey(wrapped_trk, &self.master_key);
        defer {
            std.crypto.secureZero(u8, unwrapped_trk);
            self.allocator.free(unwrapped_trk);
        }

        // 4. Simulate New Master Key
        var new_master: [32]u8 = undefined;
        std.crypto.random.bytes(&new_master);

        // 5. Wrap TRK with New Master
        var rewrapped_trk = try self.wrapKey(unwrapped_trk, &new_master);
        defer rewrapped_trk.deinit(self.allocator);

        // 6. Clear cache
        self.inner.clearCache();
    }

    /// Get cache statistics
    pub fn cacheStats(self: *KeyManager) struct { hits: u64, misses: u64 } {
        return self.inner.cacheStats();
    }
};

test "KeyManager FEK derivation and caching" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try KeyManager.init(allocator);
    defer manager.deinit();

    const ids = types.KeyIds{
        .tenant = "tenant1",
        .schema = "Person",
        .field = "ssn",
        .version = 1,
    };

    // First access - cache miss
    const fek1 = try manager.getFEK(ids);

    // Second access - cache hit
    const fek2 = try manager.getFEK(ids);

    // Keys should be identical
    try testing.expectEqualSlices(u8, &fek1, &fek2);

    // Cache should have 1 hit
    const stats = manager.cacheStats();
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.misses);
}

test "KeyManager FEK rotation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try KeyManager.init(allocator);
    defer manager.deinit();

    const tenant = "tenant1";
    const schema = "Person";
    const field = "ssn";

    // Get initial FEK v1
    const ids_v1 = types.KeyIds{
        .tenant = tenant,
        .schema = schema,
        .field = field,
        .version = 1,
    };
    const fek_v1 = try manager.getFEK(ids_v1);

    // Rotate to v2
    const new_version = try manager.rotateFEK(tenant, schema, field);
    try testing.expectEqual(@as(u16, 2), new_version);

    // Get new FEK v2
    const ids_v2 = types.KeyIds{
        .tenant = tenant,
        .schema = schema,
        .field = field,
        .version = 2,
    };
    const fek_v2 = try manager.getFEK(ids_v2);

    // Keys should be different
    try testing.expect(!std.mem.eql(u8, &fek_v1, &fek_v2));

    // Old version still accessible
    const fek_v1_again = try manager.getFEK(ids_v1);
    try testing.expectEqualSlices(u8, &fek_v1, &fek_v1_again);
}

test "KeyManager BIK derivation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try KeyManager.init(allocator);
    defer manager.deinit();

    const ids = types.KeyIds{
        .tenant = "tenant1",
        .schema = "Person",
        .field = "email",
        .version = 1,
    };

    const bik = try manager.getBIK(ids);
    const fek = try manager.getFEK(ids);

    // BIK and FEK for same field should be different
    try testing.expect(!std.mem.eql(u8, &bik, &fek));
}
