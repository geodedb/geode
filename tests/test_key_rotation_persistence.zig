const std = @import("std");
const keyrot = @import("geode").security.key_rotation; // adjust if module path differs

// CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2025-09-26

test "key rotation save/load roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var reg = keyrot.KeyRegistry.init(alloc);
    defer reg.deinit();
    _ = try reg.loadActiveDataKey();
    // Rotate twice to accumulate history
    _ = try reg.rotateNow(.{});
    _ = try reg.rotateNow(.{});
    try std.testing.expect(reg.history.items.len == 3);
    // Persist
    const path = "./tmp_key_rotation_state.json";
    defer std.fs.cwd().deleteFile(path) catch {};
    try reg.saveState(path);
    // New registry, load
    var reg2 = keyrot.KeyRegistry.init(alloc);
    defer reg2.deinit();
    try reg2.loadState(path);
    try std.testing.expect(reg2.history.items.len == 3);
    try std.testing.expect(reg2.active != null);
    const act = reg2.active.?;
    try std.testing.expect(act.id == reg.history.items[reg.history.items.len - 1].id);
    // Ensure material equality for active key
    try std.testing.expect(std.mem.eql(u8, &act.material, &reg.history.items[reg.history.items.len - 1].material));
}

// Edge case: loading nonexistent file should be no-op
// CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_NoFile; OWNER=security; UPDATED=2025-09-26

test "key rotation loadState missing file noop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var reg = keyrot.KeyRegistry.init(alloc);
    defer reg.deinit();
    try reg.loadState("./does_not_exist_rotation_state.json");
    try std.testing.expect(reg.history.items.len == 0);
    try std.testing.expect(reg.active == null);
}
