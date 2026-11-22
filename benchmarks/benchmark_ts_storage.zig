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
//                      batches (the `geode.ts.insert_many` hot path) — ns per 200-point batch.
//   - ts_range_query:  K Store.queryRange scans over a populated M-point series
//                      (the `geode.ts.range` hot path) — ns/query.
//
// SONNY-2439: like benchmark_fts_storage.zig, each scenario runs
// `robust_variance_envelope.default_rounds` passes and claims on the median /
// IQR of the per-position fastest pass of each sample's thread CPU time
// (benchmarks/robust_variance_envelope.zig), so neither a preempted sample nor
// sustained load on the shared CI runner can breach the envelope. Wall time is
// reported alongside, as information.
//
// The bench imports `geode` (for the timeseries re-export) + std only, mirroring
// src/benchmarks/bench_timeseries.zig's import + Store.init(allocator) API.
//
// CANARY: REQ=REQ-GQL-TS-STORAGE-PERF-001; FEATURE="TimeseriesStorageBackend"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TS_STORAGE_PERF_001_TsStorageVarianceEnvelope; OWNER=storage; UPDATED=2026-11-22

const std = @import("std");
const builtin = @import("builtin");
const ts = @import("geode").timeseries;
const rve = @import("robust_variance_envelope");

/// The envelope both scenarios claim (relative IQR and p95 / median of the
/// per-position minimums over the rounds).
pub const bounds: rve.Bounds = .{ .max_rel_iqr = 0.50, .max_p95_over_median = 3.0 };

// Scenario 1: batched ingest — Store.insertMany in fixed-size batches. The
// reported metric is per-point latency so it is stable across batch sizes; this
// is the `geode.ts.insert_many` hot path. A fresh Store per sample isolates each
// batch's append from prior state, mirroring the per-iteration Store in
// bench_timeseries.zig's runOneIteration.
pub fn runIngestBatch(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const samples_n: usize = 30; // 30 timed batches per round
    const warmup_n: usize = 3;
    const batch_size: usize = 200;

    const key = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };

    // Pre-allocate the per-batch point buffer once so the timed region only
    // measures the Store's insert path, not our scratch allocation.
    const pts = try allocator.alloc(ts.Point, batch_size);
    defer allocator.free(pts);

    var sampler = try rve.Sampler.init(allocator, rve.default_rounds, samples_n);
    defer sampler.deinit();

    for (0..rve.default_rounds) |r| {
        var ts_cursor: i64 = 0;
        for (0..samples_n + warmup_n) |s| {
            var store = ts.Store.init(allocator);
            defer store.deinit();

            // Distinct, ascending timestamps each batch (append-only ingest shape).
            for (pts, 0..) |*p, i| p.* = ts.Point{ .ts = ts_cursor + @as(i64, @intCast(i)), .value = @intCast(i % 100) };
            ts_cursor += @intCast(batch_size);

            const t0 = rve.Sampler.start();
            try store.insertMany(key, pts);

            // Whole-batch ns: per-point ns (~25) is too coarse an integer for
            // the IQR (SONNY-2439).
            if (s >= warmup_n) sampler.record(r, s - warmup_n, t0, 1);
        }
    }

    return sampler.emit(out, allocator, "ts_ingest_batch", warmup_n, bounds);
}

// Scenario 2: range query — Store.queryRange over a populated series. This is
// the `geode.ts.range` hot path; the metric is ns per range scan (full series).
pub fn runRangeQuery(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const series_points: usize = 5000;
    const samples_n: usize = 200;
    const warmup_n: usize = 10;
    const queries_per_sample: usize = 4;

    var store = ts.Store.init(allocator);
    defer store.deinit();

    const key = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };

    // Populate one series in a single batch, then query over it.
    {
        const pts = try allocator.alloc(ts.Point, series_points);
        defer allocator.free(pts);
        for (pts, 0..) |*p, i| p.* = ts.Point{ .ts = @intCast(i), .value = @intCast(i % 100) };
        try store.insertMany(key, pts);
    }

    var sampler = try rve.Sampler.init(allocator, rve.default_rounds, samples_n);
    defer sampler.deinit();
    const end_ts: i64 = @intCast(series_points - 1);

    for (0..rve.default_rounds) |r| {
        for (0..samples_n + warmup_n) |s| {
            const t0 = rve.Sampler.start();
            for (0..queries_per_sample) |_| {
                // queryRange allocates the Point slice with `allocator`; it is
                // freed inside the timed region, as a caller would free it.
                const rows = try store.queryRange(key, 0, end_ts, allocator);
                const n = rows.len;
                allocator.free(rows);
                if (n != series_points) return error.UnexpectedRangeRows;
                std.mem.doNotOptimizeAway(n);
            }
            if (s >= warmup_n) sampler.record(r, s - warmup_n, t0, queries_per_sample);
        }
    }

    return sampler.emit(out, allocator, "ts_range_query", warmup_n, bounds);
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
    // NOT fail the process. The VARIANCE_OK / VARIANCE_FAIL token is the signal
    // the CI bench gate greps for (GAP-0244).
    _ = try runIngestBatch(allocator, &out);
    _ = try runRangeQuery(allocator, &out);

    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, out.items) catch {};
}
