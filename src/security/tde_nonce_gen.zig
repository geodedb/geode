/// TDE Nonce Generation Module
///
/// This module provides nonce generation for AES-GCM encryption, ensuring
/// cryptographically secure random nonces as required by NIST SP 800-38D.
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
const testing = std.testing; // global for test blocks
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE Nonce Generation"; ASPECT=NonceGeneration; STATUS=TESTED; TEST=tde_tests; OWNER=security; UPDATED=2025-11-12

/// GCM standard 96-bit nonce
pub const NonceBytes = 12;

/// GAP-0109 / SEC-12 SECURITY FIX: Production build detection
/// Any non-Debug build is considered production to prevent deterministic
/// nonces in ReleaseSmall (which was previously excluded).
const is_production_build = @import("builtin").mode != .Debug;

/// Nonce generation mode
pub const NonceMode = enum {
    /// Cryptographically secure random nonces (production mode)
    Random,
    /// Deterministic nonces for testing only (NEVER use in production)
    /// GAP-0109 FIX: This mode is blocked in production builds
    Deterministic,
};

/// Nonce generator context
pub const NonceGenerator = struct {
    mode: NonceMode,
    deterministic_counter: u64,

    /// GAP-0109 SECURITY FIX: Block deterministic mode in production builds
    pub fn init(mode: NonceMode) NonceGenerator {
        // In production builds, deterministic mode is blocked at runtime
        if (is_production_build and mode == .Deterministic) {
            log.err("Deterministic nonce mode is blocked in production builds - would allow catastrophic IV reuse attacks", &.{});
            @panic("GAP-0109: Deterministic nonce mode blocked in production");
        }
        return NonceGenerator{
            .mode = mode,
            .deterministic_counter = 0,
        };
    }

    /// Generate a nonce according to the configured mode
    ///
    /// CRITICAL SECURITY: In Random mode, this uses cryptographically secure
    /// random bytes as required by NIST SP 800-38D. Deterministic mode is
    /// ONLY for testing and MUST NEVER be used in production as it would
    /// allow catastrophic IV reuse attacks.
    pub fn generate(self: *NonceGenerator, nonce: *[NonceBytes]u8) !void {
        switch (self.mode) {
            .Random => {
                // CRITICAL SECURITY: Use cryptographically secure random nonce
                // NIST SP 800-38D requires unique nonces for AES-GCM security
                // Deterministic nonces would allow catastrophic IV reuse attacks
                try cb.Csprng.bytes(nonce);
            },
            .Deterministic => {
                // TESTING ONLY: Deterministic nonce generation
                // This is UNSAFE for production use!
                cb.secureZero(nonce);
                std.mem.writeInt(u64, nonce[0..8], self.deterministic_counter, .little);
                self.deterministic_counter += 1;
            },
        }
    }
};

/// Generate a cryptographically secure random nonce
///
/// This is the recommended way to generate nonces for production use.
/// Uses the system's cryptographically secure random number generator.
pub fn generateSecureNonce(nonce: *[NonceBytes]u8) !void {
    try cb.Csprng.bytes(nonce);
}

/// Generate a deterministic nonce for testing
///
/// WARNING: This function is ONLY for testing purposes and MUST NEVER
/// be used in production code. Using deterministic nonces with AES-GCM
/// allows catastrophic IV reuse attacks that completely break encryption.
pub fn generateDeterministicNonce(nonce: *[NonceBytes]u8, counter: u64) void {
    cb.secureZero(nonce);
    std.mem.writeInt(u64, nonce[0..8], counter, .little);
}

/// Verify that a nonce meets security requirements
///
/// Checks that:
/// 1. The nonce is the correct size (96 bits / 12 bytes)
/// 2. The nonce is not all zeros (which might indicate uninitialized memory)
pub fn verifyNonce(nonce: []const u8) !void {
    if (nonce.len != NonceBytes) {
        return error.InvalidNonceSize;
    }

    // Check for all-zero nonce (might indicate uninitialized memory)
    var all_zero = true;
    for (nonce) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }

    if (all_zero) {
        return error.ZeroNonce;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "NonceGenerator - Random mode" {
    _ = std.testing;

    var gen = NonceGenerator.init(.Random);

    var nonce1: [NonceBytes]u8 = undefined;
    var nonce2: [NonceBytes]u8 = undefined;

    try gen.generate(&nonce1);
    try gen.generate(&nonce2);

    // Random nonces should be different
    try testing.expect(!std.mem.eql(u8, &nonce1, &nonce2));
}

test "NonceGenerator - Deterministic mode" {
    _ = std.testing;

    var gen = NonceGenerator.init(.Deterministic);

    var nonce1: [NonceBytes]u8 = undefined;
    var nonce2: [NonceBytes]u8 = undefined;

    try gen.generate(&nonce1);
    try gen.generate(&nonce2);

    // Deterministic nonces should be different (counter increments)
    try testing.expect(!std.mem.eql(u8, &nonce1, &nonce2));

    // First nonce should be counter=0
    var expected: [NonceBytes]u8 = [_]u8{0} ** NonceBytes;
    std.mem.writeInt(u64, expected[0..8], 0, .little);
    try testing.expect(std.mem.eql(u8, &nonce1, &expected));
}

test "generateSecureNonce - produces unique nonces" {
    _ = std.testing;

    var nonce1: [NonceBytes]u8 = undefined;
    var nonce2: [NonceBytes]u8 = undefined;

    try generateSecureNonce(&nonce1);
    try generateSecureNonce(&nonce2);

    // Should produce different nonces
    try testing.expect(!std.mem.eql(u8, &nonce1, &nonce2));
}

test "generateDeterministicNonce - produces expected values" {
    _ = std.testing;

    var nonce: [NonceBytes]u8 = undefined;

    generateDeterministicNonce(&nonce, 42);

    // Check that counter is encoded correctly
    const counter = std.mem.readInt(u64, nonce[0..8], .little);
    try testing.expectEqual(@as(u64, 42), counter);

    // Remaining bytes should be zero
    for (nonce[8..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "verifyNonce - valid nonce" {
    _ = std.testing;

    var nonce: [NonceBytes]u8 = undefined;
    try generateSecureNonce(&nonce);

    try verifyNonce(&nonce);
}

test "verifyNonce - invalid size" {
    _ = std.testing;

    const nonce = [_]u8{1} ** 10; // Wrong size

    try testing.expectError(error.InvalidNonceSize, verifyNonce(&nonce));
}

test "verifyNonce - all zeros" {
    _ = std.testing;

    const nonce = [_]u8{0} ** NonceBytes;

    try testing.expectError(error.ZeroNonce, verifyNonce(&nonce));
}

test "NonceGenerator - counter increments" {
    _ = std.testing;

    var gen = NonceGenerator.init(.Deterministic);

    for (0..5) |i| {
        var nonce: [NonceBytes]u8 = undefined;
        try gen.generate(&nonce);

        const counter = std.mem.readInt(u64, nonce[0..8], .little);
        try testing.expectEqual(i, counter);
    }
}
