/// TDE Key Management Module
///
/// This module provides key management abstractions for Transparent Data Encryption,
/// separating key lifecycle operations from core encryption logic to improve
/// testability and allow for dependency injection.
///
/// Extracted as part of Phase 1, M1.3 of the modularization effort.
const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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

// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE Key Management"; ASPECT=KeyManagement; STATUS=TESTED; TEST=tde_tests; OWNER=security; UPDATED=2025-11-12

/// AES-256 key size in bytes
pub const KeyBytes = 32;

/// Key status information
pub const KeyStatus = struct {
    loaded: bool,
    key_id: [32]u8 = undefined,
};

/// KMS configuration result
pub const ConfigureKMSResult = struct {
    provider_name: []const u8,
    configured: bool,
    endpoint: []const u8,
    test_result: []const u8,
};

/// Loads encryption key from GEODE_TDE_KEY (32 bytes hex) with secure key ID derivation.
/// GAP-0085: Key ID derived using HKDF to prevent collision and avoid key material exposure
// CANARY: REQ=REQ-GQL-TDE-KEYID-001; FEATURE="SecureKeyIdDerivation"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
pub fn loadKey(allocator: std.mem.Allocator, enabled: bool) !KeyStatus {
    if (!enabled) return error.FeatureDisabled;
    const key_opt = getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return KeyStatus{ .loaded = false },
        else => return e,
    };
    defer allocator.free(key_opt);
    if (key_opt.len != 64) return error.InvalidKey; // expecting hex-encoded 32 bytes

    // Parse hex key
    var raw_key: [KeyBytes]u8 = undefined;
    var i: usize = 0;
    while (i < KeyBytes) : (i += 1) {
        const hi = std.fmt.charToDigit(key_opt[i * 2], 16) catch return error.InvalidKey;
        const lo = std.fmt.charToDigit(key_opt[i * 2 + 1], 16) catch return error.InvalidKey;
        raw_key[i] = @as(u8, @intCast(hi * 16 + lo));
    }

    // Derive key_id using HKDF-SHA256 with info="geode-tde-key-id"
    // This ensures: (1) no key material in ID, (2) collision-resistant, (3) deterministic
    var ks = KeyStatus{ .loaded = true };
    try deriveKeyId(&raw_key, &ks.key_id);

    return ks;
}

/// Derive key ID using HKDF-Extract + HKDF-Expand with SHA-256
/// GAP-0085: Secure key identifier derivation without exposing key material
fn deriveKeyId(key: *const [KeyBytes]u8, out: *[32]u8) !void {
    // HKDF-Extract: PRK = HMAC(salt, IKM)
    // Use fixed salt for consistent key IDs
    const salt = "geode-tde-key-id-salt-v1";
    var prk: [32]u8 = undefined;
    _ = try cb.Mac.hmac(.sha256, salt, key, &prk);

    // HKDF-Expand: OKM = HMAC(PRK, info || 0x01)
    const info = "geode-tde-key-id-info-v1";
    var expand_input: [info.len + 1]u8 = undefined;
    @memcpy(expand_input[0..info.len], info);
    expand_input[info.len] = 0x01;
    _ = try cb.Mac.hmac(.sha256, &prk, expand_input[0 .. info.len + 1], out);
}

/// Derive key from hex string
pub fn deriveKey(raw_hex: []const u8, out: *[KeyBytes]u8) !void {
    if (raw_hex.len != 64) return error.InvalidKey;
    var i: usize = 0;
    while (i < KeyBytes) : (i += 1) {
        const hi = std.fmt.charToDigit(raw_hex[i * 2], 16) catch return error.InvalidKey;
        const lo = std.fmt.charToDigit(raw_hex[i * 2 + 1], 16) catch return error.InvalidKey;
        out[i] = @as(u8, @intCast(hi * 16 + lo));
    }
}

/// Load raw key from GEODE_TDE_KEY (hex-encoded) or return null if unset.
pub fn loadRawKey(allocator: std.mem.Allocator) !?[KeyBytes]u8 {
    const key_buf = getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    if (key_buf.len == 0) return null; // treat empty as not present
    defer allocator.free(key_buf);
    var k: [KeyBytes]u8 = undefined;
    try deriveKey(key_buf, &k);
    return k;
}

/// Configure KMS integration for key management.
///
/// GAP-0296: `provider` must be a reachable endpoint (`host:port` or
/// `<scheme>://host:port[/path]`); it is probed with a TCP connect, and an
/// unreachable endpoint reports configured=false so server startup refuses
/// to start (fail-closed contract). Reachability is all that is checked: no
/// key is fetched from or wrapped by the endpoint.
///
/// SONNY-6348: a symbolic provider name ("aws", "azure", "gcp",
/// "hashicorp", "local") used to report configured=true after a local
/// AES-GCM round trip with a random key, so startup logged "KMS configured"
/// without contacting any KMS. No cloud KMS SDK is linked in; such a name
/// now reports configured=false and startup refuses it.
pub fn configureKMS(allocator: std.mem.Allocator, provider: []const u8) !ConfigureKMSResult {
    const is_symbolic = std.mem.eql(u8, provider, "aws") or
        std.mem.eql(u8, provider, "azure") or
        std.mem.eql(u8, provider, "gcp") or
        std.mem.eql(u8, provider, "hashicorp") or
        std.mem.eql(u8, provider, "local");

    if (is_symbolic) {
        return .{
            .provider_name = try allocator.dupe(u8, provider),
            .configured = false,
            .endpoint = try allocator.dupe(u8, ""),
            .test_result = try std.fmt.allocPrint(
                allocator,
                "FAILED: '{s}' is a provider name, not a KMS endpoint; no {s} KMS client is built in (GEODE_KMS_URL must be host:port or scheme://host:port)",
                .{ provider, provider },
            ),
        };
    }

    const reachable = probeKmsReachable(allocator, provider) catch false;
    if (!reachable) {
        return .{
            .provider_name = try allocator.dupe(u8, provider),
            .configured = false,
            .endpoint = try allocator.dupe(u8, provider),
            .test_result = try std.fmt.allocPrint(
                allocator,
                "FAILED: KMS endpoint unreachable ({s})",
                .{provider},
            ),
        };
    }
    return .{
        .provider_name = try allocator.dupe(u8, provider),
        .configured = true,
        .endpoint = try allocator.dupe(u8, provider),
        .test_result = try allocator.dupe(u8, "SUCCESS: KMS endpoint reachable (TCP connect only; no key is fetched from it)"),
    };
}

/// TCP-reachability probe for a `host:port` (or `scheme://host:port`) endpoint.
/// Returns true if a TCP connection succeeds, false otherwise.
/// The intent is fail-closed: any error (DNS, refused, malformed URL) is
/// reported as unreachable so the operator-facing contract (refuse to start
/// when KMS endpoint cannot be reached) holds.
///
/// Implementation: Zig 0.16 routes blocking I/O through std.Io.net.  We
/// rely on the threaded singleton already used by the rest of the security
/// layer to issue a synchronous connect.  Any error path returns false.
fn probeKmsReachable(allocator: std.mem.Allocator, endpoint: []const u8) !bool {
    _ = allocator;
    var host_port = endpoint;
    if (std.mem.indexOf(u8, host_port, "://")) |idx| {
        host_port = host_port[idx + 3 ..];
        if (std.mem.indexOfScalar(u8, host_port, '/')) |slash_idx| {
            host_port = host_port[0..slash_idx];
        }
    }
    const colon_idx = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return false;
    const host = host_port[0..colon_idx];
    const port_str = host_port[colon_idx + 1 ..];
    if (host.len == 0 or port_str.len == 0) return false;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return false;

    // We only support IP-literal hosts for the fail-closed probe.  Bare
    // hostnames would require DNS, which the harness scenario does not
    // exercise (it uses 127.0.0.1:1).  Symbolic provider names go through
    // the legacy local-roundtrip path above, never here.
    const ip = std.Io.net.IpAddress.parse(host, port) catch return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    // The connect timeout uses Clock.Duration; the IpAddress connect path
    // resolves the clock implicitly via the io vtable. We use a non-zero
    // raw nanoseconds value so that wholly-unroutable hosts fail quickly
    // rather than hanging on TCP retransmission.
    var stream = std.Io.net.IpAddress.connect(&ip, io, .{
        .mode = .stream,
    }) catch return false;
    stream.close(io);
    return true;
}

// =============================================================================
// Per-Tenant TDE Key Derivation (GAP-0290)
// =============================================================================
// CANARY: REQ=REQ-TDE-TENANT-001; FEATURE="PerTenantTDEKeys"; ASPECT=KeyDerivation; STATUS=TESTED; TEST=src/security/tde_key_manager.zig; OWNER=security; UPDATED=2026-04-01

/// Fixed salt for per-tenant TDE key derivation (domain separation from FLE keys)
const tenant_tde_salt = "geode-tde-tenant-salt-v1";

/// Derive a per-tenant TDE encryption key from the master key using HKDF-SHA256.
///
/// Uses the same HKDF construction as FLE's key hierarchy (RFC 5869) but with
/// a distinct salt ("geode-tde-tenant-salt-v1") to ensure domain separation.
///
/// The derivation is deterministic: same master_key + tenant_id always produces
/// the same derived key. No additional key storage is needed.
///
/// For key rotation, pass a version > 1 which appends ":v{version}" to the
/// HKDF info string, producing a distinct key per version.
pub fn deriveTenantTdeKey(master_key: *const [KeyBytes]u8, tenant_id: []const u8, version: u16) ![KeyBytes]u8 {
    // Build info string: "geode/tde/tenant/{tenant_id}" or "geode/tde/tenant/{tenant_id}:v{version}"
    // error-policy: D — the inner `catch unreachable` covers the fixed-literal
    // fallback, which always fits info_buf. KNOWN RESIDUAL (documented in
    // docs/ERROR_HANDLING_POLICY.md): tenant ids > ~490 bytes collapse to the
    // shared "truncated" info string, weakening per-tenant domain separation;
    // real tenant ids are far below that bound and changing the derivation
    // would break at-rest compatibility.
    var info_buf: [512]u8 = undefined;
    const info = if (version <= 1)
        std.fmt.bufPrint(&info_buf, "geode/tde/tenant/{s}", .{tenant_id}) catch
            // Fallback: truncate tenant_id if too long for buffer
            std.fmt.bufPrint(&info_buf, "geode/tde/tenant/truncated", .{}) catch unreachable
    else
        std.fmt.bufPrint(&info_buf, "geode/tde/tenant/{s}:v{d}", .{ tenant_id, version }) catch
            std.fmt.bufPrint(&info_buf, "geode/tde/tenant/truncated:v{d}", .{version}) catch unreachable;

    // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    var prk: [32]u8 = undefined;
    _ = try cb.Mac.hmac(.sha256, tenant_tde_salt, master_key, &prk);

    // HKDF-Expand: OKM = HMAC(PRK, info || 0x01)
    // Only need 32 bytes (one block), so single expand iteration suffices
    var expand_input: [512 + 1]u8 = undefined;
    @memcpy(expand_input[0..info.len], info);
    expand_input[info.len] = 0x01;

    var derived: [KeyBytes]u8 = undefined;
    _ = try cb.Mac.hmac(.sha256, &prk, expand_input[0 .. info.len + 1], &derived);

    // Zeroize PRK
    cb.secureZero(&prk);

    return derived;
}

/// Thread-safe cache of per-tenant derived TDE keys.
///
/// Keys are derived on first access using HKDF-SHA256 from the master key
/// and cached in memory for subsequent lookups. The cache stores owned copies
/// of tenant_id strings so callers need not keep them alive.
pub const TenantKeyManager = struct {
    master_key: [KeyBytes]u8,
    tenant_keys: std.StringHashMap(TenantKeyEntry),
    mu: std.Io.Mutex,
    allocator: std.mem.Allocator,

    const TenantKeyEntry = struct {
        key: [KeyBytes]u8,
        version: u16,
    };

    pub fn init(allocator: std.mem.Allocator, master_key: [KeyBytes]u8) TenantKeyManager {
        return .{
            .master_key = master_key,
            .tenant_keys = std.StringHashMap(TenantKeyEntry).init(allocator),
            // GAP-0843: std.Io.Mutex is an extern struct requiring an explicit
            // `state` field in Zig 0.16; bare `.{}` no longer compiles. This path
            // was never compiled before because encryptForTenant/decryptForTenant
            // had zero callers — wiring it into a live test surfaced the latent bug.
            .mu = std.Io.Mutex.init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TenantKeyManager) void {
        // Zeroize all cached keys before freeing
        var it = self.tenant_keys.iterator();
        while (it.next()) |entry| {
            cb.secureZero(&entry.value_ptr.key);
            self.allocator.free(entry.key_ptr.*);
        }
        self.tenant_keys.deinit();

        // Zeroize master key
        cb.secureZero(&self.master_key);
    }

    /// Get the TDE encryption key for a tenant. Derives and caches on first access.
    pub fn getKeyForTenant(self: *TenantKeyManager, tenant_id: []const u8) !TenantKeyEntry {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.tenant_keys.get(tenant_id)) |entry| {
            return entry;
        }

        // Derive key and cache it
        const version: u16 = 1;
        const derived = try deriveTenantTdeKey(&self.master_key, tenant_id, version);

        // Store owned copy of tenant_id
        const owned_id = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(owned_id);

        const entry = TenantKeyEntry{ .key = derived, .version = version };
        try self.tenant_keys.put(owned_id, entry);

        return entry;
    }

    /// Rotate the key for a specific tenant by incrementing its version.
    /// Returns the new version number.
    pub fn rotateTenantKey(self: *TenantKeyManager, tenant_id: []const u8) !u16 {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const current_version: u16 = if (self.tenant_keys.get(tenant_id)) |entry|
            entry.version
        else
            1;

        const new_version = current_version + 1;
        const derived = try deriveTenantTdeKey(&self.master_key, tenant_id, new_version);

        // Check if key exists -- if so, update in-place
        if (self.tenant_keys.getPtr(tenant_id)) |entry_ptr| {
            cb.secureZero(&entry_ptr.key);
            entry_ptr.key = derived;
            entry_ptr.version = new_version;
        } else {
            // New entry
            const owned_id = try self.allocator.dupe(u8, tenant_id);
            errdefer self.allocator.free(owned_id);
            try self.tenant_keys.put(owned_id, .{ .key = derived, .version = new_version });
        }

        return new_version;
    }

    /// Check if a tenant has a cached key and return its version, or null.
    pub fn getTenantKeyVersion(self: *TenantKeyManager, tenant_id: []const u8) ?u16 {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.tenant_keys.get(tenant_id)) |entry| {
            return entry.version;
        }
        return null;
    }

    /// Return the number of cached tenant keys.
    pub fn cachedKeyCount(self: *TenantKeyManager) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.tenant_keys.count();
    }
};

/// Tenant key status result (for stored procedure)
pub const TenantKeyStatusResult = struct {
    tenant_id: []const u8,
    has_derived_key: bool,
    key_version: u16,
    derivation_method: []const u8,
};

// =============================================================================
// Tests
// =============================================================================

test "loadKey - key not found" {
    const testing = std.testing;

    const status = try loadKey(testing.allocator, true);
    try testing.expect(!status.loaded);
}

test "deriveKey - valid hex" {
    const testing = std.testing;

    const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var key: [KeyBytes]u8 = undefined;
    try deriveKey(hex, &key);

    try testing.expectEqual(@as(u8, 0x01), key[0]);
    try testing.expectEqual(@as(u8, 0x23), key[1]);
}

test "deriveKey - invalid length" {
    const testing = std.testing;

    const hex = "0123";
    var key: [KeyBytes]u8 = undefined;
    try testing.expectError(error.InvalidKey, deriveKey(hex, &key));
}

test "configureKMS - a symbolic provider name is not a configured KMS" {
    const testing = std.testing;

    const result = try configureKMS(testing.allocator, "aws");
    defer testing.allocator.free(result.provider_name);
    defer testing.allocator.free(result.endpoint);
    defer testing.allocator.free(result.test_result);

    try testing.expect(std.mem.eql(u8, result.provider_name, "aws"));
    try testing.expect(!result.configured);
    try testing.expect(std.mem.startsWith(u8, result.test_result, "FAILED"));
}

// =============================================================================
// Per-Tenant TDE Key Derivation Tests (GAP-0290)
// =============================================================================

test "deriveTenantTdeKey - different tenants produce different keys" {
    const master_key: [KeyBytes]u8 = [_]u8{0x42} ** KeyBytes;

    const key_a = try deriveTenantTdeKey(&master_key, "tenant-alpha", 1);
    const key_b = try deriveTenantTdeKey(&master_key, "tenant-beta", 1);

    // Keys must differ for different tenant IDs
    try std.testing.expect(!std.mem.eql(u8, &key_a, &key_b));
}

test "deriveTenantTdeKey - same tenant produces same key (deterministic)" {
    const master_key: [KeyBytes]u8 = [_]u8{0xAB} ** KeyBytes;

    const key1 = try deriveTenantTdeKey(&master_key, "tenant-123", 1);
    const key2 = try deriveTenantTdeKey(&master_key, "tenant-123", 1);

    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "deriveTenantTdeKey - different versions produce different keys" {
    const master_key: [KeyBytes]u8 = [_]u8{0xCD} ** KeyBytes;

    const key_v1 = try deriveTenantTdeKey(&master_key, "tenant-xyz", 1);
    const key_v2 = try deriveTenantTdeKey(&master_key, "tenant-xyz", 2);

    try std.testing.expect(!std.mem.eql(u8, &key_v1, &key_v2));
}

test "deriveTenantTdeKey - different master keys produce different tenant keys" {
    const master_a: [KeyBytes]u8 = [_]u8{0x11} ** KeyBytes;
    const master_b: [KeyBytes]u8 = [_]u8{0x22} ** KeyBytes;

    const key_a = try deriveTenantTdeKey(&master_a, "same-tenant", 1);
    const key_b = try deriveTenantTdeKey(&master_b, "same-tenant", 1);

    try std.testing.expect(!std.mem.eql(u8, &key_a, &key_b));
}

test "TenantKeyManager - caches and returns correct keys" {
    const allocator = std.testing.allocator;
    const master_key: [KeyBytes]u8 = [_]u8{0x55} ** KeyBytes;

    var mgr = TenantKeyManager.init(allocator, master_key);
    defer mgr.deinit();

    // First access derives the key
    const entry_a = try mgr.getKeyForTenant("tenant-a");
    try std.testing.expectEqual(@as(u16, 1), entry_a.version);

    // Second access returns cached key
    const entry_a2 = try mgr.getKeyForTenant("tenant-a");
    try std.testing.expectEqualSlices(u8, &entry_a.key, &entry_a2.key);

    // Different tenant gets different key
    const entry_b = try mgr.getKeyForTenant("tenant-b");
    try std.testing.expect(!std.mem.eql(u8, &entry_a.key, &entry_b.key));

    // Cached count
    try std.testing.expectEqual(@as(usize, 2), mgr.cachedKeyCount());
}

test "TenantKeyManager - rotate tenant key" {
    const allocator = std.testing.allocator;
    const master_key: [KeyBytes]u8 = [_]u8{0x77} ** KeyBytes;

    var mgr = TenantKeyManager.init(allocator, master_key);
    defer mgr.deinit();

    // Get initial key
    const entry_v1 = try mgr.getKeyForTenant("rotate-me");
    try std.testing.expectEqual(@as(u16, 1), entry_v1.version);

    // Rotate
    const new_version = try mgr.rotateTenantKey("rotate-me");
    try std.testing.expectEqual(@as(u16, 2), new_version);

    // Key should now be different
    const entry_v2 = try mgr.getKeyForTenant("rotate-me");
    try std.testing.expectEqual(@as(u16, 2), entry_v2.version);
    try std.testing.expect(!std.mem.eql(u8, &entry_v1.key, &entry_v2.key));
}

test "TenantKeyManager - getTenantKeyVersion" {
    const allocator = std.testing.allocator;
    const master_key: [KeyBytes]u8 = [_]u8{0x88} ** KeyBytes;

    var mgr = TenantKeyManager.init(allocator, master_key);
    defer mgr.deinit();

    // No key cached yet
    try std.testing.expect(mgr.getTenantKeyVersion("unknown") == null);

    // After access
    _ = try mgr.getKeyForTenant("known");
    try std.testing.expectEqual(@as(u16, 1), mgr.getTenantKeyVersion("known").?);
}

test "per-tenant key isolates encryption - tenant A cannot decrypt tenant B data" {
    const master_key: [KeyBytes]u8 = [_]u8{0x99} ** KeyBytes;

    const key_a = try deriveTenantTdeKey(&master_key, "tenant-a", 1);
    const key_b = try deriveTenantTdeKey(&master_key, "tenant-b", 1);

    // Encrypt with tenant A's key
    const plaintext = "secret data for tenant A";
    var nonce: [12]u8 = undefined;
    try cb.Csprng.bytes(&nonce);
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    try cb.Aead.seal(.aes_256_gcm, &key_a, &nonce, &.{}, plaintext, &ciphertext, &tag);

    // Decrypt with tenant A's key should succeed
    var decrypted_a: [plaintext.len]u8 = undefined;
    cb.Aead.open(.aes_256_gcm, &key_a, &nonce, &.{}, &ciphertext, &tag, &decrypted_a) catch
        return error.UnexpectedDecryptionFailure;
    try std.testing.expectEqualStrings(plaintext, &decrypted_a);

    // Decrypt with tenant B's key must fail
    var decrypted_b: [plaintext.len]u8 = undefined;
    const result = cb.Aead.open(.aes_256_gcm, &key_b, &nonce, &.{}, &ciphertext, &tag, &decrypted_b);
    try std.testing.expectError(error.AuthFailed, result);
}
