const std = @import("std");
const kms_client = @import("../src/security/external_kms_client.zig");

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26

test "external kms client tamper detection" {
    var client = kms_client.Client.init(std.heap.page_allocator, 0xAA55AA55AA55AA55);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x42);
    const env = try client.wrap(plain);
    var tampered = env;
    tampered.tag[0] ^= 0x11;
    const res = client.unwrap(tampered);
    try std.testing.expectError(error.AuthenticationFailed, res);
}
