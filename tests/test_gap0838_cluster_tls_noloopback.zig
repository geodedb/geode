// CANARY: REQ=REQ-DIST-CLUSTER-TLS-NOLOOPBACK; FEATURE="DistributedCluster"; ASPECT=PeerTlsHandshakeDistinctIp; STATUS=TESTED; TEST=tests/test_gap0838_cluster_tls_noloopback.zig; OWNER=distributed; UPDATED=2026-06-02
//
// GAP-0838 regression: the Raft peer QUIC/TLS handshake must complete across
// DISTINCT peer IPs in SECURE mode (no GEODE_CLUSTER_INSECURE). Loopback +
// insecure masked this for two releases (0.6.7, 0.6.12). This test binds the
// server on 127.0.0.2 (a distinct loopback IP), uses a real openssl-generated
// CA-issued leaf, and validates the handshake with secure verification.
//
// Skips (error.SkipZigTest) only if openssl is unavailable or 127.0.0.2 cannot
// be bound — never silently passes.
const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");

const SERVER_IP = "127.0.0.2";

const Fixtures = struct {
    dir: []const u8,
    ca_pem: []const u8, // path to CA cert (trust anchor)
    leaf_pem: []const u8, // path to CA-issued server leaf
    leaf_key: []const u8, // path to server leaf key
    selfsigned_pem: []const u8, // path to a self-signed server cert (== its own CA)
    selfsigned_key: []const u8,
};

// Run an external command to completion. Zig 0.16 note: the stdlib's
// `global_single_threaded` Threaded instance ships with `.allocator = .failing`,
// so `std.process.spawn`/`run` through it OOMs immediately inside the spawn
// arena. We therefore drive process spawning through a caller-provided `io`
// backed by a real allocator (see `makeFixtures`), matching the working pattern
// in `src/tools/cert_gen.zig`.
fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

// Generate a CA, a CA-issued leaf with SAN=IP:127.0.0.2,DNS:127.0.0.2, and a
// standalone self-signed server cert with the same SANs. Returns paths under a
// fresh temp dir. Caller frees nothing (arena-style: dir removed by caller).
fn makeFixtures(a: std.mem.Allocator) !Fixtures {
    // A process-spawning IO backed by a real allocator (smp_allocator is allowed
    // in this repo; page_allocator is forbidden). The global single-threaded IO
    // uses a failing allocator and cannot spawn (see `run` above).
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // openssl presence check
    run(spawn_gpa, io, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    const dir = try std.fmt.allocPrint(a, "/tmp/geode-gap0838-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const p = struct {
        fn j(al: std.mem.Allocator, d: []const u8, f: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f }) catch unreachable;
        }
    };
    const ca_key = p.j(a, dir, "ca.key");
    const ca_pem = p.j(a, dir, "ca.crt");
    const leaf_key = p.j(a, dir, "leaf.key");
    const leaf_csr = p.j(a, dir, "leaf.csr");
    const leaf_pem = p.j(a, dir, "leaf.crt");
    const ext = p.j(a, dir, "leaf.ext");
    const ss_key = p.j(a, dir, "ss.key");
    const ss_pem = p.j(a, dir, "ss.crt");

    // SAN extension file
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.2,DNS:127.0.0.2\nextendedKeyUsage=serverAuth\n",
    });
    // CA (P-256 self-signed)
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-x509", "-new", "-key", ca_key, "-days", "3650", "-subj", "/CN=geode-gap0838-ca", "-out", ca_pem });
    // Leaf signed by CA
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-new", "-key", leaf_key, "-subj", "/CN=geode-peer", "-out", leaf_csr });
    try run(spawn_gpa, io, &.{ "openssl", "x509", "-req", "-in", leaf_csr, "-CA", ca_pem, "-CAkey", ca_key, "-CAcreateserial", "-days", "3650", "-extfile", ext, "-out", leaf_pem });
    // Standalone self-signed server cert (acts as its own CA / shared-cert model).
    // NOTE: `openssl req` does NOT accept `-extfile` (that is an `openssl x509`
    // flag); SANs on a self-signed `req -x509` cert must be supplied via
    // `-addext` (openssl 3.x). The CA-issued leaf above correctly uses
    // `x509 -req -extfile <ext>`.
    try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ss_key });
    try run(spawn_gpa, io, &.{ "openssl", "req", "-x509", "-new", "-key", ss_key, "-days", "3650", "-subj", "/CN=geode-peer", "-addext", "subjectAltName=IP:127.0.0.2,DNS:127.0.0.2", "-addext", "extendedKeyUsage=serverAuth", "-out", ss_pem });

    return .{ .dir = dir, .ca_pem = ca_pem, .leaf_pem = leaf_pem, .leaf_key = leaf_key, .selfsigned_pem = ss_pem, .selfsigned_key = ss_key };
}

const ServerThread = struct {
    transport: *quic.QuicTransport,
    stop: *std.atomic.Value(bool),
    fn loop(t: *quic.QuicTransport, stop: *std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            t.poll(10) catch {};
        }
    }
};

const ServerHandle = struct {
    transport: *quic.QuicTransport,
    thread: std.Thread,
    stop: *std.atomic.Value(bool),
};

// Bring up a server on 127.0.0.2:port with cert/key, return port + handles.
fn startServer(a: std.mem.Allocator, cert: []const u8, key: []const u8, port: u16) !ServerHandle {
    const t = try a.create(quic.QuicTransport);
    t.* = try quic.QuicTransport.init(a, .{
        .address = SERVER_IP,
        .port = port,
        .cert_path = cert,
        .key_path = key,
    });
    t.listen() catch |e| {
        t.deinit();
        a.destroy(t);
        return e;
    };
    const stop = try a.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, ServerThread.loop, .{ t, stop });
    return .{ .transport = t, .thread = th, .stop = stop };
}

test "GAP-0838: secure peer TLS handshake on distinct IP fails without trust anchor (RC1 reproduction)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cleanup_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer cleanup_threaded.deinit();
    const io = cleanup_threaded.io();
    // Fixture path strings live in an arena so the leak-checking test allocator
    // sees them all freed at test end; the transport/client objects use `a`.
    var fx_arena = std.heap.ArenaAllocator.init(a);
    defer fx_arena.deinit();
    const fx = makeFixtures(fx_arena.allocator()) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.Io.Dir.cwd().deleteTree(io, fx.dir) catch {};

    const srv = try startServer(a, fx.leaf_pem, fx.leaf_key, 24842);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    // NEGATIVE: default connect() => connectInsecure(allow_insecure=false) with
    // no trust anchor. Must FAIL — this is the cross-pod defect.
    var client = quic.QuicClient.init(a);
    defer client.deinit();
    client.connect(SERVER_IP, 24842) catch return; // connect may itself fail; acceptable
    const r = client.waitForHandshake(2);
    try std.testing.expectError(quic.QuicError.HandshakeError, r);
}

test "GAP-0838: secure peer TLS handshake on distinct IP succeeds with CA trust (Path B)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cleanup_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer cleanup_threaded.deinit();
    const io = cleanup_threaded.io();
    // Fixture path strings live in an arena so the leak-checking test allocator
    // sees them all freed at test end; the transport/client objects use `a`.
    var fx_arena = std.heap.ArenaAllocator.init(a);
    defer fx_arena.deinit();
    const fx = makeFixtures(fx_arena.allocator()) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.Io.Dir.cwd().deleteTree(io, fx.dir) catch {};

    const srv = try startServer(a, fx.leaf_pem, fx.leaf_key, 24843);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    var client = quic.QuicClient.init(a);
    defer client.deinit();
    // connectEx with the CA as trust anchor; SNI = "127.0.0.2" matches IP SAN.
    try client.connectEx(SERVER_IP, 24843, fx.ca_pem, null, null);
    try client.waitForHandshake(5); // must SUCCEED
}

test "GAP-0838: secure peer TLS handshake succeeds with self-signed cert pinned as anchor (RC1 fix model)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cleanup_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer cleanup_threaded.deinit();
    const io = cleanup_threaded.io();
    // Fixture path strings live in an arena so the leak-checking test allocator
    // sees them all freed at test end; the transport/client objects use `a`.
    var fx_arena = std.heap.ArenaAllocator.init(a);
    defer fx_arena.deinit();
    const fx = makeFixtures(fx_arena.allocator()) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.Io.Dir.cwd().deleteTree(io, fx.dir) catch {};

    const srv = try startServer(a, fx.selfsigned_pem, fx.selfsigned_key, 24844);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    var client = quic.QuicClient.init(a);
    defer client.deinit();
    // Pin the server's own self-signed cert as the trust anchor (shared-cert model).
    try client.connectEx(SERVER_IP, 24844, fx.selfsigned_pem, null, null);
    try client.waitForHandshake(5); // must SUCCEED
}
