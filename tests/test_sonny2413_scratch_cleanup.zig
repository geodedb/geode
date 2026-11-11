// SONNY-2413: test runs left their scratch directories under /tmp. A test
// process that spawns a geode server without `--data-dir` got a per-process
// data dir, `/tmp/geode-test-<pid>` (proto_test_util.spawnServer), and nothing
// ever removed it: one task's runs left 62 behind. tests/gql_conformance.zig
// left one `/tmp/geode-gqlconf-<pid>-<n>` per query it ran (20 per run).
//
// The check here runs a real test process: this binary re-executes itself as
// a child (`/proc/self/exe`, so Linux only) that spawns a real geode server
// the way every proto_test_util test does, reports the data dir the server
// was given, stops the server and exits. Once the child is gone, nothing it
// created may remain under the temp root. The check is keyed on the paths
// that child reported, so it holds while other geode test processes run on
// the same machine.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

const child_mode_var = "GEODE_SONNY2413_CHILD";
const child_report_var = "GEODE_SONNY2413_REPORT";

fn childMode() ?[]const u8 {
    return std.testing.environ.getPosix(child_mode_var);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True once `path` is gone, waiting up to `timeout_ms` for it to go.
fn waitGone(path: []const u8, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 50) {
        if (!pathExists(path)) return true;
        sleepMs(50);
    }
    return !pathExists(path);
}

/// Only paths this test's own child reported, under the temp root, are ever
/// removed by the parent (and only to tidy up after a failed check).
fn tidyReported(path: []const u8) void {
    if (!std.mem.startsWith(u8, path, "/tmp/geode-test-")) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

const Report = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Report) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Re-executes this test binary in child `mode`, waits for it to exit, and
/// returns what the child wrote to its report file.
fn runChild(mode: []const u8) !Report {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const report_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/report", .{tmp.sub_path});
    defer gpa.free(report_path);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put(child_mode_var, mode);
    try env.put(child_report_var, report_path);
    // The default data dir is what is under test: a caller-provided one wins.
    _ = env.swapRemove("GEODE_DATA_DIR");

    var child = try std.process.spawn(io, .{
        .argv = &.{"/proc/self/exe"},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("SONNY-2413 child ({s}) ended with {any}\n", .{ mode, term });
        return error.ChildFailed;
    }

    var report: Report = .{};
    const bytes = try tmp.dir.readFile(io, "report", &report.buf);
    report.len = std.mem.trim(u8, bytes, " \r\n\t").len;
    return report;
}

fn writeReport(text: []const u8) !void {
    const path = std.testing.environ.getPosix(child_report_var) orelse return error.NoReportPath;
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

// Child half: does nothing unless this binary was re-executed by a test below.
test "SONNY-2413 child entry (no-op unless re-executed as a child)" {
    const mode = childMode() orelse return;
    const gpa = std.heap.smp_allocator;
    if (std.mem.eql(u8, mode, "default-data-dir")) {
        var server = try util.spawnServerRandom(gpa, null);
        defer server.deinit();
        const data_dir = server.env_map.?.get("GEODE_DATA_DIR") orelse return error.NoDefaultDataDir;
        try writeReport(data_dir);
        return;
    }
    return error.UnknownChildMode;
}

test "SONNY-2413: a server spawned without --data-dir leaves no scratch dir once its test process exits" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const report = try runChild("default-data-dir");
    const data_dir = report.text();
    defer tidyReported(data_dir);

    try std.testing.expect(data_dir.len > 0);
    if (!waitGone(data_dir, 10_000)) {
        std.debug.print("SONNY-2413: {s} survived its test process\n", .{data_dir});
        return error.ScratchDirLeaked;
    }
}
