// API Keys Authentication Module
// CANARY: REQ=REQ-AUTH-APIKEYS-001; FEATURE="ApiKeyAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig|geodetestlab/specs/api_key_auth.yml; OWNER=security; UPDATED=2026-01-29
// GAP-0245: API Keys for HTTP support endpoints
//
// API Key Format: gk1.<token_id_b64url>.<secret_b64url>
// - gk1: Version prefix (Geode Key v1)
// - token_id_b64url: 16-byte token ID, base64url encoded (no padding)
// - secret_b64url: 32-byte secret, base64url encoded (no padding)

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

/// API Key version prefix
pub const API_KEY_VERSION = "gk1";

/// Token ID size in bytes
pub const TOKEN_ID_SIZE: usize = 16;

/// Secret size in bytes
pub const SECRET_SIZE: usize = 32;

/// API Key structure
pub const ApiKey = struct {
    id: [TOKEN_ID_SIZE]u8,
    secret_hash: [32]u8, // SHA-256 hash of secret (never store raw secret)
    user_id: u64,
    name: []const u8,
    created_at: i64,
    expires_at: ?i64, // null = never expires
    last_used_at: ?i64,
    scopes: []const []const u8, // e.g., ["metrics:read", "health:read"]
    is_active: bool,
};

/// Parsed API key from string format
pub const ParsedApiKey = struct {
    id: [TOKEN_ID_SIZE]u8,
    secret: [SECRET_SIZE]u8,
};

/// API Key Manager
pub const ApiKeyManager = struct {
    const Self = @This();

    allocator: Allocator,
    keys: std.AutoHashMap([TOKEN_ID_SIZE]u8, ApiKey),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .keys = std.AutoHashMap([TOKEN_ID_SIZE]u8, ApiKey).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            for (entry.value_ptr.scopes) |scope| {
                self.allocator.free(scope);
            }
            self.allocator.free(entry.value_ptr.scopes);
        }
        self.keys.deinit();
    }

    /// Create a new API key for a user
    /// Returns the full key string (only time secret is available)
    /// CANARY: REQ=REQ-AUTH-APIKEYS-002; FEATURE="ApiKeyCreation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
    pub fn createKey(
        self: *Self,
        user_id: u64,
        name: []const u8,
        scopes: []const []const u8,
        expires_in_seconds: ?i64,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Generate cryptographically random token ID and secret
        var id: [TOKEN_ID_SIZE]u8 = undefined;
        var secret: [SECRET_SIZE]u8 = undefined;
        crypto.random.bytes(&id);
        crypto.random.bytes(&secret);

        // Hash the secret for storage (never store raw secret)
        var secret_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&secret, &secret_hash, .{});

        // Calculate expiration
        const now = std.time.timestamp();
        const expires_at: ?i64 = if (expires_in_seconds) |exp| now + exp else null;

        // Duplicate name and scopes
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);

        const scopes_dup = try self.allocator.alloc([]const u8, scopes.len);
        errdefer self.allocator.free(scopes_dup);
        for (scopes, 0..) |scope, i| {
            scopes_dup[i] = try self.allocator.dupe(u8, scope);
        }

        const key = ApiKey{
            .id = id,
            .secret_hash = secret_hash,
            .user_id = user_id,
            .name = name_dup,
            .created_at = now,
            .expires_at = expires_at,
            .last_used_at = null,
            .scopes = scopes_dup,
            .is_active = true,
        };

        try self.keys.put(id, key);

        // Format the key string: gk1.<id_b64url>.<secret_b64url>
        return formatApiKey(self.allocator, &id, &secret);
    }

    /// Validate an API key and return the associated key info
    /// CANARY: REQ=REQ-AUTH-APIKEYS-003; FEATURE="ApiKeyValidation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
    pub fn validateKey(self: *Self, key_string: []const u8) !?*ApiKey {
        const parsed = try parseApiKey(key_string);

        self.mutex.lock();
        defer self.mutex.unlock();

        const key = self.keys.getPtr(parsed.id) orelse return null;

        // Check if key is active
        if (!key.is_active) return null;

        // Check expiration
        if (key.expires_at) |exp| {
            if (std.time.timestamp() >= exp) {
                key.is_active = false;
                return null;
            }
        }

        // Verify secret using constant-time comparison
        var provided_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&parsed.secret, &provided_hash, .{});

        if (!constantTimeEqual(&provided_hash, &key.secret_hash)) {
            return null;
        }

        // Update last used timestamp
        key.last_used_at = std.time.timestamp();

        return key;
    }

    /// Check if a key has a specific scope
    pub fn hasScope(key: *const ApiKey, scope: []const u8) bool {
        for (key.scopes) |s| {
            if (std.mem.eql(u8, s, scope) or std.mem.eql(u8, s, "*")) {
                return true;
            }
        }
        return false;
    }

    /// Revoke an API key by ID
    /// CANARY: REQ=REQ-AUTH-APIKEYS-004; FEATURE="ApiKeyRevocation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
    pub fn revokeKey(self: *Self, id: [TOKEN_ID_SIZE]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.keys.getPtr(id)) |key| {
            key.is_active = false;
            return true;
        }
        return false;
    }

    /// Revoke all keys for a user
    pub fn revokeUserKeys(self: *Self, user_id: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.user_id == user_id and entry.value_ptr.is_active) {
                entry.value_ptr.is_active = false;
                count += 1;
            }
        }
        return count;
    }

    /// List all keys for a user (excludes secret)
    pub fn listUserKeys(self: *Self, allocator: Allocator, user_id: u64) ![]ApiKey {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayListUnmanaged(ApiKey) = .empty;
        errdefer list.deinit(allocator);

        var it = self.keys.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.user_id == user_id) {
                try list.append(allocator, entry.value_ptr.*);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// Delete expired keys (cleanup)
    pub fn cleanupExpired(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove: std.ArrayListUnmanaged([TOKEN_ID_SIZE]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        const now = std.time.timestamp();
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at) |exp| {
                if (now >= exp) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            }
        }

        for (to_remove.items) |id| {
            if (self.keys.fetchRemove(id)) |kv| {
                self.allocator.free(kv.value.name);
                for (kv.value.scopes) |scope| {
                    self.allocator.free(scope);
                }
                self.allocator.free(kv.value.scopes);
            }
        }

        return to_remove.items.len;
    }
};

/// Format an API key to string: gk1.<id_b64url>.<secret_b64url>
pub fn formatApiKey(allocator: Allocator, id: *const [TOKEN_ID_SIZE]u8, secret: *const [SECRET_SIZE]u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;

    const id_encoded_len = encoder.calcSize(TOKEN_ID_SIZE);
    const secret_encoded_len = encoder.calcSize(SECRET_SIZE);

    // gk1 + . + id + . + secret
    const total_len = API_KEY_VERSION.len + 1 + id_encoded_len + 1 + secret_encoded_len;
    var result = try allocator.alloc(u8, total_len);

    // Write version prefix
    @memcpy(result[0..API_KEY_VERSION.len], API_KEY_VERSION);
    result[API_KEY_VERSION.len] = '.';

    // Encode ID
    _ = encoder.encode(result[API_KEY_VERSION.len + 1 ..][0..id_encoded_len], id);
    result[API_KEY_VERSION.len + 1 + id_encoded_len] = '.';

    // Encode secret
    _ = encoder.encode(result[API_KEY_VERSION.len + 1 + id_encoded_len + 1 ..], secret);

    return result;
}

/// Parse an API key string to components
pub fn parseApiKey(key_string: []const u8) !ParsedApiKey {
    // Split by '.'
    var parts = std.mem.splitScalar(u8, key_string, '.');

    // Version prefix
    const version = parts.next() orelse return error.InvalidApiKeyFormat;
    if (!std.mem.eql(u8, version, API_KEY_VERSION)) {
        return error.UnsupportedApiKeyVersion;
    }

    // Token ID
    const id_encoded = parts.next() orelse return error.InvalidApiKeyFormat;
    const decoder = std.base64.url_safe_no_pad.Decoder;

    const id_size = decoder.calcSizeForSlice(id_encoded) catch return error.InvalidApiKeyFormat;
    if (id_size != TOKEN_ID_SIZE) {
        return error.InvalidApiKeyFormat;
    }
    var id: [TOKEN_ID_SIZE]u8 = undefined;
    decoder.decode(&id, id_encoded) catch return error.InvalidApiKeyFormat;

    // Secret
    const secret_encoded = parts.next() orelse return error.InvalidApiKeyFormat;
    const secret_size = decoder.calcSizeForSlice(secret_encoded) catch return error.InvalidApiKeyFormat;
    if (secret_size != SECRET_SIZE) {
        return error.InvalidApiKeyFormat;
    }
    var secret: [SECRET_SIZE]u8 = undefined;
    decoder.decode(&secret, secret_encoded) catch return error.InvalidApiKeyFormat;

    // Should be no more parts
    if (parts.next() != null) return error.InvalidApiKeyFormat;

    return ParsedApiKey{
        .id = id,
        .secret = secret,
    };
}

/// Parse Bearer token from HTTP Authorization header
/// CANARY: REQ=REQ-AUTH-APIKEYS-005; FEATURE="BearerTokenParsing"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
pub fn parseBearerToken(auth_header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (std.mem.startsWith(u8, auth_header, prefix)) {
        const token = std.mem.trim(u8, auth_header[prefix.len..], " \t\r\n");
        if (token.len > 0) {
            return token;
        }
    }
    return null;
}

/// Constant-time comparison to prevent timing attacks
fn constantTimeEqual(a: *const [32]u8, b: *const [32]u8) bool {
    var result: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        result |= byte_a ^ byte_b;
    }
    return result == 0;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "ApiKeyManager: create and validate key" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    // Create a key
    const key_string = try manager.createKey(
        1, // user_id
        "test-key",
        &[_][]const u8{ "metrics:read", "health:read" },
        null, // no expiration
    );
    defer allocator.free(key_string);

    // Validate the key
    const key = try manager.validateKey(key_string);
    try std.testing.expect(key != null);

    if (key) |k| {
        try std.testing.expectEqual(@as(u64, 1), k.user_id);
        try std.testing.expectEqualStrings("test-key", k.name);
        try std.testing.expect(k.is_active);
        try std.testing.expectEqual(@as(usize, 2), k.scopes.len);
    }
}

test "ApiKeyManager: validate key with wrong secret fails" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createKey(1, "test-key", &[_][]const u8{"metrics:read"}, null);

    // Try to validate with a fake key
    const fake_key = "gk1.AAAAAAAAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const result = try manager.validateKey(fake_key);
    try std.testing.expect(result == null);
}

test "ApiKeyManager: revoke key" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    const key_string = try manager.createKey(1, "test-key", &[_][]const u8{"metrics:read"}, null);
    defer allocator.free(key_string);

    // Validate works before revocation
    var key = try manager.validateKey(key_string);
    try std.testing.expect(key != null);

    // Revoke
    const parsed = try parseApiKey(key_string);
    try std.testing.expect(manager.revokeKey(parsed.id));

    // Validate fails after revocation
    key = try manager.validateKey(key_string);
    try std.testing.expect(key == null);
}

test "ApiKeyManager: expired key fails validation" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    // Create key that expires immediately (negative seconds in past)
    const key_string = try manager.createKey(1, "test-key", &[_][]const u8{"metrics:read"}, -1);
    defer allocator.free(key_string);

    // Should fail validation
    const key = try manager.validateKey(key_string);
    try std.testing.expect(key == null);
}

test "ApiKeyManager: hasScope checks correctly" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    const key_string = try manager.createKey(
        1,
        "test-key",
        &[_][]const u8{ "metrics:read", "health:read" },
        null,
    );
    defer allocator.free(key_string);

    const key = (try manager.validateKey(key_string)).?;

    try std.testing.expect(ApiKeyManager.hasScope(key, "metrics:read"));
    try std.testing.expect(ApiKeyManager.hasScope(key, "health:read"));
    try std.testing.expect(!ApiKeyManager.hasScope(key, "admin:write"));
}

test "ApiKeyManager: wildcard scope grants all" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    const key_string = try manager.createKey(1, "admin-key", &[_][]const u8{"*"}, null);
    defer allocator.free(key_string);

    const key = (try manager.validateKey(key_string)).?;

    try std.testing.expect(ApiKeyManager.hasScope(key, "metrics:read"));
    try std.testing.expect(ApiKeyManager.hasScope(key, "admin:write"));
    try std.testing.expect(ApiKeyManager.hasScope(key, "anything"));
}

test "parseApiKey: valid key format" {
    const allocator = std.testing.allocator;

    // Create a properly formatted key
    var id: [TOKEN_ID_SIZE]u8 = undefined;
    var secret: [SECRET_SIZE]u8 = undefined;
    @memset(&id, 0xAB);
    @memset(&secret, 0xCD);

    const key_string = try formatApiKey(allocator, &id, &secret);
    defer allocator.free(key_string);

    const parsed = try parseApiKey(key_string);
    try std.testing.expectEqualSlices(u8, &id, &parsed.id);
    try std.testing.expectEqualSlices(u8, &secret, &parsed.secret);
}

test "parseApiKey: invalid version fails" {
    const result = parseApiKey("gk2.AAAAAAAAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try std.testing.expectError(error.UnsupportedApiKeyVersion, result);
}

test "parseApiKey: invalid format fails" {
    // Missing parts
    try std.testing.expectError(error.InvalidApiKeyFormat, parseApiKey("gk1.abc"));
    try std.testing.expectError(error.InvalidApiKeyFormat, parseApiKey("gk1"));

    // Too many parts
    try std.testing.expectError(error.InvalidApiKeyFormat, parseApiKey("gk1.a.b.c"));
}

test "parseBearerToken: valid Bearer token" {
    const token = parseBearerToken("Bearer gk1.abc.def");
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("gk1.abc.def", token.?);
}

test "parseBearerToken: Bearer with whitespace" {
    const token = parseBearerToken("Bearer   gk1.abc.def  ");
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("gk1.abc.def", token.?);
}

test "parseBearerToken: invalid prefix returns null" {
    try std.testing.expect(parseBearerToken("Basic abc123") == null);
    try std.testing.expect(parseBearerToken("bearer gk1.abc.def") == null); // case sensitive
    try std.testing.expect(parseBearerToken("") == null);
}
