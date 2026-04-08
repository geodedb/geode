const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-QUIC-MUX-005; FEATURE="ActiveStreamRegistryTests"; ASPECT=ParallelCorrectness; STATUS=IMPL; OWNER=test; UPDATED=2026-04-08
const registry_mod = @import("server/active_stream_registry");
const ActiveStreamRegistry = registry_mod.ActiveStreamRegistry;

test "ActiveStreamRegistry: deduplicates and reuses stream ids" {
    var registry = ActiveStreamRegistry{};

    try testing.expect(try registry.register(4));
    try testing.expect(!try registry.register(4));
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expect(registry.contains(4));
    try testing.expect(registry.unregister(4));
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expect(try registry.register(4));
}

test "ActiveStreamRegistry: enforces per-connection stream cap" {
    var registry = ActiveStreamRegistry{};

    for (0..registry_mod.max_total_streams_per_connection) |i| {
        try testing.expect(try registry.register(@intCast(i + 1)));
    }

    try testing.expectEqual(@as(usize, registry_mod.max_total_streams_per_connection), registry.count());
    try testing.expectError(error.StreamRegistryFull, registry.register(9999));
}

test "ActiveStreamRegistry: concurrent duplicate registrations have a single owner" {
    const worker_count = 16;

    var registry = ActiveStreamRegistry{};
    var ready = std.atomic.Value(bool).init(false);
    var success_count = std.atomic.Value(u32).init(0);
    var duplicate_count = std.atomic.Value(u32).init(0);
    var stream_registry_full_count = std.atomic.Value(u32).init(0);

    var threads: [worker_count]std.Thread = undefined;
    var contexts: [worker_count]WorkerContext = undefined;

    for (&contexts, 0..) |*context, worker_index| {
        context.* = .{
            .registry = &registry,
            .ready = &ready,
            .success_count = &success_count,
            .duplicate_count = &duplicate_count,
            .base_stream_id = 42,
            .iterations = 1,
            .worker_index = worker_index,
            .stream_id_span = 1,
            .expect_duplicate_only = false,
            .unexpected_success_count = null,
            .failed_unregister_count = null,
            .stream_registry_full_count = &stream_registry_full_count,
        };
    }

    for (&threads, 0..) |*thread, worker_index| {
        thread.* = try std.Thread.spawn(.{}, workerMain, .{&contexts[worker_index]});
    }

    ready.store(true, .release);
    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(u32, 1), success_count.load(.acquire));
    try testing.expectEqual(@as(u32, worker_count - 1), duplicate_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), stream_registry_full_count.load(.acquire));
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expect(registry.unregister(42));
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "ActiveStreamRegistry: duplicate storms stay duplicate-only under parallel load" {
    const worker_count = 8;
    const active_stream_count = registry_mod.max_total_streams_per_connection;
    const iterations = 20_000;

    var registry = ActiveStreamRegistry{};
    for (0..active_stream_count) |i| {
        try testing.expect(try registry.register(@intCast(i + 1)));
    }

    var ready = std.atomic.Value(bool).init(false);
    var duplicate_count = std.atomic.Value(u32).init(0);
    var unexpected_success_count = std.atomic.Value(u32).init(0);
    var stream_registry_full_count = std.atomic.Value(u32).init(0);

    var threads: [worker_count]std.Thread = undefined;
    var contexts: [worker_count]WorkerContext = undefined;

    for (&contexts, 0..) |*context, worker_index| {
        context.* = .{
            .registry = &registry,
            .ready = &ready,
            .success_count = null,
            .duplicate_count = &duplicate_count,
            .base_stream_id = 1,
            .iterations = iterations,
            .worker_index = worker_index,
            .stream_id_span = active_stream_count,
            .expect_duplicate_only = true,
            .unexpected_success_count = &unexpected_success_count,
            .failed_unregister_count = null,
            .stream_registry_full_count = &stream_registry_full_count,
        };
    }

    for (&threads, 0..) |*thread, worker_index| {
        thread.* = try std.Thread.spawn(.{}, workerMain, .{&contexts[worker_index]});
    }

    ready.store(true, .release);
    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(u32, worker_count * iterations), duplicate_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), unexpected_success_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), stream_registry_full_count.load(.acquire));
    try testing.expectEqual(@as(usize, active_stream_count), registry.count());
}

test "ActiveStreamRegistry: parallel register/unregister churn leaves no leaked owners" {
    const worker_count = 8;
    const iterations = 10_000;

    var registry = ActiveStreamRegistry{};
    var ready = std.atomic.Value(bool).init(false);
    var success_count = std.atomic.Value(u32).init(0);
    var duplicate_count = std.atomic.Value(u32).init(0);
    var failed_unregister_count = std.atomic.Value(u32).init(0);
    var stream_registry_full_count = std.atomic.Value(u32).init(0);

    var threads: [worker_count]std.Thread = undefined;
    var contexts: [worker_count]WorkerContext = undefined;

    for (&contexts, 0..) |*context, worker_index| {
        context.* = .{
            .registry = &registry,
            .ready = &ready,
            .success_count = &success_count,
            .duplicate_count = &duplicate_count,
            .base_stream_id = (@as(u64, worker_index) + 1) << 32,
            .iterations = iterations,
            .worker_index = worker_index,
            .stream_id_span = 1,
            .expect_duplicate_only = false,
            .unexpected_success_count = null,
            .failed_unregister_count = &failed_unregister_count,
            .stream_registry_full_count = &stream_registry_full_count,
        };
    }

    for (&threads, 0..) |*thread, worker_index| {
        thread.* = try std.Thread.spawn(.{}, workerMain, .{&contexts[worker_index]});
    }

    ready.store(true, .release);
    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(u32, worker_count * iterations), success_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), duplicate_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), failed_unregister_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), stream_registry_full_count.load(.acquire));
    try testing.expectEqual(@as(usize, 0), registry.count());
}

const WorkerContext = struct {
    registry: *ActiveStreamRegistry,
    ready: *std.atomic.Value(bool),
    success_count: ?*std.atomic.Value(u32),
    duplicate_count: ?*std.atomic.Value(u32),
    base_stream_id: u64,
    iterations: usize,
    worker_index: usize,
    stream_id_span: usize,
    expect_duplicate_only: bool,
    unexpected_success_count: ?*std.atomic.Value(u32),
    failed_unregister_count: ?*std.atomic.Value(u32),
    stream_registry_full_count: ?*std.atomic.Value(u32),
};

fn workerMain(context: *WorkerContext) void {
    while (!context.ready.load(.acquire)) {
        std.Thread.sleep(1);
    }

    for (0..context.iterations) |iteration| {
        const stream_id = if (context.expect_duplicate_only)
            context.base_stream_id + @as(u64, @intCast(iteration % context.stream_id_span))
        else
            context.base_stream_id | @as(u64, @intCast(iteration));
        _ = context.worker_index;

        const registered = context.registry.register(stream_id) catch |err| switch (err) {
            error.StreamRegistryFull => blk: {
                if (context.stream_registry_full_count) |stream_registry_full_count| {
                    _ = stream_registry_full_count.fetchAdd(1, .acq_rel);
                }
                break :blk false;
            },
        };

        if (registered) {
            if (context.success_count) |success_count| {
                _ = success_count.fetchAdd(1, .acq_rel);
            }

            if (context.expect_duplicate_only) {
                if (context.unexpected_success_count) |unexpected_success_count| {
                    _ = unexpected_success_count.fetchAdd(1, .acq_rel);
                }
            }

            if (context.failed_unregister_count) |failed_unregister_count| {
                if (!context.registry.unregister(stream_id)) {
                    _ = failed_unregister_count.fetchAdd(1, .acq_rel);
                }
            }
        } else if (context.duplicate_count) |duplicate_count| {
            _ = duplicate_count.fetchAdd(1, .acq_rel);
        }
    }
}
