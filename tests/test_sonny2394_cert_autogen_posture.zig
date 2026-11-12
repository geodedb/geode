// SONNY-2394 (review): a QUIC listener with no certificate must NOT self-sign
// one in production posture.
//
// 4272d00d made QuicTransport.listen's certificate auto-generation actually
// work (it used to fail on an allocator that could not spawn openssl), which
// also let a PRODUCTION listener with no cert self-sign into ./certs and start
// -- where before it refused. Controller decision: fail closed in production
// posture (release build OR GEODE_ENV=production, the GAP-0850 posture); a
// missing certificate is self-signed only in dev posture or when explicitly
// enabled.
//
// This binary runs three times (build.zig): GEODE_ENV=production,
// GEODE_ENV=production plus the explicit opt-in (GEODE_TLS_AUTOGENERATE_CERT=1),
// and with neither set.
//
// CANARY: REQ=REQ-SONNY2394-CERT-AUTOGEN-POSTURE-001; FEATURE="ListenerCertAutogenPosture"; ASPECT=ProductionFailClosed; STATUS=TESTED; TEST=TestSONNY2394_ListenerCertAutogenFollowsPosture; OWNER=transport; UPDATED=2026-09-24
// CANARY: REQ=REQ-SONNY2394-CERT-AUTOGEN-POSTURE-001; FEATURE="ListenerCertAutogenPosture"; ASPECT=PolicyMatrix; STATUS=TESTED; TEST=TestSONNY2394_CertAutogenPolicyMatrix; OWNER=transport; UPDATED=2026-09-24
// CANARY: REQ=REQ-SONNY2394-CERT-AUTOGEN-POSTURE-001; FEATURE="ListenerCertAutogenPosture"; ASPECT=ProcessEnvironment; STATUS=TESTED; TEST=TestSONNY2394_CertAutogenSpawnsWithProcessEnvironment; OWNER=transport; UPDATED=2026-09-24
// CANARY: REQ=REQ-SONNY2394-CERT-AUTOGEN-POSTURE-001; FEATURE="ListenerCertAutogenPosture"; ASPECT=StartupProcessEnvironment; STATUS=TESTED; TEST=TestSONNY2394_StartupCertGenSpawnsWithProcessEnvironment; OWNER=transport; UPDATED=2026-09-24

const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");
const cert_gen = @import("cert_gen");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn productionPosture() bool {
    if (builtin.mode != .Debug) return true;
    const v = getenv("GEODE_ENV") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "production");
}

fn optedIn() bool {
    const v = getenv(quic.cert_autogen_opt_in_env) orelse return false;
    return std.mem.eql(u8, v, "1");
}

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

const Paths = struct {
    dir: []u8,
    cert: []u8,
    key: []u8,

    fn init(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) !Paths {
        const dir = try tmpDirPath(allocator, tmp);
        errdefer allocator.free(dir);
        const cert = try std.fmt.allocPrint(allocator, "{s}/certs/server.crt", .{dir});
        errdefer allocator.free(cert);
        const key = try std.fmt.allocPrint(allocator, "{s}/certs/server.key", .{dir});
        return .{ .dir = dir, .cert = cert, .key = key };
    }

    fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.cert);
        allocator.free(self.key);
    }
};

test "TestSONNY2394_ListenerCertAutogenFollowsPosture" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try Paths.init(allocator, &tmp);
    defer paths.deinit(allocator);

    var qt = try quic.QuicTransport.init(allocator, .{
        .port = 0,
        .address = "127.0.0.1",
        .cert_path = paths.cert,
        .key_path = paths.key,
    });
    defer qt.deinit();

    if (productionPosture() and !optedIn()) {
        // Production posture, no opt-in: a missing certificate refuses to
        // start, and nothing is written.
        try std.testing.expectError(quic.QuicError.CertificateError, qt.listen());
        try std.testing.expect(!fileExists(paths.cert));
        try std.testing.expect(!fileExists(paths.key));
    } else {
        // Dev posture, or the explicit operator opt-in: the missing
        // certificate is self-signed and the listener starts.
        try qt.listen();
        try std.testing.expect(fileExists(paths.cert));
        try std.testing.expect(fileExists(paths.key));
    }
}

fn listenWithPolicy(policy: quic.CertAutoGenerate) !bool {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try Paths.init(allocator, &tmp);
    defer paths.deinit(allocator);
    var qt = try quic.QuicTransport.init(allocator, .{
        .port = 0,
        .address = "127.0.0.1",
        .cert_path = paths.cert,
        .key_path = paths.key,
        .cert_auto_generate = policy,
    });
    defer qt.deinit();
    qt.listen() catch |err| {
        try std.testing.expectEqual(quic.QuicError.CertificateError, err);
        try std.testing.expect(!fileExists(paths.cert));
        return false;
    };
    try std.testing.expect(fileExists(paths.cert));
    return true;
}

// The per-listener config overrides the posture in both directions, in every
// environment this binary runs in.
test "TestSONNY2394_ListenerCertAutogenExplicitPolicy" {
    try std.testing.expect(!try listenWithPolicy(.never));
    try std.testing.expect(try listenWithPolicy(.always));
}

/// Stands in for `openssl`. Into the certificate path it was asked to write
/// (`-out <path>`) it records that it ran, the OPENSSL_CONF it was given, and
/// whether it inherited ignored SIGPIPE, checked by sending itself SIGPIPE.
const openssl_shim =
    \\#!/bin/sh
    \\out=""
    \\keyout=""
    \\while [ "$#" -gt 0 ]; do
    \\  if [ "$1" = "-out" ]; then out="$2"; fi
    \\  if [ "$1" = "-keyout" ]; then keyout="$2"; fi
    \\  shift
    \\done
    \\# A handler is reset by exec; an ignored signal stays ignored. A child
    \\# with default SIGPIPE exits here, before it can record success.
    \\kill -s PIPE "$$"
    \\printf 'geode-openssl-shim OPENSSL_CONF=%s\nSIGPIPE=ignored\n' "$OPENSSL_CONF" > "$out"
    \\# SONNY-6325: like openssl, write the key too; the generator installs both.
    \\printf 'geode-openssl-shim key\n' > "$keyout"
    \\
;

/// Set (or, with null, unset) an environment variable, returning the previous
/// value (owned) so the caller can put it back.
fn swapEnv(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[:0]const u8) !?[:0]u8 {
    const previous: ?[:0]u8 = if (getenv(name)) |v| try allocator.dupeZ(u8, v) else null;
    errdefer if (previous) |p| allocator.free(p);
    if (value) |v| {
        if (setenv(name, v.ptr, 1) != 0) return error.SetEnvFailed;
    } else {
        _ = unsetenv(name);
    }
    return previous;
}

fn restoreEnv(allocator: std.mem.Allocator, name: [*:0]const u8, previous: ?[:0]u8) void {
    if (previous) |p| {
        _ = setenv(name, p.ptr, 1);
        allocator.free(p);
    } else {
        _ = unsetenv(name);
    }
}

fn sigpipeAction() std.posix.Sigaction {
    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &current);
    return current;
}

fn handlerAddress(action: std.posix.Sigaction) usize {
    return if (action.handler.handler) |h| @intFromPtr(h) else 0;
}

/// A shim `openssl` first on PATH, a sentinel OPENSSL_CONF, and SIGPIPE
/// ignored, for one test. `deinit` puts all three back.
const ShimEnv = struct {
    allocator: std.mem.Allocator,
    conf: [:0]u8,
    old_path: ?[:0]u8,
    old_conf: ?[:0]u8,
    old_sigpipe: std.posix.Sigaction,

    fn init(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, dir: []const u8) !ShimEnv {
        const io = std.Io.Threaded.global_single_threaded.io();
        try tmp.dir.createDirPath(io, "bin");
        try tmp.dir.writeFile(io, .{
            .sub_path = "bin/openssl",
            .data = openssl_shim,
            .flags = .{ .permissions = .executable_file },
        });

        const new_path = if (getenv("PATH")) |p|
            try std.fmt.allocPrintSentinel(allocator, "{s}/bin:{s}", .{ dir, p }, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}/bin", .{dir}, 0);
        defer allocator.free(new_path);
        const conf = try std.fmt.allocPrintSentinel(allocator, "{s}/sonny2394-openssl.cnf", .{dir}, 0);
        errdefer allocator.free(conf);

        const old_path = try swapEnv(allocator, "PATH", new_path);
        errdefer restoreEnv(allocator, "PATH", old_path);
        const old_conf = try swapEnv(allocator, "OPENSSL_CONF", conf);

        const ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old_sigpipe: std.posix.Sigaction = undefined;
        std.posix.sigaction(.PIPE, &ignore, &old_sigpipe);

        return .{
            .allocator = allocator,
            .conf = conf,
            .old_path = old_path,
            .old_conf = old_conf,
            .old_sigpipe = old_sigpipe,
        };
    }

    fn deinit(self: *ShimEnv) void {
        std.posix.sigaction(.PIPE, &self.old_sigpipe, null);
        restoreEnv(self.allocator, "OPENSSL_CONF", self.old_conf);
        restoreEnv(self.allocator, "PATH", self.old_path);
        self.allocator.free(self.conf);
    }

    /// The shim, not a real openssl, wrote `cert_path`; it saw OPENSSL_CONF;
    /// and it inherited the ignored SIGPIPE. That last part pins a78b2f29:
    /// exec keeps an ignored signal ignored but resets a handled one to the
    /// default, so the child survives only if nothing installed a SIGPIPE handler
    /// in this process while the child was spawned.
    fn expectRan(self: *const ShimEnv, cert_path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const written = try std.Io.Dir.cwd().readFileAlloc(io, cert_path, self.allocator, .limited(4096));
        defer self.allocator.free(written);
        var lines = std.mem.splitScalar(u8, written, '\n');

        const expected = try std.fmt.allocPrint(self.allocator, "geode-openssl-shim OPENSSL_CONF={s}", .{self.conf});
        defer self.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, lines.next() orelse "");

        try std.testing.expectEqualStrings("SIGPIPE=ignored", lines.next() orelse "");
    }
};

// Certificate auto-generation runs `openssl` with the PROCESS environment: the
// binary is resolved on the process PATH and the child inherits variables such
// as OPENSSL_CONF. It used to run with an empty environment and std's fixed
// default PATH (/usr/local/bin:/bin/:/usr/bin), so an openssl installed
// anywhere else (Nix, Homebrew, a FIPS build under /usr/local/ssl) was never
// found and OPENSSL_CONF never reached it.
//
// Hermetic: a shim `openssl` in a temporary directory is put FIRST on PATH, and
// no real openssl runs. The shim writes a marker instead of a certificate, so
// the listener then refuses the file; what is asserted is that the shim ran and
// saw OPENSSL_CONF.
test "TestSONNY2394_CertAutogenSpawnsWithProcessEnvironment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try Paths.init(allocator, &tmp);
    defer paths.deinit(allocator);
    var shim = try ShimEnv.init(allocator, &tmp, paths.dir);
    defer shim.deinit();

    var qt = try quic.QuicTransport.init(allocator, .{
        .port = 0,
        .address = "127.0.0.1",
        .cert_path = paths.cert,
        .key_path = paths.key,
        .cert_auto_generate = .always,
    });
    defer qt.deinit();

    // a78b2f29: spawning openssl leaves process-wide signal dispositions
    // alone. SIGPIPE is the same after listen() as before it. This alone
    // would not catch a handler that is swapped in and restored around the
    // spawn; the child-side check in `expectRan` does.
    const before = sigpipeAction();
    // The shim's marker is not a PEM certificate, so the listener refuses it.
    try std.testing.expectError(quic.QuicError.CertificateError, qt.listen());
    const after = sigpipeAction();
    try std.testing.expectEqual(handlerAddress(before), handlerAddress(after));
    try std.testing.expectEqual(before.flags, after.flags);

    try shim.expectRan(paths.cert);
}

// `geode serve` without --cert/--key generates its certificate at startup
// through cert_gen.ensureCertificatesAtPath (server/main.zig) when none exists.
// That spawns openssl too, so it must also use the process environment and
// leave SIGPIPE alone.
test "TestSONNY2394_StartupCertGenSpawnsWithProcessEnvironment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try Paths.init(allocator, &tmp);
    defer paths.deinit(allocator);
    var shim = try ShimEnv.init(allocator, &tmp, paths.dir);
    defer shim.deinit();

    const before = sigpipeAction();
    // The shim exits 0, and startup generation does not parse what it wrote.
    try cert_gen.ensureCertificatesAtPath(allocator, paths.cert, paths.key);
    const after = sigpipeAction();
    try std.testing.expectEqual(handlerAddress(before), handlerAddress(after));
    try std.testing.expectEqual(before.flags, after.flags);

    try shim.expectRan(paths.cert);
}

test "TestSONNY2394_CertAutogenPolicyMatrix" {
    const allowed = quic.certAutoGenerationAllowed;
    // (is_release, env_production, opt_in) for the default policy:
    // dev posture self-signs; either production signal refuses; the explicit
    // opt-in lifts the refusal.
    try std.testing.expect(allowed(.dev_only, false, false, false));
    try std.testing.expect(!allowed(.dev_only, true, false, false));
    try std.testing.expect(!allowed(.dev_only, false, true, false));
    try std.testing.expect(!allowed(.dev_only, true, true, false));
    try std.testing.expect(allowed(.dev_only, false, false, true));
    try std.testing.expect(allowed(.dev_only, true, false, true));
    try std.testing.expect(allowed(.dev_only, false, true, true));
    try std.testing.expect(allowed(.dev_only, true, true, true));
    // Explicit policies ignore posture and opt-in.
    for ([_]bool{ false, true }) |rel| for ([_]bool{ false, true }) |prod| for ([_]bool{ false, true }) |opt| {
        try std.testing.expect(!allowed(.never, rel, prod, opt));
        try std.testing.expect(allowed(.always, rel, prod, opt));
    };
    try std.testing.expectEqualStrings("GEODE_TLS_AUTOGENERATE_CERT", quic.cert_autogen_opt_in_env);
}
