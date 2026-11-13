// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=ClientVerifiesPinnedFreshAttestation; STATUS=TESTED; TEST=tests/test_sonny6435_kms_attestation.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6435 (1): `RemoteKmsClient.attest` returned whatever hash the server
// sent. It never checked the signature, and checking it would have proved
// nothing: the server signed with a key it handed out in the same reply, the
// client pinned no key (and dials with an unverified TLS certificate), and
// the signed message had no nonce, so any recorded reply could be replayed.
// An unconnected client even made up a constant "attestation" hash.
//
// The contract, driven against the real remote KMS server over QUIC:
//   - a client with no pinned attestation key refuses to attest (fail closed);
//   - an unconnected client refuses instead of inventing a hash;
//   - a server whose attestation key is not the pinned one is rejected;
//   - a genuine, fresh attestation from the pinned server is accepted;
//   - a tampered reply (signature, hash, or presented key rewritten to the
//     pinned one) is rejected;
//   - a reply recorded for one nonce is rejected for another (replay);
//   - the server refuses an Attest request that carries no nonce.
const std = @import("std");
const kms = @import("security/kms_remote"); // module provided by build.zig
const kms_tls = @import("kms_test_tls.zig");

const testing = std.testing;

const seed_a = [_]u8{0xA1} ** 32;
const seed_b = [_]u8{0xB2} ** 32;

/// Public key of an attestation key seed, as an operator would export it.
fn publicKeyOf(seed: [32]u8) ![32]u8 {
    var s = try kms.Server.init(testing.allocator, 0);
    defer s.deinit();
    try s.setAttestationKeySeed(seed);
    return s.attestationPublicKey();
}

/// A real remote KMS server with attestation key `seed`, served from a
/// background thread for the duration of `body`.
fn withServer(auth: []const u8, seed: [32]u8, body: fn (*kms.RemoteKmsServer, u16) anyerror!void) !void {
    var tls = try kms_tls.TestTls.init(testing.allocator);
    defer tls.deinit(testing.allocator);
    var server = try kms.RemoteKmsServer.init(testing.allocator, 0x6435);
    defer server.deinit();
    try server.startWithOptions(0, tls.startOptions());
    try server.server.setAttestationKeySeed(seed);
    server_ca = tls.caPath();
    try server.server.setAuthToken(auth);
    var stop = std.atomic.Value(bool).init(false);
    const serving = try std.Thread.spawn(.{}, kms.RemoteKmsServer.serveUntilStopped, .{ &server, &stop });
    defer {
        stop.store(true, .release);
        serving.join();
    }
    try body(&server, server.port);
}

/// The CA bundle of the server `withServer` is running (SONNY-6442).
var server_ca: []const u8 = "";

// Clients stay on page_allocator: the pinned vendor TLS stack leaks client
// handshake allocations (see tests/canary_remote_kms.zig).
fn connectClient(port: u16, auth: []const u8) !kms.RemoteKmsClient {
    // SONNY-6442: the client verifies the server against its CA bundle.
    var client = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .ca_cert_path = server_ca });
    errdefer client.deinit();
    try client.connect("127.0.0.1", port);
    client.setAuthToken(auth);
    return client;
}

/// Send one raw request line on a fresh stream and return the reply line
/// exactly as the server sent it.
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

/// A genuine Attest reply from the real server for `nonce`.
fn captureAttest(client: *kms.RemoteKmsClient, auth: []const u8, nonce: [32]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(nonce, .lower);
    var buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf, "{{\"op\":\"Attest\",\"auth\":\"{s}\",\"nonce\":\"{s}\"}}\n", .{ auth, &hex });
    return rawExchange(client, req);
}

/// Overwrite the hex value of `field` in `resp` with `value`.
fn rewriteField(resp: []u8, field: []const u8, value: *const [32]u8) !void {
    const at = std.mem.indexOf(u8, resp, field) orelse return error.FieldMissing;
    const start = at + field.len;
    if (resp.len < start + 64) return error.FieldTruncated;
    const hex = std.fmt.bytesToHex(value.*, .lower);
    @memcpy(resp[start .. start + 64], &hex);
}

/// Flip one hex digit of `field` in `resp`.
fn flipHexDigit(resp: []u8, field: []const u8, digit: usize) !void {
    const at = std.mem.indexOf(u8, resp, field) orelse return error.FieldMissing;
    const p = at + field.len + digit;
    resp[p] = if (resp[p] == '0') '1' else '0';
}

test "SONNY-6435 (1) a client with no pinned attestation key refuses to attest" {
    try withServer("tok-6435", seed_a, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            try testing.expectError(error.AttestationTrustAnchorMissing, c.attest());
        }
    }.f);
}

test "SONNY-6435 (1) an unconnected client does not invent an attestation" {
    var c = kms.RemoteKmsClient.init(std.heap.page_allocator);
    defer c.deinit();
    c.pinAttestationKey(try publicKeyOf(seed_a));
    try testing.expectError(error.NotConnected, c.attest());
}

test "SONNY-6435 (1) the pinned server's fresh attestation is accepted" {
    try withServer("tok-6435", seed_a, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            c.pinAttestationKey(try publicKeyOf(seed_a));
            const hash = try c.attest();
            try testing.expectEqualSlices(u8, &s.server.attestation_hash, &hash);
            // A second attestation (a new nonce) is also accepted.
            _ = try c.attest();
        }
    }.f);
}

test "SONNY-6435 (1) a server holding another attestation key is rejected" {
    try withServer("tok-6435", seed_b, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            c.pinAttestationKey(try publicKeyOf(seed_a));
            try testing.expectError(error.AttestationKeyMismatch, c.attest());
        }
    }.f);
}

test "SONNY-6435 (1) a tampered attestation is rejected" {
    try withServer("tok-6435", seed_a, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            const pinned = try publicKeyOf(seed_a);
            const nonce = [_]u8{0x5A} ** 32;
            const binding = try c.channelBinding(); // SONNY-6442
            const genuine = try captureAttest(&c, "tok-6435", nonce);
            defer std.heap.page_allocator.free(genuine);

            // Control: the untouched reply verifies.
            _ = try kms.RemoteKmsClient.verifyAttestResponse(genuine, pinned, nonce, binding);

            const sig_tampered = try std.heap.page_allocator.dupe(u8, genuine);
            defer std.heap.page_allocator.free(sig_tampered);
            try flipHexDigit(sig_tampered, "\"sig\":\"", 20);
            try testing.expectError(error.AttestationSignatureInvalid, kms.RemoteKmsClient.verifyAttestResponse(sig_tampered, pinned, nonce, binding));

            const hash_tampered = try std.heap.page_allocator.dupe(u8, genuine);
            defer std.heap.page_allocator.free(hash_tampered);
            try flipHexDigit(hash_tampered, "\"hash\":\"", 3);
            try testing.expectError(error.AttestationSignatureInvalid, kms.RemoteKmsClient.verifyAttestResponse(hash_tampered, pinned, nonce, binding));
        }
    }.f);
}

test "SONNY-6435 (1) a wrong-key server presenting the pinned key is rejected" {
    try withServer("tok-6435", seed_b, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            const pinned = try publicKeyOf(seed_a);
            const nonce = [_]u8{0x3C} ** 32;
            const binding = try c.channelBinding(); // SONNY-6442
            const resp = try captureAttest(&c, "tok-6435", nonce);
            defer std.heap.page_allocator.free(resp);
            // The reply claims the pinned key, but was signed with key B.
            try rewriteField(resp, "\"pub\":\"", &pinned);
            try testing.expectError(error.AttestationSignatureInvalid, kms.RemoteKmsClient.verifyAttestResponse(resp, pinned, nonce, binding));
        }
    }.f);
}

test "SONNY-6435 (1) an attestation replayed for another nonce is rejected" {
    try withServer("tok-6435", seed_a, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            const pinned = try publicKeyOf(seed_a);
            const recorded_nonce = [_]u8{0x11} ** 32;
            const binding = try c.channelBinding(); // SONNY-6442
            const fresh_nonce = [_]u8{0x22} ** 32;
            const recorded = try captureAttest(&c, "tok-6435", recorded_nonce);
            defer std.heap.page_allocator.free(recorded);
            _ = try kms.RemoteKmsClient.verifyAttestResponse(recorded, pinned, recorded_nonce, binding);
            // Replayed as-is to a client that asked with a fresh nonce.
            try testing.expectError(error.AttestationNonceMismatch, kms.RemoteKmsClient.verifyAttestResponse(recorded, pinned, fresh_nonce, binding));
            // Replayed with its echoed nonce rewritten to the fresh one.
            const rewritten = try std.heap.page_allocator.dupe(u8, recorded);
            defer std.heap.page_allocator.free(rewritten);
            try rewriteField(rewritten, "\"nonce\":\"", &fresh_nonce);
            try testing.expectError(error.AttestationSignatureInvalid, kms.RemoteKmsClient.verifyAttestResponse(rewritten, pinned, fresh_nonce, binding));
        }
    }.f);
}

test "SONNY-6435 (1) the server refuses an Attest request without a nonce" {
    try withServer("tok-6435", seed_a, struct {
        fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var c = try connectClient(port, "tok-6435");
            defer c.deinit();
            const resp = try rawExchange(&c, "{\"op\":\"Attest\",\"auth\":\"tok-6435\"}\n");
            defer std.heap.page_allocator.free(resp);
            try testing.expect(std.mem.indexOf(u8, resp, "\"code\":\"AttestNonceRequired\"") != null);
            try testing.expect(std.mem.indexOf(u8, resp, "\"sig\":\"") == null);
        }
    }.f);
}
