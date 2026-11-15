//! SONNY-6609, against the built binary.
//!
//! (1) After a real `geode serve` enrolled a user (`mfa_setup` over QUIC)
//!     and stopped, no file in the data directory holds the TOTP secret: the
//!     user record holds it sealed (AES-256-GCM under a key derived from the
//!     HMAC key), and the loop2 hydration snapshots, which hold property
//!     values unencrypted, are not written for `__geode_security`. Before,
//!     the secret was in the security graph's files in plaintext.
//! (4) `geode user show` prints the user's MFA state (it printed none).
//!     The offline `geode user mfa enable --code` opens the sealed secret.
//!
// CANARY: REQ=REQ-SONNY-6609-MFA-AT-REST-SCAN; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6609_mfa_at_rest_scan.zig; OWNER=security; UPDATED=2026-11-15
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
const hmac_hex = "69" ** 32;
const user_pw = "Correct Horse Battery Staple 6609";

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

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6609-{s}-{d}", .{ tag, monoMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

fn codeFor(aa: std.mem.Allocator, secret: []const u8) ![]const u8 {
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    const code = try mfa.generateCodeFromBase32(aa, secret, realMillis(), 30, 6);
    return std.fmt.allocPrint(aa, "{d:0>6}", .{code});
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

    /// SIGTERM and wait (60 s at most) for the server's own shutdown, so it
    /// runs its shutdown checkpoint (which writes the loop2 hydration
    /// snapshots); `stop` SIGKILLs (SONNY-6614: `ServerHandle.stopGracefully`).
    fn stopGracefully(self: *Server, allocator: std.mem.Allocator) !void {
        defer allocator.free(self.addr);
        if (self.proc.stopGracefully(60_000) != .exited) return error.ServerDidNotShutDown;
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

/// Every file under `dir` (recursively) whose bytes contain `needle`, and
/// every loop2 hydration snapshot (`hydration_*.snap`, in the graph's
/// UUID-named directory) of the security graph: one that names
/// `__geode_security` or its `AuthChainRoot` label.
fn scan(aa: std.mem.Allocator, dir_path: []const u8, needle: []const u8, hits: *std.ArrayList([]const u8), snaps: *std.ArrayList([]const u8)) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(aa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_path, entry.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(1 << 30)) catch continue;
        if (std.mem.indexOf(u8, bytes, needle) != null) try hits.append(aa, path);
        if (std.mem.startsWith(u8, entry.basename, "hydration_") and
            (std.mem.indexOf(u8, bytes, "__geode_security") != null or std.mem.indexOf(u8, bytes, "AuthChainRoot") != null))
            try snaps.append(aa, path);
    }
}

fn runOk(aa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const r = try runGeode(aa, args);
    if (r.code != 0) {
        std.debug.print("{s} {s} exited {d}:\n{s}\n", .{ args[1], args[2], r.code, r.output });
        return error.CommandFailed;
    }
    return r.output;
}

test "SONNY-6609 (1)(4): no file of the data directory holds the TOTP secret; geode user show prints the MFA state" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "scan");
    defer removeDir(dir);

    var secret: []const u8 = "";
    {
        var s = try Server.start(testing.allocator, dir);
        errdefer s.stop(testing.allocator);
        _ = try adminRow(aa, s.addr, "CREATE USER sc6609 SET PASSWORD '" ++ user_pw ++ "'");
        const row = try adminRow(aa, s.addr, "CALL geode.auth.mfa_setup('sc6609')");
        secret = row[0]["MFA secret: ".len..];
        // Some data in another graph, so a checkpoint has work.
        _ = try adminRow(aa, s.addr, "CREATE (:Doc6609 {v: 1})");
        try s.stopGracefully(testing.allocator);
    }
    try testing.expect(secret.len >= 16);

    var hits: std.ArrayList([]const u8) = .empty;
    var snaps: std.ArrayList([]const u8) = .empty;
    try scan(aa, dir, secret, &hits, &snaps);
    if (hits.items.len > 0) {
        for (hits.items) |h| std.debug.print("SONNY-6609 (1): the TOTP secret is stored in plaintext in {s}\n", .{h});
        return error.MfaSecretInPlaintextOnDisk;
    }
    if (snaps.items.len > 0) {
        for (snaps.items) |h| std.debug.print("SONNY-6609 (1): a loop2 hydration snapshot of __geode_security (property values, unencrypted): {s}\n", .{h});
        return error.SecurityGraphSnapshotWritten;
    }

    // (4) geode user show prints the MFA state; enabling it offline opens the
    // sealed secret.
    var out = try runOk(aa, &.{ binary_path, "user", "show", "sc6609", "--data-dir", dir });
    if (std.mem.indexOf(u8, out, "MFA: disabled (enrolled") == null) {
        std.debug.print("SONNY-6609 (4): geode user show prints no MFA state:\n{s}\n", .{out});
        return error.NoMfaStateShown;
    }
    _ = try runOk(aa, &.{ binary_path, "user", "mfa", "enable", "sc6609", "--code", try codeFor(aa, secret), "--force", "--data-dir", dir });
    out = try runOk(aa, &.{ binary_path, "user", "show", "sc6609", "--data-dir", dir });
    try testing.expect(std.mem.indexOf(u8, out, "MFA: enabled (enrolled") != null);
    // A user with no enrollment.
    out = try runOk(aa, &.{ binary_path, "user", "show", util.defaultUsername(), "--data-dir", dir });
    try testing.expect(std.mem.indexOf(u8, out, "MFA: disabled (not enrolled)") != null);

    // Still nothing in plaintext after the offline change.
    hits.clearRetainingCapacity();
    snaps.clearRetainingCapacity();
    try scan(aa, dir, secret, &hits, &snaps);
    for (hits.items) |h| std.debug.print("SONNY-6609 (1): after geode user mfa enable the TOTP secret is in plaintext in {s}\n", .{h});
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}
