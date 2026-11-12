// SONNY-6272: Dockerfile.prod built on ubuntu:26.04 and ran on
// nvidia/cuda:13.4.2-base-ubuntu24.04 with `libssl3` (Ubuntu 24.04 names
// the package libssl3t64), outside the release Dockerfile compatibility
// check (tools/release_dockerfile_manifest.py) and the in-build
// `geode --version` smoke step.
//
// It is not a supported image: it cannot build at all. It installs Zig
// 0.15.2 (build.zig.zon requires 0.16.0), copies `vendor/`, which does not
// exist, and copies neither build.zig.zon nor the dependency cache, and no
// CI job builds it. The supported GPU image is Dockerfile.release.gpu, under
// the release manifest and its checks. So the fix is the ticket's first
// branch: remove it and its references.
//
// Checked here: Dockerfile.prod is gone, and no Makefile target, compose
// file, operator doc or Dockerfile test names it.
//
// CANARY: REQ=REQ-SONNY-6272-NO-DOCKERFILE-PROD; FEATURE="Container Images"; ASPECT=UnsupportedImageRemoved; STATUS=TESTED; TEST=tests/test_sonny6272_dockerfile_prod.zig; OWNER=release; UPDATED=2026-11-12
const std = @import("std");
const options = @import("sonny6272_options");

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

test "SONNY-6272 Dockerfile.prod is removed" {
    try testing.expect(!try repoFileExists(testing.allocator, "Dockerfile.prod"));
}

test "SONNY-6272 no build entry point, operator doc or Dockerfile test names Dockerfile.prod" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{
        "Makefile",
        "docker-compose.example.yml",
        "docker/README.md",
        "docs/docker/DOCKER.md",
        "docs/DOCKER_LOG_LEVEL_CONFIG.md",
        "tests/test_dockerfile_health_check.py",
    }) |rel| {
        const text = try readRepoFile(allocator, rel);
        defer allocator.free(text);
        for ([_][]const u8{ "Dockerfile.prod", "docker-build-prod" }) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) {
                bad += 1;
                std.debug.print("SONNY-6272: {s} names {s}\n", .{ rel, needle });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
