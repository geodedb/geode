const std = @import("std");
// FIPS seam: all security primitives in this file route through cb when
// the seam API covers the operation. std.crypto is retained ONLY where
// the seam cannot cover geode's key lifecycle (raw-bytes import/export)
// — each such site is marked SEAM-GAP with an explicit blocker note.
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
const hash_impl = @import("hash.zig");

// CANARY: REQ=REQ-GQL-CRYPTO-TYPES-001; FEATURE="Cryptographic Types Implementation"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_CRYPTO_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

/// Cryptographic types for security, integrity, and authentication
/// Supports hashing, digital signatures, and cryptographic primitives

// Re-export existing hash types
pub const HashAlg = hash_impl.HashAlg;
pub const Hash = hash_impl.Hash;
pub const Argon2Params = hash_impl.Argon2Params;

/// Digital signature with algorithm identification
pub const Signature = struct {
    alg: SignatureAlg,
    signature: []const u8,
    public_key: ?[]const u8 = null, // Optional public key for verification

    /// Signature algorithms supported
    pub const SignatureAlg = enum(u8) {
        Ed25519 = 1,
        ECDSA_P256 = 2,
        ECDSA_P384 = 3,
        RSA_PSS_SHA256 = 4,
        RSA_PSS_SHA512 = 5,

        pub fn toString(self: SignatureAlg) []const u8 {
            return switch (self) {
                .Ed25519 => "Ed25519",
                .ECDSA_P256 => "ECDSA-P256",
                .ECDSA_P384 => "ECDSA-P384",
                .RSA_PSS_SHA256 => "RSA-PSS-SHA256",
                .RSA_PSS_SHA512 => "RSA-PSS-SHA512",
            };
        }

        pub fn fromString(alg_str: []const u8) !SignatureAlg {
            if (std.mem.eql(u8, alg_str, "Ed25519")) return .Ed25519;
            if (std.mem.eql(u8, alg_str, "ECDSA-P256")) return .ECDSA_P256;
            if (std.mem.eql(u8, alg_str, "ECDSA-P384")) return .ECDSA_P384;
            if (std.mem.eql(u8, alg_str, "RSA-PSS-SHA256")) return .RSA_PSS_SHA256;
            if (std.mem.eql(u8, alg_str, "RSA-PSS-SHA512")) return .RSA_PSS_SHA512;
            return error.InvalidSignatureAlgorithm;
        }

        pub fn expectedSignatureSize(self: SignatureAlg) usize {
            return switch (self) {
                .Ed25519 => 64,
                .ECDSA_P256 => 64, // r + s
                .ECDSA_P384 => 96, // r + s
                .RSA_PSS_SHA256 => 256, // 2048-bit key
                .RSA_PSS_SHA512 => 512, // 4096-bit key
            };
        }

        pub fn expectedPublicKeySize(self: SignatureAlg) usize {
            return switch (self) {
                .Ed25519 => 32,
                .ECDSA_P256 => 33, // compressed point
                .ECDSA_P384 => 49, // compressed point
                .RSA_PSS_SHA256 => 256, // 2048-bit key
                .RSA_PSS_SHA512 => 512, // 4096-bit key
            };
        }
    };

    pub fn fromHex(alg: SignatureAlg, hex_sig: []const u8, hex_pubkey: ?[]const u8, allocator: std.mem.Allocator) !Signature {
        // Decode hex signature
        const sig_bytes = try allocator.alloc(u8, hex_sig.len / 2);
        errdefer allocator.free(sig_bytes);

        _ = std.fmt.hexToBytes(sig_bytes, hex_sig) catch {
            return error.InvalidSignatureLength;
        };

        // Validate signature length
        if (sig_bytes.len != alg.expectedSignatureSize()) {
            allocator.free(sig_bytes);
            return error.InvalidSignatureLength;
        }

        // Decode public key if provided
        var pubkey_bytes: ?[]const u8 = null;
        if (hex_pubkey) |hex_pk| {
            const pk_bytes = try allocator.alloc(u8, hex_pk.len / 2);
            errdefer allocator.free(pk_bytes);

            _ = std.fmt.hexToBytes(pk_bytes, hex_pk) catch {
                return error.InvalidPublicKeyLength;
            };

            if (pk_bytes.len != alg.expectedPublicKeySize()) {
                allocator.free(pk_bytes);
                return error.InvalidPublicKeyLength;
            }
            pubkey_bytes = pk_bytes;
        }

        return Signature{
            .alg = alg,
            .signature = sig_bytes,
            .public_key = pubkey_bytes,
        };
    }

    pub fn fromString(sig_str: []const u8, allocator: std.mem.Allocator) !Signature {
        // Parse format: "algorithm:signature:public_key" or "algorithm:signature"
        var parts = std.mem.splitSequence(u8, sig_str, ":");

        const alg_str = parts.next() orelse return error.InvalidSignatureFormat;
        const sig_str_part = parts.next() orelse return error.InvalidSignatureFormat;
        const pubkey_str = parts.next();

        const alg = try SignatureAlg.fromString(alg_str);
        return fromHex(alg, sig_str_part, pubkey_str, allocator);
    }

    pub fn toString(self: Signature, allocator: std.mem.Allocator) ![]u8 {
        const sig_hex = try allocator.alloc(u8, self.signature.len * 2);
        defer allocator.free(sig_hex);
        for (self.signature, 0..) |byte, i| {
            sig_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
            sig_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
        }

        if (self.public_key) |pubkey| {
            const pubkey_hex = try allocator.alloc(u8, pubkey.len * 2);
            defer allocator.free(pubkey_hex);
            for (pubkey, 0..) |byte, i| {
                pubkey_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
                pubkey_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
            }

            return std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ self.alg.toString(), sig_hex, pubkey_hex });
        } else {
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.alg.toString(), sig_hex });
        }
    }

    /// Verify signature against data.
    /// Ed25519 routes through the FIPS seam (cb.Sig).
    /// ECDSA P256/P384: SEAM-GAP — the fips backend's fromPublicBytes for
    ///   ECDSA expects DER SubjectPublicKeyInfo, but geode stores 33/49-byte
    ///   compressed SEC1 points. Routing retained on std.crypto pending a
    ///   seam extension that accepts SEC1 for ECDSA. (See task-2-report.md.)
    /// RSA-PSS: Not yet routed — geode stores raw modulus+exponent as a single
    ///   blob without DER framing; seam needs fromRsaComponents(n,e) or
    ///   fromRsaSpki(der). Returns UnsupportedSignatureAlgorithm until a key
    ///   format bridge is added.
    // CANARY: REQ=REQ-M7-SIGNATURE-001; FEATURE="CodeQuality"; ASPECT=SignatureVerification; STATUS=TESTED; TEST=TestCANARY_GAP_0253_ECDSA_SignVerify; OWNER=security; UPDATED=2026-03-13
    pub fn verify(self: Signature, data: []const u8) !bool {
        if (self.public_key == null) return error.PublicKeyRequired;

        // Basic validation
        if (self.signature.len != self.alg.expectedSignatureSize()) return false;
        if (self.public_key.?.len != self.alg.expectedPublicKeySize()) return false;

        // Perform actual cryptographic verification based on algorithm
        switch (self.alg) {
            .Ed25519 => {
                // Ed25519 expects 64-byte signature and 32-byte public key.
                // Routed through the FIPS seam: cb.Sig.KeyPair.fromPublicBytes +
                // cb.Sig.verify. Both the fips and std_shim backends accept a
                // 32-byte raw public key for Ed25519.
                if (self.signature.len != 64) return false;
                if (self.public_key.?.len != 32) return false;

                var kp = cb.Sig.KeyPair.fromPublicBytes(.ed25519, self.public_key.?) catch return false;
                defer kp.deinit();
                cb.Sig.verify(.ed25519, &kp, data, self.signature) catch return false;
                return true;
            },
            .ECDSA_P256 => {
                // SEAM-GAP: the fips backend's Sig.KeyPair.fromPublicBytes for
                // .ecdsa_p256 calls d2i_PUBKEY (DER SubjectPublicKeyInfo), but
                // geode stores 33-byte compressed SEC1. The std_shim accepts SEC1
                // via P256.PublicKey.fromSec1, so there is a backend parity gap.
                // Until the seam adds a SEC1-accepting ECDSA public-key import
                // path, this verify branch stays on std.crypto for both modes.
                // std.crypto path (non-FIPS for ECDSA P256):
                if (self.signature.len != 64) return false;
                if (self.public_key.?.len != 33) return false;

                const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
                const ecdsa_sig = EcdsaP256.Signature.fromBytes(self.signature[0..64].*);
                const public_key = EcdsaP256.PublicKey.fromSec1(self.public_key.?) catch {
                    return false;
                };
                ecdsa_sig.verify(data, public_key) catch {
                    return false;
                };
                return true;
            },
            .ECDSA_P384 => {
                // SEAM-GAP: same issue as ECDSA_P256 — fips backend needs DER
                // SPKI; geode stores 49-byte compressed SEC1. std.crypto path
                // retained for both modes pending a seam SEC1 import extension.
                if (self.signature.len != 96) return false;
                if (self.public_key.?.len != 49) return false;

                const EcdsaP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
                const ecdsa_sig = EcdsaP384.Signature.fromBytes(self.signature[0..96].*);
                const public_key = EcdsaP384.PublicKey.fromSec1(self.public_key.?) catch {
                    return false;
                };
                ecdsa_sig.verify(data, public_key) catch {
                    return false;
                };
                return true;
            },
            // RSA algorithms: SEAM-GAP — geode stores the public key as a raw
            // 256/512-byte blob without a DER header separating modulus (n) from
            // exponent (e). The seam's cb.Sig.KeyPair.fromRsaComponents(n, e)
            // requires separate n/e byte slices, and fromRsaSpki requires full
            // DER SPKI framing. Until a key-format bridge (or key schema change)
            // is in place this stays UnsupportedSignatureAlgorithm.
            .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                return error.UnsupportedSignatureAlgorithm;
            },
        }
    }

    /// Binary encoding for storage
    pub fn encode(self: Signature, writer: anytype) !void {
        try writer.writeByte(0x15); // Signature tag
        try writer.writeByte(@intFromEnum(self.alg));

        // Write signature
        try writer.writeInt(u16, @intCast(self.signature.len), .little);
        try writer.writeAll(self.signature);

        // Write public key if present
        if (self.public_key) |pubkey| {
            try writer.writeByte(1); // Has public key
            try writer.writeInt(u16, @intCast(pubkey.len), .little);
            try writer.writeAll(pubkey);
        } else {
            try writer.writeByte(0); // No public key
        }
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !Signature {
        const tag = try reader.takeByte();
        if (tag != 0x15) return error.InvalidSignatureTag;

        const alg_byte = try reader.takeByte();
        const alg = @as(SignatureAlg, @enumFromInt(alg_byte));

        // Read signature
        const sig_len = try reader.takeInt(u16, .little);
        const signature = try allocator.alloc(u8, sig_len);
        try reader.readSliceAll(signature);

        // Read public key if present
        const has_pubkey = try reader.takeByte();
        var public_key: ?[]const u8 = null;

        if (has_pubkey == 1) {
            const pubkey_len = try reader.takeInt(u16, .little);
            const pubkey_data = try allocator.alloc(u8, pubkey_len);
            try reader.readSliceAll(pubkey_data);
            public_key = pubkey_data;
        }

        return Signature{
            .alg = alg,
            .signature = signature,
            .public_key = public_key,
        };
    }

    pub fn deinit(self: Signature, allocator: std.mem.Allocator) void {
        allocator.free(self.signature);
        if (self.public_key) |pubkey| {
            allocator.free(pubkey);
        }
    }
};

/// Cryptographic key pair for asymmetric operations
pub const KeyPair = struct {
    alg: Signature.SignatureAlg,
    private_key: []const u8,
    public_key: []const u8,

    // CANARY: REQ=REQ-CRYPTO-RANDOM-001; FEATURE="CryptographicKeyGeneration"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_CRYPTO_RANDOM_001; OWNER=security; UPDATED=2026-01-11
    pub fn generate(alg: Signature.SignatureAlg, allocator: std.mem.Allocator) !KeyPair {
        // Entropy comes from the FIPS seam's CSPRNG (cb.Csprng.bytes), which
        // routes to the FIPS-validated DRBG under -Dfips=true and to the OS
        // CSPRNG under -Dfips=false. The key-derivation step (generateDeterministic)
        // still uses std.crypto because the seam's Sig.KeyPair does not expose
        // a privateBytes() extraction method — storing raw scalar/seed bytes for
        // later sign/verify operations requires the std.crypto type internals.
        // SEAM-GAP: full generate routing (no std.crypto touch) requires a
        // seam extension that exports raw key material from cb.Sig.KeyPair.
        switch (alg) {
            .Ed25519 => {
                // Seed from the FIPS seam CSPRNG; key derivation via std.crypto.
                var seed: [32]u8 = undefined;
                defer cb.secureZero(&seed);
                cb.Csprng.bytes(&seed) catch compat_fillRandom(&seed);
                const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

                const private_key = try allocator.alloc(u8, 32);
                const public_key = try allocator.alloc(u8, 32);
                const seed_bytes = key_pair.secret_key.seed();
                @memcpy(private_key, &seed_bytes);
                const pk_bytes = key_pair.public_key.toBytes();
                @memcpy(public_key, &pk_bytes);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .ECDSA_P256 => {
                // Seed from the FIPS seam CSPRNG; key derivation via std.crypto.
                const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
                var seed: [P256.KeyPair.seed_length]u8 = undefined;
                defer cb.secureZero(&seed);
                cb.Csprng.bytes(&seed) catch compat_fillRandom(&seed);
                const key_pair = try P256.KeyPair.generateDeterministic(seed);
                const private_key = try allocator.alloc(u8, 32);
                const public_key = try allocator.alloc(u8, 33); // Compressed format
                @memcpy(private_key, &key_pair.secret_key.bytes);
                const pk_compressed = key_pair.public_key.toCompressedSec1();
                @memcpy(public_key, &pk_compressed);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .ECDSA_P384 => {
                // Seed from the FIPS seam CSPRNG; key derivation via std.crypto.
                const P384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
                var seed: [P384.KeyPair.seed_length]u8 = undefined;
                defer cb.secureZero(&seed);
                cb.Csprng.bytes(&seed) catch compat_fillRandom(&seed);
                const key_pair = try P384.KeyPair.generateDeterministic(seed);
                const private_key = try allocator.alloc(u8, 48);
                const public_key = try allocator.alloc(u8, 49); // Compressed format
                @memcpy(private_key, &key_pair.secret_key.bytes);
                const pk_compressed = key_pair.public_key.toCompressedSec1();
                @memcpy(public_key, &pk_compressed);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                // GAP-0222 FIX: RSA key generation is not supported in Zig stdlib
                // Return explicit error instead of generating invalid random-byte keys
                // RSA requires external library (e.g., OpenSSL bindings) for proper implementation
                // CANARY: REQ=REQ-GQL-CRYPTO-TYPES-001; FEATURE="RSA Key Generation"; ASPECT=UnsupportedAlgorithm; STATUS=TESTED; TEST=TestRsaKeyGenerationReturnsError; OWNER=security; UPDATED=2026-01-16
                return error.UnsupportedSignatureAlgorithm;
            },
        }
    }

    /// Sign data with this key pair.
    /// SEAM-GAP for ALL algorithms: the seam's cb.Sig.KeyPair.fromPrivateBytes
    /// has backend-specific key-format requirements that conflict with geode's
    /// raw-bytes key storage:
    ///   - Ed25519: fips backend accepts 32-byte seed (OpenSSL raw private key),
    ///     std_shim needs 64-byte Zig SecretKey (seed+expanded). geode stores
    ///     32-byte seed only — works in fips mode but fails in std_shim mode.
    ///   - ECDSA P256/P384: fips backend needs DER-encoded ECPrivateKey
    ///     (d2i_PrivateKey); std_shim needs raw 32/48-byte scalar. geode stores
    ///     raw scalars — works in std_shim, fails in fips mode.
    ///   - RSA: no key generation or sign support; returns UnsupportedSignatureAlgorithm.
    /// Until the seam exposes a consistent raw-scalar import path across both
    /// backends, the sign path remains on std.crypto to keep both modes working.
    // CANARY: REQ=REQ-M7-SIGNATURE-002; FEATURE="CodeQuality"; ASPECT=SignatureSigning; STATUS=TESTED; TEST=TestCANARY_GAP_0253_ECDSA_SignVerify; OWNER=security; UPDATED=2026-03-13
    pub fn sign(self: KeyPair, data: []const u8, allocator: std.mem.Allocator) !Signature {
        // Perform actual cryptographic signing based on algorithm
        switch (self.alg) {
            .Ed25519 => {
                // Ed25519 requires 32-byte private key and produces 64-byte signature
                if (self.private_key.len != 32) return error.InvalidPrivateKeySize;
                if (self.public_key.len != 32) return error.InvalidPublicKeySize;

                const secret_bytes = self.private_key[0..32].*;

                // Create Ed25519 key pair from existing keys
                const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(secret_bytes);

                // Sign the data
                const sig_bytes = try key_pair.sign(data, null);

                // Allocate and copy signature
                const signature_bytes = try allocator.alloc(u8, 64);
                const sig_bytes_array = sig_bytes.toBytes();
                @memcpy(signature_bytes, &sig_bytes_array);

                const public_key_copy = try allocator.dupe(u8, self.public_key);

                return Signature{
                    .alg = self.alg,
                    .signature = signature_bytes,
                    .public_key = public_key_copy,
                };
            },
            .ECDSA_P256 => {
                // ECDSA P256 requires 32-byte private key and 33-byte compressed public key
                if (self.private_key.len != 32) return error.InvalidPrivateKeySize;
                if (self.public_key.len != 33) return error.InvalidPublicKeySize;

                const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

                // Reconstruct secret key from raw bytes
                const secret_key = EcdsaP256.SecretKey{ .bytes = self.private_key[0..32].* };

                // Reconstruct key pair from secret key
                const key_pair = EcdsaP256.KeyPair.fromSecretKey(secret_key) catch {
                    return error.InvalidPrivateKeySize;
                };

                // Sign the data (deterministic: noise = null)
                const ecdsa_sig = key_pair.sign(data, null) catch {
                    return error.SigningFailed;
                };

                // Convert signature to raw bytes (r || s, 64 bytes)
                const sig_raw = ecdsa_sig.toBytes();
                const signature_bytes = try allocator.alloc(u8, 64);
                @memcpy(signature_bytes, &sig_raw);

                const public_key_copy = try allocator.dupe(u8, self.public_key);

                return Signature{
                    .alg = self.alg,
                    .signature = signature_bytes,
                    .public_key = public_key_copy,
                };
            },
            .ECDSA_P384 => {
                // ECDSA P384 requires 48-byte private key and 49-byte compressed public key
                if (self.private_key.len != 48) return error.InvalidPrivateKeySize;
                if (self.public_key.len != 49) return error.InvalidPublicKeySize;

                const EcdsaP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

                // Reconstruct secret key from raw bytes
                const secret_key = EcdsaP384.SecretKey{ .bytes = self.private_key[0..48].* };

                // Reconstruct key pair from secret key
                const key_pair = EcdsaP384.KeyPair.fromSecretKey(secret_key) catch {
                    return error.InvalidPrivateKeySize;
                };

                // Sign the data (deterministic: noise = null)
                const ecdsa_sig = key_pair.sign(data, null) catch {
                    return error.SigningFailed;
                };

                // Convert signature to raw bytes (r || s, 96 bytes)
                const sig_raw = ecdsa_sig.toBytes();
                const signature_bytes = try allocator.alloc(u8, 96);
                @memcpy(signature_bytes, &sig_raw);

                const public_key_copy = try allocator.dupe(u8, self.public_key);

                return Signature{
                    .alg = self.alg,
                    .signature = signature_bytes,
                    .public_key = public_key_copy,
                };
            },
            // RSA algorithms not supported in Zig stdlib — deferred to external library integration
            .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                return error.UnsupportedSignatureAlgorithm;
            },
        }
    }

    pub fn deinit(self: KeyPair, allocator: std.mem.Allocator) void {
        // Zero out private key for security — routed through the FIPS seam.
        cb.secureZero(@constCast(self.private_key));
        allocator.free(self.private_key);
        allocator.free(self.public_key);
    }
};

/// HMAC for message authentication
pub const Hmac = struct {
    alg: HmacAlg,
    key: []const u8,
    digest: []const u8,

    pub const HmacAlg = enum(u8) {
        HMAC_SHA256 = 1,
        HMAC_SHA512 = 2,
        HMAC_SHA3_256 = 3,
        HMAC_SHA3_512 = 4,

        pub fn toString(self: HmacAlg) []const u8 {
            return switch (self) {
                .HMAC_SHA256 => "HMAC-SHA256",
                .HMAC_SHA512 => "HMAC-SHA512",
                .HMAC_SHA3_256 => "HMAC-SHA3-256",
                .HMAC_SHA3_512 => "HMAC-SHA3-512",
            };
        }

        pub fn digestSize(self: HmacAlg) usize {
            return switch (self) {
                .HMAC_SHA256, .HMAC_SHA3_256 => 32,
                .HMAC_SHA512, .HMAC_SHA3_512 => 64,
            };
        }
    };

    pub fn compute(alg: HmacAlg, key: []const u8, data: []const u8, allocator: std.mem.Allocator) !Hmac {
        const digest = try allocator.alloc(u8, alg.digestSize());
        errdefer allocator.free(digest);

        // Route through the FIPS seam: cb.Mac.hmac(cb.policy.Hash, key, msg, out).
        // Under -Dfips=true this executes inside the OpenSSL FIPS module;
        // under -Dfips=false it uses std.crypto (std_shim backend).
        switch (alg) {
            .HMAC_SHA256 => _ = try cb.Mac.hmac(.sha256, key, data, digest[0..32]),
            .HMAC_SHA512 => _ = try cb.Mac.hmac(.sha512, key, data, digest[0..64]),
            .HMAC_SHA3_256 => _ = try cb.Mac.hmac(.sha3_256, key, data, digest[0..32]),
            .HMAC_SHA3_512 => _ = try cb.Mac.hmac(.sha3_512, key, data, digest[0..64]),
        }

        const key_copy = try allocator.dupe(u8, key);

        return Hmac{
            .alg = alg,
            .key = key_copy,
            .digest = digest,
        };
    }

    pub fn verify(self: Hmac, data: []const u8, allocator: std.mem.Allocator) !bool {
        const expected = try compute(self.alg, self.key, data, allocator);
        defer expected.deinit(allocator);

        // GAP-0881: compare the FULL digest (the old code only compared the
        // first 32 bytes, silently truncating 64-byte SHA-512/SHA3-512 MACs).
        // cb.timingSafeEql routes through the FIPS seam (constant-time compare).
        if (self.digest.len != expected.digest.len) return false;
        return cb.timingSafeEql(self.digest, expected.digest);
    }

    pub fn toString(self: Hmac, allocator: std.mem.Allocator) ![]u8 {
        const digest_hex = try allocator.alloc(u8, self.digest.len * 2);
        defer allocator.free(digest_hex);
        for (self.digest, 0..) |byte, i| {
            digest_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
            digest_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
        }

        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.alg.toString(), digest_hex });
    }

    pub fn deinit(self: Hmac, allocator: std.mem.Allocator) void {
        // Zero out key for security — routed through the FIPS seam.
        cb.secureZero(@constCast(self.key));
        allocator.free(self.key);
        allocator.free(self.digest);
    }
};

// Utility functions for cryptographic operations
pub fn hashString(alg: HashAlg, data: []const u8, allocator: std.mem.Allocator) !Hash {
    return hash_impl.hash(allocator, alg, data, null, null);
}

pub fn verifySignature(sig: Signature, data: []const u8) !bool {
    return sig.verify(data);
}

pub fn generateKeyPair(alg: Signature.SignatureAlg, allocator: std.mem.Allocator) !KeyPair {
    return KeyPair.generate(alg, allocator);
}

// Test suite
test "Signature operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test signature creation from hex
    const sig = try Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.Ed25519, sig.alg);
    try testing.expectEqual(@as(usize, 64), sig.signature.len);
    try testing.expectEqual(@as(usize, 32), sig.public_key.?.len);

    // Test string representation
    const sig_str = try sig.toString(allocator);
    defer allocator.free(sig_str);
    try testing.expect(std.mem.startsWith(u8, sig_str, "Ed25519:"));

    // Test verification placeholder
    const is_valid = try sig.verify("test data");
    try testing.expect(!is_valid);
}

test "HMAC operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test HMAC computation
    const key = "secret_key";
    const data = "hello world";

    const hmac = try Hmac.compute(.HMAC_SHA256, key, data, allocator);
    defer hmac.deinit(allocator);

    try testing.expectEqual(Hmac.HmacAlg.HMAC_SHA256, hmac.alg);
    try testing.expectEqual(@as(usize, 32), hmac.digest.len);

    // Test verification
    const is_valid = try hmac.verify(data, allocator);
    try testing.expect(is_valid);

    // Test string representation
    const hmac_str = try hmac.toString(allocator);
    defer allocator.free(hmac_str);
    try testing.expect(std.mem.startsWith(u8, hmac_str, "HMAC-SHA256:"));
}

test "KeyPair generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test key pair generation
    const keypair = try KeyPair.generate(.Ed25519, allocator);
    defer keypair.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.Ed25519, keypair.alg);
    try testing.expectEqual(@as(usize, 32), keypair.private_key.len);
    try testing.expectEqual(@as(usize, 32), keypair.public_key.len);

    // Test signing
    const signature = try keypair.sign("test message", allocator);
    defer signature.deinit(allocator);

    try testing.expectEqual(keypair.alg, signature.alg);
    try testing.expectEqual(@as(usize, 64), signature.signature.len);
}

test "Cryptographic encoding and decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Signature encoding/decoding
    const sig = try Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try sig.encode(&writer);
    const sig_len = writer.buffered().len;
    var reader = std.Io.Reader.fixed(buffer[0..sig_len]);
    const decoded_sig = try Signature.decode(&reader, allocator);
    defer decoded_sig.deinit(allocator);

    try testing.expectEqual(sig.alg, decoded_sig.alg);
    try testing.expectEqual(sig.signature.len, decoded_sig.signature.len);
    try testing.expectEqualSlices(u8, sig.signature, decoded_sig.signature);
    try testing.expectEqualSlices(u8, sig.public_key.?, decoded_sig.public_key.?);
}

test "Cryptographic error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test invalid signature algorithm
    try testing.expectError(error.InvalidSignatureAlgorithm, Signature.SignatureAlg.fromString("Invalid"));

    // Test invalid signature length
    try testing.expectError(error.InvalidSignatureLength, Signature.fromHex(.Ed25519, "short", null, allocator));

    // Test invalid public key length
    try testing.expectError(error.InvalidPublicKeyLength, Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "short", allocator));
}

// CANARY: REQ=REQ-GQL-CRYPTO-TYPES-001; FEATURE="RSA Key Generation Error Test"; ASPECT=UnsupportedAlgorithm; STATUS=TESTED; TEST=TestRsaKeyGenerationReturnsError; OWNER=security; UPDATED=2026-01-16
test "GAP-0222: RSA key generation returns UnsupportedSignatureAlgorithm error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // GAP-0222 FIX: RSA algorithms should return error, not random bytes
    // RSA-PSS-SHA256 is not supported (requires external library)
    try testing.expectError(error.UnsupportedSignatureAlgorithm, KeyPair.generate(.RSA_PSS_SHA256, allocator));

    // RSA-PSS-SHA512 is not supported (requires external library)
    try testing.expectError(error.UnsupportedSignatureAlgorithm, KeyPair.generate(.RSA_PSS_SHA512, allocator));
}

test "GAP-0222: Supported algorithms generate valid key pairs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Ed25519 should work
    const ed25519_key = try KeyPair.generate(.Ed25519, allocator);
    defer allocator.free(ed25519_key.private_key);
    defer allocator.free(ed25519_key.public_key);
    try testing.expectEqual(Signature.SignatureAlg.Ed25519, ed25519_key.alg);
    try testing.expectEqual(@as(usize, 32), ed25519_key.private_key.len);
    try testing.expectEqual(@as(usize, 32), ed25519_key.public_key.len);

    // ECDSA-P256 should work
    const p256_key = try KeyPair.generate(.ECDSA_P256, allocator);
    defer allocator.free(p256_key.private_key);
    defer allocator.free(p256_key.public_key);
    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P256, p256_key.alg);
    try testing.expectEqual(@as(usize, 32), p256_key.private_key.len);
    try testing.expectEqual(@as(usize, 33), p256_key.public_key.len); // Compressed format

    // ECDSA-P384 should work
    const p384_key = try KeyPair.generate(.ECDSA_P384, allocator);
    defer allocator.free(p384_key.private_key);
    defer allocator.free(p384_key.public_key);
    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P384, p384_key.alg);
    try testing.expectEqual(@as(usize, 48), p384_key.private_key.len);
    try testing.expectEqual(@as(usize, 49), p384_key.public_key.len); // Compressed format
}

// CANARY: REQ=REQ-GQL-CRYPTO-ECDSA-001; FEATURE="ECDSA P256/P384 Sign/Verify"; ASPECT=DigitalSignatures; STATUS=TESTED; TEST=TestCANARY_GAP_0253_ECDSA_SignVerify; OWNER=security; UPDATED=2026-03-13
test "GAP-0253: ECDSA P256 sign and verify" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Generate a P256 key pair
    const keypair = try KeyPair.generate(.ECDSA_P256, allocator);
    defer keypair.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P256, keypair.alg);
    try testing.expectEqual(@as(usize, 32), keypair.private_key.len);
    try testing.expectEqual(@as(usize, 33), keypair.public_key.len);

    // Sign a message
    const message = "GAP-0253 ECDSA P256 test message";
    const signature = try keypair.sign(message, allocator);
    defer signature.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P256, signature.alg);
    try testing.expectEqual(@as(usize, 64), signature.signature.len);
    try testing.expect(signature.public_key != null);
    try testing.expectEqual(@as(usize, 33), signature.public_key.?.len);

    // Verify the signature
    const is_valid = try signature.verify(message);
    try testing.expect(is_valid);

    // Verify fails with wrong message
    const is_invalid = try signature.verify("wrong message");
    try testing.expect(!is_invalid);
}

test "GAP-0253: ECDSA P384 sign and verify" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Generate a P384 key pair
    const keypair = try KeyPair.generate(.ECDSA_P384, allocator);
    defer keypair.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P384, keypair.alg);
    try testing.expectEqual(@as(usize, 48), keypair.private_key.len);
    try testing.expectEqual(@as(usize, 49), keypair.public_key.len);

    // Sign a message
    const message = "GAP-0253 ECDSA P384 test message";
    const signature = try keypair.sign(message, allocator);
    defer signature.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P384, signature.alg);
    try testing.expectEqual(@as(usize, 96), signature.signature.len);
    try testing.expect(signature.public_key != null);
    try testing.expectEqual(@as(usize, 49), signature.public_key.?.len);

    // Verify the signature
    const is_valid = try signature.verify(message);
    try testing.expect(is_valid);

    // Verify fails with wrong message
    const is_invalid = try signature.verify("wrong message");
    try testing.expect(!is_invalid);
}

test "GAP-0253: ECDSA P256 signature encoding roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Generate, sign, encode, decode, and verify
    const keypair = try KeyPair.generate(.ECDSA_P256, allocator);
    defer keypair.deinit(allocator);

    const message = "encoding roundtrip test";
    const signature = try keypair.sign(message, allocator);
    defer signature.deinit(allocator);

    // Encode to binary
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try signature.encode(&writer);
    const written_len = writer.buffered().len;

    // Decode from binary
    var reader = std.Io.Reader.fixed(buffer[0..written_len]);
    const decoded = try Signature.decode(&reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqual(signature.alg, decoded.alg);
    try testing.expectEqualSlices(u8, signature.signature, decoded.signature);
    try testing.expectEqualSlices(u8, signature.public_key.?, decoded.public_key.?);

    // Verify decoded signature
    const is_valid = try decoded.verify(message);
    try testing.expect(is_valid);
}

test "GAP-0253: ECDSA P384 signature encoding roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Generate, sign, encode, decode, and verify
    const keypair = try KeyPair.generate(.ECDSA_P384, allocator);
    defer keypair.deinit(allocator);

    const message = "encoding roundtrip test P384";
    const signature = try keypair.sign(message, allocator);
    defer signature.deinit(allocator);

    // Encode to binary
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try signature.encode(&writer);
    const written_len = writer.buffered().len;

    // Decode from binary
    var reader = std.Io.Reader.fixed(buffer[0..written_len]);
    const decoded = try Signature.decode(&reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqual(signature.alg, decoded.alg);
    try testing.expectEqualSlices(u8, signature.signature, decoded.signature);
    try testing.expectEqualSlices(u8, signature.public_key.?, decoded.public_key.?);

    // Verify decoded signature
    const is_valid = try decoded.verify(message);
    try testing.expect(is_valid);
}

test "GAP-0253: ECDSA sign with invalid key sizes returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // P256 with wrong private key size
    const bad_p256 = KeyPair{
        .alg = .ECDSA_P256,
        .private_key = &[_]u8{ 1, 2, 3 }, // Too short
        .public_key = &[_]u8{0} ** 33,
    };
    try testing.expectError(error.InvalidPrivateKeySize, bad_p256.sign("test", allocator));

    // P256 with wrong public key size
    const bad_p256_pub = KeyPair{
        .alg = .ECDSA_P256,
        .private_key = &[_]u8{0} ** 32,
        .public_key = &[_]u8{ 1, 2, 3 }, // Too short
    };
    try testing.expectError(error.InvalidPublicKeySize, bad_p256_pub.sign("test", allocator));

    // P384 with wrong private key size
    const bad_p384 = KeyPair{
        .alg = .ECDSA_P384,
        .private_key = &[_]u8{ 1, 2, 3 }, // Too short
        .public_key = &[_]u8{0} ** 49,
    };
    try testing.expectError(error.InvalidPrivateKeySize, bad_p384.sign("test", allocator));

    // P384 with wrong public key size
    const bad_p384_pub = KeyPair{
        .alg = .ECDSA_P384,
        .private_key = &[_]u8{0} ** 48,
        .public_key = &[_]u8{ 1, 2, 3 }, // Too short
    };
    try testing.expectError(error.InvalidPublicKeySize, bad_p384_pub.sign("test", allocator));
}

test "GAP-0253: ECDSA verify with no public key returns error" {
    const testing = std.testing;

    // Signature without public key should fail verification
    const sig_no_key = Signature{
        .alg = .ECDSA_P256,
        .signature = &[_]u8{0} ** 64,
        .public_key = null,
    };
    try testing.expectError(error.PublicKeyRequired, sig_no_key.verify("test"));
}

test "GAP-0253: ECDSA P256 toString roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const keypair = try KeyPair.generate(.ECDSA_P256, allocator);
    defer keypair.deinit(allocator);

    const signature = try keypair.sign("string roundtrip", allocator);
    defer signature.deinit(allocator);

    // Convert to string
    const sig_str = try signature.toString(allocator);
    defer allocator.free(sig_str);

    // Should start with algorithm prefix
    try testing.expect(std.mem.startsWith(u8, sig_str, "ECDSA-P256:"));

    // Parse back from string
    const parsed = try Signature.fromString(sig_str, allocator);
    defer parsed.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.ECDSA_P256, parsed.alg);
    try testing.expectEqualSlices(u8, signature.signature, parsed.signature);
    try testing.expectEqualSlices(u8, signature.public_key.?, parsed.public_key.?);

    // Verify the parsed signature still works
    const is_valid = try parsed.verify("string roundtrip");
    try testing.expect(is_valid);
}

test "GAP-0253: RSA sign returns UnsupportedSignatureAlgorithm" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // RSA signing should return UnsupportedSignatureAlgorithm
    const rsa_kp = KeyPair{
        .alg = .RSA_PSS_SHA256,
        .private_key = &[_]u8{0} ** 256,
        .public_key = &[_]u8{0} ** 256,
    };
    try testing.expectError(error.UnsupportedSignatureAlgorithm, rsa_kp.sign("test", allocator));

    // RSA verification should also return UnsupportedSignatureAlgorithm
    const rsa_sig = Signature{
        .alg = .RSA_PSS_SHA256,
        .signature = &[_]u8{0} ** 256,
        .public_key = &[_]u8{0} ** 256,
    };
    try testing.expectError(error.UnsupportedSignatureAlgorithm, rsa_sig.verify("test"));
}
