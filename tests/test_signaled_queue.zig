const std = @import("std");
const queue_mod = @import("../src/containers/signaled_queue.zig");

test "TestCANARY_REQ_GQL_068_SignaledQueueBasicEnqueueDequeue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var q = queue_mod.SignaledQueue(u32).init(alloc);
    defer q.deinit();

    try q.enqueue(42);
    const v = try q.dequeue();
    try std.testing.expectEqual(@as(?u32, 42), v);
}

test "TestCANARY_REQ_GQL_068_SignaledQueueCloseSignalsConsumers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var q = queue_mod.SignaledQueue(u8).init(alloc);
    defer q.deinit();

    var th = std.Thread.spawn(.{}, struct {
        fn run(ctx: *queue_mod.SignaledQueue(u8)) void {
            // Should return error.Closed when closed and empty
            const r = ctx.dequeue();
            switch (r) {
                error.Closed => return,
                else => |_| return,
            }
        }
    }.run, .{&q}) catch unreachable;

    // Allow thread to start waiting.
    std.Thread.sleep(100_000);
    q.close();
    th.join();
    try std.testing.expect(q.isClosed());
}
