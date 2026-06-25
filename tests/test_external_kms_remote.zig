const std = @import("std");
const kms_remote = @import("../src/security/kms_remote.zig");
const rotation = @import("../src/security/key_rotation.zig");

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate; OWNER=security; UPDATED=2025-09-26

fn sleep(ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}

test "remote kms generate envelope and registry rotateWithRemoteKms" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Start server
    var server = try kms_remote.RemoteKmsServer.init(alloc, 0xDEADBEEF);
    try server.start(8770);
    // Give transport moment to bind
    sleep(50);
    // Client generate
    var client = kms_remote.RemoteKmsClient.init(alloc);
    try client.connect("127.0.0.1", 8770);
    // generate envelope
    const env = try client.generate();
    // basic plausibility
    try std.testing.expect(env.nonce[0] != 0 or env.nonce[1] != 0);

    // Integrate with KeyRegistry rotateWithRemoteKms
    var reg = rotation.KeyRegistry.init(&alloc);
    reg.setRemoteKms("127.0.0.1", 8770);
    const ev = try reg.rotateWithRemoteKms();
    try std.testing.expect(ev.new_id == 1);
    try std.testing.expect(reg.history.items.len == 1);
    try std.testing.expect(reg.history.items[0].is_wrapped);
}
