const std = @import("std");

// SignaledQueue: a simple thread-safe FIFO queue with condition variable signaling.
// Multiple producers and consumers supported. Dequeue can block until an element arrives or until the queue is closed.
// Uses std.Io.Mutex and std.Io.Condition for synchronization.
//
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueue; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_068_SignaledQueue; OWNER=graph; UPDATED=2025-09-23
pub fn SignaledQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mu: std.Io.Mutex = std.Io.Mutex.init,
        cv: std.Io.Condition = std.Io.Condition.init,
        q: std.ArrayListUnmanaged(T) = .{},
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            if (self.q.items.len > 0) self.q.clearAndFree(self.allocator);
            self.closed = true;
            self.cv.broadcast(std.Io.Threaded.global_single_threaded.io());
        }

        pub fn close(self: *Self) void {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            self.closed = true;
            self.cv.broadcast(std.Io.Threaded.global_single_threaded.io());
        }

        pub fn isClosed(self: *Self) bool {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            return self.closed;
        }

        pub fn len(self: *Self) usize {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            return self.q.items.len;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            return self.q.items.len == 0;
        }

        pub fn enqueue(self: *Self, value: T) !void {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            if (self.closed) return error.Closed;
            try self.q.append(self.allocator, value);
            self.cv.signal(std.Io.Threaded.global_single_threaded.io());
        }

        // Try to dequeue without blocking; returns null when empty and not closed.
        // If closed and empty, returns error.Closed to distinguish shutdown.
        pub fn tryDequeue(self: *Self) !?T {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            if (self.q.items.len > 0) {
                return self.q.orderedRemove(0);
            }
            if (self.closed) return error.Closed;
            return null;
        }

        // Blocking dequeue: waits until an item is available or queue is closed.
        // Returns null only if spurious wake without data and not closed (should be rare); callers typically loop.
        pub fn dequeue(self: *Self) !?T {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            while (self.q.items.len == 0 and !self.closed) {
                self.cv.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &self.mu);
            }
            if (self.q.items.len > 0) return self.q.orderedRemove(0);
            if (self.closed) return error.Closed;
            return null;
        }
    };
}

// ==================== Unit Tests (GAP-0239) ====================
// CANARY: REQ=REQ-GAP-0239; FEATURE="ContainerUnitTests"; ASPECT=SignaledQueue; STATUS=TESTED; TEST=test_signaled_queue_basic; OWNER=containers; UPDATED=2026-01-25

test "SignaledQueue init and basic state" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isClosed());
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "SignaledQueue enqueue and tryDequeue" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(10);
    try queue.enqueue(20);
    try queue.enqueue(30);

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    const v1 = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, 10), v1);

    const v2 = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, 20), v2);

    const v3 = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, 30), v3);

    try std.testing.expect(queue.isEmpty());
}

test "SignaledQueue tryDequeue returns null when empty" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    const result = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, null), result);
}

test "SignaledQueue close prevents enqueue" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    queue.close();
    try std.testing.expect(queue.isClosed());

    const result = queue.enqueue(42);
    try std.testing.expectError(error.Closed, result);
}

test "SignaledQueue tryDequeue returns error.Closed when closed and empty" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    queue.close();
    const result = queue.tryDequeue();
    try std.testing.expectError(error.Closed, result);
}

test "SignaledQueue FIFO ordering" {
    var queue = SignaledQueue(u8).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue('a');
    try queue.enqueue('b');
    try queue.enqueue('c');

    try std.testing.expectEqual(@as(?u8, 'a'), try queue.tryDequeue());
    try std.testing.expectEqual(@as(?u8, 'b'), try queue.tryDequeue());
    try std.testing.expectEqual(@as(?u8, 'c'), try queue.tryDequeue());
}

test "SignaledQueue with struct type" {
    const Message = struct { id: u32, data: i32 };
    var queue = SignaledQueue(Message).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(.{ .id = 1, .data = 100 });
    try queue.enqueue(.{ .id = 2, .data = 200 });

    const m1 = (try queue.tryDequeue()).?;
    try std.testing.expectEqual(@as(u32, 1), m1.id);

    const m2 = (try queue.tryDequeue()).?;
    try std.testing.expectEqual(@as(u32, 2), m2.id);
}

test "SignaledQueue many elements" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    // Enqueue many elements
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try queue.enqueue(i);
    }

    try std.testing.expectEqual(@as(usize, 100), queue.len());

    // Dequeue all
    i = 0;
    while (i < 100) : (i += 1) {
        const v = try queue.tryDequeue();
        try std.testing.expectEqual(@as(?i32, i), v);
    }

    try std.testing.expect(queue.isEmpty());
}

test "SignaledQueue interleaved enqueue dequeue" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try std.testing.expectEqual(@as(?i32, 1), try queue.tryDequeue());

    try queue.enqueue(2);
    try queue.enqueue(3);
    try std.testing.expectEqual(@as(?i32, 2), try queue.tryDequeue());

    try queue.enqueue(4);
    try std.testing.expectEqual(@as(?i32, 3), try queue.tryDequeue());
    try std.testing.expectEqual(@as(?i32, 4), try queue.tryDequeue());
}

test "SignaledQueue can dequeue existing items after close" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(10);
    try queue.enqueue(20);
    queue.close();

    // Should still be able to get existing items
    const v1 = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, 10), v1);

    const v2 = try queue.tryDequeue();
    try std.testing.expectEqual(@as(?i32, 20), v2);

    // Now it's empty and closed
    const v3 = queue.tryDequeue();
    try std.testing.expectError(error.Closed, v3);
}

test "SignaledQueue len updates correctly" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try queue.enqueue(1);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    try queue.enqueue(2);
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    _ = try queue.tryDequeue();
    try std.testing.expectEqual(@as(usize, 1), queue.len());
}

test "SignaledQueue isEmpty transitions" {
    var queue = SignaledQueue(i32).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());
    try queue.enqueue(1);
    try std.testing.expect(!queue.isEmpty());
    _ = try queue.tryDequeue();
    try std.testing.expect(queue.isEmpty());
}
