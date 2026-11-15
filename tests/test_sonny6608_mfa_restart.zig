//! SONNY-6608, against the built binary.
//!
//! (1) The offline `geode user mfa-setup` set the user's stored
//!     `mfa_enabled` before any code was verified, and printed recovery codes
//!     it never stored. It now stores the secret with MFA off, and the
//!     recovery codes as SHA-256 digests (`mfa.hashRecoveryCode`, as
//!     SONNY-6600), in a sealed record.
//! (2) `geode user mfa enable <user>` without `--code` turned MFA on with no
//!     proof of the authenticator. It is refused.
//! (4) A real `geode serve`: an enrollment made over QUIC (`mfa_setup`,
//!     `mfa_enable`) is in the security graph after the server stops, and a
//!     restarted server verifies codes against it. It was process memory
//!     only: after a restart `mfa_verify` answered 55000 (not enrolled).
//!
// CANARY: REQ=REQ-SONNY-6608-MFA-RESTART; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6608_mfa_restart.zig; OWNER=security; UPDATED=2026-11-15
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
const hmac_hex = "68" ** 32;
const user_pw = "Correct Horse Battery Staple 6608";

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
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6608-{s}-{d}", .{ tag, monoMillis() });
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

/// What the store holds for `user`'s MFA (opened in process; the chain must
/// verify).
const StoredMfa = struct {
    enabled: bool,
    secret: []const u8,
    digests: ?[][32]u8,
};

fn storedMfa(aa: std.mem.Allocator, dir: []const u8, user: []const u8) !StoredMfa {
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
    const digests: ?[][32]u8 = if (comptime @hasDecl(AuthGraphManager, "mfaRecoveryDigests"))
        try mgr.mfaRecoveryDigests(aa, rec.id)
    else
        null;
    return .{
        .enabled = rec.mfa_enabled,
        // SONNY-6609: stored sealed; opened with the store's key.
        .secret = if (rec.getMFASecret()) |stored| blk: {
            var buf: [64]u8 = undefined;
            break :blk try aa.dupe(u8, try AuthGraphManager.openMfaSecretWithKey(&kr.key, rec.id, stored, &buf));
        } else "",
        .digests = digests,
    };
}

fn expectDigestsOf(stored: StoredMfa, codes: []const []const u8) !void {
    const d = stored.digests orelse {
        std.debug.print("SONNY-6608: no recovery codes are stored; {d} were printed\n", .{codes.len});
        return error.RecoveryCodesNotStored;
    };
    try testing.expectEqual(codes.len, d.len);
    for (codes, d) |c, x| try testing.expectEqual(mfa.hashRecoveryCode(c), x);
}

fn codeFor(aa: std.mem.Allocator, secret: []const u8) ![]const u8 {
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    const code = try mfa.generateCodeFromBase32(aa, secret, realMillis(), 30, 6);
    return std.fmt.allocPrint(aa, "{d:0>6}", .{code});
}

test "SONNY-6608 (1)(2): offline mfa-setup stores the secret with MFA off and the recovery codes hashed; mfa enable needs a code" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "cli");
    defer removeDir(dir);
    _ = try runOk(aa, &.{ binary_path, "user", "create", "cl6608", "cl6608@example.com", "--password", user_pw, "--data-dir", dir });

    const out = try runOk(aa, &.{ binary_path, "user", "mfa-setup", "cl6608", "--data-dir", dir });
    const sp = "MFA secret: ";
    const at = std.mem.indexOf(u8, out, sp) orelse return error.NoSecretPrinted;
    const rest = out[at + sp.len ..];
    const secret = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    // The printed codes: the indented lines after "Recovery codes:".
    var codes: std.ArrayList([]const u8) = .empty;
    const ci = std.mem.indexOf(u8, out, "Recovery codes:\n") orelse return error.NoCodesPrinted;
    var lines = std.mem.splitScalar(u8, out[ci + "Recovery codes:\n".len ..], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) break;
        try codes.append(aa, std.mem.trim(u8, line, " "));
    }
    try testing.expect(codes.items.len > 0);

    var st = try storedMfa(aa, dir, "cl6608");
    try testing.expectEqualStrings(secret, st.secret);
    if (st.enabled) {
        std.debug.print("SONNY-6608 (1): geode user mfa-setup turned the stored mfa_enabled on before any code was verified\n", .{});
        return error.EnabledBeforeVerification;
    }
    try expectDigestsOf(st, codes.items);

    // (2) enable without --code: refused, nothing changed.
    const r = try runGeode(aa, &.{ binary_path, "user", "mfa", "enable", "cl6608", "--data-dir", dir });
    st = try storedMfa(aa, dir, "cl6608");
    if (r.code == 0 or st.enabled) {
        std.debug.print("SONNY-6608 (2): geode user mfa enable without --code exited {d} and left mfa_enabled={}:\n{s}\n", .{ r.code, st.enabled, r.output });
        return error.EnableWithoutCode;
    }

    // With a code that verifies: on; disable: off.
    _ = try runOk(aa, &.{ binary_path, "user", "mfa", "enable", "cl6608", "--code", try codeFor(aa, secret), "--data-dir", dir });
    try testing.expect((try storedMfa(aa, dir, "cl6608")).enabled);
    _ = try runOk(aa, &.{ binary_path, "user", "mfa", "disable", "cl6608", "--data-dir", dir });
    try testing.expect(!(try storedMfa(aa, dir, "cl6608")).enabled);
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_ENABLE_MFA=1"});
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .proc = proc, .addr = addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
    }
};

/// Run `query` as the admin: the first row's string cells, or the refusal.
fn adminRow(aa: std.mem.Allocator, addr: []const u8, query: []const u8) ![]const []const u8 {
    var client = try util.QuicProtoClient.connect(testing.allocator, addr);
    defer client.deinit();
    var h = try client.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(testing.allocator);
    if (!h.success) return error.HelloRefused;
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 10);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("`{s}`: {s} {?s}\n", .{ query, c, r.error_message });
        return error.QueryRefused;
    }
    var out: std.ArrayList([]const u8) = .empty;
    if (r.rows.len > 0) for (r.rows[0]) |cell| try out.append(aa, switch (cell) {
        .string => |s| try aa.dupe(u8, s),
        else => "",
    });
    return out.items;
}

test "SONNY-6608 (4): an MFA enrollment made over QUIC survives a server restart" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "restart");
    defer removeDir(dir);

    var secret: []const u8 = "";
    var codes: std.ArrayList([]const u8) = .empty;
    {
        var s = try Server.start(testing.allocator, dir);
        defer s.stop(testing.allocator);
        _ = try adminRow(aa, s.addr, "CREATE USER rs6608 SET PASSWORD '" ++ user_pw ++ "'");
        const row = try adminRow(aa, s.addr, "CALL geode.auth.mfa_setup('rs6608')");
        secret = row[0]["MFA secret: ".len..];
        var it = std.mem.tokenizeScalar(u8, row[1]["Recovery codes: ".len..], ' ');
        while (it.next()) |c| try codes.append(aa, c);
        _ = try adminRow(aa, s.addr, try std.fmt.allocPrint(aa, "CALL geode.auth.mfa_enable('rs6608', '{s}')", .{try codeFor(aa, secret)}));
    }

    // Stored, with the server down.
    const st = try storedMfa(aa, dir, "rs6608");
    if (!std.mem.eql(u8, st.secret, secret) or !st.enabled) {
        std.debug.print("SONNY-6608 (4): after the server stopped the store holds mfa_secret '{s}' (want the issued one) and mfa_enabled={} (want true)\n", .{ st.secret, st.enabled });
        return error.EnrollmentNotStored;
    }
    try expectDigestsOf(st, codes.items);

    // A restarted server verifies codes against it.
    {
        var s = try Server.start(testing.allocator, dir);
        defer s.stop(testing.allocator);
        _ = adminRow(aa, s.addr, try std.fmt.allocPrint(aa, "CALL geode.auth.mfa_verify('rs6608', '{s}')", .{try codeFor(aa, secret)})) catch |e| {
            std.debug.print("SONNY-6608 (4): after a restart mfa_verify with a code from the enrolled secret was refused\n", .{});
            return e;
        };
    }
}
