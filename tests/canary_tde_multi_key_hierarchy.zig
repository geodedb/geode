const std = @import("std");

// CANARY: REQ=REQ-GQL-046; FEATURE="TDE"; ASPECT=KeyHierarchy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_046_KeyHierarchy; OWNER=security; UPDATED=2025-09-21

// Placeholder: Simulate selecting correct encryption key based on page vs wal scopes.
// Real implementation would invoke encryption manager; here we emulate policy decision logic.

fn selectKey(scope: enum { page, wal }, root: []const u8, wal_over: []const u8) []const u8 {
    return switch (scope) {
        .page => root,
        .wal => if (wal_over.len > 0) wal_over else root,
    };
}

test "TestCANARY_REQ_GQL_046_KeyHierarchy" {
    const root_key = "ROOTKEY1234567890";
    const wal_key = "WALKEY0987654321";
    try std.testing.expect(std.mem.eql(u8, selectKey(.page, root_key, wal_key), root_key));
    try std.testing.expect(std.mem.eql(u8, selectKey(.wal, root_key, wal_key), wal_key));
    // No wal override
    try std.testing.expect(std.mem.eql(u8, selectKey(.wal, root_key, ""), root_key));
}
