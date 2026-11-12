const std = @import("std");

test "kms: no bare @memset (GAP-0499)" {
    const src = @embedFile("kms.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "@memset") == null);
}

test "tde_nonce_gen: no bare @memset (GAP-0499)" {
    const src = @embedFile("tde_nonce_gen.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "@memset") == null);
}
