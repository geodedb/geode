const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Large Fold"; ASPECT=Engine; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge; OWNER=engine; UPDATED=2025-09-20

fn foldDiagnostics(allocator: std.mem.Allocator, n: usize) !struct { total_bytes: usize, allocs: usize } {
    var list = std.ArrayList([]u8).init(allocator);
    defer list.deinit();
    var i: usize = 0;
    var total_allocs: usize = 0;
    while (i < n) : (i += 1) {
        const msg = try std.fmt.allocPrint(allocator, "D{d}:{s}", .{ i, if (i % 3 == 0) "US001" else "OK" });
        total_allocs += 1;
        try list.append(msg);
    }
    // compute total bytes
    var total: usize = 0;
    for (list.items) |m| total += m.len;
    for (list.items) |m| allocator.free(m);
    return .{ .total_bytes = total, .allocs = total_allocs };
}

test "BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var timer = try std.time.Timer.start();
    const result = foldDiagnostics(allocator, 50_000) catch .{ .total_bytes = 0, .allocs = 0 };
    const ns = timer.read();
    // Expect fewer than 60k allocations (should be exactly n) and total bytes > n*6 (heuristic)
    try std.testing.expect(result.allocs <= 60_000);
    try std.testing.expect(result.total_bytes > 300_000);
    std.debug.print("DiagnosticsFoldLarge total_bytes={d} allocs={d} elapsed_ns={d}\n", .{ result.total_bytes, result.allocs, ns });
}
