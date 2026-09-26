// SONNY-2778 regression: the generated admin password file.
//
// (1) Three writers put a generated admin password in `.geode_admin_password`:
//     `SecurityManager.init`, the server's first boot, and `geode auth init`.
//     They created it with O_CREAT | O_TRUNC and mode 0600 but no O_EXCL or
//     O_NOFOLLOW. A file already at the path kept its mode and owner, so a
//     pre-created world-readable file received the password, and a symbolic
//     link planted at the path was followed. `SecurityManager.init` wrote to
//     the current working directory when no data directory was set (a test
//     run left one in a source worktree), and the server did the same with no
//     data directory. Now every writer goes through
//     `geode_auth.writeAdminPasswordFile`: `<data_dir>/.geode_admin_password`,
//     O_CREAT | O_EXCL | O_NOFOLLOW, mode 0600 set again after the open, never
//     over anything already at the path, never in the cwd. Retrieval and
//     rotation are documented in docs/USER_AUTH.md.
// (2) The geode-auth tool's RLS engine leaked the policy strings
//     `UserManager.createPolicy` copies (the engine never frees a policy's
//     strings, SONNY-2773). The manager now owns them and frees them on
//     delete, on a failed create, on a replaced clause, and at deinit.
//
// CANARY: REQ=REQ-SONNY-2778-ADMIN-PASSWORD-FILE; FEATURE="Secure Default Password"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2778_admin_password_file.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");
const geode = @import("geode");

const linux = std.os.linux;
const graph_store = geode.graph_store;
const binary_path = "./zig-out/bin/geode";
const file_name = ".geode_admin_password";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn umask(mask: c_uint) c_uint;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn symlink(target: [*:0]const u8, link: [*:0]const u8) c_int;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A fresh directory under /tmp.
fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![:0]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrintSentinel(aa, "/tmp/geode-sonny2778-{s}-{d}", .{ tag, nowMillis() }, 0);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// The mode bits of `path` (not following a symbolic link), or null.
fn modeOf(path: [:0]const u8) ?u32 {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true }, &st);
    if (@as(isize, @bitCast(rc)) != 0) return null;
    return @as(u32, st.mode) & 0o7777;
}

fn readAll(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(4096));
}

fn writeFileMode(path: [:0]const u8, content: []const u8, mode: c_uint) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    try f.writeStreamingAll(io, content);
    f.close(io);
    if (chmod(path, mode) != 0) return error.ChmodFailed;
}

test "SONNY-2778: the password file is created 0600 whatever the umask, with the password" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "mode");
    defer removeDir(dir);

    // A umask that takes the owner's write bit away: the open gives 0400,
    // and the mode is set to 0600 again once the file is open.
    const old_mask = umask(0o277);
    defer _ = umask(old_mask);
    const path = try geode_auth.writeAdminPasswordFile(testing.allocator, dir, "s3cret-generated");
    defer testing.allocator.free(path);
    const pathz = try aa.dupeZ(u8, path);
    try testing.expectEqual(@as(?u32, 0o600), modeOf(pathz));
    try testing.expectEqualStrings("s3cret-generated", try readAll(aa, path));
}

test "SONNY-2778: nothing already at the path is written: a file, a symbolic link, a dangling link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A world-readable file planted at the path keeps its content and mode.
    {
        const dir = try freshDir(aa, "exists");
        defer removeDir(dir);
        const planted = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
        try writeFileMode(planted, "planted", 0o644);
        try testing.expectError(error.AdminPasswordFileExists, geode_auth.writeAdminPasswordFile(testing.allocator, dir, "s3cret"));
        try testing.expectEqualStrings("planted", try readAll(aa, planted));
        try testing.expectEqual(@as(?u32, 0o644), modeOf(planted));
    }
    // A symbolic link to a file the attacker can read is not followed.
    {
        const dir = try freshDir(aa, "symlink");
        defer removeDir(dir);
        const target = try std.fmt.allocPrintSentinel(aa, "{s}/attacker-readable", .{dir}, 0);
        try writeFileMode(target, "", 0o666);
        const link = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
        try testing.expect(symlink(target, link) == 0);
        try testing.expectError(error.AdminPasswordFileExists, geode_auth.writeAdminPasswordFile(testing.allocator, dir, "s3cret"));
        try testing.expectEqualStrings("", try readAll(aa, target));
    }
    // A dangling link does not create its target.
    {
        const dir = try freshDir(aa, "dangling");
        defer removeDir(dir);
        const target = try std.fmt.allocPrintSentinel(aa, "{s}/would-be-created", .{dir}, 0);
        const link = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
        try testing.expect(symlink(target, link) == 0);
        try testing.expectError(error.AdminPasswordFileExists, geode_auth.writeAdminPasswordFile(testing.allocator, dir, "s3cret"));
        try testing.expect(modeOf(target) == null);
    }
}

fn fileExists(path: [:0]const u8) bool {
    return modeOf(path) != null;
}

test "SONNY-2778: SecurityManager.init never writes the password into the working directory, nor over a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // Memoize Zig's view of the environment before changing it (see
    // geode_auth_lib.zig's SONNY-2394 test).
    _ = std.Io.Threaded.global_single_threaded.environString("PATH");
    _ = unsetenv("GEODE_DEFAULT_PASSWORD");
    _ = unsetenv("GEODE_DATA_DIR");
    defer _ = unsetenv("GEODE_DATA_DIR");

    // No data directory: no file anywhere, and none in the cwd. (Without the
    // fix this wrote one into the cwd, the source tree; it is removed again.)
    const in_cwd: [:0]const u8 = "./" ++ file_name;
    const was_there = fileExists(in_cwd);
    defer if (!was_there) std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), in_cwd) catch {};
    {
        var sm = try geode_auth.SecurityManager.init(testing.allocator);
        sm.deinit();
    }
    if (!was_there) try testing.expect(!fileExists(in_cwd));

    // A data directory holding a planted file: it is left as it was.
    const dir = try freshDir(aa, "sm");
    defer removeDir(dir);
    const planted = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
    try writeFileMode(planted, "planted", 0o644);
    try testing.expect(setenv("GEODE_DATA_DIR", dir, 1) == 0);
    {
        var sm = try geode_auth.SecurityManager.init(testing.allocator);
        sm.deinit();
    }
    try testing.expectEqualStrings("planted", try readAll(aa, planted));
    try testing.expectEqual(@as(?u32, 0o644), modeOf(planted));
}

const Run = struct { code: ?u8, output: []const u8 };

/// Run the geode binary with a minimal environment (no admin password
/// variables, so the password is generated). With `until`, stop the process
/// once its output shows that text, or after `deadline_ms`.
fn runGeode(aa: std.mem.Allocator, io: std.Io, args: []const []const u8, until: ?[]const u8, deadline_ms: i64) !Run {
    var env = std.process.Environ.Map.init(aa);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    if (std.c.getenv("HOME")) |p| try env.put("HOME", std.mem.span(p));
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const pid = child.id orelse return error.NoPid;
    var output: std.ArrayList(u8) = .empty;
    const t0 = nowMillis();
    var code: ?u8 = null;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                const flags = linux.fcntl(f.handle, linux.F.GETFL, 0);
                _ = linux.fcntl(f.handle, linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) > 0) try output.appendSlice(aa, buf[0..n]);
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        const seen = if (until) |marker| std.mem.indexOf(u8, output.items, marker) != null else false;
        if (seen or nowMillis() - t0 > deadline_ms) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| f.close(io);
    }
    return .{ .code = code, .output = output.items };
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, binary_path, .{}) catch return false;
    return true;
}

test "SONNY-2778: geode auth init writes a 0600 file, and refuses to write over a planted one" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    {
        const dir = try freshDir(aa, "init-clean");
        defer removeDir(dir);
        const run = try runGeode(aa, threaded.io(), &.{ binary_path, "auth", "init", "--data-dir", dir }, null, 60_000);
        if (run.code != 0) std.debug.print("{s}\n", .{run.output});
        try testing.expectEqual(@as(?u8, 0), run.code);
        const path = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
        try testing.expectEqual(@as(?u32, 0o600), modeOf(path));
        // The bootstrap password: 16 random bytes, as 32 hex digits.
        const written = try readAll(aa, path);
        try testing.expectEqual(@as(usize, 32), written.len);
        for (written) |c| try testing.expect(std.ascii.isHex(c));
    }
    {
        const dir = try freshDir(aa, "init-planted");
        defer removeDir(dir);
        const planted = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
        try writeFileMode(planted, "planted", 0o644);
        const run = try runGeode(aa, threaded.io(), &.{ binary_path, "auth", "init", "--data-dir", dir }, null, 60_000);
        try testing.expect(run.code != null and run.code.? != 0);
        try testing.expect(std.mem.indexOf(u8, run.output, "never overwritten") != null);
        try testing.expectEqualStrings("planted", try readAll(aa, planted));
        try testing.expectEqual(@as(?u32, 0o644), modeOf(planted));
        // The refusal came before the admin was created: once the file is
        // gone, `auth init` runs (it refuses a store that has records).
        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().deleteFile(io, planted);
        const again = try runGeode(aa, threaded.io(), &.{ binary_path, "auth", "init", "--data-dir", dir }, null, 60_000);
        if (again.code != 0) std.debug.print("{s}\n", .{again.output});
        try testing.expectEqual(@as(?u8, 0), again.code);
        try testing.expectEqual(@as(?u32, 0o600), modeOf(planted));
    }
}

test "SONNY-2778: a first-booting server writes nothing through a symbolic link planted at the path" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const dir = try freshDir(aa, "serve");
    defer removeDir(dir);
    const outside = try freshDir(aa, "outside");
    defer removeDir(outside);
    const target = try std.fmt.allocPrintSentinel(aa, "{s}/attacker-readable", .{outside}, 0);
    try writeFileMode(target, "", 0o666);
    const link = try std.fmt.allocPrintSentinel(aa, "{s}/" ++ file_name, .{dir}, 0);
    try testing.expect(symlink(target, link) == 0);

    var port_buf: [32]u8 = undefined;
    const port: u16 = @intCast(20000 + @mod(nowMillis(), 20000));
    const listen = try std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{port});
    const run = try runGeode(aa, threaded.io(), &.{ binary_path, "serve", "--listen", listen, "--data-dir", dir }, "[startup] server ready", 90_000);
    if (std.mem.indexOf(u8, run.output, "NOT written") == null) {
        std.debug.print("server output:\n{s}\n", .{run.output});
        return error.NoRefusalReported;
    }
    // Nothing reached the link's target.
    try testing.expectEqualStrings("", try readAll(aa, target));
}

// ---------------------------------------------------------------------------
// (2) The geode-auth tool's policy strings.
// ---------------------------------------------------------------------------

test "SONNY-2778: UserManager frees the policy strings it copies (leak-checked)" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    // The security manager is not under test (it holds the roles); it gets an
    // arena of its own.
    var sm_arena = std.heap.ArenaAllocator.init(allocator);
    defer sm_arena.deinit();
    var security_manager = try geode_auth.SecurityManager.initEmpty(sm_arena.allocator());
    defer security_manager.deinit();
    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();
    var backend = try user_storage.UserStorageBackend.init(allocator, &store);
    defer backend.deinit();
    var mgr = try user_manager.UserManager.init(allocator, &security_manager, &rls_engine, &backend);
    defer mgr.deinit();

    const request = user_manager.UserManager.CreatePolicyRequest{
        .name = "p",
        .description = "RLS policy",
        .graph = "default",
        .table = "orders",
        .operation = .select,
        .roles = &[_][]const u8{"user"},
    };
    // Created, kept, and deleted: the strings go with the policy.
    const kept = try mgr.createPolicy(request);
    var second = request;
    second.name = "q";
    const deleted = try mgr.createPolicy(second);
    try mgr.deletePolicy(deleted);
    // A clause that does not compile: nothing installed, nothing leaked.
    var bad = request;
    bad.name = "bad";
    bad.using_clause = "row.x = ";
    try testing.expectError(error.InvalidRlsExpression, mgr.createPolicy(bad));
    // Disabled, which replaces no clause.
    try mgr.updatePolicy(kept, false, null, null);
    // `mgr.deinit` frees the rest.
}
