const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
const fle = @import("fle_lib");

// Blind Index for Searchable Encrypted Fields — thin compatibility layer over external fle library
// CANARY: REQ=REQ-FLE-BI-002; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

/// Blind index token type (re-exported from fle library)
pub const BlindIndexToken = fle.blind_index.BlindIndexToken;

/// Blind index for encrypted field equality search (re-exported from fle library)
/// Maps HMAC(BIK, normalize(plaintext)) -> [record_ids]
pub const BlindIndex = fle.blind_index.BlindIndex;

test "BlindIndex put and lookup" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    // fips-exempt: non-security test-only BIK (would use cb.Csprng in prod key-derivation path)
    compat_fillRandom(&bik);

    // Index two records with same email
    try index.put("Person", "email", bik, "alice@example.com", "person1");
    try index.put("Person", "email", bik, "alice@example.com", "person2");
    try index.put("Person", "email", bik, "bob@example.com", "person3");

    // Lookup Alice's email
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 2), results.?.len);

    // Lookup Bob's email
    const results2 = try index.lookup("Person", "email", bik, "bob@example.com");
    try testing.expect(results2 != null);
    try testing.expectEqual(@as(usize, 1), results2.?.len);
    try testing.expectEqualStrings("person3", results2.?[0]);

    // Lookup non-existent email
    const results3 = try index.lookup("Person", "email", bik, "charlie@example.com");
    try testing.expect(results3 == null);
}

test "BlindIndex normalization handles case and whitespace" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    // fips-exempt: non-security test-only BIK (would use cb.Csprng in prod key-derivation path)
    compat_fillRandom(&bik);

    // Index with different casing/whitespace
    try index.put("Person", "email", bik, "  Alice@EXAMPLE.com  ", "person1");

    // Lookup with different format - should still match
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 1), results.?.len);
    try testing.expectEqualStrings("person1", results.?[0]);
}

test "BlindIndex remove" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    // fips-exempt: non-security test-only BIK (would use cb.Csprng in prod key-derivation path)
    compat_fillRandom(&bik);

    try index.put("Person", "email", bik, "alice@example.com", "person1");
    try index.put("Person", "email", bik, "alice@example.com", "person2");

    // Remove one record
    try index.remove("Person", "email", "person1");

    // Should only have person2 now
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 1), results.?.len);
    try testing.expectEqualStrings("person2", results.?[0]);
}
