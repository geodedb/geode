const std = @import("std");
const queue_mod = @import("../src/containers/signaled_queue.zig");

// Benchmark SignaledQueue SPMC variance envelope.
// Single producer, multiple consumers.
// Thresholds (General class): CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueueSpmcVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_068_SignaledQueueSpmcVarianceEnvelope; OWNER=graph; UPDATED=2025-09-23

fn getJitterNs() u64 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_BENCH_JITTER_NS")) |val| {
        defer std.heap.page_allocator.free(val);
        return std.fmt.parseInt(u64, val, 10) catch 0;
    } else |_| {}
    return 0;
}

fn run_spmc(allocator: std.mem.Allocator, consumers: usize, total_items: usize) u64 {
    var q = queue_mod.SignaledQueue(usize).init(allocator);
    defer q.deinit();

    var consumed = std.atomic.Value(usize).init(0);
    var timer = std.time.Timer.start() catch unreachable;
    const jitter = getJitterNs();

    // Spawn consumers
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    var ci: usize = 0;
    while (ci < consumers) : (ci += 1) {
        const th = std.Thread.spawn(.{}, struct {
            fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), consumed: *std.atomic.Value(usize), total: usize, jitter: u64 }) void {
                while (true) {
                    if (ctx.jitter > 0) std.time.sleep(ctx.jitter);
                    const r = ctx.q.dequeue();
                    switch (r) {
                        error.Closed => return,
                        else => |opt| {
                            if (opt) |_| {
                                const prev = ctx.consumed.fetchAdd(1, .SeqCst);
                                if (prev + 1 >= ctx.total) {
                                    ctx.q.close();
                                    return;
                                }
                            }
                        },
                    }
                }
            }
        }.run, .{ .q = &q, .consumed = &consumed, .total = total_items, .jitter = jitter }) catch unreachable;
        threads.append(th) catch unreachable;
    }

    // Producer
    const producer_th = std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), total: usize, jitter: u64 }) void {
            var i: usize = 0;
            while (i < ctx.total) : (i += 1) {
                if (ctx.jitter > 0 and (i & 63) == 0) std.time.sleep(ctx.jitter);
                _ = ctx.q.enqueue(i) catch return;
            }
        }
    }.run, .{ .q = &q, .total = total_items, .jitter = jitter }) catch unreachable;

    // Join producer; consumers will close when done
    producer_th.join();
    var idx: usize = 0;
    while (idx < threads.items.len) : (idx += 1) threads.items[idx].join();

    const got = consumed.load(.SeqCst);
    if (got != total_items) {
        std.debug.print("SPMC consumed mismatch: got {d}, expected {d}\n", .{ got, total_items });
    }

    return timer.read();
}

fn computeStats(samples: []const u64) struct { mean: f128, cv: f128, p95_ratio: f128 } {
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff_sum: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff_sum += d * d;
    }
    const variance = diff_sum / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean_f;

    // Deterministic selection sort
    var a: usize = 0;
    var tmp: u64 = 0;
    var buf = std.heap.page_allocator.alloc(u64, samples.len) catch unreachable;
    defer std.heap.page_allocator.free(buf);
    std.mem.copy(u64, buf, samples);
    while (a < buf.len) : (a += 1) {
        var min_idx = a;
        var b = a + 1;
        while (b < buf.len) : (b += 1) {
            if (buf[b] < buf[min_idx]) {
                min_idx = b;
            }
        }
        if (min_idx != a) {
            tmp = buf[a];
            buf[a] = buf[min_idx];
            buf[min_idx] = tmp;
        }
    }
    const p95_index = (buf.len * 95) / 100;
    const p95 = buf[p95_index];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    return .{ .mean = mean_f, .cv = cv, .p95_ratio = p95_ratio };
}

pub fn benchmarkSignaledQueueSpmcVarianceEnvelope() !void {
    const iterations = 64;
    const consumers = 4;
    const total_items = 1024;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) samples[i] = run_spmc(allocator, consumers, total_items);

    const stats = computeStats(samples);
    if (stats.cv > 0.22 or stats.p95_ratio > 2.55) {
        std.debug.print("SignaledQueue SPMC variance envelope breached: cv={d:.4} p95/mean={d:.4}\n", .{ stats.cv, stats.p95_ratio });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_068_SignaledQueueSpmcVarianceEnvelope" {
    try benchmarkSignaledQueueSpmcVarianceEnvelope();
}
