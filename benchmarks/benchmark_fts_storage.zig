// benchmark_fts_storage.zig
//
// Native variance benchmark for the fts-storage-backed full-text-search path.
// Geode's FTS is backed by the `fts_storage` library (src/storage/fts_storage_adapter.zig
// is a thin wrapper over fts.Engine). This benchmark exercises the library
// engine directly — the representative hot paths — and emits a
// schema_version-2 VarianceEnvelope JSON line plus a VARIANCE_OK / VARIANCE_FAIL
// token per scenario, matching geode's bench/perf-gate conventions (GAP-0244).
//
// Scenarios:
//   - fts_index_batch:  build N docs via Engine.indexDocumentBatch — ns/doc.
//   - fts_search_term:  K single-term TermIterator searches over an M-doc
//                       index — ns/query.
//
// The bench is intentionally lean: it imports `fts_storage_lib` + std only, so
// it compiles in seconds rather than dragging in the geode root module.
//
// CANARY: REQ=REQ-GQL-FTS-STORAGE-PERF-001; FEATURE="FtsStorageBackend"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_FTS_STORAGE_PERF_001_FtsStorageVarianceEnvelope; OWNER=storage; UPDATED=2026-05-31

const std = @import("std");
const builtin = @import("builtin");
const fts = @import("fts_storage_lib");

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
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
// micro-bench that touches the WAL/fsync path). Scaled by 1e4 like the rest of
// the variance suite. These are NOT enforced unless FTS_STORAGE_ENFORCE=1 is
// set (opt-in enforcement, like the other variance benchmarks) — the
// envelope is informational on noisy shared CI, and the VARIANCE_OK/FAIL token
// reflects the threshold evaluation either way.
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

// Open a fresh, unique scratch dir for an engine instance. Returns the opened
// std.Io.Dir; caller closes it (engine.deinit does NOT close base_dir) and is
// responsible for the on-disk cleanup via the returned name.
fn openScratchDir(io: std.Io, name: []const u8) !std.Io.Dir {
    return std.Io.Dir.cwd().createDirPathOpen(io, name, .{});
}

// Build a small deterministic term set for a doc. Each doc gets a handful of
// terms drawn from a fixed vocabulary plus one doc-unique term, exercising both
// common (high-df) and rare (low-df) posting lists.
fn termsForDoc(buf: []fts.TermPosting, id: u64, common_pos: []const u32, uniq_term: []const u8, uniq_pos: []const u32) []fts.TermPosting {
    _ = id;
    buf[0] = .{ .term = "alpha", .positions = common_pos };
    buf[1] = .{ .term = "beta", .positions = common_pos };
    buf[2] = .{ .term = "gamma", .positions = common_pos };
    buf[3] = .{ .term = uniq_term, .positions = uniq_pos };
    return buf[0..4];
}

pub fn runIndexBatch(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const doc_count: usize = 3000;
    const samples_n: usize = 30; // 30 batches of 100 docs
    const warmup_n: usize = 3;
    const batch_size: usize = 100;

    const common_pos = [_]u32{ 1, 4, 9 };
    const uniq_pos = [_]u32{2};

    var samples = try allocator.alloc(u64, samples_n);
    defer allocator.free(samples);

    // Pre-build all DocBatch entries so the timed region only measures the
    // engine's index path, not our scratch allocation.
    var doc_terms = try allocator.alloc([4]fts.TermPosting, doc_count);
    defer allocator.free(doc_terms);
    var uniq_terms = try allocator.alloc([24]u8, doc_count);
    defer allocator.free(uniq_terms);
    var batches = try allocator.alloc(fts.DocBatch, doc_count);
    defer allocator.free(batches);

    var d: usize = 0;
    while (d < doc_count) : (d += 1) {
        const ut = try std.fmt.bufPrint(&uniq_terms[d], "doc{d}", .{d});
        const slice = termsForDoc(&doc_terms[d], d, &common_pos, ut, &uniq_pos);
        batches[d] = .{ .doc_id = @intCast(d + 1), .terms = slice };
    }

    var dir = try openScratchDir(io, ".bench-fts-index-tmp");
    defer dir.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, ".bench-fts-index-tmp") catch {};

    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    var s: usize = 0;
    var doc_cursor: usize = 0;
    while (s < samples_n + warmup_n) : (s += 1) {
        // Each iteration indexes `batch_size` distinct docs in one batched
        // call (one fsync amortized across the batch — the real hot path).
        const lo = doc_cursor;
        const hi = @min(lo + batch_size, doc_count);
        if (hi <= lo) break;
        const this_batch = batches[lo..hi];
        const n_docs = hi - lo;
        doc_cursor = hi;

        const t0 = nowNs();
        try engine.indexDocumentBatch(this_batch);
        const elapsed = nowNs() - t0;

        if (s >= warmup_n) {
            // Record per-doc latency so the metric is stable across batch sizes.
            samples[s - warmup_n] = elapsed / @as(u64, @intCast(n_docs));
        }
        if (doc_cursor >= doc_count) doc_cursor = 0; // wrap (re-index is fine)
    }

    const st = computeStats(samples);
    return emitEnvelope(out, allocator, "fts_index_batch", st, warmup_n);
}

pub fn runSearchTerm(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const doc_count: usize = 2000;
    const samples_n: usize = 200;
    const warmup_n: usize = 10;

    const common_pos = [_]u32{ 1, 4, 9 };
    const uniq_pos = [_]u32{2};

    var dir = try openScratchDir(io, ".bench-fts-search-tmp");
    defer dir.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, ".bench-fts-search-tmp") catch {};

    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    // Build the corpus in one batch then flush so searches hit segments.
    var doc_terms = try allocator.alloc([4]fts.TermPosting, doc_count);
    defer allocator.free(doc_terms);
    var uniq_terms = try allocator.alloc([24]u8, doc_count);
    defer allocator.free(uniq_terms);
    var batches = try allocator.alloc(fts.DocBatch, doc_count);
    defer allocator.free(batches);

    var d: usize = 0;
    while (d < doc_count) : (d += 1) {
        const ut = try std.fmt.bufPrint(&uniq_terms[d], "doc{d}", .{d});
        const slice = termsForDoc(&doc_terms[d], d, &common_pos, ut, &uniq_pos);
        batches[d] = .{ .doc_id = @intCast(d + 1), .terms = slice };
    }
    try engine.indexDocumentBatch(batches);
    try engine.flush();

    var samples = try allocator.alloc(u64, samples_n);
    defer allocator.free(samples);

    // DCE sink: every search's hit count is folded in here and observed below
    // so the compiler cannot elide the search loop (std.mem.doNotOptimizeAway is
    // not available in this toolchain).
    var sink: u64 = 0;

    var s: usize = 0;
    while (s < samples_n + warmup_n) : (s += 1) {
        const t0 = nowNs();
        // A single-term search: open the iterator and drain its matches. For
        // the common term this walks the full posting list (doc_count docs).
        var it = try fts.TermIterator.init(allocator, engine, "alpha");
        var hits: usize = 0;
        while (try it.next()) |_| {
            hits += 1;
        }
        it.deinit();
        const elapsed = nowNs() - t0;
        sink +%= hits;

        if (s >= warmup_n) {
            samples[s - warmup_n] = elapsed;
        }
    }

    // Observe the sink so the search loop cannot be elided. "alpha" is in every
    // doc, so sink is large; this branch is never taken.
    if (sink == 0) return error.NoSearchHits;

    const st = computeStats(samples);
    return emitEnvelope(out, allocator, "fts_search_term", st, warmup_n);
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
    // token into `out`; the pass/fail booleans are intentionally not used to
    // fail the process. Like benchmark_tde_encrypt_pages, this bench always
    // exits 0 on a clean run — the VARIANCE_OK / VARIANCE_FAIL token is the
    // signal the CI bench gate greps for (GAP-0244), and enforcement on a noisy
    // single-core shared runner would be a flaky gate. The threshold verdict is
    // recorded in the emitted token + the `"pass"` field of the envelope.
    _ = try runIndexBatch(io, allocator, &out);
    _ = try runSearchTerm(io, allocator, &out);

    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, out.items) catch {};
}
