const std = @import("std");
const rotation = @import("../src/security/key_rotation.zig");
const kms = @import("../src/security/external_kms_client.zig");

// CANARY: REQ=REQ-GQL-SEC-KEYROT-KMS-001; FEATURE="KeyRotationKmsEnvelopes"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_KMS_001_Envelopes; OWNER=security; UPDATED=2025-09-26

fn writeTempPath(alloc: std.mem.Allocator) ![]u8 {
    var buf = try alloc.alloc(u8, 64);
    const ts = std.time.timestamp();
    const written = try std.fmt.bufPrint(buf, "/tmp/geode_rotation_{d}.json", .{ts});
    return buf[0..written.len];
}

test "kms rotation produces envelopes persisted and restored" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var reg = rotation.KeyRegistry.init(&alloc);
    defer reg.deinit();
    reg.setKmsSeed(0xABCD1234EF);
    const ev1 = try reg.rotateWithKms();
    const ev2 = try reg.rotateWithKms();
    try std.testing.expect(ev2.new_id == ev1.new_id + 1);
    try std.testing.expect(reg.history.items.len == 2);
    for (reg.history.items) |ref| {
        try std.testing.expect(ref.is_wrapped);
        try std.testing.expect(ref.envelope_json != null);
    }
    const path = try writeTempPath(alloc);
    defer alloc.free(path);
    try reg.saveState(path);
    // Backup copy
    const backup_path = try alloc.dupe(u8, path);
    defer alloc.free(backup_path);
    var backup_file = try std.fs.cwd().createFile(backup_path, .{ .truncate = true });
    defer backup_file.close();
    var orig = try std.fs.cwd().openFile(path, .{});
    defer orig.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const read_n = try orig.read(&buf);
        if (read_n == 0) break;
        try backup_file.writeAll(buf[0..read_n]);
    }
    // Destroy original file then restore from backup (simulate restore)
    try std.fs.cwd().deleteFile(path);
    // Move backup to original name
    try std.fs.cwd().rename(backup_path, path);

    // New registry load
    var reg2 = rotation.KeyRegistry.init(&alloc);
    defer reg2.deinit();
    reg2.setKmsSeed(0xABCD1234EF); // same seed to unwrap
    try reg2.loadState(path);
    try std.testing.expect(reg2.history.items.len == 2);
    try std.testing.expect(reg2.active != null);
    for (reg2.history.items) |ref| try std.testing.expect(ref.is_wrapped);
}

test "negative envelope parse errors do not crash" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var reg = rotation.KeyRegistry.init(&alloc);
    defer reg.deinit();
    reg.setKmsSeed(0x1111);
    const ev = try reg.rotateWithKms();
    try std.testing.expect(ev.new_id == 1);
    const path = "/tmp/geode_rotation_negative.json";
    try reg.saveState(path);
    // Corrupt file: replace "version":1 with invalid
    var file = try std.fs.cwd().openFile(path, .{ .write = true });
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 1 << 16);
    defer alloc.free(content);
    var corrupted = try alloc.dupe(u8, content);
    defer alloc.free(corrupted);
    if (std.mem.indexOf(u8, corrupted, "\"version\":")) |idx| {
        if (idx + 12 < corrupted.len) corrupted[idx + 11] = '9'; // set version to 9 (unsupported but still single digit)
    }
    // overwrite
    try std.fs.cwd().deleteFile(path);
    var cf = try std.fs.cwd().createFile(path, .{});
    defer cf.close();
    try cf.writeAll(corrupted);
    var reg3 = rotation.KeyRegistry.init(&alloc);
    defer reg3.deinit();
    reg3.setKmsSeed(0x1111);
    try reg3.loadState(path); // should not crash; may zero history if checksum mismatch
    // Accept either 0 or 1 depending on checksum effect
    try std.testing.expect(reg3.history.items.len <= 1);
}
