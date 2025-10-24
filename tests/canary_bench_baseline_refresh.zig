const std = @import("std");
const regress = @import("../src/tools/bench_regress.zig");
// TestCANARY_REQ_GQL_010_BenchBaselineRefresh
// Validates that writeBaseline helper produces a line containing kind and metric name/value.

test "TestCANARY_REQ_GQL_010_BenchBaselineRefresh" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const tmp_dir = try std.fs.cwd().makeOpenPath(".tmp_bench_baseline", .{});
    defer tmp_dir.close();
    const file_path = ".tmp_bench_baseline/out.jsonl";
    try regress.testWriteBaseline(allocator, file_path);
    var f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();
    var buf: [512]u8 = undefined;
    const n = try f.readAll(&buf);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "KIND1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "elapsed_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "1234") != null);
}
