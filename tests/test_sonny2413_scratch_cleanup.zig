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
// the same machine. A second child is killed with SIGKILL, so no defer runs,
// and its scratch must go too. The remaining tests drive the shared helper
// (tests/test_scratch.zig) that every scratch dir now comes from, with a real
// server holding the dir, on the success and the error path.
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

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

/// Re-executes this test binary in child `mode`, waits for it to exit (or
/// kills it once it has reported), and returns what it wrote to its report.
fn runChild(mode: []const u8, kill_after_report: bool) !Report {
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
        // The child's own test output would make a green step print as a
        // failed command; rerun the binary with the two env vars to see it.
        .stderr = .ignore,
    });
    var report: Report = .{};
    if (kill_after_report) {
        // The child reports, then blocks: kill it the way a crash or a
        // build-runner timeout would, so none of its defers run.
        var waited: u64 = 0;
        const bytes = while (waited < 60_000) : (waited += 50) {
            if (tmp.dir.readFile(io, "report", &report.buf)) |b| {
                if (b.len > 0 and b[b.len - 1] == '\n') break b;
            } else |_| {}
            sleepMs(50);
        } else {
            std.posix.kill(child.id.?, .KILL) catch {};
            _ = child.wait(io) catch {};
            return error.ChildNeverReported;
        };
        report.len = std.mem.trim(u8, bytes, " \r\n\t").len;
        try std.posix.kill(child.id.?, .KILL);
        const term = try child.wait(io);
        try std.testing.expect(term == .signal);
        return report;
    }

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("SONNY-2413 child ({s}) ended with {any}; rerun this test binary with " ++ child_mode_var ++ "={s} " ++ child_report_var ++ "=<file> to see why\n", .{ mode, term, mode });
        return error.ChildFailed;
    }

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
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const mode = childMode() orelse return;
    const gpa = std.heap.smp_allocator;
    if (std.mem.eql(u8, mode, "default-data-dir")) {
        var server = try util.spawnServerRandom(gpa, null);
        defer server.deinit();
        const data_dir = server.env_map.?.get("GEODE_DATA_DIR") orelse return error.NoDefaultDataDir;
        try writeReport(data_dir);
        return;
    }
    if (std.mem.eql(u8, mode, "killed")) {
        var report_buf: [512]u8 = undefined;
        // A scratch dir whose remove() never runs, and the default data dir
        // of a server (stopped first: a killed test leaves an orphan server
        // behind, which is a different leak).
        const scratch = try test_scratch.ScratchDir.create("killed");
        {
            var server = try util.spawnServerRandom(gpa, null);
            defer server.deinit();
            const data_dir = server.env_map.?.get("GEODE_DATA_DIR") orelse return error.NoDefaultDataDir;
            try writeReport(try std.fmt.bufPrint(&report_buf, "{s}\n{s}\n", .{ data_dir, scratch.path() }));
        }
        while (true) sleepMs(1000);
    }
    return error.UnknownChildMode;
}

test "SONNY-2413: a server spawned without --data-dir leaves no scratch dir once its test process exits" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const report = try runChild("default-data-dir", false);
    const data_dir = report.text();
    defer tidyReported(data_dir);

    try std.testing.expect(data_dir.len > 0);
    try expectGoneWithRoot(data_dir);
}

/// `path`, and the per-process scratch root holding it, are gone.
fn expectGoneWithRoot(path: []const u8) !void {
    if (!waitGone(path, 10_000)) {
        std.debug.print("SONNY-2413: {s} survived its test process\n", .{path});
        return error.ScratchDirLeaked;
    }
    const root = std.fs.path.dirname(path) orelse return error.NoScratchRoot;
    try std.testing.expect(std.mem.startsWith(u8, root, test_scratch.temp_root ++ "/" ++ test_scratch.root_prefix));
    defer tidyReported(root);
    if (!waitGone(root, 10_000)) {
        std.debug.print("SONNY-2413: scratch root {s} survived its test process\n", .{root});
        return error.ScratchDirLeaked;
    }
}

test "SONNY-2413: a test process killed with SIGKILL leaves no scratch dir behind" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const report = try runChild("killed", true);
    var lines = std.mem.splitScalar(u8, report.text(), '\n');
    const data_dir = lines.next() orelse return error.BadReport;
    const scratch = lines.next() orelse return error.BadReport;
    defer tidyReported(data_dir);
    defer tidyReported(scratch);

    try expectGoneWithRoot(scratch);
    try std.testing.expect(!pathExists(data_dir));
}

/// Spawns a real server on `dir`, waits until it serves, and writes a node so
/// the store has files on disk.
fn serveOn(gpa: std.mem.Allocator, dir: []const u8) !util.ServerHandle {
    const addr = try util.formatAddr(gpa, try util.getRandomPort());
    errdefer gpa.free(addr);
    var server = try util.spawnServer(gpa, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", dir }, null);
    server.addr = addr;
    errdefer server.deinit();
    try util.waitForServerReady(gpa, addr, 15_000);

    var client = try util.QuicProtoClient.connect(gpa, addr);
    defer client.deinit();
    var hello = try client.hello(gpa, util.defaultUsername(), util.defaultPassword());
    hello.deinit(gpa);
    var created = try client.executeAndCollect(gpa, "CREATE (:Sonny2413 {v: 1})", util.emptyParams(), 16);
    defer created.deinit(gpa);
    try std.testing.expect(created.error_code == null);
    return server;
}

test "SONNY-2413: a scratch dir is removed after the server holding it stops" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.heap.smp_allocator;
    const live_before = test_scratch.liveCount();

    var path_buf: [192]u8 = undefined;
    var path: []const u8 = undefined;
    {
        var scratch = try test_scratch.ScratchDir.create("success");
        defer scratch.remove();
        path = try std.fmt.bufPrint(&path_buf, "{s}", .{scratch.path()});
        try std.testing.expect(std.mem.startsWith(u8, path, try test_scratch.processRoot()));

        var server = try serveOn(gpa, scratch.path());
        defer server.deinit();
        try std.testing.expect(pathExists(path));
    }
    try std.testing.expect(!pathExists(path));
    try std.testing.expectEqual(live_before, test_scratch.liveCount());
}

fn failAfterServing(gpa: std.mem.Allocator, path_buf: *[192]u8, path: *[]const u8) !void {
    var scratch = try test_scratch.ScratchDir.create("error");
    defer scratch.remove();
    path.* = try std.fmt.bufPrint(path_buf, "{s}", .{scratch.path()});
    var server = try serveOn(gpa, scratch.path());
    defer server.deinit();
    return error.InjectedFailure;
}

test "SONNY-2413: a scratch dir is removed when the test using it fails" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.heap.smp_allocator;
    const live_before = test_scratch.liveCount();

    var path_buf: [192]u8 = undefined;
    var path: []const u8 = "";
    try std.testing.expectError(error.InjectedFailure, failAfterServing(gpa, &path_buf, &path));
    try std.testing.expect(path.len > 0);
    try std.testing.expect(!pathExists(path));
    try std.testing.expectEqual(live_before, test_scratch.liveCount());
}

test "SONNY-2413: the reaper removes the scratch root once its owner's pipe closes" {
    if (childMode() != null) return error.SkipZigTest;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var scratch = try test_scratch.ScratchDir.create("reaper");
    defer scratch.remove();
    const dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/watched", .{scratch.path()});
    defer std.testing.allocator.free(dir);
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var file_buf: [256]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&file_buf, "{s}/f", .{dir}), .data = "x" });

    var reaper = try test_scratch.startReaper(io, dir);
    sleepMs(200);
    try std.testing.expect(pathExists(dir));
    // What the kernel does to the write end when the owning process exits.
    reaper.stdin.?.close(io);
    reaper.stdin = null;
    _ = try reaper.wait(io);
    try std.testing.expect(!pathExists(dir));
}
