// CANARY: REQ=REQ-SONNY-6593-CDC-START-LIFECYCLE; FEATURE="CDCControl"; ASPECT=StartRecordedOnSuccessOnly; STATUS=TESTED; TEST=tests/test_sonny6593_cdc_start_lifecycle.zig; OWNER=cdc; UPDATED=2026-11-15
//
// SONNY-6593 item 3: `CDCEngine.start()` appended its `.start` lifecycle
// event before it created the worker pool, so a start that then failed
// left a `.start` record for an engine that never ran.
//
// Strategy: fail allocation n = 0, 1, 2, ... (std.testing.FailingAllocator
// fails allocation n only) of a real engine until a start runs with no
// failure induced. Every start that fails must leave the engine stopped
// with no `.start` event; the one that succeeds records exactly one.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const cdc = geode.streaming.cdc_enhanced;

const config: cdc.CDCConfig = .{ .enabled = true, .batch_size = 100, .flush_interval_ms = 1000 };

fn countStarts(engine: *cdc.CDCEngine) usize {
    var n: usize = 0;
    for (engine.diag_events.items) |e| {
        if (e == .start) n += 1;
    }
    return n;
}

test "SONNY-6593 (3): a CDC start that fails records no start event" {
    var failed_starts: usize = 0;
    var clean = false;
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        var engine = cdc.CDCEngine.init(failing.allocator(), config) catch continue;
        defer engine.deinit();
        if (engine.start()) |_| {
            if (failing.has_induced_failure) continue;
            try testing.expectEqual(@as(usize, 1), countStarts(&engine));
            clean = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(!engine.isRunning());
            if (countStarts(&engine) != 0) {
                std.debug.print("SONNY-6593 (3): start() failed at allocation {d} but recorded a start event\n", .{n});
                return error.TestUnexpectedResult;
            }
            failed_starts += 1;
        }
    }
    try testing.expect(clean);
    try testing.expect(failed_starts > 0);
}
