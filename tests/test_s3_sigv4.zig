// GAP-0885d: SEC-S3-SIGV2-01 + SEC-CLI-01 regression tests.
//
// Part 1 — AWS Signature Version 4 known-answer tests (KATs) against the
// published AWS documentation vectors ("Signature Calculations for the
// Authorization Header: Transferring Payload in a Single Chunk (AWS
// Signature Version 4)"). All vectors share:
//   access key  AKIAIOSFODNN7EXAMPLE
//   secret key  wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
//   region      us-east-1, service s3, date 20130524T000000Z
// The signer MUST reproduce the exact published signatures — this is what
// replaces the legacy SigV2 (HMAC-SHA1) signing in src/storage/s3_backup.zig.
//
// Part 2 — SEC-CLI-01: the `--insecure-tls-skip-verify` CLI flag is gated
// behind GEODE_ALLOW_INSECURE_TLS=1 under production posture (release build
// OR GEODE_ENV=production), mirroring the GAP-0850 --insecure-allow-all
// startup guard. The pure policy function is tested here.
//
// CANARY: REQ=REQ-SEC-S3-SIGV4-001; FEATURE="S3 SigV4 Signing"; ASPECT=KAT; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=security; UPDATED=2026-06-10
// CANARY: REQ=REQ-SEC-CLI-INSECURE-TLS-GATE-001; FEATURE="InsecureTlsFlagGate"; ASPECT=Policy; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const testing = std.testing;
const sigv4 = @import("s3_sigv4");
const gate = @import("insecure_tls_gate");
const s3_backup = @import("s3_backup");

const access_key = "AKIAIOSFODNN7EXAMPLE";
const secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const amz_date = "20130524T000000Z";

// Force full semantic analysis of the modernized s3_backup module so the
// S3BackupManager (and its SigV4 request signing path) stays compiled —
// the module was previously orphaned dead code that silently rotted.
comptime {
    _ = s3_backup;
}

test "s3_backup module exposes SigV4-signed manager" {
    std.testing.refAllDecls(s3_backup);
    // The S3Config plumbing (endpoint/credentials) must be preserved.
    const cfg = s3_backup.S3Config{
        .bucket = "examplebucket",
        .prefix = "backups",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    };
    try testing.expectEqualStrings("us-east-1", cfg.region);
    try testing.expect(cfg.use_ssl);
}

// AWS docs example 1: GET /test.txt (empty payload, Range header).
// Published canonical-request hash and final signature.
test "SigV4 KAT: GET object (AWS docs example)" {
    const allocator = testing.allocator;

    const headers = [_]sigv4.Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "Range", .value = "bytes=0-9" },
        .{ .name = "x-amz-content-sha256", .value = sigv4.empty_payload_hash_hex },
        .{ .name = "x-amz-date", .value = amz_date },
    };

    const input = sigv4.SignInput{
        .method = "GET",
        .canonical_uri = "/test.txt",
        .canonical_query = "",
        .headers = &headers,
        .payload_hash_hex = sigv4.empty_payload_hash_hex,
        .amz_date = amz_date,
        .region = "us-east-1",
        .service = "s3",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    };

    // Canonical request must hash to the published value.
    const cr = try sigv4.buildCanonicalRequest(allocator, input);
    defer allocator.free(cr);
    var cr_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cr, &cr_hash, .{});
    const cr_hex = std.fmt.bytesToHex(cr_hash, .lower);
    try testing.expectEqualStrings(
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972",
        &cr_hex,
    );

    // Final signature must match the published value exactly.
    const sig = try sigv4.signatureHex(allocator, input);
    try testing.expectEqualStrings(
        "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        &sig,
    );

    // Full Authorization header (header-based signing, not query-string).
    const auth = try sigv4.authorizationHeader(allocator, input);
    defer allocator.free(auth);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," ++
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        auth,
    );
}

// AWS docs example 2: PUT test$file.text with payload "Welcome to Amazon S3."
// Exercises: payload hashing, URI encoding in the canonical path, >4 signed
// headers, and canonical sorting of mixed-case header names.
test "SigV4 KAT: PUT object with payload (AWS docs example)" {
    const allocator = testing.allocator;

    const payload = "Welcome to Amazon S3.";
    const payload_hash = sigv4.hashPayloadHex(payload);
    try testing.expectEqualStrings(
        "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
        &payload_hash,
    );

    const headers = [_]sigv4.Header{
        .{ .name = "Date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = &payload_hash },
        .{ .name = "x-amz-date", .value = amz_date },
        .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
    };

    const input = sigv4.SignInput{
        .method = "PUT",
        .canonical_uri = "/test%24file.text",
        .canonical_query = "",
        .headers = &headers,
        .payload_hash_hex = &payload_hash,
        .amz_date = amz_date,
        .region = "us-east-1",
        .service = "s3",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    };

    const sig = try sigv4.signatureHex(allocator, input);
    try testing.expectEqualStrings(
        "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
        &sig,
    );
}

// AWS docs example 3: GET ?lifecycle — exercises canonical query strings
// where a parameter has an empty value ("lifecycle=").
test "SigV4 KAT: GET bucket lifecycle (canonical query, AWS docs example)" {
    const allocator = testing.allocator;

    const params = [_]sigv4.QueryParam{
        .{ .name = "lifecycle", .value = "" },
    };
    const query = try sigv4.buildCanonicalQuery(allocator, &params);
    defer allocator.free(query);
    try testing.expectEqualStrings("lifecycle=", query);

    const headers = [_]sigv4.Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = sigv4.empty_payload_hash_hex },
        .{ .name = "x-amz-date", .value = amz_date },
    };

    const input = sigv4.SignInput{
        .method = "GET",
        .canonical_uri = "/",
        .canonical_query = query,
        .headers = &headers,
        .payload_hash_hex = sigv4.empty_payload_hash_hex,
        .amz_date = amz_date,
        .region = "us-east-1",
        .service = "s3",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    };

    const sig = try sigv4.signatureHex(allocator, input);
    try testing.expectEqualStrings(
        "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543",
        &sig,
    );
}

// AWS docs example 4: GET ?max-keys=2&prefix=J — multi-parameter canonical
// query string ordering.
test "SigV4 KAT: GET list objects (multi-param query, AWS docs example)" {
    const allocator = testing.allocator;

    const params = [_]sigv4.QueryParam{
        .{ .name = "prefix", .value = "J" },
        .{ .name = "max-keys", .value = "2" },
    };
    const query = try sigv4.buildCanonicalQuery(allocator, &params);
    defer allocator.free(query);
    try testing.expectEqualStrings("max-keys=2&prefix=J", query);

    const headers = [_]sigv4.Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = sigv4.empty_payload_hash_hex },
        .{ .name = "x-amz-date", .value = amz_date },
    };

    const input = sigv4.SignInput{
        .method = "GET",
        .canonical_uri = "/",
        .canonical_query = query,
        .headers = &headers,
        .payload_hash_hex = sigv4.empty_payload_hash_hex,
        .amz_date = amz_date,
        .region = "us-east-1",
        .service = "s3",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    };

    const sig = try sigv4.signatureHex(allocator, input);
    try testing.expectEqualStrings(
        "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
        &sig,
    );
}

// Signing-key derivation KAT from the AWS general SigV4 documentation
// ("Examples of how to derive a signing key"): note this older example uses
// the `+` variant of the example secret (…MDENG+bPx…), unlike the S3 vectors.
test "SigV4 KAT: signing key derivation chain (kSecret->kDate->kRegion->kService->kSigning)" {
    const key = sigv4.signingKey(
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "20120215",
        "us-east-1",
        "iam",
    );
    const key_hex = std.fmt.bytesToHex(key, .lower);
    try testing.expectEqualStrings(
        "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d",
        &key_hex,
    );
}

test "SigV4: amz-date formatting from epoch seconds" {
    // 2013-05-24T00:00:00Z == 1369353600
    const d = sigv4.formatAmzDate(1369353600);
    try testing.expectEqualStrings("20130524T000000Z", &d);
}

test "SigV4: URI path encoding keeps slashes, encodes reserved chars" {
    const allocator = testing.allocator;
    const enc = try sigv4.uriEncodePath(allocator, "backups/full/test$file 1.backup");
    defer allocator.free(enc);
    try testing.expectEqualStrings("backups/full/test%24file%201.backup", enc);
}

// ---------------------------------------------------------------------------
// SEC-CLI-01: --insecure-tls-skip-verify gating (mirrors GAP-0850 pattern).
// ---------------------------------------------------------------------------

test "insecure-tls gate: flag refused in release build without GEODE_ALLOW_INSECURE_TLS" {
    try testing.expectError(
        error.InsecureTlsRefused,
        gate.validateInsecureTls(true, true, false, false),
    );
}

test "insecure-tls gate: flag refused under GEODE_ENV=production without override" {
    try testing.expectError(
        error.InsecureTlsRefused,
        gate.validateInsecureTls(true, false, true, false),
    );
}

test "insecure-tls gate: GEODE_ALLOW_INSECURE_TLS=1 permits the flag in production posture" {
    try gate.validateInsecureTls(true, true, true, true);
}

test "insecure-tls gate: flag allowed in debug non-production posture" {
    try gate.validateInsecureTls(true, false, false, false);
}

test "insecure-tls gate: no flag means nothing to gate" {
    try gate.validateInsecureTls(false, true, true, false);
}

test "insecure-tls gate: env truthiness parsing" {
    try testing.expect(gate.envTruthy("1"));
    try testing.expect(gate.envTruthy("true"));
    try testing.expect(gate.envTruthy("TRUE"));
    try testing.expect(gate.envTruthy("on"));
    try testing.expect(gate.envTruthy("yes"));
    try testing.expect(!gate.envTruthy("0"));
    try testing.expect(!gate.envTruthy("false"));
    try testing.expect(!gate.envTruthy(""));
}

// The live evaluation reads builtin.mode and the process environment. The
// posture branch is mode-dependent, so this test asserts mode-appropriate
// behavior in BOTH build modes (so it stays meaningful under
// `-Doptimize=ReleaseSafe`, not just Debug):
//   * Debug test binary, no GEODE_ENV=production: the gate must NOT refuse —
//     proving the dev/test workflow keeps working.
//   * Release test binary (ReleaseSafe/ReleaseFast/ReleaseSmall): the gate is
//     in production posture (`builtin.mode != .Debug`) and MUST fail closed
//     with error.InsecureTlsRefused unless GEODE_ALLOW_INSECURE_TLS is set —
//     this is the security posture worth pinning.
//
// Guard the release branch on the override env var: a release CI binary that
// happens to run with GEODE_ALLOW_INSECURE_TLS=1 set would (correctly) permit
// the flag, so only assert the refusal when the override is absent.
test "insecure-tls gate: live evaluation is mode-appropriate (debug permits, release fails closed)" {
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) {
        // Dev/test loop: permissive in a Debug binary with no production env.
        try gate.evaluateLive(true);
    } else {
        // Release binary => production posture. Fail closed unless the operator
        // set the explicit acknowledgement override.
        const override_set = if (std.c.getenv(gate.allow_env)) |p|
            gate.envTruthy(std.mem.span(p))
        else
            false;
        if (override_set) {
            try gate.evaluateLive(true);
        } else {
            try testing.expectError(error.InsecureTlsRefused, gate.evaluateLive(true));
        }
    }
}

// SEC-CLI-01 follow-up: the implicit insecure-enable triggered by
// GEODE_SERVER_ADDRESS (test-harness convenience path in cmdQuery /
// cmdAuthLogin, src/cli/main.zig) routes through the SAME
// `enforceOrExit` → `validateInsecureTls` policy as the explicit flag —
// there is no separate decision function. This test pins the decisions
// that path inherits: refused in production posture without the override,
// allowed in the Debug builds the harness actually runs.
test "insecure-tls gate: implicit GEODE_SERVER_ADDRESS path uses the same policy" {
    // Release binary with the env var set, no acknowledgement: refused.
    try testing.expectError(
        error.InsecureTlsRefused,
        gate.validateInsecureTls(true, true, false, false),
    );
    // GEODE_ENV=production, no acknowledgement: refused.
    try testing.expectError(
        error.InsecureTlsRefused,
        gate.validateInsecureTls(true, false, true, false),
    );
    // Debug build (harness contract): allowed, with the loud warning.
    try gate.validateInsecureTls(true, false, false, false);
    // Production posture WITH explicit acknowledgement: allowed.
    try gate.validateInsecureTls(true, true, false, true);
}
