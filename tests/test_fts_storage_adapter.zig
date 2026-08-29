// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// Isolated unit test for src/storage/fts_storage_adapter.zig. Imports ONLY std,
// the adapter module, and fts_storage_lib (for TermPosting/DocBatch shapes).
// Compiled by the dedicated `test-fts-storage-adapter` build step so it never
// pulls geode internals into the 30-minute main build.

const std = @import("std");
const adapter = @import("fts_storage_adapter");
const fts = @import("fts_storage_lib");

const FtsStorageAdapter = adapter.FtsStorageAdapter;
const Hit = adapter.Hit;

/// Open a base_dir ({graph_dir}/fts) inside a fresh tmpdir and build an adapter
/// over it. Caller deinits the adapter and then closes base_dir + cleans tmp.
///
/// In this Zig 0.16, `std.testing.tmpDir` returns a TmpDir whose `.dir` is a
/// `std.Io.Dir` built with the process-global single-threaded io — the same
/// world the adapter speaks. TmpDir does NOT store the io, so we borrow the
/// same global io directly and open the `fts` base_dir relative to `tmp.dir`
/// with no path gymnastics. `base_path` is purely descriptive (the adapter
/// never does I/O through it; all child ops are base_dir-relative).
const Harness = struct {
    tmp: std.testing.TmpDir,
    io: std.Io,
    base_dir: std.Io.Dir,
    base_path: []const u8 = "fts",
    a: *FtsStorageAdapter,

    fn init(alloc: std.mem.Allocator) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = std.Io.Threaded.global_single_threaded.io();

        const base_dir = try tmp.dir.createDirPathOpen(io, "fts", .{});

        const a = try FtsStorageAdapter.init(alloc, io, base_dir, "fts");
        return .{ .tmp = tmp, .io = io, .base_dir = base_dir, .a = a };
    }

    /// Tear down the adapter and base_dir but KEEP the tmp dir alive so the
    /// caller can re-open a second adapter over the same on-disk path (durability
    /// test). Returns the still-open base_dir + path; caller owns both.
    fn closeAdapterKeepDir(self: *Harness) void {
        self.a.deinit();
        // base_dir intentionally left open and tmp intentionally not cleaned.
    }

    fn deinit(self: *Harness, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.a.deinit();
        self.base_dir.close(self.io);
        self.tmp.cleanup();
    }
};

fn tp(term: []const u8, positions: []const u32) fts.TermPosting {
    return .{ .term = term, .positions = positions };
}

test "create index, index a node, search finds it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    const terms = [_]fts.TermPosting{
        tp("hello", &.{0}),
        tp("world", &.{1}),
    };
    try h.a.indexNode("idx", 1, &terms);
    try h.a.flush("idx");

    const hits = try h.a.search("idx", alloc, "hello", 10);
    defer alloc.free(hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u64, 1), hits[0].node_id);
}

test "ranking: higher term frequency scores higher" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    // node 1: "alpha" once. node 2: "alpha" three times (positions 0,1,2).
    try h.a.indexNode("idx", 1, &.{tp("alpha", &.{0})});
    try h.a.indexNode("idx", 2, &.{tp("alpha", &.{ 0, 1, 2 })});
    try h.a.flush("idx");

    const hits = try h.a.search("idx", alloc, "alpha", 10);
    defer alloc.free(hits);

    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // sorted DESC by score; both present.
    try std.testing.expect(hits[0].score >= hits[1].score);
    // node 2 (tf=3) must rank at least as high as node 1 (tf=1); with BM25
    // within-doc TF normalization node 2 should be strictly higher.
    var has1 = false;
    var has2 = false;
    for (hits) |hh| {
        if (hh.node_id == 1) has1 = true;
        if (hh.node_id == 2) has2 = true;
    }
    try std.testing.expect(has1 and has2);
    try std.testing.expectEqual(@as(u64, 2), hits[0].node_id);
}

test "delete removes a node from results" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    try h.a.indexNode("idx", 1, &.{tp("hello", &.{0})});
    try h.a.flush("idx");

    {
        const hits = try h.a.search("idx", alloc, "hello", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
    }

    try h.a.deleteNode("idx", 1);
    try h.a.flush("idx");

    const hits = try h.a.search("idx", alloc, "hello", 10);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "multi-index isolation" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("a");
    try h.a.createIndex("b");
    try h.a.indexNode("a", 10, &.{tp("apple", &.{0})});
    try h.a.indexNode("b", 20, &.{tp("banana", &.{0})});
    try h.a.flush("a");
    try h.a.flush("b");

    {
        const hits = try h.a.search("a", alloc, "apple", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(@as(u64, 10), hits[0].node_id);
    }
    {
        // "banana" lives only in index "b"; index "a" must not see it.
        const hits = try h.a.search("a", alloc, "banana", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 0), hits.len);
    }
    {
        const hits = try h.a.search("b", alloc, "banana", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(@as(u64, 20), hits[0].node_id);
    }
}

test "multi-property via field tags" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    const terms = [_]fts.TermPosting{
        .{ .term = "red", .positions = &.{0}, .field = "color" },
        .{ .term = "car", .positions = &.{0}, .field = "kind" },
    };
    try h.a.indexNode("idx", 5, &terms);
    try h.a.flush("idx");

    {
        const hits = try h.a.search("idx", alloc, "red", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(@as(u64, 5), hits[0].node_id);
    }
    {
        const hits = try h.a.search("idx", alloc, "car", 10);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(@as(u64, 5), hits[0].node_id);
    }
}

test "reopen durability via openIndex" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);

    try h.a.createIndex("idx");
    try h.a.indexNode("idx", 7, &.{tp("durable", &.{0})});
    try h.a.flush("idx");

    // Close the adapter (engines flushed-on-deinit-path + closed) but keep the
    // on-disk base_dir + tmp alive so a fresh adapter can re-open it.
    h.closeAdapterKeepDir();

    // Re-open a second adapter over the SAME base_dir.
    const a2 = try FtsStorageAdapter.init(alloc, h.io, h.base_dir, h.base_path);
    defer {
        a2.deinit();
        h.base_dir.close(h.io);
        h.tmp.cleanup();
    }

    // createIndex must refuse an existing index; openIndex replays it.
    try std.testing.expectError(error.IndexExists, a2.createIndex("idx"));
    try a2.openIndex("idx");

    const hits = try a2.search("idx", alloc, "durable", 10);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u64, 7), hits[0].node_id);
}

test "max_results truncation returns top-N" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    // Three docs all containing "common" with increasing TF so scores differ
    // and the top-2 selection is deterministic.
    try h.a.indexNode("idx", 1, &.{tp("common", &.{0})});
    try h.a.indexNode("idx", 2, &.{tp("common", &.{ 0, 1 })});
    try h.a.indexNode("idx", 3, &.{tp("common", &.{ 0, 1, 2 })});
    try h.a.flush("idx");

    {
        const all = try h.a.search("idx", alloc, "common", 0); // 0 == unlimited
        defer alloc.free(all);
        try std.testing.expectEqual(@as(usize, 3), all.len);
    }

    const top2 = try h.a.search("idx", alloc, "common", 2);
    defer alloc.free(top2);
    try std.testing.expectEqual(@as(usize, 2), top2.len);
    // sorted DESC: node 3 (tf=3) then node 2 (tf=2).
    try std.testing.expect(top2[0].score >= top2[1].score);
    try std.testing.expectEqual(@as(u64, 3), top2[0].node_id);
    try std.testing.expectEqual(@as(u64, 2), top2[1].node_id);
}

test "operations on unknown index return IndexNotFound" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try std.testing.expectError(
        error.IndexNotFound,
        h.a.search("nope", alloc, "x", 10),
    );
    try std.testing.expectError(
        error.IndexNotFound,
        h.a.indexNode("nope", 1, &.{tp("x", &.{0})}),
    );
    try std.testing.expectError(
        error.IndexNotFound,
        h.a.deleteNode("nope", 1),
    );
    try std.testing.expectError(
        error.IndexNotFound,
        h.a.flush("nope"),
    );
}

test "createIndex twice returns IndexExists" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    try std.testing.expectError(error.IndexExists, h.a.createIndex("idx"));
}

// Writer thread for the dropIndex/writer race regression below. Loops
// indexNode as fast as possible; error.IndexNotFound is the CORRECT
// outcome once dropIndex has landed (either via requireIndex failing after
// the map removal, or via the post-drop `dropped` re-check inside
// indexNode after acquiring write_mu) — only a crash (the test binary not
// surviving) or an UNEXPECTED error indicates the bug.
fn dropRaceWriterThread(a: *FtsStorageAdapter, name: []const u8, unexpected: *std.atomic.Value(bool)) void {
    var i: u64 = 1;
    while (i <= 200) : (i += 1) {
        a.indexNode(name, i, &.{tp("race", &.{0})}) catch |err| switch (err) {
            error.IndexNotFound => return,
            else => {
                unexpected.store(true, .release);
                return;
            },
        };
    }
}

// Searcher thread for the dropIndex race regression below. Loops search()
// as fast as possible; error.IndexNotFound is the CORRECT outcome once
// dropIndex has removed the index from the registry. A search that pinned
// the engine before the drop completes normally against the still-alive
// engine (dropIndex waits for the in-flight reference to drain before
// deiniting) — only a crash or an UNEXPECTED error indicates the bug
// (Engine.deinit takes no internal lock, so an unpinned concurrent search
// would race teardown).
fn dropRaceSearcherThread(a: *FtsStorageAdapter, name: []const u8, unexpected: *std.atomic.Value(bool)) void {
    const alloc = std.testing.allocator;
    var i: u64 = 0;
    while (i < 200) : (i += 1) {
        const hits = a.search(name, alloc, "race", 10) catch |err| switch (err) {
            error.IndexNotFound => return,
            else => {
                unexpected.store(true, .release);
                return;
            },
        };
        alloc.free(hits);
    }
}

// CANARY: REQ=REQ-FTS-DROP-WRITER-RACE-001; FEATURE="FullText"; ASPECT=DropDrainsWriters; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=fts; UPDATED=2026-08-29
test "dropIndex drains in-flight writers and searchers instead of freeing under them" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    // Repeat the create/race/drop cycle to widen the interleaving window
    // between the worker threads' requireIndex pin and dropIndex's
    // map-removal + refcount-drain + teardown. Each cycle uses a fresh index
    // name so a slow-to-finish worker from a prior cycle can never alias into
    // the next cycle's engine. The searcher exercises the reader side of the
    // race: searches never take write_mu, so only the in-flight reference
    // stands between a concurrent search and Engine.deinit.
    var cycle: usize = 0;
    while (cycle < 20) : (cycle += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "race{d}", .{cycle});
        try h.a.createIndex(name);

        var unexpected = std.atomic.Value(bool).init(false);
        var writer = try std.Thread.spawn(.{}, dropRaceWriterThread, .{ h.a, name, &unexpected });
        var searcher = try std.Thread.spawn(.{}, dropRaceSearcherThread, .{ h.a, name, &unexpected });

        // Give the workers a head start so they are genuinely in flight
        // (pinned via requireIndex, holding or about to acquire write_mu /
        // a TermIterator) when dropIndex runs, rather than racing dropIndex
        // against as-yet-unstarted threads. Zig 0.16 moved sleep onto the Io
        // interface (no more std.Thread.sleep).
        std.Io.sleep(h.io, .fromMilliseconds(5), .real) catch {};

        // The decisive assertion is "we got here without a crash/UAF" — the
        // test binary surviving this call under contention IS the proof.
        try h.a.dropIndex(name);

        writer.join();
        searcher.join();
        try std.testing.expect(!unexpected.load(.acquire));
    }
}

// Slow writer for the deterministic quiescence test below: one large batch
// write, then flag how the operation resolved. Exactly one of the two flags
// is set before the thread returns, and both are set only AFTER the adapter
// call fully returned — i.e. after the in-flight reference was released.
fn quiescenceWriterThread(
    a: *FtsStorageAdapter,
    name: []const u8,
    docs: []const fts.DocBatch,
    resolved: *std.atomic.Value(bool),
    unexpected: *std.atomic.Value(bool),
) void {
    a.indexNodeBatch(name, docs) catch |err| switch (err) {
        error.IndexNotFound => {
            resolved.store(true, .release);
            return;
        },
        else => {
            unexpected.store(true, .release);
            return;
        },
    };
    resolved.store(true, .release);
}

// CANARY: REQ=REQ-FTS-DROP-WRITER-RACE-001; FEATURE="FullText"; ASPECT=DropQuiescence; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=fts; UPDATED=2026-08-29
test "dropIndex returns only after an in-flight write has fully resolved" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("q");
    // Pin the wrapper pointer up front (safe: the engine stays alive until
    // our own dropIndex below) so the main thread can observe `refs` under
    // the adapter's registry mutex.
    const ie = h.a.getIndex("q").?;

    // A deliberately fat batch so the write dwells inside the engine.
    var docs: [64]fts.DocBatch = undefined;
    const terms = [_]fts.TermPosting{ tp("alpha", &.{ 0, 5, 9 }), tp("beta", &.{ 1, 3 }), tp("gamma", &.{2}) };
    for (&docs, 0..) |*d, i| d.* = .{ .doc_id = @as(u64, i) + 1, .terms = &terms };

    var resolved = std.atomic.Value(bool).init(false);
    var unexpected = std.atomic.Value(bool).init(false);
    var writer = try std.Thread.spawn(.{}, quiescenceWriterThread, .{ h.a, @as([]const u8, "q"), @as([]const fts.DocBatch, &docs), &resolved, &unexpected });

    // Deterministic ordering: wait until the writer PROVABLY holds an
    // in-flight reference (refs > 0, read under the registry mutex the count
    // is guarded by) — or has already fully resolved (fast-writer case).
    while (true) {
        if (resolved.load(.acquire)) break;
        h.a.mu.lockUncancelable(h.io);
        const r = ie.refs;
        h.a.mu.unlock(h.io);
        if (r > 0) break;
        std.Io.sleep(h.io, .fromMilliseconds(1), .real) catch {};
    }

    // If the writer held a reference when we got here (the usual case with a
    // batch this size), dropIndex MUST block until that reference drains —
    // and the adapter releases it only AFTER indexNodeBatch's engine work
    // fully completed (defer order: write_mu unlock, then releaseIndex). So
    // dropIndex returning proves the write resolved (completed or was refused
    // with IndexNotFound), never left mid-flight over freed memory; a
    // dropIndex that returned early would tear the engine down under the live
    // batch write, and the UAF crash is the decisive assertion. NOTE: the
    // writer's `resolved` STORE runs a few instructions after its release, so
    // the flag itself can lag dropIndex's return by a scheduler quantum —
    // join() bounds that lag before we assert on the flags. NOTE: `ie` is
    // freed by dropIndex; it must not be touched past this point.
    try h.a.dropIndex("q");

    writer.join();
    try std.testing.expect(!unexpected.load(.acquire));
    try std.testing.expect(resolved.load(.acquire));
}

test "dropIndex removes the index" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit(alloc);

    try h.a.createIndex("idx");
    try h.a.indexNode("idx", 1, &.{tp("gone", &.{0})});
    try h.a.flush("idx");

    try h.a.dropIndex("idx");
    try std.testing.expect(h.a.getIndex("idx") == null);
    try std.testing.expectError(
        error.IndexNotFound,
        h.a.search("idx", alloc, "gone", 10),
    );

    // After drop, the name is free again — createIndex should succeed fresh.
    try h.a.createIndex("idx");

    // Dropping a name that was never registered must surface IndexNotFound
    // (regression: previously returned a stray error.WrongOnPurpose).
    try std.testing.expectError(error.IndexNotFound, h.a.dropIndex("nope"));
}
