const std = @import("std");
const keyprov = @import("../src/security/key_provider.zig");
const kms_client = @import("../src/security/external_kms_client.zig");

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26

test "external kms provider basic usage and tamper detection" {
    // Set env to enable provider
    std.os.setenvZ("GEODE_KMS_ENDPOINT", "https://kms.integration.test") catch {};
    std.os.setenvZ("GEODE_KMS_API_KEY", "key-123") catch {};
    const p = keyprov.Provider.init(.ExternalKms);
    const km = (try p.fetch(std.heap.page_allocator)).?;
    // Fetch again and likely different keys (non-deterministic per fetch)
    const km2 = (try p.fetch(std.heap.page_allocator)).?;
    if (std.mem.eql(u8, &km.data_key, &km2.data_key)) {
        std.debug.print("Note: identical data keys across two fetches (rare)\n", .{});
    }

    // Directly test client tamper detection
    var client = kms_client.Client.init(std.heap.page_allocator, 0xAA55AA55AA55AA55);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x42);
    const env = try client.wrap(plain);
    var tampered = env;
    tampered.tag[0] ^= 0x11;
    const res = client.unwrap(tampered);
    try std.testing.expectError(error.AuthenticationFailed, res);
}
