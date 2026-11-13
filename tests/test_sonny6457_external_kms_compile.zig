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

// Response bodies below are the shapes the Vault Transit HTTP API documents
// (https://developer.hashicorp.com/vault/api-docs/secret/transit: "Encrypt
// data", "Decrypt data"), inside Vault's standard response envelope, and the
// AWS KMS Encrypt / GenerateDataKey response syntax
// (https://docs.aws.amazon.com/kms/latest/APIReference/API_Encrypt.html).

const vault_encrypt_response =
    \\{
    \\  "request_id": "c2b4a1f0-6f4c-6a8e-2b1e-3c6f5d1f7a9e",
    \\  "lease_id": "",
    \\  "renewable": false,
    \\  "lease_duration": 0,
    \\  "data": {
    \\    "ciphertext": "vault:v1:abcdefgh",
    \\    "key_version": 1
    \\  },
    \\  "wrap_info": null,
    \\  "warnings": null,
    \\  "auth": null,
    \\  "mount_type": "transit"
    \\}
;

const vault_decrypt_response =
    \\{"request_id":"9f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b","lease_id":"","renewable":false,"lease_duration":0,"data":{"plaintext":"dGhlIHF1aWNrIGJyb3duIGZveAo="},"wrap_info":null,"warnings":null,"auth":null,"mount_type":"transit"}
;

const vault_error_response =
    \\{"errors":["1 error occurred:\n\t* permission denied\n\n"]}
;

const aws_encrypt_response =
    \\{"CiphertextBlob":"AQICAHhdvTNgAAAAfjB8BgkqhkiG9w0BBwagbzBtAgEAMGgGCSqGSIb3DQEHATAeBglghkgBZQMEAS4wEQQM","EncryptionAlgorithm":"SYMMETRIC_DEFAULT","KeyId":"arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"}
;

test "SONNY-6457: Vault Transit responses are parsed from the documented JSON shape" {
    const a = std.testing.allocator;
    const ct = try kms.jsonStringField(a, vault_encrypt_response, "data", "ciphertext");
    defer a.free(ct);
    try std.testing.expectEqualStrings("vault:v1:abcdefgh", ct);
    const pt = try kms.jsonStringField(a, vault_decrypt_response, "data", "plaintext");
    defer a.free(pt);
    try std.testing.expectEqualStrings("dGhlIHF1aWNrIGJyb3duIGZveAo=", pt);

    // An error body, a missing field, a non-string value and non-JSON are
    // refused, never read as an empty ciphertext.
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a, vault_error_response, "data", "ciphertext"));
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a, vault_encrypt_response, "data", "plaintext"));
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a, vault_encrypt_response, "data", "key_version"));
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a, "<html>bad gateway</html>", "data", "ciphertext"));
    // A field name inside a string value is not a field.
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a,
        \\{"data":{"note":"\"ciphertext\":\"vault:v1:forged\""}}
    , "data", "ciphertext"));
}

test "SONNY-6457: AWS KMS responses are parsed from the documented JSON shape" {
    const a = std.testing.allocator;
    const blob = try kms.jsonStringField(a, aws_encrypt_response, null, "CiphertextBlob");
    defer a.free(blob);
    try std.testing.expect(std.mem.startsWith(u8, blob, "AQICAHhdvTNg"));
    try std.testing.expectError(error.InvalidResponse, kms.jsonStringField(a, aws_encrypt_response, null, "Plaintext"));
}

test "SONNY-6457: Vault Transit requests are built as the API documents" {
    var url_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://vault.example:8200/v1/transit/encrypt/geode-tde",
        try kms.vaultTransitUrl(&url_buf, "https://vault.example:8200", "encrypt", "geode-tde"),
    );
    try std.testing.expectEqualStrings(
        "https://vault.example:8200/v1/transit/decrypt/geode-tde",
        try kms.vaultTransitUrl(&url_buf, "https://vault.example:8200/", "decrypt", "geode-tde"),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.BufferOverflow, kms.vaultTransitUrl(&tiny, "https://vault.example:8200", "encrypt", "k"));

    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    var body_buf: [128]u8 = undefined;
    const body = try kms.vaultEncryptRequestBody(&body_buf, key);
    try std.testing.expectEqualStrings("{\"plaintext\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\"}", body);

    var hb: [2]std.http.Header = undefined;
    const plain = kms.vaultHeaders(&hb, .{ .vault_token = "s.token" });
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("X-Vault-Token", plain[0].name);
    try std.testing.expectEqualStrings("s.token", plain[0].value);
    const ns = kms.vaultHeaders(&hb, .{ .vault_token = "s.token", .vault_namespace = "team-a" });
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqualStrings("X-Vault-Namespace", ns[1].name);
    try std.testing.expectEqualStrings("team-a", ns[1].value);
}
