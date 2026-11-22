// robust_variance_envelope.zig
//
// Contention-robust VarianceEnvelope for the native storage benchmarks
// (benchmark_fts_storage.zig, benchmark_ts_storage.zig). SONNY-2439.
//
// The envelopes used to claim on the mean and the coefficient of variation of
// one pass of samples. On the shared kvm CI runner a few samples that land on
// a preempted vCPU or a contended fsync run 10-30x the rest, and one such
// sample drives the CV past its bound: fts_index_batch failed about every
// other main pipeline with cv 1.9-2.5 (CI samples 27-761 us/doc) while the
// same benchmark run locally is flat at ~55 us/doc, cv 0.02-0.04.
//
// A benchmark now runs `rounds` independent passes over the same workload and
// keeps, per sample position, the fastest of the passes (min-of-N). Host
// interference only ever adds time, so the minimum is the closest observation
// of the product cost, and a transient stall must hit the same position in
// every pass to survive. The envelope then claims on robust statistics of
// those minimums: the relative IQR ((q3 - q1) / median) and p95 / median,
// which a few outliers cannot move the way they move a mean and a standard
// deviation. Mean and CV are still emitted, as information only.
//
// The claim is on the THREAD CPU time of each sample (CLOCK_THREAD_CPUTIME_ID),
// not on wall time. Under sustained load (a Debug unit shard next to other
// shards on the shared runner) min-of-rounds wall time still breached:
// fts_index_batch's wall time is one fsync per batch on a shared disk plus
// whatever share of the CPU the scheduler grants, and neither is a property of
// the product. Thread CPU time excludes time spent preempted and blocked in
// fsync, so it measures the engine's own work on the calling thread (the
// fts_storage and timeseries engines spawn no threads: all of a sample's work
// runs on the thread that times it). Wall time is still measured and emitted,
// as information only.

const std = @import("std");
const builtin = @import("builtin");

/// CLOCK_MONOTONIC in nanoseconds.
pub fn wallNs() u64 {
    return clockNs(if (builtin.os.tag == .linux) .MONOTONIC else std.c.CLOCK.MONOTONIC);
}

/// CPU time consumed by the calling thread, in nanoseconds.
pub fn threadCpuNs() u64 {
    return clockNs(if (builtin.os.tag == .linux) .THREAD_CPUTIME_ID else std.c.CLOCK.THREAD_CPUTIME_ID);
}

fn clockNs(comptime id: anytype) u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(id, &ts);
    } else {
        _ = std.c.clock_gettime(id, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Thread CPU and wall samples, `rounds` passes of `per_round` each.
pub const Sampler = struct {
    cpu: Rounds,
    wall: Rounds,

    pub const Stamp = struct { cpu: u64, wall: u64 };

    pub fn init(allocator: std.mem.Allocator, rounds: usize, per_round: usize) !Sampler {
        var cpu = try Rounds.init(allocator, rounds, per_round);
        errdefer cpu.deinit();
        return .{ .cpu = cpu, .wall = try Rounds.init(allocator, rounds, per_round) };
    }

    pub fn deinit(self: *Sampler) void {
        self.cpu.deinit();
        self.wall.deinit();
    }

    pub fn start() Stamp {
        return .{ .wall = wallNs(), .cpu = threadCpuNs() };
    }

    /// Record sample `i` of pass `r`, started at `t0`, as ns per `ops`.
    pub fn record(self: *Sampler, r: usize, i: usize, t0: Stamp, ops: u64) void {
        const cpu = threadCpuNs() -| t0.cpu;
        const wall = wallNs() -| t0.wall;
        self.cpu.round(r)[i] = cpu / ops;
        self.wall.round(r)[i] = wall / ops;
    }

    /// Emit the envelope: claimed on thread CPU time, wall time as information.
    pub fn emit(self: *const Sampler, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8, warmup: usize, b: Bounds) !bool {
        const cpu = try self.cpu.summarize(allocator);
        const wall = try self.wall.summarize(allocator);
        return emitClaim(out, allocator, name, cpu, wall, warmup, b);
    }
};

pub const default_rounds: usize = 5;

/// Bounds the VARIANCE_OK / VARIANCE_FAIL verdict claims on.
pub const Bounds = struct {
    /// (q3 - q1) / median of the per-position minimums.
    max_rel_iqr: f64 = 1.0,
    /// p95 / median of the per-position minimums.
    max_p95_over_median: f64 = 5.0,
};

pub const Summary = struct {
    rounds: usize,
    sample_count: usize,
    min_ns: f64,
    max_ns: f64,
    median_ns: f64,
    q1_ns: f64,
    q3_ns: f64,
    p95_ns: f64,
    rel_iqr: f64,
    p95_over_median: f64,
    /// Informational only: the mean / CV of the per-position minimums.
    mean_ns: f64,
    cv: f64,
};

/// `rounds` buffers of `per_round` samples each, laid out contiguously.
pub const Rounds = struct {
    allocator: std.mem.Allocator,
    per_round: usize,
    rounds: usize,
    data: []u64,

    pub fn init(allocator: std.mem.Allocator, rounds: usize, per_round: usize) !Rounds {
        std.debug.assert(rounds > 0 and per_round > 0);
        const data = try allocator.alloc(u64, rounds * per_round);
        @memset(data, 0);
        return .{ .allocator = allocator, .per_round = per_round, .rounds = rounds, .data = data };
    }

    pub fn deinit(self: *Rounds) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// The sample buffer of pass `r`.
    pub fn round(self: *Rounds, r: usize) []u64 {
        return self.data[r * self.per_round ..][0..self.per_round];
    }

    /// Per sample position, the fastest of the passes. Caller frees.
    pub fn minimums(self: *const Rounds, allocator: std.mem.Allocator) ![]f64 {
        const out = try allocator.alloc(f64, self.per_round);
        for (out, 0..) |*o, i| {
            var m: u64 = std.math.maxInt(u64);
            for (0..self.rounds) |r| m = @min(m, self.data[r * self.per_round + i]);
            o.* = @floatFromInt(m);
        }
        return out;
    }

    pub fn summarize(self: *const Rounds, allocator: std.mem.Allocator) !Summary {
        const mins = try self.minimums(allocator);
        defer allocator.free(mins);
        return summarizeSamples(mins, self.rounds);
    }
};

fn quantile(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    const pos = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi: usize = @min(lo + 1, sorted.len - 1);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - @floor(pos));
}

/// Robust summary of `samples` (sorted in place).
pub fn summarizeSamples(samples: []f64, rounds: usize) Summary {
    std.debug.assert(samples.len > 0);
    std.sort.block(f64, samples, {}, comptime std.sort.asc(f64));
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const n: f64 = @floatFromInt(samples.len);
    const mean = sum / n;
    var sq: f64 = 0;
    for (samples) |s| sq += (s - mean) * (s - mean);
    const median = quantile(samples, 0.5);
    const q1 = quantile(samples, 0.25);
    const q3 = quantile(samples, 0.75);
    const p95 = quantile(samples, 0.95);
    return .{
        .rounds = rounds,
        .sample_count = samples.len,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .median_ns = median,
        .q1_ns = q1,
        .q3_ns = q3,
        .p95_ns = p95,
        .rel_iqr = if (median > 0) (q3 - q1) / median else 0,
        .p95_over_median = if (median > 0) p95 / median else 0,
        .mean_ns = mean,
        .cv = if (mean > 0) @sqrt(sq / n) / mean else 0,
    };
}

pub fn passes(s: Summary, b: Bounds) bool {
    return s.rel_iqr <= b.max_rel_iqr and s.p95_over_median <= b.max_p95_over_median;
}

inline fn ppm(v: f64) u64 {
    if (!(v > 0)) return 0;
    const scaled = v * 10000.0;
    if (scaled > 9.2e18) return 9_200_000_000_000_000_000;
    return @intFromFloat(scaled);
}

inline fn ns(v: f64) u64 {
    if (!(v > 0)) return 0;
    return @intFromFloat(v);
}

/// Append the schema_version-2 VarianceEnvelope JSON line and the
/// VARIANCE_OK / VARIANCE_FAIL token for `name` to `out`. The verdict (the
/// return value) is on `s`, the thread CPU summary; `wall` is information.
pub fn emitClaim(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    s: Summary,
    wall: Summary,
    warmup: usize,
    b: Bounds,
) !bool {
    const iqr_pass = s.rel_iqr <= b.max_rel_iqr;
    const p95_pass = s.p95_over_median <= b.max_p95_over_median;
    const pass = iqr_pass and p95_pass;
    const jitter_class: []const u8 = if (s.rel_iqr < 0.10) "low" else if (s.rel_iqr < 0.20) "medium" else "high";

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"{s}\"," ++
            "\"statistic\":\"min_of_rounds_median_iqr\",\"clock\":\"thread_cpu\",\"rounds\":{d}," ++
            "\"median_ns\":{d},\"q1_ns\":{d},\"q3_ns\":{d},\"min_ns\":{d},\"max_ns\":{d}," ++
            "\"sample_count\":{d},\"warmup_count\":{d}," ++
            "\"rel_iqr_scaled_ppm\":{d},\"p95_ns\":{d},\"p95_over_median_scaled_ppm\":{d}," ++
            "\"rel_iqr_max_scaled_ppm\":{d},\"p95_over_median_max_scaled_ppm\":{d}," ++
            "\"mean_ns\":{d},\"cv_scaled_ppm\":{d},\"jitter_class\":\"{s}\"," ++
            "\"wall_median_ns\":{d},\"wall_rel_iqr_scaled_ppm\":{d},\"wall_p95_over_median_scaled_ppm\":{d}," ++
            "\"thresholds_evaluated\":[" ++
            "{{\"metric\":\"rel_iqr_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}," ++
            "{{\"metric\":\"p95_over_median_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}]," ++
            "\"pass\":{s}}}\n",
        .{
            name,                              s.rounds,
            ns(s.median_ns),                   ns(s.q1_ns),
            ns(s.q3_ns),                       ns(s.min_ns),
            ns(s.max_ns),                      s.sample_count,
            warmup,                            ppm(s.rel_iqr),
            ns(s.p95_ns),                      ppm(s.p95_over_median),
            ppm(b.max_rel_iqr),                ppm(b.max_p95_over_median),
            ns(s.mean_ns),                     ppm(s.cv),
            jitter_class,                      ns(wall.median_ns),
            ppm(wall.rel_iqr),                 ppm(wall.p95_over_median),
            ppm(s.rel_iqr),                    ppm(b.max_rel_iqr),
            if (iqr_pass) "true" else "false", ppm(s.p95_over_median),
            ppm(b.max_p95_over_median),        if (p95_pass) "true" else "false",
            if (pass) "true" else "false",
        },
    );
    defer allocator.free(line);
    try out.appendSlice(allocator, line);

    const token = try std.fmt.allocPrint(
        allocator,
        "{s} {s} cpu_median_ns={d} rel_iqr={d:.4} p95_over_median={d:.4} n={d} rounds={d} (info: wall_median_ns={d} wall_rel_iqr={d:.4} wall_p95_over_median={d:.4})\n",
        .{
            if (pass) "VARIANCE_OK" else "VARIANCE_FAIL",
            name,
            ns(s.median_ns),
            s.rel_iqr,
            s.p95_over_median,
            s.sample_count,
            s.rounds,
            ns(wall.median_ns),
            wall.rel_iqr,
            wall.p95_over_median,
        },
    );
    defer allocator.free(token);
    try out.appendSlice(allocator, token);
    return pass;
}

// -- Tests (run by test-sonny2439-fts-variance-contention) -------------------

test "robust envelope: the minimum of each position across rounds drops a stall that hit one round" {
    const allocator = std.testing.allocator;
    var rounds = try Rounds.init(allocator, 3, 4);
    defer rounds.deinit();
    @memcpy(rounds.round(0), &[_]u64{ 55, 900, 56, 54 });
    @memcpy(rounds.round(1), &[_]u64{ 700, 57, 55, 56 });
    @memcpy(rounds.round(2), &[_]u64{ 56, 55, 800, 55 });
    const mins = try rounds.minimums(allocator);
    defer allocator.free(mins);
    try std.testing.expectEqualSlices(f64, &[_]f64{ 55, 55, 55, 54 }, mins);
}

test "robust envelope: three stalled samples of thirty drive the CV past 1.5 while the IQR stays tight" {
    // The CI shape: ~55 us/doc with three samples 10-14x slower.
    var samples: [30]f64 = undefined;
    for (&samples, 0..) |*s, i| s.* = 55_000 + @as(f64, @floatFromInt(i % 5)) * 400;
    samples[7] = 761_000;
    samples[19] = 640_000;
    samples[26] = 590_000;
    const s = summarizeSamples(&samples, 1);
    try std.testing.expect(s.cv > 1.5);
    try std.testing.expect(s.rel_iqr < 0.05);
    // 3 of 30 samples is 10%: p95 lands on an outlier, so one bound alone
    // would still breach; the per-position minimum across rounds is what
    // removes them (see the test above).
    try std.testing.expect(s.p95_over_median > 3.0);
}

test "robust envelope: a real regression (every sample slower and scattered) still fails" {
    var samples: [30]f64 = undefined;
    for (&samples, 0..) |*s, i| s.* = if (i % 2 == 0) 50_000 else 400_000;
    const s = summarizeSamples(&samples, 1);
    try std.testing.expect(!passes(s, .{ .max_rel_iqr = 0.50, .max_p95_over_median = 3.0 }));
}

test "robust envelope: emit writes the JSON line and the verdict token" {
    const allocator = std.testing.allocator;
    var samples = [_]f64{ 10, 11, 12, 10, 11 };
    const s = summarizeSamples(&samples, 5);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var wall_samples = [_]f64{ 30, 90, 12, 400, 11 };
    const wall = summarizeSamples(&wall_samples, 5);
    // The verdict is on the CPU summary; a wild wall summary does not move it.
    try std.testing.expect(try emitClaim(&out, allocator, "unit", s, wall, 2, .{}));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"clock\":\"thread_cpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"VarianceEnvelope\",\"benchmark\":\"unit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"rounds\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\nVARIANCE_OK unit cpu_median_ns=11 ") != null);
}

test "robust envelope: thread CPU time does not advance while the thread sleeps" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const t0 = Sampler.start();
    const req: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&req, null);
    const cpu = threadCpuNs() - t0.cpu;
    const wall = wallNs() - t0.wall;
    try std.testing.expect(wall >= 50 * std.time.ns_per_ms);
    try std.testing.expect(cpu < 10 * std.time.ns_per_ms);
}
