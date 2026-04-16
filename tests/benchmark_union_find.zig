const std = @import("std");
const uf_mod = @import("../src/graph/union_find.zig");

// BenchmarkCANARY_REQ_GQL_068_UnionFind
test "BenchmarkCANARY_REQ_GQL_068_UnionFind" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const n: u32 = 20_000;
    var uf = try uf_mod.UnionFind.init(alloc, n);
    defer uf.deinit(alloc);
    var prng = std.rand.DefaultPrng.init(0xF0F068);
    const rand = prng.random();
    const ops: usize = 50_000;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const a = rand.intRangeLessThan(u32, 0, n);
        const b = rand.intRangeLessThan(u32, 0, n);
        _ = uf.unite(a, b);
        _ = uf.find(a);
        _ = uf.find(b);
    }
    const end = std.time.nanoTimestamp();
    const dur = @as(f64, @floatFromInt(end - start));
    // Expect under 80ms
    try std.testing.expect(dur < 80_000_000.0);
    var bw = std.Io.bufferedWriter(std.Io.getStdErr().writer());
    const w = bw.writer();
    try w.print("{\"metric\":\"union_find_batch_ns\",\"value\":{d:.2}}\n", .{dur});
    try bw.flush();
}
