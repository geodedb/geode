const std = @import("std");
const extract = @import("../src/tools/bench_extract.zig");

// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Extraction"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchExtractParse; OWNER=engine; UPDATED=2025-09-20

test "TestCANARY_REQ_GQL_010_BenchExtractParse" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var wbuf: [2048]u8 = undefined;
    const w = buf.writer(&wbuf);
    try extract.parseLine("DiagnosticsFoldLarge total_bytes=100 allocs=50 elapsed_ns=12345", w);
    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"DiagnosticsFoldLarge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"total_bytes\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"elapsed_ns\":12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"raw\":\"DiagnosticsFoldLarge") != null);
}
