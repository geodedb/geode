// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const cache_line = 64;

/// Lock-free bounded multi-producer multi-consumer queue.
///
/// Implements the Dmitry Vyukov bounded MPMC queue algorithm using per-slot
/// sequence counters for correct synchronization without TOCTOU races.
///
/// `capacity` must be a power of two.
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
    }

    const mask: usize = capacity - 1;

    return struct {
        const Self = @This();

        /// Each slot is padded to a full cache line to prevent false sharing
        /// between adjacent slots under concurrent producer/consumer access.
        const Slot = struct {
            sequence: std.atomic.Value(usize) align(cache_line),
            data: T = undefined,
        };

        // head and tail are on separate cache lines to prevent false sharing
        // between producers and consumers. buffer follows with its own
        // alignment to avoid sharing a cache line with tail.
        head: std.atomic.Value(usize) align(cache_line),
        tail: std.atomic.Value(usize) align(cache_line),
        buffer: [capacity]Slot align(cache_line),

        /// Create a new empty queue. Each slot's sequence counter is
        /// initialized to its index so that the first `capacity` pushes
        /// find their slots immediately available.
        pub fn init() Self {
            var self: Self = undefined;
            for (&self.buffer, 0..) |*slot, i| {
                slot.* = Slot{ .sequence = std.atomic.Value(usize).init(i) };
            }
            self.head = std.atomic.Value(usize).init(0);
            self.tail = std.atomic.Value(usize).init(0);
            return self;
        }

        /// Try to push an item to the queue (non-blocking).
        /// Returns true if successful, false if the queue is full.
        pub fn tryPush(self: *Self, item: T) bool {
            var pos = self.tail.load(.monotonic);
            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);
                const diff: isize = @bitCast(seq -% pos);

                if (diff == 0) {
                    // Slot is available; try to claim it via CAS.
                    if (self.tail.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |updated| {
                        pos = updated;
                        continue;
                    }
                    // CAS succeeded: write data and publish.
                    slot.data = item;
                    slot.sequence.store(pos +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    // Queue is full.
                    return false;
                } else {
                    // Another producer claimed this slot; reload.
                    pos = self.tail.load(.monotonic);
                }
            }
        }

        /// Try to pop an item from the queue (non-blocking).
        /// Returns the item if available, null if the queue is empty.
        pub fn tryPop(self: *Self) ?T {
            var pos = self.head.load(.monotonic);
            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);
                const diff: isize = @bitCast(seq -% (pos +% 1));

                if (diff == 0) {
                    // Slot has data; try to claim it via CAS.
                    if (self.head.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |updated| {
                        pos = updated;
                        continue;
                    }
                    // CAS succeeded: read data and release slot for reuse.
                    const item = slot.data;
                    slot.sequence.store(pos +% mask +% 1, .release);
                    return item;
                } else if (diff < 0) {
                    // Queue is empty.
                    return null;
                } else {
                    // Another consumer claimed this slot; reload.
                    pos = self.head.load(.monotonic);
                }
            }
        }

        /// Approximate number of items in the queue.
        /// This is a snapshot of two independent atomics and may be
        /// momentarily inconsistent under concurrent access.
        pub fn len(self: *Self) usize {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.monotonic);
            return tail -% head;
        }

        /// Check if queue is empty (approximate).
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }

        /// Check if queue is full (approximate).
        pub fn isFull(self: *Self) bool {
            return self.len() >= capacity;
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "BoundedQueue: basic push and pop" {
    var queue = BoundedQueue(u32, 8).init();

    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    try std.testing.expectEqual(@as(?u32, 1), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 3), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());
}

test "BoundedQueue: full queue rejects push" {
    var queue = BoundedQueue(u32, 4).init();

    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));
    try std.testing.expect(queue.tryPush(4));

    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.tryPush(5));

    // Pop one and push should succeed.
    _ = queue.tryPop();
    try std.testing.expect(queue.tryPush(5));
}

test "BoundedQueue: empty queue returns null" {
    var queue = BoundedQueue(u32, 4).init();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());
}

test "BoundedQueue: len tracks size correctly" {
    var queue = BoundedQueue(u32, 8).init();

    try std.testing.expectEqual(@as(usize, 0), queue.len());
    _ = queue.tryPush(10);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    _ = queue.tryPush(20);
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    _ = queue.tryPop();
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    _ = queue.tryPop();
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "BoundedQueue: works with struct payloads" {
    const Item = struct { id: u32, value: u64 };
    var queue = BoundedQueue(Item, 4).init();

    try std.testing.expect(queue.tryPush(.{ .id = 1, .value = 100 }));
    try std.testing.expect(queue.tryPush(.{ .id = 2, .value = 200 }));

    const first = queue.tryPop().?;
    try std.testing.expectEqual(@as(u32, 1), first.id);
    try std.testing.expectEqual(@as(u64, 100), first.value);
}

test "BoundedQueue: wraparound correctness" {
    var queue = BoundedQueue(u32, 4).init();

    // Fill and drain multiple times to exercise wraparound.
    for (0..8) |round| {
        const base: u32 = @intCast(round * 4);
        try std.testing.expect(queue.tryPush(base + 1));
        try std.testing.expect(queue.tryPush(base + 2));
        try std.testing.expect(queue.tryPush(base + 3));
        try std.testing.expect(queue.tryPush(base + 4));
        try std.testing.expect(queue.isFull());

        try std.testing.expectEqual(@as(?u32, base + 1), queue.tryPop());
        try std.testing.expectEqual(@as(?u32, base + 2), queue.tryPop());
        try std.testing.expectEqual(@as(?u32, base + 3), queue.tryPop());
        try std.testing.expectEqual(@as(?u32, base + 4), queue.tryPop());
        try std.testing.expect(queue.isEmpty());
    }
}

test "BoundedQueue: concurrent MPMC correctness" {
    const num_producers = 4;
    const num_consumers = 4;
    const items_per_thread = 2000;

    const Queue = BoundedQueue(u64, 256);
    var queue = Queue.init();

    // Each consumer accumulates a local sum.
    var consumer_sums: [num_consumers]std.atomic.Value(u64) = undefined;
    var consumer_counts: [num_consumers]std.atomic.Value(u64) = undefined;
    for (&consumer_sums) |*s| s.* = std.atomic.Value(u64).init(0);
    for (&consumer_counts) |*c| c.* = std.atomic.Value(u64).init(0);

    var done = std.atomic.Value(bool).init(false);

    // Spawn consumers.
    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(q: *Queue, sums: *[num_consumers]std.atomic.Value(u64), counts: *[num_consumers]std.atomic.Value(u64), finished: *std.atomic.Value(bool), idx: usize) void {
                var local_sum: u64 = 0;
                var local_count: u64 = 0;
                while (true) {
                    if (q.tryPop()) |val| {
                        local_sum += val;
                        local_count += 1;
                    } else if (finished.load(.acquire)) {
                        // Drain remaining.
                        while (q.tryPop()) |val| {
                            local_sum += val;
                            local_count += 1;
                        }
                        break;
                    } else {
                        std.Thread.yield() catch {};
                    }
                }
                sums[idx].store(local_sum, .release);
                counts[idx].store(local_count, .release);
            }
        }.run, .{ &queue, &consumer_sums, &consumer_counts, &done, i });
    }

    // Spawn producers.
    var producers: [num_producers]std.Thread = undefined;
    for (&producers, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(q: *Queue, producer_id: usize) void {
                const base: u64 = @intCast(producer_id * items_per_thread + 1);
                for (0..items_per_thread) |j| {
                    while (!q.tryPush(base + @as(u64, @intCast(j)))) {
                        std.Thread.yield() catch {};
                    }
                }
            }
        }.run, .{ &queue, id });
    }

    // Wait for producers.
    for (&producers) |t| t.join();
    done.store(true, .release);

    // Wait for consumers.
    for (&consumers) |t| t.join();

    // Verify totals.
    var total_count: u64 = 0;
    var total_sum: u64 = 0;
    for (&consumer_counts) |*c| total_count += c.load(.acquire);
    for (&consumer_sums) |*s| total_sum += s.load(.acquire);

    const expected_count: u64 = num_producers * items_per_thread;
    try std.testing.expectEqual(expected_count, total_count);

    // Expected sum: each producer pushes base+0 .. base+(N-1).
    var expected_sum: u64 = 0;
    for (0..num_producers) |id| {
        const base: u64 = @intCast(id * items_per_thread + 1);
        for (0..items_per_thread) |j| {
            expected_sum += base + @as(u64, @intCast(j));
        }
    }
    try std.testing.expectEqual(expected_sum, total_sum);
}
