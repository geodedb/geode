const std = @import("std");

// Adaptive pagination prefetch simulator.
// Models a simple prefetch scheduler that issues asynchronous (simulated) fetches for next pages
// based on a sliding window and observed mean latency. We use synthetic CPU loops to represent
// page fetch cost and measure the latency experienced by the consumer when requesting each page.
// If a page is already prefetched (completed), consumer latency ~0; else it waits for residual work.
// This allows us to later benchmark stability (variance envelope) of end-user perceived latency under
// varying window sizes and page size distributions.
//
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationPrefetchSimulation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationPrefetchSimulation; OWNER=planner; UPDATED=2025-09-21

pub const PrefetchConfig = struct {
    window: usize = 2, // number of pages ahead to prefetch
    base_page_cost_units: usize = 800, // synthetic unit cost baseline
    cost_jitter_ppm: u32 = 50_000, // up to 5% jitter inject
    pages: usize = 24, // total pages simulated
    page_size: usize = 128, // influences work multiplier
};

pub const PageMetric = struct { consumer_latency_ns: u64, prefetched: bool };

fn lcgNext(state: *u64) u64 {
    state.* = state.* * 6364136223846793005 + 1;
    return state.*;
}

fn simulateWork(units: usize) void {
    var acc: usize = 0;
    var i: usize = 0;
    while (i < units) : (i += 1) {
        acc +%= i * 2654435761;
        if ((i & 127) == 0) std.mem.doNotOptimizeAway(acc);
    }
    if (acc == 0xDEADBEEF) std.mem.doNotOptimizeAway(&acc);
}

// Runs the simulation returning per-page consumer latency metrics.
pub fn runSimulation(ally: std.mem.Allocator, cfg: PrefetchConfig, seed: u64) ![]PageMetric {
    var metrics = try ally.alloc(PageMetric, cfg.pages);
    var page_done = try ally.alloc(bool, cfg.pages);
    std.mem.set(bool, page_done, false);
    var rng = seed | 1;
    // Prefetch queue simulated synchronously: we simulate time elapsing for prefetch work in advance.
    // We'll maintain an array of synthetic completion times in nanoseconds (monotonic timeline increments).
    var completion_times = try ally.alloc(u64, cfg.pages);
    defer ally.free(completion_times);
    var current_time: u64 = 0;
    var p: usize = 0;
    while (p < cfg.pages) : (p += 1) {
        // Ensure prefetch window filled.
        var w: usize = p;
        while (w < cfg.pages and w < p + cfg.window) : (w += 1) {
            if (!page_done[w]) {
                // schedule (simulate work now to produce completion time)
                _ = lcgNext(&rng);
                const jitter = (@as(usize, @intCast(rng & 0xFFFF)) * cfg.cost_jitter_ppm) / 1_000_000;
                const cost_units = cfg.base_page_cost_units + (cfg.page_size / 8) + jitter;
                const t0 = std.time.nanoTimestamp();
                simulateWork(cost_units);
                const t1 = std.time.nanoTimestamp();
                current_time += @intCast(t1 - t0); // advance synthetic global time by actual work cost
                completion_times[w] = current_time;
                page_done[w] = true;
            }
        }
        // Consumer requests page p at current_time.
        // If completion_times[p] <= current_time the page is ready (prefetched): latency 0.
        const ready = completion_times[p] <= current_time;
        var latency: u64 = 0;
        if (!ready) {
            // Work still in progress (should not happen with synchronous simulate scheduling, but kept for future async model)
            latency = completion_times[p] - current_time;
            current_time = completion_times[p];
        }
        metrics[p] = .{ .consumer_latency_ns = latency, .prefetched = ready };
    }
    ally.free(page_done);
    return metrics;
}

test "TestCANARY_REQ_GQL_004_PaginationPrefetchSimulation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const cfg: PrefetchConfig = .{ .window = 3, .pages = 16, .page_size = 64 };
    const metrics = try runSimulation(gpa.allocator(), cfg, 12345);
    defer gpa.allocator().free(metrics);
    // Expect majority of pages prefetched (latency zero) with window 3.
    var zero_lat: usize = 0;
    for (metrics) |m| {
        if (m.consumer_latency_ns == 0) zero_lat += 1;
    }
    try std.testing.expect(zero_lat >= cfg.pages - cfg.window);
}
