// SONNY-6453 item 1: `GEODE_MTLS_REQUIRED` verifies client certificates
// against the CA the operator configured, and nothing else.
//
// Before: the server asked for a client certificate but never told the TLS
// layer which CA to trust, so the chain was checked against a process-global
// trust store geode never set. Every properly signed certificate was
// rejected, while a client that sent ANY certificate without a
// CertificateVerify (no proof it holds the key, no chain validation at all)
// passed the "certificate present" check and went on to authenticate. gRPC
// listeners ignored the setting.
//
// Spawns the geode this build emitted with GEODE_MTLS_REQUIRED=1 and
// GEODE_MTLS_CLIENT_CA, and dials it over real QUIC with client
// certificates made by openssl:
//   accepted: a self-signed CA certificate that is in the client CA bundle
//   rejected: a leaf from a CA not in the bundle, a self-signed non-CA
//             certificate, a self-signed CA not in the bundle, an expired
//             certificate in the bundle, no certificate, and a certificate
//             sent without CertificateVerify
//   no start: mTLS required with no client CA, with a CA file that does not
//             exist, and together with a gRPC listener.
//
// CANARY: REQ=REQ-AUTH-MTLS-QUIC-006; FEATURE="mTLS over QUIC"; ASPECT=ClientCaTrust; STATUS=TESTED; TEST=tests/test_sonny6453_mtls_client_ca.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const quic = @import("transport/quic");
const vq = @import("vendor_quic");
const util = @import("proto_test_util.zig");

const alpn = [_][]const u8{"geode/1"};

const Fixtures = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    /// PEM bundle the server trusts: the "good" CA, the pinned client
    /// certificate and the expired pinned certificate.
    bundle: []const u8,
    /// DER certificate + PEM-decoded private key per client identity.
    pinned: Ident,
    good_leaf: Ident,
    other_leaf: Ident,
    self_signed_leaf: Ident,
    stray_ca: Ident,
    expired: Ident,

    fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
};

const Ident = struct { cert: []const u8, key: []const u8 };

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

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

fn loadIdent(a: std.mem.Allocator, io: std.Io, cert_path: []const u8, key_path: []const u8) !Ident {
    return .{
        .cert = try vq.pem.parseCertificate(a, try readFile(a, io, cert_path)),
        .key = try vq.pem.parsePrivateKey(a, try readFile(a, io, key_path)),
    };
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
    fx.dir = try tmpDirPath(a, &fx.tmp);
    const P = struct {
        fn j(al: std.mem.Allocator, d: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f });
        }
    };
    const d = fx.dir;
    const ca_ext = [_][]const u8{ "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-addext", "extendedKeyUsage=clientAuth" };

    // Self-signed CA certificates: good-ca (signs good-leaf), other-ca (not
    // trusted, signs other-leaf), pinned (trusted, used directly as a client
    // certificate), stray-ca (self-signed CA not in the bundle).
    for ([_][]const u8{ "good-ca", "other-ca", "pinned", "stray-ca" }) |name| {
        const key = try P.j(a, d, try std.fmt.allocPrint(a, "{s}.key", .{name}));
        const crt = try P.j(a, d, try std.fmt.allocPrint(a, "{s}.crt", .{name}));
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", key, "-days", "2", "-subj", try std.fmt.allocPrint(a, "/CN=sonny6453-{s}", .{name}), "-out", crt });
        try argv.appendSlice(a, &ca_ext);
        try run(spawn_gpa, io, argv.items);
    }
    // Leaves: one per issuing CA, plus a self-signed non-CA certificate.
    const leaf_ext = try P.j(a, d, "leaf.ext");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_ext, .data = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n" });
    for ([_][2][]const u8{ .{ "good-leaf", "good-ca" }, .{ "other-leaf", "other-ca" } }) |pair| {
        const key = try P.j(a, d, try std.fmt.allocPrint(a, "{s}.key", .{pair[0]}));
        const csr = try P.j(a, d, try std.fmt.allocPrint(a, "{s}.csr", .{pair[0]}));
        const crt = try P.j(a, d, try std.fmt.allocPrint(a, "{s}.crt", .{pair[0]}));
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key });
        try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-new", "-key", key, "-subj", try std.fmt.allocPrint(a, "/CN=sonny6453-{s}", .{pair[0]}), "-out", csr });
        try run(spawn_gpa, io, &.{ "openssl", "x509", "-sha256", "-req", "-in", csr, "-CA", try P.j(a, d, try std.fmt.allocPrint(a, "{s}.crt", .{pair[1]})), "-CAkey", try P.j(a, d, try std.fmt.allocPrint(a, "{s}.key", .{pair[1]})), "-CAcreateserial", "-days", "2", "-extfile", leaf_ext, "-out", crt });
    }
    {
        const key = try P.j(a, d, "self-leaf.key");
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key });
        try run(spawn_gpa, io, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", key, "-days", "2", "-subj", "/CN=sonny6453-self-leaf", "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=clientAuth", "-out", try P.j(a, d, "self-leaf.crt") });
    }
    // An expired self-signed CA certificate (2020-01-01 .. 2020-01-02).
    {
        const key = try P.j(a, d, "expired.key");
        const csr = try P.j(a, d, "expired.csr");
        const cnf = try P.j(a, d, "ca.cnf");
        const index = try P.j(a, d, "index.txt");
        const serial = try P.j(a, d, "serial");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index, .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = serial, .data = "01\n" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cnf, .data = try std.fmt.allocPrint(a, "[ca]\ndefault_ca=d\n[d]\ndatabase={s}\nnew_certs_dir={s}\nserial={s}\ndefault_md=sha256\npolicy=p\nunique_subject=no\ncopy_extensions=copy\n[p]\ncommonName=supplied\n", .{ index, d, serial }) });
        try run(spawn_gpa, io, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "openssl", "req", "-sha256", "-new", "-key", key, "-subj", "/CN=sonny6453-expired", "-out", csr });
        try argv.appendSlice(a, &ca_ext);
        try run(spawn_gpa, io, argv.items);
        try run(spawn_gpa, io, &.{ "openssl", "ca", "-batch", "-config", cnf, "-selfsign", "-keyfile", key, "-in", csr, "-startdate", "20200101000000Z", "-enddate", "20200102000000Z", "-notext", "-out", try P.j(a, d, "expired.crt") });
    }

    // The client CA bundle the server is told to trust.
    var bundle: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "good-ca.crt", "pinned.crt", "expired.crt" }) |f| try bundle.appendSlice(a, try readFile(a, io, try P.j(a, d, f)));
    fx.bundle = try P.j(a, d, "client-ca-bundle.pem");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fx.bundle, .data = bundle.items });

    fx.pinned = try loadIdent(a, io, try P.j(a, d, "pinned.crt"), try P.j(a, d, "pinned.key"));
    fx.good_leaf = try loadIdent(a, io, try P.j(a, d, "good-leaf.crt"), try P.j(a, d, "good-leaf.key"));
    fx.other_leaf = try loadIdent(a, io, try P.j(a, d, "other-leaf.crt"), try P.j(a, d, "other-leaf.key"));
    fx.self_signed_leaf = try loadIdent(a, io, try P.j(a, d, "self-leaf.crt"), try P.j(a, d, "self-leaf.key"));
    fx.stray_ca = try loadIdent(a, io, try P.j(a, d, "stray-ca.crt"), try P.j(a, d, "stray-ca.key"));
    fx.expired = try loadIdent(a, io, try P.j(a, d, "expired.crt"), try P.j(a, d, "expired.key"));
    return fx;
}

fn sleepMs(ms: u64) void {
    const ts = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

const Outcome = enum { accepted, rejected };

/// Dial the server presenting `cert` (DER) and, when given, proving it with
/// `key`. `cert` without `key` sends a Certificate and no CertificateVerify.
/// Accepted means the handshake completed and a password HELLO succeeded.
fn attempt(a: std.mem.Allocator, port: u16, cert: ?[]const u8, key: ?[]const u8) !Outcome {
    var qc = quic.QuicClient.init(a);
    const cfg = try a.create(vq.QuicConfig);
    cfg.* = .{
        .version = .v1,
        .alpn = &alpn,
        .cc = .cubic,
        .enable_datagram = false,
        .enable_spin_bit = false,
        .grease = true,
        .compatible_vn = false,
        .enable_retry = false,
        .token_secret = null,
        .token_expiry_ms = 60000,
        .enable_pacing = false,
        .max_datagram_size = 1200,
        .max_idle_timeout_ms = 30000,
        .max_udp_payload = 1350,
        .cert_path = null,
        .key_path = null,
        .ca_path = null,
        // The server certificate is the dev self-signed one; this test is
        // about the server's verification of the CLIENT.
        .allow_insecure = true,
        .aead_confidentiality_limit_override = null,
        .aead_integrity_limit_override = null,
        .inline_server_cert_der = null,
        .inline_server_priv_p256 = null,
        .inline_client_cert_der = cert,
        .inline_client_priv_key = key,
    };
    qc.quic_config = cfg;
    qc.endpoint = vq.endpointInit(&qc.allocator, "0.0.0.0:0", cfg) catch |e| {
        qc.deinit();
        return e;
    };
    const server_addr = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port});
    defer a.free(server_addr);
    qc.connection = vq.connect(qc.endpoint.?, server_addr, "127.0.0.1") catch {
        qc.deinit();
        return .rejected;
    };
    qc.waitForHandshake(3) catch {
        qc.deinit();
        return .rejected;
    };
    const stream = qc.getStream() catch {
        qc.deinit();
        return .rejected;
    };
    var pc = util.QuicProtoClient{ .allocator = a, .client = qc, .stream = stream };
    defer pc.deinit();
    var hello = pc.helloWithTimeout(a, util.defaultUsername(), util.defaultPassword(), 4000) catch return .rejected;
    defer hello.deinit(a);
    return if (hello.success) .accepted else .rejected;
}

fn makeDataDir(a: std.mem.Allocator, fx: *const Fixtures, name: []const u8) ![]const u8 {
    const p = try std.fmt.allocPrint(a, "{s}/data-{s}", .{ fx.dir, name });
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), p);
    return p;
}

/// Starts geode with `env`; true when it exits non-zero within 30 s instead
/// of serving.
fn startupRefused(a: std.mem.Allocator, args: []const []const u8, env: []const []const u8) !bool {
    var h = try util.spawnServer(a, args, env);
    defer h.deinit();
    const pid = h.child.id.?;
    var waited: u32 = 0;
    while (waited < 300 and util.processAlive(pid)) : (waited += 1) sleepMs(100);
    if (util.processAlive(pid)) return false;
    const term = try h.child.wait(h.threaded.io());
    h.child.id = null;
    return term != .exited or term.exited != 0;
}

test "SONNY-6453: mTLS required verifies client certificates against GEODE_MTLS_CLIENT_CA only" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    const fa = fx.arena.allocator();

    const port = try util.getRandomPort();
    const addr = try util.formatAddr(fa, port);
    const ca_env = try std.fmt.allocPrint(fa, "GEODE_MTLS_CLIENT_CA={s}", .{fx.bundle});
    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", try makeDataDir(fa, &fx, "matrix") }, &.{ "GEODE_MTLS_REQUIRED=1", ca_env });
    defer handle.deinit();
    try util.waitForServerReady(a, addr, 30000);

    const Case = struct { name: []const u8, cert: ?[]const u8, key: ?[]const u8, want: Outcome };
    const cases = [_]Case{
        .{ .name = "self-signed CA certificate in the client CA bundle", .cert = fx.pinned.cert, .key = fx.pinned.key, .want = .accepted },
        .{ .name = "leaf signed by a CA not in the bundle", .cert = fx.other_leaf.cert, .key = fx.other_leaf.key, .want = .rejected },
        .{ .name = "self-signed non-CA certificate", .cert = fx.self_signed_leaf.cert, .key = fx.self_signed_leaf.key, .want = .rejected },
        .{ .name = "self-signed CA certificate not in the bundle", .cert = fx.stray_ca.cert, .key = fx.stray_ca.key, .want = .rejected },
        .{ .name = "expired certificate in the bundle", .cert = fx.expired.cert, .key = fx.expired.key, .want = .rejected },
        .{ .name = "no client certificate", .cert = null, .key = null, .want = .rejected },
        .{ .name = "trusted certificate without CertificateVerify", .cert = fx.pinned.cert, .key = null, .want = .rejected },
        .{ .name = "untrusted self-signed certificate without CertificateVerify", .cert = fx.self_signed_leaf.cert, .key = null, .want = .rejected },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try attempt(a, port, c.cert, c.key);
        if (got != c.want) {
            failures += 1;
            std.debug.print("  {s}: expected {s}, got {s}\n", .{ c.name, @tagName(c.want), @tagName(got) });
        }
    }
    if (failures != 0) return error.MtlsMatrixMismatch;
}

test "SONNY-6453: mTLS required refuses to start without a usable client CA or with a gRPC listener" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try makeFixtures();
    defer fx.deinit();
    const fa = fx.arena.allocator();
    const ca_env = try std.fmt.allocPrint(fa, "GEODE_MTLS_CLIENT_CA={s}", .{fx.bundle});
    const missing_env = try std.fmt.allocPrint(fa, "GEODE_MTLS_CLIENT_CA={s}/does-not-exist.pem", .{fx.dir});

    var failures: usize = 0;
    {
        const addr = try util.formatAddr(fa, try util.getRandomPort());
        if (!try startupRefused(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", try makeDataDir(fa, &fx, "noca") }, &.{"GEODE_MTLS_REQUIRED=1"})) {
            failures += 1;
            std.debug.print("  GEODE_MTLS_REQUIRED=1 with no GEODE_MTLS_CLIENT_CA: server started\n", .{});
        }
    }
    {
        const addr = try util.formatAddr(fa, try util.getRandomPort());
        if (!try startupRefused(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", try makeDataDir(fa, &fx, "missing") }, &.{ "GEODE_MTLS_REQUIRED=1", missing_env })) {
            failures += 1;
            std.debug.print("  GEODE_MTLS_REQUIRED=1 with a client CA file that does not exist: server started\n", .{});
        }
    }
    {
        const addr = try util.formatAddr(fa, try util.getRandomPort());
        const grpc_addr = try std.fmt.allocPrint(fa, "127.0.0.1:{d}", .{try util.getRandomTcpPort()});
        if (!try startupRefused(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--listen-grpc", grpc_addr, "--data-dir", try makeDataDir(fa, &fx, "grpc") }, &.{ "GEODE_MTLS_REQUIRED=1", ca_env })) {
            failures += 1;
            std.debug.print("  GEODE_MTLS_REQUIRED=1 with --listen-grpc (gRPC cannot verify client certificates): server started\n", .{});
        }
    }
    if (failures != 0) return error.MtlsStartupNotRefused;
}
