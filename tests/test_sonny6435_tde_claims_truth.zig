// CANARY: REQ=REQ-SONNY-6435-TDE-CLAIMS-TRUTH; FEATURE="Docs"; ASPECT=NoUnmeasuredTdeOverheadClaim; STATUS=TESTED; TEST=tests/test_sonny6435_tde_claims_truth.zig; OWNER=perf; UPDATED=2026-11-12
//
// SONNY-6435 (2): the TDE overhead "benchmarks" measured no encryption.
// benchmarks/benchmark_tde_overhead.zig (the `zig build bench` step) hashed
// a buffer with Wyhash and called it encryption; benchmarks/
// benchmark_tde_oltp_overhead.zig was built by no step, used removed std
// APIs and simulated TDE too. Meanwhile README.md, BENCHMARK_REPORT.md,
// docs/FEATURES_OVERVIEW.md, docs/TODO.md, docs/SERVER_FEATURES.md,
// docs/KMS_PROVIDER_SYSTEM.md and docs/DESIGN_TDE_KMS.md claimed "<1%" or
// "<5%" TDE overhead, and src/security/test_tde_enforcement.zig asserted
// `5 <= 5` under the comment "TDE documentation claims <1% overhead".
//
// The contract: the simulations are gone (the real measurement is
// `zig build test-sonny6435-tde-overhead`), none of those claims is made,
// and the published docs cite the measurement.
const std = @import("std");
const options = @import("sonny6435_tc_options");

const testing = std.testing;

fn repoPath(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ options.repo_root, rel });
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try repoPath(allocator, rel);
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

fn repoFileExists(allocator: std.mem.Allocator, rel: []const u8) !bool {
    const abs = try repoPath(allocator, rel);
    defer allocator.free(abs);
    _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), abs, .{}) catch return false;
    return true;
}

const Claim = struct { file: []const u8, text: []const u8 };

const unmeasured_claims = [_]Claim{
    .{ .file = "README.md", .text = "<5% TDE overhead on OLTP workloads as a target" },
    .{ .file = "BENCHMARK_REPORT.md", .text = "| OLTP Overhead | < 5% | Compared to unencrypted |" },
    .{ .file = "BENCHMARK_REPORT.md", .text = "**Benchmark File:** `benchmarks/benchmark_tde_overhead.zig`" },
    .{ .file = "docs/FEATURES_OVERVIEW.md", .text = "Transparent data encryption with <1% overhead" },
    .{ .file = "docs/TODO.md", .text = "Transparent data encryption with <1% overhead" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Page encryption: <1% CPU overhead" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "WAL encryption: <1% latency overhead" },
    .{ .file = "docs/KMS_PROVIDER_SYSTEM.md", .text = "<5% TDE overhead on OLTP workloads as a target" },
    .{ .file = "docs/KMS_PROVIDER_SYSTEM.md", .text = "<5% TDE overhead on OLTP workloads (a target" },
    .{ .file = "docs/DESIGN_TDE_KMS.md", .text = "Published performance target validation (<5% overhead)" },
    .{ .file = "docs/audit/perf-phase1-context.md", .text = "| TDE OLTP overhead | < 5% |" },
    .{ .file = "src/security/test_tde_enforcement.zig", .text = "TDE documentation claims <1% overhead" },
};

test "SONNY-6435 (2) the TDE overhead simulations are gone and nothing builds them" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "benchmarks/benchmark_tde_overhead.zig", "benchmarks/benchmark_tde_oltp_overhead.zig" }) |rel| {
        if (try repoFileExists(allocator, rel)) {
            std.debug.print("SONNY-6435 (2): {s} (a simulation, no encryption timed) still exists\n", .{rel});
            bad += 1;
        }
    }
    const build_zig = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_zig);
    if (std.mem.indexOf(u8, build_zig, "benchmarks/benchmark_tde_overhead.zig") != null) {
        std.debug.print("SONNY-6435 (2): build.zig still builds benchmarks/benchmark_tde_overhead.zig\n", .{});
        bad += 1;
    }
    if (std.mem.indexOf(u8, build_zig, "\"test-sonny6435-tde-overhead\"") == null) {
        std.debug.print("SONNY-6435 (2): build.zig has no test-sonny6435-tde-overhead measurement step\n", .{});
        bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6435 (2) no doc claims an unmeasured TDE overhead, and the published ones cite the measurement" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (unmeasured_claims) |c| {
        const text = try readRepoFile(allocator, c.file);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, c.text) != null) {
            std.debug.print("SONNY-6435 (2): {s} still says \"{s}\"\n", .{ c.file, c.text });
            bad += 1;
        }
    }
    for ([_][]const u8{ "README.md", "BENCHMARK_REPORT.md", "docs/KMS_PROVIDER_SYSTEM.md", "docs/TDE_FILE_LEVEL_ENCRYPTION.md" }) |rel| {
        const text = try readRepoFile(allocator, rel);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "test-sonny6435-tde-overhead") == null) {
            std.debug.print("SONNY-6435 (2): {s} does not cite the measurement (zig build test-sonny6435-tde-overhead)\n", .{rel});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
