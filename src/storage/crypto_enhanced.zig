const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const audit = @import("../security/audit.zig");

pub const EncryptionAlgorithm = enum {
    none,
    aes_256_gcm,
    aes_256_cbc, // legacy, for migration
};

pub const KeyDerivationFunction = enum {
    pbkdf2,
    argon2id,
};

pub const KeyProvenance = struct {
    source: enum {
        local_file,
        kms,
        environment,
        hardware_module,
    },
    key_id: []const u8,
    created_at: i64,
    rotated_at: ?i64,
    version: u32,
    audit_log: []const u8,
};

pub const KMSProvider = enum {
    none,
    aws_kms,
    azure_key_vault,
    hashicorp_vault,
    google_cloud_kms,
};

pub const KMSConfig = struct {
    provider: KMSProvider,
    endpoint: []const u8,
    key_id: []const u8,
    region: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    auto_rotate: bool = true,
    rotation_period_days: u32 = 90,
};

pub const EncryptionKey = struct {
    master_key: [32]u8, // Master key (from KMS or local)
    data_key: [32]u8, // Data encryption key (DEK)
    key_encryption_key: [32]u8, // KEK for wrapping DEK
    provenance: KeyProvenance,
    algorithm: EncryptionAlgorithm,
    wrapped_dek: ?[48]u8 = null, // Encrypted DEK for storage
};

pub const GCMContext = struct {
    key: [32]u8,
    nonce: [12]u8,
    tag: [16]u8,
    additional_data: []const u8,
};

pub const CryptoManager = struct {
    allocator: Allocator,
    algorithm: EncryptionAlgorithm,
    kms_config: ?KMSConfig,
    current_key: EncryptionKey,
    key_cache: std.StringHashMap(EncryptionKey),
    rotation_in_progress: bool,
    audit_logger: ?*audit.AuditLogger,

    const Self = @This();

    pub fn init(allocator: Allocator, algorithm: EncryptionAlgorithm, kms_config: ?KMSConfig) !Self {
        var manager = Self{
            .allocator = allocator,
            .algorithm = algorithm,
            .kms_config = kms_config,
            .current_key = undefined,
            .key_cache = std.StringHashMap(EncryptionKey).init(allocator),
            .rotation_in_progress = false,
            .audit_logger = null,
        };

        try manager.initializeKeys();
        return manager;
    }

    pub fn deinit(self: *Self) void {
        // Securely wipe keys from memory
        crypto.utils.secureZero(u8, &self.current_key.master_key);
        crypto.utils.secureZero(u8, &self.current_key.data_key);
        crypto.utils.secureZero(u8, &self.current_key.key_encryption_key);

        var it = self.key_cache.iterator();
        while (it.next()) |entry| {
            crypto.utils.secureZero(u8, &entry.value_ptr.master_key);
            crypto.utils.secureZero(u8, &entry.value_ptr.data_key);
        }
        self.key_cache.deinit();
    }

    fn initializeKeys(self: *Self) !void {
        if (self.kms_config) |kms| {
            try self.fetchFromKMS(kms);
        } else {
            try self.generateLocalKeys();
        }
    }

    fn fetchFromKMS(self: *Self, config: KMSConfig) !void {
        switch (config.provider) {
            .aws_kms => try self.fetchFromAWSKMS(config),
            .azure_key_vault => try self.fetchFromAzureKeyVault(config),
            .hashicorp_vault => try self.fetchFromHashicorpVault(config),
            .google_cloud_kms => try self.fetchFromGoogleCloudKMS(config),
            .none => return error.InvalidKMSProvider,
        }
    }

    fn fetchFromAWSKMS(self: *Self, config: KMSConfig) !void {
        // Simulate AWS KMS integration
        // In production, this would use AWS SDK
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();

        // Generate master key (in reality, fetched from KMS)
        random.bytes(&self.current_key.master_key);

        // Derive DEK from master key
        try self.deriveDataKey();

        self.current_key.provenance = .{
            .source = .kms,
            .key_id = try self.allocator.dupe(u8, config.key_id),
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
            .audit_log = try self.allocator.dupe(u8, "Key fetched from AWS KMS"),
        };
    }

    fn fetchFromAzureKeyVault(self: *Self, config: KMSConfig) !void {
        _ = config;
        // Similar to AWS KMS
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();
        random.bytes(&self.current_key.master_key);
        try self.deriveDataKey();

        self.current_key.provenance = .{
            .source = .kms,
            .key_id = try self.allocator.dupe(u8, "azure-key-vault"),
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
            .audit_log = try self.allocator.dupe(u8, "Key fetched from Azure Key Vault"),
        };
    }

    fn fetchFromHashicorpVault(self: *Self, config: KMSConfig) !void {
        _ = config;
        // Similar implementation
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();
        random.bytes(&self.current_key.master_key);
        try self.deriveDataKey();

        self.current_key.provenance = .{
            .source = .kms,
            .key_id = try self.allocator.dupe(u8, "hashicorp-vault"),
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
            .audit_log = try self.allocator.dupe(u8, "Key fetched from HashiCorp Vault"),
        };
    }

    fn fetchFromGoogleCloudKMS(self: *Self, config: KMSConfig) !void {
        _ = config;
        // Similar implementation
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();
        random.bytes(&self.current_key.master_key);
        try self.deriveDataKey();

        self.current_key.provenance = .{
            .source = .kms,
            .key_id = try self.allocator.dupe(u8, "google-cloud-kms"),
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
            .audit_log = try self.allocator.dupe(u8, "Key fetched from Google Cloud KMS"),
        };
    }

    fn generateLocalKeys(self: *Self) !void {
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();

        random.bytes(&self.current_key.master_key);
        try self.deriveDataKey();

        self.current_key.provenance = .{
            .source = .local_file,
            .key_id = try self.allocator.dupe(u8, "local-generated"),
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
            .audit_log = try self.allocator.dupe(u8, "Key generated locally"),
        };
    }

    fn deriveDataKey(self: *Self) !void {
        // Derive DEK and KEK from master key using HKDF
        var hkdf = crypto.kdf.hkdf.HkdfSha256;

        const dek_info = "geode-data-encryption-key";
        const kek_info = "geode-key-encryption-key";

        hkdf.expand(&self.current_key.data_key, &self.current_key.master_key, dek_info);
        hkdf.expand(&self.current_key.key_encryption_key, &self.current_key.master_key, kek_info);

        // Wrap DEK with KEK for storage
        try self.wrapDataKey();
    }

    fn wrapDataKey(self: *Self) !void {
        // Use AES-GCM to wrap the DEK with KEK
        var wrapped: [48]u8 = undefined; // 32 bytes key + 16 bytes tag

        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // In production, use proper AES-GCM wrapping
        // For now, XOR as placeholder
        for (self.current_key.data_key, 0..) |byte, i| {
            wrapped[i] = byte ^ self.current_key.key_encryption_key[i % 32];
        }

        self.current_key.wrapped_dek = wrapped;
    }

    pub fn encryptPage(self: *Self, page_data: []const u8, page_id: u64) ![]u8 {
        if (self.algorithm == .none) {
            return try self.allocator.dupe(u8, page_data);
        }

        const encrypted = try self.allocator.alloc(u8, page_data.len + 28); // +12 nonce +16 tag

        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // Add page_id to nonce for uniqueness
        std.mem.writeInt(u64, nonce[4..12], page_id, .little);

        if (self.algorithm == .aes_256_gcm) {
            try self.encryptAES256GCM(page_data, encrypted, nonce, page_id);
        } else {
            return error.UnsupportedAlgorithm;
        }

        return encrypted;
    }

    fn encryptAES256GCM(self: *Self, plaintext: []const u8, ciphertext: []u8, nonce: [12]u8, page_id: u64) !void {
        // Store nonce at beginning
        @memcpy(ciphertext[0..12], &nonce);

        // Create additional authenticated data
        var aad: [8]u8 = undefined;
        std.mem.writeInt(u64, &aad, page_id, .little);

        // Perform AES-GCM encryption
        const gcm = crypto.aead.aes_gcm.Aes256Gcm;
        const tag_location = ciphertext.len - 16;

        gcm.encrypt(
            ciphertext[12..tag_location],
            ciphertext[tag_location..],
            plaintext,
            &aad,
            nonce,
            self.current_key.data_key,
        );
    }

    pub fn decryptPage(self: *Self, encrypted_data: []const u8, page_id: u64) ![]u8 {
        if (self.algorithm == .none) {
            return try self.allocator.dupe(u8, encrypted_data);
        }

        if (encrypted_data.len < 28) {
            return error.InvalidEncryptedData;
        }

        const plaintext = try self.allocator.alloc(u8, encrypted_data.len - 28);

        const nonce = encrypted_data[0..12];
        const ciphertext = encrypted_data[12 .. encrypted_data.len - 16];
        const tag = encrypted_data[encrypted_data.len - 16 ..];

        if (self.algorithm == .aes_256_gcm) {
            try self.decryptAES256GCM(ciphertext, tag, plaintext, nonce.*, page_id);
        } else {
            return error.UnsupportedAlgorithm;
        }

        return plaintext;
    }

    fn decryptAES256GCM(self: *Self, ciphertext: []const u8, tag: []const u8, plaintext: []u8, nonce: [12]u8, page_id: u64) !void {
        // Create additional authenticated data
        var aad: [8]u8 = undefined;
        std.mem.writeInt(u64, &aad, page_id, .little);

        // Perform AES-GCM decryption
        const gcm = crypto.aead.aes_gcm.Aes256Gcm;

        gcm.decrypt(
            plaintext,
            ciphertext,
            tag[0..16].*,
            &aad,
            nonce,
            self.current_key.data_key,
        ) catch return error.DecryptionFailed;
    }

    pub fn rotateKeys(self: *Self) !void {
        if (self.rotation_in_progress) {
            return error.RotationInProgress;
        }

        self.rotation_in_progress = true;
        defer self.rotation_in_progress = false;

        // Save old key for re-encryption
        const old_key = self.current_key;

        // Generate or fetch new key
        if (self.kms_config) |kms| {
            try self.fetchFromKMS(kms);
        } else {
            try self.generateLocalKeys();
        }

        // Update provenance
        self.current_key.provenance.rotated_at = std.time.milliTimestamp();
        self.current_key.provenance.version += 1;

        // Cache old key for gradual re-encryption
        const key_version = try std.fmt.allocPrint(self.allocator, "v{}", .{old_key.provenance.version});
        try self.key_cache.put(key_version, old_key);

        // Log rotation event
        if (self.audit_logger) |logger| {
            // Construct canonical AuditEvent for key rotation
            var details = std.StringHashMap([]const u8).init(self.allocator);
            // We leak details map for now or logger takes ownership?
            // My adapter implementation DOES NOT free keys in details map, but it frees the map.
            // So I should duplicate strings.
            try details.put("old_version", try std.fmt.allocPrint(self.allocator, "{}", .{old_key.provenance.version}));
            try details.put("new_version", try std.fmt.allocPrint(self.allocator, "{}", .{self.current_key.provenance.version}));

            var ev = audit.AuditEvent{
                .timestamp = std.time.milliTimestamp(),
                .event_type = .system_event,
                .severity = .info,
                .user_id = .system,
                .session_id = "",
                .resource = .{ .type = "security", .id = "encryption_keys", .name = "encryption_keys", .graph = null, .table = null },
                .action = "KEY_ROTATION",
                .result = .success,
                .details = details,
            };
            try logger.appendAuditEvent(&ev);

            var it = details.iterator();
            while (it.next()) |e| self.allocator.free(e.value_ptr.*);
            details.deinit();
        }
    }

    pub fn reencryptPage(self: *Self, encrypted_data: []const u8, page_id: u64, old_version: u32) ![]u8 {
        // Find old key
        const key_version = try std.fmt.allocPrint(self.allocator, "v{}", .{old_version});
        defer self.allocator.free(key_version);

        const old_key = self.key_cache.get(key_version) orelse return error.OldKeyNotFound;

        // Decrypt with old key
        const temp_manager = CryptoManager{
            .allocator = self.allocator,
            .algorithm = self.algorithm,
            .kms_config = self.kms_config,
            .current_key = old_key,
            .key_cache = undefined,
            .rotation_in_progress = false,
            .audit_logger = self.audit_logger,
        };

        const plaintext = try temp_manager.decryptPage(encrypted_data, page_id);
        defer self.allocator.free(plaintext);

        // Re-encrypt with current key
        return try self.encryptPage(plaintext, page_id);
    }
};

// Re-encryption tool for online/offline key rotation
pub const ReencryptionTool = struct {
    allocator: Allocator,
    crypto_manager: *CryptoManager,
    pages_to_reencrypt: std.ArrayList(u64),
    batch_size: usize,
    progress_callback: ?*const fn (u64, u64) void,

    const Self = @This();

    pub fn init(allocator: Allocator, crypto_manager: *CryptoManager) Self {
        return Self{
            .allocator = allocator,
            .crypto_manager = crypto_manager,
            .pages_to_reencrypt = std.ArrayList(u64).init(allocator),
            .batch_size = 1000,
            .progress_callback = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pages_to_reencrypt.deinit();
    }

    pub fn addPage(self: *Self, page_id: u64) !void {
        try self.pages_to_reencrypt.append(page_id);
    }

    pub fn reencryptAll(self: *Self, storage: *PageStorage) !void {
        const total = self.pages_to_reencrypt.items.len;
        var processed: u64 = 0;

        for (self.pages_to_reencrypt.items) |page_id| {
            const page = try storage.readPage(page_id);
            defer self.allocator.free(page);

            const reencrypted = try self.crypto_manager.reencryptPage(page, page_id, 1); // Assume old version 1
            defer self.allocator.free(reencrypted);

            try storage.writePage(page_id, reencrypted);

            processed += 1;
            if (self.progress_callback) |callback| {
                callback(processed, total);
            }
        }
    }

    pub fn reencryptOnline(self: *Self, storage: *PageStorage) !void {
        // Online re-encryption with minimal locking
        while (self.pages_to_reencrypt.items.len > 0) {
            const batch_end = @min(self.batch_size, self.pages_to_reencrypt.items.len);
            const batch = self.pages_to_reencrypt.items[0..batch_end];

            for (batch) |page_id| {
                // Acquire page lock
                try storage.lockPage(page_id);
                defer storage.unlockPage(page_id);

                const page = try storage.readPage(page_id);
                defer self.allocator.free(page);

                const reencrypted = try self.crypto_manager.reencryptPage(page, page_id, 1);
                defer self.allocator.free(reencrypted);

                try storage.writePage(page_id, reencrypted);
            }

            // Remove processed pages
            _ = self.pages_to_reencrypt.orderedRemove(0);
        }
    }
};

// Placeholder for PageStorage interface
const PageStorage = struct {
    pub fn readPage(self: *PageStorage, page_id: u64) ![]u8 {
        _ = self;
        _ = page_id;
        return error.NotImplemented;
    }

    pub fn writePage(self: *PageStorage, page_id: u64, data: []const u8) !void {
        _ = self;
        _ = page_id;
        _ = data;
    }

    pub fn lockPage(self: *PageStorage, page_id: u64) !void {
        _ = self;
        _ = page_id;
    }

    pub fn unlockPage(self: *PageStorage, page_id: u64) void {
        _ = self;
        _ = page_id;
    }
};

test "AES-256-GCM encryption and decryption" {
    const allocator = std.testing.allocator;

    var crypto_mgr = try CryptoManager.init(allocator, .aes_256_gcm, null);
    defer crypto_mgr.deinit();

    const plaintext = "Hello, World! This is a test page.";
    const page_id: u64 = 42;

    const encrypted = try crypto_mgr.encryptPage(plaintext, page_id);
    defer allocator.free(encrypted);

    const decrypted = try crypto_mgr.decryptPage(encrypted, page_id);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "Key rotation" {
    const allocator = std.testing.allocator;

    var crypto_mgr = try CryptoManager.init(allocator, .aes_256_gcm, null);
    defer crypto_mgr.deinit();

    const old_version = crypto_mgr.current_key.provenance.version;

    try crypto_mgr.rotateKeys();

    try std.testing.expect(crypto_mgr.current_key.provenance.version == old_version + 1);
    try std.testing.expect(crypto_mgr.current_key.provenance.rotated_at != null);
}

test "KMS integration simulation" {
    const allocator = std.testing.allocator;

    const kms_config = KMSConfig{
        .provider = .aws_kms,
        .endpoint = "https://kms.us-east-1.amazonaws.com",
        .key_id = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012",
        .region = "us-east-1",
        .auth_token = null,
    };

    var crypto_mgr = try CryptoManager.init(allocator, .aes_256_gcm, kms_config);
    defer crypto_mgr.deinit();

    try std.testing.expect(crypto_mgr.current_key.provenance.source == .kms);
}
