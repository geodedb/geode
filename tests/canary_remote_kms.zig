const std = @import("std");
const quic = @import("transport/quic");
// kms_remote exposed via build.zig module alias added below (security/kms_remote)
const kms = @import("security/kms_remote");

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_AttestationStub; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap; OWNER=security; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var server = kms.RemoteKmsServer.init(gpa.allocator(), 0xBEEFCAFE);
    try server.start(8876);
    server.server.setAuthToken("TOKEN123");

    // Spawn a thread to process a few requests sequentially
    var t = try std.Thread.spawn(.{}, struct {
        fn run(s: *kms.RemoteKmsServer) void {
            s.serveLoop(5) catch {};
        }
    }.run, .{&server});
    defer t.join();

    var client = kms.RemoteKmsClient.init(gpa.allocator());
    try client.connect("127.0.0.1", 8876);
    const env = try client.generate();
    _ = env; // For now just ensure parse succeeded
}

test "TestCANARY_REQ_GQL_TDE_ATTEST_001_AttestationStub" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var server = kms.RemoteKmsServer.init(gpa.allocator(), 0xABCD1234);
    try server.start(8877);
    server.server.setAuthToken("TOKEN123");
    var t = try std.Thread.spawn(.{}, struct {
        fn run(s: *kms.RemoteKmsServer) void {
            s.serveLoop(3) catch {};
        }
    }.run, .{&server});
    defer t.join();
    var client = kms.RemoteKmsClient.init(gpa.allocator());
    try client.connect("127.0.0.1", 8877);
    const hash = try client.attest();
    try std.testing.expect(hash.len == 32);
}

test "TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var server = kms.RemoteKmsServer.init(gpa.allocator(), 0x11223344);
    try server.start(8878);
    server.server.setAuthToken("TOKEN123");
    var t = try std.Thread.spawn(.{}, struct {
        fn run(s: *kms.RemoteKmsServer) void {
            s.serveLoop(10) catch {};
        }
    }.run, .{&server});
    defer t.join();
    var client = kms.RemoteKmsClient.init(gpa.allocator());
    try client.connect("127.0.0.1", 8878);
    const env = try client.generate();
    const plain = try client.privUnwrap(env);
    // quick sanity: privUnwrap returns 32-byte key
    try std.testing.expect(plain.len == 32);
}
