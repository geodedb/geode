const std = @import("std");
// Federation mismatch flag module
// Provides a single global flag toggled by federation merge logic when an ordering
// metadata mismatch (key count, direction, null ordering) forces a fallback strategy.
// The server imports this lightweight module only (decoupled from full federation implementation)
// to avoid making federation.zig a second root module and triggering Zig duplicate root errors.
//
// Semantics: When a mismatch occurs the federation engine sets the atomic flag to true.
// The protocol flag assembly calls consumeMismatchFlag(), which returns true exactly once
// (it resets the flag), causing emission of usage flag U:FederationOrderMismatch for that
// result stream. Subsequent pages / frames in the same stream will not repeat it unless a new
// mismatch event occurs.
//
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=Federation; STATUS=TESTED; TEST="federation mismatch flag consumption"; OWNER=federation; UPDATED=2026-04-05

pub var g_last_federation_mismatch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn consumeMismatchFlag() bool {
    if (g_last_federation_mismatch.load(.acquire)) {
        g_last_federation_mismatch.store(false, .release);
        return true;
    }
    return false;
}

pub fn mismatchFlag() bool {
    return g_last_federation_mismatch.load(.acquire);
}

test "federation mismatch flag consumption" {
    // Initially false
    try std.testing.expect(!mismatchFlag());
    // Set and consume
    g_last_federation_mismatch.store(true, .release);
    try std.testing.expect(consumeMismatchFlag());
    // Second consume returns false (single emission semantics)
    try std.testing.expect(!consumeMismatchFlag());
    try std.testing.expect(!mismatchFlag());
}
