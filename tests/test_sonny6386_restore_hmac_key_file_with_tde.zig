// CANARY: REQ=REQ-SONNY-6386-RESTORE-HMAC-FILE-TDE; FEATURE="Backup Restore"; ASPECT=HmacKeyFileVsTdeKeyExplained; STATUS=TESTED; TEST=tests/test_sonny6386_restore_hmac_key_file_with_tde.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6386 (7): `geode restore <file> --hmac-key-file <f>` is refused when
// GEODE_TDE_KEY (or GEODE_AUTH_HMAC_KEY) is set, because a server with
// GEODE_TDE_KEY set derives its auth-chain HMAC key from it
// (GEODE_AUTH_HMAC_KEY takes precedence) and never reads .geode_hmac_key: a
// planted key file would be ignored at the next start. An encrypted backup
// (written with GEODE_TDE_KEY set) needs GEODE_TDE_KEY to decrypt, so for it
// --hmac-key-file can never be used. Nothing said so: the help listed
// --hmac-key-file and the environment keys as alternatives, and the refusal
// read "both are set; a server uses the environment key, so give one".
//
// The contract: the help says the two cannot be combined and why; the
// refusal names both, explains that the key is derived from GEODE_TDE_KEY
// and the key file is never read, says how to restore (the source server's
// GEODE_TDE_KEY, without --hmac-key-file), and restores nothing; and that
// documented path, the same backup restored with GEODE_TDE_KEY alone,
// succeeds.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;
const tde_key = "6386638663866386638663866386638663866386638663866386638663866386";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

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

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6386 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, env_kv: []const [2][]const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(300), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// Serves `data_dir` once with GEODE_TDE_KEY set (first boot: the admin user
/// is created in __geode_security, sealed with the key derived from it).
fn seedStore(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
    try env.put("GEODE_LSP_PORT", "0");
    try env.put("GEODE_TDE_KEY", tde_key);
    const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
    defer allocator.free(addr);
    var child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const ready = util.waitForServerReady(allocator, addr, 60_000);
    if (child.id) |pid| {
        posix.kill(pid, .TERM) catch {};
        var waited: u32 = 0;
        while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
        if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
        _ = child.wait(threaded.io()) catch {};
    }
    try ready;
}

test "SONNY-6386 (7) restore refuses --hmac-key-file with GEODE_TDE_KEY set, explains why and how to restore, restores nothing; GEODE_TDE_KEY alone restores" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6386-restore-hmac");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    const src = try std.fmt.allocPrint(allocator, "{s}/src", .{root.path()});
    defer allocator.free(src);
    const backup_file = try std.fmt.allocPrint(allocator, "{s}/full.backup", .{cwd});
    defer allocator.free(backup_file);
    const key_file = try std.fmt.allocPrint(allocator, "{s}/hmac.key", .{cwd});
    defer allocator.free(key_file);
    const target = try std.fmt.allocPrint(allocator, "{s}/restored", .{root.path()});
    defer allocator.free(target);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);

    try seedStore(allocator, cwd, src);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", src, "--output", backup_file }, cwd, &.{.{ "GEODE_TDE_KEY", tde_key }});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("backup create --local");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), key_file, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(fsIo());
        try f.writeStreamingAll(fsIo(), "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n");
    }

    {
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes", "--hmac-key-file", key_file }, cwd, &.{.{ "GEODE_TDE_KEY", tde_key }});
        defer r.deinit();
        const needles = [_][]const u8{ "--hmac-key-file cannot be used with GEODE_TDE_KEY", "derives", "never reads .geode_hmac_key", "without --hmac-key-file" };
        var ok = r.code != null and r.code.? != 0 and !pathExists(target);
        for (needles) |n| ok = ok and r.output(n);
        if (!ok) r.dump("restore --hmac-key-file with GEODE_TDE_KEY");
        try testing.expect(r.code != null and r.code.? != 0);
        for (needles) |n| try testing.expect(r.output(n));
        try testing.expect(!pathExists(target));
    }
    {
        const r = try runGeode(&.{ geode_binary, "restore", "--help" }, cwd, &.{});
        defer r.deinit();
        const ok = r.output("--hmac-key-file cannot be combined with GEODE_TDE_KEY");
        if (!ok) r.dump("restore --help");
        try testing.expect(ok);
    }
    // The documented path: GEODE_TDE_KEY alone (it decrypts the backup and
    // is the HMAC key source).
    {
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes" }, cwd, &.{.{ "GEODE_TDE_KEY", tde_key }});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("restore with GEODE_TDE_KEY alone");
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(pathExists(target));
    }
}
