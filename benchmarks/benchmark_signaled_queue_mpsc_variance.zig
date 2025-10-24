const std = @import("std");
const queue_mod = @import("../src/containers/signaled_queue.zig");

// Benchmark SignaledQueue MPSC variance envelope.
// Multiple producers, single consumer.
// Thresholds (General class): CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueueMpscVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_068_SignaledQueueMpscVarianceEnvelope; OWNER=graph; UPDATED=2025-09-23

fn getJitterNs() u64 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_BENCH_JITTER_NS")) |val| {
        defer std.heap.page_allocator.free(val);
        return std.fmt.parseInt(u64, val, 10) catch 0;
    } else |_| {}
    return 0;
}

fn run_mpsc(allocator: std.mem.Allocator, producers: usize, items_per_producer: usize) u64 {
    var q = queue_mod.SignaledQueue(usize).init(allocator);
    defer q.deinit();

    const total_items: usize = producers * items_per_producer;
    var consumed = std.atomic.Value(usize).init(0);

    var timer = std.time.Timer.start() catch unreachable;

    const jitter = getJitterNs();

    // Spawn single consumer
    const consumer_th = std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), consumed: *std.atomic.Value(usize), jitter: u64 }) void {
            while (true) {
                if (ctx.jitter > 0) std.time.sleep(ctx.jitter);
                const r = ctx.q.dequeue();
                switch (r) {
                    error.Closed => return,
                    else => |opt| {
                        if (opt) |_| {
                            _ = ctx.consumed.fetchAdd(1, .SeqCst);
                        } else {
                            // spurious wake
                        }
                    },
                }
            }
        }
    }.run, .{ .q = &q, .consumed = &consumed, .jitter = jitter }) catch unreachable;

    // Spawn producers
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    var pi: usize = 0;
    while (pi < producers) : (pi += 1) {
        const start_idx = pi * items_per_producer;
        const th = std.Thread.spawn(.{}, struct {
            fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), start: usize, count: usize, jitter: u64 }) void {
                var i: usize = 0;
                while (i < ctx.count) : (i += 1) {
                    if (ctx.jitter > 0 and (i & 63) == 0) std.time.sleep(ctx.jitter);
                    _ = ctx.q.enqueue(ctx.start + i) catch return;
                }
            }
        }.run, .{ .q = &q, .start = start_idx, .count = items_per_producer, .jitter = jitter }) catch unreachable;
        threads.append(th) catch unreachable;
    }

    // Wait for producers to finish, then close to let consumer exit
    var idx: usize = 0;
    while (idx < threads.items.len) : (idx += 1) threads.items[idx].join();
    q.close();

    consumer_th.join();

    // Ensure all items accounted for (best-effort sanity; not enforced here)
    const got = consumed.load(.SeqCst);
    if (got != total_items) {
        std.debug.print("MPSC consumed mismatch: got {d}, expected {d}\n", .{ got, total_items });
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

pub fn benchmarkSignaledQueueMpscVarianceEnvelope() !void {
    const iterations = 64;
    const producers = 4;
    const items_per_producer = 256;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) samples[i] = run_mpsc(allocator, producers, items_per_producer);

    const stats = computeStats(samples);
    if (stats.cv > 0.22 or stats.p95_ratio > 2.55) {
        std.debug.print("SignaledQueue MPSC variance envelope breached: cv={d:.4} p95/mean={d:.4}\n", .{ stats.cv, stats.p95_ratio });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_068_SignaledQueueMpscVarianceEnvelope" {
    try benchmarkSignaledQueueMpscVarianceEnvelope();
}
