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
const flags_mod = @import("feature_flags");
const key_manager = @import("tde_key_manager.zig");
const nonce_gen = @import("tde_nonce_gen.zig");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// Transparent Data Encryption (TDE) minimal AES-256-GCM implementation.
// Runtime gated by GEODE_ENABLE_TDE.
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE baseline"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/e2e_security_tde_mfa.zig:1; OWNER=security; UPDATED=2026-11-12

pub const KeyStatus = key_manager.KeyStatus;

fn flag() *flags_mod.Flag {
    return &flags_mod.global().tde;
}
fn enabled() bool {
    return flag().enabled();
}

// Loads encryption key from GEODE_TDE_KEY (32 bytes hex) - placeholder validation only.
pub fn loadKey(allocator: std.mem.Allocator) !KeyStatus {
    return key_manager.loadKey(allocator, enabled());
}

// AES-256-GCM parameters
pub const KeyBytes = key_manager.KeyBytes;
pub const TagBytes = 16;
pub const NonceBytes = nonce_gen.NonceBytes;

pub const Ciphertext = struct {
    nonce: [NonceBytes]u8,
    tag: [TagBytes]u8,
    data: []u8, // encrypted payload
};

fn loadRawKey(allocator: std.mem.Allocator) !?[KeyBytes]u8 {
    return key_manager.loadRawKey(allocator);
}

pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8) !Ciphertext {
    if (!enabled()) return error.FeatureDisabled;
    const key_opt = try loadRawKey(allocator);
    if (key_opt == null) return error.KeyNotLoaded;
    const key = key_opt.?;

    // CRITICAL SECURITY: Use cryptographically secure random nonce
    // NIST SP 800-38D requires unique nonces for AES-GCM security
    // Deterministic nonces would allow catastrophic IV reuse attacks
    var nonce: [NonceBytes]u8 = undefined;
    try nonce_gen.generateSecureNonce(&nonce);

    const out_buf = try allocator.alloc(u8, plaintext.len);
    var tag: [TagBytes]u8 = undefined;
    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, aad, plaintext, out_buf, &tag);
    return .{ .nonce = nonce, .tag = tag, .data = out_buf };
}

pub fn decrypt(allocator: std.mem.Allocator, ct: Ciphertext, aad: []const u8) ![]u8 {
    if (!enabled()) return error.FeatureDisabled;
    const key_opt = try loadRawKey(allocator);
    if (key_opt == null) return error.KeyNotLoaded;
    const key = key_opt.?;
    const out = try allocator.alloc(u8, ct.data.len);
    var tag = ct.tag;
    var nonce = ct.nonce;
    cb.Aead.open(.aes_256_gcm, &key, &nonce, aad, ct.data, &tag, out) catch |e| {
        allocator.free(out);
        return e;
    };
    return out;
}

// GAP-0881: status() must reflect actual key material, not just the feature
// flag. It performs a real key-manager load: enabled + missing/invalid
// GEODE_TDE_KEY reports loaded=false; a valid key reports loaded=true with
// the HKDF-derived key fingerprint (never key material — see deriveKeyId in
// tde_key_manager.zig). Uses a small stack buffer since the env read only
// needs ~80 bytes and status() must stay allocator-free for callers.
pub fn status() KeyStatus {
    const not_loaded = KeyStatus{ .loaded = false, .key_id = [_]u8{0} ** 32 };
    if (!enabled()) return not_loaded;
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ks = key_manager.loadKey(fba.allocator(), true) catch return not_loaded;
    if (!ks.loaded) return not_loaded;
    return ks;
}

// Phase 6: TDE Core Functions

/// Configure KMS integration for key management
pub fn configureKMS(allocator: std.mem.Allocator, provider: []const u8) !key_manager.ConfigureKMSResult {
    return key_manager.configureKMS(allocator, provider);
}

// Phase 7: TDE Advanced Functions

// =============================================================================
// Per-Tenant TDE Encryption (GAP-0290)
// =============================================================================
// CANARY: REQ=REQ-TDE-TENANT-002; FEATURE="PerTenantTDEKeys"; ASPECT=EncryptDecrypt; STATUS=TESTED; TEST=src/security/tde_key_manager.zig; OWNER=security; UPDATED=2026-04-01

/// Global TenantKeyManager instance, lazily initialized from master key.
var global_tenant_key_mgr: ?key_manager.TenantKeyManager = null;
var tenant_key_mgr_mu: std.Io.Mutex = std.Io.Mutex.init;

/// Get or initialize the global TenantKeyManager.
/// Thread-safe: uses a mutex to prevent double-init.
fn getOrInitTenantKeyManager(allocator: std.mem.Allocator) !*key_manager.TenantKeyManager {
    tenant_key_mgr_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer tenant_key_mgr_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_tenant_key_mgr != null) {
        return &global_tenant_key_mgr.?;
    }

    const master_key = try loadRawKey(allocator) orelse return error.KeyNotLoaded;
    global_tenant_key_mgr = key_manager.TenantKeyManager.init(allocator, master_key);
    return &global_tenant_key_mgr.?;
}

/// Encrypt data using a per-tenant derived key.
///
/// Derives a unique AES-256-GCM key for the given tenant_id via HKDF-SHA256
/// from the master TDE key. The derived key is cached for subsequent operations.
///
/// If tenant_id is empty, falls back to the master key (backwards compatible).
pub fn encryptForTenant(allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8, tenant_id: []const u8) !Ciphertext {
    if (!enabled()) return error.FeatureDisabled;

    // Empty tenant_id means use master key directly (backwards compatible)
    if (tenant_id.len == 0) {
        return encrypt(allocator, plaintext, aad);
    }

    var mgr = try getOrInitTenantKeyManager(allocator);
    const entry = try mgr.getKeyForTenant(tenant_id);

    var nonce: [NonceBytes]u8 = undefined;
    try nonce_gen.generateSecureNonce(&nonce);

    const out_buf = try allocator.alloc(u8, plaintext.len);
    var tag: [TagBytes]u8 = undefined;
    try cb.Aead.seal(.aes_256_gcm, &entry.key, &nonce, aad, plaintext, out_buf, &tag);
    return .{ .nonce = nonce, .tag = tag, .data = out_buf };
}

/// Decrypt data using a per-tenant derived key.
///
/// Uses the same HKDF derivation as encryptForTenant. Data encrypted under
/// one tenant's key cannot be decrypted with another tenant's key.
pub fn decryptForTenant(allocator: std.mem.Allocator, ct: Ciphertext, aad: []const u8, tenant_id: []const u8) ![]u8 {
    if (!enabled()) return error.FeatureDisabled;

    if (tenant_id.len == 0) {
        return decrypt(allocator, ct, aad);
    }

    var mgr = try getOrInitTenantKeyManager(allocator);
    const entry = try mgr.getKeyForTenant(tenant_id);

    const out = try allocator.alloc(u8, ct.data.len);
    var tag2 = ct.tag;
    var nonce2 = ct.nonce;
    cb.Aead.open(.aes_256_gcm, &entry.key, &nonce2, aad, ct.data, &tag2, out) catch |e| {
        allocator.free(out);
        return e;
    };
    return out;
}

/// Get the key status for a specific tenant (for stored procedure).
pub fn getTenantKeyStatus(allocator: std.mem.Allocator, tenant_id: []const u8) !key_manager.TenantKeyStatusResult {
    if (!enabled()) return error.FeatureDisabled;

    var mgr = try getOrInitTenantKeyManager(allocator);
    const version = mgr.getTenantKeyVersion(tenant_id);

    return .{
        .tenant_id = try allocator.dupe(u8, tenant_id),
        .has_derived_key = version != null,
        .key_version = version orelse 0,
        .derivation_method = try allocator.dupe(u8, "HKDF-SHA256"),
    };
}

/// Rotate the TDE key for a specific tenant (for stored procedure).
/// Returns the new version number.
pub fn rotateTenantKey(allocator: std.mem.Allocator, tenant_id: []const u8) !u16 {
    if (!enabled()) return error.FeatureDisabled;

    var mgr = try getOrInitTenantKeyManager(allocator);
    return mgr.rotateTenantKey(tenant_id);
}

/// Deinitialize the global tenant key manager (cleanup on shutdown).
pub fn deinitTenantKeyManager() void {
    tenant_key_mgr_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer tenant_key_mgr_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_tenant_key_mgr) |*mgr| {
        mgr.deinit();
        global_tenant_key_mgr = null;
    }
}

/// Shamir's Secret Sharing over GF(256) using irreducible polynomial x^8 + x^4 + x^3 + x + 1
/// GAP-0070: Proper polynomial-based threshold secret sharing
// CANARY: REQ=REQ-GQL-TDE-SSS-001; FEATURE="ShamirSecretSharing"; ASPECT=KeyEscrow; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
const ShamirSSS = struct {
    /// GF(256) multiplication using Russian peasant algorithm
    fn gf256Mul(a: u8, b: u8) u8 {
        var p: u8 = 0;
        var aa = a;
        var bb = b;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if ((bb & 1) != 0) p ^= aa;
            const hi_bit = aa & 0x80;
            aa <<= 1;
            if (hi_bit != 0) aa ^= 0x1B; // x^8 + x^4 + x^3 + x + 1
            bb >>= 1;
        }
        return p;
    }

    /// GF(256) modular inverse using extended Euclidean algorithm
    fn gf256Inv(a: u8) u8 {
        if (a == 0) return 0;
        var t: u8 = 0;
        var newt: u8 = 1;
        var r: u16 = 0x11B; // x^8 + x^4 + x^3 + x + 1
        var newr: u16 = a;

        while (newr != 0) {
            const quotient = @divTrunc(r, newr);
            const temp_t = t;
            t = newt;
            newt = temp_t ^ @as(u8, @truncate(quotient *% newt));
            const temp_r = r;
            r = newr;
            newr = temp_r ^ (quotient * newr);
        }
        return t;
    }

    /// GF(256) division
    fn gf256Div(a: u8, b: u8) u8 {
        return gf256Mul(a, gf256Inv(b));
    }

    /// Evaluate polynomial at x using Horner's method in GF(256)
    fn evalPolynomial(coeffs: []const u8, x: u8) u8 {
        var result: u8 = 0;
        var i: usize = coeffs.len;
        while (i > 0) : (i -= 1) {
            result = gf256Mul(result, x) ^ coeffs[i - 1];
        }
        return result;
    }

    /// Create n shares with threshold k for a single byte
    fn createSharesByte(secret_byte: u8, k: usize, n: usize, coeffs: []u8, shares_out: []u8) void {
        // coeffs[0] = secret, coeffs[1..k] = random coefficients
        coeffs[0] = secret_byte;

        // Evaluate polynomial at x = 1, 2, ..., n
        for (0..n) |i| {
            const x: u8 = @intCast(i + 1);
            shares_out[i] = evalPolynomial(coeffs[0..k], x);
        }
    }

    /// Lagrange interpolation to recover secret at x=0
    fn recoverByte(xs: []const u8, ys: []const u8, k: usize) u8 {
        var secret: u8 = 0;
        for (0..k) |i| {
            var num: u8 = 1;
            var den: u8 = 1;
            for (0..k) |j| {
                if (i != j) {
                    num = gf256Mul(num, xs[j]); // (0 - x_j) = x_j in GF(256)
                    den = gf256Mul(den, xs[i] ^ xs[j]); // (x_i - x_j)
                }
            }
            const lagrange = gf256Div(num, den);
            secret ^= gf256Mul(ys[i], lagrange);
        }
        return secret;
    }
};

/// Test key escrow and recovery mechanisms using proper Shamir's Secret Sharing
/// GAP-0070: Implements polynomial interpolation over GF(256)
pub fn testKeyEscrow(allocator: std.mem.Allocator) !struct {
    escrow_successful: bool,
    recovery_tested: bool,
    shares_created: u32,
    threshold: u32,
} {
    // Master key to escrow
    const secret: [32]u8 = [_]u8{0x42} ** 32;
    const total_shares: u32 = 5;
    const threshold: u32 = 3;

    // Create shares using proper Shamir's Secret Sharing
    var shares = try allocator.alloc([33]u8, total_shares);
    defer allocator.free(shares);

    // Temporary storage for polynomial coefficients
    var coeffs: [3]u8 = undefined; // threshold coefficients

    // Generate shares for each byte of the secret
    for (0..32) |byte_idx| {
        // Random coefficients for polynomial (coeffs[0] will be set to secret byte)
        try cb.Csprng.bytes(coeffs[1..threshold]);

        // Create share values for this byte
        var share_bytes: [5]u8 = undefined;
        ShamirSSS.createSharesByte(secret[byte_idx], threshold, total_shares, &coeffs, &share_bytes);

        // Store in shares array
        for (0..total_shares) |share_idx| {
            if (byte_idx == 0) {
                shares[share_idx][0] = @intCast(share_idx + 1); // Share ID (x-coordinate)
            }
            shares[share_idx][byte_idx + 1] = share_bytes[share_idx];
        }
    }

    // Test recovery with any 'threshold' shares (use shares 0, 2, 4 to prove any subset works)
    var recovered: [32]u8 = undefined;
    const selected_indices = [_]usize{ 0, 2, 4 }; // Any k shares should work

    // Recover each byte
    for (0..32) |byte_idx| {
        var xs: [3]u8 = undefined;
        var ys: [3]u8 = undefined;
        for (0..threshold) |i| {
            xs[i] = shares[selected_indices[i]][0]; // x-coordinate (share ID)
            ys[i] = shares[selected_indices[i]][byte_idx + 1]; // y-coordinate (share value)
        }
        recovered[byte_idx] = ShamirSSS.recoverByte(&xs, &ys, threshold);
    }

    // Verify recovery
    const recovery_successful = std.mem.eql(u8, &recovered, &secret);

    return .{
        .escrow_successful = true,
        .recovery_tested = recovery_successful,
        .shares_created = total_shares,
        .threshold = threshold,
    };
}

/// Test transparent encryption with various data types
pub fn testTransparentEncryption(allocator: std.mem.Allocator) !struct {
    types_tested: u32,
    all_transparent: bool,
    performance_impact_pct: f64,
    errors_encountered: u32,
} {
    if (!enabled()) return error.FeatureDisabled;

    var types_tested: u32 = 0;
    var errors: u32 = 0;

    // Test different data types
    const test_types = [_]struct { name: []const u8, size: usize }{
        .{ .name = "INTEGER", .size = 8 },
        .{ .name = "VARCHAR", .size = 255 },
        .{ .name = "BLOB", .size = 4096 },
        .{ .name = "TIMESTAMP", .size = 8 },
        .{ .name = "VECTOR", .size = 512 },
    };

    // SONNY-6342: the impact is measured against the same buffers copied
    // without encryption (it was measured against an invented 1000 us).
    const copy_start = compat_microTimestamp();
    for (test_types) |test_type| {
        const data = try allocator.alloc(u8, test_type.size);
        defer allocator.free(data);
        // fips-exempt: non-security test-plaintext fill
        compat_fillRandom(data);
        const copy = try allocator.dupe(u8, data);
        allocator.free(copy);
    }
    const copy_time: u64 = @intCast(@max(compat_microTimestamp() - copy_start, 1));

    const baseline_time = compat_microTimestamp();

    for (test_types) |test_type| {
        const data = try allocator.alloc(u8, test_type.size);
        defer allocator.free(data);
        // fips-exempt: non-security test-plaintext fill
        compat_fillRandom(data);

        // Encrypt transparently
        const encrypted = encrypt(allocator, data, test_type.name) catch {
            errors += 1;
            continue;
        };
        defer allocator.free(encrypted.data);

        // Decrypt transparently
        const decrypted = decrypt(allocator, encrypted, test_type.name) catch {
            errors += 1;
            continue;
        };
        defer allocator.free(decrypted);

        // Verify transparency
        if (!std.mem.eql(u8, data, decrypted)) {
            errors += 1;
        }

        types_tested += 1;
    }

    const elapsed_time: u64 = @intCast(@max(compat_microTimestamp() - baseline_time, 0));
    const performance_impact = (@as(f64, @floatFromInt(elapsed_time)) / @as(f64, @floatFromInt(copy_time)) - 1.0) * 100.0;

    return .{
        .types_tested = types_tested,
        .all_transparent = errors == 0,
        .performance_impact_pct = performance_impact,
        .errors_encountered = errors,
    };
}

// ========== TDE TEST PROCEDURES - REAL IMPLEMENTATIONS ==========
// CANARY: REQ=REQ-TDE-TEST-IMPL; FEATURE="TDETestImplementations"; ASPECT=RealFunctionality; STATUS=EXEMPT; OWNER=tde; UPDATED=2025-11-12

/// Test block-level encryption
pub fn encryptPageTest(allocator: std.mem.Allocator) !struct {
    page_id: i64,
    encryption_status: []const u8,
    page_size_encrypted: i64,
    integrity_check: bool,
} {
    // Create actual page data
    const page_size: usize = 8192;
    const page_data = try allocator.alloc(u8, page_size);
    defer allocator.free(page_data);
    // fips-exempt: non-security test-plaintext fill
    compat_fillRandom(page_data);

    // Actually encrypt the page
    const encrypted = try encrypt(allocator, page_data, "page_encryption");
    defer allocator.free(encrypted.data);

    // Verify decryption works
    const decrypted = try decrypt(allocator, encrypted, "page_encryption");
    defer allocator.free(decrypted);

    const integrity_ok = std.mem.eql(u8, page_data, decrypted);

    return .{
        .page_id = 1,
        .encryption_status = try allocator.dupe(u8, if (integrity_ok) "encrypted" else "failed"),
        .page_size_encrypted = @intCast(encrypted.data.len),
        .integrity_check = integrity_ok,
    };
}

/// Test backup payload encryption
pub fn encryptBackupTest(allocator: std.mem.Allocator) !struct {
    backup_id: i64,
    encryption_status: []const u8,
    backup_size: i64,
    integrity_verified: bool,
} {
    // Create actual backup payload data (reduced from 16MB to 64KB for test performance)
    const backup_size: usize = 65536; // 64KB
    const backup_data = try allocator.alloc(u8, backup_size);
    defer allocator.free(backup_data);
    // fips-exempt: non-security test-plaintext fill
    compat_fillRandom(backup_data);

    // Actually encrypt the backup payload
    const encrypted = try encrypt(allocator, backup_data, "backup_encryption");
    defer allocator.free(encrypted.data);

    // Verify decryption works
    const decrypted = try decrypt(allocator, encrypted, "backup_encryption");
    defer allocator.free(decrypted);

    const integrity_ok = std.mem.eql(u8, backup_data, decrypted);

    return .{
        .backup_id = 1,
        .encryption_status = try allocator.dupe(u8, if (integrity_ok) "encrypted" else "failed"),
        .backup_size = @intCast(encrypted.data.len),
        .integrity_verified = integrity_ok,
    };
}

/// Test encryption/decryption roundtrip
pub fn roundtripTest(allocator: std.mem.Allocator, test_data: []const u8) !struct {
    original_data: []const u8,
    decrypted_data: []const u8,
    roundtrip_success: bool,
} {
    // Actually encrypt the data
    const encrypted = try encrypt(allocator, test_data, "roundtrip_test");
    defer allocator.free(encrypted.data);

    // Actually decrypt the data
    const decrypted = try decrypt(allocator, encrypted, "roundtrip_test");

    // Verify roundtrip
    const success = std.mem.eql(u8, test_data, decrypted);

    return .{
        .original_data = try allocator.dupe(u8, test_data),
        .decrypted_data = decrypted,
        .roundtrip_success = success,
    };
}

/// Measure encryption overhead
pub fn measureOverhead(allocator: std.mem.Allocator) !struct {
    baseline_ops_per_sec: i64,
    encrypted_ops_per_sec: i64,
    overhead_percentage: f64,
    passes_threshold: bool,
} {
    if (!enabled()) return error.FeatureDisabled;

    const iterations: usize = 1000;
    const test_data = try allocator.alloc(u8, 1024);
    defer allocator.free(test_data);
    // fips-exempt: non-security test-plaintext fill
    compat_fillRandom(test_data);

    // Baseline (no encryption)
    const baseline_start = compat_microTimestamp();
    for (0..iterations) |_| {
        const copy = try allocator.alloc(u8, test_data.len);
        @memcpy(copy, test_data);
        allocator.free(copy);
    }
    const baseline_time = compat_microTimestamp() - baseline_start;

    // With encryption
    const encrypted_start = compat_microTimestamp();
    for (0..iterations) |_| {
        const enc = try encrypt(allocator, test_data, "overhead_test");
        allocator.free(enc.data);
    }
    const encrypted_time = compat_microTimestamp() - encrypted_start;

    // Calculate ops/sec. SONNY-2739: a loop timed at 0 us made the rate
    // infinite and `@intFromFloat` aborted the server; time at least 1 us.
    const baseline_ops = (@as(f64, iterations) / @as(f64, @floatFromInt(@max(baseline_time, 1)))) * 1000000.0;
    const encrypted_ops = (@as(f64, iterations) / @as(f64, @floatFromInt(@max(encrypted_time, 1)))) * 1000000.0;
    const overhead = ((baseline_ops - encrypted_ops) / baseline_ops) * 100.0;

    return .{
        .baseline_ops_per_sec = std.math.lossyCast(i64, baseline_ops),
        .encrypted_ops_per_sec = std.math.lossyCast(i64, encrypted_ops),
        .overhead_percentage = overhead,
        .passes_threshold = overhead < 5.0, // <5% overhead threshold
    };
}

/// Simulate OLTP workload with encryption
pub fn simulateOLTPWorkload(allocator: std.mem.Allocator, duration_seconds: u32, concurrent_transactions: u32) !struct {
    avg_transaction_time_ms: f64,
    tps_with_encryption: i64,
    tps_without_encryption: i64,
    degradation_percentage: f64,
} {
    if (!enabled()) return error.FeatureDisabled;

    _ = concurrent_transactions;

    const test_data = try allocator.alloc(u8, 256);
    defer allocator.free(test_data);
    // fips-exempt: non-security test-plaintext fill
    compat_fillRandom(test_data);

    // SONNY-2739: u64, so a large duration cannot overflow the product.
    const iterations = @as(u64, duration_seconds) * 10; // Simulate transactions

    // Without encryption
    const unencrypted_start = compat_milliTimestamp();
    for (0..iterations) |_| {
        const copy = try allocator.alloc(u8, test_data.len);
        @memcpy(copy, test_data);
        allocator.free(copy);
    }
    const unencrypted_time = compat_milliTimestamp() - unencrypted_start;

    // With encryption
    const encrypted_start = compat_milliTimestamp();
    for (0..iterations) |_| {
        const enc = try encrypt(allocator, test_data, "oltp_test");
        const dec = try decrypt(allocator, enc, "oltp_test");
        allocator.free(enc.data);
        allocator.free(dec);
    }
    const encrypted_time = compat_milliTimestamp() - encrypted_start;

    // SONNY-2739: a loop timed at 0 ms made the rate infinite; see above.
    const tps_unencrypted = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(@max(unencrypted_time, 1)))) * 1000.0;
    const tps_encrypted = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(@max(encrypted_time, 1)))) * 1000.0;
    const avg_time = @as(f64, @floatFromInt(encrypted_time)) / @as(f64, @floatFromInt(iterations));
    const degradation = ((tps_unencrypted - tps_encrypted) / tps_unencrypted) * 100.0;

    return .{
        .avg_transaction_time_ms = avg_time,
        .tps_with_encryption = std.math.lossyCast(i64, tps_encrypted),
        .tps_without_encryption = std.math.lossyCast(i64, tps_unencrypted),
        .degradation_percentage = degradation,
    };
}

/// Test KMS wrap/unwrap
pub fn testKmsWrapUnwrap(allocator: std.mem.Allocator) !struct {
    wrap_success: bool,
    unwrap_success: bool,
    roundtrip_verified: bool,
    latency_ms: i64,
} {
    if (!enabled()) return error.FeatureDisabled;

    const start = compat_milliTimestamp();

    // Generate test key
    var test_key: [32]u8 = undefined;
    // fips-exempt: non-security test PLAINTEXT (the value is the data being encrypted by encrypt(), NOT the AES key/nonce; encrypt() derives its own key+nonce)
    compat_fillRandom(&test_key);

    // Simulate wrap (encrypt key with KEK)
    const wrapped = try encrypt(allocator, &test_key, "kms_wrap");
    defer allocator.free(wrapped.data);

    // Simulate unwrap (decrypt key with KEK)
    const unwrapped = try decrypt(allocator, wrapped, "kms_wrap");
    defer allocator.free(unwrapped);

    const latency = compat_milliTimestamp() - start;
    const verified = std.mem.eql(u8, &test_key, unwrapped);

    return .{
        .wrap_success = true,
        .unwrap_success = true,
        .roundtrip_verified = verified,
        .latency_ms = latency,
    };
}

/// Test KMS attestation with real Ed25519 signature verification
/// GAP-0211 SECURITY FIX: Implement actual Ed25519 verification instead of length check
/// CANARY: REQ=REQ-GQL-TDE-ATTEST-REAL-001; FEATURE="RealEd25519Attestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=test_gap_0211_ed25519_attestation; OWNER=security; UPDATED=2026-01-16
pub fn testKmsAttestation(allocator: std.mem.Allocator) !struct {
    attestation_valid: bool,
    signature_verified: bool,
    ed25519_verification: bool,
    tamper_detected: bool,
} {
    _ = allocator;

    // GAP-0211 FIX: Real Ed25519 key generation and signature verification
    // Route through cb.Sig so this executes in the OpenSSL FIPS module under -Dfips

    // Generate a test keypair (in real usage, public key would come from KMS)
    var keypair = cb.Sig.generate(.ed25519) catch {
        return .{
            .attestation_valid = false,
            .signature_verified = false,
            .ed25519_verification = false,
            .tamper_detected = false,
        };
    };
    defer keypair.deinit();

    // Create attestation message (nonce + timestamp + KMS identifier)
    var attestation_data: [64]u8 = undefined;
    // fips-exempt: non-security attestation replay-nonce (signed, not an AEAD IV or key)
    compat_fillRandom(attestation_data[0..32]); // nonce
    const timestamp = compat_milliTimestamp();
    std.mem.writeInt(i64, attestation_data[32..40], timestamp, .little);
    @memset(attestation_data[40..64], 0); // padding

    // Sign the attestation with private key
    var sig_buf: [64]u8 = undefined;
    _ = cb.Sig.sign(.ed25519, &keypair, &attestation_data, &sig_buf) catch {
        return .{
            .attestation_valid = false,
            .signature_verified = false,
            .ed25519_verification = false,
            .tamper_detected = false,
        };
    };

    // Verify the signature with public key (this is the real verification)
    var attestation_valid = false;
    var ed25519_verification = false;
    var tamper_detected = false;

    // Verify valid signature
    cb.Sig.verify(.ed25519, &keypair, &attestation_data, &sig_buf) catch {
        // Signature verification failed
        return .{
            .attestation_valid = false,
            .signature_verified = false,
            .ed25519_verification = false,
            .tamper_detected = false,
        };
    };
    // If we get here, verification succeeded
    attestation_valid = true;
    ed25519_verification = true;

    // Test tamper detection by modifying attestation and verifying rejection
    var tampered_data = attestation_data;
    tampered_data[0] ^= 0xFF; // Flip bits to simulate tampering

    // Tampered data should fail verification
    cb.Sig.verify(.ed25519, &keypair, &tampered_data, &sig_buf) catch {
        // Tampered data correctly rejected - this is expected
        tamper_detected = true;
        return .{
            .attestation_valid = attestation_valid,
            .signature_verified = attestation_valid,
            .ed25519_verification = ed25519_verification,
            .tamper_detected = tamper_detected,
        };
    };
    // If tampered data passes, that's bad
    tamper_detected = false;

    return .{
        .attestation_valid = attestation_valid,
        .signature_verified = attestation_valid,
        .ed25519_verification = ed25519_verification,
        .tamper_detected = tamper_detected,
    };
}
