const std = @import("std");
const geode = @import("geode");
const lfu = geode.graph.containers.lfu;
const Ctx = struct {};

// Zig 0.16: std.testing.fuzz hands the test a *Smith generator instead of a
// raw byte slice.  Draw a fuzzer-controlled byte slice from the Smith and
// feed it to the original byte-driven harness.
fn fuzz_lfu(context: Ctx, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const len = smith.slice(&buf);
    try fuzz_lfu_bytes(context, buf[0..len]);
}

fn fuzz_lfu_bytes(context: Ctx, data: []const u8) anyerror!void {
    _ = context;
    if (data.len == 0) return;
    const cap = @as(usize, (data[0] % 32));
    var cache = lfu.LfuU32U32.init(std.testing.allocator, cap);
    defer cache.deinit();

    var i: usize = 1;
    while (i + 4 <= data.len) : (i += 4) {
        const op = data[i] % 4;
        const k: u32 = @intCast((@as(u32, data[i]) << 24) | (@as(u32, data[i + 1]) << 16) | (@as(u32, data[i + 2]) << 8) | data[i + 3]);
        switch (op) {
            0 => {
                _ = cache.get(k);
            },
            1 => {
                _ = cache.remove(k);
            },
            2 => {
                const v: u32 = k ^ 0x9e3779b9;
                _ = cache.put(k, v) catch {};
            },
            3 => {
                _ = cache.get(k);
            },
            else => {},
        }
        if (cache.size() > cap) return error.Unexpected;
    }
}

test "fuzz lfu cache" {
    try std.testing.fuzz(Ctx{}, fuzz_lfu, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
