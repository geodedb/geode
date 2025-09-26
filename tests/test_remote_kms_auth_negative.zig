const std = @import("std");
const kms = @import("security/kms_remote");
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSAuthGuard"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_AuthNegative; OWNER=security; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_AuthNegative" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var server = kms.RemoteKmsServer.init(alloc, 0xABCDEF01);
    try server.start(44555);
    server.server.setAuthToken("secret-token");

    var client = kms.RemoteKmsClient.init(alloc);
    try client.connect("127.0.0.1", 44555);
    // Attempt generate without auth token should fail (InvalidResponse due to auth error)
    const gen_result = client.generate();
    try std.testing.expectError(error.InvalidResponse, gen_result);

    // Set token, now should succeed
    client.setAuthToken("secret-token");
    const env = try client.generate();
    _ = try client.unwrap(env);
}
