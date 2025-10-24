const std = @import("std");
const geode = @import("src/lib.zig");
const eval_ext = @import("src/eval_extended.zig");
const extf = @import("src/types/extended_functions.zig");

// Benchmark measuring overhead of bridged extended builtin vs direct local implementation.
// CANARY: REQ=REQ-GQL-082; FEATURE="ExtendedBuiltins"; ASPECT=PERFORMANCE; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_082_ExtendedBuiltinsAdapterOverhead; OWNER=engine; UPDATED=2025-09-26

// We compare invoking uuid_v4 via adapterFactory through eval_extended vs direct registry lookup extf.
// Metric: nanoseconds per call (mean) & ratio adapter/direct printed as JSON line.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const iterations: usize = 10_000;

    // Direct registry
    var direct_reg = try extf.initRegistry(alloc);
    defer direct_reg.deinit();
    const uuid_fn = direct_reg.get("uuid_v4") orelse return error.NotFound;

    var adapter_reg = try eval_ext.initFunctionRegistry(alloc);
    defer adapter_reg.deinit();
    const adapter_fn = adapter_reg.get("uuid_v4") orelse return error.NotFound;

    var t = std.time.Timer.start() catch unreachable;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const v = try uuid_fn(alloc, &[_]extf.BuiltinValue{});
        // free produced string
        if (v == .Str) alloc.free(v.Str);
    }
    const direct_ns = t.read();

    t.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const v = try adapter_fn(alloc, &[_]eval_ext.ExtValue{});
        if (v == .Str) {}
    }
    const adapter_ns = t.read();

    const direct_mean = @as(f64, @floatFromInt(direct_ns)) / @as(f64, @floatFromInt(iterations));
    const adapter_mean = @as(f64, @floatFromInt(adapter_ns)) / @as(f64, @floatFromInt(iterations));
    const ratio = adapter_mean / direct_mean;

    var stdout = std.io.getStdOut().writer();
    try std.json.stringify(.{ .bench = "BenchmarkCANARY_REQ_GQL_082_ExtendedBuiltinsAdapterOverhead", .iterations = iterations, .direct_ns = direct_ns, .adapter_ns = adapter_ns, .adapter_overhead_ratio = ratio }, .{}, stdout);
    try stdout.writeByte('\n');
}
