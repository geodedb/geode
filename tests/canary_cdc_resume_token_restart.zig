const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Resume Token Restart"; ASPECT=API; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ResumeTokenRestart; OWNER=streaming; UPDATED=2026-11-14

test "TestCANARY_REQ_GQL_042_CDC_ResumeTokenRestart" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 8 });
    defer engine.deinit();

    try engine.start();
    // Emit some events
    var i: usize = 0;
    while (i < 20) : (i += 1) try engine.emitChange(.insert, .node, @intCast(i), null, "{\"v\":1}");
    const token_before = engine.currentResumeToken();
    engine.stop();

    // Resume (start again) and emit some more
    try engine.start();
    var j: usize = 0;
    while (j < 10) : (j += 1) try engine.emitChange(.update, .node, @intCast(j), null, "{\"v\":2}");
    const token_after = engine.currentResumeToken();
    try std.testing.expect(token_after > token_before);

    // Acquire replay from previous token (should only include new events)
    const replay = try engine.replayFrom(allocator, token_before);
    defer allocator.free(replay);
    try std.testing.expect(replay.len == 10);
    // Ensure monotonic sequence strictly increasing over replay slice
    var last_seq: u64 = 0;
    for (replay) |ev| {
        try std.testing.expect(ev.sequence > token_before - 1);
        try std.testing.expect(ev.sequence > last_seq);
        last_seq = ev.sequence;
    }
}
