// CANARY: REQ=REQ-SONNY-6593-CDC-START-LIFECYCLE; FEATURE="CDCControl"; ASPECT=StartRecordedOnSuccessOnly; STATUS=TESTED; TEST=tests/test_sonny6593_cdc_start_lifecycle.zig; OWNER=cdc; UPDATED=2026-11-15
//
// SONNY-6593 item 3: `CDCEngine.start()` appended its `.start` lifecycle
// event before it created the worker pool, so a start that then failed
// left a `.start` record for an engine that never ran.
//
// Strategy: std.testing.FailingAllocator fails allocation n and every one
// after it. With k the allocations CDCEngine.init makes, start() is run
// failing from k (its first allocation) and from k + 1 (its second): before
// the fix the lifecycle record was allocation k, so failing from k + 1 let
// it be recorded and then failed the worker pool. Each start must fail,
// leave the engine stopped and record no start; a start that succeeds then
// records exactly one. (Failing later would fail inside thread_pool 0.2.11's
// Core.allocateStorage, which leaks; fixed in thread_pool 0.2.12, SONNY-6593
// part 1.)
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
    const k = blk: {
        var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
        var engine = try cdc.CDCEngine.init(counting.allocator(), config);
        defer engine.deinit();
        break :blk counting.alloc_index;
    };
    for ([_]usize{ k, k + 1 }) |n| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        var engine = try cdc.CDCEngine.init(failing.allocator(), config);
        defer engine.deinit();
        try testing.expectError(error.OutOfMemory, engine.start());
        try testing.expect(!engine.isRunning());
        if (countStarts(&engine) != 0) {
            std.debug.print("SONNY-6593 (3): start() failing from allocation {d} (init made {d}) recorded a start event\n", .{ n, k });
            return error.TestUnexpectedResult;
        }
    }

    var engine = try cdc.CDCEngine.init(testing.allocator, config);
    defer engine.deinit();
    try engine.start();
    try testing.expectEqual(@as(usize, 1), countStarts(&engine));
    // diagnosticsLifecycle (it called std.mem.copy, gone in Zig 0.16).
    const events = try engine.diagnosticsLifecycle(testing.allocator);
    defer testing.allocator.free(events);
    try testing.expectEqualSlices(cdc.CDCEngine.DiagEvent, &.{.start}, events);
}
