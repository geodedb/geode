const std = @import("std");
const wal_mod = @import("../src/wal/wal.zig");

// End-to-end test invoking wal_compact --auto to reclaim old segments.

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.segment_limit = 2 * 1024; // 2KB for faster rollover
    const base = "/tmp/geode_cli_compact_test";
    try wal.openFile(base);
    // Write enough records to create several segments, plus checkpoint.
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const page: u32 = @intCast(i % 11);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 7, 7, 7 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
        if (i == 250) _ = try wal.writeCheckpoint();
    }
    try wal.fsync();
    // Count segments before.
    var before: usize = 0;
    var seg: usize = 0;
    while (seg < 16) : (seg += 1) {
        const path = try std.fmt.allocPrint(gpa, "{s}.wal.{d}", .{ base, seg });
        defer gpa.free(path);
        if (std.fs.cwd().access(path, .{})) |_| before += 1 else |_| {}
    }
    // Run wal_compact --auto
    const exe_path = try std.fmt.allocPrint(gpa, "./zig-out/bin/wal_compact", .{});
    defer gpa.free(exe_path);
    var proc = std.ChildProcess.init(&.{ exe_path, "--base", base, "--auto" }, gpa);
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;
    try proc.spawn();
    const term = try proc.wait();
    if (term.Exited != 0) return error.CompactToolFailed;
    // Count segments after.
    var after: usize = 0;
    seg = 0;
    while (seg < 16) : (seg += 1) {
        const path2 = try std.fmt.allocPrint(gpa, "{s}.wal.{d}", .{ base, seg });
        defer gpa.free(path2);
        if (std.fs.cwd().access(path2, .{})) |_| after += 1 else |_| {}
    }
    if (!(after < before and after > 0)) return error.NoReclaim;
}
