const std = @import("std");
const kms = @import("security/kms_remote");
// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_SignatureVerify|TestCANARY_REQ_GQL_TDE_ATTEST_001_TamperDetect; OWNER=security; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_TDE_ATTEST_001_SignatureVerify" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var server = try kms.RemoteKmsServer.init(alloc, 0x1234);
    try server.start(44556);
    try server.server.setAuthToken("tok-attest");

    var client = kms.RemoteKmsClient.init(alloc);
    try client.connect("127.0.0.1", 44556);
    client.setAuthToken("tok-attest");
    // Perform raw attest and capture full response by duplicating client logic (temporary until client exposes structured API)
    // Acquire stream manually to read raw JSON
    var stream = try client.quic_client.getStream();
    defer stream.deinit();
    try stream.writeAll("{\"op\":\"Attest\",\"auth\":\"tok-attest\"}\n");
    var buf = try alloc.alloc(u8, 512);
    defer alloc.free(buf);
    const n = try stream.read(buf);
    const resp = buf[0..n];
    // Extract hash/pub/sig
    const hpos = std.mem.indexOf(u8, resp, "\"hash\":\"") orelse return error.TestExpectedEqual;
    const pubpos = std.mem.indexOf(u8, resp, "\"pub\":\"") orelse return error.TestExpectedEqual;
    const sigpos = std.mem.indexOf(u8, resp, "\"sig\":\"") orelse return error.TestExpectedEqual;
    var hash: [32]u8 = undefined;
    var pub_key: [32]u8 = undefined;
    var sig: [64]u8 = undefined;
    var i: usize = 0;
    var start: usize = hpos + 9;
    while (i < 32) : (i += 1) hash[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    i = 0;
    start = pubpos + 8;
    while (i < 32) : (i += 1) pub_key[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    i = 0;
    start = sigpos + 8;
    while (i < 64) : (i += 1) sig[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    // Verify signature via exported helper
    const ok = kms.RemoteKmsClient.verifyAttestation(std.testing.allocator, pub_key, hash, sig, false);
    try std.testing.expect(ok);
    // Non-zero hash sanity
    var zero: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &hash, &zero));
}

test "TestCANARY_REQ_GQL_TDE_ATTEST_001_TamperDetect" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var server = try kms.RemoteKmsServer.init(alloc, 0x9999);
    try server.start(44557);
    try server.server.setAuthToken("tok-attest2");

    var client = kms.RemoteKmsClient.init(alloc);
    try client.connect("127.0.0.1", 44557);
    client.setAuthToken("tok-attest2");

    // Perform direct attest to get values via raw call (reuse internal function by forging response not exposed; we just call attest then mutate and re-verify using exported verifyAttestation)
    // Perform real attest request to capture authentic values
    var stream = try client.quic_client.getStream();
    defer stream.deinit();
    try stream.writeAll("{\"op\":\"Attest\",\"auth\":\"tok-attest2\"}\n");
    var buf = try alloc.alloc(u8, 512);
    defer alloc.free(buf);
    const n = try stream.read(buf);
    const resp = buf[0..n];
    const hpos = std.mem.indexOf(u8, resp, "\"hash\":\"") orelse return error.TestExpectedEqual;
    const pubpos = std.mem.indexOf(u8, resp, "\"pub\":\"") orelse return error.TestExpectedEqual;
    const sigpos = std.mem.indexOf(u8, resp, "\"sig\":\"") orelse return error.TestExpectedEqual;
    var hash: [32]u8 = undefined;
    var pub_key: [32]u8 = undefined;
    var sig: [64]u8 = undefined;
    var i: usize = 0;
    var start: usize = hpos + 9;
    while (i < 32) : (i += 1) hash[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    i = 0;
    start = pubpos + 8;
    while (i < 32) : (i += 1) pub_key[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    i = 0;
    start = sigpos + 8;
    while (i < 64) : (i += 1) sig[i] = parseHexByte(resp[start + i * 2 .. start + i * 2 + 2]);
    // Tamper with signature (flip byte) -> must fail
    var sig_tampered = sig;
    sig_tampered[10] ^= 0xAA;
    const ok1 = kms.RemoteKmsClient.verifyAttestation(std.testing.allocator, pub_key, hash, sig, false);
    try std.testing.expect(ok1);
    const ok2 = kms.RemoteKmsClient.verifyAttestation(std.testing.allocator, pub_key, hash, sig_tampered, false);
    try std.testing.expect(!ok2);
}

// Helper duplicated from kms_remote for test parsing (keep private here)
fn parseHexByte(slice: []const u8) u8 {
    return std.fmt.parseInt(u8, slice, 16) catch 0;
}
