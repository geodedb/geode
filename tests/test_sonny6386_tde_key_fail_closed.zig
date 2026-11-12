// CANARY: REQ=REQ-SONNY-6386-TDE-KEY-FAIL-CLOSED; FEATURE="TDE baseline"; ASPECT=MalformedKeyRefusesStartup; STATUS=TESTED; TEST=tests/test_sonny6386_tde_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6386 (1): `initGlobalAdapter` loaded the page-encryption key with
// `tde.loadKey(allocator) catch null`. A GEODE_TDE_KEY that is set but is
// not 64 hex characters therefore opened the store with NO encryption key,
// and every page was written in plaintext while the operator believed TDE
// was on. The same class of swallow sat in two other key loaders:
//   - `wal.loadWalKey`: a GEODE_WAL_KEY of the wrong length was skipped, so
//     the WAL fell back to GEODE_TDE_KEY or, when that was unset, plaintext;
//   - `AuthGraphManager.resolveHmacKey`: a GEODE_TDE_KEY of the wrong length
//     was skipped and the auth chain was sealed with the file key instead.
//
// The contract: a key variable that is set (non-empty) but unusable is an
// error everywhere, never "no key". `geode serve` refuses to start, says
// which variable is wrong and what it must be, does not echo the value, and
// creates nothing in the data directory. An unset (or empty) GEODE_TDE_KEY
// keeps today's behaviour: the store opens without page encryption.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const auth_graph_manager = @import("auth_graph_manager");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;
const graph_store = geode.graph_store;
const geode_binary = geode_test_bin.geode_exe;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

fn entryCount(dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(fsIo())) |_| n += 1;
    return n;
}

/// Runs `env_name=value` for the duration of a test; restores "unset".
const EnvGuard = struct {
    name: [*:0]const u8,

    fn set(name: [*:0]const u8, value: [*:0]const u8) EnvGuard {
        _ = setenv(name, value, 1);
        return .{ .name = name };
    }

    fn restore(self: EnvGuard) void {
        _ = unsetenv(self.name);
    }
};

fn clearKeyEnv() void {
    _ = unsetenv("GEODE_TDE_KEY");
    _ = unsetenv("GEODE_WAL_KEY");
    _ = unsetenv("GEODE_AUTH_HMAC_KEY");
}

const Run = struct {
    code: ?u8,
    killed: bool,
    text: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.text);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6386 {s}: exit={?d} killed_at_timeout={}\noutput:\n{s}\n", .{ what, self.code, self.killed, self.text });
    }
};

/// Runs `geode serve` with a hard deadline; a server still running at the
/// deadline is killed and reported as `killed` (it started).
fn runServe(cwd: []const u8, data_dir: []const u8, tde_key: []const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6386-Admin-pw1");
    try env.put("GEODE_LSP_PORT", "0");
    try env.put("GEODE_TDE_KEY", tde_key);
    var port_buf: [32]u8 = undefined;
    const addr = try std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{try test_ports.freeUdpPort()});
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/serve-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
    const child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            posix.kill(pid, .TERM) catch {};
            var grace: u32 = 0;
            while (grace < 10_000) : (grace += 100) {
                if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) break;
                sleepMs(100);
            } else {
                posix.kill(pid, .KILL) catch {};
                _ = linux.waitpid(pid, &status, 0);
            }
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .killed = !exited, .text = text };
}

// A server that starts comes up in a few seconds; one still running at this
// deadline accepted the key.
const serve_deadline_s: i64 = 30;

const malformed_keys = [_][]const u8{
    // Too short (a typo, a truncated paste).
    "not-a-tde-key-sonny6386",
    // 64 characters, not hex.
    "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg",
    // 63 hex characters (one short).
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde",
};

test "SONNY-6386 (1) geode serve refuses a set but malformed GEODE_TDE_KEY, names it, does not echo it, and creates nothing in the data directory" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    for (malformed_keys, 0..) |bad_key, i| {
        var root = try test_scratch.ScratchDir.create("sonny6386-serve");
        defer root.remove();
        const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
        defer allocator.free(cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        // The data directory does not exist yet: a refused start creates it
        // no more than it writes pages into it.
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/data{d}", .{ root.path(), i });
        defer allocator.free(data_dir);

        const r = try runServe(cwd, data_dir, bad_key, serve_deadline_s);
        defer r.deinit();
        const refused = r.code != null and r.code.? != 0;
        const ok = refused and r.output("GEODE_TDE_KEY") and r.output("64 hex characters") and
            r.output("refusing to start") and !r.output(bad_key) and !pathExists(data_dir);
        if (!ok) {
            r.dump(bad_key);
            if (pathExists(data_dir)) std.debug.print("SONNY-6386: the data directory {s} was created ({d} entries)\n", .{ data_dir, entryCount(data_dir) catch 0 });
        }
        try testing.expect(!r.killed);
        try testing.expect(refused);
        try testing.expect(r.output("GEODE_TDE_KEY"));
        try testing.expect(r.output("64 hex characters"));
        try testing.expect(r.output("refusing to start"));
        // The rejected value is a secret; it is never printed.
        try testing.expect(!r.output(bad_key));
        try testing.expect(!pathExists(data_dir));
    }
}

test "SONNY-6386 (1) initGlobalAdapter fails with InvalidKey on a malformed GEODE_TDE_KEY and writes nothing; unset and empty keys still open the store" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;

    for (malformed_keys) |bad_key| {
        var root = try test_scratch.ScratchDir.create("sonny6386-adapter");
        defer root.remove();
        const key_z = try allocator.dupeZ(u8, bad_key);
        defer allocator.free(key_z);
        const g = EnvGuard.set("GEODE_TDE_KEY", key_z);
        defer g.restore();
        const result = graph_store.initGlobalAdapter(allocator, root.path());
        if (result) |_| {
            graph_store.deinitGlobalAdapter();
            std.debug.print("SONNY-6386: initGlobalAdapter opened the store with GEODE_TDE_KEY='{s}' (pages unencrypted)\n", .{bad_key});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.InvalidKey, err);
        }
        try testing.expectEqual(@as(usize, 0), try entryCount(root.path()));
    }

    // Unset: today's behaviour, the store opens (without page encryption).
    {
        var root = try test_scratch.ScratchDir.create("sonny6386-adapter-unset");
        defer root.remove();
        _ = try graph_store.initGlobalAdapter(allocator, root.path());
        graph_store.deinitGlobalAdapter();
    }
    // Empty is unset.
    {
        var root = try test_scratch.ScratchDir.create("sonny6386-adapter-empty");
        defer root.remove();
        const g = EnvGuard.set("GEODE_TDE_KEY", "");
        defer g.restore();
        _ = try graph_store.initGlobalAdapter(allocator, root.path());
        graph_store.deinitGlobalAdapter();
    }
}

test "SONNY-6386 (1) a GEODE_WAL_KEY of the wrong length fails the WAL open instead of falling back to GEODE_TDE_KEY or plaintext" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6386-wal");
    defer root.remove();
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/graph.wal", .{root.path()});
    defer allocator.free(wal_path);

    {
        const g = EnvGuard.set("GEODE_WAL_KEY", "abcdef");
        defer g.restore();
        if (geode.wal.WriteAheadLog.init(allocator, wal_path)) |w| {
            var wal = w;
            wal.deinit();
            std.debug.print("SONNY-6386: a 6-character GEODE_WAL_KEY opened the WAL without encryption\n", .{});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.InvalidKey, err);
        }
    }
    // With a valid GEODE_TDE_KEY to fall back to, a bad GEODE_WAL_KEY is
    // still refused (not silently replaced by the other key).
    {
        const t = EnvGuard.set("GEODE_TDE_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        defer t.restore();
        const g = EnvGuard.set("GEODE_WAL_KEY", "abcdef");
        defer g.restore();
        if (geode.wal.WriteAheadLog.init(allocator, wal_path)) |w| {
            var wal = w;
            wal.deinit();
            std.debug.print("SONNY-6386: a 6-character GEODE_WAL_KEY was replaced by GEODE_TDE_KEY\n", .{});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.InvalidKey, err);
        }
    }
    try testing.expect(!pathExists(wal_path));
}

test "SONNY-6386 (1) resolveHmacKey refuses a GEODE_TDE_KEY of the wrong length instead of sealing with the file key" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    var root = try test_scratch.ScratchDir.create("sonny6386-hmac");
    defer root.remove();
    const g = EnvGuard.set("GEODE_TDE_KEY", "not-a-tde-key-sonny6386");
    defer g.restore();
    const AGM = auth_graph_manager.AuthGraphManager;
    if (AGM.resolveHmacKey(testing.allocator, root.path())) |kr| {
        std.debug.print("SONNY-6386: resolveHmacKey ignored the malformed GEODE_TDE_KEY and used key source '{s}'\n", .{kr.key_id});
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.HmacKeyInvalid, err);
    }
    // No key file was generated in its place.
    try testing.expectEqual(@as(usize, 0), try entryCount(root.path()));
}
