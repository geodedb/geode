const std = @import("std");
const queue_mod = @import("../src/containers/signaled_queue.zig");

// Benchmark SignaledQueue MPMC variance envelope.
// Measures stability of enqueue/dequeue under multi-producer/multi-consumer contention.
// Thresholds (General class): CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=SignaledQueueMpmcVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_068_SignaledQueueMpmcVarianceEnvelope; OWNER=graph; UPDATED=2025-09-23

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Zig 0.16 compat: std.Thread.sleep / std.time.sleep removed; use raw nanosleep syscall.
fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

fn getJitterNs() u64 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_BENCH_JITTER_NS")) |val| {
        defer std.heap.page_allocator.free(val);
        return std.fmt.parseInt(u64, val, 10) catch 0;
    } else |_| {}
    return 0;
}

fn run_mpmc(allocator: std.mem.Allocator, producers: usize, consumers: usize, items_per_producer: usize) u64 {
    var q = queue_mod.SignaledQueue(usize).init(allocator);
    defer q.deinit();

    const total_items: usize = producers * items_per_producer;
    var consumed = std.atomic.Value(usize).init(0);

    const timer_start_ns = nowNs();

    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);

    const jitter = getJitterNs();

    // Spawn consumers first
    var ci: usize = 0;
    while (ci < consumers) : (ci += 1) {
        const th = std.Thread.spawn(.{}, struct {
            fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), consumed: *std.atomic.Value(usize), total: usize, jitter: u64 }) void {
                while (true) {
                    if (ctx.jitter > 0) sleepNs(ctx.jitter);
                    const r = ctx.q.dequeue();
                    switch (r) {
                        error.Closed => return,
                        else => |opt| {
                            if (opt) |_| {
                                const prev = ctx.consumed.fetchAdd(1, .seq_cst);
                                if (prev + 1 >= ctx.total) {
                                    // signal completion by closing the queue
                                    ctx.q.close();
                                    return;
                                }
                            } else {
                                // spurious wake up, continue
                            }
                        },
                    }
                }
            }
        }.run, .{ .q = &q, .consumed = &consumed, .total = total_items, .jitter = jitter }) catch unreachable;
        threads.append(allocator, th) catch unreachable;
    }

    // Spawn producers
    var pi: usize = 0;
    while (pi < producers) : (pi += 1) {
        const start_idx = pi * items_per_producer;
        const th = std.Thread.spawn(.{}, struct {
            fn run(ctx: struct { q: *queue_mod.SignaledQueue(usize), start: usize, count: usize, jitter: u64 }) void {
                var i: usize = 0;
                while (i < ctx.count) : (i += 1) {
                    if (ctx.jitter > 0 and (i & 63) == 0) sleepNs(ctx.jitter);
                    _ = ctx.q.enqueue(ctx.start + i) catch return;
                }
            }
        }.run, .{ .q = &q, .start = start_idx, .count = items_per_producer, .jitter = jitter }) catch unreachable;
        threads.append(allocator, th) catch unreachable;
    }

    // Join threads
    var idx: usize = 0;
    while (idx < threads.items.len) : (idx += 1) threads.items[idx].join();

    return nowNs() - timer_start_ns;
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
    @memcpy(buf, samples);
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

pub fn benchmarkSignaledQueueMpmcVarianceEnvelope() !void {
    const iterations = 64;
    const producers = 4;
    const consumers = 4;
    const items_per_producer = 256;

    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) samples[i] = run_mpmc(allocator, producers, consumers, items_per_producer);

    const stats = computeStats(samples);
    if (stats.cv > 0.22 or stats.p95_ratio > 2.55) {
        std.debug.print("SignaledQueue MPMC variance envelope breached: cv={d:.4} p95/mean={d:.4}\n", .{ stats.cv, stats.p95_ratio });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_068_SignaledQueueMpmcVarianceEnvelope" {
    try benchmarkSignaledQueueMpmcVarianceEnvelope();
}
