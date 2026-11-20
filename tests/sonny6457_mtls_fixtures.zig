// SONNY-6457: shared fixtures for the client-certificate presentation
// regressions (tests/test_sonny6457_connectex_client_cert.zig and
// tests/test_sonny6457_cli_client_cert.zig).
//
// Makes, with openssl:
//   - a server CA and a server certificate for 127.0.0.1 signed by it, so a
//     client verifies the server with --ca-cert like an operator would;
//   - "pinned": a self-signed client certificate that is in the client CA
//     bundle the server is started with (GEODE_MTLS_CLIENT_CA);
//   - "stray": a self-signed client certificate that is not in the bundle.
// and spawns the geode this build emitted with GEODE_MTLS_REQUIRED=1.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

pub const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    server_ca: []const u8,
    server_cert: []const u8,
    server_key: []const u8,
    /// PEM bundle the server trusts for client certificates.
    client_bundle: []const u8,
    pinned_cert: []const u8,
    pinned_key: []const u8,
    stray_cert: []const u8,
    stray_key: []const u8,

    pub fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn path(self: *Fixtures, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.dir, name });
    }
};

fn runOpenssl(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("openssl failed: {s}\n", .{result.stderr});
        return error.OpensslFailed;
    }
}

fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

/// Skips the test when openssl is not installed.
pub fn make() !Fixtures {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    runOpenssl(gpa, io, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    var fx: Fixtures = undefined;
    fx.tmp = std.testing.tmpDir(.{});
    errdefer fx.tmp.cleanup();
    fx.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer fx.arena.deinit();
    const a = fx.arena.allocator();
    fx.dir = try tmpDirPath(a, &fx.tmp);

    const ca_ext = [_][]const u8{ "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign" };
    const client_ext = [_][]const u8{ "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-addext", "extendedKeyUsage=clientAuth" };

    // Server CA (self-signed) and the server certificate it signs.
    fx.server_ca = try fx.path("server-ca.crt");
    const server_ca_key = try fx.path("server-ca.key");
    try runOpenssl(gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", server_ca_key });
    {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", server_ca_key, "-days", "2", "-subj", "/CN=sonny6457-server-ca", "-out", fx.server_ca });
        try argv.appendSlice(a, &ca_ext);
        try runOpenssl(gpa, io, argv.items);
    }
    fx.server_key = try fx.path("server.key");
    fx.server_cert = try fx.path("server.crt");
    const server_csr = try fx.path("server.csr");
    const server_ext = try fx.path("server.ext");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = server_ext, .data = "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n" });
    try runOpenssl(gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", fx.server_key });
    try runOpenssl(gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", fx.server_key, "-subj", "/CN=127.0.0.1", "-out", server_csr });
    try runOpenssl(gpa, io, &.{ "openssl", "x509", "-sha256", "-req", "-in", server_csr, "-CA", fx.server_ca, "-CAkey", server_ca_key, "-CAcreateserial", "-days", "2", "-extfile", server_ext, "-out", fx.server_cert });

    // Client certificates: "pinned" is in the client CA bundle, "stray" is not.
    for ([_][]const u8{ "pinned", "stray" }) |name| {
        const key = try fx.path(try std.fmt.allocPrint(a, "{s}.key", .{name}));
        const crt = try fx.path(try std.fmt.allocPrint(a, "{s}.crt", .{name}));
        try runOpenssl(gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", key, "-days", "2", "-subj", try std.fmt.allocPrint(a, "/CN=sonny6457-{s}", .{name}), "-out", crt });
        try argv.appendSlice(a, &client_ext);
        try runOpenssl(gpa, io, argv.items);
    }
    fx.pinned_cert = try fx.path("pinned.crt");
    fx.pinned_key = try fx.path("pinned.key");
    fx.stray_cert = try fx.path("stray.crt");
    fx.stray_key = try fx.path("stray.key");
    fx.client_bundle = fx.pinned_cert;
    return fx;
}

pub const Server = struct {
    handle: util.ServerHandle,
    port: u16,
    addr: []const u8,

    pub fn deinit(self: *Server) void {
        self.handle.deinit();
    }
};

/// Starts `geode serve` with the fixture server certificate,
/// GEODE_MTLS_REQUIRED=1 and the fixture client CA bundle.
pub fn startMtlsServer(a: std.mem.Allocator, fx: *Fixtures, name: []const u8) !Server {
    const fa = fx.arena.allocator();
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(fa, port);
    const data_dir = try std.fmt.allocPrint(fa, "{s}/data-{s}", .{ fx.dir, name });
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir);
    const ca_env = try std.fmt.allocPrint(fa, "GEODE_MTLS_CLIENT_CA={s}", .{fx.client_bundle});
    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--cert", fx.server_cert, "--key", fx.server_key, "--data-dir", data_dir }, &.{ "GEODE_MTLS_REQUIRED=1", ca_env });
    errdefer handle.deinit();
    try util.waitForServerReady(a, addr, 30000);
    return .{ .handle = handle, .port = port, .addr = addr };
}
