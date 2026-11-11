// benchmark_rls_row_skip.zig
//
// PERF-A / #808: RLS row-rebuild elimination micro-benchmark.
//
// The match loop's per-row RLS hot path (`passesRLSExprFilter` in
// src/execution/match_operations.zig) used to rebuild a StringHashMap row via
// `rls_value_bridge.nodePropertiesToRLSRowInto` for EVERY candidate node before
// calling `RLSEngine.checkRowAccessByUsername`. After PERF-A, the row is only
// built when `engine.needsRowDataForTable()` reports that an applicable
// compiled policy actually reads row data (bytecode contains `load_row`).
//
// Scenarios (each measures the real production functions, per-row ns):
//   - rls_row_build_baseline: the OLD per-row shape — unconditional
//     nodePropertiesToRLSRowInto + checkRowAccessByUsername against a
//     row-free policy (the policy never reads the row; the build is waste).
//   - rls_row_skip: the NEW per-row shape for the same row-free policy —
//     needsRowDataForTable gate (false) → clearRetainingCapacity +
//     checkRowAccessByUsername with the empty scratch row.
//   - rls_row_build_gated: the NEW per-row shape when the policy DOES read
//     row data — needsRowDataForTable gate (true) + build + check. Shows the
//     pre-scan overhead added to the needs-row path.
//
// Emits a schema_version-2 VarianceEnvelope JSON line + VARIANCE_OK /
// VARIANCE_FAIL token per scenario (GAP-0244 conventions, mirroring
// benchmark_ts_storage.zig), plus a PERF_A_SPEEDUP summary line comparing
// the skip path against the baseline.
//
// CANARY: REQ=REQ-PERF-RLS-ROW-SKIP-001; FEATURE="RLSRowBuildSkip"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_PERF_RLS_ROW_SKIP_001_RowSkipVarianceEnvelope; OWNER=performance; UPDATED=2026-06-11

const std = @import("std");
const builtin = @import("builtin");
const rls = @import("rls");
const geode = @import("geode");
const rls_value_bridge = @import("rls_value_bridge");
const graph_store = geode.graph_store;

const RLSEngine = rls.RLSEngine;
const Value = rls.Value;
const Policy = RLSEngine.Policy;
const Expression = RLSEngine.Expression;
const CompiledExpression = RLSEngine.CompiledExpression;

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var t: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &t);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t);
    }
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}

const Stats = struct {
    mean_ns: f64,
    min_ns: u64,
    max_ns: u64,
    p95_ns: u64,
    cv: f64,
    p95_over_mean: f64,
    sample_count: usize,
};

fn computeStats(samples: []u64) Stats {
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));
    var diff: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        diff += d * d;
    }
    const variance = diff / @as(f64, @floatFromInt(samples.len));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    const p95_idx = (samples.len * 95) / 100;
    const p95 = samples[if (p95_idx >= samples.len) samples.len - 1 else p95_idx];
    const p95_over_mean = if (mean == 0) 0 else @as(f64, @floatFromInt(p95)) / mean;
    return .{
        .mean_ns = mean,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .p95_ns = p95,
        .cv = cv,
        .p95_over_mean = p95_over_mean,
        .sample_count = samples.len,
    };
}

inline fn scaledPpm(val: f64) u64 {
    if (val <= 0) return 0;
    const scaled = val * 10000.0;
    if (scaled > 9.2e18) return 9_200_000_000_000_000_000;
    return @intFromFloat(scaled);
}

// Variance thresholds (General class). NOT enforced — the VARIANCE_OK /
// VARIANCE_FAIL token + envelope "pass" field carry the verdict (GAP-0244).
const CV_MAX_PPM: u64 = 20000; // cv <= 2.00
const P95_OVER_MEAN_MAX_PPM: u64 = 50000; // p95/mean <= 5.0

fn emitEnvelope(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    st: Stats,
    warmup: usize,
) !bool {
    const cv_ppm = scaledPpm(st.cv);
    const p95om_ppm = scaledPpm(st.p95_over_mean);
    const cv_pass = cv_ppm <= CV_MAX_PPM;
    const p95_pass = p95om_ppm <= P95_OVER_MEAN_MAX_PPM;
    const pass = cv_pass and p95_pass;
    const jitter_class: []const u8 = if (st.cv < 0.10) "low" else if (st.cv < 0.20) "medium" else "high";

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"{s}\"," ++
            "\"mean_ns\":{d},\"min_ns\":{d},\"max_ns\":{d},\"sample_count\":{d},\"warmup_count\":{d}," ++
            "\"cv_scaled_ppm\":{d},\"p95_ns\":{d},\"p95_over_mean_scaled_ppm\":{d}," ++
            "\"cv_max_scaled_ppm\":{d},\"p95_over_mean_max_scaled_ppm\":{d},\"jitter_class\":\"{s}\"," ++
            "\"thresholds_evaluated\":[" ++
            "{{\"metric\":\"cv_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}," ++
            "{{\"metric\":\"p95_over_mean_scaled_ppm\",\"actual\":{d},\"max\":{d},\"pass\":{s}}}]," ++
            "\"pass\":{s}}}\n",
        .{
            name,
            @as(u64, @intFromFloat(st.mean_ns)),
            st.min_ns,
            st.max_ns,
            st.sample_count,
            warmup,
            cv_ppm,
            st.p95_ns,
            p95om_ppm,
            CV_MAX_PPM,
            P95_OVER_MEAN_MAX_PPM,
            jitter_class,
            cv_ppm,
            CV_MAX_PPM,
            if (cv_pass) "true" else "false",
            p95om_ppm,
            P95_OVER_MEAN_MAX_PPM,
            if (p95_pass) "true" else "false",
            if (pass) "true" else "false",
        },
    );
    defer allocator.free(line);
    try out.appendSlice(allocator, line);

    const token = try std.fmt.allocPrint(
        allocator,
        "{s} {s} mean_ns={d} cv={d:.4} p95_over_mean={d:.4} n={d}\n",
        .{
            if (pass) "VARIANCE_OK" else "VARIANCE_FAIL",
            name,
            @as(u64, @intFromFloat(st.mean_ns)),
            st.cv,
            st.p95_over_mean,
            st.sample_count,
        },
    );
    defer allocator.free(token);
    try out.appendSlice(allocator, token);

    return pass;
}

const GRAPH = "bench_graph";
const ROW_FREE_TABLE = "RowFree";
const ROW_BOUND_TABLE = "RowBound";

fn basePolicy() Policy {
    return Policy{
        .id = 0,
        .name = "",
        .description = "",
        .graph = GRAPH,
        .table = "",
        .operation = .select,
        .permissive = false,
        .roles = &.{},
        .using_expr = null,
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

// Row-bound pinned bytecode: row.classification != 'secret' (contains load_row).
const row_bound_constants = [_]Value{
    .{ .string = "classification" },
    .{ .string = "secret" },
};
const row_bound_bytecode = [_]u8{
    0x10, 0x00, // load_row 0
    0x01, 0x01, // push_const 1
    0x21, // neq
    0xFF, // ret
};

fn setupEngine(allocator: std.mem.Allocator, row_bound_compiled: *CompiledExpression) !*RLSEngine {
    const engine = try allocator.create(RLSEngine);
    engine.* = try RLSEngine.init(allocator);

    // Row-free restrictive policy compiled from raw GQL-ish expression:
    // `current_user = current_user` → [load_user, load_user, eq, ret].
    // No load_row → needs_row_data=false → the match loop may skip the build.
    var row_free = basePolicy();
    row_free.id = 1;
    row_free.name = "row_free_user_check";
    row_free.table = ROW_FREE_TABLE;
    row_free.using_expr = Expression{
        .raw = "current_user = current_user",
        .parsed = null,
        .compiled = null, // compiled by createPolicy
        .parameters = &.{},
    };
    try engine.createPolicy(row_free);

    // Row-bound pinned policy: reads row.classification → build required.
    var row_bound = basePolicy();
    row_bound.id = 2;
    row_bound.name = "row_bound_classification";
    row_bound.table = ROW_BOUND_TABLE;
    row_bound.using_expr = Expression{
        .raw = "classification != 'secret'",
        .parsed = null,
        .compiled = row_bound_compiled,
        .parameters = &.{},
    };
    try engine.createPolicy(row_bound);

    return engine;
}

fn buildProperties(allocator: std.mem.Allocator) !graph_store.CompactPropertyMap {
    // 8 mixed-type properties — a representative node payload for the
    // per-row conversion the old path performed unconditionally.
    var props = graph_store.CompactPropertyMap.init(allocator);
    try props.put("name", .{ .String = "alice" });
    try props.put("classification", .{ .String = "public" });
    try props.put("age", .{ .Int = 34 });
    try props.put("score", .{ .Float = 9.25 });
    try props.put("active", .{ .Bool = true });
    try props.put("dept", .{ .String = "engineering" });
    try props.put("region", .{ .String = "eu-west" });
    try props.put("balance", .{ .Decimal = .{ .coeff = 199999, .scale = 2 } });
    return props;
}

const SAMPLES_N: usize = 200;
const WARMUP_N: usize = 10;
const BATCH: usize = 100; // rows per timed sample → ns/row metric

const Mode = enum {
    baseline_build, // OLD: unconditional row build, row-free policy
    skip, // NEW: gate says no → empty scratch row, row-free policy
    row_bound_baseline, // OLD: unconditional row build, row-bound policy
    gated_build, // NEW: gate says yes → build, row-bound policy
};

fn runScenario(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    engine: *RLSEngine,
    props: *const graph_store.CompactPropertyMap,
    mode: Mode,
    name: []const u8,
    mean_out: *f64,
) !bool {
    var scratch = std.StringHashMap(Value).init(allocator);
    defer scratch.deinit();

    var samples = try allocator.alloc(u64, SAMPLES_N);
    defer allocator.free(samples);

    const table: []const u8 = switch (mode) {
        .baseline_build, .skip => ROW_FREE_TABLE,
        .row_bound_baseline, .gated_build => ROW_BOUND_TABLE,
    };

    // DCE sink: fold every verdict in so the loop cannot be elided.
    var sink: u64 = 0;

    var s: usize = 0;
    while (s < SAMPLES_N + WARMUP_N) : (s += 1) {
        const t0 = nowNs();
        var i: usize = 0;
        while (i < BATCH) : (i += 1) {
            switch (mode) {
                .baseline_build, .row_bound_baseline => {
                    // OLD passesRLSExprFilter shape: always rebuild the row.
                    try rls_value_bridge.nodePropertiesToRLSRowInto(&scratch, props);
                },
                .skip, .gated_build => {
                    // NEW passesRLSExprFilter shape: gate on the bytecode pre-scan.
                    if (engine.needsRowDataForTable(.select, GRAPH, table)) {
                        try rls_value_bridge.nodePropertiesToRLSRowInto(&scratch, props);
                    } else {
                        scratch.clearRetainingCapacity();
                    }
                },
            }
            const allowed = try engine.checkRowAccessByUsername(&scratch, .select, "alice", GRAPH, table);
            sink +%= @intFromBool(allowed);
        }
        const elapsed = nowNs() - t0;
        if (s >= WARMUP_N) samples[s - WARMUP_N] = elapsed / BATCH;
    }

    // Both policies allow the bench row, so sink must be the full row count;
    // observing it keeps the loop live.
    if (sink != (SAMPLES_N + WARMUP_N) * BATCH) return error.UnexpectedRlsVerdict;

    const st = computeStats(samples);
    mean_out.* = st.mean_ns;
    return emitEnvelope(out, allocator, name, st, WARMUP_N);
}

pub fn main() !void {
    // Arena: RLSEngine.compileExpression allocations are process-lifetime in
    // production and the engine does not free them on deinit; an arena keeps
    // the bench leak-free under the Debug allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var row_bound_compiled = CompiledExpression{
        .bytecode = &row_bound_bytecode,
        .constants = &row_bound_constants,
        .jump_table = &.{},
    };
    const engine = try setupEngine(allocator, &row_bound_compiled);
    defer engine.deinit();

    var props = try buildProperties(allocator);
    defer props.deinit();

    var baseline_mean: f64 = 0;
    var skip_mean: f64 = 0;
    var rb_baseline_mean: f64 = 0;
    var gated_mean: f64 = 0;

    _ = try runScenario(allocator, &out, engine, &props, .baseline_build, "rls_row_build_baseline", &baseline_mean);
    _ = try runScenario(allocator, &out, engine, &props, .skip, "rls_row_skip", &skip_mean);
    _ = try runScenario(allocator, &out, engine, &props, .row_bound_baseline, "rls_row_bound_baseline", &rb_baseline_mean);
    _ = try runScenario(allocator, &out, engine, &props, .gated_build, "rls_row_build_gated", &gated_mean);

    const speedup = if (skip_mean == 0) 0 else baseline_mean / skip_mean;
    const gate_overhead = gated_mean - rb_baseline_mean;
    const summary = try std.fmt.allocPrint(
        allocator,
        "PERF_A_SPEEDUP rls_row_skip vs rls_row_build_baseline: {d:.2}x " ++
            "(baseline_mean_ns={d:.0} skip_mean_ns={d:.0} row_bound_baseline_mean_ns={d:.0} " ++
            "gated_mean_ns={d:.0} gate_overhead_ns={d:.0})\n",
        .{ speedup, baseline_mean, skip_mean, rb_baseline_mean, gated_mean, gate_overhead },
    );
    defer allocator.free(summary);
    try out.appendSlice(allocator, summary);

    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, out.items) catch {};
}
