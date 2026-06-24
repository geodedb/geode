const std = @import("std");
const cb = @import("crypto_backend");

// secure_mem.zig
// Utilities for explicit secret zeroization and audit.
// CANARY: REQ=REQ-GQL-SEC-ZEROIZE-001; FEATURE="SecretsZeroization"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_ZEROIZE_001_Basic; OWNER=security; UPDATED=2025-09-26

pub fn wipe(buf: []u8) void {
    // SEC-11: Route through FIPS seam for optimizer-resistant zeroing.
    cb.secureZero(buf);
}

pub fn wipeStruct(comptime T: type, val: *T) void {
    const bytes = std.mem.asBytes(val);
    wipe(bytes);
}

test "TestCANARY_REQ_GQL_SEC_ZEROIZE_001_Basic" {
    var data: [32]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i * 7 + 3);
    wipe(data[0..]);
    for (data) |b| std.testing.expect(b == 0) catch @panic("expected zero");
}
