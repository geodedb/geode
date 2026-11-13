// SONNY-6453 item 2 (+ item 5's raft comment): every cluster peer dial —
// 2PC, raft and the cluster coordinator — uses ONE verified transport
// configuration (`cluster_auth.dialClusterPeer`): the CA bundle in
// GEODE_CLUSTER_CA_CERT, or (Debug builds only) GEODE_CLUSTER_INSECURE.
//
// Before: the 2PC transport never read GEODE_CLUSTER_CA_CERT. It dialled
// with verification on and no trust anchor, so a verified 2PC handshake
// could never complete. Raft and the coordinator, with no CA configured,
// fell back to a "system CA bundle" that is never loaded. Now a dial with
// no CA configured is refused up front with error.ClusterCaRequired.
//
// Real QUIC: an in-process `QuicTransport` server on 127.0.0.31 presents a
// leaf signed by CA "good"; the 2PC transport and the raft/cluster connect
// helper dial it with the right CA, another CA, and none. Fixtures are made
// with openssl (skips only if openssl is absent or 127.0.0.31 cannot be bound).
// 127.0.0.31 is an address no other test step uses (SONNY-6460), so the
// free port it binds there cannot collide with another step's.
//
// CANARY: REQ=REQ-2PC-TLS-003; FEATURE="2PC TLS"; ASPECT=ClusterCa; STATUS=TESTED; TEST=tests/test_sonny6453_cluster_peer_tls.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const quic = @import("transport/quic");
const test_ports = @import("test_ports.zig");

const twophase = geode.distributed.twophase;
const cluster_auth = geode.distributed.cluster_auth;

const SERVER_IP = "127.0.0.31";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    good_ca: [:0]const u8,
    other_ca: [:0]const u8,
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
    fx.good_ca = try std.fmt.allocPrintSentinel(a, "{s}/good-ca.crt", .{dir}, 0);
    const other_key = try std.fmt.allocPrint(a, "{s}/other-ca.key", .{dir});
    fx.other_ca = try std.fmt.allocPrintSentinel(a, "{s}/other-ca.crt", .{dir}, 0);
    fx.leaf_key = try std.fmt.allocPrint(a, "{s}/leaf.key", .{dir});
    const leaf_csr = try std.fmt.allocPrint(a, "{s}/leaf.csr", .{dir});
    fx.leaf = try std.fmt.allocPrint(a, "{s}/leaf.crt", .{dir});
    const ext = try std.fmt.allocPrint(a, "{s}/leaf.ext", .{dir});

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.31,DNS:127.0.0.31\nextendedKeyUsage=serverAuth\n",
    });
    for ([_][2][]const u8{ .{ good_key, fx.good_ca }, .{ other_key, fx.other_ca } }, [_][]const u8{ "/CN=sonny6453-good-ca", "/CN=sonny6453-other-ca" }) |pair, subj| {
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", pair[0] });
        try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", pair[0], "-days", "1", "-subj", subj, "-addext", "basicConstraints=critical,CA:TRUE", "-out", pair[1] });
    }
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", fx.leaf_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", fx.leaf_key, "-subj", "/CN=sonny6453-peer", "-out", leaf_csr });
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

fn setClusterCa(path: ?[:0]const u8) void {
    if (path) |p| {
        _ = setenv("GEODE_CLUSTER_CA_CERT", p, 1);
    } else {
        _ = unsetenv("GEODE_CLUSTER_CA_CERT");
    }
}

test "SONNY-6453: 2PC dials participants verified against GEODE_CLUSTER_CA_CERT" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    _ = unsetenv("GEODE_CLUSTER_INSECURE");
    var fx = try makeFixtures();
    defer fx.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);
    defer setClusterCa(null);
    const endpoint = try std.fmt.allocPrint(a, "{s}:{d}", .{ SERVER_IP, srv.port });
    defer a.free(endpoint);

    // The cluster CA that signed the participant: the handshake completes.
    {
        setClusterCa(fx.good_ca);
        var t = twophase.TwoPhaseTransport.init(a);
        defer t.deinit();
        _ = try t.getConnection(endpoint);
    }
    // A CA that did not sign it: refused.
    {
        setClusterCa(fx.other_ca);
        var t = twophase.TwoPhaseTransport.init(a);
        defer t.deinit();
        try std.testing.expectError(error.HandshakeFailed, t.getConnection(endpoint));
    }
    // No cluster CA configured: refused before dialling, with a clear error.
    {
        setClusterCa(null);
        var t = twophase.TwoPhaseTransport.init(a);
        defer t.deinit();
        try std.testing.expectError(error.ClusterCaRequired, t.getConnection(endpoint));
    }
}

test "SONNY-6453: the raft / cluster coordinator peer dial verifies against the cluster CA and refuses without one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    _ = unsetenv("GEODE_CLUSTER_INSECURE");
    var fx = try makeFixtures();
    defer fx.deinit();
    var srv: Server = undefined;
    try Server.start(a, &srv, &fx);
    defer srv.stopAndFree(a);
    defer setClusterCa(null);

    {
        setClusterCa(null);
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try std.testing.expectError(error.ClusterCaRequired, cluster_auth.dialClusterPeer(&qc, SERVER_IP, srv.port));
        try std.testing.expect(qc.connection == null);
    }
    {
        setClusterCa(fx.good_ca);
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        try cluster_auth.dialClusterPeer(&qc, SERVER_IP, srv.port);
        try qc.waitForHandshake(5);
    }
}
