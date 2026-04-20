// benchmarks/bench_executor_match.zig — in-process MATCH executor throughput
// across 10 canonical query shapes × 3 dataset sizes (Task 3.1,
// plan 2026-04-20-query-path-benchmarks.md).
//
// Key design decisions:
//
// 1. lt_id=42 baked in: Rather than binding a $id parameter at runtime (which
//    requires wiring query_param_names/query_param_values into ExecutionContext),
//    we inline the literal 42 into each query. All seeded datasets have at least
//    500 nodes (lt_id in 0..499), so node 42 always exists. The parameter-binding
//    overhead is tracked separately in the QUIC loadtest, not here.
//
// 2. execute_ns includes plan phase: `executeProgramWithContext` performs
//    parse→plan→execute in one call. There is no top-level plan-only hook
//    separate from execute, so execute_ns_per_op_p50 includes both plan and
//    execution cost. The M2 bench already isolates plan-only. This is intentional.
//    `materialize_ns_per_op_p50` is emitted as 0 (no separate materialize hook).
//
// 3. Small dataset has no edges: seedFanOut(..., 0) seeds 500 persons and 50
//    companies but 0 LT_KNOWS edges. So one_hop/two_hop_distinct/fan_out_cross_type
//    return 0 rows on .small — this is a valid measurement of the executor's
//    empty-result path and is documented in row_count_p50.
//
// 4. Each size fully reseeds: deinitGlobalStore + initGlobalStore wipes the
//    prior seeded dataset before seeding the next size. This prevents cross-
//    contamination (e.g. medium's 2000 nodes mixing with small's 500).
//
// Emits a ResultDocument JSON via `--output <path>` (compatible with
// `zig build compare-bench`), or human-readable stdout otherwise.
//
// Iteration counts: 200 timed + 20 warmup per (scenario, size).
// Total: 10 scenarios × 3 sizes × 220 exec × ~1ms each ≈ minutes on .large.

const std = @import("std");
const builtin = @import("builtin");
const common_query = @import("common_query");
const schema = @import("bench_schema");
const datasets = @import("query_datasets");
const geode = @import("geode");

fn nowUnixS() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn getEnvOr(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]const u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    if (std.c.getenv(name_z)) |ptr| {
        const slice = std.mem.span(ptr);
        if (slice.len == 0) return try allocator.dupe(u8, fallback);
        return try allocator.dupe(u8, slice);
    }
    return try allocator.dupe(u8, fallback);
}

// SCENARIOS: $id from bench_parser/bench_planner replaced with literal 42.
// See top-of-file comment for rationale.
const SCENARIOS = [_]struct { name: []const u8, query: []const u8 }{
    .{ .name = "ping", .query = "RETURN 1 AS x" },
    .{ .name = "point_read_inline", .query = "MATCH (p:LT_Person {lt_id: 42}) RETURN p.name, p.age" },
    .{ .name = "point_read_where", .query = "MATCH (p:LT_Person) WHERE p.lt_id = 42 RETURN p.name" },
    .{ .name = "one_hop", .query = "MATCH (a:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b) RETURN b.name, b.age" },
    .{ .name = "two_hop_distinct", .query = "MATCH (a:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name, c.lt_id LIMIT 20" },
    .{ .name = "fan_out_cross_type", .query = "MATCH (p:LT_Person {lt_id: 42})-[:LT_KNOWS]->(f)-[:LT_WORKS_AT]->(c:LT_Company) RETURN DISTINCT c.name LIMIT 10" },
    .{ .name = "agg_count_label", .query = "MATCH (p:LT_Person) RETURN count(p) AS n" },
    .{ .name = "agg_avg_property", .query = "MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age) AS mean_age" },
    .{ .name = "order_by_limit", .query = "MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50" },
    .{ .name = "union_two_labels", .query = "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id" },
};

const DATASET_SIZES = [_]common_query.DatasetSize{ .small, .medium, .large };

pub fn main(proc_init: std.process.Init.Minimal) !void {
    // GAP-0810-INVESTIGATE: use smp_allocator (the production allocator
    // chosen by `graph_store.global_allocator` per GAP-0754) instead of
    // DebugAllocator.  DebugAllocator's per-allocation bookkeeping has
    // O(live_allocations) cost on free, which artificially penalizes
    // code paths that retain live allocations across timed iterations
    // (e.g. an in-process parse cache).  See
    // `tests/test_gap0810_reproduce_regression.zig` for the reproducer
    // that pinned this down — with DebugAllocator the A/B gate showed a
    // phantom +37-117% execute regression when wiring parseGqlCached;
    // under smp_allocator the regression evaporates and the expected
    // parse-cache win surfaces.  Matches the server's real runtime
    // behavior (QUIC handler allocates from smp_allocator in
    // ReleaseFast).
    const allocator = std.heap.smp_allocator;

    // GAP-0810: process-scoped AST cache so repeated parses of the same
    // scenario query text (10 scenarios × 3 sizes = 30 unique shapes) hit
    // the cache instead of re-parsing every iteration. Matches the QUIC
    // server path and keeps bench numbers on the cached-parse code path.
    var ast_cache = geode.SharedAstCache.init(allocator, 64);
    defer ast_cache.deinit();

    // --- argv parsing: --output <path> ----------------------------------------
    const raw_argv = proc_init.args.vector;
    var output_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < raw_argv.len) : (idx += 1) {
        const a = std.mem.span(raw_argv[idx]);
        if (std.mem.eql(u8, a, "--output")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("bench-query-executor-match: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "bench-query-executor-match [--output <path>]\n" ++
                    "  --output PATH   write ResultDocument JSON to PATH\n" ++
                    "                  (default: human-readable stdout)\n",
                .{},
            );
            return;
        }
    }

    const git_sha = try getEnvOr(allocator, "GEODE_BENCH_GIT_SHA", "unknown");
    defer allocator.free(git_sha);
    const cpu = try getEnvOr(allocator, "GEODE_BENCH_CPU", "unknown");
    defer allocator.free(cpu);

    // 20 timed + 3 warmup: full-scan and multi-hop scenarios on large datasets
    // (10k nodes, 30k+ edges) are compute-heavy even in ReleaseFast; keeping
    // iterations low ensures total bench wall-time stays under 2 minutes.
    // 20 samples is sufficient to compute a stable p50 for trend tracking.
    const iterations: usize = 20;
    const warmup: usize = 3;

    var rows: std.ArrayList(common_query.QueryResultRow) = .empty;
    defer rows.deinit(allocator);

    if (output_path == null) {
        std.debug.print("=== bench-query-executor-match: in-process MATCH exec timings ===\n", .{});
    }

    // Build tmp dir path using PID to avoid collisions.
    var tmp_dir_buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/bench-exec-match-{d}", .{pid});

    const fs_io = std.Io.Threaded.global_single_threaded.io();
    // Ensure the directory exists (createDirPath is a no-op if it already exists).
    try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};

    // Bootstrap global store once so ensureCatalogInstance can proceed.
    _ = try geode.graph_store.initGlobalStore(allocator, tmp_path);

    // ensureCatalogInstance must be called while the store is live. The defer
    // order here is LIFO: cleanupCatalogInstance runs first, then we tear down
    // the store inside the size loop. Final deinit after the loop is in the
    // outer scope below.
    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();
    // The global store will be torn down per-size inside the loop; we defer a
    // final deinit here as a safety net in case we exit the loop early.
    defer geode.graph_store.deinitGlobalStore();

    for (DATASET_SIZES) |size| {
        // Reset the store for this size to avoid cross-contamination between
        // small (500 nodes) and medium/large (2000/10000 nodes).
        // We must delete the tmp directory so deinitGlobalStore + initGlobalStore
        // creates a fresh store rather than replaying the WAL from the prior size.
        geode.graph_store.deinitGlobalStore();
        std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};
        try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
        _ = try geode.graph_store.initGlobalStore(allocator, tmp_path);

        // Seed all sizes via seedFanOut so every size has both LT_Person and
        // LT_Company nodes, and LT_WORKS_AT edges for fan_out_cross_type.
        // For .small, knows_per_person=0 → no LT_KNOWS edges (one_hop/two_hop
        // return 0 rows on .small — valid measurement of the empty-result path).
        // Node counts chosen to give meaningful scale separation while keeping
        // seeding + bench total wall-time under 2 minutes in ReleaseFast:
        //   small:  500 persons + 50 companies, no LT_KNOWS edges
        //   medium: 2000 persons + 100 companies + 4 LT_KNOWS/person
        //   large:  5000 persons + 100 companies + 3 LT_KNOWS/person
        // (Original plan's 10k-node large was too slow for a smoke-run iteration.)
        switch (size) {
            .small => try datasets.seedFanOut(allocator, "default", 500, 50, 0),
            .medium => try datasets.seedFanOut(allocator, "default", 2000, 100, 4),
            .large => try datasets.seedFanOut(allocator, "default", 5000, 100, 3),
        }

        if (output_path == null) {
            std.debug.print("  [size={s}] seeded\n", .{size.label()});
        }

        for (SCENARIOS) |scn| {
            // Allocate sample slices on the heap to avoid stack overflow.
            const parse_ns_samples = try allocator.alloc(u64, iterations);
            defer allocator.free(parse_ns_samples);
            const execute_ns_samples = try allocator.alloc(u64, iterations);
            defer allocator.free(execute_ns_samples);
            const row_count_samples = try allocator.alloc(u64, iterations);
            defer allocator.free(row_count_samples);

            const ctx = geode.execution.ExecutionContext{ .catalog = catalog };

            // Warmup — parse + execute but discard results.
            for (0..warmup) |_| {
                const outcome = try geode.parseGqlCached(&ast_cache, scn.query, .{});
                var handle = switch (outcome) {
                    .Ok => |h| h,
                    .Err => return error.ParseFailed,
                };
                defer handle.release();
                var result = try geode.execution.executeProgramWithContext(allocator, &handle.parse_result.program, ctx);
                defer result.deinit(allocator);
            }

            // Timed loop: measure parse (cache lookup or cold miss) and
            // execute phases separately.
            for (0..iterations) |i| {
                const parse_start = nowNs();
                const outcome = try geode.parseGqlCached(&ast_cache, scn.query, .{});
                var handle = switch (outcome) {
                    .Ok => |h| h,
                    .Err => return error.ParseFailed,
                };
                const parse_end = nowNs();

                const exec_start = nowNs();
                var result = try geode.execution.executeProgramWithContext(allocator, &handle.parse_result.program, ctx);
                const exec_end = nowNs();

                row_count_samples[i] = @intCast(result.rows.len);

                result.deinit(allocator);
                handle.release();

                parse_ns_samples[i] = parse_end - parse_start;
                execute_ns_samples[i] = exec_end - exec_start;
            }

            // Sort samples ascending before computing median.
            std.mem.sort(u64, parse_ns_samples, {}, std.sort.asc(u64));
            std.mem.sort(u64, execute_ns_samples, {}, std.sort.asc(u64));
            std.mem.sort(u64, row_count_samples, {}, std.sort.asc(u64));

            const parse_stat = common_query.medianAndStddev(parse_ns_samples);
            const exec_stat = common_query.medianAndStddev(execute_ns_samples);
            const row_stat = common_query.medianAndStddev(row_count_samples);

            const combined_ns: u64 = parse_stat.median + exec_stat.median;
            const throughput: f64 = if (combined_ns > 0)
                1e9 / @as(f64, @floatFromInt(combined_ns))
            else
                0;

            try rows.append(allocator, .{
                .git_sha = git_sha,
                .run_timestamp_unix_s = nowUnixS(),
                .zig_version = builtin.zig_version_string,
                .os = @tagName(builtin.os.tag),
                .arch = @tagName(builtin.cpu.arch),
                .cpu = cpu,
                .scenario_name = scn.name,
                .variant = "executor-match",
                .dataset_size = size.label(),
                .iterations = iterations,
                .warmup_iterations = warmup,
                .wall_time_ns_median = combined_ns,
                .wall_time_ns_stddev = parse_stat.stddev + exec_stat.stddev,
                .throughput_ops_per_sec = throughput,
                .parse_ns_per_op_p50 = parse_stat.median,
                // execute_ns includes plan phase — no top-level plan-only hook.
                .execute_ns_per_op_p50 = exec_stat.median,
                // No separate materialize hook at this layer.
                .materialize_ns_per_op_p50 = 0,
                .row_count_p50 = row_stat.median,
            });

            if (output_path == null) {
                std.debug.print(
                    "  {s:<32} size={s:<8} parse={d:>8}ns  exec={d:>10}ns  rows={d:>6}  {d:>10.0} ops/sec\n",
                    .{ scn.name, size.label(), parse_stat.median, exec_stat.median, row_stat.median, throughput },
                );
            }
        }
    }

    if (output_path) |path| {
        const expanded = try common_query.expand(allocator, rows.items);
        defer common_query.freeExpanded(allocator, expanded);
        const doc = schema.ResultDocument{
            .generated_at_unix_s = nowUnixS(),
            .rows = expanded,
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        try schema.writeDocument(allocator, io, path, doc);
        std.debug.print("bench-query-executor-match: wrote {d} rows to {s}\n", .{ expanded.len, path });
    } else {
        std.debug.print("\n{d} (scenario, size) pairs measured. Pass --output <path> to emit ResultDocument JSON.\n", .{rows.items.len});
    }
}
