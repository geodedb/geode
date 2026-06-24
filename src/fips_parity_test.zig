//! Task 11: FIPS dual-mode parity / Known-Answer Tests (KATs)
//!
//! Imports only `crypto_backend` — no `build_options`.  The seam dispatches
//! to the correct backend (-Dfips=false → std_shim, -Dfips=true → OpenSSL).
//! Every test must pass under BOTH modes.
//!
//! Vectors:
//!   SHA-256("abc")                 RFC 4634 §8.1
//!   SHA3-256("abc")                NIST FIPS 202 example
//!   HMAC-SHA256 TC2                RFC 4231 §4.3
//!   HMAC-SHA1 TC2                  RFC 2202 §3 TC2
//!   AES-256-GCM round-trip + tamper
//!   HKDF-SHA256 TC1                RFC 5869 Appendix A.1
//!   Ed25519 sign/verify round-trip + corrupt-sig
//!   ECDSA-P256 sign/verify round-trip + corrupt-sig
//!   RSA-PSS: error.Unsupported on std_shim; sign/verify if FIPS backend

const std = @import("std");
const cb = @import("crypto_backend");

// ---------------------------------------------------------------------------
// SHA-256("abc")
// RFC 4634 §8.1 / FIPS 180-4
// ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad
// ---------------------------------------------------------------------------
test "fips-parity: SHA-256 KAT" {
    const msg = "abc";
    const expected = [32]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    var out: [32]u8 = undefined;
    const n = try cb.Hash.digest(.sha256, msg, &out);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

// ---------------------------------------------------------------------------
// SHA3-256("abc")
// NIST FIPS 202 example
// 3a985da7 4fe225b2 045c172d 6bd390bd 855f086e 3e9d525b 46bfe245 11431532
// ---------------------------------------------------------------------------
test "fips-parity: SHA3-256 KAT" {
    const msg = "abc";
    const expected = [32]u8{
        0x3a, 0x98, 0x5d, 0xa7, 0x4f, 0xe2, 0x25, 0xb2,
        0x04, 0x5c, 0x17, 0x2d, 0x6b, 0xd3, 0x90, 0xbd,
        0x85, 0x5f, 0x08, 0x6e, 0x3e, 0x9d, 0x52, 0x5b,
        0x46, 0xbf, 0xe2, 0x45, 0x11, 0x43, 0x15, 0x32,
    };
    var out: [32]u8 = undefined;
    const n = try cb.Hash.digest(.sha3_256, msg, &out);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

// ---------------------------------------------------------------------------
// HMAC-SHA256 RFC 4231 TC2
//   Key  = "Jefe"  (4 bytes)
//   Data = "what do ya want for nothing?"
// Expected: 5bdcc146 bf60754e 6a042426 089575c7 5a003f08 9d273983 9dec58b9 64ec3843
// ---------------------------------------------------------------------------
test "fips-parity: HMAC-SHA256 RFC4231-TC2" {
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected = [32]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };
    var out: [32]u8 = undefined;
    const n = try cb.Mac.hmac(.sha256, key, data, &out);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

// ---------------------------------------------------------------------------
// HMAC-SHA1 RFC 2202 TC2
//   Key  = "Jefe"
//   Data = "what do ya want for nothing?"
// Expected: effcdf6a e5eb2fa2 d27416d5 f184df9c 259a7c79
// ---------------------------------------------------------------------------
test "fips-parity: HMAC-SHA1 RFC2202-TC2" {
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected = [20]u8{
        0xef, 0xfc, 0xdf, 0x6a, 0xe5, 0xeb, 0x2f, 0xa2,
        0xd2, 0x74, 0x16, 0xd5, 0xf1, 0x84, 0xdf, 0x9c,
        0x25, 0x9a, 0x7c, 0x79,
    };
    var out: [20]u8 = undefined;
    const n = try cb.Mac.hmacSha1(key, data, &out);
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

// ---------------------------------------------------------------------------
// AES-256-GCM round-trip
//   key   = 32 × 0x00
//   nonce = 12 × 0x00
//   ad    = empty
//   pt    = "hello world"
// ---------------------------------------------------------------------------
test "fips-parity: AES-256-GCM round-trip" {
    const key = [_]u8{0} ** 32;
    const nonce = [_]u8{0} ** 12;
    const ad = "";
    const plaintext = "hello world";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;

    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, ad, plaintext, &ciphertext, &tag);

    var decrypted: [plaintext.len]u8 = undefined;
    try cb.Aead.open(.aes_256_gcm, &key, &nonce, ad, &ciphertext, &tag, &decrypted);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

// ---------------------------------------------------------------------------
// AES-256-GCM tamper → error.AuthFailed
// ---------------------------------------------------------------------------
test "fips-parity: AES-256-GCM tamper returns AuthFailed" {
    const key = [_]u8{0} ** 32;
    const nonce = [_]u8{0} ** 12;
    const ad = "";
    const plaintext = "hello world";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, ad, plaintext, &ciphertext, &tag);

    // Flip one byte in the tag.
    tag[0] ^= 0xff;

    var decrypted: [plaintext.len]u8 = undefined;
    const result = cb.Aead.open(.aes_256_gcm, &key, &nonce, ad, &ciphertext, &tag, &decrypted);
    try std.testing.expectError(error.AuthFailed, result);
}

// ---------------------------------------------------------------------------
// HKDF-SHA256 RFC 5869 Appendix A.1
//   IKM  = 0x0b × 22
//   salt = 0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08 0x09 0x0a 0x0b 0x0c
//   info = 0xf0 0xf1 0xf2 0xf3 0xf4 0xf5 0xf6 0xf7 0xf8 0xf9
//   L    = 42 bytes
// Expected OKM: 3cb25f25 faacd57a 90434f64 d0362f2a 2d2d0a90 cf1a5a4c
//               5db02d56 ecc4c5bf 34007208 d5b88718 5865
// ---------------------------------------------------------------------------
test "fips-parity: HKDF-SHA256 RFC5869-A1" {
    const ikm = [_]u8{0x0b} ** 22;
    const salt = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const info = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };
    const expected = [42]u8{
        0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a,
        0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36, 0x2f, 0x2a,
        0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c,
        0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf,
        0x34, 0x00, 0x72, 0x08, 0xd5, 0xb8, 0x87, 0x18,
        0x58, 0x65,
    };
    var okm: [42]u8 = undefined;
    try cb.Kdf.hkdf(.sha256, &ikm, &salt, &info, &okm);
    try std.testing.expectEqualSlices(u8, &expected, &okm);
}

// ---------------------------------------------------------------------------
// Ed25519 sign/verify round-trip
// ---------------------------------------------------------------------------
test "fips-parity: Ed25519 sign/verify round-trip" {
    var kp = try cb.Sig.generate(.ed25519);
    defer kp.deinit();

    const msg = "test message for ed25519";
    var sig_buf: [64]u8 = undefined;
    const sig_len = try cb.Sig.sign(.ed25519, &kp, msg, &sig_buf);
    try cb.Sig.verify(.ed25519, &kp, msg, sig_buf[0..sig_len]);
}

// ---------------------------------------------------------------------------
// Ed25519: corrupted signature → error.VerifyFailed
// ---------------------------------------------------------------------------
test "fips-parity: Ed25519 corrupt-sig returns VerifyFailed" {
    var kp = try cb.Sig.generate(.ed25519);
    defer kp.deinit();

    const msg = "test message for ed25519 corrupt";
    var sig_buf: [64]u8 = undefined;
    const sig_len = try cb.Sig.sign(.ed25519, &kp, msg, &sig_buf);

    // Flip a byte in the middle of the signature.
    sig_buf[sig_len / 2] ^= 0xff;

    const result = cb.Sig.verify(.ed25519, &kp, msg, sig_buf[0..sig_len]);
    try std.testing.expectError(error.VerifyFailed, result);
}

// ---------------------------------------------------------------------------
// ECDSA-P256 sign/verify round-trip
// ---------------------------------------------------------------------------
test "fips-parity: ECDSA-P256 sign/verify round-trip" {
    var kp = try cb.Sig.generate(.ecdsa_p256);
    defer kp.deinit();

    const msg = "test message for ecdsa-p256";
    // DER-encoded ECDSA signature: at most 72 bytes for P-256.
    var sig_buf: [72]u8 = undefined;
    const sig_len = try cb.Sig.sign(.ecdsa_p256, &kp, msg, &sig_buf);
    try cb.Sig.verify(.ecdsa_p256, &kp, msg, sig_buf[0..sig_len]);
}

// ---------------------------------------------------------------------------
// ECDSA-P256: corrupted signature → error.VerifyFailed
// ---------------------------------------------------------------------------
test "fips-parity: ECDSA-P256 corrupt-sig returns VerifyFailed" {
    var kp = try cb.Sig.generate(.ecdsa_p256);
    defer kp.deinit();

    const msg = "test message for ecdsa-p256 corrupt";
    var sig_buf: [72]u8 = undefined;
    const sig_len = try cb.Sig.sign(.ecdsa_p256, &kp, msg, &sig_buf);

    // Flip the last byte — avoids corrupting DER framing length bytes at
    // the start which might cause a parse error rather than VerifyFailed.
    sig_buf[sig_len - 1] ^= 0xff;

    const result = cb.Sig.verify(.ecdsa_p256, &kp, msg, sig_buf[0..sig_len]);
    try std.testing.expectError(error.VerifyFailed, result);
}

// ---------------------------------------------------------------------------
// RSA-PSS: std_shim returns error.Unsupported; FIPS backend supports it.
// Wrap with the parity pattern: if generate succeeds (FIPS mode), do a
// round-trip; if it fails with Unsupported (shim mode), that is correct.
// ---------------------------------------------------------------------------
test "fips-parity: RSA-PSS Unsupported-on-shim / round-trip-on-FIPS" {
    if (cb.Sig.generate(.rsa_pss)) |kp| {
        // FIPS backend: RSA is available. Exercise sign + verify.
        // rsa_pss keypairs carry large key material; deinit is critical.
        var mutable_kp = kp;
        defer mutable_kp.deinit();

        const msg = "rsa-pss parity test message";
        // RSA-2048 PSS signature is 256 bytes; use a generous buffer.
        var sig_buf: [512]u8 = undefined;
        const sig_len = try cb.Sig.sign(.rsa_pss, &mutable_kp, msg, &sig_buf);
        try cb.Sig.verify(.rsa_pss, &mutable_kp, msg, sig_buf[0..sig_len]);
    } else |err| {
        // std_shim: Unsupported is the required boundary signal.
        try std.testing.expect(err == error.Unsupported);
    }
}
