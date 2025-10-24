const std = @import("std");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="Aggregation COUNT DISTINCT"; ASPECT=HashAggDistinctSpillEvictVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_012_HashAggDistinctSpillEvictVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

// High-cardinality COUNT DISTINCT under forced eviction. Generates random-ish integer values per group.
// Measures insertion variance with spill+merge.

const Runs = 18;
const GroupsPerRun = 300;
const DistinctPerGroup = 40;

fn Stats(comptime N: usize) type {
    return struct {
        samples: [N]i128 = [_]i128{0} ** N,
        idx: usize = 0,
        pub fn add(self: *@This(), v: i128) void {
            self.samples[self.idx] = v;
            self.idx += 1;
        }
        pub fn finalize(self: *@This()) struct { mean: f128, cv: f128, p95: i128 } {
            var sum: f128 = 0;
            var i: usize = 0;
            while (i < self.idx) : (i += 1) sum += @as(f128, @floatFromInt(self.samples[i]));
            const mean: f128 = sum / @as(f128, @floatFromInt(self.idx));
            var var_acc: f128 = 0;
            i = 0;
            while (i < self.idx) : (i += 1) {
                const d = @as(f128, @floatFromInt(self.samples[i])) - mean;
                var_acc += d * d;
            }
            const variance = if (self.idx > 1) var_acc / @as(f128, @floatFromInt(self.idx - 1)) else 0;
            const stddev = @sqrt(variance);
            var tmp = self.samples;
            std.sort.block(i128, &tmp, {}, struct {
                fn less(_: void, a: i128, b: i128) bool {
                    return a < b;
                }
            }.less);
            const p95 = tmp[@min(self.idx - 1, (self.idx * 95) / 100)];
            const cv: f128 = if (mean == 0) 0 else stddev / mean;
            return .{ .mean = mean, .cv = cv, .p95 = p95 };
        }
    };
}

test "BenchmarkCANARY_REQ_GQL_012_HashAggDistinctSpillEvictVarianceEnvelope" {
    var stats = Stats(Runs){};
    var seed: u64 = 0xC0FFEE;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var prng = std.rand.DefaultPrng.init(seed);
        seed = seed * 1315423911 + 1;
        var agg = exec.HashAggregator.init(std.testing.allocator, 4096);
        defer agg.deinit();
        const t0 = std.time.nanoTimestamp();
        var g: usize = 0;
        while (g < GroupsPerRun) : (g += 1) {
            const key = [_]exec.BindingValue{.{ .Int = @intCast(g) }};
            var d: usize = 0;
            while (d < DistinctPerGroup) : (d += 1) {
                const val = [_]exec.BindingValue{.{ .Int = @intCast(@mod(prng.random().int(u32), 10_000)) }};
                try agg.addRow(&key, &val, &.{.CountDistinct});
            }
        }
        try agg.flushSegment(&.{.CountDistinct});
        const t1 = std.time.nanoTimestamp();
        stats.add(t1 - t0);
        const rows = try agg.getResults();
        std.testing.allocator.free(rows);
    }
    const st = stats.finalize();
    const p95_mean_ratio = @as(f128, @floatFromInt(st.p95)) / st.mean;
    if (!(st.cv <= 0.22 and p95_mean_ratio <= 2.55)) {
        std.debug.print("VARIANCE_FAIL HashAggDistinctSpillEvictVarianceEnvelope cv={:.4} p95={} mean={d}\n", .{ st.cv, st.p95, @as(i128, @intFromFloat(st.mean)) });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK HashAggDistinctSpillEvictVarianceEnvelope cv={:.4} p95={} mean={d}\n", .{ st.cv, st.p95, @as(i128, @intFromFloat(st.mean)) });
}
