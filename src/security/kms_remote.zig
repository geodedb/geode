const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
const quic = @import("transport/quic");

/// Monotonic nanoseconds (std's portable awake clock; SONNY-2394 review: was
/// a raw Linux clock_gettime).
fn monoNs() u64 {
    const now = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
    return @intCast(@max(now.nanoseconds, 0));
}

fn sleepMs(ms: i64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(ms), .awake) catch {};
}

// CANARY: REQ=REQ-M6-UNREACHABLE-001; FEATURE="CodeQuality"; ASPECT=ErrorHandling; STATUS=EXEMPT; OWNER=security; UPDATED=2025-10-17
// M6: Replaced all 'unreachable' statements with proper error handling (try/panic)

// kms_remote.zig
// Minimal remote KMS prototype over QUIC performing AES-256-GCM wrap/unwrap.
// Server holds KEK and serves two JSON line oriented requests on a single stream:
//   {"op":"Generate"} -> {"status":"OK","envelope":{...}}
//   {"op":"Unwrap","envelope":{...}} -> {"status":"OK","plaintext":"<64 hex>"}
// Errors -> {"status":"ERR","code":"AuthenticationFailed"}
// This is a development scaffold; now includes minimal token auth (header field) on each request.
//
// Channel security (SONNY-6442): the client verifies the server's
// certificate against an operator-supplied CA bundle (and its name against
// the dialed host) and refuses to connect without one. Generate / Unwrap
// replies carry no signature of their own: they are protected by that
// verified TLS 1.3 channel (server authenticated by its certificate, every
// QUIC packet AEAD-protected). The Attest reply is additionally signed by
// the pinned attestation key over the client's nonce AND the channel's
// RFC 8446 exporter value, so it cannot be relayed onto another channel.

/// Constant-time comparison to prevent timing attacks on authentication tokens.
/// Returns true iff `a` and `b` are equal, without leaking which byte differs.
fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate|TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_InvalidAuth; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_AttestationStub|TestCANARY_REQ_GQL_TDE_ATTEST_001_SignatureVerifyTamperDetect|tests/test_sonny6435_kms_attestation.zig|tests/test_sonny6442_kms_channel.zig; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-002; FEATURE="RemoteKMSVerifiedChannel"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_sonny6442_kms_channel.zig; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap; OWNER=security; UPDATED=2026-11-12

pub const Envelope = struct {
    version: u8 = 1,
    alg: []const u8 = "AES-256-GCM",
    nonce: [12]u8,
    tag: [16]u8,
    ct: [32]u8,
};

/// Domain of the attestation signature. The signed message is
/// `attest_domain || nonce || hash || channel_binding`: the client's fresh
/// 32-byte nonce binds the signature to its request, so a recorded reply
/// cannot be replayed (SONNY-6435), and the channel binding -- the TLS
/// exporter value under `attest_exporter_label` of the connection the
/// request arrived on -- binds it to that TLS channel, so a reply a man in
/// the middle obtained on his own channel to the server does not verify on
/// the client's (SONNY-6442).
pub const attest_domain = "GEODE-KMS-ATTEST-V3";

/// RFC 8446 §7.5 exporter label of the attestation channel binding.
pub const attest_exporter_label = "EXPORTER-geode-kms-attest-v3";

pub fn attestationMessage(nonce: [32]u8, hash: [32]u8, channel_binding: [32]u8) [attest_domain.len + 96]u8 {
    var msg: [attest_domain.len + 96]u8 = undefined;
    @memcpy(msg[0..attest_domain.len], attest_domain);
    @memcpy(msg[attest_domain.len..][0..32], &nonce);
    @memcpy(msg[attest_domain.len + 32 ..][0..32], &hash);
    @memcpy(msg[attest_domain.len + 64 ..][0..32], &channel_binding);
    return msg;
}

/// HKDF salt of the KEK identifier.
pub const kek_id_salt = "GEODE-KMS-KEK-ID-V1";

/// The attested hash (SONNY-6442): a public identifier of the server's KEK,
/// HKDF-SHA256(ikm = KEK, salt = `kek_id_salt`, info = ""). It tells a
/// client WHICH key-encryption key the server holds (it changes when the KEK
/// does) and reveals nothing about it: HKDF is a one-way PRF keyed by all 256
/// KEK bits, so the identifier gives no KEK bytes and no offline guess short
/// of the KEK itself. It does not depend on the auth token. (It replaced
/// SHA-256(token || kek[0..16]), computed over raw KEK bytes.)
pub fn kekIdentifier(kek: [32]u8) ![32]u8 {
    var out: [32]u8 = undefined;
    try cb.Kdf.hkdf(.sha256, &kek, kek_id_salt, "", &out);
    return out;
}

/// Decode the 2*N hex digits that follow `key` (e.g. `"hash":"`) in `json`.
fn hexFieldAfter(json: []const u8, key: []const u8, out: []u8) !void {
    const at = std.mem.indexOf(u8, json, key) orelse return error.InvalidResponse;
    const start = at + key.len;
    const end = start + out.len * 2;
    if (end >= json.len or json[end] != '"') return error.InvalidResponse;
    _ = std.fmt.hexToBytes(out, json[start..end]) catch return error.InvalidResponse;
}

fn envelopeToJson(env: Envelope, w: anytype) !void {
    try w.writeAll("{\"version\":");
    try w.print("{d}", .{env.version});
    try w.writeAll(",\"alg\":\"");
    try w.writeAll(env.alg);
    try w.writeAll("\",\"nonce\":\"");
    for (env.nonce) |b| try w.print("{x:0>2}", .{b});
    try w.writeAll("\",\"tag\":\"");
    for (env.tag) |b| try w.print("{x:0>2}", .{b});
    try w.writeAll("\",\"ct\":\"");
    for (env.ct) |b| try w.print("{x:0>2}", .{b});
    try w.writeAll("\"}");
}

// GAP-0141: Safe hex parsing with proper error handling
// GAP-0145: Bounds-checked JSON parsing
// CANARY: REQ=REQ-HEX-PARSE-KMS-001; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-13
// CANARY: REQ=REQ-JSON-PARSE-KMS-001; FEATURE="Safe JSON Parsing"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=security; UPDATED=2026-01-13
fn parseHexByte(slice: []const u8) !u8 {
    return std.fmt.parseInt(u8, slice, 16) catch return error.InvalidHexEncoding;
}

fn jsonFind(hay: []const u8, key: []const u8) ?usize {
    return std.mem.indexOf(u8, hay, key);
}

fn parseEnvelope(json: []const u8) !Envelope {
    if (jsonFind(json, "\"nonce\":\"") == null) return error.InvalidEnvelope;
    var env: Envelope = .{ .nonce = undefined, .tag = undefined, .ct = undefined };

    // Find field positions with validation
    const nidx = jsonFind(json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
    const tidx = jsonFind(json, "\"tag\":\"") orelse return error.InvalidEnvelope;
    const cidx = jsonFind(json, "\"ct\":\"") orelse return error.InvalidEnvelope;

    const nstart = nidx + 9;
    const tstart = tidx + 7;
    const cstart = cidx + 6;

    // GAP-0145: Bounds checking before array access
    if (nstart + 24 > json.len) return error.TruncatedEnvelope;
    if (tstart + 32 > json.len) return error.TruncatedEnvelope;
    if (cstart + 64 > json.len) return error.TruncatedEnvelope;

    var i: usize = 0;
    while (i < 12) : (i += 1) env.nonce[i] = try parseHexByte(json[nstart + i * 2 .. nstart + i * 2 + 2]);
    i = 0;
    while (i < 16) : (i += 1) env.tag[i] = try parseHexByte(json[tstart + i * 2 .. tstart + i * 2 + 2]);
    i = 0;
    while (i < 32) : (i += 1) env.ct[i] = try parseHexByte(json[cstart + i * 2 .. cstart + i * 2 + 2]);
    return env;
}

// GAP-0142: DEPRECATED - Deterministic PRNG removed for security
// CANARY: REQ=REQ-PRNG-CRYPTO-001; FEATURE="Cryptographic PRNG"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=security; UPDATED=2026-01-13
// The custom xorshift128+ PRNG was insecure for cryptographic use.
// All nonce generation now uses std.crypto.random for cryptographic security.

pub const Server = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8,
    // REMOVED: prng field - use std.crypto.random instead
    auth_token: ?[]const u8 = null,
    /// The attested hash: `kekIdentifier(kek)` (SONNY-6442).
    attestation_hash: [32]u8,
    /// Ed25519 key that signs attestations. An operator provisions it with
    /// `setAttestationKeySeed` and gives clients its public key to pin
    /// (SONNY-6435). Without one, `setAuthToken` creates an ephemeral key,
    /// which no client can pin.
    attest_keypair: ?cb.Sig.KeyPair = null,
    attest_key_provisioned: bool = false,

    /// Initialize KMS server with cryptographically secure KEK
    /// GAP-0142: Now uses std.crypto.random instead of deterministic PRNG
    /// The seed parameter is kept for API compatibility but IGNORED in production
    pub fn init(allocator: std.mem.Allocator, _: u64) !Server {
        var kek: [32]u8 = undefined;
        // Use cryptographic random for KEK generation
        try cb.Csprng.bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .attestation_hash = try kekIdentifier(kek) };
    }

    pub fn setAuthToken(self: *Server, tok: []const u8) !void {
        self.auth_token = tok;
        if (self.attest_key_provisioned) return;
        // Free the prior ephemeral keypair before generating a new one (prevents EVP_PKEY leak)
        if (self.attest_keypair) |*kp| kp.deinit();
        // Generate a fresh ephemeral Ed25519 key pair from cryptographic random
        var seed: [32]u8 = undefined;
        try cb.Csprng.bytes(&seed);
        const attest_kp = try cb.Sig.KeyPair.fromPrivateBytes(.ed25519, &seed);
        self.attest_keypair = attest_kp;
    }

    /// Install the provisioned Ed25519 attestation key (32-byte seed). Its
    /// public key (`attestationPublicKey`) is what clients pin.
    pub fn setAttestationKeySeed(self: *Server, seed: [32]u8) !void {
        const kp = try cb.Sig.KeyPair.fromPrivateBytes(.ed25519, &seed);
        if (self.attest_keypair) |*old| old.deinit();
        self.attest_keypair = kp;
        self.attest_key_provisioned = true;
    }

    /// Public half of the attestation key, for clients to pin.
    pub fn attestationPublicKey(self: *Server) ![32]u8 {
        var kp = self.attest_keypair orelse return error.NotConfigured;
        var out: [32]u8 = undefined;
        _ = try kp.publicBytes(&out);
        return out;
    }

    /// Release resources owned by Server (attestation keypair).
    pub fn deinit(self: *Server) void {
        if (self.attest_keypair) |*kp| kp.deinit();
        self.attest_keypair = null;
    }

    /// GAP-0142: Wrap key material using cryptographically secure nonces
    pub fn wrap(self: *Server, plaintext: [32]u8) !Envelope {
        var nonce: [12]u8 = undefined;
        // Use cryptographic random for nonce generation - CRITICAL for AES-GCM security
        try cb.Csprng.bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        try cb.Aead.seal(.aes_256_gcm, &self.kek, &nonce, &.{}, &plaintext, &ct, &tag);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    pub fn unwrap(self: *Server, env: Envelope) ![32]u8 {
        var out: [32]u8 = undefined;
        var tag = env.tag;
        var nonce = env.nonce;
        cb.Aead.open(.aes_256_gcm, &self.kek, &nonce, &.{}, &env.ct, &tag, &out) catch return error.AuthenticationFailed;
        return out;
    }
};

// CANARY: REQ=REQ-REMOTE-KMS-SERVER-001; FEATURE="Remote KMS Server"; ASPECT=QUICTransport; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-09
pub const RemoteKmsServer = struct {
    allocator: std.mem.Allocator,
    quic_transport: ?*quic.QuicTransport = null,
    /// SONNY-2394: every accepted client connection, each served until it
    /// drains or the server is deinit'ed. Previously a single `active_conn` was
    /// held for the server's whole lifetime, so a second client (let alone 16
    /// concurrent ones) was never accepted or served. Owned by the serving
    /// thread; destroyed in deinit().
    conns: std.ArrayListUnmanaged(ServedConn) = .empty,
    server: Server,
    port: u16 = 0,
    /// Serving counters. Owned by the serving thread: read them only while it
    /// is stopped or parked.
    stats: Stats = .{},

    pub const Stats = struct {
        /// Request lines read and answered (error replies included).
        requests_served: u64 = 0,
        /// Accept notifications for a stream already served on its connection,
        /// released unread (see `ServedConn`).
        stale_notifications: u64 = 0,
    };

    /// An accepted client connection, its in-progress requests, and the ids of
    /// the streams it recently used. SONNY-2394: the transport re-queues a
    /// stream id EVERY time more data lands on it -- accept notifications are
    /// readiness signals, not proof of a new stream (the rule
    /// src/server/quic_connection_handler.zig already applies) -- so a request
    /// that arrives in pieces is announced more than once. A known id is never
    /// treated as a new request: its bytes are read through the one pending
    /// entry for that stream, and the repeat wrapper is released unread.
    pub const ServedConn = struct {
        conn: *quic.QuicConnection,
        /// Requests whose line has not fully arrived yet (review: per-
        /// connection, non-blocking -- a partial request no longer holds up
        /// every other connection, and is no longer dropped after ~50 ms).
        pending: std.ArrayListUnmanaged(PendingRequest) = .empty,
        recent: [recent_capacity]u64 = undefined,
        recent_len: usize = 0,
        recent_next: usize = 0,

        /// Repeat announcements trail the original closely (they are queued
        /// while it is pending or just answered), so a short window of ids
        /// suffices. An id that has left the window is read and found empty,
        /// which releases it as an abandoned request.
        const recent_capacity = 32;

        fn seen(self: *const ServedConn, stream_id: u64) bool {
            return std.mem.indexOfScalar(u64, self.recent[0..self.recent_len], stream_id) != null;
        }

        fn remember(self: *ServedConn, stream_id: u64) void {
            self.recent[self.recent_next] = stream_id;
            self.recent_next = (self.recent_next + 1) % recent_capacity;
            self.recent_len = @min(self.recent_len + 1, recent_capacity);
        }

        fn deinit(self: *ServedConn, allocator: std.mem.Allocator) void {
            for (self.pending.items) |*pr| pr.release(allocator, self.conn);
            self.pending.deinit(allocator);
        }
    };

    /// One request stream whose line is still arriving.
    pub const PendingRequest = struct {
        stream: *quic.QuicStream,
        line: std.ArrayListUnmanaged(u8) = .empty,
        since_ns: u64,

        fn release(self: *PendingRequest, allocator: std.mem.Allocator, conn: *quic.QuicConnection) void {
            self.stream.close();
            conn.destroyStream(self.stream);
            self.line.deinit(allocator);
        }
    };

    /// Where the TLS listener finds its certificate, and whether it may
    /// self-sign a missing one (SONNY-2394 review: tests use a private pair
    /// per server instead of racing on a shared ./certs).
    pub const StartOptions = struct {
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
        cert_auto_generate: quic.CertAutoGenerate = .dev_only,
    };

    /// Longest request line accepted; a longer one is answered with
    /// `RequestTooLarge` and the stream is closed.
    pub const max_request_bytes: usize = 4096;
    /// A request whose line has not completed within this window is dropped.
    pub const request_assembly_timeout_ns: u64 = 30 * std.time.ns_per_s;
    /// New request streams admitted per connection per cycle (fairness).
    const max_new_streams_per_cycle: usize = 8;

    pub fn init(allocator: std.mem.Allocator, seed: u64) !RemoteKmsServer {
        return .{ .allocator = allocator, .server = try Server.init(allocator, seed) };
    }

    /// Clean shutdown. Stop any serving thread (`serveUntilStopped`) BEFORE
    /// calling this: the connection list is owned by that thread.
    pub fn deinit(self: *RemoteKmsServer) void {
        if (self.quic_transport) |qt| {
            for (self.conns.items) |*sc| {
                sc.deinit(self.allocator);
                qt.destroyConnection(sc.conn);
            }
            self.conns.clearRetainingCapacity();
            qt.deinit();
            self.allocator.destroy(qt);
            self.quic_transport = null;
        }
        self.conns.deinit(self.allocator);
        self.server.deinit();
    }

    pub fn start(self: *RemoteKmsServer, port: u16) !void {
        return self.startWithOptions(port, .{});
    }

    pub fn startWithOptions(self: *RemoteKmsServer, port: u16, options: StartOptions) !void {
        self.port = port;

        // Initialize the transport in place: listen() records `self` in a
        // process-wide pointer (the connection-count gauge), so it must not
        // run on a stack copy that is moved to the heap afterwards.
        const qt = try self.allocator.create(quic.QuicTransport);
        errdefer self.allocator.destroy(qt);
        // GAP-0105 SECURITY FIX: Use secure TLS by default for KMS transport
        // Initialize QUIC transport with certificate validation enabled
        qt.* = try quic.QuicTransport.init(self.allocator, .{
            .port = port,
            .address = "0.0.0.0",
            .allow_insecure = false, // Security: require valid TLS certificates
            .cert_path = options.cert_path,
            .key_path = options.key_path,
            .cert_auto_generate = options.cert_auto_generate,
        });
        errdefer qt.deinit();

        try qt.listen();
        self.quic_transport = qt;
        // SONNY-6332: `port` 0 asks the kernel for a free port; `self.port`
        // is the one the socket is bound to.
        self.port = qt.boundPort();

        std.debug.print("KMS_SERVER: Listening on port {d}\n", .{self.port});
    }

    /// One serving cycle (SONNY-2394 multi-connection): poll the transport,
    /// accept EVERY pending connection, then advance each connection's
    /// requests without blocking -- admit newly announced streams, read
    /// whatever bytes have arrived, and answer every request whose line is
    /// complete. Connections that have drained (client closed) are released.
    /// Returns true when at least one request was answered.
    pub fn serveOnce(self: *RemoteKmsServer) !bool {
        const qt = self.quic_transport orelse return error.NotStarted;

        // Poll for events
        try qt.poll(100);

        // Accept loop: every connection that completed its handshake.
        while (qt.tryAccept()) |conn| {
            self.conns.append(self.allocator, .{ .conn = conn }) catch |err| {
                qt.destroyConnection(conn);
                return err;
            };
            std.debug.print("KMS_SERVER: Accepted connection ({d} open)\n", .{self.conns.items.len});
        }

        // Per-connection handling. GAP-0514 P3: connections persist across
        // requests (one QUIC stream per request).
        var served = false;
        var i: usize = 0;
        while (i < self.conns.items.len) {
            const sc = &self.conns.items[i];
            if (sc.conn.isDrained()) {
                sc.deinit(self.allocator);
                qt.destroyConnection(sc.conn);
                _ = self.conns.swapRemove(i);
                continue;
            }
            self.admitStreams(sc);
            var j: usize = 0;
            while (j < sc.pending.items.len) {
                const pr = &sc.pending.items[j];
                const outcome = self.advance(sc.conn, pr);
                if (outcome == .waiting) {
                    j += 1;
                    continue;
                }
                if (outcome == .answered) served = true;
                pr.release(self.allocator, sc.conn);
                _ = sc.pending.swapRemove(j);
            }
            i += 1;
        }
        return served;
    }

    /// Admit newly announced request streams on `sc`. A repeat announcement of
    /// a known stream id is released unread (its bytes are read through the
    /// stream's one pending entry).
    fn admitStreams(self: *RemoteKmsServer, sc: *ServedConn) void {
        var admitted: usize = 0;
        while (admitted < max_new_streams_per_cycle) {
            const stream = sc.conn.tryAcceptStream() orelse return;
            if (sc.seen(stream.stream_id)) {
                self.stats.stale_notifications += 1;
                sc.conn.destroyStream(stream);
                continue;
            }
            sc.remember(stream.stream_id);
            sc.pending.append(self.allocator, .{ .stream = stream, .since_ns = monoNs() }) catch {
                stream.close();
                sc.conn.destroyStream(stream);
                continue;
            };
            admitted += 1;
        }
    }

    const Advance = enum { waiting, answered, dropped };

    /// Read whatever has arrived on `pr`'s stream without blocking; answer
    /// the request once its line is complete.
    fn advance(self: *RemoteKmsServer, conn: *quic.QuicConnection, pr: *PendingRequest) Advance {
        var chunk: [512]u8 = undefined;
        while (std.mem.indexOfScalar(u8, pr.line.items, '\n') == null) {
            const n = pr.stream.read(&chunk) catch |err| switch (err) {
                error.WouldBlock => {
                    if (monoNs() -| pr.since_ns > request_assembly_timeout_ns) {
                        std.debug.print("KMS_SERVER: dropping a request whose line never completed\n", .{});
                        return .dropped;
                    }
                    return .waiting;
                },
                else => {
                    std.debug.print("KMS_SERVER: Failed to read request: {}\n", .{err});
                    return .dropped;
                },
            };
            // FIN before a complete line: the client abandoned the request.
            if (n == 0) return .dropped;
            if (pr.line.items.len + n > max_request_bytes) {
                // error-policy: A -- best-effort reply to an oversized request.
                pr.stream.writeAll("{\"status\":\"ERR\",\"code\":\"RequestTooLarge\"}\n") catch {};
                return .dropped;
            }
            pr.line.appendSlice(self.allocator, chunk[0..n]) catch return .dropped;
        }
        const end = std.mem.indexOfScalar(u8, pr.line.items, '\n').?;
        self.answer(conn, pr.stream, pr.line.items[0 .. end + 1]);
        return .answered;
    }

    /// Answer one complete request line on `stream` of `conn`.
    fn answer(self: *RemoteKmsServer, conn: *quic.QuicConnection, stream: *quic.QuicStream, request: []const u8) void {
        self.stats.requests_served += 1;
        std.debug.print("KMS_SERVER: Received request: {s}\n", .{request});

        // Process request and generate response
        var response_buf: [4096]u8 = undefined;
        const response = self.processRequest(conn, request, &response_buf) catch |err| {
            std.debug.print("KMS_SERVER: Failed to process request: {}\n", .{err});
            const err_response = "{\"status\":\"ERR\",\"code\":\"InternalError\"}\n";
            // error-policy: A — best-effort error reply on an already-logged
            // failure; if the peer is gone there is nothing further to do.
            stream.writeAll(err_response) catch {};
            return;
        };

        // Send response
        stream.writeAll(response) catch |err| {
            std.debug.print("KMS_SERVER: Failed to send response: {}\n", .{err});
        };
    }

    /// Consecutive serving failures after which `serveUntilStopped` gives up.
    pub const max_consecutive_serve_failures: u32 = 50;

    /// Back-off before the next serving cycle after `failures` consecutive
    /// failed cycles: 10 ms doubling to a 1 s cap.
    pub fn serveFailureBackoffMs(failures: u32) i64 {
        const shift: u6 = @intCast(@min(failures -| 1, 7));
        return @min(@as(i64, 10) << shift, 1000);
    }

    /// Serving-thread body (SONNY-2394): run serving cycles until `stop` is
    /// set. Pair with deinit(): set `stop`, join the thread, then deinit.
    /// Review: a server that cannot serve no longer spins -- one that was
    /// never started returns at once, a failing cycle backs off, and
    /// `max_consecutive_serve_failures` in a row end the loop.
    pub fn serveUntilStopped(self: *RemoteKmsServer, stop: *const std.atomic.Value(bool)) void {
        var failures: u32 = 0;
        while (!stop.load(.acquire)) {
            if (self.serveOnce()) |_| {
                failures = 0;
            } else |err| {
                if (err == error.NotStarted) return;
                failures += 1;
                std.debug.print("KMS_SERVER: serveOnce error: {} ({d} in a row)\n", .{ err, failures });
                if (failures >= max_consecutive_serve_failures) {
                    std.debug.print("KMS_SERVER: giving up after {d} consecutive serving failures\n", .{failures});
                    return;
                }
                // Back off in short slices so `stop` is still honoured promptly.
                var left = serveFailureBackoffMs(failures);
                while (left > 0 and !stop.load(.acquire)) : (left -= 10) sleepMs(@min(left, 10));
            }
        }
    }

    fn processRequest(self: *RemoteKmsServer, conn: *quic.QuicConnection, request: []const u8, response_buf: []u8) ![]const u8 {
        // Parse operation type
        const op = jsonFind(request, "\"op\":\"") orelse return error.InvalidRequest;
        const op_start = op + 6;
        const op_end = std.mem.indexOfPos(u8, request, op_start, "\"") orelse return error.InvalidRequest;
        const operation = request[op_start..op_end];

        // Check authentication
        if (self.server.auth_token) |expected_token| {
            const auth = jsonFind(request, "\"auth\":\"");
            if (auth == null) {
                return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"AuthenticationFailed\"}}\n", .{});
            }
            const auth_start = auth.? + 8;
            const auth_end = std.mem.indexOfPos(u8, request, auth_start, "\"") orelse return error.InvalidRequest;
            const provided_token = request[auth_start..auth_end];
            if (!timingSafeEql(provided_token, expected_token)) {
                return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"AuthenticationFailed\"}}\n", .{});
            }
        }

        // Handle operations
        if (std.mem.eql(u8, operation, "Generate")) {
            return self.handleGenerate(response_buf);
        } else if (std.mem.eql(u8, operation, "Unwrap")) {
            return self.handleUnwrap(request, response_buf);
        } else if (std.mem.eql(u8, operation, "PrivUnwrap")) {
            return self.handlePrivUnwrap(request, response_buf);
        } else if (std.mem.eql(u8, operation, "Attest")) {
            return self.handleAttest(conn, request, response_buf);
        } else {
            return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"InvalidOperation\"}}\n", .{});
        }
    }

    fn handleGenerate(self: *RemoteKmsServer, response_buf: []u8) ![]const u8 {
        // Generate a new data key and wrap it
        var plaintext: [32]u8 = undefined;
        try cb.Csprng.bytes(&plaintext);

        const envelope = try self.server.wrap(plaintext);

        // Build response
        var fbs_writer: std.Io.Writer = .fixed(response_buf);
        const writer = &fbs_writer;

        try writer.writeAll("{\"status\":\"OK\",\"envelope\":");
        try envelopeToJson(envelope, writer);
        try writer.writeAll("}\n");

        return fbs_writer.buffered();
    }

    fn handleUnwrap(self: *RemoteKmsServer, request: []const u8, response_buf: []u8) ![]const u8 {
        // Parse envelope from request
        const env_idx = jsonFind(request, "\"envelope\":") orelse return error.InvalidRequest;
        const env_start = std.mem.indexOfPos(u8, request, env_idx, "{") orelse return error.InvalidRequest;
        const env_end = std.mem.indexOfPos(u8, request, env_start, "}") orelse return error.InvalidRequest;
        const env_json = request[env_start .. env_end + 1];

        const envelope = try parseEnvelope(env_json);
        const plaintext = try self.server.unwrap(envelope);

        // Build response with hex-encoded plaintext
        var fbs_writer: std.Io.Writer = .fixed(response_buf);
        const writer = &fbs_writer;

        try writer.writeAll("{\"status\":\"OK\",\"plaintext\":\"");
        for (plaintext) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\"}\n");

        return fbs_writer.buffered();
    }

    fn handlePrivUnwrap(self: *RemoteKmsServer, request: []const u8, response_buf: []u8) ![]const u8 {
        // Privileged unwrap - same as regular unwrap but may include attestation
        return self.handleUnwrap(request, response_buf);
    }

    fn handleAttest(self: *RemoteKmsServer, conn: *quic.QuicConnection, request: []const u8, response_buf: []u8) ![]const u8 {
        // SONNY-6435: sign only over the client's fresh nonce; without one
        // the signature would be replayable.
        var nonce: [32]u8 = undefined;
        hexFieldAfter(request, "\"nonce\":\"", &nonce) catch {
            return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"AttestNonceRequired\"}}\n", .{});
        };
        var kp = self.server.attest_keypair orelse return error.NotConfigured;
        // SONNY-6442: and over the TLS channel the request arrived on.
        var binding: [32]u8 = undefined;
        conn.exportKeyingMaterial(attest_exporter_label, &binding) catch {
            return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"ChannelBindingUnavailable\"}}\n", .{});
        };

        const msg = attestationMessage(nonce, self.server.attestation_hash, binding);

        var sig_buf: [64]u8 = undefined;
        _ = try cb.Sig.sign(.ed25519, &kp, &msg, &sig_buf);

        var pub_buf: [32]u8 = undefined;
        _ = try kp.publicBytes(&pub_buf);

        // Build response
        var fbs_writer: std.Io.Writer = .fixed(response_buf);
        const writer = &fbs_writer;

        try writer.writeAll("{\"status\":\"OK\",\"hash\":\"");
        for (self.server.attestation_hash) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\",\"pub\":\"");
        for (pub_buf) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\",\"sig\":\"");
        for (sig_buf) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\",\"nonce\":\"");
        for (nonce) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\"}\n");

        return fbs_writer.buffered();
    }

    pub fn serveLoop(self: *RemoteKmsServer, iterations: usize) !void {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = self.serveOnce() catch |err| {
                if (err != error.NotStarted) {
                    std.debug.print("KMS_SERVER: serveOnce error: {}\n", .{err});
                }
                continue;
            };
        }
    }

    /// GAP-0514 P3: serve until `want` requests have been processed or
    /// `max_iterations` idle/serve cycles elapse. Replaces fixed-iteration
    /// serveLoop in tests, where a slow TLS handshake could exhaust the
    /// serve window before the first request arrived (flaky timeout).
    pub fn serveUntil(self: *RemoteKmsServer, want: usize, max_iterations: usize) !void {
        var served: usize = 0;
        var i: usize = 0;
        while (i < max_iterations and served < want) : (i += 1) {
            const did = self.serveOnce() catch |err| blk: {
                if (err != error.NotStarted) {
                    std.debug.print("KMS_SERVER: serveOnce error: {}\n", .{err});
                }
                break :blk false;
            };
            if (did) served += 1;
        }
    }
};

// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=NETWORK; STATUS=TESTED; TEST=geodetestlab/specs/external_kms_integration.yml; OWNER=security; UPDATED=2026-01-09
pub const RemoteKmsClient = struct {
    allocator: std.mem.Allocator,
    quic_client: ?quic.QuicClient = null,
    auth_token: ?[]const u8 = null,
    connected: bool = false,
    /// Wall-clock bound, in milliseconds, on waiting for the response to one
    /// request (SONNY-2394; see `sendRequest`).
    response_timeout_ms: u32 = default_response_timeout_ms,
    /// Wall-clock bound on establishing the QUIC/TLS connection. The server
    /// handles concurrent handshakes serially, before it can serve requests.
    handshake_timeout_secs: u32 = default_handshake_timeout_secs,
    /// The server attestation public key this client trusts (SONNY-6435).
    /// The trust anchor: `attest` refuses without one, and accepts only a
    /// signature by this key over its own fresh nonce.
    pinned_attestation_key: ?[32]u8 = null,
    /// PEM CA bundle that verifies the KMS server's certificate (SONNY-6442).
    /// The TLS trust anchor: `connect` refuses without one. Not owned.
    ca_cert_path: ?[]const u8 = null,

    /// Generous on purpose: a live server answers as soon as its serving loop
    /// reaches the request, and that loop can legitimately be busy for
    /// seconds -- e.g. completing a burst of concurrent TLS handshakes, which
    /// its endpoint poll processes one after another (~120 ms each on a
    /// starved CPU). A closed connection is detected separately and fails fast.
    pub const default_response_timeout_ms: u32 = 30_000;
    pub const default_handshake_timeout_secs: u32 = 30;

    pub fn init(allocator: std.mem.Allocator) RemoteKmsClient {
        return .{ .allocator = allocator, .quic_client = null, .connected = false };
    }

    pub const Options = struct {
        /// See `response_timeout_ms`.
        response_timeout_ms: u32 = default_response_timeout_ms,
        /// See `handshake_timeout_secs`.
        handshake_timeout_secs: u32 = default_handshake_timeout_secs,
        /// See `pinned_attestation_key`.
        attestation_public_key: ?[32]u8 = null,
        /// See `ca_cert_path`.
        ca_cert_path: ?[]const u8 = null,
    };

    /// `init` with explicit options (SONNY-2394 review: the configuration
    /// route production callers use for the response deadline, e.g.
    /// `KMSConfig.remote_response_timeout_ms`).
    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) RemoteKmsClient {
        var client = init(allocator);
        client.response_timeout_ms = options.response_timeout_ms;
        client.handshake_timeout_secs = options.handshake_timeout_secs;
        client.pinned_attestation_key = options.attestation_public_key;
        client.ca_cert_path = options.ca_cert_path;
        return client;
    }

    /// Trust attestations signed by `public_key` (and only those).
    pub fn pinAttestationKey(self: *RemoteKmsClient, public_key: [32]u8) void {
        self.pinned_attestation_key = public_key;
    }

    pub fn deinit(self: *RemoteKmsClient) void {
        if (self.quic_client) |*client| {
            client.deinit();
        }
        self.quic_client = null;
        self.connected = false;
    }

    /// Connect to the KMS server at `host:port` over QUIC/TLS, verifying its
    /// certificate chain against `ca_cert_path` and its name against `host`
    /// (SONNY-6442). Fails closed: no CA bundle (error.KmsTrustAnchorMissing),
    /// a bundle that cannot be loaded, or a server it does not verify is an
    /// error, and the client stays unconnected. There is no unverified mode.
    pub fn connect(self: *RemoteKmsClient, host: []const u8, port: u16) !void {
        const ca = self.ca_cert_path orelse return error.KmsTrustAnchorMissing;
        self.deinit();
        // In place: the QUIC config points into the QuicClient.
        self.quic_client = quic.QuicClient.init(self.allocator);
        errdefer self.deinit();
        try self.quic_client.?.connectWithCa(host, port, ca);
        try self.quic_client.?.waitForHandshake(self.handshake_timeout_secs);
        self.connected = true;
    }

    /// The TLS exporter value of this client's channel that the server
    /// signs into an attestation (`attest_exporter_label`).
    pub fn channelBinding(self: *RemoteKmsClient) ![32]u8 {
        if (!self.connected or self.quic_client == null) return error.NotConnected;
        var out: [32]u8 = undefined;
        try self.quic_client.?.exportKeyingMaterial(attest_exporter_label, &out);
        return out;
    }

    pub fn setAuthToken(self: *RemoteKmsClient, tok: []const u8) void {
        self.auth_token = tok;
    }

    fn authPrefix(self: *RemoteKmsClient) []const u8 {
        return if (self.auth_token) |t| t else "";
    }

    /// Send a JSON request over QUIC and read the JSON response line.
    ///
    /// SONNY-2394: the wait is bounded by WALL-CLOCK time
    /// (`response_timeout_ms`), not by a retry count. The old bound -- 100 x
    /// (poll(50) + 10 ms sleep) -- was nominally ~6 s but shrank to ~1.5 s
    /// whenever the connection had timer/ACK activity, so a live server busy
    /// for a couple of seconds (16 concurrent handshakes on a loaded host) saw
    /// 15 of its 16 clients give up just before it answered them. A connection
    /// the server has closed fails fast with error.ConnectionClosed.
    fn sendRequest(self: *RemoteKmsClient, request: []const u8) ![]u8 {
        if (!self.connected or self.quic_client == null) {
            return error.NotConnected;
        }
        const client = &self.quic_client.?;

        // Open a stream for this request
        var stream = try client.getStream();
        defer stream.close();

        // Write the request (must end with newline)
        try stream.writeAll(request);

        // Poll and read the response until the deadline.
        const deadline_ns = monoNs() + @as(u64, self.response_timeout_ms) * std.time.ns_per_ms;
        while (true) {
            try client.poll(50);
            const response = stream.readLine(8192) catch |err| {
                if (err != error.WouldBlock) return err;
                if (client.isClosed()) return error.ConnectionClosed;
                if (monoNs() >= deadline_ns) return error.Timeout;
                sleepMs(10);
                continue;
            };
            return response;
        }
    }

    /// Ask the server for a new data key, wrapped under its KEK. Fails with
    /// error.NotConnected when not connected: there is no local stand-in
    /// (SONNY-6442; it was a KEK derived from a fixed public seed).
    pub fn generate(self: *RemoteKmsClient) !Envelope {
        if (!self.connected) return error.NotConnected;
        // Build JSON request
        var request_buf: [256]u8 = undefined;
        var fbs_writer: std.Io.Writer = .fixed(&request_buf);
        const writer = &fbs_writer;

        if (self.auth_token) |tok| {
            try writer.print("{{\"op\":\"Generate\",\"auth\":\"{s}\"}}\n", .{tok});
        } else {
            try writer.writeAll("{\"op\":\"Generate\"}\n");
        }

        const request = fbs_writer.buffered();

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parseEnvelopeResponse(response);
    }

    /// Unwrap `env` on the server. error.NotConnected when not connected
    /// (no local stand-in, SONNY-6442).
    pub fn unwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        if (!self.connected) return error.NotConnected;
        // Build JSON request with envelope
        var request_buf: [1024]u8 = undefined;
        var fbs_writer: std.Io.Writer = .fixed(&request_buf);
        const writer = &fbs_writer;

        try writer.writeAll("{\"op\":\"Unwrap\"");
        if (self.auth_token) |tok| {
            try writer.print(",\"auth\":\"{s}\"", .{tok});
        }
        try writer.writeAll(",\"envelope\":");
        try envelopeToJson(env, writer);
        try writer.writeAll("}\n");

        const request = fbs_writer.buffered();

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parsePlaintextResponse(response);
    }

    /// Privileged unwrap of `env` on the server. error.NotConnected when not
    /// connected (SONNY-6442).
    pub fn privUnwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        if (!self.connected) return error.NotConnected;
        // Build JSON request with PrivUnwrap operation
        var request_buf: [1024]u8 = undefined;
        var fbs_writer: std.Io.Writer = .fixed(&request_buf);
        const writer = &fbs_writer;

        try writer.writeAll("{\"op\":\"PrivUnwrap\"");
        if (self.auth_token) |tok| {
            try writer.print(",\"auth\":\"{s}\"", .{tok});
        }
        try writer.writeAll(",\"envelope\":");
        try envelopeToJson(env, writer);
        try writer.writeAll("}\n");

        const request = fbs_writer.buffered();

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parsePlaintextResponse(response);
    }

    /// Ask the server to attest, and return the attested hash (the server's
    /// KEK identifier, `kekIdentifier`) only if the reply is signed by the
    /// pinned key over this call's fresh nonce (SONNY-6435) and this
    /// client's TLS channel binding (SONNY-6442). Fails closed: no pinned
    /// key, no connection (there is no local stand-in), another key, a bad
    /// signature, another nonce or another channel is an error.
    pub fn attest(self: *RemoteKmsClient) ![32]u8 {
        const pinned = self.pinned_attestation_key orelse return error.AttestationTrustAnchorMissing;
        if (!self.connected) return error.NotConnected;
        const binding = try self.channelBinding();

        var nonce: [32]u8 = undefined;
        try cb.Csprng.bytes(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);

        var request_buf: [512]u8 = undefined;
        var fbs_writer: std.Io.Writer = .fixed(&request_buf);
        const writer = &fbs_writer;
        try writer.writeAll("{\"op\":\"Attest\"");
        if (self.auth_token) |tok| {
            try writer.print(",\"auth\":\"{s}\"", .{tok});
        }
        try writer.print(",\"nonce\":\"{s}\"}}\n", .{&nonce_hex});

        const response = try self.sendRequest(fbs_writer.buffered());
        defer self.allocator.free(response);

        return verifyAttestResponse(response, pinned, nonce, binding);
    }

    /// Check an Attest reply against the pinned key, the nonce the client
    /// sent and the client's own channel binding, and return the attested
    /// hash. The signature is verified under the PINNED key over the
    /// client's OWN nonce and channel binding, whatever the reply claims.
    pub fn verifyAttestResponse(response: []const u8, pinned: [32]u8, nonce: [32]u8, channel_binding: [32]u8) ![32]u8 {
        if (std.mem.indexOf(u8, response, "\"hash\":\"") == null) {
            if (std.mem.indexOf(u8, response, "\"ERR\"") != null) {
                return remoteError(response);
            }
            return error.InvalidResponse;
        }
        var hash: [32]u8 = undefined;
        var presented: [32]u8 = undefined;
        var sig: [64]u8 = undefined;
        var echoed: [32]u8 = undefined;
        try hexFieldAfter(response, "\"hash\":\"", &hash);
        try hexFieldAfter(response, "\"pub\":\"", &presented);
        try hexFieldAfter(response, "\"sig\":\"", &sig);
        try hexFieldAfter(response, "\"nonce\":\"", &echoed);
        if (!timingSafeEql(&presented, &pinned)) return error.AttestationKeyMismatch;
        if (!timingSafeEql(&echoed, &nonce)) return error.AttestationNonceMismatch;
        if (!verifyAttestation(pinned, nonce, hash, channel_binding, sig)) return error.AttestationSignatureInvalid;
        return hash;
    }

    /// Map an `{"status":"ERR","code":...}` reply to a typed error. SONNY-2394:
    /// the server reports auth failures as `"code":"AuthenticationFailed"`
    /// (the documented protocol above), but every ERR used to collapse into
    /// the generic `error.RemoteError`, so callers could not tell a rejected
    /// credential from any other remote failure.
    fn remoteError(response: []const u8) error{ AuthenticationFailed, RemoteError } {
        if (std.mem.indexOf(u8, response, "\"code\":\"AuthenticationFailed\"") != null) {
            return error.AuthenticationFailed;
        }
        return error.RemoteError;
    }

    /// Parse envelope from JSON response like {"status":"OK","envelope":{...}}
    fn parseEnvelopeResponse(response: []const u8) !Envelope {
        // Simple JSON parsing - look for envelope field
        const envelope_start = std.mem.indexOf(u8, response, "\"envelope\":");
        if (envelope_start == null) {
            // Check for error status
            if (std.mem.indexOf(u8, response, "\"ERR\"") != null) {
                return remoteError(response);
            }
            return error.InvalidResponse;
        }

        // Parse the envelope object within the response
        return try parseEnvelopeFromJson(response[envelope_start.? + 11 ..]);
    }

    /// Parse plaintext from JSON response like {"status":"OK","plaintext":"..."}
    fn parsePlaintextResponse(response: []const u8) ![32]u8 {
        // Look for plaintext field
        const pt_start = std.mem.indexOf(u8, response, "\"plaintext\":\"");
        if (pt_start == null) {
            if (std.mem.indexOf(u8, response, "\"ERR\"") != null) {
                return remoteError(response);
            }
            return error.InvalidResponse;
        }

        // Extract hex string
        const hex_start = pt_start.? + 13;
        const hex_end = std.mem.indexOfPos(u8, response, hex_start, "\"");
        if (hex_end == null or hex_end.? - hex_start != 64) {
            return error.InvalidResponse;
        }

        var result: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&result, response[hex_start..hex_end.?]) catch return error.InvalidResponse;
        return result;
    }

    /// Parse envelope JSON object
    fn parseEnvelopeFromJson(json: []const u8) !Envelope {
        var env = Envelope{
            .nonce = undefined,
            .tag = undefined,
            .ct = undefined,
        };

        // Parse nonce
        if (std.mem.indexOf(u8, json, "\"nonce\":\"")) |nonce_start| {
            const hex_start = nonce_start + 9;
            if (hex_start + 24 <= json.len) {
                _ = std.fmt.hexToBytes(&env.nonce, json[hex_start .. hex_start + 24]) catch return error.InvalidResponse;
            }
        } else {
            return error.InvalidResponse;
        }

        // Parse tag
        if (std.mem.indexOf(u8, json, "\"tag\":\"")) |tag_start| {
            const hex_start = tag_start + 7;
            if (hex_start + 32 <= json.len) {
                _ = std.fmt.hexToBytes(&env.tag, json[hex_start .. hex_start + 32]) catch return error.InvalidResponse;
            }
        } else {
            return error.InvalidResponse;
        }

        // Parse ct (ciphertext)
        if (std.mem.indexOf(u8, json, "\"ct\":\"")) |ct_start| {
            const hex_start = ct_start + 6;
            if (hex_start + 64 <= json.len) {
                _ = std.fmt.hexToBytes(&env.ct, json[hex_start .. hex_start + 64]) catch return error.InvalidResponse;
            }
        } else {
            return error.InvalidResponse;
        }

        return env;
    }

    /// True iff `sig` is `pub_key`'s Ed25519 signature over
    /// `attestationMessage(nonce, hash, channel_binding)`. Callers pass the
    /// PINNED key, their OWN nonce and their OWN channel binding, never
    /// values taken from the reply (SONNY-6435, SONNY-6442).
    pub fn verifyAttestation(pub_key: [32]u8, nonce: [32]u8, hash: [32]u8, channel_binding: [32]u8, sig: [64]u8) bool {
        const msg = attestationMessage(nonce, hash, channel_binding);
        var kp = cb.Sig.KeyPair.fromPublicBytes(.ed25519, &pub_key) catch return false;
        defer kp.deinit();
        cb.Sig.verify(.ed25519, &kp, &msg, &sig) catch return false;
        return true;
    }
};

// (Tests moved to tests/canary_remote_kms.zig)
