// SONNY-6465: the Vault Transit and AWS KMS clients
// (src/security/external_kms_client.zig) claimed to work but:
//   1. AWS KMS requests were not SigV4-signed, so real AWS KMS refuses them;
//   2. KmsConfig.tls_ca_cert and tls_skip_verify were ignored (the system CA
//      bundle was always used);
//   3. unwrap ignored the envelope and decrypted the ciphertext of the LAST
//      wrap held in memory, so nothing could be unwrapped after a restart (or
//      any envelope but the last); rotateKey only bumped a local counter;
//   4. the file's inline tests ran in no build step.
// (Item 5 is in the tls dependency and handled on another lane.)
//
// Nothing in the product constructs these clients yet (story SONNY-6380), so
// these tests check what the clients send and accept against the documented
// wire formats, with no network call: the AWS SigV4 signature against the
// published AWS test-suite vector and the documented signing-key example, the
// KMS JSON 1.1 request headers, the Vault/AWS decrypt request built from the
// envelope alone, and refusals that must happen before any request.
// Talking to a live Vault or AWS KMS is not tested here (no service is
// available to the suite); the inline integration tests in the client file
// run only when VAULT_ADDR / AWS_KMS_ENDPOINT name one, and are skipped
// otherwise.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const kms = @import("external_kms_client");

// ---------------------------------------------------------------------------
// 1. SigV4
// ---------------------------------------------------------------------------

// AWS documentation, "Examples of how to derive a signing key for Signature
// Version 4": secret wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY, 20120215,
// us-east-1, iam -> f4780e2d...404d (published value).
test "SONNY-6465 (1) the SigV4 signing key matches the AWS documentation example" {
    const key = try kms.awsSigningKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam");
    const hex = std.fmt.bytesToHex(key, .lower);
    try testing.expectEqualStrings("f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", &hex);
}

// The AWS KMS JSON 1.1 request (POST / with Content-Type
// application/x-amz-json-1.1 and X-Amz-Target) signed for service "kms". The
// SigV4 core (canonical request, string to sign, signing key) is the one
// src/storage/s3_sigv4.zig implements and `zig build test-s3-sigv4` checks
// against the published AWS documentation vectors; the signing key is checked
// against the published example above. The expected signature below was
// computed independently (Python hmac/hashlib from the SigV4 specification),
// not with this code.
test "SONNY-6465 (1) an AWS KMS request is SigV4-signed over content-type, host, x-amz-date and x-amz-target" {
    const config = kms.KmsConfig{
        .backend = .AwsKms,
        .aws_region = "eu-west-1",
        .aws_key_id = "alias/geode",
        .aws_access_key = "AKIDEXAMPLE",
        .aws_secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    };
    const body = "{\"KeyId\":\"alias/geode\"}";
    const auth = try kms.awsKmsAuthorization(testing.allocator, config, "kms.eu-west-1.amazonaws.com", "TrentService.GenerateDataKey", body, "20150830T123600Z");
    defer testing.allocator.free(auth);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/eu-west-1/kms/aws4_request," ++
            "SignedHeaders=content-type;host;x-amz-date;x-amz-target," ++
            "Signature=e9f2ed60e420e823496f11e41b006f06ec7ad2e0938db8f9d569434f84c2eb8e",
        auth,
    );
    // The payload is signed: a different body is a different signature.
    const other = try kms.awsKmsAuthorization(testing.allocator, config, "kms.eu-west-1.amazonaws.com", "TrentService.GenerateDataKey", "{\"KeyId\":\"alias/other\"}", "20150830T123600Z");
    defer testing.allocator.free(other);
    try testing.expect(!std.mem.eql(u8, other, auth));
}

test "SONNY-6465 (1) an AWS KMS client without static credentials is refused before any request" {
    var aws = kms.AwsKmsClient.init(testing.allocator, .{
        .backend = .AwsKms,
        .aws_key_id = "alias/geode",
        // An address nothing listens on: reaching the network would be a
        // connection error, not the refusal.
        .aws_endpoint = "http://127.0.0.1:1",
    });
    defer aws.deinit();
    var key: [32]u8 = undefined;
    @memset(&key, 0x55);
    try testing.expectError(error.AwsCredentialsRequired, aws.wrap(key));
    try testing.expectError(error.AwsCredentialsRequired, aws.generateKey());
}

// ---------------------------------------------------------------------------
// 2. TLS options
// ---------------------------------------------------------------------------

test "SONNY-6465 (2) tls_skip_verify is refused, not ignored" {
    try testing.expectError(error.TlsSkipVerifyUnsupported, kms.kmsHttpClient(testing.allocator, .{ .tls_skip_verify = true }));
    var vault = kms.VaultTransitClient.init(testing.allocator, .{
        .backend = .VaultTransit,
        .vault_addr = "https://127.0.0.1:1",
        .vault_token = "t",
        .vault_key_name = "k",
        .tls_skip_verify = true,
    });
    defer vault.deinit();
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    try testing.expectError(error.TlsSkipVerifyUnsupported, vault.wrap(key));
}

test "SONNY-6465 (2) tls_ca_cert is the only trust anchor; a missing file is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.Io.Threaded.global_single_threaded.io(), &path_buf);
    const dir = path_buf[0..dir_len];
    const key_path = try std.fmt.allocPrint(testing.allocator, "{s}/ca.key", .{dir});
    defer testing.allocator.free(key_path);
    const ca_path = try std.fmt.allocPrint(testing.allocator, "{s}/ca.crt", .{dir});
    defer testing.allocator.free(ca_path);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gen = std.process.run(testing.allocator, io, .{ .argv = &.{ "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key_path, "-out", ca_path, "-days", "2", "-subj", "/CN=sonny6465-kms-ca" } }) catch return error.SkipZigTest;
    testing.allocator.free(gen.stdout);
    testing.allocator.free(gen.stderr);
    if (gen.term != .exited or gen.term.exited != 0) return error.SkipZigTest;

    var client = try kms.kmsHttpClient(testing.allocator, .{ .tls_ca_cert = ca_path });
    defer client.deinit();
    // Exactly the configured CA, and no rescan of the system store.
    try testing.expectEqual(@as(u32, 1), client.ca_bundle.map.count());
    try testing.expect(client.now != null);

    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/missing.crt", .{dir});
    defer testing.allocator.free(missing);
    try testing.expectError(error.KmsCaCertUnreadable, kms.kmsHttpClient(testing.allocator, .{ .tls_ca_cert = missing }));
}

// ---------------------------------------------------------------------------
// 3. unwrap from the envelope; rotation
// ---------------------------------------------------------------------------

const vault_config = kms.KmsConfig{
    .backend = .VaultTransit,
    .vault_addr = "http://127.0.0.1:1",
    .vault_token = "t",
    .vault_key_name = "geode-key",
};

test "SONNY-6465 (3) a Vault envelope carries its ciphertext: a fresh client builds the decrypt request from it" {
    // The envelope as `wrap` builds it from Vault's encrypt response.
    var env = try kms.vaultEnvelope(testing.allocator, "geode-key", "vault:v3:AbCdEf0123456789+/==");
    defer env.deinitKmsCiphertext(testing.allocator);
    try testing.expectEqual(@as(u8, 3), env.version);
    try testing.expectEqualStrings("VAULT-TRANSIT", env.alg);

    // A client that never wrapped anything (a restarted process) asks Vault
    // to decrypt exactly that ciphertext.
    const body = try kms.vaultDecryptRequestBody(testing.allocator, env);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"ciphertext\":\"vault:v3:AbCdEf0123456789+/==\"}", body);

    // The envelope survives its JSON form with the ciphertext.
    const json = try kms.envelopeToJson(env, testing.allocator);
    defer testing.allocator.free(json);
    const back = try kms.envelopeFromJson(json);
    try testing.expectEqualStrings(env.kms_ciphertext, back.kms_ciphertext);
    const body2 = try kms.vaultDecryptRequestBody(testing.allocator, back);
    defer testing.allocator.free(body2);
    try testing.expectEqualStrings(body, body2);
}

test "SONNY-6465 (3) an envelope without its ciphertext, or with a different one, is refused before any request" {
    var vault = kms.VaultTransitClient.init(testing.allocator, vault_config);
    defer vault.deinit();
    var env = try kms.vaultEnvelope(testing.allocator, "geode-key", "vault:v1:AAAA");
    defer env.deinitKmsCiphertext(testing.allocator);

    var bare = env;
    bare.kms_ciphertext = "";
    try testing.expectError(error.MissingKmsCiphertext, vault.unwrap(bare));

    var swapped = env;
    swapped.kms_ciphertext = "vault:v1:BBBB";
    try testing.expectError(error.EnvelopeCiphertextMismatch, vault.unwrap(swapped));

    // A malformed Vault ciphertext is not accepted into an envelope.
    try testing.expectError(error.InvalidVaultCiphertext, kms.vaultEnvelope(testing.allocator, "geode-key", "not-vault"));
    try testing.expectError(error.InvalidVaultCiphertext, kms.vaultEnvelope(testing.allocator, "geode-key", "vault:v1:a\"b"));
}

test "SONNY-6465 (3) an AWS envelope carries its CiphertextBlob and the Decrypt request is built from it" {
    var env = try kms.awsEnvelope(testing.allocator, "alias/geode", "AQIDAHhBlobBase64==");
    defer env.deinitKmsCiphertext(testing.allocator);
    const body = try kms.awsDecryptRequestBody(testing.allocator, "alias/geode", env);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"CiphertextBlob\":\"AQIDAHhBlobBase64==\",\"KeyId\":\"alias/geode\"}", body);

    var aws = kms.AwsKmsClient.init(testing.allocator, .{
        .backend = .AwsKms,
        .aws_key_id = "alias/geode",
        .aws_endpoint = "http://127.0.0.1:1",
        .aws_access_key = "AKIDEXAMPLE",
        .aws_secret_key = "secret",
    });
    defer aws.deinit();
    var swapped = env;
    swapped.kms_ciphertext = "AQIDAHhOtherBlob==";
    try testing.expectError(error.EnvelopeCiphertextMismatch, aws.unwrap(swapped));
    var bare = env;
    bare.kms_ciphertext = "";
    try testing.expectError(error.MissingKmsCiphertext, aws.unwrap(bare));
}

test "SONNY-6465 (3) AWS rotateKey refuses instead of pretending; no local version counter moves" {
    var aws = kms.AwsKmsClient.init(testing.allocator, .{ .backend = .AwsKms, .aws_key_id = "alias/geode" });
    defer aws.deinit();
    const before = try aws.getKeyVersion();
    try testing.expectError(error.AwsKmsRotationIsManagedByAws, aws.rotateKey());
    try testing.expectEqual(before, try aws.getKeyVersion());
}
