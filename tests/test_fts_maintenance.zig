// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-GQL-FTS-DDL-001; FEATURE="Fulltext node write-maintenance"; ASPECT=E2E; STATUS=IMPL; TEST=self; OWNER=index; UPDATED=2026-11-14
//
//! A4b end-to-end: prove that a fulltext index created BEFORE any inserts stays
//! current as nodes are CREATEd / SET / DELETEd through GQL — WITHOUT a manual
//! reindex. The maintenance hook fires on the executor (connection) thread:
//!   * CREATE — node properties flow through `setNodePropertyFromValue`, which
//!     calls `maintainFulltextOnWrite(.update)` (delete-then-index; the engine
//!     is append-only). Backfill saw nothing (empty graph), so a search hit here
//!     proves write-path maintenance, not backfill.
//!   * SET — the same chokepoint re-runs delete-then-index against the node's
//!     CURRENT properties, so the OLD term disappears and the NEW term appears.
//!   * DELETE — `executeDelete` calls `maintainFulltextOnWrite(.delete)` BEFORE
//!     the store delete, dropping the node's postings.
//!
//! Mirrors the in-process Harness from `tests/test_fts_e2e.zig` (boot a global
//! store + adapter rooted at a tmp dir; run GQL through execution.executeQuery;
//! assert on the typed ExecutionResult). No mocks — the real adapter engine.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []const u8,

    fn init(allocator: std.mem.Allocator) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmp.dir.realpathAlloc(allocator, ".");

        try graph_store.initGlobalStoreWithDataDir(allocator, data_dir);

        return .{ .allocator = allocator, .tmp = tmp, .data_dir = data_dir };
    }

    fn deinit(self: *Harness) void {
        graph_store.deinitGlobalStore();
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn exec(self: *Harness, gql: []const u8) !execution.ExecutionResult {
        return try execution.executeQuery(self.allocator, gql, self.data_dir);
    }

    /// Run a statement whose result we don't inspect, freeing it.
    fn run(self: *Harness, gql: []const u8) !void {
        var r = try self.exec(gql);
        r.deinit(self.allocator);
    }

    /// Number of geode.fts.search hits for `term` in `index`.
    fn searchCount(self: *Harness, index: []const u8, term: []const u8) !usize {
        const gql = try std.fmt.allocPrint(self.allocator, "CALL geode.fts.search('{s}', '{s}')", .{ index, term });
        defer self.allocator.free(gql);
        var r = try self.exec(gql);
        defer r.deinit(self.allocator);
        return r.rows.len;
    }
};

test "fts maintenance: CREATE after index is searchable without reindex" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Index created on an EMPTY graph: backfill indexes nothing.
    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // Insert AFTER the index — only the write-maintenance hook can index these.
    try h.run("CREATE (:Doc {body: 'the quick brown fox'})");
    try h.run("CREATE (:Doc {body: 'lazy dog'})");

    // Proves CREATE-path maintenance (backfill saw an empty graph). Exactly one
    // doc carries 'fox' — assert a single hit (no duplicate postings).
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "fox"));
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "dog"));
}

test "fts maintenance: SET updates index (delete-then-index)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'the quick brown fox'})");
    try h.run("CREATE (:Doc {body: 'lazy dog'})");

    // Sanity: the fox node is indexed via the CREATE hook.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "fox"));

    // Update the fox node's body. The SET chokepoint re-runs delete-then-index,
    // so the OLD term ('fox') must vanish and the NEW term ('falcon') appear.
    try h.run("MATCH (d:Doc) WHERE d.body CONTAINS 'fox' SET d.body = 'a swift falcon'");

    // OLD term gone (proves UPDATE = delete-then-index, not append-only stale).
    try testing.expectEqual(@as(usize, 0), try h.searchCount("doc_idx", "fox"));
    // NEW term present.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "falcon"));
    // The untouched 'dog' node is unaffected.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "dog"));
}

test "fts maintenance: DELETE drops index entry" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'the quick brown fox'})");
    try h.run("CREATE (:Doc {body: 'lazy dog'})");

    // Turn the fox node into a falcon (exercises SET maintenance again).
    try h.run("MATCH (d:Doc) WHERE d.body CONTAINS 'fox' SET d.body = 'a swift falcon'");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "falcon"));

    // Delete the falcon node; its postings must be dropped by the DELETE hook.
    try h.run("MATCH (d:Doc) WHERE d.body CONTAINS 'falcon' DELETE d");
    try testing.expectEqual(@as(usize, 0), try h.searchCount("doc_idx", "falcon"));

    // The surviving 'dog' node is still searchable.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "dog"));
}
