const std = @import("std");
const crypto = std.crypto;

// HashiCorp Vault KMS Provider for Geode TDE
// CANARY: REQ=REQ-GQL-VAULT-KMS-001; FEATURE="VaultKMSProvider"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_vault_kms_provider.zig; OWNER=security; UPDATED=2025-10-05

pub const VaultKMSProvider = struct {
    allocator: std.mem.Allocator,
    vault_addr: []const u8,
    vault_token: []const u8,
    key_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .vault_addr = vault_addr,
            .vault_token = vault_token,
            .key_path = key_path,
        };
    }

    /// Generate a new encryption key and store it in Vault
    pub fn generateAndStoreKey(self: *Self, key_name: []const u8) ![]u8 {
        // Generate a cryptographically secure 32-byte key
        var key_bytes: [32]u8 = undefined;
        crypto.random.bytes(&key_bytes);

        // Convert to hex for storage
        const hex_key = std.fmt.bytesToHex(key_bytes, .lower);

        // Store in Vault
        try self.storeKeyInVault(key_name, &hex_key);

        return try self.allocator.dupe(u8, &key_bytes);
    }

    /// Retrieve an encryption key from Vault
    pub fn retrieveKey(self: *Self, key_name: []const u8) ![]u8 {
        const hex_key = try self.getKeyFromVault(key_name);
        defer self.allocator.free(hex_key);

        if (hex_key.len != 64) return error.InvalidKeyFormat;

        // Convert hex to bytes
        var key_bytes: [32]u8 = undefined;
        for (0..32) |i| {
            const hi = std.fmt.charToDigit(hex_key[i * 2], 16) catch return error.InvalidHexChar;
            const lo = std.fmt.charToDigit(hex_key[i * 2 + 1], 16) catch return error.InvalidHexChar;
            key_bytes[i] = @as(u8, @intCast(hi * 16 + lo));
        }

        return try self.allocator.dupe(u8, &key_bytes);
    }

    /// Wrap (encrypt) a data key using Vault-stored master key
    pub fn wrapDataKey(self: *Self, master_key_name: []const u8, plaintext: []const u8) !WrappedKey {
        if (plaintext.len != 32) return error.InvalidKeyLength;

        // Retrieve master key from Vault
        const master_key = try self.retrieveKey(master_key_name);
        defer self.allocator.free(master_key);

        if (master_key.len != 32) return error.InvalidMasterKeyLength;

        // Perform AES-256-GCM encryption
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        const ciphertext = try self.allocator.alloc(u8, plaintext.len);
        var tag: [16]u8 = undefined;

        var master_key_array: [32]u8 = undefined;
        @memcpy(&master_key_array, master_key[0..32]);

        crypto.aead.aes_gcm.Aes256Gcm.encrypt(ciphertext, &tag, plaintext, &.{}, nonce, master_key_array);

        // Create envelope with metadata
        const envelope = VaultEnvelope{
            .version = 1,
            .algorithm = "AES-256-GCM",
            .master_key_name = master_key_name,
            .nonce = nonce,
            .tag = tag,
            .ciphertext = ciphertext,
        };

        const metadata = try self.serializeEnvelope(envelope);

        return WrappedKey{
            .key_id = try self.allocator.dupe(u8, master_key_name),
            .ciphertext = ciphertext,
            .metadata = metadata,
        };
    }

    /// Unwrap (decrypt) a data key using Vault-stored master key
    pub fn unwrapDataKey(self: *Self, wrapped: WrappedKey) ![]u8 {
        if (wrapped.metadata == null) return error.MissingMetadata;

        const envelope = try self.deserializeEnvelope(wrapped.metadata.?);
        defer self.allocator.free(envelope.ciphertext);

        // Retrieve master key from Vault
        const master_key = try self.retrieveKey(envelope.master_key_name);
        defer self.allocator.free(master_key);

        if (master_key.len != 32) return error.InvalidMasterKeyLength;

        // Decrypt
        const plaintext = try self.allocator.alloc(u8, envelope.ciphertext.len);

        var master_key_array: [32]u8 = undefined;
        @memcpy(&master_key_array, master_key[0..32]);

        crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, envelope.ciphertext, envelope.tag, &.{}, // No AAD
            envelope.nonce, master_key_array) catch |e| {
            self.allocator.free(plaintext);
            return e;
        };

        return plaintext;
    }

    /// Rotate a master key in Vault
    pub fn rotateKey(self: *Self, key_name: []const u8) !void {
        // Generate new key
        _ = try self.generateAndStoreKey(key_name);
    }

    /// List available keys in Vault
    // CANARY: REQ=REQ-VAULT-KMS-LIST-001; FEATURE="Vault Key Listing"; ASPECT=Core; STATUS=IMPL; OWNER=security; UPDATED=2026-01-10
    /// GAP-0052: Implements actual Vault key listing using `vault kv list` command
    pub fn listKeys(self: *Self) ![][]u8 {
        // Execute vault kv list command to get actual keys
        const result = std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "vault", "kv", "list", "-format=json", self.key_path },
            .env_map = &std.process.EnvMap.init(self.allocator),
        }) catch |err| {
            // If vault command fails (e.g., vault not available), return empty list
            std.log.warn("Vault list keys failed: {}, returning empty list", .{err});
            return try self.allocator.alloc([]u8, 0);
        };
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            // No keys found or path doesn't exist - return empty list
            return try self.allocator.alloc([]u8, 0);
        }

        // Parse JSON array output from vault kv list
        // Format: ["key1", "key2", ...]
        const json_output = std.mem.trim(u8, result.stdout, " \t\n\r");
        defer self.allocator.free(result.stdout);

        if (json_output.len == 0 or json_output[0] != '[') {
            // Not valid JSON array - return empty list
            return try self.allocator.alloc([]u8, 0);
        }

        // Count keys by counting quotes
        var key_count: usize = 0;
        var in_string = false;
        for (json_output) |c| {
            if (c == '"' and !in_string) {
                in_string = true;
            } else if (c == '"' and in_string) {
                in_string = false;
                key_count += 1;
            }
        }
        key_count = key_count / 2; // Each key has 2 quotes

        if (key_count == 0) {
            return try self.allocator.alloc([]u8, 0);
        }

        // Allocate result array
        const keys = try self.allocator.alloc([]u8, key_count);
        errdefer self.allocator.free(keys);

        // Parse keys from JSON
        var key_idx: usize = 0;
        var i: usize = 1; // Skip opening [
        while (i < json_output.len and key_idx < key_count) {
            // Find start of string
            while (i < json_output.len and json_output[i] != '"') {
                i += 1;
            }
            if (i >= json_output.len) break;
            i += 1; // Skip opening quote

            // Find end of string
            const key_start = i;
            while (i < json_output.len and json_output[i] != '"') {
                i += 1;
            }
            if (i >= json_output.len) break;

            // Copy key
            keys[key_idx] = try self.allocator.dupe(u8, json_output[key_start..i]);
            key_idx += 1;
            i += 1; // Skip closing quote
        }

        return keys;
    }

    // Private helper methods

    fn storeKeyInVault(self: *Self, key_name: []const u8, hex_key: []const u8) !void {
        // Build vault command: vault kv put {path}/{key_name} value={hex_key}
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.key_path, key_name });
        defer self.allocator.free(path);

        const value = try std.fmt.allocPrint(self.allocator, "value={s}", .{hex_key});
        defer self.allocator.free(value);

        const result = try std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "vault", "kv", "put", path, value },
            .env_map = &std.process.EnvMap.init(self.allocator),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.VaultOperationFailed;
        }
    }

    fn getKeyFromVault(self: *Self, key_name: []const u8) ![]u8 {
        // Build vault command: vault kv get -field=value {path}/{key_name}
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.key_path, key_name });
        defer self.allocator.free(path);

        const result = try std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "vault", "kv", "get", "-field=value", path },
            .env_map = &std.process.EnvMap.init(self.allocator),
        });
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            return error.VaultKeyNotFound;
        }

        // Trim whitespace from stdout
        const key = std.mem.trim(u8, result.stdout, " \t\n\r");
        return try self.allocator.dupe(u8, key);
    }

    fn serializeEnvelope(self: *Self, envelope: VaultEnvelope) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{");
        try writer.print("\"version\":{d},", .{envelope.version});
        try writer.print("\"algorithm\":\"{s}\",", .{envelope.algorithm});
        try writer.print("\"master_key_name\":\"{s}\",", .{envelope.master_key_name});
        try writer.writeAll("\"nonce\":\"");
        for (envelope.nonce) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeAll("\",\"tag\":\"");
        for (envelope.tag) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeAll("\"}");

        return buf.toOwnedSlice();
    }

    fn deserializeEnvelope(self: *Self, json: []const u8) !VaultEnvelope {
        // Simple JSON parser for envelope format
        var envelope: VaultEnvelope = undefined;

        // Extract master_key_name
        const key_name_start = std.mem.indexOf(u8, json, "\"master_key_name\":\"") orelse return error.InvalidEnvelope;
        const key_name_begin = key_name_start + 19;
        const key_name_end = std.mem.indexOfScalarPos(u8, json, key_name_begin, '"') orelse return error.InvalidEnvelope;
        envelope.master_key_name = json[key_name_begin..key_name_end];

        // GAP-0141: Safe hex parsing with proper error handling
        // CANARY: REQ=REQ-HEX-PARSE-VAULT-001; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-13
        // Extract nonce
        const nonce_start = std.mem.indexOf(u8, json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
        const nonce_begin = nonce_start + 9;
        // Bounds check for nonce
        if (nonce_begin + 24 > json.len) return error.InvalidEnvelope;
        for (0..12) |i| {
            const hex_start = nonce_begin + i * 2;
            envelope.nonce[i] = std.fmt.parseInt(u8, json[hex_start .. hex_start + 2], 16) catch return error.InvalidHexInNonce;
        }

        // Extract tag
        const tag_start = std.mem.indexOf(u8, json, "\"tag\":\"") orelse return error.InvalidEnvelope;
        const tag_begin = tag_start + 7;
        // Bounds check for tag
        if (tag_begin + 32 > json.len) return error.InvalidEnvelope;
        for (0..16) |i| {
            const hex_start = tag_begin + i * 2;
            envelope.tag[i] = std.fmt.parseInt(u8, json[hex_start .. hex_start + 2], 16) catch return error.InvalidHexInTag;
        }

        envelope.version = 1;
        envelope.algorithm = "AES-256-GCM";
        envelope.ciphertext = try self.allocator.dupe(u8, &[_]u8{}); // Will be overwritten

        return envelope;
    }
};

pub const VaultEnvelope = struct {
    version: u8,
    algorithm: []const u8,
    master_key_name: []const u8,
    nonce: [12]u8,
    tag: [16]u8,
    ciphertext: []u8,
};

pub const WrappedKey = struct {
    key_id: []const u8,
    ciphertext: []u8,
    metadata: ?[]u8,

    pub fn deinit(self: *WrappedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.key_id);
        allocator.free(self.ciphertext);
        if (self.metadata) |meta| {
            allocator.free(meta);
        }
    }
};

// Factory function for easy Vault KMS creation
pub fn createVaultKMSProvider(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) VaultKMSProvider {
    return VaultKMSProvider.init(allocator, vault_addr, vault_token, key_path);
}

// Integration with environment variables
pub fn createVaultKMSFromEnv(allocator: std.mem.Allocator) !VaultKMSProvider {
    const vault_addr = std.process.getEnvVarOwned(allocator, "VAULT_ADDR") catch return error.VaultAddrNotSet;
    defer allocator.free(vault_addr);

    const vault_token = std.process.getEnvVarOwned(allocator, "VAULT_TOKEN") catch return error.VaultTokenNotSet;
    defer allocator.free(vault_token);

    const key_path = std.process.getEnvVarOwned(allocator, "VAULT_KEY_PATH") catch "geode";
    defer if (!std.mem.eql(u8, key_path, "geode")) allocator.free(key_path);

    return VaultKMSProvider.init(allocator, try allocator.dupe(u8, vault_addr), try allocator.dupe(u8, vault_token), try allocator.dupe(u8, key_path));
}
