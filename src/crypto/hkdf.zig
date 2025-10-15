const std = @import("std");

// CANARY: FLE_CRYPTO_PRIMITIVES - HKDF Key Derivation
// CANARY: REQ=REQ-FLE-HKDF-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

/// HKDF-SHA256 key derivation
/// Based on RFC 5869
pub fn hkdfSha256(
    out: []u8,
    ikm: []const u8, // Input Keying Material
    salt: []const u8,
    info: []const u8,
) !void {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

    // Extract: PRK = HMAC-SHA256(salt, IKM)
    var prk: [32]u8 = undefined;
    var extract_hmac = Hmac.init(salt);
    extract_hmac.update(ikm);
    extract_hmac.final(&prk);
    defer std.crypto.secureZero(u8, &prk);

    // Expand: OKM = T(1) || T(2) || ... || T(N)
    // T(0) = empty string (zero length)
    // T(1) = HMAC-Hash(PRK, T(0) || info || 0x01)
    // T(2) = HMAC-Hash(PRK, T(1) || info || 0x02)
    // ...
    var okm_pos: usize = 0;
    var counter: u8 = 1;
    var t_prev: [32]u8 = undefined;
    var t_prev_len: usize = 0;

    while (okm_pos < out.len) {
        var expand_hmac = Hmac.init(&prk);

        if (counter > 1) {
            expand_hmac.update(t_prev[0..t_prev_len]);
        }

        expand_hmac.update(info);
        expand_hmac.update(&[_]u8{counter});

        var t: [32]u8 = undefined;
        expand_hmac.final(&t);

        const copy_len = @min(32, out.len - okm_pos);
        @memcpy(out[okm_pos .. okm_pos + copy_len], t[0..copy_len]);

        @memcpy(&t_prev, &t);
        t_prev_len = 32;
        okm_pos += copy_len;
        counter += 1;

        if (counter == 0) return error.HkdfOutputTooLong; // Wrapped after 255
    }
}

/// Derive a 32-byte key from master with context info
pub fn deriveKey32(
    master: []const u8,
    salt: []const u8,
    context: []const u8,
) ![32]u8 {
    var out: [32]u8 = undefined;
    try hkdfSha256(&out, master, salt, context);
    return out;
}

/// Derive TRK (Tenant Root Key) from master
pub fn deriveTRK(master: []const u8, tenant_id: []const u8) ![32]u8 {
    var context_buf: [256]u8 = undefined;
    const context = try std.fmt.bufPrint(&context_buf, "geode/trk/{s}", .{tenant_id});
    return deriveKey32(master, "geode-fle-salt", context);
}

/// Derive SK (Schema Key) from TRK
pub fn deriveSK(trk: []const u8, schema: []const u8) ![32]u8 {
    var context_buf: [256]u8 = undefined;
    const context = try std.fmt.bufPrint(&context_buf, "geode/sk/{s}", .{schema});
    return deriveKey32(trk, "geode-fle-salt", context);
}

/// Derive FEK (Field Encryption Key) from SK
pub fn deriveFEK(sk: []const u8, field: []const u8) ![32]u8 {
    var context_buf: [256]u8 = undefined;
    const context = try std.fmt.bufPrint(&context_buf, "geode/fek/{s}", .{field});
    return deriveKey32(sk, "geode-fle-salt", context);
}

/// Derive BIK (Blind Index Key) from SK
pub fn deriveBIK(sk: []const u8, field: []const u8) ![32]u8 {
    var context_buf: [256]u8 = undefined;
    const context = try std.fmt.bufPrint(&context_buf, "geode/bi/{s}", .{field});
    return deriveKey32(sk, "geode-fle-salt", context);
}

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
