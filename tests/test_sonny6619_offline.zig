//! SONNY-6619, against the built binary.
//!
//! (1) The offline `geode user mfa enable --code` checked the code against
//!     the stored secret with no attempt limit: the guessing route SONNY-6614
//!     closed for `mfa-verify` stayed open here. It now counts against the
//!     same sealed `MfaAttempts` record, before the code is checked.
//! (5) Opening the store in process (the offline CLI, these fixtures) left a
//!     directory handle open in the data directory: timeseries-storage opens
//!     `<graph>/timeseries` for its WAL (`engine.zig`, `Engine.init`) and
//!     never closes it (the wal library does not own it). The live-server
//!     guard of the offline CLI then saw this process as a holder of the
//!     data directory, so every offline write in a test needed `--force`.
//!     geode's timeseries `Store.deinit` now closes it; no fixture here
//!     passes `--force`.
//!
// CANARY: REQ=REQ-SONNY-6619-OFFLINE; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6619_offline.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const mfa = geode.mfa_test_support;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = @import("geode_test_bin").geode_exe;
const hmac_hex = "19" ** 32;
const user_pw = "Correct Horse Battery Staple 6619";

fn monoMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn realMillis() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` (MFA turned on); stdout and stderr.
fn runGeode(aa: std.mem.Allocator, args: []const []const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    try env.put("GEODE_ENABLE_MFA", "1");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    const t0 = monoMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
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
        if (monoMillis() - t0 > 120_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                try output.appendSlice(aa, buf[0..n]);
            }
            f.close(io);
        }
    }
    return .{ .code = code, .output = output.items };
}

fn runOk(aa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const r = try runGeode(aa, args);
    if (r.code != 0) {
        std.debug.print("{s} {s} exited {d}:\n{s}\n", .{ args[1], args[2], r.code, r.output });
        return error.CommandFailed;
    }
    return r.output;
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6619-{s}-{d}", .{ tag, monoMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

/// A data directory with a key file and a sealed store (the bootstrap admin).
fn bootstrappedStore(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try freshDir(aa, tag);
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    const key_file = try std.Io.Dir.cwd().createFile(io, key_path, .{ .permissions = .fromMode(0o600) });
    try key_file.writeStreamingAll(io, hmac_hex);
    key_file.close(io);

    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    _ = try mgr.bootstrapDefaultAdmin(&kr.key);
    try mgr.verifyChain(&kr.key);
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

fn codeFor(aa: std.mem.Allocator, secret: []const u8) ![]const u8 {
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    const code = try mfa.generateCodeFromBase32(aa, secret, realMillis(), 30, 6);
    return std.fmt.allocPrint(aa, "{d:0>6}", .{code});
}

const Attempts = struct { fail_count: u32, lockout_until_ms: i64 };

/// The user's stored MFA attempt record (the chain must verify), or null.
fn storedAttempts(dir: []const u8, user: []const u8) !?Attempts {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    const kr = try AuthGraphManager.resolveExistingHmacKey(pa, dir);
    try mgr.verifyChain(&kr.key);
    const rec = mgr.storage.getUserByUsername(user) orelse return error.UserNotStored;
    if (comptime !@hasDecl(AuthGraphManager, "mfaAttempts")) {
        std.debug.print("SONNY-6619: the security graph keeps no MFA attempt record\n", .{});
        return error.NoStoredMfaAttempts;
    } else {
        const a = (try mgr.mfaAttempts(rec.id)) orelse return null;
        return .{ .fail_count = a.fail_count, .lockout_until_ms = a.lockout_until_ms };
    }
}

fn enrolledStore(aa: std.mem.Allocator, tag: []const u8, user: []const u8) !struct { dir: []const u8, secret: []const u8 } {
    const dir = try bootstrappedStore(aa, tag);
    _ = try runOk(aa, &.{ binary_path, "user", "create", user, "x@example.com", "--password", user_pw, "--data-dir", dir });
    const out = try runOk(aa, &.{ binary_path, "user", "mfa-setup", user, "--data-dir", dir });
    const sp = "MFA secret: ";
    const at = std.mem.indexOf(u8, out, sp) orelse return error.NoSecretPrinted;
    const rest = out[at + sp.len ..];
    return .{ .dir = dir, .secret = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len] };
}

fn verify(aa: std.mem.Allocator, dir: []const u8, user: []const u8, token: []const u8) !Run {
    return runGeode(aa, &.{ binary_path, "user", "mfa-verify", user, "--token", token, "--data-dir", dir });
}

fn enable(aa: std.mem.Allocator, dir: []const u8, user: []const u8, code: []const u8) !Run {
    return runGeode(aa, &.{ binary_path, "user", "mfa", "enable", user, "--code", code, "--data-dir", dir });
}

/// Every descriptor this process holds inside `dir`.
fn heldInside(aa: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var d = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer d.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (try it.next(io)) |e| {
        const n = d.readLink(io, e.name, &buf) catch continue;
        if (std.mem.startsWith(u8, buf[0..n], dir)) try out.append(aa, try aa.dupe(u8, buf[0..n]));
    }
    return out.items;
}

test "SONNY-6619 (5): opening the store in process releases the data directory; offline writes need no --force" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "release");
    defer removeDir(dir);
    const held = try heldInside(aa, dir);
    if (held.len > 0) {
        for (held) |h| std.debug.print("SONNY-6619 (5): after the store was closed this process still holds {s}\n", .{h});
        return error.DataDirStillHeld;
    }
    _ = try runOk(aa, &.{ binary_path, "user", "create", "fr6619", "fr@example.com", "--password", user_pw, "--data-dir", dir });
    // And again after an in-process read of the store.
    _ = try storedAttempts(dir, "fr6619");
    try testing.expectEqual(@as(usize, 0), (try heldInside(aa, dir)).len);
    _ = try runOk(aa, &.{ binary_path, "user", "mfa-setup", "fr6619", "--data-dir", dir });
}

test "SONNY-6619 (1): offline mfa enable --code counts against the attempt limit, with mfa-verify" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const e = try enrolledStore(aa, "enable", "en6619");
    defer removeDir(e.dir);

    // Three wrong codes through mfa enable, two through mfa-verify: five.
    var i: usize = 0;
    while (i < 3) : (i += 1) try testing.expect((try enable(aa, e.dir, "en6619", "000000")).code != 0);
    const st3 = (try storedAttempts(e.dir, "en6619")) orelse {
        std.debug.print("SONNY-6619 (1): three wrong codes through geode user mfa enable left no attempt record\n", .{});
        return error.EnableNotCounted;
    };
    try testing.expectEqual(@as(u32, 3), st3.fail_count);
    i = 0;
    while (i < 2) : (i += 1) try testing.expect((try verify(aa, e.dir, "en6619", "000000")).code != 0);

    // Locked out: a right code through mfa enable is refused, MFA stays off.
    const r = try enable(aa, e.dir, "en6619", try codeFor(aa, e.secret));
    if (r.code == 0 or std.mem.indexOf(u8, r.output, "locked out") == null) {
        std.debug.print("SONNY-6619 (1): after five failures geode user mfa enable exited {d}:\n{s}\n", .{ r.code, r.output });
        return error.EnableNotLimited;
    }
    const st = (try storedAttempts(e.dir, "en6619")) orelse return error.NoAttemptRecord;
    try testing.expectEqual(@as(u32, 5), st.fail_count);
}

test "SONNY-6619 (1): a right code through mfa enable resets the count" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const e = try enrolledStore(aa, "enreset", "er6619");
    defer removeDir(e.dir);
    try testing.expect((try enable(aa, e.dir, "er6619", "000000")).code != 0);
    const out = try runOk(aa, &.{ binary_path, "user", "mfa", "enable", "er6619", "--code", try codeFor(aa, e.secret), "--data-dir", e.dir });
    try testing.expect(std.mem.indexOf(u8, out, "MFA enabled for er6619") != null);
    const st = (try storedAttempts(e.dir, "er6619")) orelse return error.NoAttemptRecord;
    try testing.expectEqual(@as(u32, 0), st.fail_count);
}
