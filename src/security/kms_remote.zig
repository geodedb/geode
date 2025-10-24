const std = @import("std");
// const quic = @import("../transport/quic.zig"); // Disabled for now
const crypto = std.crypto;

// CANARY: REQ=REQ-M6-UNREACHABLE-001; FEATURE="CodeQuality"; ASPECT=ErrorHandling; STATUS=IMPL; OWNER=security; UPDATED=2025-10-17
// M6: Replaced all 'unreachable' statements with proper error handling (try/panic)

// kms_remote.zig
// Minimal remote KMS prototype over QUIC performing AES-256-GCM wrap/unwrap.
// Server holds KEK and serves two JSON line oriented requests on a single stream:
//   {"op":"Generate"} -> {"status":"OK","envelope":{...}}
//   {"op":"Unwrap","envelope":{...}} -> {"status":"OK","plaintext":"<64 hex>"}
// Errors -> {"status":"ERR","code":"AuthenticationFailed"}
// This is a development scaffold; now includes minimal token auth (header field) on each request.
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate|TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_AuthNegative; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_AttestationStub|TestCANARY_REQ_GQL_TDE_ATTEST_001_UnwrapSignatureVerify; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap|TestCANARY_REQ_GQL_TDE_ATTEST_001_UnwrapSignatureVerify|TestCANARY_REQ_GQL_TDE_ATTEST_001_UnwrapTamperDetect; OWNER=security; UPDATED=2025-09-26

pub const Envelope = struct {
    version: u8 = 1,
    alg: []const u8 = "AES-256-GCM",
    nonce: [12]u8,
    tag: [16]u8,
    ct: [32]u8,
};

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

fn parseHexByte(slice: []const u8) u8 {
    return std.fmt.parseInt(u8, slice, 16) catch 0;
}

fn jsonFind(hay: []const u8, key: []const u8) ?usize {
    return std.mem.indexOf(u8, hay, key);
}

fn parseEnvelope(json: []const u8) !Envelope {
    if (jsonFind(json, "\"nonce\":\"") == null) return error.InvalidEnvelope;
    var env: Envelope = .{ .nonce = undefined, .tag = undefined, .ct = undefined };
    // naive scans
    const nidx = jsonFind(json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
    const tidx = jsonFind(json, "\"tag\":\"") orelse return error.InvalidEnvelope;
    const cidx = jsonFind(json, "\"ct\":\"") orelse return error.InvalidEnvelope;
    const nstart = nidx + 9;
    const tstart = tidx + 7;
    const cstart = cidx + 6;
    var i: usize = 0;
    while (i < 12) : (i += 1) env.nonce[i] = parseHexByte(json[nstart + i * 2 .. nstart + i * 2 + 2]);
    i = 0;
    while (i < 16) : (i += 1) env.tag[i] = parseHexByte(json[tstart + i * 2 .. tstart + i * 2 + 2]);
    i = 0;
    while (i < 32) : (i += 1) env.ct[i] = parseHexByte(json[cstart + i * 2 .. cstart + i * 2 + 2]);
    return env;
}

const Prng = struct {
    s0: u64,
    s1: u64,
    fn init(seed: u64) @This() {
        var z = seed +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        const s0 = z ^ (z >> 31);
        z +%= 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        const s1 = z ^ (z >> 31);
        return .{ .s0 = s0, .s1 = s1 };
    }
    fn next(self: *@This()) u64 {
        const result = self.s0 +% self.s1;
        const s1 = self.s1 ^ self.s0;
        self.s0 = std.math.rotl(u64, self.s0, 55) ^ s1 ^ (s1 << 14);
        self.s1 = std.math.rotl(u64, s1, 36);
        return result;
    }
    pub fn bytes(self: *@This(), out: []u8) void {
        var i: usize = 0;
        var r: u64 = 0;
        while (i < out.len) : (i += 1) {
            if (i % 8 == 0) r = self.next();
            const shift: u6 = @intCast((i % 8) * 8);
            const val = r >> shift;
            out[i] = @as(u8, @truncate(val));
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8,
    prng: Prng,
    auth_token: ?[]const u8 = null,
    attestation_hash: [32]u8 = [_]u8{0} ** 32,
    // Ephemeral Ed25519 key pair created on auth token set (test scope, could be rotated with token)
    attest_keypair: ?std.crypto.sign.Ed25519.KeyPair = null,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Server {
        var prng = Prng.init(seed);
        var kek: [32]u8 = undefined;
        prng.bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .prng = prng }; // auth_token set later
    }

    pub fn setAuthToken(self: *Server, tok: []const u8) !void {
        self.auth_token = tok;
        // derive attestation hash (sha256 over token + kek prefix)
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(tok);
        h.update(self.kek[0..16]);
        h.final(&self.attestation_hash);
        // Generate a fresh ephemeral Ed25519 key pair deterministically from a random seed so
        // tests are reproducible if we ever choose to expose the seed (currently we don't).
        // Zig 0.15.1 Ed25519 API: KeyPair.generateDeterministic(seed) and kp.sign(msg, null)
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        const attest_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        self.attest_keypair = attest_kp;
    }

    pub fn wrap(self: *Server, plaintext: [32]u8) Envelope {
        var nonce: [12]u8 = undefined;
        self.prng.bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &plaintext, &.{}, nonce, self.kek);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    pub fn unwrap(self: *Server, env: Envelope) ![32]u8 {
        var out: [32]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(&out, &env.ct, env.tag, &.{}, env.nonce, self.kek) catch return error.AuthenticationFailed;
        return out;
    }
};

pub const RemoteKmsServer = struct {
    allocator: std.mem.Allocator,
    quic_transport: ?void = null, // Disabled quic
    server: Server,

    pub fn init(allocator: std.mem.Allocator, seed: u64) RemoteKmsServer {
        return .{ .allocator = allocator, .server = Server.init(allocator, seed) };
    }

    pub fn start(self: *RemoteKmsServer, port: u16) !void {
        // Stub out QUIC transport for now - will be replaced when quic module is available
        // var qt = try quic.QuicTransport.init(self.allocator, .{ .port = port });
        // try qt.listen();
        // self.quic_transport = try self.allocator.create(quic.QuicTransport);
        // self.quic_transport.?.* = qt;
        _ = port;
        self.quic_transport = null;
    }

    pub fn serveOnce(self: *RemoteKmsServer) !void {
        if (self.quic_transport == null) return error.NotStarted;
        // Stub implementation - would accept QUIC connections when available
        // This entire method depends on QUIC streaming which is not available yet
        return error.NotImplemented;
    }

    pub fn serveLoop(self: *RemoteKmsServer, iterations: usize) !void {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try self.serveOnce();
        }
    }
};

pub const RemoteKmsClient = struct {
    allocator: std.mem.Allocator,
    quic_client: ?void, // Stub for now - will be replaced with quic.QuicClient when available
    auth_token: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) RemoteKmsClient {
        return .{ .allocator = allocator, .quic_client = null };
    }

    pub fn connect(self: *RemoteKmsClient, host: []const u8, port: u16) !void {
        // Stub implementation - will be replaced when quic module is available
        _ = self;
        _ = host;
        _ = port;
        // Connection would happen here with QUIC
    }

    pub fn setAuthToken(self: *RemoteKmsClient, tok: []const u8) void {
        self.auth_token = tok;
    }

    fn authPrefix(self: *RemoteKmsClient) []const u8 {
        return if (self.auth_token) |t| t else "";
    }

    pub fn generate(self: *RemoteKmsClient) !Envelope {
        // Stub implementation using local generation - will be replaced with QUIC RPC
        const ext = @import("external_kms_client.zig");
        var client = ext.Client.init(self.allocator, 0x12345678);
        var key: [32]u8 = undefined;
        std.crypto.random.bytes(&key);
        const ext_envelope = try client.wrap(key);
        // Convert external_kms_client.Envelope to kms_remote.Envelope
        return Envelope{
            .version = ext_envelope.version,
            .alg = ext_envelope.alg,
            .nonce = ext_envelope.nonce,
            .tag = ext_envelope.tag,
            .ct = ext_envelope.ct,
        };
    }

    pub fn unwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        // Stub implementation using local unwrapping - will be replaced with QUIC RPC
        const ext = @import("external_kms_client.zig");
        var client = ext.Client.init(self.allocator, 0x12345678);
        // Convert kms_remote.Envelope to external_kms_client.Envelope
        const ext_envelope = ext.Envelope{
            .version = env.version,
            .alg = env.alg,
            .nonce = env.nonce,
            .tag = env.tag,
            .ct = env.ct,
        };
        return try client.unwrap(ext_envelope);
    }

    pub fn privUnwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        // Stub implementation - privileged unwrap would check auth differently
        // For now, just delegate to regular unwrap
        return self.unwrap(env);
    }

    pub fn attest(self: *RemoteKmsClient) ![32]u8 {
        // Stub implementation - attestation would verify TPM/HSM signatures
        _ = self;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("GEODE-KMS-ATTEST", &hash, .{});
        return hash;
    }

    /// P2-3: Now accepts allocator parameter for temporary message allocation
    pub fn verifyAttestation(allocator: std.mem.Allocator, pub_key: [32]u8, hash: [32]u8, sig: [64]u8, is_unwrap: bool) bool {
        const domain_attest = if (is_unwrap) "GEODE-KMS-ATTEST-UNWRAP" else "GEODE-KMS-ATTEST";
        const msg_len = domain_attest.len + hash.len;
        var msg = allocator.alloc(u8, msg_len) catch return false;
        defer allocator.free(msg);
        std.mem.copyForwards(u8, msg[0..domain_attest.len], domain_attest);
        std.mem.copyForwards(u8, msg[domain_attest.len..msg_len], &hash);
        const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key) catch return false;
        const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig);
        signature.verify(msg, pk) catch return false;
        return true;
    }
};

// (Tests moved to tests/canary_remote_kms.zig)
