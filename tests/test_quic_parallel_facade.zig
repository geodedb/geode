// CANARY: REQ=REQ-QUIC-HC-029; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedParallelCryptoTest; STATUS=TESTED; TEST=test_quic_parallel_facade; OWNER=transport; UPDATED=2026-05-26
const std = @import("std");
const testing = std.testing;
const quic_parallel = @import("quic_parallel");

test "bounded QUIC parallel facade encrypts and decrypts batches" {
    defer quic_parallel.deinitPool();

    const count = 8;
    const key = [_]u8{0x11} ** 16;
    const iv = [_]u8{0x22} ** 12;
    const aad = "geode-quic-aad";
    const plaintext = "parallel packet payload";

    var enc_inputs: [count]quic_parallel.AeadEncryptInput = undefined;
    var enc_storage: [count][64]u8 = undefined;
    var enc_outputs: [count][]u8 = undefined;
    var enc_results: [count]quic_parallel.AeadEncryptResult = undefined;

    for (0..count) |i| {
        enc_inputs[i] = .{
            .key = &key,
            .iv = &iv,
            .packet_number = @intCast(i),
            .aad = aad,
            .plaintext = plaintext,
        };
        enc_outputs[i] = enc_storage[i][0..];
    }

    quic_parallel.parallelAeadEncrypt(.aes_128_gcm, &enc_inputs, &enc_outputs, &enc_results);
    for (enc_results) |result| {
        try testing.expect(result.success);
        try testing.expectEqual(plaintext.len + 16, result.length);
    }

    var dec_inputs: [count]quic_parallel.AeadDecryptInput = undefined;
    var dec_storage: [count][64]u8 = undefined;
    var dec_outputs: [count][]u8 = undefined;
    var dec_results: [count]quic_parallel.AeadDecryptResult = undefined;

    for (0..count) |i| {
        dec_inputs[i] = .{
            .key = &key,
            .iv = &iv,
            .packet_number = @intCast(i),
            .aad = aad,
            .ciphertext_and_tag = enc_outputs[i][0..enc_results[i].length],
        };
        dec_outputs[i] = dec_storage[i][0..];
    }

    quic_parallel.parallelAeadDecrypt(.aes_128_gcm, &dec_inputs, &dec_outputs, &dec_results);
    for (dec_results, 0..) |result, i| {
        try testing.expect(result.success);
        try testing.expect(!result.auth_failed);
        try testing.expectEqual(plaintext.len, result.length);
        try testing.expectEqualStrings(plaintext, dec_outputs[i][0..result.length]);
    }
}

test "bounded QUIC parallel facade protects headers and detects losses" {
    defer quic_parallel.deinitPool();

    const count = 8;
    const hp_key = [_]u8{0x33} ** 16;
    const sample = [_]u8{0x44} ** 16;

    var hp_inputs: [count]quic_parallel.HeaderProtectInput = undefined;
    var masks: [count][5]u8 = undefined;
    for (0..count) |i| {
        hp_inputs[i] = .{ .hp_key = &hp_key, .sample = sample };
    }
    quic_parallel.parallelHeaderProtect(.aes_128_gcm, &hp_inputs, &masks);
    for (masks[1..]) |mask| {
        try testing.expectEqualSlices(u8, &masks[0], &mask);
    }

    var sent: [128]quic_parallel.SentPacketInfo = undefined;
    for (&sent, 0..) |*packet, i| {
        packet.* = .{
            .packet_number = @intCast(i),
            .size = 1200,
            .time_sent_ns = 0,
            .ack_eliciting = true,
            .declared_lost = false,
        };
    }

    const result = quic_parallel.parallelLossDetect(&sent, 127, 3, 1_000, 10_000);
    try testing.expectEqual(@as(usize, 127), result.lost_count);
    try testing.expectEqual(@as(usize, 127 * 1200), result.bytes_lost);
    try testing.expect(!sent[127].declared_lost);
}
