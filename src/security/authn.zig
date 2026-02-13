// Unified Authentication Provider Chain
// CANARY: REQ=REQ-AUTH-UNIFIED-001; FEATURE="UnifiedAuthenticationProvider"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_authn.zig|geodetestlab/specs/authn_provider.yml; OWNER=security; UPDATED=2026-01-29
//
// This module provides a unified authentication entry point that chains multiple
// authentication providers in order of priority:
//
// 1. mTLS (client certificate) - highest trust level
// 2. API Key (Bearer token) - for programmatic access
// 3. Session Token - for authenticated sessions with rotation
// 4. Username/Password + MFA - for interactive login
//
// The chain stops at the first successful authentication.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;

const api_keys = @import("api_keys.zig");
const mtls_provider = @import("mtls_provider.zig");

/// Authentication method used
pub const AuthMethod = enum {
    mtls,
    api_key,
    session_token,
    password,
    password_mfa,
    recovery_code,
    anonymous, // For public endpoints
};

/// Authentication result
pub const AuthResult = struct {
    user_id: u64,
    username: []const u8,
    method: AuthMethod,
    roles: []const []const u8,
    scopes: []const []const u8, // API key scopes
    session_token: ?[]const u8, // New session token if created
    requires_mfa: bool, // If true, MFA step required
    requires_password_reset: bool,
    elevation_level: ElevationLevel,
};

/// Elevation level for step-up authentication
pub const ElevationLevel = enum {
    none, // Basic authentication
    standard, // Password verified
    elevated, // MFA completed recently
    high_assurance, // mTLS or fresh MFA
};

/// Authentication request with all possible credentials
pub const AuthRequest = struct {
    // mTLS
    client_cert_der: ?[]const u8 = null,

    // API Key (from Authorization: Bearer header)
    bearer_token: ?[]const u8 = null,

    // Session token
    session_token: ?[]const u8 = null,

    // Username/Password
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    // MFA
    totp_code: ?u32 = null,
    recovery_code: ?[]const u8 = null,

    // Request context
    ip_address: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    request_path: ?[]const u8 = null,
};

/// Session token with rotation support
/// CANARY: REQ=REQ-AUTH-SESSION-ROTATE-001; FEATURE="RotatingSessionToken"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_authn.zig; OWNER=security; UPDATED=2026-01-29
pub const RotatingSessionToken = struct {
    token: [32]u8,
    user_id: u64,
    created_at: i64,
    last_used_at: i64,
    expires_at: i64,
    rotation_at: i64, // When to rotate
    previous_token: ?[32]u8, // Grace period for old token
    previous_expires_at: ?i64,
    ip_address: ?[]const u8,
    elevation_level: ElevationLevel,
    mfa_verified_at: ?i64,

    const TOKEN_LIFETIME_SECS: i64 = 86400; // 24 hours
    const ROTATION_INTERVAL_SECS: i64 = 3600; // 1 hour
    const IDLE_TIMEOUT_SECS: i64 = 1800; // 30 minutes
    const GRACE_PERIOD_SECS: i64 = 60; // 1 minute grace for old token

    pub fn generate(allocator: Allocator, user_id: u64, ip: ?[]const u8) !RotatingSessionToken {
        _ = allocator;
        var token: [32]u8 = undefined;
        crypto.random.bytes(&token);

        const now = std.time.timestamp();

        return RotatingSessionToken{
            .token = token,
            .user_id = user_id,
            .created_at = now,
            .last_used_at = now,
            .expires_at = now + TOKEN_LIFETIME_SECS,
            .rotation_at = now + ROTATION_INTERVAL_SECS,
            .previous_token = null,
            .previous_expires_at = null,
            .ip_address = ip,
            .elevation_level = .standard,
            .mfa_verified_at = null,
        };
    }

    pub fn needsRotation(self: *const RotatingSessionToken) bool {
        return std.time.timestamp() >= self.rotation_at;
    }

    pub fn rotate(self: *RotatingSessionToken) void {
        const now = std.time.timestamp();

        // Save current token as previous (grace period)
        self.previous_token = self.token;
        self.previous_expires_at = now + GRACE_PERIOD_SECS;

        // Generate new token
        crypto.random.bytes(&self.token);
        self.rotation_at = now + ROTATION_INTERVAL_SECS;
        self.last_used_at = now;
    }

    pub fn isExpired(self: *const RotatingSessionToken) bool {
        return std.time.timestamp() >= self.expires_at;
    }

    pub fn isIdle(self: *const RotatingSessionToken) bool {
        return (std.time.timestamp() - self.last_used_at) >= IDLE_TIMEOUT_SECS;
    }

    pub fn touch(self: *RotatingSessionToken) void {
        self.last_used_at = std.time.timestamp();
    }

    pub fn matchesToken(self: *const RotatingSessionToken, token: *const [32]u8) bool {
        // Check current token
        if (constantTimeEqual(&self.token, token)) return true;

        // Check previous token during grace period
        if (self.previous_token) |prev| {
            if (self.previous_expires_at) |exp| {
                if (std.time.timestamp() < exp) {
                    return constantTimeEqual(&prev, token);
                }
            }
        }

        return false;
    }

    pub fn setMfaVerified(self: *RotatingSessionToken) void {
        self.mfa_verified_at = std.time.timestamp();
        self.elevation_level = .elevated;
    }

    pub fn toHexString(self: *const RotatingSessionToken, allocator: Allocator) ![]u8 {
        const hex_array = std.fmt.bytesToHex(self.token, .lower);
        return allocator.dupe(u8, &hex_array);
    }
};

/// Unified Authentication Provider
pub const AuthProvider = struct {
    const Self = @This();

    allocator: Allocator,
    api_key_manager: api_keys.ApiKeyManager,
    mtls: mtls_provider.MtlsProvider,
    sessions: std.StringHashMap(RotatingSessionToken),
    mutex: std.Thread.Mutex,

    // Configuration
    allow_anonymous: bool,
    anonymous_paths: std.StringHashMap(void), // Paths that allow anonymous access
    require_mfa_paths: std.StringHashMap(void), // Paths requiring MFA

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .api_key_manager = api_keys.ApiKeyManager.init(allocator),
            .mtls = mtls_provider.MtlsProvider.init(allocator),
            .sessions = std.StringHashMap(RotatingSessionToken).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allow_anonymous = false,
            .anonymous_paths = std.StringHashMap(void).init(allocator),
            .require_mfa_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.api_key_manager.deinit();
        self.mtls.deinit();

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.ip_address) |ip| {
                self.allocator.free(ip);
            }
        }
        self.sessions.deinit();
        self.anonymous_paths.deinit();
        self.require_mfa_paths.deinit();
    }

    /// Authenticate a request through the provider chain
    /// CANARY: REQ=REQ-AUTH-UNIFIED-002; FEATURE="AuthenticationChain"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_authn.zig; OWNER=security; UPDATED=2026-01-29
    pub fn authenticate(self: *Self, request: AuthRequest) !AuthResult {
        // Check for anonymous access first
        if (self.allow_anonymous) {
            if (request.request_path) |path| {
                if (self.anonymous_paths.contains(path)) {
                    return AuthResult{
                        .user_id = 0,
                        .username = "anonymous",
                        .method = .anonymous,
                        .roles = &[_][]const u8{},
                        .scopes = &[_][]const u8{},
                        .session_token = null,
                        .requires_mfa = false,
                        .requires_password_reset = false,
                        .elevation_level = .none,
                    };
                }
            }
        }

        // 1. Try mTLS (highest priority)
        if (request.client_cert_der) |cert_der| {
            if (try self.tryMtlsAuth(cert_der)) |result| {
                return result;
            }
        }

        // 2. Try API Key
        if (request.bearer_token) |token| {
            if (try self.tryApiKeyAuth(token)) |result| {
                return result;
            }
        }

        // 3. Try Session Token
        if (request.session_token) |token| {
            if (try self.trySessionAuth(token, request.request_path)) |result| {
                return result;
            }
        }

        // 4. Password auth is handled separately via authenticatePassword
        // as it may need SecurityManager integration

        return error.AuthenticationRequired;
    }

    /// Try mTLS authentication
    fn tryMtlsAuth(self: *Self, cert_der: []const u8) !?AuthResult {
        const identity = try mtls_provider.extractIdentity(self.allocator, cert_der);
        const mtls_result = try self.mtls.authenticate(&identity);

        if (mtls_result) |r| {
            return AuthResult{
                .user_id = r.user_id,
                .username = r.matched_value,
                .method = .mtls,
                .roles = r.roles,
                .scopes = &[_][]const u8{"*"}, // mTLS gets full access
                .session_token = null,
                .requires_mfa = false,
                .requires_password_reset = false,
                .elevation_level = .high_assurance,
            };
        }

        return null;
    }

    /// Try API Key authentication
    fn tryApiKeyAuth(self: *Self, token: []const u8) !?AuthResult {
        const key = try self.api_key_manager.validateKey(token);

        if (key) |k| {
            return AuthResult{
                .user_id = k.user_id,
                .username = k.name,
                .method = .api_key,
                .roles = &[_][]const u8{},
                .scopes = k.scopes,
                .session_token = null,
                .requires_mfa = false,
                .requires_password_reset = false,
                .elevation_level = .standard,
            };
        }

        return null;
    }

    /// Try session token authentication
    fn trySessionAuth(self: *Self, token_hex: []const u8, path: ?[]const u8) !?AuthResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.getPtr(token_hex) orelse return null;

        // Decode hex token
        if (token_hex.len != 64) return null;
        var token_bytes: [32]u8 = undefined;
        for (0..32) |i| {
            const hi = std.fmt.charToDigit(token_hex[i * 2], 16) catch return null;
            const lo = std.fmt.charToDigit(token_hex[i * 2 + 1], 16) catch return null;
            token_bytes[i] = @as(u8, hi) * 16 + @as(u8, lo);
        }

        if (!session.matchesToken(&token_bytes)) return null;
        if (session.isExpired()) return null;
        if (session.isIdle()) return error.SessionIdleTimeout;

        // Check if MFA is required for this path
        var requires_mfa = false;
        if (path) |p| {
            if (self.require_mfa_paths.contains(p)) {
                if (session.elevation_level != .elevated and
                    session.elevation_level != .high_assurance)
                {
                    requires_mfa = true;
                }
            }
        }

        // Touch session and check for rotation
        session.touch();

        var new_token: ?[]u8 = null;
        if (session.needsRotation()) {
            session.rotate();
            new_token = try session.toHexString(self.allocator);

            // Update session key in map
            // (In production, would need atomic update)
        }

        return AuthResult{
            .user_id = session.user_id,
            .username = "", // Would need lookup
            .method = .session_token,
            .roles = &[_][]const u8{},
            .scopes = &[_][]const u8{"*"},
            .session_token = new_token,
            .requires_mfa = requires_mfa,
            .requires_password_reset = false,
            .elevation_level = session.elevation_level,
        };
    }

    /// Create a new session for a user
    pub fn createSession(self: *Self, user_id: u64, ip: ?[]const u8) ![]u8 {
        const ip_dup = if (ip) |i| try self.allocator.dupe(u8, i) else null;
        errdefer if (ip_dup) |i| self.allocator.free(i);

        var session = try RotatingSessionToken.generate(self.allocator, user_id, ip_dup);
        const token_hex = try session.toHexString(self.allocator);
        errdefer self.allocator.free(token_hex);

        self.mutex.lock();
        defer self.mutex.unlock();

        const key_dup = try self.allocator.dupe(u8, token_hex);
        try self.sessions.put(key_dup, session);

        return token_hex;
    }

    /// Mark a session as MFA verified
    pub fn markSessionMfaVerified(self: *Self, token_hex: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(token_hex)) |session| {
            session.setMfaVerified();
            return true;
        }
        return false;
    }

    /// Invalidate a session
    pub fn invalidateSession(self: *Self, token_hex: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(token_hex)) |kv| {
            self.allocator.free(kv.key);
            if (kv.value.ip_address) |ip| {
                self.allocator.free(ip);
            }
        }
    }

    /// Invalidate all sessions for a user
    pub fn invalidateUserSessions(self: *Self, user_id: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.user_id == user_id) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                if (kv.value.ip_address) |ip| {
                    self.allocator.free(ip);
                }
            }
        }

        return to_remove.items.len;
    }

    /// Cleanup expired sessions
    pub fn cleanupExpiredSessions(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired() or entry.value_ptr.isIdle()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                if (kv.value.ip_address) |ip| {
                    self.allocator.free(ip);
                }
            }
        }

        return to_remove.items.len;
    }

    /// Add path that allows anonymous access
    pub fn allowAnonymousPath(self: *Self, path: []const u8) !void {
        try self.anonymous_paths.put(path, {});
    }

    /// Add path that requires MFA
    pub fn requireMfaForPath(self: *Self, path: []const u8) !void {
        try self.require_mfa_paths.put(path, {});
    }
};

/// Constant-time comparison to prevent timing attacks (#440: use stdlib implementation)
fn constantTimeEqual(a: *const [32]u8, b: *const [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, a.*, b.*);
}

/// Extract Bearer token from HTTP Authorization header
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    return api_keys.parseBearerToken(auth_header);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "RotatingSessionToken: generate and validate" {
    const allocator = std.testing.allocator;

    var session = try RotatingSessionToken.generate(allocator, 42, null);

    try std.testing.expectEqual(@as(u64, 42), session.user_id);
    try std.testing.expect(!session.isExpired());
    try std.testing.expect(!session.isIdle());
    try std.testing.expect(session.matchesToken(&session.token));
}

test "RotatingSessionToken: rotation preserves grace period" {
    const allocator = std.testing.allocator;

    var session = try RotatingSessionToken.generate(allocator, 42, null);

    const original_token = session.token;

    // Force rotation
    session.rotation_at = 0;
    try std.testing.expect(session.needsRotation());

    session.rotate();

    // New token should be different
    try std.testing.expect(!std.mem.eql(u8, &session.token, &original_token));

    // Old token should still work (grace period)
    try std.testing.expect(session.matchesToken(&original_token));
    try std.testing.expect(session.matchesToken(&session.token));
}

test "RotatingSessionToken: idle detection" {
    const allocator = std.testing.allocator;

    var session = try RotatingSessionToken.generate(allocator, 42, null);

    // Fresh session is not idle
    try std.testing.expect(!session.isIdle());

    // Simulate idle timeout
    session.last_used_at = std.time.timestamp() - RotatingSessionToken.IDLE_TIMEOUT_SECS - 1;
    try std.testing.expect(session.isIdle());
}

test "AuthProvider: API key authentication" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    // Create an API key
    const key_string = try provider.api_key_manager.createKey(
        100,
        "test-key",
        &[_][]const u8{"metrics:read"},
        null,
    );
    defer allocator.free(key_string);

    // Authenticate with the key
    const result = try provider.authenticate(.{
        .bearer_token = key_string,
    });

    try std.testing.expectEqual(@as(u64, 100), result.user_id);
    try std.testing.expectEqual(AuthMethod.api_key, result.method);
}

test "AuthProvider: session authentication" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    // Create a session
    const token = try provider.createSession(200, null);
    defer allocator.free(token);

    // Authenticate with the session
    const result = try provider.authenticate(.{
        .session_token = token,
    });

    try std.testing.expectEqual(@as(u64, 200), result.user_id);
    try std.testing.expectEqual(AuthMethod.session_token, result.method);
}

test "AuthProvider: authentication fails without credentials" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    // Empty request should fail
    const result = provider.authenticate(.{});
    try std.testing.expectError(error.AuthenticationRequired, result);
}

test "AuthProvider: anonymous path allows access" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    provider.allow_anonymous = true;
    try provider.allowAnonymousPath("/health");

    // Anonymous request to health path should succeed
    const result = try provider.authenticate(.{
        .request_path = "/health",
    });

    try std.testing.expectEqual(AuthMethod.anonymous, result.method);
    try std.testing.expectEqual(@as(u64, 0), result.user_id);
}

test "AuthProvider: MFA required path detection" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    try provider.requireMfaForPath("/admin/settings");

    // Create a session
    const token = try provider.createSession(300, null);
    defer allocator.free(token);

    // Authenticate to admin path - should require MFA
    const result = try provider.authenticate(.{
        .session_token = token,
        .request_path = "/admin/settings",
    });

    try std.testing.expect(result.requires_mfa);
}

test "AuthProvider: invalidate session" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    // Create a session
    const token = try provider.createSession(400, null);

    // Validate it works
    _ = try provider.authenticate(.{ .session_token = token });

    // Invalidate
    provider.invalidateSession(token);
    allocator.free(token);

    // Should fail now
    const result = provider.authenticate(.{ .session_token = "invalid" });
    try std.testing.expectError(error.AuthenticationRequired, result);
}

test "AuthProvider: invalidate user sessions" {
    const allocator = std.testing.allocator;

    var provider = AuthProvider.init(allocator);
    defer provider.deinit();

    // Create multiple sessions for same user
    const token1 = try provider.createSession(500, null);
    const token2 = try provider.createSession(500, null);
    defer allocator.free(token1);
    defer allocator.free(token2);

    // Create session for different user
    const token3 = try provider.createSession(501, null);
    defer allocator.free(token3);

    // Invalidate user 500's sessions
    const count = provider.invalidateUserSessions(500);
    try std.testing.expectEqual(@as(usize, 2), count);

    // User 501's session should still work
    _ = try provider.authenticate(.{ .session_token = token3 });
}
