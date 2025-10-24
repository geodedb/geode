const std = @import("std");
const keyrot = @import("../src/security/key_rotation.zig");

// CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-CHK-001; FEATURE="KeyRotationStateChecksum"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_CHK_001; OWNER=security; UPDATED=2025-09-26

test "rotation state checksum verifies integrity and rejects tamper" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var reg = keyrot.KeyRegistry.init(alloc);
    defer reg.deinit();
    _ = try reg.loadActiveDataKey();
    // rotate to add second key for non-trivial checksum
    _ = try reg.rotateNow(.{});
    const path = "rotation_state_test.json";
    try reg.saveState(path);

    // Load into fresh registry (should succeed)
    var reg2 = keyrot.KeyRegistry.init(alloc);
    defer reg2.deinit();
    try reg2.loadState(path);
    try std.testing.expect(reg2.active != null);
    try std.testing.expect(reg2.history.items.len == reg.history.items.len);

    // Tamper file (flip a byte in material hex) and expect load to clear state
    var file = try std.fs.cwd().openFile(path, .{ .read = true, .write = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = try file.read(&buf);
    var pos: usize = 0;
    while (pos + 1 < n) : (pos += 1) {
        if (buf[pos] == 'a') {
            buf[pos] = 'b';
            break;
        }
    }
    try file.seekTo(0);
    _ = try file.write(buf[0..n]);

    var reg3 = keyrot.KeyRegistry.init(alloc);
    defer reg3.deinit();
    try reg3.loadState(path);
    try std.testing.expect(reg3.active == null);
    try std.testing.expect(reg3.history.items.len == 0);

    _ = std.fs.cwd().deleteFile(path) catch {};
}
