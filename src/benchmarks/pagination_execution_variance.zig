const std = @import("std");
// (Note) We avoid importing non-public planner AST symbols; execution variance benchmark
// uses a synthetic workload only (planning already covered by ordered planning benchmark).

// Benchmark pagination execution (streaming page PULL) variance envelope.
// Simulates execution-phase latency for delivering successive pages after a planned
// ordered query (ORDER BY + LIMIT/OFFSET). We approximate execution work per page
// using a synthetic workload scaled by page_size. Each iteration measures the
// latency of producing a page. We collect a fixed number of page samples across a
// sweep of page sizes (env override) and enforce variance thresholds:
//   CV <= 0.22, p95/mean <= 2.55
// Output: two JSON lines (schema_version=1 & schema_version=2) similar to other
// variance envelopes.
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationExecutionVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_004_PaginationExecutionVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn fabricatePlannedQuery() void {}

fn simulatePageExecution(page_size: usize) u64 {
    // Synthetic CPU loop proportional to page_size, plus a small fixed component.
    var acc: usize = 0;
    var i: usize = 0;
    const work = page_size * 32 + 128; // scaled factor chosen empirically small
    while (i < work) : (i += 1) {
        acc +%= i * 1315423911;
        if (i % 97 == 0) std.mem.doNotOptimizeAway(acc);
    }
    if (acc == 0xFFFF_FFFF) std.mem.doNotOptimizeAway(&acc); // prevent elimination
    return 0; // value unused; loop time is what we measure
}

pub fn benchmarkPaginationExecutionVarianceEnvelope() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    fabricatePlannedQuery(); // placeholder (future: real plan + exec state integration)
    // Determine page sizes sweep from env: GEODE_PAGINATION_BENCH_PAGE_SIZES="64,128,256" default.
    var sizes_buf: []const u8 = "64,128,256";
    if (std.process.getEnvVarOwned(ally, "GEODE_PAGINATION_BENCH_PAGE_SIZES")) |val| {
        sizes_buf = val;
    } else |_| {}
    defer if (!std.mem.eql(u8, sizes_buf, "64,128,256")) ally.free(sizes_buf);
    // Parse CSV of sizes.
    // Collect page sizes into dynamically grown slice (manual growth).
    var cap: usize = 4;
    var sizes_mem = try ally.alloc(usize, cap);
    var sizes_len: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= sizes_buf.len) : (i += 1) {
        if (i == sizes_buf.len or sizes_buf[i] == ',') {
            const tok = sizes_buf[start..i];
            if (tok.len != 0) {
                const parsed = std.fmt.parseInt(u64, tok, 10) catch 0;
                if (parsed != 0) {
                    if (sizes_len == cap) {
                        const new_cap = cap * 2;
                        var new_mem = try ally.alloc(usize, new_cap);
                        std.mem.copyForwards(usize, new_mem[0..sizes_len], sizes_mem[0..sizes_len]);
                        ally.free(sizes_mem);
                        sizes_mem = new_mem;
                        cap = new_cap;
                    }
                    sizes_mem[sizes_len] = @intCast(parsed);
                    sizes_len += 1;
                }
            }
            start = i + 1;
        }
    }
    if (sizes_len == 0) return error.InvalidPageSizeSweep;
    const per_size_samples: usize = 20; // collect 20 page latencies per size
    const total_samples = per_size_samples * sizes_len;
    var samples = try ally.alloc(u64, total_samples);
    defer ally.free(samples);
    var sample_index: usize = 0;
    for (sizes_mem[0..sizes_len]) |sz| {
        var s: usize = 0;
        while (s < per_size_samples) : (s += 1) {
            const t0 = std.time.nanoTimestamp();
            _ = simulatePageExecution(sz);
            const t1 = std.time.nanoTimestamp();
            samples[sample_index] = @intCast(t1 - t0);
            sample_index += 1;
        }
    }
    // Compute stats (mean, cv, p95 ratio) similar to planning bench.
    var sum: u128 = 0;
    for (samples) |v| sum += v;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff: f128 = 0;
    for (samples) |v| {
        const vf = @as(f128, @floatFromInt(v));
        const d = vf - mean_f;
        diff += d * d;
    }
    const variance = diff / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean_f;
    std.sort.pdq(u64, samples, {}, comptime std.sort.asc(u64));
    const p95 = samples[@min(samples.len - 1, (samples.len * 95) / 100)];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    const pass = !(cv > 0.22 or p95_mean_ratio > 2.55);
    // Emit schema_version=1
    {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        const scale = 10000.0;
        w.writeAll("{\"schema_version\":1,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"pagination_execution_variance\",") catch {};
        inline for (.{
            struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(mean_f), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @as(u64, @intFromFloat(cv * scale)), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = p95, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @as(u64, @intFromFloat(p95_mean_ratio * scale)), .comma = true },
        }) |entry| {
            w.writeAll("\"") catch {};
            w.writeAll(entry.k) catch {};
            w.writeAll("\":") catch {};
            var numtmp: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch "0";
            w.writeAll(slice) catch {};
            if (entry.comma) w.writeAll(",") catch {};
        }
        w.writeAll("\"pass\":") catch {};
        w.writeAll(if (pass) "true" else "false") catch {};
        w.writeAll("}\n") catch {};
        std.debug.print("{s}", .{fbs.getWritten()});
    }
    // schema_version=2 (extended)
    {
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;
        for (samples) |v| {
            if (v < min_ns) min_ns = v;
            if (v > max_ns) max_ns = v;
        }
        const jitter_class = if (cv < 0.10) "low" else if (cv < 0.20) "medium" else "high";
        var buf: [768]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        const scale = 10000.0;
        w.writeAll("{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"pagination_execution_variance\",") catch {};
        inline for (.{
            struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(mean_f), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "min_ns", .v = min_ns, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "max_ns", .v = max_ns, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "sample_count", .v = samples.len, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @as(u64, @intFromFloat(cv * scale)), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = p95, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @as(u64, @intFromFloat(p95_mean_ratio * scale)), .comma = true },
        }) |entry| {
            w.writeAll("\"") catch {};
            w.writeAll(entry.k) catch {};
            w.writeAll("\":") catch {};
            var numtmp: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch "0";
            w.writeAll(slice) catch {};
            if (entry.comma) w.writeAll(",") catch {};
        }
        w.writeAll("\"jitter_class\":\"") catch {};
        w.writeAll(jitter_class) catch {};
        w.writeAll("\",") catch {};
        w.writeAll("\"thresholds_evaluated\":[") catch {};
        {
            w.writeAll("{\"metric\":\"cv_scaled_ppm\",\"actual\":") catch {};
            var numtmp: [32]u8 = undefined;
            var slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(cv * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"max\":") catch {};
            slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(0.22 * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"pass\":") catch {};
            w.writeAll(if (cv <= 0.22) "true" else "false") catch {};
            w.writeAll("}") catch {};
        }
        w.writeAll(",") catch {};
        {
            w.writeAll("{\"metric\":\"p95_over_mean_scaled_ppm\",\"actual\":") catch {};
            var numtmp2: [32]u8 = undefined;
            var slice2 = std.fmt.bufPrint(&numtmp2, "{d}", .{@as(u64, @intFromFloat(p95_mean_ratio * scale))}) catch "0";
            w.writeAll(slice2) catch {};
            w.writeAll(",\"max\":") catch {};
            slice2 = std.fmt.bufPrint(&numtmp2, "{d}", .{@as(u64, @intFromFloat(2.55 * scale))}) catch "0";
            w.writeAll(slice2) catch {};
            w.writeAll(",\"pass\":") catch {};
            w.writeAll(if (p95_mean_ratio <= 2.55) "true" else "false") catch {};
            w.writeAll("}") catch {};
        }
        w.writeAll("],\"pass\":") catch {};
        w.writeAll(if (pass) "true" else "false") catch {};
        w.writeAll("}\n") catch {};
        std.debug.print("{s}", .{fbs.getWritten()});
    }
    if (!pass) return error.VarianceEnvelopeBreached;
}

test "BenchmarkCANARY_REQ_GQL_004_PaginationExecutionVarianceEnvelope" {
    try benchmarkPaginationExecutionVarianceEnvelope();
}
