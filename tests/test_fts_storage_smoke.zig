// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Smoke test for the fts-storage library wiring.
//!
//! Proves the external `fts_storage` Zig library is importable as
//! `fts_storage_lib` and performs a real init -> index -> flush -> search ->
//! deinit roundtrip in a temp directory. The setup mirrors the library's own
//! integration tests (see fts-storage/tests/integration.zig) verbatim for the
//! Zig 0.16 std.Io / TmpDir idiom.
//!
//! Compiled and run via `zig build test-fts-storage-smoke` (does NOT pull in
//! any geode source, so it stays cheap).

const std = @import("std");
const fts = @import("fts_storage_lib");

test "fts-storage smoke: index/flush/search roundtrip finds the indexed doc" {
    const allocator = std.testing.allocator;

    // Temp dir owned by the test; cleaned up AFTER engine deinit.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();

    // init -> index -> flush
    var eng = try fts.Engine.init(io, allocator, tmp_dir.dir);
    defer eng.deinit(); // deinit does NOT flush; we flushed above.

    try eng.indexDocument(1, &[_]fts.TermPosting{
        .{ .term = "hello", .positions = &[_]u32{0} },
        .{ .term = "world", .positions = &[_]u32{1} },
    });
    try eng.flush();

    // search: the term "hello" must resolve to exactly doc_id == 1.
    var it = try fts.TermIterator.init(allocator, eng, "hello");
    defer it.deinit();

    var match_count: usize = 0;
    var found_doc: u64 = 0;
    while (try it.next()) |m| {
        match_count += 1;
        found_doc = m.doc_id;
    }

    try std.testing.expectEqual(@as(usize, 1), match_count);
    try std.testing.expectEqual(@as(u64, 1), found_doc);
}
