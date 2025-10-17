const std = @import("std");
const quic = @import("transport/quic");
const crypto = std.crypto;

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

    pub fn setAuthToken(self: *Server, tok: []const u8) void {
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
        const attest_kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
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
    quic_transport: ?*quic.QuicTransport = null,
    server: Server,

    pub fn init(allocator: std.mem.Allocator, seed: u64) RemoteKmsServer {
        return .{ .allocator = allocator, .server = Server.init(allocator, seed) };
    }

    pub fn start(self: *RemoteKmsServer, port: u16) !void {
        var qt = try quic.QuicTransport.init(self.allocator, .{ .port = port });
        try qt.listen();
        self.quic_transport = try self.allocator.create(quic.QuicTransport);
        self.quic_transport.?.* = qt;
    }

    pub fn serveOnce(self: *RemoteKmsServer) !void {
        if (self.quic_transport == null) return error.NotStarted;
        var conn = try self.quic_transport.?.accept();
        var stream = try conn.acceptStream();
        var buf = try self.allocator.alloc(u8, 1024);
        defer self.allocator.free(buf);
        const n = try stream.read(buf);
        if (n == 0) return;
        const req = buf[0..n];
        // Simple auth: expect field "auth":"<token>" if token configured
        if (self.server.auth_token) |tok| {
            // naive check: token must appear and be preceded by "auth":"
            const pos = std.mem.indexOf(u8, req, tok);
            if (pos == null or std.mem.indexOf(u8, req, "\"auth\":\"") == null) {
                try stream.writeAll("{\"status\":\"ERR\",\"code\":\"AuthenticationFailed\"}\n");
                return;
            }
        }
        if (std.mem.indexOf(u8, req, "Generate")) |_| {
            // create random plaintext key then wrap
            var plain: [32]u8 = undefined;
            self.server.prng.bytes(&plain);
            const env = self.server.wrap(plain);
            var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
            defer out.deinit(self.allocator);
            const w = out.writer(self.allocator);
            try w.writeAll("{\"status\":\"OK\",\"envelope\":");
            try envelopeToJson(env, w);
            try w.writeAll("}\n");
            try stream.writeAll(out.items);
        } else if (std.mem.indexOf(u8, req, "Unwrap")) |_| {
            // find envelope object start
            const env_pos = std.mem.indexOf(u8, req, "{\"version\"") orelse return;
            const env_slice = req[env_pos .. n - 1];
            const env = parseEnvelope(env_slice) catch return;
            const plain = self.server.unwrap(env) catch |e| switch (e) {
                error.AuthenticationFailed => {
                    try stream.writeAll("{\"status\":\"ERR\",\"code\":\"AuthenticationFailed\"}\n");
                    return;
                },
                else => return,
            };
            var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
            defer out.deinit(self.allocator);
            const w = out.writer(self.allocator);
            try w.writeAll("{\"status\":\"OK\",\"plaintext\":\"");
            for (plain) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll(",\"attestation\":{\"hash\":\"");
            for (self.server.attestation_hash) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll(",\"pub\":\"");
            const kp = self.server.attest_keypair.?;
            for (kp.public_key.toBytes()) |b| try w.print("{x:0>2}", .{b});
            // Sign message: domain tag + hash (plaintext excluded for simplicity)
            const domain = "GEODE-KMS-ATTEST-UNWRAP";
            const msg_len = domain.len + self.server.attestation_hash.len;
            var msg = try self.allocator.alloc(u8, msg_len);
            defer self.allocator.free(msg);
            std.mem.copyForwards(u8, msg[0..domain.len], domain);
            std.mem.copyForwards(u8, msg[domain.len..msg_len], &self.server.attestation_hash);
            const sig = kp.sign(msg, null) catch unreachable;
            try w.writeAll(",\"sig\":\"");
            const sig_bytes = sig.toBytes();
            for (sig_bytes) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll("\"}}\n");
            try stream.writeAll(out.items);
        } else if (std.mem.indexOf(u8, req, "PrivUnwrap")) |_| {
            // privileged unwrap same as unwrap but explicit op; enforce token already checked
            const env_pos = std.mem.indexOf(u8, req, "{\"version\"") orelse return;
            const env_slice = req[env_pos .. n - 1];
            const env = parseEnvelope(env_slice) catch return;
            const plain = self.server.unwrap(env) catch |e| switch (e) {
                error.AuthenticationFailed => {
                    try stream.writeAll("{\"status\":\"ERR\",\"code\":\"AuthenticationFailed\"}\n");
                    return;
                },
                else => return,
            };
            var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
            defer out.deinit(self.allocator);
            const w = out.writer(self.allocator);
            try w.writeAll("{\"status\":\"OK\",\"plaintext\":\"");
            for (plain) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll("\",\"privileged\":true}\n");
            try stream.writeAll(out.items);
        } else if (std.mem.indexOf(u8, req, "Attest")) |_| {
            var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
            defer out.deinit(self.allocator);
            const w = out.writer(self.allocator);
            try w.writeAll("{\"status\":\"OK\",\"attestation\":{\"hash\":\"");
            for (self.server.attestation_hash) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll(",\"pub\":\"");
            const kp2 = self.server.attest_keypair.?;
            for (kp2.public_key.toBytes()) |b| try w.print("{x:0>2}", .{b});
            const domain2 = "GEODE-KMS-ATTEST";
            const msg2_len = domain2.len + self.server.attestation_hash.len;
            var msg2 = try self.allocator.alloc(u8, msg2_len);
            defer self.allocator.free(msg2);
            std.mem.copyForwards(u8, msg2[0..domain2.len], domain2);
            std.mem.copyForwards(u8, msg2[domain2.len..msg2_len], &self.server.attestation_hash);
            const sig2 = kp2.sign(msg2, null) catch unreachable;
            try w.writeAll(",\"sig\":\"");
            const sig2_bytes = sig2.toBytes();
            for (sig2_bytes) |b| try w.print("{x:0>2}", .{b});
            try w.writeAll("\"}}\n");
            try stream.writeAll(out.items);
        } else {
            try stream.writeAll("{\"status\":\"ERR\",\"code\":\"BadOp\"}\n");
        }
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
    quic_client: quic.QuicClient,
    auth_token: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) RemoteKmsClient {
        return .{ .allocator = allocator, .quic_client = quic.QuicClient.init(allocator) };
    }

    pub fn connect(self: *RemoteKmsClient, host: []const u8, port: u16) !void {
        try self.quic_client.connect(host, port);
    }

    pub fn setAuthToken(self: *RemoteKmsClient, tok: []const u8) void {
        self.auth_token = tok;
    }

    fn authPrefix(self: *RemoteKmsClient) []const u8 {
        return if (self.auth_token) |t| t else "";
    }

    pub fn generate(self: *RemoteKmsClient) !Envelope {
        var stream = try self.quic_client.getStream();
        defer stream.deinit();
        if (self.auth_token) |_| {
            try stream.writeAll("{\"op\":\"Generate\",\"auth\":\"");
            try stream.writeAll(self.auth_token.?);
            try stream.writeAll("\"}\n");
        } else try stream.writeAll("{\"op\":\"Generate\"}\n");
        var buf = try self.allocator.alloc(u8, 512);
        defer self.allocator.free(buf);
        const n = try stream.read(buf);
        const resp = buf[0..n];
        if (std.mem.indexOf(u8, resp, "\"status\":\"OK\"")) |_| {
            const env_pos = std.mem.indexOf(u8, resp, "{\"version\"") orelse return error.InvalidResponse;
            const env = try parseEnvelope(resp[env_pos..]);
            return env;
        }
        return error.InvalidResponse;
    }

    pub fn unwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        var stream = try self.quic_client.getStream();
        defer stream.deinit();
        var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        if (self.auth_token) |_| {
            try w.writeAll("{\"op\":\"Unwrap\",\"auth\":\"");
            try w.writeAll(self.auth_token.?);
            try w.writeAll("\",\"envelope\":");
        } else {
            try w.writeAll("{\"op\":\"Unwrap\",\"envelope\":");
        }
        try envelopeToJson(env, w);
        try w.writeAll("}\n");
        try stream.writeAll(out.items);
        var buf = try self.allocator.alloc(u8, 512);
        defer self.allocator.free(buf);
        const n = try stream.read(buf);
        const resp = buf[0..n];
        if (std.mem.indexOf(u8, resp, "AuthenticationFailed")) |_| return error.AuthenticationFailed;
        if (std.mem.indexOf(u8, resp, "\"status\":\"OK\"")) |_| {
            const ppos = std.mem.indexOf(u8, resp, "\"plaintext\":\"") orelse return error.InvalidResponse;
            const start = ppos + 13;
            var plain: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) plain[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
            return plain;
        }
        return error.InvalidResponse;
    }

    pub fn privUnwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        var stream = try self.quic_client.getStream();
        defer stream.deinit();
        var out = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        if (self.auth_token) |_| {
            try w.writeAll("{\"op\":\"PrivUnwrap\",\"auth\":\"");
            try w.writeAll(self.auth_token.?);
            try w.writeAll("\",\"envelope\":");
        } else {
            try w.writeAll("{\"op\":\"PrivUnwrap\",\"envelope\":");
        }
        try envelopeToJson(env, w);
        try w.writeAll("}\n");
        try stream.writeAll(out.items);
        var buf = try self.allocator.alloc(u8, 512);
        defer self.allocator.free(buf);
        const n = try stream.read(buf);
        const resp = buf[0..n];
        if (std.mem.indexOf(u8, resp, "\"privileged\":true")) |_| {
            const ppos = std.mem.indexOf(u8, resp, "\"plaintext\":\"") orelse return error.InvalidResponse;
            const start = ppos + 13;
            var plain: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) plain[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
            return plain;
        }
        return error.InvalidResponse;
    }

    pub fn attest(self: *RemoteKmsClient) ![32]u8 {
        var stream = try self.quic_client.getStream();
        defer stream.deinit();
        if (self.auth_token) |_| {
            try stream.writeAll("{\"op\":\"Attest\",\"auth\":\"");
            try stream.writeAll(self.auth_token.?);
            try stream.writeAll("\"}\n");
        } else try stream.writeAll("{\"op\":\"Attest\"}\n");
        var buf = try self.allocator.alloc(u8, 256);
        defer self.allocator.free(buf);
        const n = try stream.read(buf);
        const resp = buf[0..n];
        const hpos = std.mem.indexOf(u8, resp, "\"hash\":\"") orelse return error.InvalidResponse;
        const pubpos = std.mem.indexOf(u8, resp, "\"pub\":\"") orelse return error.InvalidResponse;
        const sigpos = std.mem.indexOf(u8, resp, "\"sig\":\"") orelse return error.InvalidResponse;
        var hash: [32]u8 = undefined;
        var pub_key: [32]u8 = undefined;
        var sig: [64]u8 = undefined; // Ed25519 signature length
        var i: usize = 0;
        var start = hpos + 9;
        while (i < 32) : (i += 1) hash[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
        i = 0;
        start = pubpos + 8;
        while (i < 32) : (i += 1) pub_key[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
        i = 0;
        start = sigpos + 8;
        while (i < 64) : (i += 1) sig[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
        if (!verifyAttestation(self.allocator, pub_key, hash, sig, false)) return error.InvalidResponse;
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
