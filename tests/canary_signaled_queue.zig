const std = @import("std");
const testing = std.testing;
const queue_mod = @import("../src/containers/signaled_queue.zig");

fn spawnProducer(q: *queue_mod.SignaledQueue(u32), values: []const u32) !std.Thread {
    return try std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { q: *queue_mod.SignaledQueue(u32), vals: []const u32 }) void {
            for (ctx.vals) |v| {
                // Ignore errors for test simplicity
                _ = ctx.q.enqueue(v) catch {};
            }
        }
    }.run, .{ .q = q, .vals = values });
}

// Covers: blocking dequeue wakeup, FIFO ordering, tryDequeue behavior on empty and closed.
test "TestCANARY_REQ_GQL_068_SignaledQueue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var q = queue_mod.SignaledQueue(u32).init(allocator);
    defer q.deinit();

    // Initially empty
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(?u32, null), try q.tryDequeue());

    // Spawn a producer to enqueue values
    var values = [_]u32{ 1, 2, 3, 4, 5 };
    var th = try spawnProducer(&q, &values);

    // Dequeue all with blocking
    var out = std.ArrayList(u32).init(allocator);
    defer out.deinit();
    while (out.items.len < values.len) {
        const x = try q.dequeue();
        if (x) |v| try out.append(v) else break;
    }
    th.join();

    // Verify FIFO
    try testing.expectEqual(values.len, out.items.len);
    for (values, 0..) |v, i| {
        try testing.expectEqual(v, out.items[i]);
    }

    // tryDequeue on now-empty queue -> null
    try testing.expectEqual(@as(?u32, null), try q.tryDequeue());

    // Close and verify tryDequeue and dequeue signal closure
    q.close();
    const td = q.tryDequeue();
    try testing.expectError(error.Closed, td);
    const dd = q.dequeue();
    try testing.expectError(error.Closed, dd);
}
