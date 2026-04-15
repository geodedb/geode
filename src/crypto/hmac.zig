const std = @import("std");
const fle = @import("fle_lib");

// HMAC for Blind Index Tokens — thin compatibility layer over external fle library
// CANARY: REQ=REQ-FLE-BI-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/crypto/hmac.zig; OWNER=security; UPDATED=2026-01-15

/// Compute HMAC-SHA256 blind index token — re-exported from fle library
pub const blindIndexHmac256 = fle.hmac.blindIndexHmac256;

/// Normalize value for blind index: ASCII lowercase + trim — re-exported from fle library
pub const normalizeForBlindIndex = fle.hmac.normalizeForBlindIndex;

/// Convert blind index token to hex string (64 chars, lowercase) — re-exported from fle library
pub const tokenToHex = fle.hmac.tokenToHex;

/// Parse hex string back to token — re-exported from fle library
pub const hexToToken = fle.hmac.hexToToken;

test "HMAC-SHA256 RFC 4231 test vector - Jefe" {
    const testing = std.testing;

    const key = "Jefe";
    const msg = "what do ya want for nothing?";

    var out: [32]u8 = undefined;
    blindIndexHmac256(&out, key, msg);

    // Expected: 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
    const expected = [_]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };

    try testing.expectEqualSlices(u8, &expected, &out);
}

test "Normalization for blind index" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const normalized = try normalizeForBlindIndex(allocator, "  Alice@Example.COM  ");
    defer allocator.free(normalized);

    try testing.expectEqualStrings("alice@example.com", normalized);
}

test "Token hex conversion round-trip" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const token = [_]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };

    const hex = try tokenToHex(allocator, token);
    defer allocator.free(hex);

    try testing.expectEqualStrings("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", hex);

    const token2 = try hexToToken(hex);
    try testing.expectEqualSlices(u8, &token, &token2);
}
