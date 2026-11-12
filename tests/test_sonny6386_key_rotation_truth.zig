// CANARY: REQ=REQ-SONNY-6386-KEYROT-TRUTH; FEATURE="KeyRotation"; ASPECT=NoUncompiledPersistenceOrSimulatedKmsClaims; STATUS=TESTED; TEST=tests/test_sonny6386_key_rotation_truth.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6386 (5): `src/security/key_rotation.zig` `KeyRegistry` has no
// production caller (it is exported from lib.zig and used only by tests).
// Its `saveState` / `loadState` predated the Zig 0.16 std.Io migration
// (`file.close()` without an Io, `file.writer()`, `readToEndAlloc`) and so
// never compiled; `loadState` could unwrap a persisted envelope only with the
// local simulated KMS (`external_kms_client.Client`, a key derived from a
// seed), and `rotateWithKms` wrapped with the same simulator. The only tests
// of them (tests/test_key_rotation_persistence.zig, _checksum.zig,
// _kms_envelopes.zig) were in no build step, yet REQ-GQL-SEC-KEYROT-STATE-001
// and seven external_kms_client markers claimed TESTED against them, and
// docs/DESIGN_TDE_KMS.md listed "Rotation Persistence: Implemented".
//
// The contract: the uncompiled persistence and simulated-KMS rotation are
// removed with their unbuilt tests; no marker or doc claims them; the
// external_kms_client guards those markers named are tested here for real
// (backend production safety, the TLS/backend production check, envelope
// JSON round trip and hex rejection), and the Vault/AWS network clients,
// which no test reaches, are IMPL.
const std = @import("std");
const options = @import("sonny6386_kr_options");
const kms = @import("external_kms_client");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

fn repoFileExists(allocator: std.mem.Allocator, rel: []const u8) !bool {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    std.Io.Dir.cwd().access(io(), abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "SONNY-6386 (5) KeyRegistry has no uncompiled persistence or simulated-KMS rotation, and their unbuilt tests are gone" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    const src = try readRepoFile(allocator, "src/security/key_rotation.zig");
    defer allocator.free(src);
    for ([_][]const u8{ "pub fn saveState", "pub fn loadState", "rotateWithKms", "setKmsSeed", "kms_seed", "REQ-GQL-SEC-KEYROT-STATE-001" }) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) {
            std.debug.print("SONNY-6386 (5): src/security/key_rotation.zig still contains {s}\n", .{needle});
            bad += 1;
        }
    }
    for ([_][]const u8{ "tests/test_key_rotation_persistence.zig", "tests/test_key_rotation_checksum.zig", "tests/test_key_rotation_kms_envelopes.zig" }) |dead| {
        if (try repoFileExists(allocator, dead)) {
            std.debug.print("SONNY-6386 (5): {s} (built by no step) still exists\n", .{dead});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6386 (5) no marker or doc cites the removed tests or claims rotation persistence" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "src/security/external_kms_client.zig", "src/security/key_rotation.zig", "docs/DESIGN_TDE_KMS.md", "docs/SECURITY_PROGRESS.md" }) |rel| {
        const text = try readRepoFile(allocator, rel);
        defer allocator.free(text);
        for ([_][]const u8{ "test_key_rotation_kms_envelopes", "test_key_rotation_persistence", "test_key_rotation_checksum", "KEYROT-STATE-001" }) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) {
                std.debug.print("SONNY-6386 (5): {s} still cites {s}\n", .{ rel, needle });
                bad += 1;
            }
        }
    }
    const design = try readRepoFile(allocator, "docs/DESIGN_TDE_KMS.md");
    defer allocator.free(design);
    if (std.mem.indexOf(u8, design, "| Rotation Persistence         | Implemented") != null) {
        std.debug.print("SONNY-6386 (5): docs/DESIGN_TDE_KMS.md still lists Rotation Persistence as Implemented\n", .{});
        bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6386 (5) KmsBackend.isProductionSafe refuses only the local simulator" {
    try testing.expect(!kms.KmsBackend.LocalSimulated.isProductionSafe());
    try testing.expect(kms.KmsBackend.VaultTransit.isProductionSafe());
    try testing.expect(kms.KmsBackend.AwsKms.isProductionSafe());
}

test "SONNY-6386 (5) KmsConfig.isSecureForProduction refuses tls_skip_verify and the local simulator; validateForProduction allows them only outside release builds" {
    const vault: kms.KmsConfig = .{ .backend = .VaultTransit, .vault_addr = "https://vault:8200", .vault_token = "t", .vault_key_name = "k" };
    try testing.expect(vault.isSecureForProduction());
    var skip = vault;
    skip.tls_skip_verify = true;
    try testing.expect(!skip.isSecureForProduction());
    const local: kms.KmsConfig = .{ .backend = .LocalSimulated };
    try testing.expect(!local.isSecureForProduction());

    const release = @import("builtin").mode != .Debug;
    if (release) {
        try testing.expectError(error.InsecureTlsConfigurationBlocked, skip.validateForProduction());
        try testing.expectError(error.InsecureKmsBackendBlocked, local.validateForProduction());
    } else {
        try skip.validateForProduction();
        try local.validateForProduction();
    }
    try vault.validateForProduction();
}

test "SONNY-6386 (5) envelopeToJson / envelopeFromJson round trip, and non-hex nonce, tag or ciphertext is refused" {
    const allocator = testing.allocator;
    var client = try kms.Client.init(allocator, 0x6386);
    var plain: [32]u8 = undefined;
    @memset(&plain, 0x5a);
    const env = try client.wrap(plain);
    const json = try kms.envelopeToJson(env, allocator);
    defer allocator.free(json);
    const back = try kms.envelopeFromJson(json);
    try testing.expectEqualSlices(u8, &env.nonce, &back.nonce);
    try testing.expectEqualSlices(u8, &env.tag, &back.tag);
    try testing.expectEqualSlices(u8, &env.ct, &back.ct);
    try testing.expectEqualSlices(u8, &plain, &(try client.unwrap(back)));

    const fields = [_]struct { key: []const u8, err: anyerror }{
        .{ .key = "\"nonce\":\"", .err = error.InvalidHexInNonce },
        .{ .key = "\"tag\":\"", .err = error.InvalidHexInTag },
        .{ .key = "\"ct\":\"", .err = error.InvalidHexInCiphertext },
    };
    for (fields) |f| {
        const bad = try allocator.dupe(u8, json);
        defer allocator.free(bad);
        const at = std.mem.indexOf(u8, bad, f.key).? + f.key.len;
        bad[at] = 'z';
        try testing.expectError(f.err, kms.envelopeFromJson(bad));
    }
}
