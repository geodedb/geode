// Wrapper exe that runs the phase1 + phase2 micro-benchmarks and emits a
// ResultDocument JSON (M0.5). Invoked by `zig build benchmark -- --output
// <path>`; the existing `test` blocks in phase1_benchmarks.zig /
// phase2_benchmarks.zig continue to run under `zig build test` and enforce
// the improvement-ratio assertions.
//
// Schema: see benchmarks/bench_schema.zig (M0.4 — the same schema used by
// bench-timeseries). One row per named bench, measurement =
// "improvement_ratio", variant = "default".
//
// Rationale for single well-warmed sample (no median-of-6):
//   - These benches are deterministic micro-benches that already include
//     an internal warmup pass before the measured run.
//   - The existing `test` blocks enforce threshold assertions; this wrapper
//     is solely responsible for emitting machine-readable JSON for the
//     compare-bench comparator (M0.6) and perf-gate.sh (M0.7).
//   - Median-of-6 would ~6x the wall clock for no added signal — the
//     improvement ratios here are stable to <5% across runs in ReleaseFast.

const std = @import("std");
const builtin = @import("builtin");
const schema = @import("bench_schema");
const phase1 = @import("phase1_benchmarks");
const phase2 = @import("phase2_benchmarks");

// Zig 0.16 compat: std.time.timestamp removed; use clock_gettime(REALTIME).
fn nowUnixS() i64 {
    var tsval: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &tsval);
    return @intCast(tsval.sec);
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

const RowCommon = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
};

fn appendPhase1Rows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(schema.ResultRow),
    owned_scenarios: *std.ArrayList([]u8),
    common: RowCommon,
) !void {
    var results: std.ArrayList(phase1.BenchResult) = .empty;
    defer results.deinit(allocator);

    try phase1.runAll(allocator, &results);
    for (results.items) |r| {
        const scenario_name = try std.fmt.allocPrint(allocator, "phase1_{s}", .{r.name});
        try owned_scenarios.append(allocator, scenario_name);
        try rows.append(allocator, .{
            .git_sha = common.git_sha,
            .run_timestamp_unix_s = common.run_timestamp_unix_s,
            .zig_version = common.zig_version,
            .os = common.os,
            .arch = common.arch,
            .cpu = common.cpu,
            .scenario_name = scenario_name,
            .measurement = "improvement_ratio",
            .value = r.improvement_ratio,
            .sample_count = r.iterations,
            .wall_time_ns = r.wall_time_ns,
        });
    }
}

fn appendPhase2Rows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(schema.ResultRow),
    owned_scenarios: *std.ArrayList([]u8),
    common: RowCommon,
) !void {
    var results: std.ArrayList(phase2.BenchResult) = .empty;
    defer results.deinit(allocator);

    try phase2.runAll(allocator, &results);
    for (results.items) |r| {
        const scenario_name = try std.fmt.allocPrint(allocator, "phase2_{s}", .{r.name});
        try owned_scenarios.append(allocator, scenario_name);
        try rows.append(allocator, .{
            .git_sha = common.git_sha,
            .run_timestamp_unix_s = common.run_timestamp_unix_s,
            .zig_version = common.zig_version,
            .os = common.os,
            .arch = common.arch,
            .cpu = common.cpu,
            .scenario_name = scenario_name,
            .measurement = "improvement_ratio",
            .value = r.improvement_ratio,
            .sample_count = r.iterations,
            .wall_time_ns = r.wall_time_ns,
        });
    }
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- argv parsing: --output <path> -------------------------------------
    const raw_argv = proc_init.args.vector;
    var output_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < raw_argv.len) : (idx += 1) {
        const a = std.mem.span(raw_argv[idx]);
        if (std.mem.eql(u8, a, "--output")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("phase-benchmarks: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "phase-benchmarks [--output <path>]\n" ++
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

    const common = RowCommon{
        .git_sha = git_sha,
        .run_timestamp_unix_s = nowUnixS(),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = cpu,
    };

    var rows: std.ArrayList(schema.ResultRow) = .empty;
    defer rows.deinit(allocator);

    var owned_scenarios: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_scenarios.items) |s| allocator.free(s);
        owned_scenarios.deinit(allocator);
    }

    if (output_path == null) {
        std.debug.print("=== Phase 1 + Phase 2 micro-benchmarks ===\n", .{});
    }

    try appendPhase1Rows(allocator, &rows, &owned_scenarios, common);
    try appendPhase2Rows(allocator, &rows, &owned_scenarios, common);

    if (output_path) |path| {
        const doc = schema.ResultDocument{
            .generated_at_unix_s = nowUnixS(),
            .rows = rows.items,
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        try schema.writeDocument(allocator, io, path, doc);
        std.debug.print("phase-benchmarks: wrote {d} rows to {s}\n", .{ rows.items.len, path });
    } else {
        // Human-readable mode — print each row's scenario + ratio.
        for (rows.items) |r| {
            std.debug.print(
                "  {s:<48} {s:<20} {d:.3}x (n={d}, wall={d} ns)\n",
                .{ r.scenario_name, r.measurement, r.value, r.sample_count, r.wall_time_ns },
            );
        }
        std.debug.print("\n{d} bench rows collected.\n", .{rows.items.len});
        std.debug.print("Pass --output <path> to emit ResultDocument JSON.\n", .{});
    }
}
