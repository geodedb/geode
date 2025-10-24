const std = @import("std");
const hnsw_persist = @import("hnsw_persist");
const hnsw = @import("hnsw");
const FuzzCtx = struct {};

fn capped(data: []const u8) []const u8 {
    return data[0..@min(data.len, 1_000_000)];
}

fn fuzz_hnsw_snapshot(context: FuzzCtx, data: []const u8) anyerror!void {
    _ = context;
    const slice = capped(data);
    var ally = std.testing.allocator;
    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/fuzz/hnsw", .{});
    defer tmp_dir.close();
    var name_buf: [64]u8 = undefined;
    const snap_name = try std.fmt.bufPrint(&name_buf, "snap-{d}.bin", .{@intFromPtr(slice.ptr)});
    const vec_name = try std.fmt.bufPrint(&name_buf, "vec-{d}.bin", .{@intFromPtr(slice.ptr) ^ 0x9e37});
    {
        var f = try tmp_dir.createFile(snap_name, .{});
        defer f.close();
        _ = try f.write(slice);
    }
    {
        var f = try tmp_dir.createFile(vec_name, .{});
        defer f.close();
        _ = try f.write(slice);
    }

    const snap_path = try std.fs.path.join(ally, &.{ "zig-cache/fuzz/hnsw", snap_name });
    defer ally.free(snap_path);
    const vec_path = try std.fs.path.join(ally, &.{ "zig-cache/fuzz/hnsw", vec_name });
    defer ally.free(vec_path);

    var loaded = hnsw_persist.loadSnapshot(ally, snap_path, vec_path) catch |e| switch (e) {
        error.InvalidMagic, error.InvalidVersion => return,
        else => return,
    };
    defer loaded.deinit();

    const out_snap = try std.fs.path.join(ally, &.{ "zig-cache/fuzz/hnsw", "out-snap.bin" });
    defer ally.free(out_snap);
    const out_vec = try std.fs.path.join(ally, &.{ "zig-cache/fuzz/hnsw", "out-vec.bin" });
    defer ally.free(out_vec);
    try hnsw_persist.saveSnapshot(&loaded, out_snap, out_vec);
}

test "fuzz hnsw snapshot" {
    try std.testing.fuzz(FuzzCtx{}, fuzz_hnsw_snapshot, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
