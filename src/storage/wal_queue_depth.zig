const std = @import("std");

// WAL Queue Depth Instrumentation Stub
// This module provides a minimal, thread-safe (atomic) queue depth counter and
// lightweight sampler used by variance benchmarks (e.g., WALPageFlushQueueDepthVarianceEnvelope)
// until real flush scheduler integration lands.
//
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Page Flush Queue Depth"; ASPECT=QueueDepthInstrumentation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_WALPageFlushQueueDepthInstrumentation; BENCH=BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21
// Instrumentation provides atomic depth tracking + max observed watermark and sampler.
// Future integration: real flush scheduler will call inc/dec around enqueue/dequeue events.

pub const QueueDepth = struct {
    depth: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_observed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn inc(self: *QueueDepth) void {
        const new = self.depth.fetchAdd(1, .SeqCst) + 1;
        // Track max observed depth (relaxed acceptable — eventual visibility fine).
        var cur_max = self.max_observed.load(.Relaxed);
        while (new > cur_max) {
            if (self.max_observed.cmpxchgWeak(cur_max, new, .Relaxed, .Relaxed)) |old| {
                cur_max = old; // retry with updated value
            } else break;
        }
    }

    pub fn dec(self: *QueueDepth) void {
        _ = self.depth.fetchSub(1, .SeqCst);
    }

    pub fn sample(self: *QueueDepth) Sample {
        return Sample{ .depth = self.depth.load(.Acquire), .max = self.max_observed.load(.Relaxed) };
    }
};

pub const Sample = struct {
    depth: u32,
    max: u32,
};

pub const Sampler = struct {
    qd: *QueueDepth,

    pub fn init(qd: *QueueDepth) Sampler {
        return Sampler{ .qd = qd };
    }

    pub fn collect(self: *Sampler, buf: []Sample) usize {
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            buf[i] = self.qd.sample();
        }
        return i;
    }
};

test "TestCANARY_REQ_GQL_028_WALPageFlushQueueDepthInstrumentation" {
    var qd: QueueDepth = .{};
    // Simulate burst enqueue
    var i: usize = 0;
    while (i < 16) : (i += 1) qd.inc();
    try std.testing.expectEqual(@as(u32, 16), qd.sample().depth);
    // Dequeue half
    var j: usize = 0;
    while (j < 8) : (j += 1) qd.dec();
    const s_mid = qd.sample();
    try std.testing.expectEqual(@as(u32, 8), s_mid.depth);
    // Ensure max observed tracked original burst
    try std.testing.expect(s_mid.max >= 16);
    // Stress sampler collection
    var buf: [5]Sample = undefined;
    var sampler = Sampler.init(&qd);
    const collected = sampler.collect(&buf);
    try std.testing.expectEqual(@as(usize, buf.len), collected);
    for (buf) |s| {
        try std.testing.expect(s.depth <= s.max);
        try std.testing.expect(s.max >= 16);
    }
}
