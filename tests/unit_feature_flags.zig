const std = @import("std");
const testing = std.testing;
const flags_mod = @import("src/util/feature_flags.zig");

// Basic tests for shared feature flag wrapper
// CANARY: REQ=REQ-GQL-FLAGS-001; FEATURE="Shared Feature Flag Wrapper"; ASPECT=INFRA; STATUS=TESTED; OWNER=core; UPDATED=2025-09-26

fn resetAll() void {
    // Disable all flags to baseline state
    flags_mod.global().tde.disableForTests();
    flags_mod.global().mfa.disableForTests();
    flags_mod.global().adv_fts.disableForTests();
}

test "feature_flags: test overrides enable flag irrespective of env" {
    resetAll();
    // Ensure env var absence path (cannot unset env reliably in sandbox, rely on default false)
    try testing.expect(!flags_mod.global().tde.enabled());
    flags_mod.global().tde.enableForTests();
    try testing.expect(flags_mod.global().tde.enabled());
    flags_mod.global().tde.disableForTests();
    try testing.expect(!flags_mod.global().tde.enabled());
}

test "feature_flags: independent flags do not interfere" {
    resetAll();
    flags_mod.global().mfa.enableForTests();
    try testing.expect(flags_mod.global().mfa.enabled());
    try testing.expect(!flags_mod.global().adv_fts.enabled());
    flags_mod.global().adv_fts.enableForTests();
    try testing.expect(flags_mod.global().adv_fts.enabled());
    flags_mod.global().mfa.disableForTests();
    try testing.expect(!flags_mod.global().mfa.enabled());
    try testing.expect(flags_mod.global().adv_fts.enabled());
}
