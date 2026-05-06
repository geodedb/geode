// LSP Transport tests
// Covers Content-Length header parsing and DoS-guard caps.
//
// CANARY: REQ=REQ-LSP-SEC-001; FEATURE="ContentLengthCap"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const transport = @import("transport.zig");

test "LSP-SEC-001: Content-Length above 16 MiB returns InvalidContentLength" {
    // 17_000_000 bytes ≈ 16.21 MiB — strictly above the 16 MiB cap.
    const result = transport.parseContentLength("17000000");
    try testing.expectError(transport.TransportError.InvalidContentLength, result);
}

test "LSP-SEC-001: Content-Length u64::MAX returns InvalidContentLength" {
    const result = transport.parseContentLength("18446744073709551615");
    try testing.expectError(transport.TransportError.InvalidContentLength, result);
}

test "LSP-SEC-001: Content-Length exactly at cap (16 MiB) is accepted" {
    // 16 * 1024 * 1024 = 16777216 — boundary-of-acceptance.
    const v = try transport.parseContentLength("16777216");
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), v);
}

test "LSP-SEC-001: Content-Length one byte over cap rejected" {
    // 16 MiB + 1
    const result = transport.parseContentLength("16777217");
    try testing.expectError(transport.TransportError.InvalidContentLength, result);
}

test "LSP-SEC-001: small Content-Length (1024) still succeeds" {
    const v = try transport.parseContentLength("1024");
    try testing.expectEqual(@as(usize, 1024), v);
}

test "LSP-SEC-001: zero Content-Length is parseable (semantic check up to caller)" {
    const v = try transport.parseContentLength("0");
    try testing.expectEqual(@as(usize, 0), v);
}

test "LSP-SEC-001: garbage Content-Length still returns InvalidContentLength" {
    const result = transport.parseContentLength("not_a_number");
    try testing.expectError(transport.TransportError.InvalidContentLength, result);
}

test "LSP-SEC-001: MAX_LSP_MESSAGE constant is 16 MiB" {
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), transport.MAX_LSP_MESSAGE);
}
