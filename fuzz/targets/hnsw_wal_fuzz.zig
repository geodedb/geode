const std = @import("std");
const hnsw_persist = @import("hnsw_persist");
const hnsw = @import("hnsw");
const FuzzCtx = struct {};

fn cap(data: []const u8) []const u8 {
    return data[0..@min(data.len, 1_000_000)];
}

fn fuzz_hnsw_wal(context: FuzzCtx, data: []const u8) anyerror!void {
    _ = context;
    const slice = cap(data);
    const ally = std.testing.allocator;
    var idx = hnsw.Hnsw.init(ally, 4, 4, 16);
    defer idx.deinit();

    var dir = try std.fs.cwd().makeOpenPath("zig-cache/fuzz/hnsw", .{});
    defer dir.close();
    const wal_path = try std.fs.path.join(ally, &.{ "zig-cache/fuzz/hnsw", "wal.bin" });
    defer ally.free(wal_path);
    {
        var f = try std.fs.cwd().createFile(wal_path, .{});
        defer f.close();
        _ = try f.write(slice);
    }
    _ = hnsw_persist.replayWal(&idx, wal_path) catch |e| switch (e) {
        error.InvalidWalOp => return,
        else => return,
    };
}

test "fuzz hnsw wal" {
    try std.testing.fuzz(FuzzCtx{}, fuzz_hnsw_wal, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
