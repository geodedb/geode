// CANARY: REQ=REQ-SONNY-6435-MASTER-KEY-CHECK; FEATURE="Key configuration"; ASPECT=MasterKeyCheckValue; STATUS=TESTED; TEST=tests/test_sonny6435_master_key_check.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6435 (3): nothing recorded which GEODE_MASTER_KEY a data directory's
// encrypted fields were written with, so a server restarted with another key
// (a typo, another secret, or GEODE_MASTER_KEY_FORMAT changed so the same
// characters give another key) started normally: old fields were unreadable
// and new ones were written under the new key, mixing two keys in one store.
//
// The contract, driven against the built `geode serve` across restarts of
// one data directory:
//   - with no GEODE_MASTER_KEY nothing is checked or recorded: a deployment
//     without FLE is never blocked;
//   - the first start with a key records a key check value
//     (`fle_master_key.kcv` beside the FLE catalog) that holds neither the
//     key nor its encoding;
//   - a restart with the same key starts;
//   - a restart with another key, or the same characters read in another
//     GEODE_MASTER_KEY_FORMAT, refuses to start, naming the variable and
//     the file, never the key;
//   - a data directory without a recorded value (written before this check)
//     starts with a key and records it (upgrade path), and is then checked.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;

const kcv_file_name = "fle_master_key.kcv";

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

const key_a = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8";
const key_b = "6b86b273ff34fce19c6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";

const Env = struct { name: []const u8, value: []const u8 };

const Run = struct {
    code: ?u8,
    started: bool,
    text: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.text);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

const ready_marker = "QUIC transport listening";

/// Runs `geode serve` with `extra` in its environment; a server that gets
/// ready (or is still running at the deadline) is stopped and reported as
/// `started`.
fn runServe(cwd: []const u8, data_dir: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6435-Admin-pw1");
    try env.put("GEODE_LSP_PORT", "0");
    for (extra) |e| try env.put(e.name, e.value);
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
        if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        const so_far = std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) catch null;
        const ready = if (so_far) |t| std.mem.indexOf(u8, t, ready_marker) != null else false;
        if (so_far) |t| testing.allocator.free(t);
        if (ready or waited_ms >= 60_000) {
            posix.kill(pid, .TERM) catch {};
            var grace: u32 = 0;
            while (grace < 15_000) : (grace += 100) {
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
    return .{ .code = code, .started = !exited, .text = text };
}

const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    data_dir: []u8,
    kcv_path: []u8,

    fn init(tag: []const u8) !Fixture {
        const allocator = testing.allocator;
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
        errdefer allocator.free(cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
        errdefer allocator.free(data_dir);
        const kcv_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, kcv_file_name });
        return .{ .root = root, .cwd = cwd, .data_dir = data_dir, .kcv_path = kcv_path };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.cwd);
        testing.allocator.free(self.data_dir);
        testing.allocator.free(self.kcv_path);
        self.root.remove();
    }

    fn serve(self: *Fixture, extra: []const Env) !Run {
        return runServe(self.cwd, self.data_dir, extra);
    }
};

fn expectStarted(r: Run, what: []const u8) !void {
    const ok = r.started and !r.output(key_a) and !r.output(key_b);
    if (!ok) std.debug.print("SONNY-6435 (3) {s}: expected a start; exit={?d}\n{s}\n", .{ what, r.code, r.text });
    try testing.expect(ok);
}

fn expectRefused(r: Run, what: []const u8) !void {
    const ok = !r.started and r.code != null and r.code.? != 0 and r.output("refusing to start") and
        r.output("GEODE_MASTER_KEY") and r.output(kcv_file_name) and !r.output(key_a) and !r.output(key_b);
    if (!ok) std.debug.print("SONNY-6435 (3) {s}: expected a refusal naming GEODE_MASTER_KEY and {s}; started={} exit={?d}\n{s}\n", .{ what, kcv_file_name, r.started, r.code, r.text });
    try testing.expect(ok);
}

const hex_a = [_]Env{ .{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hex" }, .{ .name = "GEODE_MASTER_KEY", .value = key_a } };
const hex_b = [_]Env{ .{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hex" }, .{ .name = "GEODE_MASTER_KEY", .value = key_b } };
// The same characters as key A without a format: the legacy reading, another key.
const legacy_a = [_]Env{.{ .name = "GEODE_MASTER_KEY", .value = key_a }};

test "SONNY-6435 (3) a restart with another GEODE_MASTER_KEY refuses to start; the recorded key starts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6435-kcv");
    defer fx.deinit();

    {
        const r = try fx.serve(&hex_a);
        defer r.deinit();
        try expectStarted(r, "first start with key A");
    }
    // Recorded, and it is not the key.
    try testing.expect(pathExists(fx.kcv_path));
    {
        const recorded = try std.Io.Dir.cwd().readFileAlloc(fsIo(), fx.kcv_path, testing.allocator, .limited(4096));
        defer testing.allocator.free(recorded);
        var key_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&key_bytes, key_a);
        try testing.expect(std.mem.indexOf(u8, recorded, key_a) == null);
        try testing.expect(std.mem.indexOf(u8, recorded, &key_bytes) == null);
    }
    {
        const r = try fx.serve(&hex_a);
        defer r.deinit();
        try expectStarted(r, "restart with key A");
    }
    {
        const r = try fx.serve(&hex_b);
        defer r.deinit();
        try expectRefused(r, "restart with key B");
    }
    {
        const r = try fx.serve(&legacy_a);
        defer r.deinit();
        try expectRefused(r, "restart with key A's characters in the legacy format");
    }
    // The refusals changed nothing: key A still starts.
    {
        const r = try fx.serve(&hex_a);
        defer r.deinit();
        try expectStarted(r, "restart with key A after the refusals");
    }
}

test "SONNY-6435 (3) with no GEODE_MASTER_KEY nothing is checked or recorded" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6435-kcv-nokey");
    defer fx.deinit();
    {
        const r = try fx.serve(&.{});
        defer r.deinit();
        try expectStarted(r, "start without a master key");
    }
    try testing.expect(!pathExists(fx.kcv_path));
    {
        const r = try fx.serve(&.{});
        defer r.deinit();
        try expectStarted(r, "restart without a master key");
    }
    try testing.expect(!pathExists(fx.kcv_path));
}

test "SONNY-6435 (3) a data directory with no recorded value records one with its key, and is checked from then on" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init("sonny6435-kcv-upgrade");
    defer fx.deinit();
    // A store written without the check (no key at the time, or a server
    // from before this change): no recorded value.
    {
        const r = try fx.serve(&.{});
        defer r.deinit();
        try expectStarted(r, "store created without a key check");
    }
    try testing.expect(!pathExists(fx.kcv_path));
    {
        const r = try fx.serve(&hex_a);
        defer r.deinit();
        try expectStarted(r, "upgrade start with key A");
    }
    try testing.expect(pathExists(fx.kcv_path));
    {
        const r = try fx.serve(&hex_b);
        defer r.deinit();
        try expectRefused(r, "restart with key B after the upgrade");
    }
}
