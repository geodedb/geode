// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-002; FEATURE="RemoteKMSVerifiedChannel"; ASPECT=VerifiedChannelBoundAttestation; STATUS=TESTED; TEST=tests/test_sonny6442_kms_channel.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6442 (1-3), driven against the real remote KMS server over QUIC:
//
// (1) `RemoteKmsClient.connect` dialed with `connectInsecure`: the server's
//     certificate was never verified, and the attestation signature covered
//     only the client's nonce and the hash, so a man in the middle could
//     relay the Attest exchange to the real server and pass its reply on.
//     The contract: the client refuses to connect without a CA bundle
//     (fail closed), with a bundle it cannot load, or to a server whose
//     certificate that bundle does not verify; and an attestation is bound
//     to the TLS channel it was asked on (RFC 8446 exporter), so one
//     obtained on another channel -- what a relay forwards -- is rejected.
// (2) An unconnected client "generated" and "unwrapped" keys locally under
//     a KEK derived from the fixed public seed 0x12345678. The contract:
//     generate, unwrap and privUnwrap refuse with error.NotConnected.
// (3) The attested hash was SHA-256(auth token || kek[0..16]), changing with
//     the token and computed from raw KEK bytes. The contract: it is the
//     KEK's identifier HKDF-SHA256(ikm = KEK, salt = "GEODE-KMS-KEK-ID-V1"),
//     the same whatever the token, set before any token, and different for
//     another KEK.
// And the seeded "local simulation" KMS client (external_kms_client.zig) is
// reachable from tests only: nothing in src/ but kms.zig's KMSProvider
// imports it, and its constructors refuse to compile outside a test build.
const std = @import("std");
const kms = @import("security/kms_remote"); // module provided by build.zig
const kms_tls = @import("kms_test_tls.zig");
const options = @import("sonny6442_kms_options");

const testing = std.testing;

const auth = "tok-6442";
const attest_seed = [_]u8{0x64} ** 32;

/// A real remote KMS server, served from a background thread for the
/// duration of `body`, which gets the server and its CA bundle.
fn withServer(body: fn (*kms.RemoteKmsServer, []const u8) anyerror!void) !void {
    var tls = try kms_tls.TestTls.init(testing.allocator);
    defer tls.deinit(testing.allocator);
    var server = try kms.RemoteKmsServer.init(testing.allocator, 0x6442);
    defer server.deinit();
    try server.startWithOptions(0, tls.startOptions());
    try server.server.setAttestationKeySeed(attest_seed);
    try server.server.setAuthToken(auth);
    var stop = std.atomic.Value(bool).init(false);
    const serving = try std.Thread.spawn(.{}, kms.RemoteKmsServer.serveUntilStopped, .{ &server, &stop });
    defer {
        stop.store(true, .release);
        serving.join();
    }
    try body(&server, tls.caPath());
}

// Clients stay on page_allocator: the pinned vendor TLS stack leaks client
// handshake allocations (see tests/canary_remote_kms.zig).
fn verifiedClient(port: u16, ca: []const u8) !kms.RemoteKmsClient {
    var client = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .ca_cert_path = ca, .handshake_timeout_secs = 10 });
    errdefer client.deinit();
    try client.connect("127.0.0.1", port);
    client.setAuthToken(auth);
    return client;
}

/// Send one raw request line on a fresh stream and return the reply line.
fn rawExchange(client: *kms.RemoteKmsClient, request: []const u8) ![]u8 {
    const qc = &client.quic_client.?;
    var stream = try qc.getStream();
    defer stream.close();
    try stream.writeAll(request);
    var waited_ms: u32 = 0;
    while (true) {
        try qc.poll(50);
        return stream.readLine(8192) catch |err| {
            if (err != error.WouldBlock) return err;
            if (waited_ms >= 30_000) return error.Timeout;
            waited_ms += 60;
            std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
            continue;
        };
    }
}

fn publicKey() ![32]u8 {
    var s = try kms.Server.init(testing.allocator, 0);
    defer s.deinit();
    try s.setAttestationKeySeed(attest_seed);
    return s.attestationPublicKey();
}

// ---------------------------------------------------------------- (1)

test "SONNY-6442 (1) a client with no CA bundle refuses to connect" {
    try withServer(struct {
        fn f(s: *kms.RemoteKmsServer, ca: []const u8) !void {
            std.mem.doNotOptimizeAway(ca);
            var c = kms.RemoteKmsClient.init(std.heap.page_allocator);
            defer c.deinit();
            try testing.expectError(error.KmsTrustAnchorMissing, c.connect("127.0.0.1", s.port));
            try testing.expect(!c.connected);
        }
    }.f);
}

test "SONNY-6442 (1) a CA bundle that cannot be loaded is an error, not an unverified connection" {
    try withServer(struct {
        fn f(s: *kms.RemoteKmsServer, ca: []const u8) !void {
            std.mem.doNotOptimizeAway(ca);
            var c = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .ca_cert_path = "/nonexistent/sonny6442-ca.pem", .handshake_timeout_secs = 5 });
            defer c.deinit();
            if (c.connect("127.0.0.1", s.port)) |_| return error.ConnectedWithoutTrustAnchor else |_| {}
            try testing.expect(!c.connected);
        }
    }.f);
}

test "SONNY-6442 (1) a server whose certificate the CA bundle does not verify is refused" {
    // Another server's self-signed certificate as the only trust anchor.
    var other = try kms_tls.TestTls.init(testing.allocator);
    defer other.deinit(testing.allocator);
    const Ctx = struct {
        var wrong_ca: []const u8 = undefined;
        fn f(s: *kms.RemoteKmsServer, ca: []const u8) !void {
            std.mem.doNotOptimizeAway(ca);
            var c = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .ca_cert_path = wrong_ca, .handshake_timeout_secs = 5 });
            defer c.deinit();
            if (c.connect("127.0.0.1", s.port)) |_| return error.ConnectedToUnverifiedServer else |_| {}
            try testing.expect(!c.connected);
        }
    };
    Ctx.wrong_ca = other.caPath();
    try withServer(Ctx.f);
}

test "SONNY-6442 (1) a verified client generates, unwraps and accepts the pinned server's attestation" {
    try withServer(struct {
        fn f(s: *kms.RemoteKmsServer, ca: []const u8) !void {
            var c = try verifiedClient(s.port, ca);
            defer c.deinit();
            const env = try c.generate();
            const k1 = try c.unwrap(env);
            const k2 = try c.privUnwrap(env);
            try testing.expectEqualSlices(u8, &k1, &k2);
            c.pinAttestationKey(try publicKey());
            const hash = try c.attest();
            try testing.expectEqualSlices(u8, &s.server.attestation_hash, &hash);
        }
    }.f);
}

test "SONNY-6442 (1) an attestation obtained on another TLS channel is rejected" {
    try withServer(struct {
        fn f(s: *kms.RemoteKmsServer, ca: []const u8) !void {
            // `relay` is the channel a man in the middle would hold to the
            // real server; `victim` is the client's own channel.
            var relay = try verifiedClient(s.port, ca);
            defer relay.deinit();
            var victim = try verifiedClient(s.port, ca);
            defer victim.deinit();
            const pinned = try publicKey();

            const relay_binding = try relay.channelBinding();
            const victim_binding = try victim.channelBinding();
            try testing.expect(!std.mem.eql(u8, &relay_binding, &victim_binding));

            // The victim's fresh nonce, asked over the relay's channel.
            const nonce = [_]u8{0x42} ** 32;
            const hex = std.fmt.bytesToHex(nonce, .lower);
            var buf: [256]u8 = undefined;
            const req = try std.fmt.bufPrint(&buf, "{{\"op\":\"Attest\",\"auth\":\"{s}\",\"nonce\":\"{s}\"}}\n", .{ auth, &hex });
            const relayed = try rawExchange(&relay, req);
            defer std.heap.page_allocator.free(relayed);

            // Control: it verifies for the channel it was asked on ...
            _ = try kms.RemoteKmsClient.verifyAttestResponse(relayed, pinned, nonce, relay_binding);
            // ... and not for the victim's channel.
            try testing.expectError(error.AttestationSignatureInvalid, kms.RemoteKmsClient.verifyAttestResponse(relayed, pinned, nonce, victim_binding));
        }
    }.f);
}

// ---------------------------------------------------------------- (2)

test "SONNY-6442 (2) an unconnected client refuses generate, unwrap and privUnwrap" {
    var c = kms.RemoteKmsClient.init(std.heap.page_allocator);
    defer c.deinit();
    try testing.expectError(error.NotConnected, c.generate());
    const env = kms.Envelope{ .nonce = [_]u8{1} ** 12, .tag = [_]u8{2} ** 16, .ct = [_]u8{3} ** 32 };
    try testing.expectError(error.NotConnected, c.unwrap(env));
    try testing.expectError(error.NotConnected, c.privUnwrap(env));
}

// ---------------------------------------------------------------- (3)

fn expectedKekId(kek: [32]u8) [32]u8 {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = Hkdf.extract("GEODE-KMS-KEK-ID-V1", &kek);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, "", prk);
    return out;
}

test "SONNY-6442 (3) the attested hash is the KEK identifier, independent of the auth token" {
    var a = try kms.Server.init(testing.allocator, 0);
    defer a.deinit();
    const before_token = a.attestation_hash;
    try testing.expect(!std.mem.allEqual(u8, &before_token, 0));
    try testing.expectEqualSlices(u8, &expectedKekId(a.kek), &before_token);
    try testing.expectEqualSlices(u8, &expectedKekId(a.kek), &kms.kekIdentifier(a.kek));

    // Not the old SHA-256(token || kek[0..16]).
    try a.setAuthToken("token-one");
    var legacy: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("token-one");
    h.update(a.kek[0..16]);
    h.final(&legacy);
    try testing.expect(!std.mem.eql(u8, &legacy, &a.attestation_hash));

    // The token does not change it.
    try testing.expectEqualSlices(u8, &before_token, &a.attestation_hash);
    try a.setAuthToken("token-two");
    try testing.expectEqualSlices(u8, &before_token, &a.attestation_hash);

    // Another KEK, another identifier.
    var b = try kms.Server.init(testing.allocator, 0);
    defer b.deinit();
    try testing.expect(!std.mem.eql(u8, &a.attestation_hash, &b.attestation_hash));
}

// ------------------------------------------------- simulated KMS client

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

test "SONNY-6442 the seeded simulated KMS client is reachable from tests only" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Nothing in src/ but kms.zig's KMSProvider imports it.
    const root = try std.fs.path.join(allocator, &.{ options.repo_root, "src" });
    defer allocator.free(root);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var bad: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "security/external_kms_client.zig") or std.mem.eql(u8, entry.path, "security/kms.zig")) continue;
        const text = try dir.readFileAlloc(io, entry.path, allocator, .limited(64 << 20));
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "external_kms_client") != null) {
            std.debug.print("SONNY-6442: src/{s} reaches the simulated KMS client\n", .{entry.path});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // Its constructors, and the factory's LocalSimulated branch, are
    // compiled only into test builds.
    const ext = try readRepoFile(allocator, "src/security/external_kms_client.zig");
    defer allocator.free(ext);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ext, "if (comptime !builtin.is_test) @compileError(simulated_kms_test_only);"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ext, "if (comptime !builtin.is_test) return error.SimulatedKmsUnavailable;"));
    try testing.expect(std.mem.indexOf(u8, ext, "GEODE_ALLOW_LOCAL_KMS") == null);
}
