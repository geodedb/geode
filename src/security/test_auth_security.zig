const std = @import("std");

// CANARY: REQ=REQ-GAP-0481-NO-PASSWORD-HINT-LOG; FEATURE="AuthSecurity"; ASPECT=SecurityAudit; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

test "geode_auth_lib: no password_hint in structured log (GAP-0481)" {
    const src = @embedFile("geode_auth_lib.zig");
    // Must NOT log any portion of the password as a structured attribute
    const has_hint = std.mem.indexOf(u8, src, "Attr.string(\"password_hint\"") != null;
    try std.testing.expect(!has_hint);
}
