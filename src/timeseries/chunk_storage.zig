// Thin compatibility wrapper -- delegates to the external timeseries library's
// chunk_storage module while preserving the public API surface used by Geode.
//
// Upstream: @import("timeseries_lib").chunk_storage

// CANARY: REQ=REQ-TS-CHUNK-001; FEATURE="ChunkStorage"; ASPECT=Storage; STATUS=TESTED; TEST=src/timeseries/chunk_storage.zig:"chunk_storage: compression and stats"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GORILLA-ENC-001; FEATURE="GorillaEncoder"; ASPECT=Compression; STATUS=TESTED; TEST=src/timeseries/chunk_storage.zig:"chunk_storage: compression and stats"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GORILLA-DEC-001; FEATURE="GorillaDecoder"; ASPECT=Compression; STATUS=TESTED; TEST=src/timeseries/chunk_storage.zig:"chunk_storage: compression and stats"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-RETENTION-001; FEATURE="ChunkRetention"; ASPECT=Lifecycle; STATUS=TESTED; TEST=src/timeseries/chunk_storage.zig:"chunk_storage: retention"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-COMPRESS-STATS-001; FEATURE="CompressionStats"; ASPECT=Observability; STATUS=TESTED; TEST=src/timeseries/chunk_storage.zig:"chunk_storage: compression and stats"; OWNER=timeseries; UPDATED=2026-04-01

const ts_lib = @import("timeseries_lib");
const ts_chunk = ts_lib.chunk_storage;

// Re-export the timeseries.zig wrapper for local imports (gql_functions.zig).
pub const timeseries = @import("timeseries.zig");

// Re-export chunk storage types at the same names the rest of Geode expects.
pub const ChunkConfig = ts_chunk.ChunkConfig;
pub const CompressionAlgorithm = ts_chunk.CompressionAlgorithm;
pub const ChunkMeta = ts_chunk.ChunkMeta;
pub const GorillaEncoder = ts_chunk.GorillaEncoder;
pub const GorillaDecoder = ts_chunk.GorillaDecoder;
pub const ChunkStorage = ts_chunk.ChunkStorage;

// ---------------------------------------------------------------------------
// Tests -- verify that the external library types work through this wrapper.
// ---------------------------------------------------------------------------

const std = @import("std");

test "chunk_storage: compression and stats" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_chunks_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // Generate test data
    var points: std.ArrayList(timeseries.Point) = .{};
    defer points.deinit(ally);

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        try points.append(ally, .{
            .ts = 1000 + i * 1000,
            .value = 100 + @rem(i, 10),
        });
    }

    // Write points
    try storage.writePoints(42, points.items);

    // Check compression stats
    const stats = storage.getCompressionStats();
    try std.testing.expect(stats.total_chunks == 1);
    try std.testing.expect(stats.ratio < 1.0); // Should achieve some compression
    try std.testing.expect(stats.total_compressed < stats.total_uncompressed);
}

test "chunk_storage: retention" {
    const ally = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/ts_test_retention_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{ .retention_days = 1 });
    defer storage.deinit();

    const current_time: i64 = 1000000000;
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Add old chunk (should be pruned)
    try storage.writePoints(1, &[_]timeseries.Point{
        .{ .ts = current_time - 2 * day_ms, .value = 1 },
    });

    // Add recent chunk (should be kept)
    try storage.writePoints(2, &[_]timeseries.Point{
        .{ .ts = current_time - 1000, .value = 2 },
    });

    try std.testing.expect(storage.chunks.items.len == 2);

    // Run retention
    try storage.runRetention(current_time);

    // Should only have 1 chunk left
    try std.testing.expect(storage.chunks.items.len == 1);
    try std.testing.expect(storage.chunks.items[0].series_id == 2);
}
