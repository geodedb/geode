const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Resume Token"; ASPECT=API; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ResumeToken; OWNER=streaming; UPDATED=2026-11-14

test "TestCANARY_REQ_GQL_042_CDC_ResumeToken" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 50 });
    defer engine.deinit();
    try engine.start();
    defer engine.stop();

    // Emit some events
    var i: usize = 0;
    while (i < 10) : (i += 1) try engine.emitChange(.insert, .node, @intCast(i), null, "{\"id\":1}");

    const token = engine.currentResumeToken(); // should be next seq (11)
    try std.testing.expect(token == 11);

    // Add a few more events
    while (i < 15) : (i += 1) try engine.emitChange(.update, .node, @intCast(i), null, "{\"id\":2}");

    const replay = try engine.replayFrom(allocator, token);
    defer allocator.free(replay);
    try std.testing.expect(replay.len == 5);
    // sequences should start at token (11)
    var seq_expected: u64 = token;
    for (replay) |ev| {
        try std.testing.expect(ev.sequence == seq_expected);
        seq_expected += 1;
    }
}
