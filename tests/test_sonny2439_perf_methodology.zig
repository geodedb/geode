// SONNY-2439 (partial): the perf gates measured benchmark artifacts, not the
// product. This pins the parts of the methodology fix that have landed:
//
//   (1) every file that makes a perf claim through tests/perf_gate.zig
//       times with a monotonic clock. All of the gated canary benchmarks
//       timed with CLOCK_REALTIME, which NTP slews and steps;
//   (2) the two gated benchmarks that timed only test-local code are gone:
//       tests/canary_storage_redo_delta.zig (a synthetic simulateRedo loop
//       whose result was discarded) and tests/canary_path_varlen_predicate.zig
//       (a 4-node test-local DFS). Neither imported any product code, so a
//       missed claim could not mean a product regression, and the optimizer
//       could drop the loop they timed;
//   (3) every step the scheduled test-perf-gates-enforced job runs exists.
//
// Still open (SONNY-2439): batch timing, the production allocator instead of
// DebugAllocator, interleaved A/B with median/IQR statistics, thresholds
// calibrated on the quiet CI runner, the phantom-range baseline that never
// enables phantom prevention, and the GitLab schedule for the enforced job.
//
// CANARY: REQ=REQ-SONNY-2439-PERF-METHODOLOGY; FEATURE="Perf Gates"; ASPECT=MonotonicClockNoTestLocalBenchmarks; STATUS=TESTED; TEST=tests/test_sonny2439_perf_methodology.zig; OWNER=performance; UPDATED=2026-11-12
const std = @import("std");
const options = @import("sonny2439_options");

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

test "SONNY-2439 (1) every file that makes a gated perf claim times with a monotonic clock" {
    const allocator = testing.allocator;
    var gated: usize = 0;
    var bad: usize = 0;
    for ([_][]const u8{ "tests", "src" }) |top| {
        const top_abs = try std.fs.path.join(allocator, &.{ options.repo_root, top });
        defer allocator.free(top_abs);
        var dir = try std.Io.Dir.cwd().openDir(io(), top_abs, .{ .iterate = true });
        defer dir.close(io());
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // The gate itself, and this file's own search strings.
            if (std.mem.eql(u8, entry.basename, "perf_gate.zig")) continue;
            if (std.mem.eql(u8, entry.basename, "test_sonny2439_perf_methodology.zig")) continue;
            const src = dir.readFileAlloc(io(), entry.path, allocator, .limited(64 << 20)) catch continue;
            defer allocator.free(src);
            if (std.mem.indexOf(u8, src, "perf_gate.check(") == null and std.mem.indexOf(u8, src, "perf_gate.envelope(") == null) continue;
            gated += 1;
            var lines = std.mem.splitScalar(u8, src, '\n');
            var n: usize = 0;
            while (lines.next()) |line| {
                n += 1;
                if (std.mem.indexOf(u8, line, ".REALTIME") != null) {
                    bad += 1;
                    std.debug.print("SONNY-2439: {s}/{s}:{d}: a gated benchmark reads CLOCK_REALTIME: {s}\n", .{ top, entry.path, n, std.mem.trim(u8, line, " ") });
                }
            }
        }
    }
    try testing.expect(gated >= 10);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-2439 (2) the gated benchmarks that timed only test-local code are gone" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "tests/canary_storage_redo_delta.zig", "tests/canary_path_varlen_predicate.zig" }) |rel| {
        if (try repoFileExists(allocator, rel)) {
            bad += 1;
            std.debug.print("SONNY-2439: {s} still exists (it times test-local code only)\n", .{rel});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-2439 (3) every step the enforced perf-gate job runs exists" {
    const allocator = testing.allocator;
    const ci = try readRepoFile(allocator, ".gitlab-ci.yml");
    defer allocator.free(ci);
    const build_src = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_src);
    const job = std.mem.indexOf(u8, ci, "GEODE_PERF_GATES: \"enforce\"") orelse return error.EnforcedJobNotFound;
    const loop_start = std.mem.indexOfPos(u8, ci, job, "for step in") orelse return error.EnforcedJobNotFound;
    const loop_end = std.mem.indexOfPos(u8, ci, loop_start, "; do") orelse return error.EnforcedJobNotFound;
    var tokens = std.mem.tokenizeAny(u8, ci[loop_start + "for step in".len .. loop_end], " \\\n");
    var steps: usize = 0;
    var bad: usize = 0;
    while (tokens.next()) |name| {
        steps += 1;
        const decl = try std.fmt.allocPrint(allocator, "b.step(\"{s}\"", .{name});
        defer allocator.free(decl);
        if (std.mem.indexOf(u8, build_src, decl) == null) {
            bad += 1;
            std.debug.print("SONNY-2439: the enforced perf-gate job runs {s}, which build.zig does not define\n", .{name});
        }
    }
    try testing.expect(steps >= 8);
    try testing.expectEqual(@as(usize, 0), bad);
}
