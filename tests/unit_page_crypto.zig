const std = @import("std");
const disk = @import("../src/storage/disk.zig");
const iface = @import("../src/storage/interface.zig");

test "disk crypto: roundtrip" {
    // set env: GEODE_DISK_ENCRYPTION=on and a fixed key
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_ENCRYPTION", "on") catch {};
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_KEY_HEX", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") catch {};
    var d = try disk.Disk.init(std.testing.allocator, ":mem:");
    defer d.deinit();
    var page: [4096]u8 = undefined;
    std.crypto.random.bytes(&page);
    var c = page;
    d.encryptPage(1, c[0..]);
    d.decryptPage(1, c[0..]);
    try std.testing.expect(std.mem.eql(u8, &page, &c));
}

test "disk crypto: tweak changes ciphertext" {
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_ENCRYPTION", "on") catch {};
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_KEY_HEX", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") catch {};
    var d = try disk.Disk.init(std.testing.allocator, ":mem:");
    defer d.deinit();
    var page: [4096]u8 = undefined;
    std.crypto.random.bytes(&page);
    var c1 = page;
    var c2 = page;
    d.encryptPage(1, c1[0..]);
    d.encryptPage(2, c2[0..]);
    try std.testing.expect(!std.mem.eql(u8, &c1, &c2));
}
