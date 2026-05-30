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
}
