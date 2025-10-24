const std = @import("std");
const keyrot = @import("geode").security.key_rotation; // adjust if module path differs

// CANARY: REQ=REQ-GQL-SEC-KEYROT-002; FEATURE="KeyRotationScheduling"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_002_Schedule; OWNER=security; UPDATED=2025-09-26

test "key rotation schedule triggers after min interval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var reg = keyrot.KeyRegistry.init(alloc);
    defer reg.deinit();
    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 10, .max_age_secs = 100, .lazy_reencrypt = true };
    const k = try reg.loadActiveDataKey();
    // Before interval
    try std.testing.expect(!reg.scheduleRotation(policy, k.created_unix_epoch + 5));
    // After min interval
    try std.testing.expect(reg.scheduleRotation(policy, k.created_unix_epoch + 11));
}
