const std = @import("std");
const wal_mod = @import("../src/wal/wal.zig");

// WAL compaction e2e: create multiple segments, checkpoint, compact, ensure old segments removed
// and recovery still succeeds (idempotent) with remaining segments.

pub fn main() !void {
    var gpa = std.heap.page_allocator;
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    // Force tiny segment size to cause rollovers.
    wal.segment_limit = 4 * 1024; // 4KB
    try wal.openFile("/tmp/geode_compact_test");
    // Write enough inserts to create several segments.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const page: u32 = @intCast(i % 7);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 9, 9, 9 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    // Emit checkpoint capturing durable boundary (end of current log state).
    const ckpt_lsn = try wal.writeCheckpoint();
    // Add more records (next segment likely) so some earlier segments become obsolete.
    i = 0;
    while (i < 200) : (i += 1) {
        const page: u32 = @intCast((i + 13) % 7);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 1, 2, 3, 4 });
        defer gpa.free(payload);
        _ = try wal.append(2, .Insert, payload, 0);
    }
    try wal.fsync();
    // Capture list of segment files before compaction.
    var before_count: usize = 0;
    {
        var seg_index: usize = 0;
        while (seg_index < 10) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(gpa, "/tmp/geode_compact_test.wal.{d}", .{seg_index});
            defer gpa.free(path);
            if (std.fs.cwd().access(path, .{})) |_| before_count += 1 else |_| {}
        }
    }
    // Run compaction with durable_lsn = checkpoint lsn.
    try wal.compact(ckpt_lsn.value);
    // Count again.
    var after_count: usize = 0;
    var retained_earliest: ?usize = null;
    {
        var seg_index: usize = 0;
        while (seg_index < 10) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(gpa, "/tmp/geode_compact_test.wal.{d}", .{seg_index});
            defer gpa.free(path);
            if (std.fs.cwd().access(path, .{})) |_| {
                after_count += 1;
                if (retained_earliest == null) retained_earliest = seg_index;
            } else |_| {}
        }
    }
    if (!(after_count < before_count and after_count > 0)) return error.CompactionDidNotReclaim;
    // Sanity: earliest retained segment index should be >=1 (i.e., segment 0 deleted) in most cases; allow fallback.
    if (retained_earliest) |idx| {
        if (idx == 0) return error.ExpectedOldestSegmentReclaimed; // strict expectation for this pattern size
    } else return error.NoSegmentsRetained;
    // Recovery test: open earliest retained segment and perform recovery to ensure remaining log valid.
    if (retained_earliest) |start_idx| {
        const pm_mod = @import("../src/storage/page_manager.zig");
        var pm = pm_mod.PageManager.init(gpa);
        defer pm.deinit();
        var wal_recover = wal_mod.Wal.init(gpa);
        defer wal_recover.deinit();
        // Recover each existing segment sequentially.
        var seg_index: usize = start_idx;
        while (seg_index < 10) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(gpa, "/tmp/geode_compact_test.wal.{d}", .{seg_index});
            defer gpa.free(path);
            if (std.fs.cwd().access(path, .{})) |_| {
                _ = try wal_recover.recover(&pm, path);
            } else |_| break;
        }
    }
}
