const std = @import("std");

// CANARY: REQ=REQ-GRAPHSTORE-QUEUE-001; FEATURE="SnapshotFlushQueueDepth"; ASPECT=Metrics; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-04
// Lightweight queue depth tracker for GraphStore flush scheduling and diagnostics.

pub const Sample = struct {
    current: u32,
    max: u32,
};

pub const QueueDepth = struct {
    current: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn inc(self: *QueueDepth) void {
        const val = self.current.fetchAdd(1, .monotonic) + 1;
        _ = self.updateMax(val);
    }

    pub fn dec(self: *QueueDepth) void {
        _ = self.current.fetchSub(1, .monotonic);
    }

    pub fn sample(self: *QueueDepth) Sample {
        return .{
            .current = self.current.load(.monotonic),
            .max = self.max.load(.monotonic),
        };
    }

    fn updateMax(self: *QueueDepth, val: u32) void {
        var cur = self.max.load(.monotonic);
        while (val > cur) {
            if (self.max.compareExchangeWeak(cur, val, .monotonic, .monotonic)) |_| break;
            cur = self.max.load(.monotonic);
        }
    }
};

pub const Sampler = struct {
    qd: *QueueDepth,

    pub fn init(qd: *QueueDepth) Sampler {
        return .{ .qd = qd };
    }

    pub fn collect(self: *Sampler, out: []Sample) usize {
        const s = self.qd.sample();
        for (out, 0..) |*slot, _| slot.* = s;
        return out.len;
    }
};
