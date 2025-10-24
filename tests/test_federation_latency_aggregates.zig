const std = @import("std");
const agg = @import("distributed/federation_latency_aggregate.zig");
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Archive; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyArchive; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Summary; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencySummary; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=MultiRun; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyMultiRun; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=RobustStats; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyRobustStats; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=SchemaValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencySchemaValidation; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Streak; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyStreak; OWNER=federation; UPDATED=2025-09-26

fn recordSamples(count: usize, mismatch_every: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const miss = (mismatch_every != 0) and (i % mismatch_every == 0);
        agg.recordLatency(100 + @as(u64, @intCast(i)), miss);
    }
}

test "TestCANARY_REQ_GQL_024_FedLatencyMultiRun" {
    agg.resetAll();
    recordSamples(20, 3); // cycle 0
    _ = agg.finalizeCycle();
    recordSamples(15, 4); // cycle 1
    const snap = agg.finalizeCycle();
    try std.testing.expect(snap.cycle_id == 1);
    try std.testing.expect(agg.archiveLen() == 2);
}

test "TestCANARY_REQ_GQL_024_FedLatencyArchive" {
    agg.resetAll();
    var c: usize = 0;
    while (c < 5) : (c += 1) {
        recordSamples(10, 2);
        _ = agg.finalizeCycle();
    }
    try std.testing.expect(agg.archiveLen() == 5);
    const any = agg.findSnapshot(2) orelse return error.TestExpectedEqual;
    try std.testing.expect(any.count > 0);
}

test "TestCANARY_REQ_GQL_024_FedLatencySummary" {
    agg.resetAll();
    recordSamples(8, 2);
    const snap = agg.snapshotCurrent();
    try std.testing.expect(snap.count == 8);
    try std.testing.expect(snap.max_ns >= snap.min_ns);
}

test "TestCANARY_REQ_GQL_024_FedLatencyRobustStats" {
    agg.resetAll();
    // Create variance by alternating values
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const val: u64 = if ((i % 2) == 0) 100 else 1000;
        agg.recordLatency(val, true);
    }
    const snap = agg.snapshotCurrent();
    try std.testing.expect(snap.p95_ns >= snap.min_ns and snap.p95_ns <= snap.max_ns);
}

test "TestCANARY_REQ_GQL_024_FedLatencySchemaValidation" {
    agg.resetAll();
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        recordSamples(12, 3);
        _ = agg.finalizeCycle();
    }
    try std.testing.expect(agg.schemaValidate());
}

test "TestCANARY_REQ_GQL_024_FedLatencyStreak" {
    agg.resetAll();
    // Mismatch every sample first cycle => streak grows
    recordSamples(5, 1);
    const s0 = agg.snapshotCurrent();
    try std.testing.expect(s0.streak == 5);
    // Next cycle with no mismatches resets streak
    _ = agg.finalizeCycle();
    recordSamples(4, 0); // no mismatches
    const s1 = agg.snapshotCurrent();
    try std.testing.expect(s1.streak == 0);
}
