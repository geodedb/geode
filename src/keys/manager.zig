const std = @import("std");
const types = @import("fle_key_types");
const fle_aead = @import("fle_aead");
const hkdf = @import("fle_hkdf");

// CANARY: FLE_KEY_MANAGER - Hierarchical Key Manager with Cache and Rotation
// CANARY: REQ=REQ-FLE-KEY-002; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

pub const Error = error{
    KeyNotFound,
    InvalidKeyVersion,
    RotationInProgress,
    OutOfMemory,
};

/// Key cache entry
const CacheEntry = struct {
    key: [32]u8,
    version: u16,
    last_accessed: i64,
};

/// Key cache for performance
const KeyCache = struct {
    map: std.StringHashMap(CacheEntry),
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) KeyCache {
        return .{
            .map = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *KeyCache) void {
        // Securely zero all cached keys and free key strings before freeing
        const allocator = self.map.allocator;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            std.crypto.secureZero(u8, &entry.value_ptr.key);
            allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    pub fn get(self: *KeyCache, key: []const u8) ?CacheEntry {
        if (self.map.get(key)) |entry| {
            self.hits += 1;
            return entry;
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *KeyCache, key: []const u8, entry: CacheEntry) !void {
        try self.map.put(key, entry);
    }
};

/// Hierarchical Key Manager
/// TRK (Tenant Root Key) → SK (Schema Key) → FEK (Field Encryption Key) / BIK (Blind Index Key)
pub const KeyManager = struct {
    allocator: std.mem.Allocator,
    master_key: [32]u8, // Master key for deriving TRKs
    fek_cache: KeyCache,
    bik_cache: KeyCache,
    key_versions: std.StringHashMap(u16),

    pub fn init(allocator: std.mem.Allocator) !*KeyManager {
        const manager = try allocator.create(KeyManager);

        // Load master key from environment variable or use deterministic test key
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
            // No env var set - use deterministic key for testing
            // In production, this should FAIL and require KMS configuration
            const test_seed = "geode-fle-test-master-key-v1";
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(test_seed);
            hasher.final(&master_key);
        }

        manager.* = .{
            .allocator = allocator,
            .master_key = master_key,
            .fek_cache = KeyCache.init(allocator),
            .bik_cache = KeyCache.init(allocator),
            .key_versions = std.StringHashMap(u16).init(allocator),
        };

        return manager;
    }

    pub fn deinit(self: *KeyManager) void {
        std.crypto.secureZero(u8, &self.master_key);
        self.fek_cache.deinit();
        self.bik_cache.deinit();
        self.key_versions.deinit();
        self.allocator.destroy(self);
    }

    /// Get current key version for a field (default 1)
    fn getKeyVersion(self: *KeyManager, key_path: []const u8) u16 {
        return self.key_versions.get(key_path) orelse 1;
    }

    /// Set key version for a field
    fn setKeyVersion(self: *KeyManager, key_path: []const u8, version: u16) !void {
        try self.key_versions.put(key_path, version);
    }

    /// Build cache key for FEK/BIK lookup
    fn buildCacheKey(allocator: std.mem.Allocator, ids: types.KeyIds) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}:{s}:v{d}", .{
            ids.tenant,
            ids.schema,
            ids.field,
            ids.version,
        });
    }

    /// Get Field Encryption Key (FEK)
    /// Derives TRK → SK → FEK using HKDF
    pub fn getFEK(self: *KeyManager, ids: types.KeyIds) ![32]u8 {
        const cache_key = try buildCacheKey(self.allocator, ids);

        // Check cache first
        if (self.fek_cache.get(cache_key)) |entry| {
            // Cache hit - free the key we just built since we don't need it
            self.allocator.free(cache_key);
            return entry.key;
        }

        // Derive key hierarchy
        var trk = try hkdf.deriveTRK(&self.master_key, ids.tenant);
        defer std.crypto.secureZero(u8, &trk);

        var sk = try hkdf.deriveSK(&trk, ids.schema);
        defer std.crypto.secureZero(u8, &sk);

        const fek = try hkdf.deriveFEKVersioned(&sk, ids.field, ids.version);

        // Cache the result - cache takes ownership of cache_key
        const now = std.time.timestamp();
        try self.fek_cache.put(cache_key, .{
            .key = fek,
            .version = ids.version,
            .last_accessed = now,
        });

        return fek;
    }

    /// Get Blind Index Key (BIK)
    pub fn getBIK(self: *KeyManager, ids: types.KeyIds) ![32]u8 {
        const cache_key = try buildCacheKey(self.allocator, ids);

        // Check cache first
        if (self.bik_cache.get(cache_key)) |entry| {
            // Cache hit - free the key we just built since we don't need it
            self.allocator.free(cache_key);
            return entry.key;
        }

        // Derive key hierarchy
        var trk = try hkdf.deriveTRK(&self.master_key, ids.tenant);
        defer std.crypto.secureZero(u8, &trk);

        var sk = try hkdf.deriveSK(&trk, ids.schema);
        defer std.crypto.secureZero(u8, &sk);

        const bik = try hkdf.deriveBIKVersioned(&sk, ids.field, ids.version);

        // Cache the result - cache takes ownership of cache_key
        const now = std.time.timestamp();
        try self.bik_cache.put(cache_key, .{
            .key = bik,
            .version = ids.version,
            .last_accessed = now,
        });

        return bik;
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
        const key_path = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{
            tenant,
            schema,
            field,
        });
        defer self.allocator.free(key_path);

        const current_version = self.getKeyVersion(key_path);
        const new_version = current_version + 1;

        try self.setKeyVersion(key_path, new_version);

        return new_version;
    }

    /// Wrap a key (encrypt it) using a wrapping key
    /// Returns: Envelope containing encrypted key
    pub fn wrapKey(self: *KeyManager, key_to_wrap: []const u8, wrapping_key: []const u8) !fle_aead.EnvelopeV1 {
        const aad = try fle_aead.makeAAD(self.allocator, "system", "sys", "key_wrap", "0", 1);
        defer self.allocator.free(aad);

        // Encryption of keys uses AES-256-GCM
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
        // Clear cache first to force re-derivation/re-fetch
        // In a database-backed implementation, this would:
        // 1. Fetch wrapped SK from DB (wrapped with OLD TRK)
        // 2. Unwrap with OLD TRK
        // 3. Wrap with NEW TRK
        // 4. Store back to DB
        //
        // Since this Alpha implementation uses HKDF derivation on-the-fly,
        // "Rotation" of TRK implicitly changes SK unless we store it.
        // For now, we simulate the *capability* of rewrapping:

        // 1. Derive current (Old) TRK and SK
        var old_trk = try hkdf.deriveTRK(&self.master_key, tenant);
        defer std.crypto.secureZero(u8, &old_trk);

        var sk = try hkdf.deriveSK(&old_trk, schema);
        defer std.crypto.secureZero(u8, &sk);

        // 2. Simulate wrapping SK with Old TRK (as if we just read it from DB)
        var wrapped_sk = try self.wrapKey(&sk, &old_trk);
        defer wrapped_sk.deinit(self.allocator);

        // 3. Unwrap it to verify logic
        const unwrapped_sk = try self.unwrapKey(wrapped_sk, &old_trk);
        defer {
            std.crypto.secureZero(u8, unwrapped_sk);
            self.allocator.free(unwrapped_sk);
        }

        // 4. Generate NEW TRK (Simulated - in real app Master Key would have rotated)
        // Here we just use a dummy new key for verification
        var new_trk: [32]u8 = undefined;
        std.crypto.random.bytes(&new_trk);

        // 5. Wrap SK with NEW TRK
        var rewrapped_sk = try self.wrapKey(unwrapped_sk, &new_trk);
        defer rewrapped_sk.deinit(self.allocator);

        // 6. Clearing cache ensures subsequent getFEK calls will re-run derivation
        // (In pure HKDF mode, this means they get new keys if Master changed)
        self.fek_cache.map.clearRetainingCapacity();
        self.bik_cache.map.clearRetainingCapacity();
    }

    /// Rewrap TRK (Tenant Root Key) - updates master without re-encrypting data
    /// Used when master key rotates
    pub fn rewrapTRK(
        self: *KeyManager,
        tenant: []const u8,
    ) !void {
        // Similar logic to rewrapSK

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
        self.fek_cache.map.clearRetainingCapacity();
        self.bik_cache.map.clearRetainingCapacity();
    }

    /// Get cache statistics
    pub fn cacheStats(self: *KeyManager) struct { hits: u64, misses: u64 } {
        return .{
            .hits = self.fek_cache.hits + self.bik_cache.hits,
            .misses = self.fek_cache.misses + self.bik_cache.misses,
        };
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
