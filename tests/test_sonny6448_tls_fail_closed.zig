// SONNY-6448 item 1: a QUIC client given a CA bundle verifies the server
// against it or does not connect at all.
//
//   * `QuicClient.connectEx` (the cluster / raft / 2PC peer path, which reads
//     GEODE_CLUSTER_CA_CERT) used to log a warning and carry on WITHOUT a
//     trust anchor when the bundle could not be loaded. It now returns the
//     load error: a missing file, an unreadable file and a file with no
//     certificate in it are all refused before any packet is sent.
//   * `zig_quic_bridge.initClient` (geode query / shell / REPL) used to turn
//     certificate verification OFF unless mTLS material was given, so a
//     `--ca-cert` was silently ignored and a server signed by another CA was
//     accepted. A supplied CA now always verifies.
//
// Real QUIC: an in-process `QuicTransport` server on 127.0.0.2 presents a
// leaf signed by CA "good"; the clients dial it with the right CA, a CA that
// did not sign it, and CA bundles that cannot be loaded. Fixtures are made
// with openssl (skips only if openssl is absent or 127.0.0.2 cannot be bound).
const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");
const bridge = @import("zig_quic_bridge");
const test_ports = @import("test_ports.zig");

const SERVER_IP = "127.0.0.2";

const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    good_ca: []const u8,
    other_ca: []const u8,
    leaf: []const u8,
    leaf_key: []const u8,
    missing_ca: []const u8,
    no_cert_ca: []const u8,
    unreadable_ca: []const u8,

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

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

fn makeFixtures() !Fixtures {
    // Process spawning needs an Io with a real allocator (the global
    // single-threaded one fails every allocation).
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
    const p = struct {
        fn j(al: std.mem.Allocator, d: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f });
        }
    };
    const good_key = try p.j(a, dir, "good-ca.key");
    fx.good_ca = try p.j(a, dir, "good-ca.crt");
    const other_key = try p.j(a, dir, "other-ca.key");
    fx.other_ca = try p.j(a, dir, "other-ca.crt");
    fx.leaf_key = try p.j(a, dir, "leaf.key");
    const leaf_csr = try p.j(a, dir, "leaf.csr");
    fx.leaf = try p.j(a, dir, "leaf.crt");
    const ext = try p.j(a, dir, "leaf.ext");
    fx.missing_ca = try p.j(a, dir, "does-not-exist.crt");
    fx.no_cert_ca = try p.j(a, dir, "no-cert.crt");
    fx.unreadable_ca = try p.j(a, dir, "unreadable.crt");

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.2,DNS:127.0.0.2\nextendedKeyUsage=serverAuth\n",
    });
    for ([_][2][]const u8{ .{ good_key, fx.good_ca }, .{ other_key, fx.other_ca } }, [_][]const u8{ "/CN=sonny6448-good-ca", "/CN=sonny6448-other-ca" }) |pair, subj| {
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", pair[0] });
        try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", pair[0], "-days", "1", "-subj", subj, "-addext", "basicConstraints=critical,CA:TRUE", "-out", pair[1] });
    }
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", fx.leaf_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", fx.leaf_key, "-subj", "/CN=sonny6448-peer", "-out", leaf_csr });
    try run(spawn_gpa, io, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", fx.good_ca, "-CAkey", good_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", fx.leaf });

    // A file that exists but holds no certificate.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fx.no_cert_ca, .data = "this is not a PEM certificate\n" });
    // A real CA certificate the process may not read.
    try run(spawn_gpa, io, &.{ "cp", fx.good_ca, fx.unreadable_ca });
    try run(spawn_gpa, io, &.{ "chmod", "000", fx.unreadable_ca });
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
            // 127.0.0.2 is not bindable on every host.
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

fn runningAsRoot() bool {
    return std.c.geteuid() == 0;
}

test "SONNY-6448: connectEx refuses a CA bundle it cannot load and verifies with one it can" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);

    // Missing CA file: refused, never a connection without a trust anchor.
    {
        var client = quic.QuicClient.init(a);
        defer client.deinit();
        try std.testing.expectError(error.FileNotFound, client.connectEx(SERVER_IP, srv.port, fx.missing_ca, null, null));
        try std.testing.expect(client.connection == null);
    }
    // A file with no certificate in it.
    {
        var client = quic.QuicClient.init(a);
        defer client.deinit();
        try std.testing.expectError(error.NoCertificatesInCaFile, client.connectEx(SERVER_IP, srv.port, fx.no_cert_ca, null, null));
        try std.testing.expect(client.connection == null);
    }
    // An unreadable CA file (root reads anything, so only as non-root).
    if (!runningAsRoot()) {
        var client = quic.QuicClient.init(a);
        defer client.deinit();
        try std.testing.expectError(error.AccessDenied, client.connectEx(SERVER_IP, srv.port, fx.unreadable_ca, null, null));
        try std.testing.expect(client.connection == null);
    }
    // A CA that did not sign the server's certificate: the handshake fails.
    {
        var client = quic.QuicClient.init(a);
        defer client.deinit();
        try client.connectEx(SERVER_IP, srv.port, fx.other_ca, null, null);
        try std.testing.expectError(quic.QuicError.HandshakeError, client.waitForHandshake(3));
    }
    // The CA that signed it: the handshake completes.
    {
        var client = quic.QuicClient.init(a);
        defer client.deinit();
        try client.connectEx(SERVER_IP, srv.port, fx.good_ca, null, null);
        try client.waitForHandshake(5);
    }
}

test "SONNY-6448: the CLI client verifies against a supplied --ca-cert instead of ignoring it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);

    // A CA that did not sign the server: the connection must fail. Before
    // the fix, initClient forced insecure mode (no mTLS material given), so
    // this connected.
    {
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{ .ca_cert_path = fx.other_ca }, null, null);
        defer client.deinit();
        if (client.connect()) |_| {
            return error.TestUnexpectedResult; // accepted a server the CA did not sign
        } else |_| {}
    }
    // A CA bundle that cannot be loaded: refused.
    {
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{ .ca_cert_path = fx.missing_ca }, null, null);
        defer client.deinit();
        try std.testing.expectError(error.FileNotFound, client.connect());
    }
    // The CA that signed it: verified and connected.
    {
        var client = try bridge.initClient(a, SERVER_IP, srv.port, .{ .ca_cert_path = fx.good_ca }, null, null);
        defer client.deinit();
        try client.connect();
    }
}
