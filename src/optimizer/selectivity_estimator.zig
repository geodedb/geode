const std = @import("std");

// Simple frequency sampler + adaptive feedback estimator.
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=FrequencySampler; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_084_FrequencySampler; OWNER=optimizer; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=EstimatorApi; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_084_EstimatorApi; OWNER=optimizer; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=AdaptiveFeedbackHook; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook; OWNER=optimizer; UPDATED=2026-11-14

pub const Sample = struct { hash: u64, count: u64 };

pub const FrequencySampler = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(Sample),
    max_samples: usize,
    total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_samples: usize) FrequencySampler {
        return .{ .allocator = allocator, .samples = std.ArrayList(Sample).init(allocator), .max_samples = max_samples };
    }
    pub fn deinit(self: *FrequencySampler) void {
        self.samples.deinit();
    }

    fn hashVal(val: []const u8) u64 {
        return std.hash.Wyhash.hash(0, val);
    }

    pub fn record(self: *FrequencySampler, val: []const u8) !void {
        const h = hashVal(val);
        self.total += 1;
        // Try find existing
        for (self.samples.items) |*s| {
            if (s.hash == h) {
                s.count += 1;
                return;
            }
        }
        if (self.samples.items.len < self.max_samples) {
            try self.samples.append(.{ .hash = h, .count = 1 });
        } else {
            // Reservoir-style eviction: replace a random slot with probability
            const idx: usize = @intCast(h % @as(u64, self.max_samples));
            self.samples.items[idx] = .{ .hash = h, .count = 1 };
        }
    }

    pub fn estimate(self: *const FrequencySampler, val: []const u8) f64 {
        if (self.total == 0) return 0.0;
        const h = hashVal(val);
        for (self.samples.items) |s| if (s.hash == h) return @as(f64, @floatFromInt(s.count)) / @as(f64, @floatFromInt(self.total));
        // Unseen fallback heuristic: use 1 / (total + distinct_est)
        const distinct_est = @as(f64, @floatFromInt(self.samples.items.len));
        return 1.0 / (@as(f64, @floatFromInt(self.total)) + distinct_est);
    }
};

pub const AdaptiveEstimator = struct {
    allocator: std.mem.Allocator,
    sampler: FrequencySampler,
    bias_alpha: f64 = 0.2,
    correction: f64 = 1.0,

    pub fn init(allocator: std.mem.Allocator, cap: usize) AdaptiveEstimator {
        return .{ .allocator = allocator, .sampler = FrequencySampler.init(allocator, cap) };
    }
    pub fn deinit(self: *AdaptiveEstimator) void {
        self.sampler.deinit();
    }

    pub fn observe(self: *AdaptiveEstimator, val: []const u8) !void {
        try self.sampler.record(val);
    }

    pub fn estimate(self: *AdaptiveEstimator, val: []const u8) f64 {
        return self.sampler.estimate(val) * self.correction;
    }

    pub fn feedback(self: *AdaptiveEstimator, val: []const u8, actual_selectivity: f64) void {
        const pred = self.estimate(val);
        if (pred <= 0) return;
        // Update correction multiplicatively toward actual/pred
        const target = actual_selectivity / pred;
        self.correction = self.correction + self.bias_alpha * (target - self.correction);
    }
};

pub const Api = struct {
    estimator: *AdaptiveEstimator,
    pub fn get(self: *Api, val: []const u8) f64 {
        return self.estimator.estimate(val);
    }
    pub fn feedback(self: *Api, val: []const u8, actual: f64) void {
        self.estimator.feedback(val, actual);
    }
};
