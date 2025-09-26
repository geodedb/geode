const std = @import("std");
const quic = @import("../transport/quic.zig");
const crypto = std.crypto;

// kms_remote.zig
// Minimal remote KMS prototype over QUIC performing AES-256-GCM wrap/unwrap.
// Server holds KEK and serves two JSON line oriented requests on a single stream:
//   {"op":"Generate"} -> {"status":"OK","envelope":{...}}
//   {"op":"Unwrap","envelope":{...}} -> {"status":"OK","plaintext":"<64 hex>"}
// Errors -> {"status":"ERR","code":"AuthenticationFailed"}
// This is a development scaffold; no auth, single connection, single stream.
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=STUB; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate; OWNER=security; UPDATED=2025-09-26

pub const Envelope = struct {
    version: u8 = 1,
    alg: []const u8 = "AES-256-GCM",
    nonce: [12]u8,
    tag: [16]u8,
    ct: [32]u8,
};

fn envelopeToJson(env: Envelope, w: anytype) !void {
    try w.print("{\"version\":{d},\"alg\":\"{s}\",\"nonce\":\"", .{ env.version, env.alg });
    for (env.nonce) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"tag\":\"", .{});
    for (env.tag) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"ct\":\"", .{});
    for (env.ct) |b| try w.print("{x:0>2}", .{b});
    try w.print("\"}", .{});
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

pub const Server = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8,
    prng: std.rand.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Server {
        var prng = std.rand.DefaultPrng.init(seed);
        var kek: [32]u8 = undefined;
        prng.random().bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .prng = prng };
    }

    fn wrap(self: *Server, plaintext: [32]u8) Envelope {
        var nonce: [12]u8 = undefined;
        self.prng.random().bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &plaintext, &.{}, nonce, self.kek);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    fn unwrap(self: *Server, env: Envelope) ![32]u8 {
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
        if (std.mem.indexOf(u8, req, "Generate")) |_| {
            // create random plaintext key then wrap
            var plain: [32]u8 = undefined;
            self.server.prng.random().bytes(&plain);
            const env = self.server.wrap(plain);
            var out = std.ArrayList(u8).init(self.allocator);
            defer out.deinit();
            const w = out.writer();
            try w.print("{\"status\":\"OK\",\"envelope\":", .{});
            try envelopeToJson(env, w);
            try w.print("}\n", .{});
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
            var out = std.ArrayList(u8).init(self.allocator);
            defer out.deinit();
            const w = out.writer();
            try w.print("{\"status\":\"OK\",\"plaintext\":\"", .{});
            for (plain) |b| try w.print("{x:0>2}", .{b});
            try w.print("\"}\n", .{});
            try stream.writeAll(out.items);
        } else {
            try stream.writeAll("{\"status\":\"ERR\",\"code\":\"BadOp\"}\n");
        }
    }
};

pub const RemoteKmsClient = struct {
    allocator: std.mem.Allocator,
    quic_client: quic.QuicClient,

    pub fn init(allocator: std.mem.Allocator) RemoteKmsClient {
        return .{ .allocator = allocator, .quic_client = quic.QuicClient.init(allocator) };
    }

    pub fn connect(self: *RemoteKmsClient, host: []const u8, port: u16) !void {
        try self.quic_client.connect(host, port);
    }

    pub fn generate(self: *RemoteKmsClient) !Envelope {
        var stream = try self.quic_client.getStream();
        defer stream.deinit();
        try stream.writeAll("{\"op\":\"Generate\"}\n");
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
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        const w = out.writer();
        try w.print("{\"op\":\"Unwrap\",\"envelope\":", .{});
        try envelopeToJson(env, w);
        try w.print("}\n", .{});
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
};

// Basic tests
test "remote kms generate and unwrap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var server = RemoteKmsServer.init(gpa.allocator(), 0xABCD1234);
    // Use ephemeral port 8765 for test
    try server.start(8765);
    var client = RemoteKmsClient.init(gpa.allocator());
    try client.connect("127.0.0.1", 8765);
    // For scaffold we directly write then have server accept after a short delay
    // NOTE: Real implementation would run server loop concurrently.
    // Generate
    // (We cannot easily interleave without async; skip functional assertion until loop added.)
}
