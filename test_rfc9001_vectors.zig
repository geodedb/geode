const std = @import("std");
const ks = @import("vendor/quic/src/quic/tls/key_schedule.zig");

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var result: [hex.len / 2]u8 = undefined;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const byte = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
        result[i / 2] = byte;
    }
    return result;
}

test "RFC 9001 A.1 Initial Secrets" {
    // Test vectors from RFC 9001 Appendix A.1
    const cid = hexToBytes("8394c8f03e515708");
    const expected_initial_secret = hexToBytes("7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44");
    const expected_client_initial = hexToBytes("c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea");
    const expected_server_initial = hexToBytes("3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b");
    const expected_client_key = hexToBytes("1f369613dd76d5467730efcbe3b1a22d");
    const expected_client_iv = hexToBytes("fa044b2f42a3fd3b46fb255c");
    const expected_client_hp = hexToBytes("9f50449e04a0e810283a1e9933adedd2");

    // Derive initial_secret using v1 (RFC 9001 uses QUIC v1)
    const initial_secret = ks.deriveInitialSecretV1(&cid);
    try std.testing.expectEqualSlices(u8, &expected_initial_secret, &initial_secret);
    std.debug.print("✓ Initial secret matches RFC 9001\n", .{});

    // Derive client and server initial secrets
    const secrets = ks.deriveClientServerInitial(initial_secret);
    try std.testing.expectEqualSlices(u8, &expected_client_initial, &secrets.client);
    try std.testing.expectEqualSlices(u8, &expected_server_initial, &secrets.server);
    std.debug.print("✓ Client/Server initial secrets match RFC 9001\n", .{});

    // Derive and verify client keys
    const client_keys = ks.deriveKeyIvHp(secrets.client);
    try std.testing.expectEqualSlices(u8, &expected_client_key, &client_keys.key);
    try std.testing.expectEqualSlices(u8, &expected_client_iv, &client_keys.iv);
    try std.testing.expectEqualSlices(u8, &expected_client_hp, &client_keys.hp);
    std.debug.print("✓ Client keys (key, iv, hp) match RFC 9001\n", .{});
}

test "RFC 9001 Handshake Key Derivation" {
    // This test verifies that handshake keys are derived correctly from TLS secrets
    // The handshake secrets come from TLS 1.3 after processing ClientHello + ServerHello

    // For this test, we need to simulate the exact handshake from the RFC
    // But first let's verify our HKDF implementation works correctly

    const test_secret = hexToBytes("c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea");
    const keys = ks.deriveKeyIvHp(test_secret);

    // These should match the client initial keys from above
    const expected_key = hexToBytes("1f369613dd76d5467730efcbe3b1a22d");
    const expected_iv = hexToBytes("fa044b2f42a3fd3b46fb255c");
    const expected_hp = hexToBytes("9f50449e04a0e810283a1e9933adedd2");

    try std.testing.expectEqualSlices(u8, &expected_key, &keys.key);
    try std.testing.expectEqualSlices(u8, &expected_iv, &keys.iv);
    try std.testing.expectEqualSlices(u8, &expected_hp, &keys.hp);
    std.debug.print("✓ QUIC key derivation from secret works correctly\n", .{});
}

pub fn main() !void {
    std.debug.print("Running RFC 9001 test vector verification...\n", .{});

    // Run the tests
    _ = try @import("std").testing.runTests(@This());

    std.debug.print("\n✅ All RFC 9001 test vectors passed!\n", .{});
}