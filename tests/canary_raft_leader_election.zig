const std = @import("std");
const raft_mod = @import("../src/distributed/raft.zig");
// TestCANARY_REQ_GQL_040_RaftLeaderElection
// 3-node in-memory cluster; we manually drive election by invoking tick and injecting vote responses.

fn dummySend(_: []const u8, _: raft_mod.MessageType, _: []const u8) void {}
fn dummyApply(_: []const u8) void {}

test "TestCANARY_REQ_GQL_040_RaftLeaderElection" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const peers = [_][]const u8{ "n2", "n3" };
    var n1 = try raft_mod.RaftNode.init(allocator, .{ .node_id = "n1", .peers = &peers, .election_timeout_min_ms = 10, .election_timeout_max_ms = 20 });
    defer n1.deinit();
    n1.enableFeatures(true, false);
    n1.setApplyCallback(dummyApply);
    n1.setSendMessageCallback(dummySend);
    try n1.start();

    // Force immediate election attempt
    try n1.startElection();
    try std.testing.expect(n1.state == .candidate);

    // Simulate two vote responses granting vote (including self already 1)
    const resp = raft_mod.RequestVoteResponse{ .term = n1.current_term, .vote_granted = true };
    const payload = try std.json.stringifyAlloc(allocator, resp, .{});
    defer allocator.free(payload);
    try n1.handleMessage("n2", .request_vote_response, payload);
    try n1.handleMessage("n3", .request_vote_response, payload);

    // Should now be leader
    try std.testing.expect(n1.state == .leader);
    const info = n1.getLeaderInfo();
    try std.testing.expect(info.is_leader);
}
