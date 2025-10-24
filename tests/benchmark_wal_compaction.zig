const std = @import("std");
const wal = @import("../src/storage/wal_compactor.zig");

// BenchmarkCANARY_REQ_GQL_028_WalCompact - synthetic benchmark for WAL compaction cycle.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prepare synthetic log segments metadata; we assume wal.compact takes a context with segments list.
    var segments = std.ArrayList(wal.SegmentMeta).init(allocator);
    defer segments.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const id: u32 = @intCast(i);
        try segments.append(.{ .id = id, .live_bytes = 1024, .dead_bytes = 256 });
    }

    var ctx = wal.CompactionContext{ .segments = segments.items, .threshold = 0.20 }; // stub style context

    var timer = try std.time.Timer.start();
    const rounds: usize = 200;
    var r: usize = 0;
    var total_compacted: usize = 0;
    while (r < rounds) : (r += 1) {
        const c = wal.compact(&ctx) catch 0; // ignore errors for synthetic run
        total_compacted += c;
    }
    const ns = timer.read();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_028_WalCompact\",\"rounds\":{d},\"segments\":{d},\"total_compacted\":{d},\"total_ns\":{d}}\n", .{ rounds, segments.items.len, total_compacted, ns });
}
