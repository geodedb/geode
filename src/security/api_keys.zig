// API Keys Authentication Module
// CANARY: REQ=REQ-AUTH-APIKEYS-001; FEATURE="ApiKeyAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig|geodetestlab/specs/api_key_auth.yml; OWNER=security; UPDATED=2026-01-29
// GAP-0245: API Keys for HTTP support endpoints
//
// Thin compatibility wrapper over the external `auth` library's api_keys module.
// Preserves the original public API (Geode Key v1 "gk1" prefix, error types,
// function signatures) so that consumers (authn.zig, apikey_cli.zig) require
// no changes.
//
// API Key Format: gk1.<token_id_b64url>.<secret_b64url>
// - gk1: Version prefix (Geode Key v1)
// - token_id_b64url: 16-byte token ID, base64url encoded (no padding)
// - secret_b64url: 32-byte secret, base64url encoded (no padding)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ext_api_keys = @import("auth_lib").api_keys;

/// API Key version prefix
pub const API_KEY_VERSION = "gk1";

/// Token ID size in bytes
pub const TOKEN_ID_SIZE: usize = ext_api_keys.TOKEN_ID_SIZE;

/// Secret size in bytes
pub const SECRET_SIZE: usize = ext_api_keys.SECRET_SIZE;

/// Geode-specific configuration for the external API key manager.
const geode_config = ext_api_keys.Config{
    .key_prefix = API_KEY_VERSION,
};

/// API Key structure
pub const ApiKey = ext_api_keys.ApiKey;

/// Parsed API key from string format
pub const ParsedApiKey = struct {
    id: [TOKEN_ID_SIZE]u8,
    secret: [SECRET_SIZE]u8,
};

/// API Key Manager
pub const ApiKeyManager = struct {
    const Self = @This();

    inner: ext_api_keys.ApiKeyManager,

    pub fn init(allocator: Allocator) Self {
        return .{
            .inner = ext_api_keys.ApiKeyManager.init(allocator, geode_config),
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
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
        return self.inner.createKey(user_id, name, scopes, expires_in_seconds);
    }

    /// Validate an API key and return the associated key info
    /// CANARY: REQ=REQ-AUTH-APIKEYS-003; FEATURE="ApiKeyValidation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
    pub fn validateKey(self: *Self, key_string: []const u8) !?ApiKey {
        return self.inner.validateKey(key_string);
    }

    /// Check if a key has a specific scope
    pub fn hasScope(key: *const ApiKey, scope: []const u8) bool {
        return ext_api_keys.ApiKeyManager.hasScope(key, scope);
    }

    /// Revoke an API key by ID
    /// CANARY: REQ=REQ-AUTH-APIKEYS-004; FEATURE="ApiKeyRevocation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
    pub fn revokeKey(self: *Self, id: [TOKEN_ID_SIZE]u8) bool {
        return self.inner.revokeKey(id);
    }

    /// Revoke all keys for a user
    pub fn revokeUserKeys(self: *Self, user_id: u64) usize {
        return self.inner.revokeUserKeys(user_id);
    }

    /// List all keys for a user (excludes secret)
    pub fn listUserKeys(self: *Self, allocator: Allocator, user_id: u64) ![]ApiKey {
        return self.inner.listUserKeys(allocator, user_id);
    }

    /// Free a key list returned by `listUserKeys`.
    pub fn freeKeyList(allocator: Allocator, keys: []ApiKey) void {
        ext_api_keys.ApiKeyManager.freeKeyList(allocator, keys);
    }

    /// Delete expired keys (cleanup)
    pub fn cleanupExpired(self: *Self) usize {
        return self.inner.cleanupExpired() catch 0;
    }
};

/// Format an API key to string: gk1.<id_b64url>.<secret_b64url>
pub fn formatApiKey(allocator: Allocator, id: *const [TOKEN_ID_SIZE]u8, secret: *const [SECRET_SIZE]u8) ![]u8 {
    return ext_api_keys.formatApiKey(allocator, API_KEY_VERSION, id, secret);
}

/// Parse an API key string to components
pub fn parseApiKey(key_string: []const u8) !ParsedApiKey {
    const parsed = ext_api_keys.parseApiKey(key_string) catch |err| switch (err) {
        error.InvalidApiKeyFormat => return error.InvalidApiKeyFormat,
    };

    // Enforce Geode Key v1 prefix
    if (!std.mem.eql(u8, parsed.prefix, API_KEY_VERSION)) {
        return error.UnsupportedApiKeyVersion;
    }

    return ParsedApiKey{
        .id = parsed.id,
        .secret = parsed.secret,
    };
}

/// Parse Bearer token from HTTP Authorization header
/// CANARY: REQ=REQ-AUTH-APIKEYS-005; FEATURE="BearerTokenParsing"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_api_keys.zig; OWNER=security; UPDATED=2026-01-29
pub fn parseBearerToken(auth_header: []const u8) ?[]const u8 {
    return ext_api_keys.parseBearerToken(auth_header);
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

    try std.testing.expect(ApiKeyManager.hasScope(&key, "metrics:read"));
    try std.testing.expect(ApiKeyManager.hasScope(&key, "health:read"));
    try std.testing.expect(!ApiKeyManager.hasScope(&key, "admin:write"));
}

test "ApiKeyManager: wildcard scope grants all" {
    const allocator = std.testing.allocator;

    var manager = ApiKeyManager.init(allocator);
    defer manager.deinit();

    const key_string = try manager.createKey(1, "admin-key", &[_][]const u8{"*"}, null);
    defer allocator.free(key_string);

    const key = (try manager.validateKey(key_string)).?;

    try std.testing.expect(ApiKeyManager.hasScope(&key, "metrics:read"));
    try std.testing.expect(ApiKeyManager.hasScope(&key, "admin:write"));
    try std.testing.expect(ApiKeyManager.hasScope(&key, "anything"));
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
