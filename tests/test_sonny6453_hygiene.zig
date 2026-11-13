// SONNY-6453 item 5: small findings from the SONNY-6448 TLS audit.
//
//   * Compose files set the PID limit two ways: `pids_limit` (in
//     docker-compose.yml, .example.yml, .gpu.yml, .otel.yml and the test
//     stacks) and `deploy.resources.limits.pids` (the others). Compose
//     refuses a service that has both, so adding a deploy limit to one of
//     the `pids_limit` files would break it. Every compose file now uses
//     `deploy.resources.limits.pids` only.
//   * src/security/kms.zig carried a dead `compat_fillRandom`, and its
//     inline tests ran in no step; they now run in
//     `zig build test-sonny6453-kms-inline`.
//   * The GAP-0499 secure-zero test (src/security/test_secure_zero.zig) ran
//     only in the aggregate; it now has `zig build test-secure-zero`.
//
// CANARY: REQ=REQ-SONNY-6453-HYGIENE; FEATURE="Docs"; ASPECT=ComposePidsAndTestSteps; STATUS=TESTED; TEST=tests/test_sonny6453_hygiene.zig; OWNER=docs; UPDATED=2026-11-13

const std = @import("std");
const options = @import("sonny6453_hygiene_options");
const testing = std.testing;

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

const compose_files = [_][]const u8{
    "docker-compose.yml",
    "docker-compose.dev.yml",
    "docker-compose.distributed.yml",
    "docker-compose.example.yml",
    "docker-compose.gpu.yml",
    "docker-compose.otel.yml",
    "docker-compose.override.yml",
    "docker-integration/docker-compose.integration.yml",
    "tests/docker-compose.test.yml",
    "tests/ha/docker-compose.yml",
    "tests/ha/docker-compose.clients.yml",
};

test "SONNY-6453 (5) no compose file sets pids_limit (the limit is deploy.resources.limits.pids)" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "pids_limit:")) {
                std.debug.print("SONNY-6453 (5): {s}:{d} sets pids_limit\n", .{ file, n });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6453 (5) kms.zig has no dead compat_fillRandom" {
    const allocator = testing.allocator;
    const text = try readRepoFile(allocator, "src/security/kms.zig");
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "fn compat_fillRandom") == null);
}

test "SONNY-6453 (5) the kms.zig inline tests and the secure-zero test have named steps" {
    const allocator = testing.allocator;
    const text = try readRepoFile(allocator, "build.zig");
    defer allocator.free(text);
    var bad: usize = 0;
    for ([_][]const u8{ "b.step(\"test-sonny6453-kms-inline\"", "b.step(\"test-secure-zero\"" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("SONNY-6453 (5): build.zig has no {s}\n", .{needle});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
