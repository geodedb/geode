// CANARY: REQ=REQ-SONNY-6386-REMOTE-BACKUP-ATOMIC; FEATURE="CLI Backup"; ASPECT=RemoteOutputAtomicDurable; STATUS=TESTED; TEST=tests/test_sonny6386_remote_backup_atomic_output.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6386 (3): `geode backup create --server` (executeRemoteBackup)
// opened --output with createFile (truncating any existing file), streamed
// the server's backup into it in place, never synced it, and on a failed
// transfer deleted it. So:
//   - a previous backup at --output was destroyed the moment the transfer
//     started, and gone for good if the transfer then failed;
//   - a crash or power loss after "Backup completed" could leave a short or
//     empty file under the backup's name.
//
// The contract: the backup is received into a private temporary file beside
// --output (0600, created exclusively), synced, and renamed onto --output,
// whose directory is then synced. --output is never written in place: a
// reader holding the previous backup open keeps reading it whole, and the
// name points at a new file only once the complete backup is on disk.
// Nothing else is left beside it.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn entryNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(fsIo())) |e| try names.append(allocator, try allocator.dupe(u8, e.name));
    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        try env.put("GEODE_LSP_PORT", "0");
        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        errdefer allocator.free(addr);
        const inherit = std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (inherit) .inherit else .ignore,
            .stderr = if (inherit) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 60_000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }
};

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6386 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(180), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

const sentinel = "SONNY6386-PREVIOUS-BACKUP-THAT-MUST-SURVIVE-UNTIL-THE-NEW-ONE-IS-COMPLETE\n";
const sentinel_copies = 512;

test "SONNY-6386 (3) geode backup create --server replaces --output by rename: the previous backup is never truncated in place, the new file is a complete 0600 backup, and nothing else is left beside it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6386-remote-backup");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const out_dir = try std.fmt.allocPrint(allocator, "{s}/out", .{root.path()});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), out_dir);
    const dest = try std.fmt.allocPrint(allocator, "{s}/nightly.backup", .{out_dir});
    defer allocator.free(dest);

    // The previous backup at --output.
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), dest, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(fsIo());
        for (0..sentinel_copies) |_| try f.writeStreamingAll(fsIo(), sentinel);
    }
    const old_stat = try std.Io.Dir.cwd().statFile(fsIo(), dest, .{});
    // A reader that has the previous backup open (a copy job, a restore).
    const held = try std.Io.Dir.cwd().openFile(fsIo(), dest, .{ .mode = .read_only });
    defer held.close(fsIo());

    var server = try Server.start(allocator, cwd, data_dir);
    defer server.stop(allocator);

    const r = try runGeode(&.{
        geode_binary, "backup",                  "create",
        "--server",   server.addr,               "--insecure-tls-skip-verify",
        "--user",     util.DefaultAuth.username, "--password",
        admin_pw,     "--output",                dest,
        "--timeout",  "120",
    }, cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("backup create --server");
    try testing.expectEqual(@as(?u8, 0), r.code);

    // The name now points at a different file: the backup was renamed onto
    // it, not streamed into the previous file.
    const new_stat = try std.Io.Dir.cwd().statFile(fsIo(), dest, .{});
    if (new_stat.inode == old_stat.inode) {
        std.debug.print("SONNY-6386 (3): --output was rewritten in place (same inode {d}); the previous backup was truncated as soon as the transfer started\n", .{old_stat.inode});
    }
    try testing.expect(new_stat.inode != old_stat.inode);

    // The reader holding the previous backup still reads all of it.
    {
        var buf: [sentinel.len * sentinel_copies + 64]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = try held.readPositional(fsIo(), &.{buf[total..]}, total);
            if (n == 0) break;
            total += n;
        }
        try testing.expectEqual(sentinel.len * sentinel_copies, total);
        var off: usize = 0;
        while (off < total) : (off += sentinel.len) try testing.expectEqualStrings(sentinel, buf[off .. off + sentinel.len]);
    }

    // The new file is a complete backup, owner-only.
    _ = try backup.readBackupHeader(dest);
    var decoded = try backup.readBackupFile(allocator, dest, null);
    decoded.deinit(allocator);
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(new_stat.permissions.toMode() & 0o777)));

    // Nothing else beside it (no temporary file left behind).
    const names = try entryNames(allocator, out_dir);
    defer freeNames(allocator, names);
    if (names.len != 1) {
        for (names) |n| std.debug.print("SONNY-6386 (3): {s} holds {s}\n", .{ out_dir, n });
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("nightly.backup", names[0]);
}

test "SONNY-6386 (3) a failed remote backup leaves an existing --output untouched" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6386-remote-backup-fail");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    const dest = try std.fmt.allocPrint(allocator, "{s}/nightly.backup", .{cwd});
    defer allocator.free(dest);
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), dest, .{});
        defer f.close(fsIo());
        try f.writeStreamingAll(fsIo(), sentinel);
    }

    var server = try Server.start(allocator, cwd, data_dir);
    defer server.stop(allocator);
    // Wrong password: the server refuses the session.
    const r = try runGeode(&.{
        geode_binary, "backup",                  "create",     "--server",            server.addr, "--insecure-tls-skip-verify",
        "--user",     util.DefaultAuth.username, "--password", "wrong-password-6386", "--output",  dest,
    }, cwd);
    defer r.deinit();
    if (r.code == @as(?u8, 0)) r.dump("backup create --server with a wrong password");
    try testing.expect(r.code != @as(?u8, 0));
    const after = try std.Io.Dir.cwd().readFileAlloc(fsIo(), dest, allocator, .limited(1 << 20));
    defer allocator.free(after);
    try testing.expectEqualStrings(sentinel, after);
    const names = try entryNames(allocator, cwd);
    defer freeNames(allocator, names);
    for (names) |n| try testing.expect(std.mem.indexOf(u8, n, ".tmp") == null);
}
