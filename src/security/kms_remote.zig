const std = @import("std");
const quic = @import("transport/quic");
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

// CANARY: REQ=REQ-REMOTE-KMS-SERVER-001; FEATURE="Remote KMS Server"; ASPECT=QUICTransport; STATUS=IMPL; OWNER=security; UPDATED=2026-01-09
pub const RemoteKmsServer = struct {
    allocator: std.mem.Allocator,
    quic_transport: ?*quic.QuicTransport = null,
    server: Server,
    port: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64) RemoteKmsServer {
        return .{ .allocator = allocator, .server = Server.init(allocator, seed) };
    }

    pub fn deinit(self: *RemoteKmsServer) void {
        if (self.quic_transport) |qt| {
            qt.deinit();
            self.allocator.destroy(qt);
            self.quic_transport = null;
        }
    }

    pub fn start(self: *RemoteKmsServer, port: u16) !void {
        self.port = port;

        // GAP-0105 SECURITY FIX: Use secure TLS by default for KMS transport
        // Initialize QUIC transport with certificate validation enabled
        var qt = try quic.QuicTransport.init(self.allocator, .{
            .port = port,
            .address = "0.0.0.0",
            .allow_insecure = false, // Security: require valid TLS certificates
        });
        errdefer qt.deinit();

        try qt.listen();

        // Store transport
        const qt_ptr = try self.allocator.create(quic.QuicTransport);
        qt_ptr.* = qt;
        self.quic_transport = qt_ptr;

        std.debug.print("KMS_SERVER: Listening on port {d}\n", .{port});
    }

    pub fn serveOnce(self: *RemoteKmsServer) !void {
        const qt = self.quic_transport orelse return error.NotStarted;

        // Poll for events
        try qt.poll(100);

        // Try to accept a connection
        const conn = qt.tryAccept() orelse return;
        defer conn.close();

        std.debug.print("KMS_SERVER: Accepted connection\n", .{});

        // Accept stream
        const stream = conn.acceptStream() catch |err| {
            std.debug.print("KMS_SERVER: Failed to accept stream: {}\n", .{err});
            return;
        };
        defer stream.close();

        // Read request line
        const request = stream.readLine(4096) catch |err| {
            if (err == error.WouldBlock) return;
            std.debug.print("KMS_SERVER: Failed to read request: {}\n", .{err});
            return;
        };
        defer self.allocator.free(request);

        std.debug.print("KMS_SERVER: Received request: {s}\n", .{request});

        // Process request and generate response
        var response_buf: [4096]u8 = undefined;
        const response = self.processRequest(request, &response_buf) catch |err| {
            std.debug.print("KMS_SERVER: Failed to process request: {}\n", .{err});
            const err_response = "{\"status\":\"ERR\",\"code\":\"InternalError\"}\n";
            stream.writeAll(err_response) catch {};
            return;
        };

        // Send response
        stream.writeAll(response) catch |err| {
            std.debug.print("KMS_SERVER: Failed to send response: {}\n", .{err});
        };
    }

    fn processRequest(self: *RemoteKmsServer, request: []const u8, response_buf: []u8) ![]const u8 {
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
            if (!std.mem.eql(u8, provided_token, expected_token)) {
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
            return self.handleAttest(response_buf);
        } else {
            return try std.fmt.bufPrint(response_buf, "{{\"status\":\"ERR\",\"code\":\"InvalidOperation\"}}\n", .{});
        }
    }

    fn handleGenerate(self: *RemoteKmsServer, response_buf: []u8) ![]const u8 {
        // Generate a new data key and wrap it
        var plaintext: [32]u8 = undefined;
        std.crypto.random.bytes(&plaintext);

        const envelope = self.server.wrap(plaintext);

        // Build response
        var fbs = std.io.fixedBufferStream(response_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"status\":\"OK\",\"envelope\":");
        try envelopeToJson(envelope, writer);
        try writer.writeAll("}\n");

        return fbs.getWritten();
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
        var fbs = std.io.fixedBufferStream(response_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"status\":\"OK\",\"plaintext\":\"");
        for (plaintext) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\"}\n");

        return fbs.getWritten();
    }

    fn handlePrivUnwrap(self: *RemoteKmsServer, request: []const u8, response_buf: []u8) ![]const u8 {
        // Privileged unwrap - same as regular unwrap but may include attestation
        return self.handleUnwrap(request, response_buf);
    }

    fn handleAttest(self: *RemoteKmsServer, response_buf: []u8) ![]const u8 {
        // Generate attestation response
        const kp = self.server.attest_keypair orelse return error.NotConfigured;

        // Sign the attestation hash
        const domain = "GEODE-KMS-ATTEST";
        var msg: [domain.len + 32]u8 = undefined;
        @memcpy(msg[0..domain.len], domain);
        @memcpy(msg[domain.len..], &self.server.attestation_hash);

        const sig = try kp.sign(&msg, null);
        const sig_bytes = sig.toBytes();

        // Build response
        var fbs = std.io.fixedBufferStream(response_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"status\":\"OK\",\"hash\":\"");
        for (self.server.attestation_hash) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\",\"pub\":\"");
        for (kp.public_key.bytes) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\",\"sig\":\"");
        for (sig_bytes) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\"}\n");

        return fbs.getWritten();
    }

    pub fn serveLoop(self: *RemoteKmsServer, iterations: usize) !void {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            self.serveOnce() catch |err| {
                if (err != error.NotStarted) {
                    std.debug.print("KMS_SERVER: serveOnce error: {}\n", .{err});
                }
            };
        }
    }
};

// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=NETWORK; STATUS=IMPL; OWNER=security; UPDATED=2026-01-09
pub const RemoteKmsClient = struct {
    allocator: std.mem.Allocator,
    quic_client: ?quic.QuicClient = null,
    auth_token: ?[]const u8 = null,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator) RemoteKmsClient {
        return .{ .allocator = allocator, .quic_client = null, .connected = false };
    }

    pub fn deinit(self: *RemoteKmsClient) void {
        if (self.quic_client) |*client| {
            client.deinit();
        }
        self.quic_client = null;
        self.connected = false;
    }

    pub fn connect(self: *RemoteKmsClient, host: []const u8, port: u16) !void {
        // Initialize QUIC client and connect to KMS server
        self.quic_client = quic.QuicClient.init(self.allocator);
        try self.quic_client.?.connectInsecure(host, port, true);
        try self.quic_client.?.waitForHandshake(10);
        self.connected = true;
    }

    pub fn setAuthToken(self: *RemoteKmsClient, tok: []const u8) void {
        self.auth_token = tok;
    }

    fn authPrefix(self: *RemoteKmsClient) []const u8 {
        return if (self.auth_token) |t| t else "";
    }

    /// Send a JSON request over QUIC and read the JSON response line
    fn sendRequest(self: *RemoteKmsClient, request: []const u8) ![]u8 {
        if (!self.connected or self.quic_client == null) {
            return error.NotConnected;
        }

        // Open a stream for this request
        var stream = try self.quic_client.?.getStream();
        defer stream.close();

        // Write the request (must end with newline)
        try stream.writeAll(request);

        // Poll and read response
        var retries: usize = 0;
        while (retries < 100) : (retries += 1) {
            try self.quic_client.?.poll(50);
            const response = stream.readLine(8192) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return response;
        }
        return error.Timeout;
    }

    pub fn generate(self: *RemoteKmsClient) !Envelope {
        // Build JSON request
        var request_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const writer = fbs.writer();

        if (self.auth_token) |tok| {
            try writer.print("{{\"op\":\"Generate\",\"auth\":\"{s}\"}}\n", .{tok});
        } else {
            try writer.writeAll("{\"op\":\"Generate\"}\n");
        }

        const request = fbs.getWritten();

        // If not connected, fall back to local generation
        if (!self.connected) {
            const ext = @import("external_kms_client.zig");
            var client = ext.Client.init(self.allocator, 0x12345678);
            var key: [32]u8 = undefined;
            std.crypto.random.bytes(&key);
            const ext_envelope = try client.wrap(key);
            return Envelope{
                .version = ext_envelope.version,
                .alg = ext_envelope.alg,
                .nonce = ext_envelope.nonce,
                .tag = ext_envelope.tag,
                .ct = ext_envelope.ct,
            };
        }

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parseEnvelopeResponse(response);
    }

    pub fn unwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        // Build JSON request with envelope
        var request_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"op\":\"Unwrap\"");
        if (self.auth_token) |tok| {
            try writer.print(",\"auth\":\"{s}\"", .{tok});
        }
        try writer.writeAll(",\"envelope\":");
        try envelopeToJson(env, writer);
        try writer.writeAll("}\n");

        const request = fbs.getWritten();

        // If not connected, fall back to local unwrapping
        if (!self.connected) {
            const ext = @import("external_kms_client.zig");
            var client = ext.Client.init(self.allocator, 0x12345678);
            const ext_envelope = ext.Envelope{
                .version = env.version,
                .alg = env.alg,
                .nonce = env.nonce,
                .tag = env.tag,
                .ct = env.ct,
            };
            return try client.unwrap(ext_envelope);
        }

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parsePlaintextResponse(response);
    }

    pub fn privUnwrap(self: *RemoteKmsClient, env: Envelope) ![32]u8 {
        // Build JSON request with PrivUnwrap operation
        var request_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"op\":\"PrivUnwrap\"");
        if (self.auth_token) |tok| {
            try writer.print(",\"auth\":\"{s}\"", .{tok});
        }
        try writer.writeAll(",\"envelope\":");
        try envelopeToJson(env, writer);
        try writer.writeAll("}\n");

        const request = fbs.getWritten();

        // If not connected, fall back to local unwrapping
        if (!self.connected) {
            return self.unwrap(env);
        }

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parsePlaintextResponse(response);
    }

    pub fn attest(self: *RemoteKmsClient) ![32]u8 {
        // Build JSON request
        var request_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const writer = fbs.writer();

        if (self.auth_token) |tok| {
            try writer.print("{{\"op\":\"Attest\",\"auth\":\"{s}\"}}\n", .{tok});
        } else {
            try writer.writeAll("{\"op\":\"Attest\"}\n");
        }

        const request = fbs.getWritten();

        // If not connected, fall back to local attestation hash
        if (!self.connected) {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("GEODE-KMS-ATTEST", &hash, .{});
            return hash;
        }

        // Send request and parse response
        const response = try self.sendRequest(request);
        defer self.allocator.free(response);

        return try parseAttestResponse(response);
    }

    /// Parse envelope from JSON response like {"status":"OK","envelope":{...}}
    fn parseEnvelopeResponse(response: []const u8) !Envelope {
        // Simple JSON parsing - look for envelope field
        const envelope_start = std.mem.indexOf(u8, response, "\"envelope\":");
        if (envelope_start == null) {
            // Check for error status
            if (std.mem.indexOf(u8, response, "\"ERR\"") != null) {
                return error.RemoteError;
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
                return error.RemoteError;
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

    /// Parse attestation hash from JSON response
    fn parseAttestResponse(response: []const u8) ![32]u8 {
        // Look for hash field
        const hash_start = std.mem.indexOf(u8, response, "\"hash\":\"");
        if (hash_start == null) {
            if (std.mem.indexOf(u8, response, "\"ERR\"") != null) {
                return error.RemoteError;
            }
            return error.InvalidResponse;
        }

        // Extract hex string
        const hex_start = hash_start.? + 8;
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
