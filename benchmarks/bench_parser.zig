// benchmarks/bench_parser.zig — parse-only throughput across 10 canonical
// query shapes (Task 1.1, plan 2026-04-20-query-path-benchmarks.md).
//
// Each scenario runs 500 warmup iterations then 10,000 timed iterations.
// A new arena is created and deinit'd per iteration so peak RSS stays small.
// Emits a ResultDocument JSON via `--output <path>` (compatible with
// `zig build compare-bench`), or human-readable stdout otherwise.

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
                std.debug.print("bench-query-parser: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "bench-query-parser [--output <path>]\n" ++
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

    const iterations: usize = 10_000;
    const warmup: usize = 500;

    var rows: std.ArrayList(common_query.QueryResultRow) = .empty;
    defer rows.deinit(allocator);

    if (output_path == null) {
        std.debug.print("=== bench-query-parser: parse-only throughput ===\n", .{});
    }

    for (SCENARIOS) |scn| {
        // Warmup — create and discard arena per iteration to avoid accumulation.
        for (0..warmup) |_| {
            var result = try geode.parse(allocator, scn.query, .{});
            result.deinit();
        }

        // Timed loop — new arena per iteration; arena.deinit() frees program.
        const start = nowNs();
        for (0..iterations) |_| {
            var result = try geode.parse(allocator, scn.query, .{});
            result.deinit();
        }
        const elapsed = nowNs() - start;

        const throughput: f64 = @as(f64, @floatFromInt(iterations)) * 1e9 /
            @as(f64, @floatFromInt(elapsed));
        const ns_per_op: u64 = elapsed / iterations;

        try rows.append(allocator, .{
            .git_sha = git_sha,
            .run_timestamp_unix_s = nowUnixS(),
            .zig_version = builtin.zig_version_string,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .cpu = cpu,
            .scenario_name = scn.name,
            .variant = "parser",
            .dataset_size = "none",
            .iterations = iterations,
            .warmup_iterations = warmup,
            .wall_time_ns_median = elapsed,
            .throughput_ops_per_sec = throughput,
            .parse_ns_per_op_p50 = ns_per_op,
        });

        if (output_path == null) {
            std.debug.print(
                "  {s:<32} {d:>12.0} ops/sec  {d:>8} ns/op\n",
                .{ scn.name, throughput, ns_per_op },
            );
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
        std.debug.print("bench-query-parser: wrote {d} rows to {s}\n", .{ expanded.len, path });
    } else {
        std.debug.print("\n{d} scenarios measured. Pass --output <path> to emit ResultDocument JSON.\n", .{rows.items.len});
    }
}
