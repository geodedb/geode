// SONNY-6457 item 4: the Vault Transit and AWS KMS clients in
// src/security/external_kms_client.zig compile.
//
// Nothing in the product constructs them yet (KMS wiring is story
// SONNY-6380), so no build ever analysed their HTTP code, and it had rotted:
// `std.http.Client{ .allocator = ... }` with no `.io`, and the pre-0.15
// `client.open` / `request.write` / `finish` / `wait` / `reader` API. This
// step forces analysis of every network-facing entry point, so the clients
// cannot stop compiling again unnoticed. No network call is made.

const std = @import("std");
const kms = @import("external_kms_client");

comptime {
    _ = &kms.VaultTransitClient.wrap;
    _ = &kms.VaultTransitClient.unwrap;
    _ = &kms.VaultTransitClient.rotateKey;
    _ = &kms.VaultTransitClient.toProvider;
    _ = &kms.AwsKmsClient.wrap;
    _ = &kms.AwsKmsClient.unwrap;
    _ = &kms.AwsKmsClient.generateKey;
    _ = &kms.AwsKmsClient.toProvider;
    _ = &kms.createKmsProvider;
}

test "SONNY-6457: the Vault and AWS KMS clients refuse an incomplete configuration before any request" {
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    var vault = kms.VaultTransitClient.init(std.testing.allocator, .{ .backend = .VaultTransit });
    defer vault.deinit();
    try std.testing.expectError(error.InvalidConfiguration, vault.wrap(key));
    try std.testing.expectError(error.InvalidConfiguration, vault.rotateKey());
    var aws = kms.AwsKmsClient.init(std.testing.allocator, .{ .backend = .AwsKms });
    defer aws.deinit();
    try std.testing.expectError(error.InvalidConfiguration, aws.wrap(key));
    try std.testing.expectError(error.InvalidConfiguration, aws.generateKey());
}
