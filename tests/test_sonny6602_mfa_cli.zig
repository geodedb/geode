//! SONNY-6602 (1), offline CLI: `geode user mfa-setup` printed a TOTP secret
//! and recovery codes ("Store these recovery codes securely. Each can only
//! be used once."), and `geode user mfa enable` printed "MFA enabled for
//! <user>." MFA is not enforced at login (HELLO never asks for a code;
//! SONNY-6604), and the CLI does not even keep the recovery codes it prints.
//! Both commands, and their help, now say so.
//!
//! Spawns the built geode binary against a bootstrapped offline store.
//!
// CANARY: REQ=REQ-SONNY-6602-MFA-CLI-HONESTY; FEATURE="MFA authentication"; ASPECT=OfflineCliWarning; STATUS=TESTED; TEST=tests/test_sonny6602_mfa_cli.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const mfa = geode.mfa_test_support;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = @import("geode_test_bin").geode_exe;
const hmac_hex = "62" ** 32;
const user_pw = "Correct Horse Battery Staple 6602";

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

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` (MFA turned on) and wait for it (120 s
/// at most). stdout and stderr together.
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
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6602-{s}-{d}", .{ tag, monoMillis() });
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

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

fn expectNotEnforcedWarning(what: []const u8, output: []const u8) !void {
    for ([_][]const u8{ "not enforced at login", "SONNY-6604" }) |needle| {
        if (std.mem.indexOf(u8, output, needle) == null) {
            std.debug.print("SONNY-6602 (1): {s} does not say \"{s}\":\n{s}\n", .{ what, needle, output });
            return error.NoNotEnforcedWarning;
        }
    }
}

test "SONNY-6602 (1): geode user mfa-setup / mfa enable and their help say MFA is not enforced at login" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try expectNotEnforcedWarning("geode user mfa-setup --help", try runOk(aa, &.{ binary_path, "user", "mfa-setup", "--help" }));
    try expectNotEnforcedWarning("geode user mfa --help", try runOk(aa, &.{ binary_path, "user", "mfa", "--help" }));

    const dir = try bootstrappedStore(aa, "cli");
    defer removeDir(dir);
    _ = try runOk(aa, &.{ binary_path, "user", "create", "cli6602", "cli6602@example.com", "--password", user_pw, "--force", "--data-dir", dir });

    const setup = try runOk(aa, &.{ binary_path, "user", "mfa-setup", "cli6602", "--show-recovery", "--force", "--data-dir", dir });
    try expectNotEnforcedWarning("geode user mfa-setup", setup);
    if (std.mem.indexOf(u8, setup, "Each can only be used once") != null) {
        std.debug.print("SONNY-6602 (1): geode user mfa-setup says its recovery codes can be used once; nothing redeems them:\n{s}\n", .{setup});
        return error.UnredeemableRecoveryCodesAdvertised;
    }

    // The secret it printed, and a code that verifies against it.
    const prefix = "MFA secret: ";
    const at = std.mem.indexOf(u8, setup, prefix) orelse return error.NoSecretPrinted;
    const rest = setup[at + prefix.len ..];
    const secret = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    const code = try mfa.generateCodeFromBase32(aa, secret, realMillis(), 30, 6);
    const code_str = try std.fmt.allocPrint(aa, "{d:0>6}", .{code});

    const enable = try runOk(aa, &.{ binary_path, "user", "mfa", "enable", "cli6602", "--code", code_str, "--force", "--data-dir", dir });
    if (std.mem.indexOf(u8, enable, "MFA enabled for cli6602") == null) {
        std.debug.print("geode user mfa enable did not enable:\n{s}\n", .{enable});
        return error.NotEnabled;
    }
    try expectNotEnforcedWarning("geode user mfa enable", enable);
}
