// External KMS client envelope wrap/unwrap and tamper detection.
//
// SONNY-6320: this file sat in no build step (it imported `../src/...` from
// outside its module root and used the removed std.os.setenvZ). Ported to
// the live `external_kms_client` module; the provider-from-environment half
// is covered by src/security/key_provider.zig's inline tests.
//
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_external_kms_provider.zig; OWNER=security; UPDATED=2026-11-12
const std = @import("std");
const kms_client = @import("external_kms_client");

const testing = std.testing;

test "external kms client: an envelope unwraps to the data key it wrapped" {
    var client = try kms_client.Client.init(testing.allocator, 0xAA55AA55AA55AA55);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x42);
    const env = try client.wrap(plain);
    try testing.expect(!std.mem.eql(u8, &env.ct, &plain));
    const back = try client.unwrap(env);
    try testing.expectEqualSlices(u8, &plain, &back);
}

test "external kms client: a tampered tag, ciphertext or nonce is refused" {
    var client = try kms_client.Client.init(testing.allocator, 0xAA55AA55AA55AA55);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x42);
    const env = try client.wrap(plain);

    var bad_tag = env;
    bad_tag.tag[0] ^= 0x11;
    try testing.expectError(error.AuthFailed, client.unwrap(bad_tag));

    var bad_ct = env;
    bad_ct.ct[31] ^= 0x01;
    try testing.expectError(error.AuthFailed, client.unwrap(bad_ct));

    var bad_nonce = env;
    bad_nonce.nonce[0] ^= 0x80;
    try testing.expectError(error.AuthFailed, client.unwrap(bad_nonce));

    var bad_version = env;
    bad_version.version = 2;
    try testing.expectError(error.UnsupportedEnvelopeVersion, client.unwrap(bad_version));
}

test "external kms client: another key encryption key cannot unwrap the envelope" {
    var a = try kms_client.Client.init(testing.allocator, 1);
    var b = try kms_client.Client.init(testing.allocator, 2);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x07);
    const env = try a.wrap(plain);
    try testing.expectError(error.AuthFailed, b.unwrap(env));
}
