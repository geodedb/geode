// SONNY-6453 item 4: one rule for a CLI connection with no trust material
// (no --ca-cert, no client certificate, no --insecure-tls-skip-verify).
//
// `geode auth` already refused that implicit unverified connection under
// production posture (a release build or GEODE_ENV=production, unless
// GEODE_ALLOW_INSECURE_TLS=1). `geode query`, `geode shell` and the REPL
// (`zig_quic_bridge.initClient`) connected unverified anyway, with only a
// stderr warning. They now follow the same rule: refused under production
// posture, and in a Debug build outside GEODE_ENV=production they still
// connect (with the warning), as before.
//
// Real QUIC: an in-process `QuicTransport` server on 127.0.0.42 presents a
// leaf signed by CA "good"; the CLI client bridge dials it under each
// posture. This Debug test binary sets GEODE_ENV=production to get
// production posture (a release build gets it unconditionally).
//
// CANARY: REQ=REQ-SEC-CLI-NO-CA-DEFAULT-001; FEATURE="InsecureTlsFlagGate"; ASPECT=ImplicitNoCaDefault; STATUS=TESTED; TEST=tests/test_sonny6453_cli_no_ca_default.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");
const bridge = @import("zig_quic_bridge");
const test_ports = @import("test_ports.zig");

const SERVER_IP = "127.0.0.42";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    good_ca: []const u8,
    leaf: []const u8,
    leaf_key: []const u8,

    fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
};

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

fn makeFixtures() !Fixtures {
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    run(spawn_gpa, io, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    var fx: Fixtures = undefined;
    fx.tmp = std.testing.tmpDir(.{});
    errdefer fx.tmp.cleanup();
    fx.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer fx.arena.deinit();
    const a = fx.arena.allocator();
    const dir = try tmpDirPath(a, &fx.tmp);
    const good_key = try std.fmt.allocPrint(a, "{s}/good-ca.key", .{dir});
    fx.good_ca = try std.fmt.allocPrint(a, "{s}/good-ca.crt", .{dir});
    fx.leaf_key = try std.fmt.allocPrint(a, "{s}/leaf.key", .{dir});
    const leaf_csr = try std.fmt.allocPrint(a, "{s}/leaf.csr", .{dir});
    fx.leaf = try std.fmt.allocPrint(a, "{s}/leaf.crt", .{dir});
    const ext = try std.fmt.allocPrint(a, "{s}/leaf.ext", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ext, .data = "subjectAltName=IP:127.0.0.42,DNS:127.0.0.42\nextendedKeyUsage=serverAuth\n" });
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", good_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", good_key, "-days", "1", "-subj", "/CN=sonny6453-cli-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", fx.good_ca });
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", fx.leaf_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", fx.leaf_key, "-subj", "/CN=sonny6453-cli-server", "-out", leaf_csr });
    try run(spawn_gpa, io, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", fx.good_ca, "-CAkey", good_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", fx.leaf });
    return fx;
}

const Server = struct {
    transport: *quic.QuicTransport,
    thread: std.Thread,
    stop: std.atomic.Value(bool),
    port: u16,

    fn loop(self: *Server) void {
        while (!self.stop.load(.acquire)) self.transport.poll(10) catch {};
    }

    fn start(a: std.mem.Allocator, self: *Server, fx: *const Fixtures) !void {
        self.port = try test_ports.freeUdpPort();
        self.stop = std.atomic.Value(bool).init(false);
        self.transport = try a.create(quic.QuicTransport);
        errdefer a.destroy(self.transport);
        self.transport.* = try quic.QuicTransport.init(a, .{
            .address = SERVER_IP,
            .port = self.port,
            .cert_path = fx.leaf,
            .key_path = fx.leaf_key,
            .cert_auto_generate = .never,
        });
        self.transport.listen() catch |e| {
            self.transport.deinit();
            return if (e == error.AddressNotAvailable) error.SkipZigTest else e;
        };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    fn stopAndFree(self: *Server, a: std.mem.Allocator) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.transport.deinit();
        a.destroy(self.transport);
    }
};

fn resetPostureEnv() void {
    _ = unsetenv("GEODE_ENV");
    _ = unsetenv("GEODE_ALLOW_INSECURE_TLS");
}

test "SONNY-6453: the CLI client refuses an implicit unverified connection under production posture" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);
    defer resetPostureEnv();

    // Production posture, nothing to verify with, no flag: refused before
    // any packet is sent. Before the fix this connected unverified.
    {
        resetPostureEnv();
        _ = setenv("GEODE_ENV", "production", 1);
        if (bridge.initClient(a, SERVER_IP, srv.port, .{}, null, null)) |client| {
            var c = client;
            c.deinit();
            return error.ImplicitUnverifiedConnectionAllowed;
        } else |err| try std.testing.expectEqual(error.ImplicitInsecureTlsRefused, err);
    }
    // The operator's explicit acknowledgement lifts the refusal.
    {
        resetPostureEnv();
        _ = setenv("GEODE_ENV", "production", 1);
        _ = setenv("GEODE_ALLOW_INSECURE_TLS", "1", 1);
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{}, null, null);
        defer client.deinit();
        try client.connect();
    }
    // A --ca-cert verifies, so production posture does not matter.
    {
        resetPostureEnv();
        _ = setenv("GEODE_ENV", "production", 1);
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{ .ca_cert_path = fx.good_ca }, null, null);
        defer client.deinit();
        try client.connect();
    }
    // Debug build outside GEODE_ENV=production: the developer default still
    // connects (and warns).
    {
        resetPostureEnv();
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{}, null, null);
        defer client.deinit();
        try client.connect();
    }
}

test "SONNY-6453: insecurePosture is the geode auth / SEC-CLI-01 rule" {
    const P = bridge.insecurePosture;
    // (is_release, env_production, allow_override)
    try std.testing.expectEqual(bridge.InsecurePosture.warn, P(false, false, false));
    try std.testing.expectEqual(bridge.InsecurePosture.refuse, P(true, false, false));
    try std.testing.expectEqual(bridge.InsecurePosture.refuse, P(false, true, false));
    try std.testing.expectEqual(bridge.InsecurePosture.refuse, P(true, true, false));
    try std.testing.expectEqual(bridge.InsecurePosture.warn, P(true, true, true));
    try std.testing.expectEqual(bridge.InsecurePosture.warn, P(true, false, true));
}

test "SONNY-6453: initClientStrictTls refuses no trust material under production posture" {
    const a = std.testing.allocator;
    defer resetPostureEnv();
    resetPostureEnv();
    _ = setenv("GEODE_ENV", "production", 1);
    if (bridge.initClientStrictTls(a, SERVER_IP, 1, .{}, null, null, .{})) |client| {
        var c = client;
        c.deinit();
        return error.ImplicitUnverifiedConnectionAllowed;
    } else |err| try std.testing.expectEqual(error.ImplicitInsecureTlsRefused, err);
}
