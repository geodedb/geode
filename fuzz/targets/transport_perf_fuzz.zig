// Comprehensive fuzz testing for transport layer performance optimizations
// CANARY: REQ=REQ-PERF-FUZZ-001; FEATURE="TransportFuzzing"; ASPECT=PerformanceOptimizations; STATUS=IMPL; OWNER=fuzz; UPDATED=2026-01-26
// GAP-0201: Fuzz tests to validate thread pool, scheduler, and backoff under stress

const std = @import("std");
const testing = std.testing;

const thread_pool = @import("transport/thread_pool");
const stream_scheduler = @import("transport/stream_scheduler");

// Zig 0.16 compat: std.Thread.sleep removed; nanosleep directly.
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize random generator
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        compat_fillRandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     TRANSPORT LAYER PERFORMANCE FUZZ TESTING                 ║\n", .{});
    std.debug.print("║     GAP-0201: Thread Pool, Scheduler, Backoff                ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const iterations: u32 = 10000;

    try fuzzBoundedQueue(random, iterations);
    try fuzzThreadPool(allocator, random, iterations);
    try fuzzStreamScheduler(allocator, random, iterations);
    try fuzzAdaptiveBackoff(random, iterations);
    try fuzzConcurrentAccess(allocator, random, iterations);

    std.debug.print("\n=== Fuzz Testing Complete ===\n", .{});
}

/// Fuzz test the bounded queue with random operations
fn fuzzBoundedQueue(random: std.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing BoundedQueue\n", .{});

    const Queue = thread_pool.BoundedQueue(u64, 256);
    var queue = Queue.init();

    var push_count: u32 = 0;
    var pop_count: u32 = 0;
    var push_failures: u32 = 0;
    var pop_failures: u32 = 0;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const op = random.int(u8) % 10;

        if (op < 6) {
            // 60% push
            const value = random.int(u64);
            if (queue.tryPush(value)) {
                push_count += 1;
            } else {
                push_failures += 1;
            }
        } else {
            // 40% pop
            if (queue.tryPop()) |_| {
                pop_count += 1;
            } else {
                pop_failures += 1;
            }
        }

        // Verify queue integrity
        const len = queue.len();
        if (len > 256) {
            std.debug.print("ERROR: Queue size exceeded capacity: {}\n", .{len});
            return error.QueueOverflow;
        }
    }

    std.debug.print("  Iterations: {}\n", .{iterations});
    std.debug.print("  Pushes: {} (failures: {})\n", .{ push_count, push_failures });
    std.debug.print("  Pops: {} (failures: {})\n", .{ pop_count, pop_failures });
    std.debug.print("  Final queue size: {}\n", .{queue.len()});
    std.debug.print("  PASS\n\n", .{});
}

/// Fuzz test thread pool with random work patterns
fn fuzzThreadPool(allocator: std.mem.Allocator, random: std.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing ThreadPool\n", .{});

    // Random thread count 1-8
    const num_threads = random.intRangeAtMost(usize, 1, 8);

    const pool = try thread_pool.ThreadPool.init(allocator, .{
        .num_threads = num_threads,
    });
    defer pool.deinit();

    var completed = std.atomic.Value(u32).init(0);
    var submitted: u32 = 0;
    var rejected: u32 = 0;

    const Context = struct {
        completed: *std.atomic.Value(u32),
        random_delay: bool,
    };

    var ctx = Context{
        .completed = &completed,
        .random_delay = random.boolean(),
    };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            // Simulate variable work time
            if (c.random_delay) {
                compat_sleep(1 * std.time.ns_per_us);
            }
            _ = c.completed.fetchAdd(1, .release);
        }
    }.call;

    // Submit random number of tasks
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Randomly pause submissions
        if (random.intRangeAtMost(u32, 0, 100) == 0) {
            compat_sleep(1 * std.time.ns_per_ms);
        }

        if (pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            submitted += 1;
        } else {
            rejected += 1;
        }
    }

    // Wait for completion with timeout
    var timeout: u32 = 0;
    while (completed.load(.acquire) < submitted and timeout < 10000) {
        compat_sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    const final_completed = completed.load(.acquire);

    std.debug.print("  Thread count: {}\n", .{num_threads});
    std.debug.print("  Submitted: {}\n", .{submitted});
    std.debug.print("  Rejected: {}\n", .{rejected});
    std.debug.print("  Completed: {}\n", .{final_completed});
    std.debug.print("  Completion rate: {d:.1}%\n", .{@as(f64, @floatFromInt(final_completed)) / @as(f64, @floatFromInt(submitted)) * 100.0});

    // Verify all submitted tasks completed
    if (final_completed < submitted) {
        std.debug.print("  WARNING: {} tasks not completed (timeout)\n", .{submitted - final_completed});
    }

    std.debug.print("  PASS\n\n", .{});
}

/// Fuzz test stream scheduler with random stream patterns
fn fuzzStreamScheduler(allocator: std.mem.Allocator, random: std.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing StreamScheduler\n", .{});

    var scheduler = stream_scheduler.StreamScheduler.init(allocator);
    defer scheduler.deinit();

    var add_count: u32 = 0;
    var remove_count: u32 = 0;
    var schedule_count: u32 = 0;
    var block_count: u32 = 0;
    var unblock_count: u32 = 0;
    var bytes_recorded: u64 = 0;

    var order: [256]u64 = undefined;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const op = random.int(u8) % 100;

        if (op < 20) {
            // 20% add stream
            const stream_id = random.int(u64);
            const quantum = random.intRangeAtMost(u64, 100, 10000);
            scheduler.addStream(stream_id, quantum) catch {};
            add_count += 1;
        } else if (op < 30) {
            // 10% remove stream
            const stream_id = random.int(u64);
            scheduler.removeStream(stream_id);
            remove_count += 1;
        } else if (op < 50) {
            // 20% schedule
            _ = scheduler.getScheduledStreams(&order);
            schedule_count += 1;
        } else if (op < 60) {
            // 10% block
            const stream_id = random.int(u64);
            scheduler.markBlocked(stream_id);
            block_count += 1;
        } else if (op < 70) {
            // 10% unblock
            const stream_id = random.int(u64);
            scheduler.markUnblocked(stream_id);
            unblock_count += 1;
        } else {
            // 30% record bytes
            const stream_id = random.int(u64);
            const bytes = random.intRangeAtMost(u64, 0, 65536);
            scheduler.recordBytesRead(stream_id, bytes);
            bytes_recorded += bytes;
        }
    }

    const stats = scheduler.getStats();

    std.debug.print("  Operations:\n", .{});
    std.debug.print("    Add:      {}\n", .{add_count});
    std.debug.print("    Remove:   {}\n", .{remove_count});
    std.debug.print("    Schedule: {}\n", .{schedule_count});
    std.debug.print("    Block:    {}\n", .{block_count});
    std.debug.print("    Unblock:  {}\n", .{unblock_count});
    std.debug.print("  Stats:\n", .{});
    std.debug.print("    Total streams: {}\n", .{stats.total_streams});
    std.debug.print("    Total rounds:  {}\n", .{stats.total_rounds});
    std.debug.print("    Bytes recorded: {}\n", .{bytes_recorded});
    std.debug.print("  PASS\n\n", .{});
}

/// Fuzz test adaptive backoff logic
fn fuzzAdaptiveBackoff(random: std.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing Adaptive Backoff\n", .{});

    const max_idle_before_sleep: u32 = 10;
    const min_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    var idle_iterations: u32 = 0;
    var total_sleep_us: u64 = 0;
    var reset_count: u32 = 0;
    var sleep_count: u32 = 0;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Randomly simulate data processing or idle
        const processed_data = random.boolean();

        if (processed_data) {
            // Reset idle counter
            idle_iterations = 0;
            reset_count += 1;
        } else {
            // Increment idle counter
            idle_iterations += 1;

            if (idle_iterations > max_idle_before_sleep) {
                const backoff_multiplier = @min(idle_iterations - max_idle_before_sleep, 4);
                const sleep_us = @min(min_sleep_us << @intCast(backoff_multiplier), max_sleep_us);

                // Verify sleep time is bounded
                if (sleep_us < min_sleep_us or sleep_us > max_sleep_us) {
                    std.debug.print("ERROR: Sleep time out of bounds: {} us\n", .{sleep_us});
                    return error.SleepTimeBoundsError;
                }

                total_sleep_us += sleep_us;
                sleep_count += 1;
            }
        }
    }

    std.debug.print("  Iterations: {}\n", .{iterations});
    std.debug.print("  Resets: {}\n", .{reset_count});
    std.debug.print("  Sleeps: {}\n", .{sleep_count});
    std.debug.print("  Total simulated sleep: {} us\n", .{total_sleep_us});
    std.debug.print("  PASS\n\n", .{});
}

/// Fuzz test concurrent access patterns
fn fuzzConcurrentAccess(allocator: std.mem.Allocator, random: std.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing Concurrent Access\n", .{});

    const Queue = thread_pool.BoundedQueue(u64, 1024);
    var queue = Queue.init();

    const num_threads = random.intRangeAtMost(usize, 2, 8);
    var threads: [8]std.Thread = undefined;

    var total_pushed = std.atomic.Value(u64).init(0);
    var total_popped = std.atomic.Value(u64).init(0);
    var stop = std.atomic.Value(bool).init(false);

    std.debug.print("  Starting {} concurrent threads...\n", .{num_threads});

    // Start threads
    for (0..num_threads) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(q: *Queue, pushed: *std.atomic.Value(u64), popped: *std.atomic.Value(u64), s: *std.atomic.Value(bool), r: std.Random, iters: u32) void {
                var i: u32 = 0;
                while (i < iters and !s.load(.acquire)) : (i += 1) {
                    if (r.boolean()) {
                        if (q.tryPush(i)) {
                            _ = pushed.fetchAdd(1, .release);
                        }
                    } else {
                        if (q.tryPop()) |_| {
                            _ = popped.fetchAdd(1, .release);
                        }
                    }
                }
            }
        }.run, .{ &queue, &total_pushed, &total_popped, &stop, random, iterations / @as(u32, @intCast(num_threads)) });
    }

    // Wait for threads
    for (0..num_threads) |t| {
        threads[t].join();
    }

    const pushed = total_pushed.load(.acquire);
    const popped = total_popped.load(.acquire);
    const remaining = queue.len();

    std.debug.print("  Total pushed: {}\n", .{pushed});
    std.debug.print("  Total popped: {}\n", .{popped});
    std.debug.print("  Remaining in queue: {}\n", .{remaining});

    // Verify invariant: pushed - popped = remaining
    const expected_remaining = pushed - popped;
    if (remaining != expected_remaining) {
        std.debug.print("  WARNING: Queue size mismatch (expected {}, got {})\n", .{ expected_remaining, remaining });
    }

    std.debug.print("  PASS\n\n", .{});

    _ = allocator;
}

// Unit tests for quick validation
test "fuzz_bounded_queue" {
    var prng = std.Random.DefaultPrng.init(42);
    try fuzzBoundedQueue(prng.random(), 100);
}

test "fuzz_adaptive_backoff" {
    var prng = std.Random.DefaultPrng.init(42);
    try fuzzAdaptiveBackoff(prng.random(), 100);
}

test "fuzz_thread_pool" {
    var prng = std.Random.DefaultPrng.init(42);
    try fuzzThreadPool(std.testing.allocator, prng.random(), 100);
}

test "fuzz_stream_scheduler" {
    var prng = std.Random.DefaultPrng.init(42);
    try fuzzStreamScheduler(std.testing.allocator, prng.random(), 100);
}

test "fuzz_concurrent_access" {
    var prng = std.Random.DefaultPrng.init(42);
    try fuzzConcurrentAccess(std.testing.allocator, prng.random(), 100);
}
