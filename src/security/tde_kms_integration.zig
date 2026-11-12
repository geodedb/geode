const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const cb = @import("crypto_backend");
pub const kms = @import("kms.zig");
const tde_hierarchy = @import("tde_hierarchy.zig");
const flags_mod = @import("feature_flags");

// TDE-KMS Integration: Enhanced Transparent Data Encryption with KMS Provider support
// CANARY: REQ=REQ-GQL-TDE-KMS-001; FEATURE="TDEKMSIntegration"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2025-10-05

pub const TDEKeyManager = struct {
    allocator: std.mem.Allocator,
    kms_provider: ?*kms.KMSProvider = null,
    hierarchy: ?tde_hierarchy.KeyHierarchy = null,
    key_status: KeyStatus = .{ .loaded = false },

    pub const KeyStatus = struct {
        loaded: bool,
        key_id: ?[]const u8 = null,
        provider_type: ?kms.KMSProviderType = null,
        last_rotation: ?i64 = null,
    };

    pub fn init(allocator: std.mem.Allocator) TDEKeyManager {
        return TDEKeyManager{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TDEKeyManager) void {
        if (self.kms_provider) |provider| {
            provider.deinit();
            self.allocator.destroy(provider);
        }
        if (self.key_status.key_id) |key_id| {
            self.allocator.free(key_id);
        }
    }

    /// Initialize TDE with KMS provider
    pub fn initializeWithKMS(self: *TDEKeyManager, kms_config: kms.KMSConfig) !void {
        if (!self.isEnabled()) return error.TDENotEnabled;

        // Initialize KMS provider
        var provider = try kms.KMSProvider.init(self.allocator, kms_config);

        // Generate or fetch master key. external_kms allocates the id unless
        // the config names one (see KMSProvider.wrapDataKey).
        const master_key_id = try provider.fetchActiveMasterKey();
        defer if (kms_config.master_key_id == null and kms_config.provider_type == .external_kms) self.allocator.free(master_key_id);

        // Generate a new data encryption key (DEK)
        const dek_plaintext = try self.generateDataEncryptionKey();
        defer self.allocator.free(dek_plaintext);

        // Wrap the DEK with KMS
        var wrapped_key = try provider.wrapDataKey(dek_plaintext);
        defer wrapped_key.deinit(self.allocator);

        // Create key hierarchy from the DEK
        var master_key: [32]u8 = undefined;
        @memcpy(&master_key, dek_plaintext[0..32]);
        self.hierarchy = try tde_hierarchy.KeyHierarchy.init(master_key);

        // Store KMS provider and status
        self.kms_provider = try self.allocator.create(kms.KMSProvider);
        self.kms_provider.?.* = provider;

        self.key_status = KeyStatus{
            .loaded = true,
            .key_id = try self.allocator.dupe(u8, master_key_id),
            .provider_type = kms_config.provider_type,
            .last_rotation = compat_timestamp(),
        };
    }

    /// Initialize TDE with environment variable (legacy mode)
    pub fn initializeWithEnv(self: *TDEKeyManager) !void {
        if (!self.isEnabled()) return error.TDENotEnabled;

        const key_hex = getEnvVarOwned(self.allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => return error.TDEKeyNotFound,
            else => return e,
        };
        defer self.allocator.free(key_hex);

        if (key_hex.len != 64) return error.InvalidTDEKey;

        // Parse hex key
        var master_key: [32]u8 = undefined;
        try self.parseHexKey(key_hex, &master_key);

        // Create key hierarchy
        self.hierarchy = try tde_hierarchy.KeyHierarchy.init(master_key);

        self.key_status = KeyStatus{
            .loaded = true,
            .key_id = try self.allocator.dupe(u8, "env-tde-key"),
            .provider_type = null, // Environment mode
            .last_rotation = null,
        };
    }

    /// Get data encryption key for page encryption
    pub fn getDataKey(self: *TDEKeyManager) ![32]u8 {
        if (!self.key_status.loaded) return error.TDENotInitialized;
        return self.hierarchy.?.data_key;
    }

    /// Get backup encryption key
    pub fn getBackupKey(self: *TDEKeyManager) ![32]u8 {
        if (!self.key_status.loaded) return error.TDENotInitialized;
        return self.hierarchy.?.backup_key;
    }

    /// Rotate keys using KMS provider
    pub fn rotateKeys(self: *TDEKeyManager) !void {
        if (self.kms_provider == null) return error.KMSNotAvailable;

        // Generate new DEK
        const new_dek = try self.generateDataEncryptionKey();
        defer self.allocator.free(new_dek);

        // Wrap with KMS
        var wrapped_key = try self.kms_provider.?.wrapDataKey(new_dek);
        defer wrapped_key.deinit(self.allocator);

        // Update hierarchy
        var new_master: [32]u8 = undefined;
        @memcpy(&new_master, new_dek[0..32]);
        self.hierarchy = try tde_hierarchy.KeyHierarchy.init(new_master);

        // Update status
        self.key_status.last_rotation = compat_timestamp();
    }

    /// Get current key status
    pub fn getStatus(self: *TDEKeyManager) KeyStatus {
        return self.key_status;
    }

    /// Check if TDE is enabled
    fn isEnabled(self: *TDEKeyManager) bool {
        _ = self;
        return flags_mod.global().tde.enabled();
    }

    /// Generate a cryptographically secure 32-byte data encryption key
    fn generateDataEncryptionKey(self: *TDEKeyManager) ![]u8 {
        const dek = try self.allocator.alloc(u8, 32);
        try cb.Csprng.bytes(dek);
        return dek;
    }

    /// Parse hex-encoded key string into bytes
    fn parseHexKey(self: *TDEKeyManager, hex_key: []const u8, out: *[32]u8) !void {
        _ = self;
        if (hex_key.len != 64) return error.InvalidKeyLength;

        for (0..32) |i| {
            const hi = std.fmt.charToDigit(hex_key[i * 2], 16) catch return error.InvalidHexChar;
            const lo = std.fmt.charToDigit(hex_key[i * 2 + 1], 16) catch return error.InvalidHexChar;
            out[i] = @as(u8, @intCast(hi * 16 + lo));
        }
    }
};

/// Enhanced TDE operations using KMS-backed key management
pub const TDEOperations = struct {
    key_manager: *TDEKeyManager,

    pub fn init(key_manager: *TDEKeyManager) TDEOperations {
        return TDEOperations{ .key_manager = key_manager };
    }

    /// Encrypt data using TDE data key
    pub fn encryptData(self: *TDEOperations, allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8) !EncryptedData {
        const data_key = try self.key_manager.getDataKey();
        return encryptWithKey(allocator, plaintext, aad, data_key);
    }

    /// Decrypt data using TDE data key
    pub fn decryptData(self: *TDEOperations, allocator: std.mem.Allocator, encrypted: EncryptedData, aad: []const u8) ![]u8 {
        const data_key = try self.key_manager.getDataKey();
        return decryptWithKey(allocator, encrypted, aad, data_key);
    }

    /// Encrypt backup payload using TDE backup key
    pub fn encryptBackup(self: *TDEOperations, allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8) !EncryptedData {
        const backup_key = try self.key_manager.getBackupKey();
        return encryptWithKey(allocator, plaintext, aad, backup_key);
    }

    /// Decrypt backup payload using TDE backup key
    pub fn decryptBackup(self: *TDEOperations, allocator: std.mem.Allocator, encrypted: EncryptedData, aad: []const u8) ![]u8 {
        const backup_key = try self.key_manager.getBackupKey();
        return decryptWithKey(allocator, encrypted, aad, backup_key);
    }
};

pub const EncryptedData = struct {
    nonce: [12]u8,
    tag: [16]u8,
    ciphertext: []u8,

    pub fn deinit(self: *EncryptedData, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
    }
};

/// Low-level encryption with specific key
fn encryptWithKey(allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8, key: [32]u8) !EncryptedData {
    // Generate secure random nonce via FIPS seam
    var nonce: [12]u8 = undefined;
    try cb.Csprng.bytes(&nonce);

    // Allocate ciphertext buffer
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    var tag: [16]u8 = undefined;

    // Perform AES-256-GCM encryption via FIPS seam
    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, aad, plaintext, ciphertext, &tag);

    return EncryptedData{
        .nonce = nonce,
        .tag = tag,
        .ciphertext = ciphertext,
    };
}

/// Low-level decryption with specific key
fn decryptWithKey(allocator: std.mem.Allocator, encrypted: EncryptedData, aad: []const u8, key: [32]u8) ![]u8 {
    const plaintext = try allocator.alloc(u8, encrypted.ciphertext.len);

    cb.Aead.open(.aes_256_gcm, &key, &encrypted.nonce, aad, encrypted.ciphertext, &encrypted.tag, plaintext) catch |e| {
        allocator.free(plaintext);
        return e;
    };

    return plaintext;
}

// Factory functions for different TDE configurations
pub fn createLocalDevTDE(allocator: std.mem.Allocator) !TDEKeyManager {
    var manager = TDEKeyManager.init(allocator);
    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .local_dev });
    return manager;
}

pub fn createExternalKMSTDE(allocator: std.mem.Allocator, seed: u64) !TDEKeyManager {
    var manager = TDEKeyManager.init(allocator);
    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .external_kms, .seed = seed });
    return manager;
}

pub fn createEnvTDE(allocator: std.mem.Allocator) !TDEKeyManager {
    var manager = TDEKeyManager.init(allocator);
    try manager.initializeWithEnv();
    return manager;
}

pub fn createVaultTDE(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) !TDEKeyManager {
    var manager = TDEKeyManager.init(allocator);
    try manager.initializeWithKMS(kms.KMSConfig{ .provider_type = .vault_transit, .vault_addr = vault_addr, .auth_token = vault_token, .vault_key_path = key_path });
    return manager;
}
