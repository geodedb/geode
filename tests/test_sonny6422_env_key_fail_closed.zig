// CANARY: REQ=REQ-SONNY-6422-ENV-KEY-FAIL-CLOSED; FEATURE="Key configuration"; ASPECT=SetButUnusableKeyRefuses; STATUS=TESTED; TEST=tests/test_sonny6422_env_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6422 (1, 2 and the sweep): environment-supplied keys whose wrong or
// partial value was swallowed into a weaker mode.
//   - GEODE_AUDIT_PUB / GEODE_AUDIT_SEC: with only one of them set (or a
//     public key that does not belong to the seed) `AuditLogger.loadKeys`
//     quietly generated file-based keys beside the audit log, and the
//     per-graph security audit logger failed soft (no audit at all).
//   - GEODE_MASTER_KEY: any length was accepted and a short value was
//     hashed into a key, so "abc" became a working FLE master key.
//   - GEODE_WAL_KEY: no production code reads it (the WriteAheadLog wrapper
//     that did has no caller); the storage-engine WAL is encrypted with
//     GEODE_TDE_KEY, so a server given only GEODE_WAL_KEY wrote its WAL in
//     plaintext.
//   - GEODE_MIGRATION_HMAC_KEY: a value that was not 64 hex characters made
//     `migrate create` write an unsigned migration (or, with a .hmac_key
//     file, sign with that file's key instead).
//
// The contract: a key variable that is set (non-empty) but unusable is an
// error. `geode serve` refuses to start before it creates the data
// directory, names the variable and what it must be, and never prints the
// value; the in-process loaders return an error instead of a weaker key.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;
const graph_store = geode.graph_store;
const audit = geode.security.audit;
const fle_key_manager = geode.fle_key_manager;
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

const key_vars = [_][*:0]const u8{ "GEODE_AUDIT_PUB", "GEODE_AUDIT_SEC", "GEODE_MASTER_KEY", "GEODE_WAL_KEY", "GEODE_TDE_KEY", "GEODE_MIGRATION_HMAC_KEY" };

fn clearKeyEnv() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    for (key_vars) |v| _ = unsetenv(v);
}

fn setEnv(name: [*:0]const u8, value: []const u8) !void {
    const z = try testing.allocator.dupeZ(u8, value);
    defer testing.allocator.free(z);
    _ = setenv(name, z, 1);
}

/// A matching Ed25519 audit key pair (seed hex, public key hex) from `seed`.
fn auditPair(seed: [32]u8) !struct { sec: [64]u8, pub_hex: [64]u8 } {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    return .{ .sec = std.fmt.bytesToHex(seed, .lower), .pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower) };
}

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

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6422 {s}: exit={?d} started={}\noutput:\n{s}\n", .{ what, self.code, self.started, self.text });
    }
};

const ready_marker = "QUIC transport listening";

/// Runs `geode serve` with `extra` in its environment. A server that prints
/// the ready marker (or is still running at the deadline) is stopped and
/// reported as `started`.
fn runServe(cwd: []const u8, data_dir: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6422-Admin-pw1");
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
    const deadline_ms: i64 = 60_000;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        const so_far = std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) catch null;
        const ready = if (so_far) |t| std.mem.indexOf(u8, t, ready_marker) != null else false;
        if (so_far) |t| testing.allocator.free(t);
        if (ready or waited_ms >= deadline_ms) {
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

const Case = struct {
    what: []const u8,
    env: []const Env,
    /// Texts the refusal names (the variable(s) and the expected format).
    names: []const []const u8,
    /// Secret values that must not be printed.
    secrets: []const []const u8,
};

fn expectRefused(c: Case, i: usize) !void {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6422-serve");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data{d}", .{ root.path(), i });
    defer allocator.free(data_dir);

    const r = try runServe(cwd, data_dir, c.env);
    defer r.deinit();
    var ok = !r.started and r.code != null and r.code.? != 0 and r.output("refusing to start") and !pathExists(data_dir);
    for (c.names) |n| ok = ok and r.output(n);
    for (c.secrets) |s| ok = ok and !r.output(s);
    if (!ok) {
        r.dump(c.what);
        if (pathExists(data_dir)) std.debug.print("SONNY-6422 {s}: the data directory was created ({d} entries)\n", .{ c.what, entryCount(data_dir) catch 0 });
    }
    try testing.expect(ok);
}

test "SONNY-6422 geode serve refuses a half-configured or mismatched audit key pair, a short GEODE_MASTER_KEY and an unused GEODE_WAL_KEY, before it creates the data directory and without printing the values" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = try auditPair([_]u8{0x22} ** 32);
    const b = try auditPair([_]u8{0x33} ** 32);
    const short_master = "sonny6422-short-master";
    const wal_key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const cases = [_]Case{
        .{ .what = "only GEODE_AUDIT_PUB", .env = &.{.{ .name = "GEODE_AUDIT_PUB", .value = &a.pub_hex }}, .names = &.{ "GEODE_AUDIT_PUB", "GEODE_AUDIT_SEC" }, .secrets = &.{} },
        .{ .what = "only GEODE_AUDIT_SEC", .env = &.{.{ .name = "GEODE_AUDIT_SEC", .value = &a.sec }}, .names = &.{ "GEODE_AUDIT_PUB", "GEODE_AUDIT_SEC" }, .secrets = &.{&a.sec} },
        .{ .what = "GEODE_AUDIT_PUB of another seed", .env = &.{ .{ .name = "GEODE_AUDIT_PUB", .value = &b.pub_hex }, .{ .name = "GEODE_AUDIT_SEC", .value = &a.sec } }, .names = &.{ "GEODE_AUDIT_PUB", "GEODE_AUDIT_SEC" }, .secrets = &.{&a.sec} },
        .{ .what = "short GEODE_MASTER_KEY", .env = &.{.{ .name = "GEODE_MASTER_KEY", .value = short_master }}, .names = &.{ "GEODE_MASTER_KEY", "at least 32" }, .secrets = &.{short_master} },
        .{ .what = "GEODE_WAL_KEY", .env = &.{.{ .name = "GEODE_WAL_KEY", .value = wal_key }}, .names = &.{ "GEODE_WAL_KEY", "GEODE_TDE_KEY" }, .secrets = &.{wal_key} },
    };
    for (cases, 0..) |c, i| try expectRefused(c, i);
}

test "SONNY-6422 geode serve still starts with a complete audit key pair and a 32-byte GEODE_MASTER_KEY" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const a = try auditPair([_]u8{0x44} ** 32);
    var root = try test_scratch.ScratchDir.create("sonny6422-serve-ok");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const r = try runServe(cwd, data_dir, &.{
        .{ .name = "GEODE_AUDIT_PUB", .value = &a.pub_hex },
        .{ .name = "GEODE_AUDIT_SEC", .value = &a.sec },
        .{ .name = "GEODE_MASTER_KEY", .value = "sonny6422-master-key-of-32-bytes" },
    });
    defer r.deinit();
    if (!r.started) r.dump("complete key configuration");
    try testing.expect(r.started);
}

test "SONNY-6422 (1) AuditLogger refuses a half-configured or mismatched GEODE_AUDIT_PUB/SEC pair and writes no file-based keys in its place" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    const a = try auditPair([_]u8{0x55} ** 32);
    const b = try auditPair([_]u8{0x66} ** 32);

    const Setting = struct { pub_hex: ?[]const u8, sec: ?[]const u8, want: anyerror };
    const settings = [_]Setting{
        .{ .pub_hex = &a.pub_hex, .sec = null, .want = error.AuditKeyPairIncomplete },
        .{ .pub_hex = null, .sec = &a.sec, .want = error.AuditKeyPairIncomplete },
        .{ .pub_hex = &a.pub_hex, .sec = "", .want = error.AuditKeyPairIncomplete },
        .{ .pub_hex = &b.pub_hex, .sec = &a.sec, .want = error.AuditKeyMismatch },
        .{ .pub_hex = &a.pub_hex, .sec = "zz" ** 32, .want = error.AuditKeyInvalid },
    };
    for (settings) |s| {
        clearKeyEnv();
        if (s.pub_hex) |p| try setEnv("GEODE_AUDIT_PUB", p);
        if (s.sec) |v| try setEnv("GEODE_AUDIT_SEC", v);
        var root = try test_scratch.ScratchDir.create("sonny6422-audit");
        defer root.remove();
        const log_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{root.path()});
        defer allocator.free(log_path);
        if (audit.AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path })) |l| {
            var logger = l;
            logger.deinit();
            std.debug.print("SONNY-6422 (1): the audit logger opened with GEODE_AUDIT_PUB set={} GEODE_AUDIT_SEC set={} (file-based keys: {s}.key exists={})\n", .{ s.pub_hex != null, s.sec != null, log_path, blk: {
                var kb: [std.fs.max_path_bytes]u8 = undefined;
                break :blk pathExists(try std.fmt.bufPrint(&kb, "{s}.key", .{log_path}));
            } });
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(s.want, @as(anyerror, err));
        }
        var kb: [std.fs.max_path_bytes]u8 = undefined;
        try testing.expect(!pathExists(try std.fmt.bufPrint(&kb, "{s}.key", .{log_path})));
        try testing.expect(!pathExists(try std.fmt.bufPrint(&kb, "{s}.pub", .{log_path})));
    }

    // A complete, matching pair signs with the env key (no key files).
    {
        clearKeyEnv();
        try setEnv("GEODE_AUDIT_PUB", &a.pub_hex);
        try setEnv("GEODE_AUDIT_SEC", &a.sec);
        var root = try test_scratch.ScratchDir.create("sonny6422-audit-ok");
        defer root.remove();
        const log_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{root.path()});
        defer allocator.free(log_path);
        var logger = try audit.AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path });
        logger.deinit();
        var kb: [std.fs.max_path_bytes]u8 = undefined;
        try testing.expect(!pathExists(try std.fmt.bufPrint(&kb, "{s}.key", .{log_path})));
    }
}

test "SONNY-6422 (1) the __geode_security graph does not open without its audit logger when the audit key pair is half-configured" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    const a = try auditPair([_]u8{0x77} ** 32);
    try setEnv("GEODE_AUDIT_PUB", &a.pub_hex);
    var root = try test_scratch.ScratchDir.create("sonny6422-secgraph");
    defer root.remove();
    const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
    defer graph_store.deinitGlobalAdapter();
    if (adapter.getOrCreateGraph("__geode_security")) |mg| {
        std.debug.print("SONNY-6422 (1): __geode_security opened with audit_logger={s} under a half-configured audit key pair\n", .{if (mg.audit_logger == null) "null (no audit)" else "set"});
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(@as(anyerror, error.AuditKeyPairIncomplete), @as(anyerror, err));
    }
}

test "SONNY-6422 (2) loadMasterKeyFromEnv refuses a GEODE_MASTER_KEY shorter than 32 bytes and an empty one instead of hashing it into a key" {
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    for ([_][]const u8{ "a", "abc", "0123456789abcdef0123456789abcde" }) |short| {
        try setEnv("GEODE_MASTER_KEY", short);
        if (fle_key_manager.loadMasterKeyFromEnv(allocator)) |_| {
            std.debug.print("SONNY-6422 (2): a {d}-byte GEODE_MASTER_KEY was accepted as an FLE master key\n", .{short.len});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(@as(anyerror, error.MasterKeyTooShort), @as(anyerror, err));
        }
    }
    try setEnv("GEODE_MASTER_KEY", "");
    try testing.expectError(error.MasterKeyRequired, fle_key_manager.loadMasterKeyFromEnv(allocator));
    _ = unsetenv("GEODE_MASTER_KEY");
    try testing.expectError(error.MasterKeyRequired, fle_key_manager.loadMasterKeyFromEnv(allocator));
    // 32 bytes is the minimum; the first 32 bytes are the key.
    try setEnv("GEODE_MASTER_KEY", "0123456789abcdef0123456789abcdef");
    const k = try fle_key_manager.loadMasterKeyFromEnv(allocator);
    try testing.expectEqualSlices(u8, "0123456789abcdef0123456789abcdef", &k);
}

const CliRun = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CliRun) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn says(self: CliRun, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or std.mem.indexOf(u8, self.stderr, needle) != null;
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, extra: []const Env) !CliRun {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (extra) |e| try env.put(e.name, e.value);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

test "SONNY-6422 (sweep) geode migrate create refuses a malformed GEODE_MIGRATION_HMAC_KEY instead of writing an unsigned migration or signing with the .hmac_key file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const bad_key = "sonny6422-not-a-migration-key";
    for ([_]bool{ false, true }) |with_file| {
        var root = try test_scratch.ScratchDir.create("sonny6422-migrate");
        defer root.remove();
        const mig_dir = try std.fmt.allocPrint(allocator, "{s}/migrations", .{root.path()});
        defer allocator.free(mig_dir);
        try std.Io.Dir.cwd().createDirPath(fsIo(), mig_dir);
        if (with_file) {
            const kp = try std.fmt.allocPrint(allocator, "{s}/.hmac_key", .{mig_dir});
            defer allocator.free(kp);
            const f = try std.Io.Dir.cwd().createFile(fsIo(), kp, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
            defer f.close(fsIo());
            try f.writeStreamingAll(fsIo(), "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100");
        }
        const before = try entryCount(mig_dir);
        const r = try runGeode(&.{ geode_binary, "migrate", "create", "add_people", "--dir", mig_dir }, root.path(), &.{.{ .name = "GEODE_MIGRATION_HMAC_KEY", .value = bad_key }});
        defer r.deinit();
        const after = try entryCount(mig_dir);
        const ok = r.code != null and r.code.? != 0 and r.says("GEODE_MIGRATION_HMAC_KEY") and r.says("64 hex characters") and !r.says(bad_key) and after == before;
        if (!ok) std.debug.print("SONNY-6422 (sweep) migrate create with_file={}: exit={?d} files {d}->{d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ with_file, r.code, before, after, r.stdout, r.stderr });
        try testing.expect(ok);
    }
}
