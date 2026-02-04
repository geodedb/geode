const std = @import("std");
const testing = std.testing;
const graph_store = @import("geode").graph_store;
const user_storage = @import("../src/storage/user_storage.zig");

// Tests for User Management with GraphStore-backed storage
// CANARY: REQ=REQ-GQL-202; FEATURE="UserManagement"; ASPECT=PersistentStorage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserManagement; OWNER=security; UPDATED=2025-10-04

test "TestCANARY_REQ_GQL_202_UserManagement" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var backend = try user_storage.UserStorageBackend.init(allocator, &store);
    defer backend.deinit();

    try backend.persistUser(
        1,
        "alice",
        "alice@example.com",
        "hashed_password_123",
        "salt",
    );

    const stored_user = backend.getUser(1);
    try testing.expect(stored_user != null);
    try testing.expectEqualStrings("alice", stored_user.?.getUsername());
    try testing.expectEqualStrings("alice@example.com", stored_user.?.getEmail());
    try testing.expectEqualStrings("hashed_password_123", stored_user.?.getPasswordHash());
}

test "user storage CRUD operations" {
    const allocator = testing.allocator;

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var backend = try user_storage.UserStorageBackend.init(allocator, &store);
    defer backend.deinit();

    // Create users
    try backend.persistUser(1, "alice", "alice@example.com", "hash1", "salt1");
    try backend.persistUser(2, "bob", "bob@example.com", "hash2", "salt2");
    try backend.persistUser(3, "charlie", "charlie@example.com", "hash3", "salt3");

    // Test getUserByUsername
    const alice = backend.getUserByUsername("alice");
    try testing.expect(alice != null);
    try testing.expect(alice.?.id == 1);

    // Update user
    try backend.updateUser(2, "bob@new.com", "hash2b", false, true, "mfa-secret");
    const bob = backend.getUser(2);
    try testing.expect(bob != null);
    try testing.expectEqualStrings("bob@new.com", bob.?.getEmail());
    try testing.expectEqualStrings("hash2b", bob.?.getPasswordHash());
    try testing.expect(bob.?.mfa_enabled);

    // Remove user
    try backend.removeUser(3);
    const charlie = backend.getUser(3);
    try testing.expect(charlie == null);
}
