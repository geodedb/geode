// benchmark_ts_storage.zig
//
// Native variance benchmark for the timeseries-storage-backed Store path.
// Geode's timeseries surface (`CALL geode.ts.*`) is backed by the
// `timeseries_storage` library, re-exported through src/timeseries/timeseries.zig
// (ts.Store / ts.SeriesKey / ts.Point) and driven by src/execution/ts_dispatch.zig.
// This benchmark exercises the library Store directly — the representative hot
// paths behind `geode.ts.insert_many` (Store.insertMany) and `geode.ts.range`
// (Store.queryRange) — and emits a schema_version-2 VarianceEnvelope JSON line
// plus a VARIANCE_OK / VARIANCE_FAIL token per scenario, matching geode's
// bench/perf-gate conventions (GAP-0244). It is the timeseries analog of
// benchmark_fts_storage.zig.
//
// Scenarios:
//   - ts_ingest_batch: append N points via Store.insertMany in fixed-size
//                      batches (the `geode.ts.insert_many` hot path) — ns/point.
//   - ts_range_query:  K Store.queryRange scans over a populated M-point series
//                      (the `geode.ts.range` hot path) — ns/query.
//
// The bench imports `geode` (for the timeseries re-export) + std only, mirroring
// src/benchmarks/bench_timeseries.zig's import + Store.init(allocator) API.
//
// CANARY: REQ=REQ-GQL-TS-STORAGE-PERF-001; FEATURE="TimeseriesStorageBackend"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TS_STORAGE_PERF_001_TsStorageVarianceEnvelope; OWNER=storage; UPDATED=2026-05-31

const std = @import("std");
const builtin = @import("builtin");
const ts = @import("geode").timeseries;

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var t: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &t);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t);
    }
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}

const Stats = struct {
    mean_ns: f64,
    min_ns: u64,
    max_ns: u64,
    p95_ns: u64,
    cv: f64,
    p95_over_mean: f64,
    sample_count: usize,
};

fn computeStats(samples: []u64) Stats {
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));
    var diff: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        diff += d * d;
    }
    const variance = diff / @as(f64, @floatFromInt(samples.len));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    const p95_idx = (samples.len * 95) / 100;
    const p95 = samples[if (p95_idx >= samples.len) samples.len - 1 else p95_idx];
    const p95_over_mean = if (mean == 0) 0 else @as(f64, @floatFromInt(p95)) / mean;
    return .{
        .mean_ns = mean,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .p95_ns = p95,
        .cv = cv,
        .p95_over_mean = p95_over_mean,
        .sample_count = samples.len,
    };
}

inline fn scaledPpm(val: f64) u64 {
    if (val <= 0) return 0;
    const scaled = val * 10000.0;
    if (scaled > 9.2e18) return 9_200_000_000_000_000_000;
    return @intFromFloat(scaled);
}

// Variance thresholds (General class, generous for a single-core wall-clock
// micro-bench). Scaled by 1e4 like the rest of the variance suite. These are
// NOT enforced (the bench always exits 0); the VARIANCE_OK / VARIANCE_FAIL
// token + the envelope "pass" field carry the threshold verdict, matching
// benchmark_fts_storage.zig.
const CV_MAX_PPM: u64 = 20000; // cv <= 2.00
const P95_OVER_MEAN_MAX_PPM: u64 = 50000; // p95/mean <= 5.0

fn emitEnvelope(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    st: Stats,
    warmup: usize,
) !bool {
    const cv_ppm = scaledPpm(st.cv);
    const p95om_ppm = scaledPpm(st.p95_over_mean);
    const cv_pass = cv_ppm <= CV_MAX_PPM;
    const p95_pass = p95om_ppm <= P95_OVER_MEAN_MAX_PPM;
    const pass = cv_pass and p95_pass;
    const jitter_class: []const u8 = if (st.cv < 0.10) "low" else if (st.cv < 0.20) "medium" else "high";

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"{s}\"," ++
            "\"mean_ns\":{d},\"min_ns\":{d},\"max_ns\":{d},\"sample_count\":{d},\"warmup_count\":{d}," ++
            "\"cv_scaled_ppm\":{d},\"p95_ns\":{d},\"p95_over_mean_scaled_ppm\":{d}," ++
            "\"cv_max_scaled_ppm\":{d},\"p95_over_mean_max_scaled_ppm\":{d},\"jitter_class\":\"{s}\"," ++
            "\"thresholds_evaluated\":[" ++
            "{{\"metric\":\"cv_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}," ++
            "{{\"metric\":\"p95_over_mean_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}]," ++
            "\"pass\":{s}}}\n",
        .{
            name,
            @as(u64, @intFromFloat(st.mean_ns)),
            st.min_ns,
            st.max_ns,
            st.sample_count,
            warmup,
            cv_ppm,
            st.p95_ns,
            p95om_ppm,
            CV_MAX_PPM,
            P95_OVER_MEAN_MAX_PPM,
            jitter_class,
            cv_ppm,
            CV_MAX_PPM,
            if (cv_pass) "true" else "false",
            p95om_ppm,
            P95_OVER_MEAN_MAX_PPM,
            if (p95_pass) "true" else "false",
            if (pass) "true" else "false",
        },
    );
    defer allocator.free(line);
    try out.appendSlice(allocator, line);

    const token = try std.fmt.allocPrint(
        allocator,
        "{s} {s} mean_ns={d} cv={d:.4} p95_over_mean={d:.4} n={d}\n",
        .{
            if (pass) "VARIANCE_OK" else "VARIANCE_FAIL",
            name,
            @as(u64, @intFromFloat(st.mean_ns)),
            st.cv,
            st.p95_over_mean,
            st.sample_count,
        },
    );
    defer allocator.free(token);
    try out.appendSlice(allocator, token);

    return pass;
}

// Scenario 1: batched ingest — Store.insertMany in fixed-size batches. The
// reported metric is per-point latency so it is stable across batch sizes; this
// is the `geode.ts.insert_many` hot path. A fresh Store per sample isolates each
// batch's append from prior state, mirroring the per-iteration Store in
// bench_timeseries.zig's runOneIteration.
fn runIngestBatch(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const samples_n: usize = 30; // 30 timed batches
    const warmup_n: usize = 3;
    const batch_size: usize = 200;

    const key = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };

    // Pre-allocate the per-batch point buffer once so the timed region only
    // measures the Store's insert path, not our scratch allocation.
    var pts = try allocator.alloc(ts.Point, batch_size);
    defer allocator.free(pts);

    var samples = try allocator.alloc(u64, samples_n);
    defer allocator.free(samples);

    var s: usize = 0;
    var ts_cursor: i64 = 0;
    while (s < samples_n + warmup_n) : (s += 1) {
        var store = ts.Store.init(allocator);
        defer store.deinit();

        // Distinct, ascending timestamps each batch (append-only ingest shape).
        var i: usize = 0;
        while (i < batch_size) : (i += 1) {
            pts[i] = ts.Point{ .ts = ts_cursor + @as(i64, @intCast(i)), .value = @intCast(i % 100) };
        }
        ts_cursor += @intCast(batch_size);

        const t0 = nowNs();
        try store.insertMany(key, pts);
        const elapsed = nowNs() - t0;

        if (s >= warmup_n) {
            // Per-point latency so the metric is comparable across batch sizes.
            samples[s - warmup_n] = elapsed / @as(u64, @intCast(batch_size));
        }
    }

    const st = computeStats(samples);
    return emitEnvelope(out, allocator, "ts_ingest_batch", st, warmup_n);
}

// Scenario 2: range query — Store.queryRange over a populated series. This is
// the `geode.ts.range` hot path; the metric is ns per range scan (full series).
fn runRangeQuery(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const series_points: usize = 5000;
    const samples_n: usize = 200;
    const warmup_n: usize = 10;

    var store = ts.Store.init(allocator);
    defer store.deinit();

    const key = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };

    // Populate one series in a single batch, then query over it.
    {
        var pts = try allocator.alloc(ts.Point, series_points);
        defer allocator.free(pts);
        var i: usize = 0;
        while (i < series_points) : (i += 1) {
            pts[i] = ts.Point{ .ts = @intCast(i), .value = @intCast(i % 100) };
        }
        try store.insertMany(key, pts);
    }

    var samples = try allocator.alloc(u64, samples_n);
    defer allocator.free(samples);

    // DCE sink: fold every query's row count in so the loop cannot be elided
    // (std.mem.doNotOptimizeAway is not available in this toolchain).
    var sink: u64 = 0;
    const end_ts: i64 = @intCast(series_points - 1);

    var s: usize = 0;
    while (s < samples_n + warmup_n) : (s += 1) {
        const t0 = nowNs();
        // queryRange allocates the Point slice with `allocator`; free it after
        // observing its length so the bench measures the scan, not the alloc
        // lifetime, and stays allocation-neutral.
        const r = try store.queryRange(key, 0, end_ts, allocator);
        const elapsed = nowNs() - t0;
        sink +%= r.len;
        allocator.free(r);

        if (s >= warmup_n) {
            samples[s - warmup_n] = elapsed;
        }
    }

    // Observe the sink so the query loop cannot be elided. The full series is in
    // range, so sink is large; this branch is never taken.
    if (sink == 0) return error.NoRangeRows;

    const st = computeStats(samples);
    return emitEnvelope(out, allocator, "ts_range_query", st, warmup_n);
}

pub fn main() !void {
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    const io = std.Io.Threaded.global_single_threaded.io();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    // Both scenarios emit their VarianceEnvelope JSON + VARIANCE_OK/VARIANCE_FAIL
    // token into `out`; like benchmark_fts_storage.zig the pass/fail booleans do
    // NOT fail the process. The bench always exits 0 on a clean run — the
    // VARIANCE_OK / VARIANCE_FAIL token is the signal the CI bench gate greps for
    // (GAP-0244); enforcement on a noisy single-core shared runner would be a
    // flaky gate. The threshold verdict is recorded in the emitted token + the
    // `"pass"` field of the envelope.
    _ = try runIngestBatch(allocator, &out);
    _ = try runRangeQuery(allocator, &out);

    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, out.items) catch {};
}
