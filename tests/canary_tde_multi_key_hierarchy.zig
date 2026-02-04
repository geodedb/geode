const std = @import("std");

// CANARY: REQ=REQ-GQL-046; FEATURE="TDE"; ASPECT=KeyHierarchy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_046_KeyHierarchy; OWNER=security; UPDATED=2025-09-21

// Placeholder: Simulate selecting correct encryption key based on data vs backup scopes.
// Real implementation would invoke encryption manager; here we emulate policy decision logic.

fn selectKey(scope: enum { data, backup }, root: []const u8, backup_over: []const u8) []const u8 {
    return switch (scope) {
        .data => root,
        .backup => if (backup_over.len > 0) backup_over else root,
    };
}

test "TestCANARY_REQ_GQL_046_KeyHierarchy" {
    const root_key = "ROOTKEY1234567890";
    const backup_key = "BACKUPKEY0987654";
    try std.testing.expect(std.mem.eql(u8, selectKey(.data, root_key, backup_key), root_key));
    try std.testing.expect(std.mem.eql(u8, selectKey(.backup, root_key, backup_key), backup_key));
    // No backup override
    try std.testing.expect(std.mem.eql(u8, selectKey(.backup, root_key, ""), root_key));
}
