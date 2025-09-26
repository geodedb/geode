const std = @import("std");
const crypto = std.crypto;

// external_kms_client.zig
// Simulated external KMS client that performs AES-256-GCM wrapping locally to mimic
// a remote service. Non-deterministic via random nonce so the same plaintext key
// produces different envelopes. Future implementation would replace internals with
// QUIC RPC to a remote KMS service performing hardware-backed encryption.
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26

pub const Envelope = struct {
    version: u8 = 1,
    alg: []const u8 = "AES-256-GCM",
    nonce: [12]u8,
    tag: [16]u8,
    ct: [32]u8, // wrapped 32-byte data key
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8, // simulated Key Encryption Key (would be remote / HSM-controlled)
    prng: std.rand.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Client {
        // Derive KEK deterministically from seed for test reproducibility; real impl would fetch
        var prng = std.rand.DefaultPrng.init(seed);
        var kek: [32]u8 = undefined;
        prng.random().bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .prng = prng };
    }

    pub fn wrap(self: *Client, data_key: [32]u8) !Envelope {
        var nonce: [12]u8 = undefined;
        self.prng.random().bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &data_key, &.{}, nonce, self.kek);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    pub fn unwrap(self: *Client, env: Envelope) ![32]u8 {
        if (env.version != 1) return error.UnsupportedEnvelopeVersion;
        if (!std.mem.eql(u8, env.alg, "AES-256-GCM")) return error.UnsupportedAlgorithm;
        var out: [32]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(&out, &env.ct, env.tag, &.{}, env.nonce, self.kek) catch |e| return e;
        return out;
    }
};

// Serialization helpers (minimal JSON subset for diagnostics & persistence if needed)
pub fn envelopeToJson(env: Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.print("{\"version\":{d},\"alg\":\"{s}\",\"nonce\":\"", .{ env.version, env.alg });
    for (env.nonce) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"tag\":\"", .{});
    for (env.tag) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"ct\":\"", .{});
    for (env.ct) |b| try w.print("{x:0>2}", .{b});
    try w.print("\"}", .{});
    return buf.toOwnedSlice();
}

pub fn envelopeFromJson(json: []const u8) !Envelope {
    // Extremely small parser assuming format produced above. Not robust; internal use only.
    var env: Envelope = undefined;
    env.version = 0; // will set below
    // find fields
    const nonce_key = std.mem.indexOf(u8, json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
    const tag_key = std.mem.indexOf(u8, json, "\"tag\":\"") orelse return error.InvalidEnvelope;
    const ct_key = std.mem.indexOf(u8, json, "\"ct\":\"") orelse return error.InvalidEnvelope;
    // version
    const ver_key = std.mem.indexOf(u8, json, "\"version\":") orelse return error.InvalidEnvelope;
    var i = ver_key + 11; // skip "version":
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    env.version = std.fmt.parseInt(u8, json[i .. i + 1], 10) catch return error.InvalidEnvelope; // single digit expected
    // alg
    const alg_key = std.mem.indexOf(u8, json, "\"alg\":\"") orelse return error.InvalidEnvelope;
    var j = alg_key + 7;
    const alg_end = std.mem.indexOfScalarPos(u8, json, j, '"') orelse return error.InvalidEnvelope;
    const alg_slice = json[j..alg_end];
    if (!std.mem.eql(u8, alg_slice, "AES-256-GCM")) return error.UnsupportedAlgorithm;
    // nonce hex (24 chars)
    const nonce_start = nonce_key + 9;
    const nonce_end = nonce_start + 24;
    if (nonce_end > json.len) return error.InvalidEnvelope;
    var k: usize = 0;
    while (k < 12) : (k += 1) env.nonce[k] = std.fmt.parseInt(u8, json[nonce_start + k * 2 .. nonce_start + k * 2 + 2], 16) catch 0;
    // tag hex (32 chars)
    const tag_start = tag_key + 7;
    const tag_end = tag_start + 32;
    if (tag_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 16) : (k += 1) env.tag[k] = std.fmt.parseInt(u8, json[tag_start + k * 2 .. tag_start + k * 2 + 2], 16) catch 0;
    // ct hex (64 chars)
    const ct_start = ct_key + 6;
    const ct_end = ct_start + 64;
    if (ct_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 32) : (k += 1) env.ct[k] = std.fmt.parseInt(u8, json[ct_start + k * 2 .. ct_start + k * 2 + 2], 16) catch 0;
    env.alg = "AES-256-GCM";
    return env;
}

// Basic tests
test "external kms client wrap/unwrap round trip & non-deterministic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var client = Client.init(gpa.allocator(), 0xDEEFA55E);
    var key: [32]u8 = undefined;
    @memset(&key, 0x11);
    const env1 = try client.wrap(key);
    const env2 = try client.wrap(key);
    try std.testing.expect(!std.mem.eql(u8, &env1.nonce, &env2.nonce));
    const k_out = try client.unwrap(env1);
    try std.testing.expect(std.mem.eql(u8, &key, &k_out));
    // Tamper tag
    var tampered = env1;
    tampered.tag[0] ^= 0xFF;
    const res = client.unwrap(tampered);
    try std.testing.expectError(error.AuthenticationFailed, res);
}
