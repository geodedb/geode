// `geode backup create` must not turn a failed remote backup into a local one.
//
// The CLI used to catch any error from the remote (QUIC) backup, run a local
// data-directory backup instead, and print "Backup created successfully" with
// exit 0. The caller got a different backup than the one asked for, and with
// GEODE_DATA_DIR unset the storage layer read all of /tmp as the data
// directory (one run reached 10 GB RSS). Now a remote failure exits non-zero
// and leaves no output file; the local path runs only with --local and a
// data directory given by --data-dir or GEODE_DATA_DIR.
//
// Spawns ./zig-out/bin/geode (the build step installs it first). No server is
// started: the remote side is a closed loopback port. Every child is capped
// at 60 s.
//
// CANARY: REQ=REQ-BACKUP-CLI-001; FEATURE="CLI Backup"; ASPECT=RemoteFailureIsAnError; STATUS=TESTED; TEST=tests/test_backup_create_remote_failure.zig; OWNER=cli; UPDATED=2026-10-24

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const geode_binary = "./zig-out/bin/geode";
// Nothing listens on UDP port 1 on loopback.
const dead_server = "127.0.0.1:1";

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }
};

fn absTmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/{s}", .{ cwd, &tmp.sub_path, name });
}

/// Run geode with a minimal environment: PATH and HOME from the parent, plus
/// GEODE_DATA_DIR only when `data_dir` is given.
fn runGeode(argv: []const []const u8, data_dir: ?[]const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    if (data_dir) |d| try env.put("GEODE_DATA_DIR", d);

    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(60), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn expectRemoteFailureReported(r: Run, out_path: []const u8) !void {
    if (r.code == null or r.code.? == 0 or r.output("Backup created successfully") or
        r.output("Local backup completed") or fileExists(out_path))
    {
        std.debug.print("exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ r.code, r.stdout, r.stderr });
    }
    try testing.expect(r.code != null);
    try testing.expectEqual(@as(u8, 1), r.code.?);
    try testing.expect(!r.output("Backup created successfully"));
    try testing.expect(!r.output("Local backup completed"));
    try testing.expect(!r.output("Attempting local data directory backup"));
    try testing.expect(r.output("No backup was created"));
    try testing.expect(!fileExists(out_path));
}

test "remote backup failure exits non-zero instead of falling back to a local backup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try absTmpPath(testing.allocator, &tmp, "");
    defer testing.allocator.free(data_dir);
    const out_path = try absTmpPath(testing.allocator, &tmp, "remote.backup");
    defer testing.allocator.free(out_path);

    // GEODE_DATA_DIR points at an empty directory so the old fallback, if it
    // came back, would succeed quickly rather than read a real data dir.
    const r = try runGeode(&.{ geode_binary, "backup", "create", "--output", out_path, "--server", dead_server }, data_dir);
    defer r.deinit();
    try expectRemoteFailureReported(r, out_path);
}

test "remote backup failure with GEODE_DATA_DIR unset does not read /tmp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try absTmpPath(testing.allocator, &tmp, "remote.backup");
    defer testing.allocator.free(out_path);

    const r = try runGeode(&.{ geode_binary, "backup", "create", "--output", out_path, "--server", dead_server }, null);
    defer r.deinit();
    try expectRemoteFailureReported(r, out_path);
}

test "--local without a data directory is a usage error" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try absTmpPath(testing.allocator, &tmp, "local.backup");
    defer testing.allocator.free(out_path);

    const r = try runGeode(&.{ geode_binary, "backup", "create", "--output", out_path, "--local" }, null);
    defer r.deinit();
    try testing.expectEqual(@as(?u8, 2), r.code);
    try testing.expect(r.output("--local requires --data-dir"));
    try testing.expect(!fileExists(out_path));
}

test "--local --data-dir creates a local backup without contacting a server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "data");
    const data_dir = try absTmpPath(testing.allocator, &tmp, "data");
    defer testing.allocator.free(data_dir);
    const out_path = try absTmpPath(testing.allocator, &tmp, "local.backup");
    defer testing.allocator.free(out_path);

    // --server names the dead port: --local must not touch it.
    const r = try runGeode(&.{ geode_binary, "backup", "create", "--output", out_path, "--local", "--data-dir", data_dir, "--server", dead_server }, null);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output("Local backup completed"));
    try testing.expect(fileExists(out_path));
}
