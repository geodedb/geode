const std = @import("std");
const geode = @import("geode");
const raft_persistent = geode.distributed.raft_persistent;

test "Raft persistence: open, write term, read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_state", .{sub});
    defer std.testing.allocator.free(path);

    // Create a Raft node, set term, and close (deinit persists state)
    {
        var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
        node.current_term = 42;
        node.deinit();
    }

    // Reopen and verify term was persisted
    {
        var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
        defer node.deinit();
        try std.testing.expectEqual(@as(u64, 42), node.current_term);
    }
}

test "Raft persistence: add and remove members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_members", .{sub});
    defer std.testing.allocator.free(path);

    var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
    defer node.deinit();

    // Add members
    try node.raftAddMember(1, "node1:5000");
    try node.raftAddMember(2, "node2:5000");
    try node.raftAddMember(3, "node3:5000");

    try std.testing.expectEqual(@as(usize, 3), node.cluster.members.items.len);
    try std.testing.expectEqual(@as(u32, 1), node.cluster.members.items[0].id);
    try std.testing.expectEqual(@as(u32, 2), node.cluster.members.items[1].id);
    try std.testing.expectEqual(@as(u32, 3), node.cluster.members.items[2].id);

    // Remove member 2
    node.raftRemoveMember(2);
    try std.testing.expectEqual(@as(usize, 2), node.cluster.members.items.len);
    try std.testing.expectEqual(@as(u32, 1), node.cluster.members.items[0].id);
    try std.testing.expectEqual(@as(u32, 3), node.cluster.members.items[1].id);
}

test "Raft persistence: create snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_snap", .{sub});
    defer std.testing.allocator.free(path);

    var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
    defer node.deinit();

    node.current_term = 5;
    node.commit_index = 10;

    // Before snapshot
    try std.testing.expect(node.snapshot == null);

    // Create snapshot
    try node.createSnapshot();

    // Verify snapshot captures current state
    try std.testing.expect(node.snapshot != null);
    const snap = node.snapshot.?;
    try std.testing.expectEqual(@as(u64, 10), snap.last_included_index);
    try std.testing.expectEqual(@as(u64, 5), snap.last_included_term);
}

test "Raft persistence: initial state is follower with term 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_init", .{sub});
    defer std.testing.allocator.free(path);

    var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
    defer node.deinit();

    try std.testing.expectEqual(raft_persistent.RaftNode.State.follower, node.state);
    try std.testing.expectEqual(@as(u64, 0), node.current_term);
    try std.testing.expect(node.voted_for == null);
    try std.testing.expectEqual(@as(u64, 0), node.commit_index);
    try std.testing.expectEqual(@as(u64, 0), node.last_applied);
    try std.testing.expectEqual(@as(usize, 0), node.cluster.members.items.len);
    try std.testing.expect(node.snapshot == null);
}

test "Raft persistence: member voting flag defaults to true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_vote", .{sub});
    defer std.testing.allocator.free(path);

    var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
    defer node.deinit();

    try node.raftAddMember(4, "node4:6000");
    try std.testing.expect(node.cluster.members.items[0].voting);
}
