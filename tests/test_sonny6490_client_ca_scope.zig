// SONNY-6490 item 1: the mTLS client CAs (GEODE_MTLS_CLIENT_CA) authenticate
// CLIENTS of the geode listener and nothing else. They are never trust
// anchors for a SERVER certificate an outbound dial from the same process
// receives.
//
// Before: `installClientCaTrust` (what `geode serve` runs for
// GEODE_MTLS_REQUIRED) also installed the bundle as the process-wide x509
// trust store. The listener no longer needs that (SONNY-6457 passes the
// bundle to it as `inline_client_ca_der`), but every client TLS context
// created afterwards in the process caches that store and, when it has no
// CA of its own, validates the server against it. A dial without its own CA
// (`QuicClient.connect`, `connectEx` with no CA) then accepted a server that
// presented a client identity from the bundle (a pinned self-signed client
// certificate), or a chain ending in a client CA: a confused deputy.
//
// Real QUIC: an in-process `QuicTransport` on 127.0.0.149 presents the pinned
// client certificate of the mTLS bundle as its server certificate. The
// bundle is loaded with `installClientCaTrust`, as `geode serve` does. Then:
//   - the process-wide trust store stays unset;
//   - a dial with no CA of its own fails the handshake;
//   - the vendor's server-chain validation with no anchors of its own (the
//     exact call a client TLS context makes) rejects a leaf issued by the
//     client CA together with that CA;
//   - every outbound dial geode makes in the server process pins its own
//     anchors, so none would take the client CAs today either: the cluster
//     peer dial (raft, coordinator, 2PC) with a cluster CA that did not sign
//     the endpoint fails, and without one is refused (ClusterCaRequired); the
//     remote KMS client with a KMS CA that did not sign it fails, and without
//     one is refused (KmsTrustAnchorMissing).
// Fixtures are made with openssl (skips only if openssl is absent or
// 127.0.0.149 cannot be bound). 127.0.0.149 is used by no other test step.
//
// CANARY: REQ=REQ-AUTH-MTLS-QUIC-008; FEATURE="mTLS over QUIC"; ASPECT=ClientCaScope; STATUS=TESTED; TEST=tests/test_sonny6490_client_ca_scope.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const quic = @import("transport/quic");
const quic_x509 = @import("quic_x509");
const vq = @import("vendor_quic");
const kms = @import("security/kms_remote");
const test_ports = @import("test_ports.zig");

const cluster_auth = geode.distributed.cluster_auth;

const SERVER_IP = "127.0.0.149";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// GEODE_MTLS_CLIENT_CA: client-ca + the pinned client certificate.
    bundle: []const u8,
    /// A self-signed client identity pinned in the bundle (CA:TRUE, no
    /// extendedKeyUsage, so any purpose); the endpoint serves it.
    pinned: []const u8,
    pinned_key: []const u8,
    /// DER: client-ca and a leaf it issued (no extendedKeyUsage).
    client_ca_der: []const u8,
    client_leaf_der: []const u8,
    /// The CA a cluster peer / KMS server certificate must chain to. It
    /// signed nothing the endpoint presents.
    server_ca: [:0]const u8,

    fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
};

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
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

fn derOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const pem = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    return vq.pem.parseCertificate(a, pem);
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
    const d = try tmpDirPath(a, &fx.tmp);
    const P = struct {
        fn j(al: std.mem.Allocator, dir: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ dir, f });
        }
    };

    const client_ca_key = try P.j(a, d, "client-ca.key");
    const client_ca = try P.j(a, d, "client-ca.crt");
    const server_ca_key = try P.j(a, d, "server-ca.key");
    fx.server_ca = try std.fmt.allocPrintSentinel(a, "{s}/server-ca.crt", .{d}, 0);
    fx.pinned_key = try P.j(a, d, "pinned.key");
    fx.pinned = try P.j(a, d, "pinned.crt");
    const leaf_key = try P.j(a, d, "client-leaf.key");
    const leaf_csr = try P.j(a, d, "client-leaf.csr");
    const leaf = try P.j(a, d, "client-leaf.crt");
    const leaf_ext = try P.j(a, d, "client-leaf.ext");
    fx.bundle = try P.j(a, d, "client-bundle.pem");

    const san = "subjectAltName=IP:" ++ SERVER_IP ++ ",DNS:" ++ SERVER_IP;
    for ([_][3][]const u8{
        .{ client_ca_key, client_ca, "/CN=sonny6490-client-ca" },
        .{ server_ca_key, fx.server_ca, "/CN=sonny6490-server-ca" },
    }) |ca| {
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca[0] });
        try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca[0], "-days", "2", "-subj", ca[2], "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-out", ca[1] });
    }
    // A pinned self-signed client identity (accepted by the mTLS listener
    // because it is in the bundle, test-sonny6453-mtls-client-ca).
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", fx.pinned_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", fx.pinned_key, "-days", "2", "-subj", "/CN=sonny6490-pinned-client", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-addext", san, "-out", fx.pinned });
    // A client leaf issued by client-ca, no extendedKeyUsage.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_ext, .data = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n" ++ san ++ "\n" });
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", leaf_key, "-subj", "/CN=sonny6490-client-leaf", "-out", leaf_csr });
    try run(spawn_gpa, io, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", client_ca, "-CAkey", client_ca_key, "-CAcreateserial", "-days", "2", "-extfile", leaf_ext, "-out", leaf });

    const ca_pem = try std.Io.Dir.cwd().readFileAlloc(io, client_ca, a, .limited(1024 * 1024));
    const pinned_pem = try std.Io.Dir.cwd().readFileAlloc(io, fx.pinned, a, .limited(1024 * 1024));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fx.bundle, .data = try std.mem.concat(a, u8, &.{ ca_pem, pinned_pem }) });

    fx.client_ca_der = try derOf(a, io, client_ca);
    fx.client_leaf_der = try derOf(a, io, leaf);
    return fx;
}

/// An endpoint that presents the pinned client identity as its SERVER
/// certificate.
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
            .cert_path = fx.pinned,
            .key_path = fx.pinned_key,
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

fn setClusterCa(path: ?[:0]const u8) void {
    if (path) |p| {
        _ = setenv("GEODE_CLUSTER_CA_CERT", p, 1);
    } else {
        _ = unsetenv("GEODE_CLUSTER_CA_CERT");
    }
}

fn unixNow() i64 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toSeconds();
}

test "SONNY-6490: loading the mTLS client CA bundle installs no process-wide trust store" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    try std.testing.expect(quic_x509.getTrustStore() == null);

    var trust = try quic.installClientCaTrust(a, fx.bundle);
    defer trust.deinit();
    // Both bundle certificates go to the listener (inline_client_ca_der).
    try std.testing.expectEqual(@as(usize, 2), trust.ders.len);
    try std.testing.expect(quic_x509.getTrustStore() == null);
}

test "SONNY-6490: a dial with no CA of its own rejects a server presenting a client identity from the mTLS bundle" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    var trust = try quic.installClientCaTrust(a, fx.bundle);
    defer trust.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);

    {
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try qc.connect(SERVER_IP, srv.port);
        try std.testing.expectError(error.HandshakeError, qc.waitForHandshake(3));
    }
    {
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try qc.connectEx(SERVER_IP, srv.port, null, null, null);
        try std.testing.expectError(error.HandshakeError, qc.waitForHandshake(3));
    }
}

test "SONNY-6490: server-chain validation without its own anchors rejects a chain ending in a client CA" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    var trust = try quic.installClientCaTrust(a, fx.bundle);
    defer trust.deinit();

    // What a client TLS context with no trusted_ca_der runs on the server's
    // Certificate message: the leaf and its issuer, the client CA.
    const chain = [_][]const u8{ fx.client_leaf_der, fx.client_ca_der };
    if (quic_x509.validateChainReturnLeafAndIssuer(a, &chain, unixNow(), SERVER_IP, .secure, .server_auth, quic_x509.getTrustStore())) |ok| {
        var parsed = ok;
        parsed.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.UntrustedRoot, err);
}

test "SONNY-6490: the cluster peer dial and the remote KMS client never fall back to the client CAs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    _ = unsetenv("GEODE_CLUSTER_INSECURE");
    var fx = try makeFixtures();
    defer fx.deinit();
    var trust = try quic.installClientCaTrust(a, fx.bundle);
    defer trust.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);
    defer setClusterCa(null);

    // Raft, the cluster coordinator and 2PC dial through dialClusterPeer.
    {
        setClusterCa(null);
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try std.testing.expectError(error.ClusterCaRequired, cluster_auth.dialClusterPeer(&qc, SERVER_IP, srv.port));
    }
    {
        setClusterCa(fx.server_ca);
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try cluster_auth.dialClusterPeer(&qc, SERVER_IP, srv.port);
        try std.testing.expectError(error.HandshakeError, qc.waitForHandshake(3));
    }
    // The remote KMS channel.
    {
        var client = kms.RemoteKmsClient.initWithOptions(a, .{ .handshake_timeout_secs = 3 });
        defer client.deinit();
        try std.testing.expectError(error.KmsTrustAnchorMissing, client.connect(SERVER_IP, srv.port));
    }
    {
        var client = kms.RemoteKmsClient.initWithOptions(a, .{ .ca_cert_path = fx.server_ca, .handshake_timeout_secs = 3 });
        defer client.deinit();
        try std.testing.expectError(error.HandshakeError, client.connect(SERVER_IP, srv.port));
        try std.testing.expect(!client.connected);
    }
}
