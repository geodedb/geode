// benchmarks/bench_group_commit.zig — Task 19 (enterprise-ingest-throughput)
// group-commit coordinator: 16-way contended vs uncontended throughput.
//
// Three scenarios, stdout only (no ResultDocument JSON).  Intended to be
// run as a sanity check / commit evidence:
//
//   1. bulk_create_single: single thread, N ops via adapter.bulkInsertNode
//      with the per-graph write lock.  Establishes the serial baseline.
//   2. bulk_create_16way_no_coord: 16 threads, each doing N ops through
//      the direct bulkInsertNode path, each under its own write-lock
//      acquire.  Models the pre-Task-19 QUIC fast-path behaviour.
//   3. bulk_create_16way_with_coord: 16 threads, each submitting N ops
//      through the per-graph coordinator.  Reports batches coalesced.
//
// The bench reports aggregate ops/sec plus per-op p50/p95 wall-time,
// computed across all submitters for the concurrent scenarios.  Expected
// 5-10x throughput win for the coordinator vs uncoalesced on a quiet
// 16-core host; the actual ratio is reported regardless so a regression
// shows up immediately.
//
// Uses the public `geode.group_commit` + `geode.graph_storage_adapter`
// APIs directly so we don't pay QUIC/protobuf overhead that would
// obscure the apply-phase win.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const execution = geode.execution;

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monoNanosNow() u64 {
    return nowNs();
}

fn sortU64(slice: []u64) void {
    std.sort.pdq(u64, slice, {}, std.sort.asc(u64));
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(idx_f);
    return sorted[idx];
}

// ----------------------------------------------------------------------
// Scenario 1: single-thread baseline.
// ----------------------------------------------------------------------

fn runBulkCreateSingle(
    adapter: *adapter_mod.StorageAdapter,
    graph_name: []const u8,
    samples: []u64,
) !u64 {
    const total_start = nowNs();
    for (samples, 0..) |*s, i| {
        _ = i;
        const labels = [_][]const u8{"BenchSingle"};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};

        const t0 = nowNs();
        const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
        const h = try graph_store.acquireGraphWriteLockCancelable(graph_name, deadline);
        _ = try adapter.bulkInsertNode(graph_name, &labels, &props, null);
        graph_store.releaseGraphLock(h);
        s.* = nowNs() - t0;
    }
    return nowNs() - total_start;
}

// ----------------------------------------------------------------------
// Scenario 2: 16 threads, no coordinator — direct bulkInsertNode under
// per-thread write-lock acquire.  This is the pre-Task-19 behaviour.
// ----------------------------------------------------------------------

const NoCoordCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    graph_name: []const u8,
    n: usize,
    tid: usize,
    samples: []u64,
    errors: std.atomic.Value(u32),
};

fn noCoordWorker(ctx: *NoCoordCtx) void {
    for (ctx.samples, 0..) |*s, i| {
        _ = i;
        const labels = [_][]const u8{"BenchConcNoCoord"};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};

        const t0 = nowNs();
        const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
        const h = graph_store.acquireGraphWriteLockCancelable(ctx.graph_name, deadline) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
            s.* = 0;
            continue;
        };
        _ = ctx.adapter.bulkInsertNode(ctx.graph_name, &labels, &props, null) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
        };
        graph_store.releaseGraphLock(h);
        s.* = nowNs() - t0;
    }
}

// ----------------------------------------------------------------------
// Scenario 3: 16 threads submitting through the coordinator.
// ----------------------------------------------------------------------

const CoordCtx = struct {
    coord: *group_commit.ShardedCoordinator,
    n: usize,
    tid: usize,
    samples: []u64,
    errors: std.atomic.Value(u32),
};

fn coordWorker(ctx: *CoordCtx) void {
    for (ctx.samples, 0..) |*s, i| {
        _ = i;
        const labels = [_][]const u8{"BenchConcCoord"};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};

        const t0 = nowNs();
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{
            .labels = &labels,
            .props = &props,
            .result = .{},
        } };
        _ = ctx.coord.submit(&op) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
        };
        s.* = nowNs() - t0;
    }
}

// ----------------------------------------------------------------------
// Reporter
// ----------------------------------------------------------------------

const Report = struct {
    scenario: []const u8,
    total_ops: usize,
    elapsed_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    batches: ?u64 = null,
};

fn printReport(r: Report) void {
    const ops_per_sec = @as(f64, @floatFromInt(r.total_ops)) /
        (@as(f64, @floatFromInt(r.elapsed_ns)) / std.time.ns_per_s);
    std.debug.print(
        "[bench_group_commit] scenario={s} ops={d} elapsed_ms={d:.1} ops/sec={d:.0} p50_us={d:.1} p95_us={d:.1}",
        .{
            r.scenario,
            r.total_ops,
            @as(f64, @floatFromInt(r.elapsed_ns)) / std.time.ns_per_ms,
            ops_per_sec,
            @as(f64, @floatFromInt(r.p50_ns)) / std.time.ns_per_us,
            @as(f64, @floatFromInt(r.p95_ns)) / std.time.ns_per_us,
        },
    );
    if (r.batches) |b| {
        const avg_batch = @as(f64, @floatFromInt(r.total_ops)) /
            @as(f64, @floatFromInt(b));
        std.debug.print(" batches={d} avg_batch={d:.2}", .{ b, avg_batch });
    }
    std.debug.print("\n", .{});
}

// ----------------------------------------------------------------------
// Setup / teardown
// ----------------------------------------------------------------------

fn makeDataDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    // Simple unique-ish tmp path under /tmp — the bench is a throwaway
    // process so collision risk is negligible, and we don't need the
    // testing-allocator auto-cleanup that std.testing.tmpDir provides.
    var seed_buf: [8]u8 = undefined;
    _ = std.os.linux.getrandom(&seed_buf, seed_buf.len, 0);
    const seed = std.mem.readInt(u64, &seed_buf, .little);
    return std.fmt.allocPrint(
        allocator,
        "/tmp/geode-bench-groupcommit-{s}-{x}",
        .{ tag, seed },
    );
}

const Harness = struct {
    data_dir: []u8,
    adapter: *adapter_mod.StorageAdapter,
};

fn freshHarness(allocator: std.mem.Allocator, tag: []const u8) !Harness {
    // Reset any prior state.
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    const data_dir = try makeDataDir(allocator, tag);
    errdefer allocator.free(data_dir);

    // Create the directory up front — the adapter's graphs/ subdir
    // creation can handle it, but keep the shape predictable.
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    graph_store.setDataDirOverride(allocator, data_dir);
    _ = graph_store.getGlobalStore(allocator);
    _ = try execution.ensureCatalogInstance(allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.getOrCreateGraph("default");

    return .{ .data_dir = data_dir, .adapter = adapter };
}

fn tearDown(allocator: std.mem.Allocator, data_dir: []u8) void {
    group_commit.shutdownAllCoordinators();
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    graph_store.setDataDirOverride(allocator, null);
    // Best-effort cleanup of the tmp dir; failure is harmless.
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};
    allocator.free(data_dir);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const thread_count: usize = 16;
    const ops_per_thread: usize = 1000;
    const single_total: usize = 10_000;

    // --- Scenario 1: single thread baseline ------------------------
    {
        const fh = try freshHarness(allocator, "single");
        defer tearDown(allocator, fh.data_dir);

        const samples = try allocator.alloc(u64, single_total);
        defer allocator.free(samples);

        const elapsed = try runBulkCreateSingle(fh.adapter, "default", samples);
        sortU64(samples);
        printReport(.{
            .scenario = "bulk_create_single",
            .total_ops = single_total,
            .elapsed_ns = elapsed,
            .p50_ns = percentile(samples, 0.5),
            .p95_ns = percentile(samples, 0.95),
        });
    }

    // --- Scenario 2: 16 threads, no coordinator --------------------
    {
        const fh = try freshHarness(allocator, "16way_no_coord");
        defer tearDown(allocator, fh.data_dir);

        var samples = try allocator.alloc(u64, thread_count * ops_per_thread);
        defer allocator.free(samples);

        var contexts: [16]NoCoordCtx = undefined;
        for (0..thread_count) |i| {
            contexts[i] = NoCoordCtx{
                .adapter = fh.adapter,
                .graph_name = "default",
                .n = ops_per_thread,
                .tid = i,
                .samples = samples[i * ops_per_thread ..][0..ops_per_thread],
                .errors = std.atomic.Value(u32).init(0),
            };
        }

        const start = nowNs();
        var threads: [16]std.Thread = undefined;
        for (0..thread_count) |i| {
            threads[i] = try std.Thread.spawn(.{}, noCoordWorker, .{&contexts[i]});
        }
        for (threads) |t| t.join();
        const elapsed = nowNs() - start;

        sortU64(samples);
        var error_total: u32 = 0;
        for (contexts) |c| error_total += c.errors.load(.acquire);
        if (error_total != 0) std.debug.print("[bench_group_commit] scenario=16way_no_coord errors={d}\n", .{error_total});

        printReport(.{
            .scenario = "bulk_create_16way_no_coord",
            .total_ops = thread_count * ops_per_thread,
            .elapsed_ns = elapsed,
            .p50_ns = percentile(samples, 0.5),
            .p95_ns = percentile(samples, 0.95),
        });
    }

    // --- Scenario 3: 16 threads, coordinator -----------------------
    {
        const fh = try freshHarness(allocator, "16way_coord");
        defer tearDown(allocator, fh.data_dir);

        const coord = try group_commit.getOrStartCoordinator(allocator, fh.adapter, "default");

        var samples = try allocator.alloc(u64, thread_count * ops_per_thread);
        defer allocator.free(samples);

        var contexts: [16]CoordCtx = undefined;
        for (0..thread_count) |i| {
            contexts[i] = CoordCtx{
                .coord = coord,
                .n = ops_per_thread,
                .tid = i,
                .samples = samples[i * ops_per_thread ..][0..ops_per_thread],
                .errors = std.atomic.Value(u32).init(0),
            };
        }

        const start = nowNs();
        var threads: [16]std.Thread = undefined;
        for (0..thread_count) |i| {
            threads[i] = try std.Thread.spawn(.{}, coordWorker, .{&contexts[i]});
        }
        for (threads) |t| t.join();
        const elapsed = nowNs() - start;

        sortU64(samples);
        var error_total: u32 = 0;
        for (contexts) |c| error_total += c.errors.load(.acquire);
        if (error_total != 0) std.debug.print("[bench_group_commit] scenario=16way_with_coord errors={d}\n", .{error_total});

        const batches = coord.apply_batches_total.load(.acquire);
        const ops_applied = coord.apply_ops_total.load(.acquire);
        _ = ops_applied;

        printReport(.{
            .scenario = "bulk_create_16way_with_coord",
            .total_ops = thread_count * ops_per_thread,
            .elapsed_ns = elapsed,
            .p50_ns = percentile(samples, 0.5),
            .p95_ns = percentile(samples, 0.95),
            .batches = batches,
        });
    }
}
