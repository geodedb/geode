// SONNY-6320: password hashing and timing-attack resistance, deterministically.
//
// src/security/test_argon2id_hashing.zig and src/security/test_timing_attacks.zig
// were in no build step: the first called an `Auth` API that no longer exists,
// both asserted wall-clock timing (a variance bound over ~400 Argon2
// verifications, 100-500 ms per hash), and the second used the removed
// std.time.nanoTimestamp. Password hashing and timing resistance had no
// running test from them. This file replaces both against the live code:
// `hashPasswordArgon2id` / `verifyPasswordArgon2id` (the one hashing
// implementation every component uses) and `SecurityManager`'s verify path.
//
// Constant time is checked structurally, never by a clock: the digest
// comparisons on the verify paths go through the FIPS seam's
// `timingSafeEql`, and no `std.mem.eql` compares a digest there. A wall-clock
// bound is not a correctness check (it fails on a loaded runner and passes
// on a leaky compare whose difference is below the noise).
//
// CANARY: REQ=REQ-SONNY-6320-PASSWORD-HASHING; FEATURE="Argon2id Password Hashing"; ASPECT=DeterministicHashAndConstantTimeVerify; STATUS=TESTED; TEST=tests/test_sonny6320_password_hashing.zig; OWNER=security; UPDATED=2026-11-12
const std = @import("std");
const auth = @import("geode_auth");
const cb = @import("crypto_backend");
const options = @import("sonny6320_options");
const build_options = @import("build_options");

const testing = std.testing;

const phc_prefix = "$argon2id$v=19$m=19456,t=2,p=1$";

test "SONNY-6320: Argon2id hashes are PHC strings with the OWASP parameters and a fresh 16-byte salt" {
    // Argon2id is not FIPS-approved: under -Dfips hashing fails closed
    // (covered by test-auth-enforcement's FIPS fail-close cases).
    if (build_options.fips) return error.SkipZigTest;
    const a = testing.allocator;
    const h1 = try auth.hashPasswordArgon2id(a, "correct horse battery staple");
    defer a.free(h1);
    const h2 = try auth.hashPasswordArgon2id(a, "correct horse battery staple");
    defer a.free(h2);

    for ([_][]const u8{ h1, h2 }) |h| {
        try testing.expect(std.mem.startsWith(u8, h, phc_prefix));
        // $argon2id$v=19$m=19456,t=2,p=1$<32 hex salt>$<64 hex hash>
        const rest = h[phc_prefix.len..];
        const dollar = std.mem.indexOfScalar(u8, rest, '$') orelse return error.NoHashField;
        try testing.expectEqual(@as(usize, 32), dollar);
        try testing.expectEqual(@as(usize, 64), rest.len - dollar - 1);
        for (rest) |c| try testing.expect(c == '$' or std.ascii.isHex(c));
    }
    // Same password, different salt, different string.
    try testing.expect(!std.mem.eql(u8, h1, h2));
    try testing.expect(!std.mem.eql(u8, h1[phc_prefix.len..][0..32], h2[phc_prefix.len..][0..32]));
}

test "SONNY-6320: verify accepts the password and refuses any other, including near misses" {
    // Argon2id is not FIPS-approved: under -Dfips hashing fails closed
    // (covered by test-auth-enforcement's FIPS fail-close cases).
    if (build_options.fips) return error.SkipZigTest;
    const a = testing.allocator;
    const pw = "CorrectPassword123!";
    const h = try auth.hashPasswordArgon2id(a, pw);
    defer a.free(h);
    try testing.expect(try auth.verifyPasswordArgon2id(a, pw, h));
    for ([_][]const u8{ "", "CorrectPassword123", "CorrectPassword123!!", "correctPassword123!", "WrongPassword123!" }) |wrong| {
        try testing.expect(!try auth.verifyPasswordArgon2id(a, wrong, h));
    }
}

test "SONNY-6320: verify refuses a malformed or foreign PHC string instead of matching it" {
    // Argon2id is not FIPS-approved: under -Dfips hashing fails closed
    // (covered by test-auth-enforcement's FIPS fail-close cases).
    if (build_options.fips) return error.SkipZigTest;
    const a = testing.allocator;
    const h = try auth.hashPasswordArgon2id(a, "pw");
    defer a.free(h);
    const salt_and_hash = h[phc_prefix.len..];

    var buf: [256]u8 = undefined;
    const cases = [_][]const u8{
        "",
        "$argon2id$",
        "plaintext",
        try std.fmt.bufPrint(buf[0..128], "$argon2i$v=19$m=19456,t=2,p=1${s}", .{salt_and_hash}),
        try std.fmt.bufPrint(buf[128..256], "$argon2id$v=16$m=19456,t=2,p=1${s}", .{salt_and_hash}),
        h[0 .. h.len - 2], // truncated hash
        h[0 .. phc_prefix.len + 30], // truncated salt
    };
    // SONNY-6598: a string it cannot use is an error, not a mismatch.
    for (cases) |bad| try testing.expectError(error.InvalidHashFormat, auth.verifyPasswordArgon2id(a, "pw", bad));

    // A flipped hash digit no longer verifies.
    const flipped = try a.dupe(u8, h);
    defer a.free(flipped);
    flipped[flipped.len - 1] = if (flipped[flipped.len - 1] == '0') '1' else '0';
    try testing.expect(!try auth.verifyPasswordArgon2id(a, "pw", flipped));
}

var auth_source_buf: ?[]u8 = null;

/// src/security/geode_auth_lib.zig, read once (page_allocator: lives for the
/// test binary).
fn authSource() ![]const u8 {
    if (auth_source_buf) |s| return s;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fs.path.join(std.heap.page_allocator, &.{ options.repo_root, "src/security/geode_auth_lib.zig" });
    defer std.heap.page_allocator.free(path);
    const s = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(16 << 20));
    auth_source_buf = s;
    return s;
}

/// The body of the function declared by `signature` in the auth source: from
/// the signature to the next line that is exactly `}` at its indentation.
fn functionBody(signature: []const u8) ![]const u8 {
    const auth_source = try authSource();
    const at = std.mem.indexOf(u8, auth_source, signature) orelse return error.FunctionNotFound;
    const line_start = (std.mem.lastIndexOfScalar(u8, auth_source[0..at], '\n') orelse 0) + 1;
    const indent = auth_source[line_start..at];
    var close_buf: [64]u8 = undefined;
    const close = try std.fmt.bufPrint(&close_buf, "\n{s}}}\n", .{indent});
    const end = std.mem.indexOfPos(u8, auth_source, at, close) orelse return error.FunctionEndNotFound;
    return auth_source[at..end];
}

test "SONNY-6320: the verify paths compare digests in constant time (structural, no clock)" {
    // Argon2id: the re-derived digest against the stored one.
    const argon = try functionBody("pub fn verifyPasswordArgon2id(");
    try testing.expect(std.mem.indexOf(u8, argon, "crypto_backend.timingSafeEql(&computed_hash, &expected_hash)") != null);
    try testing.expect(std.mem.indexOf(u8, argon, "std.mem.eql(u8, &computed_hash") == null);
    try testing.expect(std.mem.indexOf(u8, argon, "std.mem.eql(u8, &expected_hash") == null);

    // Legacy Blake2b (migration only): through the one legacy verifier
    // (SONNY-6367, `verifyPasswordBlake2bLegacy`), which compares the digests
    // with timingSafeEql.
    const legacy = try functionBody("fn verifyBlake2bLegacy(");
    try testing.expect(std.mem.indexOf(u8, legacy, "verifyPasswordBlake2bLegacy(password, stored_hash)") != null);
    try testing.expect(std.mem.indexOf(u8, legacy, "std.mem.eql") == null);
    const legacy_verify = try functionBody("pub fn verifyPasswordBlake2bLegacy(");
    try testing.expect(std.mem.indexOf(u8, legacy_verify, "crypto_backend.timingSafeEql(&digest, &expected)") != null);
    try testing.expect(std.mem.indexOf(u8, legacy_verify, "std.mem.eql") == null);

    // SecurityManager's verify dispatches only to those two.
    const dispatch = try functionBody("fn verifyPassword(self: *Self");
    try testing.expect(std.mem.indexOf(u8, dispatch, "self.verifyArgon2idPHC(password, stored_hash)") != null);
    try testing.expect(std.mem.indexOf(u8, dispatch, "self.verifyBlake2bLegacy(password, stored_hash)") != null);
    try testing.expect(std.mem.indexOf(u8, dispatch, "std.mem.eql(u8, password") == null);
    const phc = try functionBody("fn verifyArgon2idPHC(");
    try testing.expect(std.mem.indexOf(u8, phc, "verifyPasswordArgon2id(self.allocator, password, phc_string)") != null);
}

test "SONNY-6320: the constant-time primitive answers equal and unequal inputs correctly" {
    var x: [32]u8 = @splat(0xAA);
    var y: [32]u8 = @splat(0xAA);
    try testing.expect(cb.timingSafeEql(&x, &y));
    y[0] = 0xAB;
    try testing.expect(!cb.timingSafeEql(&x, &y));
    y = x;
    y[31] = 0x00;
    try testing.expect(!cb.timingSafeEql(&x, &y));
}

/// The test files SONNY-6320 found in no build step. Each must now be gone
/// (it tested nothing live, or duplicated a registered test) or be the root
/// of a test the build compiles.
const orphans = [_][]const u8{
    "src/security/test_argon2id_hashing.zig",
    "src/security/test_timing_attacks.zig",
    "src/server/test_abac_enforcement.zig",
    "src/server/test_async_connection.zig",
    "tests/e2e_rls_enhanced.zig",
    "tests/canary_federation_latency_aggregate.zig",
    "tests/priority_implementations.zig",
    "tests/test_canary_core.zig",
    "tests/test_performance_integration.zig",
    "tests/test_external_kms_provider.zig",
    "tests/test_gap_0193_batch2_engine.zig",
    "tests/test_gap_0193_batch2_misc.zig",
    "tests/test_gap_0193_impl_verification.zig",
};

test "SONNY-6320: every test file that sat in no build step is removed or built" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const build_path = try std.fs.path.join(a, &.{ options.repo_root, "build.zig" });
    defer a.free(build_path);
    const build_src = try std.Io.Dir.cwd().readFileAlloc(io, build_path, a, .limited(16 << 20));
    defer a.free(build_src);

    var bad: usize = 0;
    for (orphans) |rel| {
        const abs = try std.fs.path.join(a, &.{ options.repo_root, rel });
        defer a.free(abs);
        const exists = if (std.Io.Dir.cwd().access(io, abs, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (!exists) continue;
        const needle = try std.fmt.allocPrint(a, "b.path(\"{s}\")", .{rel});
        defer a.free(needle);
        var built = false;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, build_src, from, needle)) |at| : (from = at + 1) {
            const line_start = (std.mem.lastIndexOfScalar(u8, build_src[0..at], '\n') orelse 0) + 1;
            const line = std.mem.trimStart(u8, build_src[line_start..at], " \t");
            if (!std.mem.startsWith(u8, line, "//")) built = true;
        }
        if (!built) {
            std.debug.print("SONNY-6320: {s} exists and no build step compiles it\n", .{rel});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
