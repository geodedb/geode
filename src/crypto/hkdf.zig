const std = @import("std");
const fle = @import("fle_lib");

// HKDF Key Derivation — thin compatibility layer over external fle library
// CANARY: REQ=REQ-FLE-HKDF-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/crypto/hkdf.zig; OWNER=security; UPDATED=2026-01-15

/// Default salt used in the FLE key hierarchy
pub const default_salt = fle.hkdf.default_salt;

/// HKDF-SHA256 key derivation (RFC 5869) — re-exported from fle library
pub const hkdfSha256 = fle.hkdf.hkdfSha256;

/// Derive a 32-byte key from master with context info — re-exported from fle library
pub const deriveKey32 = fle.hkdf.deriveKey32;

/// Derive TRK (Tenant Root Key) from master — re-exported from fle library
pub const deriveTRK = fle.hkdf.deriveTRK;

/// Derive SK (Schema Key) from TRK — re-exported from fle library
pub const deriveSK = fle.hkdf.deriveSK;

/// Derive FEK (Field Encryption Key) from SK — re-exported from fle library
pub const deriveFEK = fle.hkdf.deriveFEK;

/// Derive FEK with version for key rotation support — re-exported from fle library
pub const deriveFEKVersioned = fle.hkdf.deriveFEKVersioned;

/// Derive BIK (Blind Index Key) from SK — re-exported from fle library
pub const deriveBIK = fle.hkdf.deriveBIK;

/// Derive BIK with version for key rotation support — re-exported from fle library
pub const deriveBIKVersioned = fle.hkdf.deriveBIKVersioned;

test "HKDF-SHA256 derivation" {
    const testing = std.testing;

    const ikm = "input keying material";
    const salt = "salt";
    const info = "context info";

    var out: [42]u8 = undefined;
    try hkdfSha256(&out, ikm, salt, info);

    // Verify output is non-zero and deterministic
    var all_zero = true;
    for (out) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);

    // Same inputs produce same output
    var out2: [42]u8 = undefined;
    try hkdfSha256(&out2, ikm, salt, info);
    try testing.expectEqualSlices(u8, &out, &out2);

    // Different info produces different output
    var out3: [42]u8 = undefined;
    try hkdfSha256(&out3, ikm, salt, "different");
    try testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "Key hierarchy derivation" {
    const testing = std.testing;

    var master: [32]u8 = undefined;
    std.crypto.random.bytes(&master);

    const tenant_id = "tenant-123";
    const schema = "Person";
    const field = "ssn";

    const trk = try deriveTRK(&master, tenant_id);
    const sk = try deriveSK(&trk, schema);
    const fek = try deriveFEK(&sk, field);
    const bik = try deriveBIK(&sk, field);

    // All keys should be different
    try testing.expect(!std.mem.eql(u8, &trk, &sk));
    try testing.expect(!std.mem.eql(u8, &sk, &fek));
    try testing.expect(!std.mem.eql(u8, &fek, &bik));

    // Same inputs produce same keys
    const fek2 = try deriveFEK(&sk, field);
    try testing.expectEqualSlices(u8, &fek, &fek2);
}
