// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6551 item 4: the server's default data directory never goes under
// the working directory.
//
// `graph_store.defaultDataDir` joined a relative XDG_STATE_HOME or HOME
// as given, so `geode serve` with no --data-dir / GEODE_DATA_DIR and
// `XDG_STATE_HOME=relstate` (or `HOME=relhome`) put the whole data
// directory, HMAC key included, at `<cwd>/relstate/geode` (or
// `<cwd>/relhome/.local/state/geode`). The XDG Base Directory
// specification says a relative value is invalid and must be ignored; a
// relative HOME is not a home directory either. An explicit relative
// --data-dir keeps working (test-sonny6499-relative-data-dir).
//
// Real `geode serve` binary, run in a scratch working directory with a
// scratch TMPDIR; no mocks.
//
// CANARY: REQ=REQ-SONNY-6551-DEFAULT-DATA-DIR-ABSOLUTE; FEATURE="DataDirLock"; ASPECT=RelativeXdgAndHomeIgnored; STATUS=TESTED; TEST=tests/test_sonny6551_relative_state_home.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
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

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6551 {s}: exit={?d} killed={}\n{s}\n", .{ what, self.code, self.killed, self.text });
    }
};

/// `geode serve` with no --data-dir, `env` only (no GEODE_DATA_DIR), in
/// `cwd`; SIGTERM once "server ready" is printed, SIGKILL after 90 s.
fn serve(env_kv: []const [2][]const u8, cwd: []const u8, out_dir: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    const addr = try util.formatAddr(testing.allocator, try test_ports.freeUdpPort());
    defer testing.allocator.free(addr);
    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/serve.out", .{out_dir});
    defer testing.allocator.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--lsp-port=0" },
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
            const so_far = std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) catch "";
            defer if (so_far.len > 0) testing.allocator.free(so_far);
            if (std.mem.indexOf(u8, so_far, "server ready") != null) {
                posix.kill(pid, .TERM) catch {};
                signalled = true;
            }
        }
        if (waited_ms >= 90_000) {
            posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            killed = true;
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .text = text, .killed = killed };
}

const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    tmp: []u8,
    home: []u8,

    fn init(tag: []const u8) !Fixture {
        const a = testing.allocator;
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try std.fmt.allocPrint(a, "{s}/cwd", .{root.path()});
        errdefer a.free(cwd);
        const tmp = try std.fmt.allocPrint(a, "{s}/tmp", .{root.path()});
        errdefer a.free(tmp);
        const home = try std.fmt.allocPrint(a, "{s}/home", .{root.path()});
        errdefer a.free(home);
        for ([_][]const u8{ cwd, tmp, home }) |p| try std.Io.Dir.cwd().createDirPath(fsIo(), p);
        return .{ .root = root, .cwd = cwd, .tmp = tmp, .home = home };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.cwd);
        testing.allocator.free(self.tmp);
        testing.allocator.free(self.home);
        self.root.remove();
    }

    /// Nothing was created in the working directory.
    fn expectCwdEmpty(self: *Fixture, r: Run, label: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(fsIo(), self.cwd, .{ .iterate = true });
        defer dir.close(fsIo());
        var it = dir.iterate();
        if (try it.next(fsIo())) |entry| {
            r.dump(label);
            std.debug.print("SONNY-6551 {s}: '{s}' was created in the working directory\n", .{ label, entry.name });
            return error.CreatedUnderWorkingDirectory;
        }
    }
};

fn expectStarted(r: Run, label: []const u8) !void {
    if (!r.has("server ready") or r.killed) {
        r.dump(label);
        return error.ServerDidNotStart;
    }
}

fn expectKeyIn(r: Run, dir: []const u8, label: []const u8) !void {
    const key = try std.fmt.allocPrint(testing.allocator, "{s}/.geode_hmac_key", .{dir});
    defer testing.allocator.free(key);
    if (!pathExists(key)) {
        r.dump(label);
        std.debug.print("SONNY-6551 {s}: no data directory at {s}\n", .{ label, dir });
        return error.DataDirNotWhereExpected;
    }
}

test "SONNY-6551 (4): a relative XDG_STATE_HOME is ignored; the data directory goes under the absolute HOME" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6551-xdg-rel");
    defer fx.deinit();

    const r = try serve(&.{
        .{ "XDG_STATE_HOME", "relstate" },
        .{ "HOME", fx.home },
        .{ "TMPDIR", fx.tmp },
    }, fx.cwd, fx.root.path());
    defer r.deinit();
    try expectStarted(r, "XDG_STATE_HOME=relstate");
    try fx.expectCwdEmpty(r, "XDG_STATE_HOME=relstate");
    const want = try std.fmt.allocPrint(testing.allocator, "{s}/.local/state/geode", .{fx.home});
    defer testing.allocator.free(want);
    try expectKeyIn(r, want, "XDG_STATE_HOME=relstate");
}

test "SONNY-6551 (4): a relative HOME (and XDG_STATE_HOME) falls back to the private per-user TMPDIR directory" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6551-home-rel");
    defer fx.deinit();

    for ([_][]const u8{ "relhome", "./relhome" }) |rel_home| {
        const r = try serve(&.{
            .{ "XDG_STATE_HOME", "relstate" },
            .{ "HOME", rel_home },
            .{ "TMPDIR", fx.tmp },
        }, fx.cwd, fx.root.path());
        defer r.deinit();
        try expectStarted(r, rel_home);
        try fx.expectCwdEmpty(r, rel_home);
        const want = try std.fmt.allocPrint(testing.allocator, "{s}/geode-{d}", .{ fx.tmp, linux.getuid() });
        defer testing.allocator.free(want);
        try expectKeyIn(r, want, rel_home);
    }
}

test "SONNY-6551 (4): an absolute XDG_STATE_HOME is still used" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6551-xdg-abs");
    defer fx.deinit();

    const state = try std.fmt.allocPrint(testing.allocator, "{s}/state", .{fx.root.path()});
    defer testing.allocator.free(state);
    const r = try serve(&.{
        .{ "XDG_STATE_HOME", state },
        .{ "HOME", fx.home },
        .{ "TMPDIR", fx.tmp },
    }, fx.cwd, fx.root.path());
    defer r.deinit();
    try expectStarted(r, "XDG_STATE_HOME absolute");
    try fx.expectCwdEmpty(r, "XDG_STATE_HOME absolute");
    const want = try std.fmt.allocPrint(testing.allocator, "{s}/geode", .{state});
    defer testing.allocator.free(want);
    try expectKeyIn(r, want, "XDG_STATE_HOME absolute");
}
