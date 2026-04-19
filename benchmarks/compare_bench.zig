// compare_bench (M0.6): reads two ResultDocument JSONs and returns
// non-zero when any matched row shows a regression beyond the noise
// gate. This is the comparator that gates perf changes in
// scripts/perf-gate.sh (M0.7) and CI.
//
// Matching:
//   rows are matched on (scenario_name, variant, measurement).
//   Unmatched rows (either side) are silently ignored — a perf change
//   that adds or removes a scenario isn't a regression of the
//   remaining rows.
//
// Noise gate:
//   gate_pct = max(15.0, 3.0 * stddev_pct) where
//   stddev_pct = (base.value_stddev / base.value) * 100 when base.value != 0.
//   When base.value == 0 the stddev component collapses to 0 and the
//   hard floor dominates.
//
// Direction (dispatched on measurement-name prefix):
//   throughput_  higher-is-better
//   improvement_ higher-is-better
//   latency_     lower-is-better
//   wall_time_   lower-is-better
//   ns_per_op_   lower-is-better
//   default      higher-is-better
//
// A row regresses when the signed delta pct crosses the gate in the
// "worse" direction. Improvements never fire.

const std = @import("std");
const schema = @import("bench_schema");

const HARD_FLOOR_PCT: f64 = 15.0;
const SIGMA_MULTIPLIER: f64 = 3.0;

fn isHigherIsBetter(measurement: []const u8) bool {
    if (std.mem.startsWith(u8, measurement, "throughput_")) return true;
    if (std.mem.startsWith(u8, measurement, "improvement_")) return true;
    if (std.mem.startsWith(u8, measurement, "latency_")) return false;
    if (std.mem.startsWith(u8, measurement, "wall_time_")) return false;
    if (std.mem.startsWith(u8, measurement, "ns_per_op_")) return false;
    return true; // default
}

fn noiseGatePct(base: schema.ResultRow) f64 {
    const stddev_pct = if (base.value != 0)
        (base.value_stddev / base.value) * 100.0
    else
        0.0;
    const sigma_gate = SIGMA_MULTIPLIER * @abs(stddev_pct);
    return @max(HARD_FLOOR_PCT, sigma_gate);
}

fn findMatchingRow(rows: []const schema.ResultRow, key: schema.ResultRow) ?schema.ResultRow {
    for (rows) |r| {
        if (std.mem.eql(u8, r.scenario_name, key.scenario_name) and
            std.mem.eql(u8, r.variant, key.variant) and
            std.mem.eql(u8, r.measurement, key.measurement))
        {
            return r;
        }
    }
    return null;
}

/// Compare `current` against `baseline` row-by-row and return the
/// number of rows that regressed beyond the noise gate. Prints one
/// line per matched row (including non-regressions) so the caller can
/// see exactly what the gate did.
pub fn compareDocuments(
    allocator: std.mem.Allocator,
    baseline: schema.ResultDocument,
    current: schema.ResultDocument,
) !usize {
    _ = allocator; // reserved for future per-row allocations
    var failures: usize = 0;
    for (baseline.rows) |base| {
        const curr = findMatchingRow(current.rows, base) orelse continue;
        const gate = noiseGatePct(base);
        const delta_pct: f64 = if (base.value != 0)
            (curr.value - base.value) / base.value * 100.0
        else
            0.0;
        const higher_is_better = isHigherIsBetter(base.measurement);
        const regressed = if (higher_is_better)
            delta_pct < -gate
        else
            delta_pct > gate;
        const verdict = if (regressed) "REGRESSION" else "ok";
        const sign: []const u8 = if (delta_pct >= 0) "+" else "";
        std.debug.print(
            "{s}/{s}/{s} delta {s}{d:.2}% (gate={d:.2}%, dir={s}) {s}\n",
            .{
                base.scenario_name,
                base.variant,
                base.measurement,
                sign,
                delta_pct,
                gate,
                if (higher_is_better) "higher_is_better" else "lower_is_better",
                verdict,
            },
        );
        if (regressed) failures += 1;
    }
    return failures;
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_argv = proc_init.args.vector;
    var baseline_path: ?[]const u8 = null;
    var current_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < raw_argv.len) : (idx += 1) {
        const a = std.mem.span(raw_argv[idx]);
        if (std.mem.eql(u8, a, "--baseline")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("compare-bench: --baseline requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            baseline_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--baseline=")) {
            baseline_path = a["--baseline=".len..];
        } else if (std.mem.eql(u8, a, "--current")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("compare-bench: --current requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            current_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--current=")) {
            current_path = a["--current=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "compare-bench --baseline <path> --current <path>\n" ++
                    "  Compares two ResultDocument JSON files emitted by\n" ++
                    "  bench-timeseries (M0.4) or benchmark (M0.5).\n" ++
                    "  Exits non-zero if any (scenario, variant, measurement)\n" ++
                    "  row regressed beyond max(15%, 3σ).\n",
                .{},
            );
            return;
        }
    }

    if (baseline_path == null or current_path == null) {
        std.debug.print("compare-bench: both --baseline and --current are required\n", .{});
        return error.InvalidArgs;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var baseline_parsed = try schema.readDocument(allocator, io, baseline_path.?);
    defer baseline_parsed.deinit();
    var current_parsed = try schema.readDocument(allocator, io, current_path.?);
    defer current_parsed.deinit();

    const failures = try compareDocuments(allocator, baseline_parsed.value, current_parsed.value);
    if (failures != 0) {
        std.debug.print("compare-bench: {d} regression(s) detected\n", .{failures});
        return error.BenchmarkRegression;
    }
    std.debug.print("compare-bench: no regressions detected\n", .{});
}
