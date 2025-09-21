const std = @import("std");

// WAL Queue Depth Instrumentation Stub
// This module provides a minimal, thread-safe (atomic) queue depth counter and
// lightweight sampler used by variance benchmarks (e.g., WALPageFlushQueueDepthVarianceEnvelope)
// until real flush scheduler integration lands.
//
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Page Flush Queue Depth"; ASPECT=QueueDepthInstrumentation; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_028_WALPageFlushQueueDepthInstrumentation; BENCH=BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21
// Rationale: We intentionally register as IMPL to avoid counting toward BENCHED/TESTED
// until an actual test lands (future slice). The existing variance bench uses an
// internal model rather than this stub. When real integration occurs, tests will
// promote this aspect.

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

test "queue depth basic increment/decrement" {
    var qd: QueueDepth = .{};
    qd.inc();
    qd.inc();
    try std.testing.expectEqual(@as(u32, 2), qd.sample().depth);
    qd.dec();
    try std.testing.expectEqual(@as(u32, 1), qd.sample().depth);
    const s = qd.sample();
    try std.testing.expect(s.max >= 2);
}
