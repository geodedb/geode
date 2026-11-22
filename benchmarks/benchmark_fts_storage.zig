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
// SONNY-2439: each scenario runs `robust_variance_envelope.default_rounds`
// independent passes and the envelope claims on the median / IQR of the
// per-position fastest pass (benchmarks/robust_variance_envelope.zig), so a
// batch that lands on a preempted vCPU or a contended fsync on the shared CI
// runner cannot breach it. tests/test_sonny2439_fts_variance_contention.zig
// runs both scenarios under real CPU + fsync contention.
//
// The bench is intentionally lean: it imports `fts_storage_lib` + std only, so
// it compiles in seconds rather than dragging in the geode root module.
//
// CANARY: REQ=REQ-GQL-FTS-STORAGE-PERF-001; FEATURE="FtsStorageBackend"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_FTS_STORAGE_PERF_001_FtsStorageVarianceEnvelope; OWNER=storage; UPDATED=2026-11-22

const std = @import("std");
const builtin = @import("builtin");
const fts = @import("fts_storage_lib");
const rve = @import("robust_variance_envelope");

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

/// The envelope both scenarios claim (relative IQR and p95 / median of the
/// per-position minimums over the rounds).
pub const bounds: rve.Bounds = .{ .max_rel_iqr = 0.50, .max_p95_over_median = 3.0 };

// Open a fresh, unique scratch dir for an engine instance. Returns the opened
// std.Io.Dir; caller closes it (engine.deinit does NOT close base_dir) and is
// responsible for the on-disk cleanup via the returned name.
fn openScratchDir(io: std.Io, name: []const u8) !std.Io.Dir {
    return std.Io.Dir.cwd().createDirPathOpen(io, name, .{});
}

// Build a small deterministic term set for a doc. Each doc gets a handful of
// terms drawn from a fixed vocabulary plus one doc-unique term, exercising both
// common (high-df) and rare (low-df) posting lists.
fn termsForDoc(buf: []fts.TermPosting, common_pos: []const u32, uniq_term: []const u8, uniq_pos: []const u32) []fts.TermPosting {
    buf[0] = .{ .term = "alpha", .positions = common_pos };
    buf[1] = .{ .term = "beta", .positions = common_pos };
    buf[2] = .{ .term = "gamma", .positions = common_pos };
    buf[3] = .{ .term = uniq_term, .positions = uniq_pos };
    return buf[0..4];
}

const common_positions = [_]u32{ 1, 4, 9 };
const uniq_positions = [_]u32{2};

/// `doc_count` pre-built DocBatch entries, so the timed region only measures
/// the engine's index path, not our scratch allocation.
const Corpus = struct {
    allocator: std.mem.Allocator,
    doc_terms: [][4]fts.TermPosting,
    uniq_terms: [][24]u8,
    batches: []fts.DocBatch,

    fn init(allocator: std.mem.Allocator, doc_count: usize) !Corpus {
        const doc_terms = try allocator.alloc([4]fts.TermPosting, doc_count);
        errdefer allocator.free(doc_terms);
        const uniq_terms = try allocator.alloc([24]u8, doc_count);
        errdefer allocator.free(uniq_terms);
        const batches = try allocator.alloc(fts.DocBatch, doc_count);
        for (0..doc_count) |d| {
            const ut = std.fmt.bufPrint(&uniq_terms[d], "doc{d}", .{d}) catch unreachable;
            batches[d] = .{ .doc_id = @intCast(d + 1), .terms = termsForDoc(&doc_terms[d], &common_positions, ut, &uniq_positions) };
        }
        return .{ .allocator = allocator, .doc_terms = doc_terms, .uniq_terms = uniq_terms, .batches = batches };
    }

    fn deinit(self: *Corpus) void {
        self.allocator.free(self.batches);
        self.allocator.free(self.uniq_terms);
        self.allocator.free(self.doc_terms);
    }
};

const index_samples: usize = 30; // 30 timed batches of 100 docs per round
const index_warmup: usize = 3;
const index_batch: usize = 100;

/// One pass: a fresh engine indexes the corpus in `index_batch`-doc batches;
/// `samples` receives the ns/doc of each timed batch.
fn indexRound(io: std.Io, allocator: std.mem.Allocator, corpus: *const Corpus, samples: []u64) !void {
    const dir_name = ".bench-fts-index-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    var dir = try openScratchDir(io, dir_name);
    defer dir.close(io);
    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    for (0..index_samples + index_warmup) |s| {
        // Each iteration indexes `index_batch` distinct docs in one batched
        // call (one fsync amortized across the batch — the real hot path).
        const batch = corpus.batches[s * index_batch ..][0..index_batch];
        const t0 = nowNs();
        try engine.indexDocumentBatch(batch);
        const elapsed = nowNs() - t0;
        // Per-doc latency so the metric is stable across batch sizes.
        if (s >= index_warmup) samples[s - index_warmup] = elapsed / index_batch;
    }
}

pub fn runIndexBatch(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    var corpus = try Corpus.init(allocator, (index_samples + index_warmup) * index_batch);
    defer corpus.deinit();

    var rounds = try rve.Rounds.init(allocator, rve.default_rounds, index_samples);
    defer rounds.deinit();
    for (0..rve.default_rounds) |r| try indexRound(io, allocator, &corpus, rounds.round(r));

    const st = try rounds.summarize(allocator);
    return rve.emit(out, allocator, "fts_index_batch", st, index_warmup, bounds);
}

const search_docs: usize = 2000;
const search_samples: usize = 200;
const search_warmup: usize = 10;
const search_batch: usize = 8; // queries per sample

pub fn runSearchTerm(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !bool {
    const dir_name = ".bench-fts-search-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    var dir = try openScratchDir(io, dir_name);
    defer dir.close(io);
    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    // Build the corpus in one batch then flush so searches hit segments.
    var corpus = try Corpus.init(allocator, search_docs);
    defer corpus.deinit();
    try engine.indexDocumentBatch(corpus.batches);
    try engine.flush();

    var rounds = try rve.Rounds.init(allocator, rve.default_rounds, search_samples);
    defer rounds.deinit();
    for (0..rve.default_rounds) |r| {
        const samples = rounds.round(r);
        for (0..search_samples + search_warmup) |s| {
            const t0 = nowNs();
            for (0..search_batch) |_| {
                // A single-term search: open the iterator and drain its
                // matches. For the common term this walks the full posting
                // list (search_docs docs).
                var it = try fts.TermIterator.init(allocator, engine, "alpha");
                var hits: usize = 0;
                while (try it.next()) |_| hits += 1;
                it.deinit();
                if (hits != search_docs) return error.UnexpectedSearchHits;
                std.mem.doNotOptimizeAway(hits);
            }
            const elapsed = nowNs() - t0;
            if (s >= search_warmup) samples[s - search_warmup] = elapsed / search_batch;
        }
    }

    const st = try rounds.summarize(allocator);
    return rve.emit(out, allocator, "fts_search_term", st, search_warmup, bounds);
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
    // fail the process. The VARIANCE_OK / VARIANCE_FAIL token is the signal the
    // CI bench gate greps for (GAP-0244); the verdict is also recorded in the
    // `"pass"` field of the envelope.
    _ = try runIndexBatch(io, allocator, &out);
    _ = try runSearchTerm(io, allocator, &out);

    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, out.items) catch {};
}
