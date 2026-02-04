const std = @import("std");
const tde = @import("tde_hierarchy");

test "TestCANARY_REQ_GQL_046_KeyHierarchy" {
    // Deterministic master key (hex: 00..1f)
    var master: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) master[i] = @as(u8, @intCast(i));

    var kh1 = tde.KeyHierarchy.init(master);
    try std.testing.expect(!std.mem.eql(u8, &kh1.master, &kh1.data_key));
    try std.testing.expect(!std.mem.eql(u8, &kh1.master, &kh1.backup_key));
    try std.testing.expect(!std.mem.eql(u8, &kh1.data_key, &kh1.backup_key));

    // Re-derive should be deterministic.
    var kh2 = tde.KeyHierarchy.init(master);
    try std.testing.expect(std.mem.eql(u8, &kh1.data_key, &kh2.data_key));
    try std.testing.expect(std.mem.eql(u8, &kh1.backup_key, &kh2.backup_key));

    // Simulate rotation: different master produces different child keys.
    var rotated_master: [32]u8 = undefined;
    i = 0;
    while (i < 32) : (i += 1) rotated_master[i] = @as(u8, @intCast(255 - i));
    var kh_rot = tde.KeyHierarchy.init(rotated_master);
    try std.testing.expect(!std.mem.eql(u8, &kh1.data_key, &kh_rot.data_key));
    try std.testing.expect(!std.mem.eql(u8, &kh1.backup_key, &kh_rot.backup_key));

    // Child keys still 32 bytes.
    try std.testing.expect(kh1.data_key.len == 32);
    try std.testing.expect(kh1.backup_key.len == 32);
}
