// benchmarks/bench_executor_mutation.zig — in-process mutation-path benchmarks
// across 6 canonical write scenarios (Task 3.2,
// plan 2026-04-20-query-path-benchmarks.md).
//
// Key design decisions:
//
// 1. IDs baked into query text: Rather than binding $id parameters at runtime,
//    we inline unique IDs per-iteration via std.fmt.allocPrint. This sidesteps
//    the query_param_names/query_param_values plumbing in ExecutionContext and
//    keeps the bench self-contained.
//
// 2. execute_ns includes plan phase: same as bench_executor_match — no top-level
//    plan-only hook separate from executeProgramWithContext.
//
// 3. dataset_size is flat "mutation": we don't sweep store sizes for mutations.
//    The workload is steady per scenario (fixed seed count, fixed iteration count).
//
// 4. Store resets between scenarios: deinitGlobalStore + initGlobalStore + deleteTree
//    wipes the store before each scenario so mutations from one scenario cannot
//    contaminate the next.
//
// 5. ID ranges avoid cross-scenario collisions:
//    - create_single:   IDs start at 1_000_000
//    - create_batch_100: IDs start at 2_000_000
//    - set_property:    cycles i % 500 (through seeded 0..499)
//    - delete_single:   IDs 0..iterations-1 (seeded range covers it)
//    - merge_single:    IDs start at 3_000_000
//    - create_edge:     cycles (i % 500, (i+1) % 500) through seeded 0..499
//
// Emits a ResultDocument JSON via `--output <path>`, or human-readable stdout.

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

// --------------------------------------------------------------------------
// Setup functions
// --------------------------------------------------------------------------

fn noopSetup(_: std.mem.Allocator) anyerror!void {}

fn seed500Persons(allocator: std.mem.Allocator) anyerror!void {
    try datasets.seedPerson(allocator, "default", 500);
}

// delete_single consumes nodes linearly, so seed enough for warmup + iterations.
// warmup=20, iterations=300 → need at least 320; seed 800 for headroom.
fn seedLargePersons(allocator: std.mem.Allocator) anyerror!void {
    try datasets.seedPerson(allocator, "default", 800);
}

// --------------------------------------------------------------------------
// Run functions — one per scenario
// --------------------------------------------------------------------------

fn runCreateSingle(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // IDs start at 1_000_000 to avoid seed-range collision.
    const id = 1_000_000 + iter;
    const q = try std.fmt.allocPrint(
        allocator,
        "CREATE (:LT_Person {{lt_id: {d}, name: \"User{d}\", age: 30}})",
        .{ id, id },
    );
    defer allocator.free(q);

    const parse_start = nowNs();
    var pr = try geode.parse(allocator, q, .{});
    const parse_end = nowNs();
    defer pr.deinit();

    var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
    const exec_end = nowNs();
    defer r.deinit(allocator);

    parse_samples[iter] = parse_end - parse_start;
    exec_samples[iter] = exec_end - parse_end;
    row_counts[iter] = r.rows.len;
}

fn runCreateBatch100(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // IDs start at 2_000_000; each outer iteration uses 100 contiguous IDs.
    const base: usize = 2_000_000;
    const batch_size: usize = 100;

    var total_parse_ns: u64 = 0;
    var total_exec_ns: u64 = 0;
    var total_rows: u64 = 0;

    for (0..batch_size) |j| {
        const id = base + iter * batch_size + j;
        const q = try std.fmt.allocPrint(
            allocator,
            "CREATE (:LT_Person {{lt_id: {d}, name: \"User{d}\", age: 30}})",
            .{ id, id },
        );
        defer allocator.free(q);

        const parse_start = nowNs();
        var pr = try geode.parse(allocator, q, .{});
        const parse_end = nowNs();
        defer pr.deinit();

        var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
        const exec_end = nowNs();
        defer r.deinit(allocator);

        total_parse_ns += parse_end - parse_start;
        total_exec_ns += exec_end - parse_end;
        total_rows += r.rows.len;
    }

    // Record the batch totals as one sample. "op" = one batch of 100.
    parse_samples[iter] = total_parse_ns;
    exec_samples[iter] = total_exec_ns;
    row_counts[iter] = total_rows;
}

fn runSetProperty(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // Cycle through seeded 0..499. Use iter as the timestamp value — it just needs
    // to be a distinct integer per iteration; the actual value doesn't matter for
    // the benchmark.
    const target_id = iter % 500;
    const q = try std.fmt.allocPrint(
        allocator,
        "MATCH (p:LT_Person {{lt_id: {d}}}) SET p.last_seen = {d}",
        .{ target_id, iter },
    );
    defer allocator.free(q);

    const parse_start = nowNs();
    var pr = try geode.parse(allocator, q, .{});
    const parse_end = nowNs();
    defer pr.deinit();

    var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
    const exec_end = nowNs();
    defer r.deinit(allocator);

    parse_samples[iter] = parse_end - parse_start;
    exec_samples[iter] = exec_end - parse_end;
    row_counts[iter] = r.rows.len;
}

fn runDeleteSingle(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // Consumes nodes 0..iterations-1 linearly. seedLargePersons seeds 800.
    const q = try std.fmt.allocPrint(
        allocator,
        "MATCH (p:LT_Person {{lt_id: {d}}}) DELETE p",
        .{iter},
    );
    defer allocator.free(q);

    const parse_start = nowNs();
    var pr = try geode.parse(allocator, q, .{});
    const parse_end = nowNs();
    defer pr.deinit();

    var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
    const exec_end = nowNs();
    defer r.deinit(allocator);

    parse_samples[iter] = parse_end - parse_start;
    exec_samples[iter] = exec_end - parse_end;
    row_counts[iter] = r.rows.len;
}

fn runMergeSingle(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // IDs start at 3_000_000 so MERGE hits ON CREATE on first pass.
    // Repeated IDs (second half reuses same range) measure the "matched existing" path.
    const id = 3_000_000 + iter;
    const q = try std.fmt.allocPrint(
        allocator,
        "MERGE (p:LT_Person {{lt_id: {d}}}) ON CREATE SET p.name = \"New{d}\"",
        .{ id, id },
    );
    defer allocator.free(q);

    const parse_start = nowNs();
    var pr = try geode.parse(allocator, q, .{});
    const parse_end = nowNs();
    defer pr.deinit();

    var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
    const exec_end = nowNs();
    defer r.deinit(allocator);

    parse_samples[iter] = parse_end - parse_start;
    exec_samples[iter] = exec_end - parse_end;
    row_counts[iter] = r.rows.len;
}

fn runCreateEdge(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void {
    // Cycle through seeded 0..499 for both src and dst.
    const src = iter % 500;
    const dst = (iter + 1) % 500;
    const q = try std.fmt.allocPrint(
        allocator,
        "MATCH (a:LT_Person {{lt_id: {d}}}), (b:LT_Person {{lt_id: {d}}}) CREATE (a)-[:LT_KNOWS]->(b)",
        .{ src, dst },
    );
    defer allocator.free(q);

    const parse_start = nowNs();
    var pr = try geode.parse(allocator, q, .{});
    const parse_end = nowNs();
    defer pr.deinit();

    var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
    const exec_end = nowNs();
    defer r.deinit(allocator);

    parse_samples[iter] = parse_end - parse_start;
    exec_samples[iter] = exec_end - parse_end;
    row_counts[iter] = r.rows.len;
}

// --------------------------------------------------------------------------
// Scenario table
// --------------------------------------------------------------------------

const RunFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    iter: usize,
    parse_samples: []u64,
    exec_samples: []u64,
    row_counts: []u64,
) anyerror!void;

const SetupFn = *const fn (allocator: std.mem.Allocator) anyerror!void;

const MutationScenario = struct {
    name: []const u8,
    iterations: usize,
    warmup: usize,
    setupFn: SetupFn,
    runFn: RunFn,
};

const MUTATION_SCENARIOS = [_]MutationScenario{
    .{ .name = "create_single", .iterations = 300, .warmup = 20, .setupFn = noopSetup, .runFn = runCreateSingle },
    .{ .name = "create_batch_100", .iterations = 30, .warmup = 3, .setupFn = noopSetup, .runFn = runCreateBatch100 },
    .{ .name = "set_property", .iterations = 300, .warmup = 20, .setupFn = seed500Persons, .runFn = runSetProperty },
    .{ .name = "delete_single", .iterations = 300, .warmup = 20, .setupFn = seedLargePersons, .runFn = runDeleteSingle },
    .{ .name = "merge_single", .iterations = 300, .warmup = 20, .setupFn = noopSetup, .runFn = runMergeSingle },
    .{ .name = "create_edge", .iterations = 300, .warmup = 20, .setupFn = seed500Persons, .runFn = runCreateEdge },
};

// --------------------------------------------------------------------------
// Warmup helper — runs the scenario's runFn for warmup iters, discards results.
// Uses iter=0 throughout so IDs don't drift into the timed range.
// --------------------------------------------------------------------------
fn runWarmup(
    allocator: std.mem.Allocator,
    ctx: geode.execution.ExecutionContext,
    scn: MutationScenario,
    tmp_parse: []u64,
    tmp_exec: []u64,
    tmp_rows: []u64,
) !void {
    for (0..scn.warmup) |_| {
        // Use iter=0 for all warmup passes. The create_single / merge_single ranges
        // start at 1_000_000 / 3_000_000 so iter=0 is always in the timed range
        // and won't collide with the timed IDs. delete_single warmup at iter=0
        // would delete node 0; that's fine — we don't care about warmup correctness.
        try scn.runFn(allocator, ctx, 0, tmp_parse, tmp_exec, tmp_rows);
    }
}

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------

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
                std.debug.print("bench-query-executor-mutation: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "bench-query-executor-mutation [--output <path>]\n" ++
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

    var rows: std.ArrayList(common_query.QueryResultRow) = .empty;
    defer rows.deinit(allocator);

    if (output_path == null) {
        std.debug.print("=== bench-query-executor-mutation: in-process mutation timings ===\n", .{});
    }

    // Build tmp dir path using PID to avoid collisions.
    var tmp_dir_buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/bench-exec-mutation-{d}", .{pid});

    const fs_io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};

    // Bootstrap global store + catalog once.
    _ = try geode.graph_store.initGlobalStore(allocator, tmp_path);
    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    const ctx = geode.execution.ExecutionContext{ .catalog = catalog };

    for (MUTATION_SCENARIOS) |scn| {
        if (output_path == null) {
            std.debug.print("  [scenario={s}] starting\n", .{scn.name});
        }

        // Reset store between scenarios.
        geode.graph_store.deinitGlobalStore();
        std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};
        try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
        _ = geode.graph_store.initGlobalStore(allocator, tmp_path) catch |err| {
            std.debug.print("  [scenario={s}] store init failed: {}\n", .{ scn.name, err });
            continue;
        };

        // Run scenario-specific setup (seed data or noop).
        scn.setupFn(allocator) catch |err| {
            std.debug.print("  [scenario={s}] setup failed: {}\n", .{ scn.name, err });
            continue;
        };

        // Allocate sample slices.
        const parse_ns_samples = try allocator.alloc(u64, scn.iterations);
        defer allocator.free(parse_ns_samples);
        const execute_ns_samples = try allocator.alloc(u64, scn.iterations);
        defer allocator.free(execute_ns_samples);
        const row_count_samples = try allocator.alloc(u64, scn.iterations);
        defer allocator.free(row_count_samples);

        // Temp slices for warmup (single-slot, reused each warmup pass).
        const tmp_parse = try allocator.alloc(u64, 1);
        defer allocator.free(tmp_parse);
        const tmp_exec = try allocator.alloc(u64, 1);
        defer allocator.free(tmp_exec);
        const tmp_rows = try allocator.alloc(u64, 1);
        defer allocator.free(tmp_rows);

        runWarmup(allocator, ctx, scn, tmp_parse, tmp_exec, tmp_rows) catch |err| {
            std.debug.print("  [scenario={s}] warmup error: {}\n", .{ scn.name, err });
            // Non-fatal: proceed to timed loop.
        };

        // Timed loop.
        for (0..scn.iterations) |i| {
            scn.runFn(allocator, ctx, i, parse_ns_samples, execute_ns_samples, row_count_samples) catch |err| {
                std.debug.print("  [scenario={s}] iter {d} error: {}\n", .{ scn.name, i, err });
                // Fill remaining samples with the last recorded value or 0 to keep slice valid.
                if (i < parse_ns_samples.len) {
                    parse_ns_samples[i] = if (i > 0) parse_ns_samples[i - 1] else 0;
                    execute_ns_samples[i] = if (i > 0) execute_ns_samples[i - 1] else 0;
                    row_count_samples[i] = 0;
                }
                continue;
            };
        }

        // Sort ascending before computing median.
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
            .dataset_size = "mutation",
            .iterations = scn.iterations,
            .warmup_iterations = scn.warmup,
            .wall_time_ns_median = combined_ns,
            .wall_time_ns_stddev = parse_stat.stddev + exec_stat.stddev,
            .throughput_ops_per_sec = throughput,
            .parse_ns_per_op_p50 = parse_stat.median,
            .execute_ns_per_op_p50 = exec_stat.median,
            // No separate materialize phase for mutations.
            .materialize_ns_per_op_p50 = 0,
            .row_count_p50 = row_stat.median,
        });

        if (output_path == null) {
            std.debug.print(
                "  {s:<20} parse={d:>8}ns  exec={d:>10}ns  rows={d:>4}  {d:>10.0} ops/sec\n",
                .{ scn.name, parse_stat.median, exec_stat.median, row_stat.median, throughput },
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
        std.debug.print("bench-query-executor-mutation: wrote {d} rows to {s}\n", .{ expanded.len, path });
    } else {
        std.debug.print("\n{d} mutation scenarios measured. Pass --output <path> to emit ResultDocument JSON.\n", .{rows.items.len});
    }
}
