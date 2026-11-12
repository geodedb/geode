// SONNY-6378: server exit leaks and release hygiene found during
// SONNY-6374/6272/2441/6321.
//
//   (1) a debug server reported the GraphRBACPolicy that
//       server_init.wireAuthDDLCallbacks allocates as leaked at exit;
//   (2) ... and the proto-reader registry capacity that main.zig reserves
//       (proto_reader_registry.Registry.reserveCapacity);
//   (3) KeyRegistry.rotateWithRemoteKms called ArrayList.writer(), which Zig
//       0.16 does not have, so it never compiled; it also installed an
//       all-zero key as the active data key, and loadState unwraps every
//       envelope with the local simulated KMS, so a remotely wrapped key
//       could not be reloaded. Nothing called it; it is removed;
//   (4) verifyPasswordArgon2id accepted any t and m up to u32 max, so a
//       corrupt stored hash could burn CPU or memory on every login;
//   (5) tests/e2e_security_tde_mfa.zig was compiled but never run, while
//       REQ-GQL-TDE-001 cited it as evidence;
//   (6) the GAP-0193 batch 2 engine, misc, security and testing suites
//       backed product-feature TESTED markers with parse-only tests;
//   (7) Dockerfile, Dockerfile.dev, Dockerfile.simple, Dockerfile.reliable
//       (and Dockerfile.gpu, docker-compose.yml, scripts/install-deps.sh)
//       pinned Zig 0.15.x; build.zig.zon requires 0.16.0;
//   (8) the structured logger buffered stderr in 4 KiB and never flushed, so
//       startup log.info lines did not reach the log.
//
// CANARY: REQ=REQ-SONNY-6378-SERVER-EXIT-HYGIENE; FEATURE="Server Hygiene"; ASPECT=ExitLeaksArgonBoundsLoggerDocker; STATUS=TESTED; TEST=tests/test_sonny6378_server_exit_and_hygiene.zig; OWNER=server; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const options = @import("sonny6378_options");
const build_options = @import("build_options");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn monoMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

fn repoFileExists(allocator: std.mem.Allocator, rel: []const u8) !bool {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    std.Io.Dir.cwd().access(io(), abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// ---------------------------------------------------------------------------
// (1) (2) (8) a debug server: startup log lines, and no leak at exit
// ---------------------------------------------------------------------------

const LoggedServer = struct {
    handle: util.ServerHandle,
    dir: scratch.ScratchDir,
    log_path: []u8,

    fn start(allocator: std.mem.Allocator) !LoggedServer {
        var dir = try scratch.ScratchDir.create("sonny6378");
        errdefer dir.remove();
        const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
        defer allocator.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(io(), data_dir);
        const log_path = try std.fs.path.join(allocator, &.{ dir.path(), "server.log" });
        errdefer allocator.free(log_path);

        const quic_port = try test_ports.freeUdpPort();
        var listen_buf: [32]u8 = undefined;
        const listen = try std.fmt.bufPrint(&listen_buf, "127.0.0.1:{d}", .{quic_port});

        var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer map.deinit();
        try map.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
        try map.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);

        const argv = [_][]const u8{ geode_test_bin.geode_exe, "serve", "--listen", listen, "--data-dir", data_dir, "--log-level=info" };

        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const log_file = try std.Io.Dir.cwd().createFile(io(), log_path, .{});
        defer log_file.close(io());
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &argv,
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        return .{
            .handle = .{ .allocator = allocator, .threaded = threaded, .child = child, .env_map = map },
            .dir = dir,
            .log_path = log_path,
        };
    }

    fn log(self: *const LoggedServer, allocator: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io(), self.log_path, allocator, .limited(64 << 20));
    }

    fn printLog(self: *const LoggedServer, allocator: std.mem.Allocator) void {
        if (self.log(allocator)) |text| {
            defer allocator.free(text);
            std.debug.print("SONNY-6378: server log:\n{s}\n", .{text});
        } else |_| {}
    }

    fn waitForLog(self: *const LoggedServer, allocator: std.mem.Allocator, needle: []const u8, ms: u64) !void {
        const deadline = monoMs() + ms;
        while (monoMs() < deadline) {
            const text = try self.log(allocator);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
            sleepMs(100);
        }
        std.debug.print("SONNY-6378: no \"{s}\" within {d} ms\n", .{ needle, ms });
        self.printLog(allocator);
        return error.Timeout;
    }

    fn stop(self: *LoggedServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.log_path);
        self.dir.remove();
    }
};

fn waitExit(pid: std.posix.pid_t, ms: u64) ?u32 {
    const deadline = monoMs() + ms;
    while (monoMs() < deadline) {
        var status: u32 = 0;
        const rc = std.os.linux.wait4(pid, &status, std.os.linux.W.NOHANG, null);
        if (rc == pid) return status;
        sleepMs(50);
    }
    return null;
}

/// The number of DebugAllocator leak reports whose stack trace mentions
/// `needle`.
fn leakReportsMentioning(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var blocks = std.mem.splitSequence(u8, text, "leaked:");
    _ = blocks.next();
    while (blocks.next()) |block| {
        const end = std.mem.indexOf(u8, block, "\n\n") orelse block.len;
        if (std.mem.indexOf(u8, block[0..end], needle) != null) n += 1;
    }
    return n;
}

test "leakReportsMentioning counts only the reports whose trace names the site" {
    const text = "error(DebugAllocator): memory address 0x1 leaked: \n/src/server/server_init.zig:1110:36: 0x3 in wireAuthDDLCallbacks (unified_entry.zig)\n\nerror(DebugAllocator): memory address 0x2 leaked: \n/src/server/proto_reader_registry.zig:92:41: 0x4 in reserveCapacity (unified_entry.zig)\n\n[shutdown] done\n";
    try testing.expectEqual(@as(usize, 1), leakReportsMentioning(text, "wireAuthDDLCallbacks"));
    try testing.expectEqual(@as(usize, 1), leakReportsMentioning(text, "proto_reader_registry"));
    try testing.expectEqual(@as(usize, 0), leakReportsMentioning(text, "main.zig"));
}

test "SONNY-6378 (1)(2)(8) a debug server writes its startup log.info lines and frees the RBAC policy and proto-reader registry at exit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var srv = try LoggedServer.start(allocator);
    defer srv.stop(allocator);
    try srv.waitForLog(allocator, "[startup] server ready", 120_000);

    // (8) A log.info line main.zig writes at startup, before the server is
    // ready, is in the log while the server runs.
    const startup_line = "Authentication configured for persistent auth graph";
    var startup_logged = false;
    {
        const deadline = monoMs() + 5_000;
        while (monoMs() < deadline) {
            const text = try srv.log(allocator);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, startup_line) != null) {
                startup_logged = true;
                break;
            }
            sleepMs(100);
        }
    }

    const pid = srv.handle.child.id.?;
    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, 120_000) orelse {
        std.debug.print("SONNY-6378: the server did not exit within 120 s of SIGTERM\n", .{});
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    };
    srv.handle.child.id = null; // reaped

    const text = try srv.log(allocator);
    defer allocator.free(text);
    const policy_leaks = leakReportsMentioning(text, "wireAuthDDLCallbacks");
    const registry_leaks = leakReportsMentioning(text, "proto_reader_registry");
    const exited_zero = std.os.linux.W.IFEXITED(status) and std.os.linux.W.EXITSTATUS(status) == 0;
    if (!startup_logged or policy_leaks != 0 or registry_leaks != 0 or !exited_zero) {
        std.debug.print("SONNY-6378: startup log.info line logged while running: {}; GraphRBACPolicy leak reports: {d}; proto-reader registry leak reports: {d}; exit status 0x{x} (want exit 0)\n", .{ startup_logged, policy_leaks, registry_leaks, status });
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// (3) rotateWithRemoteKms
// ---------------------------------------------------------------------------

test "SONNY-6378 (3) the never-compiled KeyRegistry.rotateWithRemoteKms and its never-built test are gone" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    const src = try readRepoFile(allocator, "src/security/key_rotation.zig");
    defer allocator.free(src);
    for ([_][]const u8{ "rotateWithRemoteKms", "setRemoteKms", "remote_kms_host", "kms_remote.zig" }) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) {
            bad += 1;
            std.debug.print("SONNY-6378 (3): src/security/key_rotation.zig still contains {s}\n", .{needle});
        }
    }
    if (try repoFileExists(allocator, "tests/test_external_kms_remote.zig")) {
        bad += 1;
        std.debug.print("SONNY-6378 (3): tests/test_external_kms_remote.zig (built by no step) still exists\n", .{});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (4) Argon2id t and m bounds
// ---------------------------------------------------------------------------

/// A real Argon2id PHC string for `password` with the given parameters.
fn phcFor(buf: []u8, password: []const u8, t: u32, m: u32, p: u24) ![]const u8 {
    const salt = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = t, .m = m, .p = p }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m={d},t={d},p={d}${x}${x}", .{ m, t, p, &salt, &hash });
}

test "SONNY-6378 (4) verifyPasswordArgon2id refuses a stored hash whose t or m is outside the bounds" {
    if (build_options.fips) return error.SkipZigTest;
    const allocator = testing.allocator;
    const auth = geode.auth;
    var buf: [256]u8 = undefined;

    // The bounds: 1 <= t <= 10, 8*p <= m <= 262144 KiB (256 MiB), 1 <= p <= 16.
    // A correct hash at the iteration bound verifies.
    const ok = try phcFor(&buf, "pw", 10, 64, 1);
    try testing.expect(try auth.verifyPasswordArgon2id(allocator, "pw", ok));

    // A correct hash for the right password, with one iteration more than
    // the bound, is refused: a stored t is untrusted input and is not run.
    const too_many_t = try phcFor(&buf, "pw", 11, 64, 1);
    try testing.expect(!try auth.verifyPasswordArgon2id(allocator, "pw", too_many_t));

    // Out-of-range parameters are refused without running Argon2 (an
    // unbounded t would not return within the test's lifetime).
    const salt_hex = "000102030405060708090a0b0c0d0e0f";
    const hash_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    for ([_][]const u8{
        "m=64,t=4294967295,p=1",
        "m=4294967295,t=1,p=1",
        "m=19456,t=0,p=1",
        "m=7,t=1,p=1", // below Argon2's minimum of 8 KiB per lane
        "m=64,t=1,p=9", // below 8 KiB per lane
        "m=262145,t=1,p=1",
        "m=19456,t=1,p=17",
    }) |params| {
        const s = try std.fmt.bufPrint(&buf, "$argon2id$v=19${s}${s}${s}", .{ params, salt_hex, hash_hex });
        const started = monoMs();
        try testing.expect(!try auth.verifyPasswordArgon2id(allocator, "pw", s));
        try testing.expect(monoMs() - started < 5_000);
    }

    // The parameters Geode writes still verify.
    const written = try auth.hashPasswordArgon2id(allocator, "pw");
    defer allocator.free(written);
    try testing.expect(try auth.verifyPasswordArgon2id(allocator, "pw", written));
}

// ---------------------------------------------------------------------------
// (5) tests/e2e_security_tde_mfa.zig runs
// ---------------------------------------------------------------------------

test "SONNY-6378 (5) tests/e2e_security_tde_mfa.zig is run by a named step in the aggregate" {
    const allocator = testing.allocator;
    const build_src = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_src);
    var bad: usize = 0;
    if (std.mem.indexOf(u8, build_src, "b.step(\"test-e2e-security-tde-mfa\"") == null) {
        bad += 1;
        std.debug.print("SONNY-6378 (5): no named step test-e2e-security-tde-mfa runs tests/e2e_security_tde_mfa.zig\n", .{});
    }
    if (std.mem.indexOf(u8, build_src, "b.addRunArtifact(e2e_security_tde_mfa_test)") == null) {
        bad += 1;
        std.debug.print("SONNY-6378 (5): tests/e2e_security_tde_mfa.zig is compiled but never run\n", .{});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (6) parse-only suites behind product-feature TESTED markers
// ---------------------------------------------------------------------------

test "SONNY-6378 (6) the parse-only GAP-0193 batch 2 suites claim no product feature TESTED" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{
        "tests/test_gap_0193_batch2_engine.zig",
        "tests/test_gap_0193_batch2_misc.zig",
        "tests/test_gap_0193_batch2_security.zig",
        "tests/test_gap_0193_batch2_testing.zig",
    }) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "// CANARY:")) continue;
            if (std.mem.indexOf(u8, trimmed, "STATUS=TESTED") == null) continue;
            // A refused statement is a parser behaviour: parsing is the
            // whole of it, so a parse test is its evidence.
            if (std.mem.indexOf(u8, trimmed, "Refused;") != null) continue;
            bad += 1;
            std.debug.print("SONNY-6378 (6): {s}:{d}: TESTED by a parse-only test: {s}\n", .{ rel, n, trimmed });
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (7) Zig version pins
// ---------------------------------------------------------------------------

/// The `.minimum_zig_version` of build.zig.zon.
fn requiredZig(zon: []const u8) ![]const u8 {
    const key = ".minimum_zig_version = \"";
    const at = std.mem.indexOf(u8, zon, key) orelse return error.NoMinimumZigVersion;
    const rest = zon[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoMinimumZigVersion;
    return rest[0..end];
}

/// Whether `line` pins a Zig version (an ARG/ENV/variable default or a
/// zig-<arch>-linux-<version> tarball name) other than `want`.
fn pinsOtherZig(line: []const u8, want: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "ZIG_VERSION=", "ZIG_VER=", "ZIG_VERSION: \"", "ZIG_VERSION:-", "-linux-0." };
    for (markers) |m| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, m)) |at| {
            from = at + m.len;
            var start = at + m.len;
            if (std.mem.endsWith(u8, m, "0.")) start -= 2;
            while (start < line.len and (line[start] == '"' or line[start] == ' ')) start += 1;
            var end = start;
            while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.')) end += 1;
            var version = line[start..end];
            version = std.mem.trimEnd(u8, version, ".");
            if (version.len == 0 or version[0] != '0') continue;
            if (!std.mem.eql(u8, version, want)) return version;
        }
    }
    return null;
}

test "SONNY-6378 (7) the Zig pin parser" {
    try testing.expectEqualStrings("0.15.2", pinsOtherZig("ARG ZIG_VERSION=0.15.2", "0.16.0").?);
    try testing.expectEqualStrings("0.15.1", pinsOtherZig("COPY docker/zig/zig-x86_64-linux-0.15.1.tar.xz /tmp/zig.tar.xz", "0.16.0").?);
    try testing.expectEqualStrings("0.15.2", pinsOtherZig("        ZIG_VERSION: \"0.15.2\"", "0.16.0").?);
    try testing.expectEqualStrings("0.15.2", pinsOtherZig("    GEODE_ZIG_VERSION=\"${GEODE_ZIG_VERSION:-0.15.2}\"", "0.16.0").?);
    try testing.expect(pinsOtherZig("ARG ZIG_VERSION=0.16.0", "0.16.0") == null);
    try testing.expect(pinsOtherZig("    ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig", "0.16.0") == null);
}

test "SONNY-6378 (7) no Dockerfile, compose file or install script pins a Zig other than build.zig.zon's minimum" {
    const allocator = testing.allocator;
    const zon = try readRepoFile(allocator, "build.zig.zon");
    defer allocator.free(zon);
    const want = try requiredZig(zon);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io(), options.repo_root, .{ .iterate = true });
        defer dir.close(io());
        var it = dir.iterate();
        while (try it.next(io())) |entry| {
            if (entry.kind != .file) continue;
            const is_dockerfile = std.mem.startsWith(u8, entry.name, "Dockerfile");
            const is_compose = std.mem.startsWith(u8, entry.name, "docker-compose") and std.mem.endsWith(u8, entry.name, ".yml");
            if (is_dockerfile or is_compose) try files.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    try files.append(allocator, try allocator.dupe(u8, "scripts/install-deps.sh"));
    try testing.expect(files.items.len > 5);

    var bad: usize = 0;
    for (files.items) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (pinsOtherZig(line, want)) |v| {
                bad += 1;
                std.debug.print("SONNY-6378 (7): {s}:{d}: pins Zig {s}, build.zig.zon requires {s}: {s}\n", .{ rel, n, v, want, std.mem.trim(u8, line, " ") });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
