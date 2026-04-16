const std = @import("std");
const raft_mod = @import("../distributed/raft.zig");
// BenchmarkCANARY_REQ_GQL_040_RaftElectionLatency
// Measures number of simulated ticks until leader elected over multiple trials.

fn dummySend(_: []const u8, _: raft_mod.MessageType, _: []const u8) void {}
fn dummyApply(_: []const u8) void {}

test "BenchmarkCANARY_REQ_GQL_040_RaftElectionLatency" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var prng = std.rand.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var total_ticks: u64 = 0;
    const trials: usize = 25;
    var i: usize = 0;
    while (i < trials) : (i += 1) {
        const peers = [_][]const u8{ "n2", "n3" };
        var n1 = try raft_mod.RaftNode.init(allocator, .{ .node_id = "n1", .peers = &peers, .election_timeout_min_ms = 10, .election_timeout_max_ms = 20 });
        defer n1.deinit();
        n1.enableFeatures(true, false);
        n1.setApplyCallback(dummyApply);
        n1.setSendMessageCallback(dummySend);
        try n1.start();
        // Randomize whether we trigger immediate election or wait a couple ticks
        var tick_count: u64 = 0;
        while (n1.state != .leader and tick_count < 50) : (tick_count += 1) {
            if (tick_count == 0 or rand.boolean()) {
                // attempt election start if follower
                if (n1.state == .follower) {
                    n1.startElection() catch {};
                }
            }
            // Simulate vote responses probabilistically once candidate
            if (n1.state == .candidate) {
                const resp = raft_mod.RequestVoteResponse{ .term = n1.current_term, .vote_granted = true };
                const payload = try std.json.stringifyAlloc(allocator, resp, .{});
                defer allocator.free(payload);
                _ = n1.handleMessage("n2", .request_vote_response, payload) catch {};
                _ = n1.handleMessage("n3", .request_vote_response, payload) catch {};
            }
        }
        total_ticks += tick_count;
    }
    const avg = @as(f64, @floatFromInt(total_ticks)) / @as(f64, @floatFromInt(trials));
    // Ensure average ticks reasonable (< 15 arbitrary sanity bound)
    try std.testing.expect(avg < 15.0);
    // Write a small JSON metrics artifact (stdout) to mirror other benches (not strictly required but useful)
    var bw = std.Io.bufferedWriter(std.Io.getStdErr().writer());
    const w = bw.writer();
    try w.print("{\"metric\":\"raft_election_avg_ticks\",\"value\":{d:.2}}\n", .{avg});
    try bw.flush();
}
