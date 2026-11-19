// SONNY-6457 item 1: `QuicClient.connectEx` presents the client certificate
// it is given.
//
// Before: a client certificate path was put in the vendor config's
// `cert_path`, which is how the vendor library tells a SERVER endpoint from a
// client one, and the certificate was never loaded into
// `inline_client_cert_der` / `inline_client_priv_key`, the fields the client
// TLS context sends from. So a geode client could not present a certificate
// to a server that requires one.
//
// Spawns the geode this build emitted with GEODE_MTLS_REQUIRED=1 and a client
// CA bundle, and dials it through `connectEx` with the server CA:
//   accepted: a client certificate in the bundle (handshake + password HELLO)
//   rejected: a client certificate not in the bundle, and no certificate
//   refused before dialling: a certificate without its key, a key without its
//             certificate, a certificate or key file that does not exist.

const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");
const util = @import("proto_test_util.zig");
const fixtures = @import("sonny6457_mtls_fixtures.zig");
const test_ports = @import("test_ports.zig");

const Outcome = enum { accepted, rejected };

fn attempt(a: std.mem.Allocator, port: u16, server_ca: []const u8, cert: ?[]const u8, key: ?[]const u8) !Outcome {
    var qc = quic.QuicClient.init(a);
    qc.connectEx("127.0.0.1", port, server_ca, cert, key) catch {
        qc.deinit();
        return .rejected;
    };
    qc.waitForHandshake(5) catch {
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

test "SONNY-6457: QuicClient.connectEx presents its client certificate to an mTLS-required server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try fixtures.make();
    defer fx.deinit();
    var server = try fixtures.startMtlsServer(a, &fx, "connectex");
    defer server.deinit();

    const Case = struct { name: []const u8, cert: ?[]const u8, key: ?[]const u8, want: Outcome };
    const cases = [_]Case{
        .{ .name = "client certificate in the client CA bundle", .cert = fx.pinned_cert, .key = fx.pinned_key, .want = .accepted },
        .{ .name = "client certificate not in the bundle", .cert = fx.stray_cert, .key = fx.stray_key, .want = .rejected },
        .{ .name = "no client certificate", .cert = null, .key = null, .want = .rejected },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try attempt(a, server.port, fx.server_ca, c.cert, c.key);
        if (got != c.want) {
            failures += 1;
            std.debug.print("  {s}: expected {s}, got {s}\n", .{ c.name, @tagName(c.want), @tagName(got) });
        }
    }
    if (failures != 0) return error.ClientCertMatrixMismatch;
}

test "SONNY-6457: QuicClient.connectEx refuses incomplete or unreadable client identity material" {
    const a = std.testing.allocator;
    var fx = try fixtures.make();
    defer fx.deinit();
    const missing = try fx.path("does-not-exist.pem");
    // Nothing listens on this port: every case must fail before dialling.
    // SONNY-6836: a free port, not a literal (SONNY-6332).
    const port = try test_ports.freeUdpPort();
    const Case = struct { name: []const u8, cert: ?[]const u8, key: ?[]const u8, want: anyerror };
    const cases = [_]Case{
        .{ .name = "certificate without key", .cert = fx.pinned_cert, .key = null, .want = error.ClientCertificateKeyMismatch },
        .{ .name = "key without certificate", .cert = null, .key = fx.pinned_key, .want = error.ClientCertificateKeyMismatch },
        .{ .name = "certificate file missing", .cert = missing, .key = fx.pinned_key, .want = error.FileNotFound },
        .{ .name = "key file missing", .cert = fx.pinned_cert, .key = missing, .want = error.FileNotFound },
        .{ .name = "certificate file holds a key", .cert = fx.pinned_key, .key = fx.pinned_key, .want = error.NoCertificateFound },
        .{ .name = "key file holds a certificate", .cert = fx.pinned_cert, .key = fx.pinned_cert, .want = error.UnsupportedKeyType },
    };
    var failures: usize = 0;
    for (cases) |c| {
        var qc = quic.QuicClient.init(a);
        defer qc.deinit();
        if (qc.connectEx("127.0.0.1", port, fx.server_ca, c.cert, c.key)) |_| {
            failures += 1;
            std.debug.print("  {s}: connectEx dialled, expected {s}\n", .{ c.name, @errorName(c.want) });
        } else |err| if (err != c.want) {
            failures += 1;
            std.debug.print("  {s}: got {s}, expected {s}\n", .{ c.name, @errorName(err), @errorName(c.want) });
        }
    }
    if (failures != 0) return error.ClientIdentityNotRefused;
}
