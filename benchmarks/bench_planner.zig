// benchmarks/bench_planner.zig — parse + plan phase timings across 10 canonical
// query shapes × 3 dataset sizes (Task 2.1, plan 2026-04-20-query-path-benchmarks.md).
//
// Each (scenario, size) pair runs 200 warmup iterations then 2000 timed
// iterations. A new arena is created and deinit'd per iteration so peak RSS
// stays small. The dataset_size label is purely dimensional — the planner
// doesn't execute queries, so no actual graph seeding is performed.
//
// Emits a ResultDocument JSON via `--output <path>` (compatible with
// `zig build compare-bench`), or human-readable stdout otherwise.
//
// Plan-cache stats: deferred to a future variant sweep that instantiates a
// local SharedQueryOptimizer. For now plan_cache_hits/misses = 0.
// TODO(M2-cache): wire SharedQueryOptimizer locally to capture hit/miss counts.

const std = @import("std");
const builtin = @import("builtin");
const common_query = @import("common_query");
const schema = @import("bench_schema");
const geode = @import("geode");

// Zig 0.16: std.time.timestamp() removed; use clock_gettime(REALTIME).
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

const SCENARIOS = [_]struct { name: []const u8, query: []const u8 }{
    .{ .name = "ping", .query = "RETURN 1 AS x" },
    .{ .name = "point_read_inline", .query = "MATCH (p:LT_Person {lt_id: $id}) RETURN p.name, p.age" },
    .{ .name = "point_read_where", .query = "MATCH (p:LT_Person) WHERE p.lt_id = $id RETURN p.name" },
    .{ .name = "one_hop", .query = "MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b) RETURN b.name, b.age" },
    .{ .name = "two_hop_distinct", .query = "MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name, c.lt_id LIMIT 20" },
    .{ .name = "fan_out_cross_type", .query = "MATCH (p:LT_Person {lt_id: $id})-[:LT_KNOWS]->(f)-[:LT_WORKS_AT]->(c:LT_Company) RETURN DISTINCT c.name LIMIT 10" },
    .{ .name = "agg_count_label", .query = "MATCH (p:LT_Person) RETURN count(p) AS n" },
    .{ .name = "agg_avg_property", .query = "MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age) AS mean_age" },
    .{ .name = "order_by_limit", .query = "MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50" },
    .{ .name = "union_two_labels", .query = "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id" },
};

const DATASET_SIZES = [_]common_query.DatasetSize{ .small, .medium, .large };

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- argv parsing: --output <path> ----------------------------------------
    const raw_argv = proc_init.args.vector;
    var output_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < raw_argv.len) : (idx += 1) {
        const a = std.mem.span(raw_argv[idx]);
        if (std.mem.eql(u8, a, "--output")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("bench-query-planner: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "bench-query-planner [--output <path>]\n" ++
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

    const iterations: usize = 2_000;
    const warmup: usize = 200;

    var rows: std.ArrayList(common_query.QueryResultRow) = .empty;
    defer rows.deinit(allocator);

    if (output_path == null) {
        std.debug.print("=== bench-query-planner: parse + plan phase timings ===\n", .{});
    }

    for (DATASET_SIZES) |size| {
        for (SCENARIOS) |scn| {
            // Allocate sample slices on the heap so they don't overflow the stack.
            const parse_ns_samples = try allocator.alloc(u64, iterations);
            defer allocator.free(parse_ns_samples);
            const plan_ns_samples = try allocator.alloc(u64, iterations);
            defer allocator.free(plan_ns_samples);

            // Warmup — parse and plan but discard results.
            for (0..warmup) |_| {
                var result = try geode.parse(allocator, scn.query, .{});
                result.deinit();
            }

            // Timed loop — measure parse and plan separately per iteration.
            for (0..iterations) |i| {
                const parse_start = nowNs();
                var result = try geode.parse(allocator, scn.query, .{});
                const parse_end = nowNs();

                const plan_start = nowNs();
                var did_plan: bool = false;
                if (result.program.statements.len > 0) {
                    switch (result.program.statements[0]) {
                        .Query => |q| {
                            _ = try geode.planner.planQuery(allocator, q, .{});
                            did_plan = true;
                        },
                        else => {},
                    }
                }
                const plan_end = nowNs();

                result.deinit();

                parse_ns_samples[i] = parse_end - parse_start;
                plan_ns_samples[i] = if (did_plan) plan_end - plan_start else 0;
            }

            // Sort each slice ascending before computing median.
            std.mem.sort(u64, parse_ns_samples, {}, std.sort.asc(u64));
            std.mem.sort(u64, plan_ns_samples, {}, std.sort.asc(u64));

            const parse_med = common_query.medianAndStddev(parse_ns_samples);
            const plan_med = common_query.medianAndStddev(plan_ns_samples);

            const combined_ns: u64 = parse_med.median + plan_med.median;
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
                .dataset_size = size.label(),
                .iterations = iterations,
                .warmup_iterations = warmup,
                .wall_time_ns_median = combined_ns,
                .wall_time_ns_stddev = parse_med.stddev + plan_med.stddev,
                .throughput_ops_per_sec = throughput,
                .parse_ns_per_op_p50 = parse_med.median,
                .plan_ns_per_op_p50 = plan_med.median,
                // Plan-cache stats deferred — see TODO(M2-cache) above.
                .plan_cache_hits = 0,
                .plan_cache_misses = 0,
            });

            if (output_path == null) {
                std.debug.print(
                    "  {s:<32} size={s:<8} parse={d:>8}ns  plan={d:>8}ns  {d:>10.0} ops/sec\n",
                    .{ scn.name, size.label(), parse_med.median, plan_med.median, throughput },
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
        std.debug.print("bench-query-planner: wrote {d} rows to {s}\n", .{ expanded.len, path });
    } else {
        std.debug.print("\n{d} (scenario, size) pairs measured. Pass --output <path> to emit ResultDocument JSON.\n", .{rows.items.len});
    }
}
