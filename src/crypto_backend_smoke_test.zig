// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Task 1 smoke test: verifies that the crypto_backend seam is wired correctly
// in both -Dfips=false (std_shim) and -Dfips=true (OpenSSL FIPS) modes.
//
// Two KAT vectors:
//   SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
//   HMAC-SHA1("Jefe", "what do ya want for nothing?")
//     = effcdf6ae5eb2fa2d27416d5f184df9c259a7c79
// The second vector proves the extended fips seam (Task 0: Mac.hmacSha1) is
// live in whichever backend was compiled in.

const std = @import("std");
const cb = @import("crypto_backend");

test "crypto_backend: SHA-256 KAT (abc)" {
    const msg = "abc";
    var out: [64]u8 = undefined;
    const n = try cb.Hash.digest(.sha256, msg, &out);
    try std.testing.expectEqual(@as(usize, 32), n);

    // Expected: SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    const expected = [32]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected, out[0..32]);
}

test "crypto_backend: HMAC-SHA1 KAT (RFC 2202 test-case 2)" {
    // RFC 2202 / FIPS 198-1 test vector:
    //   Key  = "Jefe"
    //   Data = "what do ya want for nothing?"
    //   HMAC = effcdf6ae5eb2fa2d27416d5f184df9c259a7c79
    const key = "Jefe";
    const msg = "what do ya want for nothing?";
    var mac: [20]u8 = undefined;
    const n = try cb.Mac.hmacSha1(key, msg, &mac);
    try std.testing.expectEqual(@as(usize, 20), n);

    const expected = [20]u8{
        0xef, 0xfc, 0xdf, 0x6a, 0xe5, 0xeb, 0x2f, 0xa2,
        0xd2, 0x74, 0x16, 0xd5, 0xf1, 0x84, 0xdf, 0x9c,
        0x25, 0x9a, 0x7c, 0x79,
    };
    try std.testing.expectEqualSlices(u8, &expected, &mac);
}
