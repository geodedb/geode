const std = @import("std");
const disk = @import("storage/disk.zig");

fn set_env(k: []const u8, v: []const u8) void {
    std.process.setEnvVarOwned(std.testing.allocator, k, v) catch {};
}

test "disk xts: ciphertext differs by page id and roundtrip ok" {
    set_env("GEODE_DISK_ENCRYPTION", "on");
    set_env("GEODE_DISK_KEY_HEX", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var d = try disk.Disk.init(std.testing.allocator, ":mem:");
    defer d.deinit();

    var p: [4096]u8 = undefined;
    std.crypto.random.bytes(&p);
    var c1 = p;
    var c2 = p;
    d.encryptPage(1, c1[0..]);
    d.encryptPage(2, c2[0..]);
    try std.testing.expect(!std.mem.eql(u8, &c1, &c2));
    d.decryptPage(1, c1[0..]);
    try std.testing.expect(std.mem.eql(u8, &p, &c1));
}
