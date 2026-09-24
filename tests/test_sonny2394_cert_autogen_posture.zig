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

const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");

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
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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
