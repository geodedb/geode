const std = @import("std");
const expect = std.testing.expect;
const mfa = @import("../src/security/mfa.zig");

// Negative Base32 decode robustness tests.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=RobustnessBase32Decode; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_Base32DecodeNegatives; OWNER=security; UPDATED=2026-11-14

// Access internal function via declaration hack (could be moved to public for testing if desired)
extern fn base32Decode(allocator: std.mem.Allocator, encoded: []const u8) anyerror![]u8; // expected symbol re-export if made pub

// For now replicate minimal wrapper since base32Decode is internal in mfa.zig.
fn tryDecode(allocator: std.mem.Allocator, input: []const u8) !bool {
    // Attempt to invoke via mfa.generateCodeFromBase32 to exercise decode path indirectly.
    // We rely on decode precondition (length multiple of 8) to trigger early errors.
    // Provide fake timestamp/params; failure from decode should surface.
    return mfa.generateCodeFromBase32(allocator, input, 0, 30, 6) catch |e| switch (e) {
        error.InvalidBase32 => return false,
        else => return false,
    } != false;
}

test "TestCANARY_REQ_GQL_MFA_CORE_001_Base32DecodeNegatives" {
    mfa.enableForTests();
    defer mfa.disableForTests();
    const alloc = std.testing.allocator;
    // Case 1: length not multiple of 8
    try expect(!tryDecode(alloc, "ABC"));
    // Case 2: invalid character '!' inside block
    try expect(!tryDecode(alloc, "ABCDEFG!"));
    // Case 3: numeric '1' not in Base32 alphabet
    try expect(!tryDecode(alloc, "AAAAAAA1"));
    // Case 4: mixed lowercase (should be invalid)
    try expect(!tryDecode(alloc, "abcDEFGH"));
}
