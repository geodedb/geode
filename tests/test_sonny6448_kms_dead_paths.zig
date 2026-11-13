// CANARY: REQ=REQ-SONNY-6448-KMS-NO-LOCAL-DEV; FEATURE="KMSProviderSystem"; ASPECT=NoKeyFromKeyId; STATUS=TESTED; TEST=tests/test_sonny6448_kms_dead_paths.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6448 (7):
//   - src/security/kms.zig offered a `local_dev` KMSProvider whose wrapping
//     key was HKDF(key id): anyone holding a wrapped key (which carries its
//     key id) could unwrap it, and its "legacy" unwrap used a nonce derived
//     from CRC32(key id). It was constructible in a Debug build, and nothing
//     in the product used it (KMS wiring is story SONNY-6380). It is gone,
//     with `localDevProvider`, the `defaultProvider` that returned it and
//     their tests.
//   - benchmarks/benchmark_remote_kms_unwrap_concurrency.zig kept an unused
//     `connectClient` that dialled the remote KMS with no CA bundle. It is
//     gone.
const std = @import("std");
const kms = @import("security/kms");
const options = @import("sonny6448_kms_options");

const testing = std.testing;

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(16 << 20));
}

test "SONNY-6448 (7) KMSProvider has no local_dev provider deriving its key from the key id" {
    try testing.expect(!@hasField(kms.KMSProviderType, "local_dev"));
    try testing.expect(!@hasDecl(kms, "localDevProvider"));
    try testing.expect(!@hasDecl(kms, "defaultProvider"));
    const src = try readRepoFile(testing.allocator, "src/security/kms.zig");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "LOCAL_DEV_WRAP") == null);
}

test "SONNY-6448 (7) the remote KMS concurrency benchmark has no client that dials without a CA bundle" {
    const src = try readRepoFile(testing.allocator, "benchmarks/benchmark_remote_kms_unwrap_concurrency.zig");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "fn connectClient(") == null);
}
