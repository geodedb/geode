const std = @import("std");
const agg = @import("src/distributed/federation_latency_aggregate.zig");
const fed_flag = @import("src/distributed/federation_flag.zig");

fn simulateCycle(latencies: []const u64, mismatch_every: u64) void {
    var i: usize = 0;
    while (i < latencies.len) : (i += 1) {
        const mismatch = (mismatch_every != 0 and (@as(u64, @intCast(i)) % mismatch_every) == 0);
        agg.recordLatency(latencies[i], mismatch);
    }
    _ = agg.finalizeCycle();
}

// Archive test: ensure snapshots accumulate up to ring size and wrap.
test "TestCANARY_REQ_GQL_024_FedLatencyArchive" {
    agg.resetAll();
    var latencies: [8]u64 = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    var c: usize = 0;
    while (c < 20) : (c += 1) simulateCycle(&latencies, 2);
    try std.testing.expect(agg.archiveLen() == 16); // ring capacity
}

// Summary test: verify mean/p95 fields plausible (p95 within range; mean between min/max).
test "TestCANARY_REQ_GQL_024_FedLatencySummary" {
    agg.resetAll();
    const latencies = [_]u64{ 5, 6, 7, 8, 9, 10 };
    simulateCycle(&latencies, 1);
    const snap = agg.findSnapshot(0) orelse return error.TestExpectedFound;
    try std.testing.expect(snap.mean_ns >= 5 and snap.mean_ns <= 10);
    try std.testing.expect(snap.p95_ns >= snap.min_ns and snap.p95_ns <= snap.max_ns);
}

// MultiRun test: ensure multiple cycles produce monotonically increasing cycle_id.
test "TestCANARY_REQ_GQL_024_FedLatencyMultiRun" {
    agg.resetAll();
    const latencies = [_]u64{ 1, 2, 3 };
    simulateCycle(&latencies, 1);
    simulateCycle(&latencies, 1);
    const s0 = agg.findSnapshot(0) orelse return error.TestExpectedFound;
    const s1 = agg.findSnapshot(1) orelse return error.TestExpectedFound;
    try std.testing.expect(s1.cycle_id > s0.cycle_id);
}

// RobustStats test: record variable latencies including outliers; ensure p95 >= mean.
test "TestCANARY_REQ_GQL_024_FedLatencyRobustStats" {
    agg.resetAll();
    const latencies = [_]u64{ 1, 1, 1, 1, 50, 60, 70, 80, 90, 100 };
    simulateCycle(&latencies, 2);
    const s = agg.findSnapshot(0) orelse return error.TestExpectedFound;
    try std.testing.expect(@as(f128, s.p95_ns) >= s.mean_ns);
}

// SchemaValidation test: confirm invariants hold across archive.
test "TestCANARY_REQ_GQL_024_FedLatencySchemaValidation" {
    agg.resetAll();
    var latencies: [4]u64 = .{ 3, 4, 5, 6 };
    var c: usize = 0;
    while (c < 6) : (c += 1) simulateCycle(&latencies, 1);
    try std.testing.expect(agg.schemaValidate());
}

// Streak test: mismatch streak increments only when mismatch=true consecutive cycles.
test "TestCANARY_REQ_GQL_024_FedLatencyStreak" {
    agg.resetAll();
    fed_flag.g_last_federation_mismatch = false;
    const lat = [_]u64{ 1, 2, 3 };
    simulateCycle(&lat, 0); // no mismatches streak=0
    const s0 = agg.findSnapshot(0) orelse return error.TestExpectedFound;
    try std.testing.expectEqual(@as(u64, 0), s0.streak);
    simulateCycle(&lat, 1); // mismatch events (every sample) streak increments
    const s1 = agg.findSnapshot(1) orelse return error.TestExpectedFound;
    try std.testing.expect(s1.streak > s0.streak);
}
