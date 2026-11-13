// CANARY: REQ=REQ-SONNY-6499-RELATIVE-DATA-DIR; FEATURE="Server Startup"; ASPECT=RelativeDataDirAndRefusalCleanup; STATUS=TESTED; TEST=tests/test_sonny6499_relative_data_dir.zig; OWNER=security; UPDATED=2026-11-13
//
// SONNY-6499 item 3: `geode serve --data-dir <relative path>` behaves as the
// absolute path does.
//
// Before: a relative --data-dir with a `..` segment (`../X`) on a FRESH
// directory refused to start with "HMAC key required" (the store has no
// auth record): the server carried the path as given, and a component that
// opened the auth state under it failed, which the startup guard
// (`storeHasAuthRecords`) reads as "records exist" (fail closed). And every
// startup refusal after the index catalog was set up leaked it (5
// allocations reported by the debug allocator on stderr).
//
// Real binary, real data directories; no mocks.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

const Run = struct {
    code: ?u8,
    text: []u8,
    killed: bool,

    fn deinit(self: Run) void {
        testing.allocator.free(self.text);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6499 {s}: exit={?d} killed={}\n{s}\n", .{ what, self.code, self.killed, self.text });
    }
};

/// Runs `geode serve` until it exits, or until `stop_on` appears in its
/// output (then SIGTERM, a clean shutdown), or `timeout_s` passes (SIGKILL).
fn serve(data_dir: []const u8, env_kv: []const [2][]const u8, cwd: []const u8, stop_on: ?[]const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    const addr = try util.formatAddr(testing.allocator, try test_ports.freeUdpPort());
    defer testing.allocator.free(addr);
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/run-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
    const child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_binary, "serve", "--listen", addr, "--lsp-port=0", "--data-dir", data_dir },
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var killed = false;
    var signalled = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (!signalled) {
            if (stop_on) |needle| {
                const so_far = std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) catch "";
                defer if (so_far.len > 0) testing.allocator.free(so_far);
                if (std.mem.indexOf(u8, so_far, needle) != null) {
                    posix.kill(pid, .TERM) catch {};
                    signalled = true;
                }
            }
        }
        if (waited_ms >= timeout_s * 1000) {
            posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            killed = true;
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .text = text, .killed = killed };
}

const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        return .{ .root = root, .cwd = cwd };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        self.root.remove();
    }
};

const pw_env = [_][2][]const u8{.{ "GEODE_ADMIN_PASSWORD", admin_pw }};

/// First boot of `given` (as passed to --data-dir, from the fixture's cwd)
/// whose real location is `real`: the server starts, its HMAC key is in
/// `real`, and it shuts down cleanly.
fn checkFirstBoot(allocator: std.mem.Allocator, fx: *Fixture, given: []const u8, real: []const u8) !void {
    const r = try serve(given, &pw_env, fx.cwd, "server ready", 90);
    defer r.deinit();
    const ok = r.output("server ready") and !r.output("HMAC key required") and !r.killed;
    if (!ok) r.dump(given);
    try testing.expect(r.output("server ready"));
    try testing.expect(!r.output("HMAC key required"));
    try testing.expect(!r.killed);
    const key = try join(allocator, real, ".geode_hmac_key");
    defer allocator.free(key);
    try testing.expect(pathExists(key));
}

test "SONNY-6499 (3) a relative --data-dir with a '..' segment starts on a fresh directory, as the absolute path does" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6499-reldir");
    defer fx.deinit(allocator);

    const abs = try join(allocator, fx.root.path(), "ABS");
    defer allocator.free(abs);
    try checkFirstBoot(allocator, &fx, abs, abs);

    // The same kind of directory, named relative to the working directory
    // through its parent.
    const real = try join(allocator, fx.root.path(), "REL");
    defer allocator.free(real);
    try checkFirstBoot(allocator, &fx, "../REL", real);
    // A restart from the same relative name finds its key and records.
    try checkFirstBoot(allocator, &fx, "../REL", real);
}

test "SONNY-6499 (3) a startup refusal frees what startup allocated (relative and absolute --data-dir)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6499-refusal");
    defer fx.deinit(allocator);
    const real = try join(allocator, fx.root.path(), "X");
    defer allocator.free(real);
    try checkFirstBoot(allocator, &fx, real, real);

    // Auth records and no key: the documented refusal (SONNY-6322).
    const key = try join(allocator, real, ".geode_hmac_key");
    defer allocator.free(key);
    const saved = try join(allocator, fx.root.path(), "saved_key");
    defer allocator.free(saved);
    try std.Io.Dir.cwd().rename(key, std.Io.Dir.cwd(), saved, fsIo());

    for ([_][]const u8{ real, "../X" }) |given| {
        const r = try serve(given, &pw_env, fx.cwd, null, 90);
        defer r.deinit();
        const ok = r.code != null and r.code.? != 0 and r.output("HMAC key required") and !r.output("leaked");
        if (!ok) r.dump(given);
        try testing.expect(r.code != null and r.code.? != 0);
        try testing.expect(r.output("HMAC key required"));
        // The debug allocator reports every allocation still live at exit.
        try testing.expect(!r.output("leaked"));
    }
}
