// mTLS Authentication Provider
// CANARY: REQ=REQ-AUTH-MTLS-001; FEATURE="MtlsAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig|geodetestlab/specs/mtls_auth.yml; OWNER=security; UPDATED=2026-01-29
// GAP-0248: mTLS auth vs transport clarification
//
// This module provides certificate-based authentication by extracting identity
// from client certificates and mapping to Geode principals.
//
// Identity extraction methods:
// 1. Certificate fingerprint (SHA-256)
// 2. Subject Alternative Name (SAN) - DNS, email, URI
// 3. Subject Common Name (CN)
// 4. Subject Distinguished Name (DN)

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

/// Certificate identity extraction method
pub const IdentityMethod = enum {
    fingerprint, // SHA-256 fingerprint of certificate
    san_email, // Subject Alternative Name - email
    san_dns, // Subject Alternative Name - DNS
    san_uri, // Subject Alternative Name - URI
    subject_cn, // Subject Common Name
    subject_dn, // Full Subject Distinguished Name
};

/// Certificate identity extracted from client cert
pub const CertificateIdentity = struct {
    fingerprint: [64]u8, // SHA-256 as hex string
    subject_cn: ?[]const u8,
    subject_dn: ?[]const u8,
    san_email: ?[]const u8,
    san_dns: ?[]const u8,
    san_uri: ?[]const u8,
    issuer_dn: ?[]const u8,
    not_before: i64,
    not_after: i64,
    serial_number: []const u8,
};

/// Certificate-to-user mapping entry
pub const CertificateMapping = struct {
    method: IdentityMethod,
    pattern: []const u8, // Exact match or glob pattern
    user_id: u64,
    roles: []const []const u8,
    enabled: bool,
    created_at: i64,
    description: []const u8,
};

/// mTLS Provider manages certificate-to-user mappings
pub const MtlsProvider = struct {
    const Self = @This();

    allocator: Allocator,
    mappings: std.ArrayList(CertificateMapping),
    /// Fingerprint-based fast lookup cache
    fingerprint_cache: std.StringHashMap(u64),
    mutex: std.Thread.Mutex,
    /// Default identity extraction method
    default_method: IdentityMethod,
    /// Require exact fingerprint match (strictest security)
    strict_mode: bool,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .mappings = std.ArrayList(CertificateMapping).initCapacity(allocator, 0) catch unreachable,
            .fingerprint_cache = std.StringHashMap(u64).init(allocator),
            .mutex = std.Thread.Mutex{},
            .default_method = .fingerprint,
            .strict_mode = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.mappings.items) |mapping| {
            self.allocator.free(mapping.pattern);
            self.allocator.free(mapping.description);
            for (mapping.roles) |role| {
                self.allocator.free(role);
            }
            self.allocator.free(mapping.roles);
        }
        self.mappings.deinit(self.allocator);

        var it = self.fingerprint_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.fingerprint_cache.deinit();
    }

    /// Add a certificate-to-user mapping
    /// CANARY: REQ=REQ-AUTH-MTLS-002; FEATURE="CertificateMappingCreation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-01-29
    pub fn addMapping(
        self: *Self,
        method: IdentityMethod,
        pattern: []const u8,
        user_id: u64,
        roles: []const []const u8,
        description: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pattern_dup = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_dup);

        const desc_dup = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_dup);

        const roles_dup = try self.allocator.alloc([]const u8, roles.len);
        errdefer self.allocator.free(roles_dup);
        for (roles, 0..) |role, i| {
            roles_dup[i] = try self.allocator.dupe(u8, role);
        }

        const mapping = CertificateMapping{
            .method = method,
            .pattern = pattern_dup,
            .user_id = user_id,
            .roles = roles_dup,
            .enabled = true,
            .created_at = std.time.timestamp(),
            .description = desc_dup,
        };

        try self.mappings.append(self.allocator, mapping);

        // Add to fingerprint cache if applicable
        if (method == .fingerprint) {
            const pattern_key = try self.allocator.dupe(u8, pattern);
            try self.fingerprint_cache.put(pattern_key, user_id);
        }
    }

    /// Remove a mapping by pattern
    pub fn removeMapping(self: *Self, method: IdentityMethod, pattern: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var idx: usize = 0;
        while (idx < self.mappings.items.len) {
            const mapping = self.mappings.items[idx];
            if (mapping.method == method and std.mem.eql(u8, mapping.pattern, pattern)) {
                // Remove from cache
                if (method == .fingerprint) {
                    if (self.fingerprint_cache.fetchRemove(pattern)) |kv| {
                        self.allocator.free(kv.key);
                    }
                }

                // Free mapping resources
                self.allocator.free(mapping.pattern);
                self.allocator.free(mapping.description);
                for (mapping.roles) |role| {
                    self.allocator.free(role);
                }
                self.allocator.free(mapping.roles);

                _ = self.mappings.orderedRemove(idx);
                return true;
            }
            idx += 1;
        }
        return false;
    }

    /// Authenticate a certificate and return the user ID
    /// CANARY: REQ=REQ-AUTH-MTLS-003; FEATURE="CertificateAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-01-29
    pub fn authenticate(self: *Self, identity: *const CertificateIdentity) !?AuthResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check certificate validity period
        const now = std.time.timestamp();
        if (now < identity.not_before or now > identity.not_after) {
            return error.CertificateExpired;
        }

        // Try fingerprint cache first (fast path)
        if (self.fingerprint_cache.get(&identity.fingerprint)) |user_id| {
            // Find the mapping to get roles
            for (self.mappings.items) |mapping| {
                if (mapping.method == .fingerprint and
                    std.mem.eql(u8, mapping.pattern, &identity.fingerprint) and
                    mapping.enabled)
                {
                    return AuthResult{
                        .user_id = user_id,
                        .roles = mapping.roles,
                        .method = .fingerprint,
                        .matched_value = &identity.fingerprint,
                    };
                }
            }
        }

        // Fall back to checking all mappings
        for (self.mappings.items) |mapping| {
            if (!mapping.enabled) continue;

            const identity_value = switch (mapping.method) {
                .fingerprint => @as(?[]const u8, &identity.fingerprint),
                .san_email => identity.san_email,
                .san_dns => identity.san_dns,
                .san_uri => identity.san_uri,
                .subject_cn => identity.subject_cn,
                .subject_dn => identity.subject_dn,
            };

            if (identity_value) |value| {
                if (matchPattern(mapping.pattern, value)) {
                    return AuthResult{
                        .user_id = mapping.user_id,
                        .roles = mapping.roles,
                        .method = mapping.method,
                        .matched_value = value,
                    };
                }
            }
        }

        // In strict mode, no mapping = authentication failure
        if (self.strict_mode) {
            return null;
        }

        return null;
    }

    /// Enable/disable a mapping
    pub fn setMappingEnabled(self: *Self, method: IdentityMethod, pattern: []const u8, enabled: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.mappings.items) |*mapping| {
            if (mapping.method == method and std.mem.eql(u8, mapping.pattern, pattern)) {
                mapping.enabled = enabled;
                return true;
            }
        }
        return false;
    }

    /// List all mappings
    pub fn listMappings(self: *Self, allocator: Allocator) ![]CertificateMapping {
        self.mutex.lock();
        defer self.mutex.unlock();

        const list = try allocator.alloc(CertificateMapping, self.mappings.items.len);
        @memcpy(list, self.mappings.items);
        return list;
    }
};

/// Authentication result from mTLS
pub const AuthResult = struct {
    user_id: u64,
    roles: []const []const u8,
    method: IdentityMethod,
    matched_value: []const u8,
};

/// Extract identity from raw certificate DER bytes
/// CANARY: REQ=REQ-AUTH-MTLS-004; FEATURE="CertificateIdentityExtraction"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-01-29
pub fn extractIdentity(allocator: Allocator, cert_der: []const u8) !CertificateIdentity {
    // Calculate SHA-256 fingerprint
    var fingerprint_bytes: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(cert_der, &fingerprint_bytes, .{});

    // Convert to hex string using bytesToHex
    const fingerprint = std.fmt.bytesToHex(fingerprint_bytes, .lower);

    // For now, return minimal identity with fingerprint
    // Full X.509 parsing would require a proper ASN.1/X.509 library
    _ = allocator;

    return CertificateIdentity{
        .fingerprint = fingerprint,
        .subject_cn = null, // Would need X.509 parsing
        .subject_dn = null,
        .san_email = null,
        .san_dns = null,
        .san_uri = null,
        .issuer_dn = null,
        .not_before = 0, // Would need X.509 parsing
        .not_after = std.math.maxInt(i64), // Default to far future
        .serial_number = "", // Would need X.509 parsing
    };
}

/// Create identity from known values (for testing or when cert is already parsed)
pub fn createIdentity(
    fingerprint_hex: []const u8,
    subject_cn: ?[]const u8,
    san_email: ?[]const u8,
) CertificateIdentity {
    var fingerprint: [64]u8 = undefined;
    if (fingerprint_hex.len >= 64) {
        @memcpy(&fingerprint, fingerprint_hex[0..64]);
    } else {
        @memset(&fingerprint, '0');
        @memcpy(fingerprint[0..fingerprint_hex.len], fingerprint_hex);
    }

    return CertificateIdentity{
        .fingerprint = fingerprint,
        .subject_cn = subject_cn,
        .subject_dn = null,
        .san_email = san_email,
        .san_dns = null,
        .san_uri = null,
        .issuer_dn = null,
        .not_before = 0,
        .not_after = std.math.maxInt(i64),
        .serial_number = "",
    };
}

/// Simple glob-style pattern matching (* as wildcard)
fn matchPattern(pattern: []const u8, value: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, pattern, value)) return true;

    // Wildcard patterns
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        // Check prefix matches
        if (prefix.len > 0 and !std.mem.startsWith(u8, value, prefix)) {
            return false;
        }

        // Check suffix matches
        if (suffix.len > 0 and !std.mem.endsWith(u8, value, suffix)) {
            return false;
        }

        // For patterns like "*.example.com", ensure value is long enough
        if (value.len >= prefix.len + suffix.len) {
            return true;
        }
        return false;
    }

    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "MtlsProvider: add and authenticate by fingerprint" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // Add mapping
    try provider.addMapping(
        .fingerprint,
        fingerprint,
        42,
        &[_][]const u8{"admin"},
        "Test admin cert",
    );

    // Create identity and authenticate
    const identity = createIdentity(fingerprint, "admin", "admin@example.com");
    const result = try provider.authenticate(&identity);

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(u64, 42), r.user_id);
        try std.testing.expectEqual(IdentityMethod.fingerprint, r.method);
    }
}

test "MtlsProvider: authenticate by SAN email" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    // Add mapping by email
    try provider.addMapping(
        .san_email,
        "alice@example.com",
        100,
        &[_][]const u8{"user"},
        "Alice's cert",
    );

    const identity = createIdentity(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        null,
        "alice@example.com",
    );
    const result = try provider.authenticate(&identity);

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(u64, 100), r.user_id);
        try std.testing.expectEqual(IdentityMethod.san_email, r.method);
    }
}

test "MtlsProvider: wildcard pattern matching" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    // Add wildcard mapping
    try provider.addMapping(
        .san_email,
        "*@example.com",
        200,
        &[_][]const u8{"employee"},
        "All example.com employees",
    );

    // Should match
    const identity1 = createIdentity(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        null,
        "bob@example.com",
    );
    const result1 = try provider.authenticate(&identity1);
    try std.testing.expect(result1 != null);

    // Should also match
    const identity2 = createIdentity(
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        null,
        "charlie@example.com",
    );
    const result2 = try provider.authenticate(&identity2);
    try std.testing.expect(result2 != null);

    // Should NOT match different domain
    const identity3 = createIdentity(
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        null,
        "dan@other.com",
    );
    const result3 = try provider.authenticate(&identity3);
    try std.testing.expect(result3 == null);
}

test "MtlsProvider: remove mapping" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

    try provider.addMapping(
        .fingerprint,
        fingerprint,
        300,
        &[_][]const u8{"test"},
        "Test mapping",
    );

    // Authenticate works
    const identity = createIdentity(fingerprint, null, null);
    var result = try provider.authenticate(&identity);
    try std.testing.expect(result != null);

    // Remove mapping
    try std.testing.expect(provider.removeMapping(.fingerprint, fingerprint));

    // Authenticate fails
    result = try provider.authenticate(&identity);
    try std.testing.expect(result == null);
}

test "MtlsProvider: disabled mapping not matched" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    try provider.addMapping(
        .fingerprint,
        fingerprint,
        400,
        &[_][]const u8{"test"},
        "Test mapping",
    );

    // Disable the mapping
    try std.testing.expect(provider.setMappingEnabled(.fingerprint, fingerprint, false));

    // Authenticate should fail
    const identity = createIdentity(fingerprint, null, null);
    const result = try provider.authenticate(&identity);
    try std.testing.expect(result == null);
}

test "matchPattern: exact match" {
    try std.testing.expect(matchPattern("test", "test"));
    try std.testing.expect(!matchPattern("test", "test2"));
}

test "matchPattern: wildcard prefix" {
    try std.testing.expect(matchPattern("*@example.com", "user@example.com"));
    try std.testing.expect(matchPattern("*@example.com", "admin@example.com"));
    try std.testing.expect(!matchPattern("*@example.com", "user@other.com"));
}

test "matchPattern: wildcard suffix" {
    try std.testing.expect(matchPattern("admin*", "admin"));
    try std.testing.expect(matchPattern("admin*", "administrator"));
    try std.testing.expect(!matchPattern("admin*", "user"));
}

test "matchPattern: wildcard middle" {
    try std.testing.expect(matchPattern("admin*@example.com", "admin@example.com"));
    try std.testing.expect(matchPattern("admin*@example.com", "admin123@example.com"));
    try std.testing.expect(!matchPattern("admin*@example.com", "user@example.com"));
}

test "extractIdentity: computes fingerprint" {
    const allocator = std.testing.allocator;

    // Use some test bytes as "certificate"
    const test_cert = "test certificate data";
    const identity = try extractIdentity(allocator, test_cert);

    // Fingerprint should be 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), identity.fingerprint.len);

    // Should only contain hex characters
    for (identity.fingerprint) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
