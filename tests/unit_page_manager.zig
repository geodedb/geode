const std = @import("std");
const tde = @import("../src/storage/tde_file_encryption.zig");

test "tde encrypt/decrypt roundtrip with deterministic key" {
    const allocator = std.testing.allocator;

    var key: [tde.KEY_BYTES]u8 = undefined;
    for (key, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    const plaintext1 = "payload-one";
    const plaintext2 = "payload-two";

    const enc1 = try tde.encryptWithKey(allocator, plaintext1, key);
    defer allocator.free(enc1);
    const enc2 = try tde.encryptWithKey(allocator, plaintext2, key);
    defer allocator.free(enc2);

    try std.testing.expect(tde.isEncrypted(enc1));
    try std.testing.expect(tde.isEncrypted(enc2));
    try std.testing.expect(!std.mem.eql(u8, enc1, enc2));

    const dec1 = try tde.decryptWithKey(allocator, enc1, key);
    defer allocator.free(dec1);
    const dec2 = try tde.decryptWithKey(allocator, enc2, key);
    defer allocator.free(dec2);

    try std.testing.expectEqualStrings(plaintext1, dec1);
    try std.testing.expectEqualStrings(plaintext2, dec2);
}
