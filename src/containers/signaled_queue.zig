const std = @import("std");

// SignaledQueue: a simple thread-safe FIFO queue with condition variable signaling.
// Multiple producers and consumers supported. Dequeue can block until an element arrives or until the queue is closed.
// Uses std.Thread.Mutex and std.Thread.Condition for synchronization.
//
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueue; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_068_SignaledQueue; OWNER=graph; UPDATED=2025-09-23
pub fn SignaledQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        q: std.ArrayListUnmanaged(T) = .{},
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.q.items.len > 0) self.q.clearAndFree(self.allocator);
            self.closed = true;
            self.cv.broadcast();
        }

        pub fn close(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.closed = true;
            self.cv.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.closed;
        }

        pub fn len(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.q.items.len;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.q.items.len == 0;
        }

        pub fn enqueue(self: *Self, value: T) !void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return error.Closed;
            try self.q.append(self.allocator, value);
            self.cv.signal();
        }

        // Try to dequeue without blocking; returns null when empty and not closed.
        // If closed and empty, returns error.Closed to distinguish shutdown.
        pub fn tryDequeue(self: *Self) !?T {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.q.items.len > 0) {
                return self.q.orderedRemove(0);
            }
            if (self.closed) return error.Closed;
            return null;
        }

        // Blocking dequeue: waits until an item is available or queue is closed.
        // Returns null only if spurious wake without data and not closed (should be rare); callers typically loop.
        pub fn dequeue(self: *Self) !?T {
            self.mu.lock();
            defer self.mu.unlock();
            while (self.q.items.len == 0 and !self.closed) {
                self.cv.wait(&self.mu);
            }
            if (self.q.items.len > 0) return self.q.orderedRemove(0);
            if (self.closed) return error.Closed;
            return null;
        }
    };
}
