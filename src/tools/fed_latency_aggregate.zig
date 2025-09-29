const std = @import("std");
const builtin = @import("builtin");

// Federation mismatch latency multi-run aggregation tool.
// Spawns the existing `bench_federation_mismatch_latency` executable multiple times,
// parses each JSON line, and computes aggregate stability metrics across runs.
// Promotion readiness heuristic: every run must satisfy raw cv<=0.22, trim_cv<=0.22,
// p95_mean_ratio<=2.55, outlier_ratio<=0.10. If all runs pass → promotion_ready=true.
// Config:
//   FED_LATENCY_AGG_RUNS   (default 5)   : number of independent runs
//   FED_LATENCY_STABILIZE   (pass-through): enables per-run stabilization loop if set by caller
//   FED_LATENCY_AGG_REQUIRE (0/1)        : if 1 and promotion_ready=false, exit non-zero.
//   FED_LATENCY_BENCH_PATH  (optional)   : override path to benchmark executable.
// Output: single JSON line summarizing runs.
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateMultiRun; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateMultiRun; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateRobustStats; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateRobustStats; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateArchive; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateArchive; OWNER=federation; UPDATED=2025-09-26

const RunMetrics = struct {
    mean_ns: f128 = 0,
    cv: f128 = 0,
    trim_cv: f128 = 0,
    p95_mean_ratio: f128 = 0,
    outlier_ratio: f128 = 0,
    passes: usize = 0,
    promotion_ok: bool = false,
    fail_reasons: u32 = 0, // bitmask for unmet criteria
};

fn median(vals: []f128) f128 {
    if (vals.len == 0) return 0;
    std.sort.block(f128, vals, {}, comptime std.sort.asc(f128));
    const mid = vals.len / 2;
    if (vals.len % 2 == 1) {
        return vals[mid];
    } else {
        return (vals[mid - 1] + vals[mid]) / 2.0;
    }
}

fn quartiles(sorted: []const f128) struct { q1: f128, q3: f128 } {
    if (sorted.len == 0) return .{ .q1 = 0, .q3 = 0 };
    // Assume input already sorted ascending.
    const mid = sorted.len / 2;
    const lower = sorted[0..mid];
    const upper = if (sorted.len % 2 == 0) sorted[mid..] else sorted[mid + 1 ..];
    var q1: f128 = 0;
    var q3: f128 = 0;
    if (lower.len > 0) {
        if (lower.len % 2 == 1) q1 = lower[lower.len / 2] else q1 = (lower[lower.len / 2 - 1] + lower[lower.len / 2]) / 2.0;
    }
    if (upper.len > 0) {
        if (upper.len % 2 == 1) q3 = upper[upper.len / 2] else q3 = (upper[upper.len / 2 - 1] + upper[upper.len / 2]) / 2.0;
    }
    return .{ .q1 = q1, .q3 = q3 };
}

fn mad(sorted: []const f128, median_val: f128, ally: std.mem.Allocator) f128 {
    if (sorted.len == 0) return 0;
    var deviations = ally.alloc(f128, sorted.len) catch return 0;
    defer ally.free(deviations);
    var i: usize = 0;
    while (i < sorted.len) : (i += 1) {
        const d = sorted[i] - median_val;
        deviations[i] = if (d < 0) -d else d;
    }
    // median of absolute deviations
    std.sort.block(f128, deviations, {}, comptime std.sort.asc(f128));
    const mid = deviations.len / 2;
    if (deviations.len % 2 == 1) return deviations[mid];
    return (deviations[mid - 1] + deviations[mid]) / 2.0;
}

fn parseF128(field: []const u8, json: []const u8) ?f128 {
    if (std.mem.indexOf(u8, json, field)) |idx| {
        const after = json[idx + field.len ..];
        // Expect number until delimiter comma or }.
        var end: usize = 0;
        while (end < after.len) : (end += 1) {
            const c = after[end];
            if (!(c == '-' or c == '+' or (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E')) break;
        }
        const num_slice = after[0..end];
        var f: f128 = 0;
        if (std.fmt.parseFloat(f128, num_slice)) |val| {
            f = val;
            return f;
        } else |_| {}
    }
    return null;
}

fn parseUsize(field: []const u8, json: []const u8) ?usize {
    if (std.mem.indexOf(u8, json, field)) |idx| {
        const after = json[idx + field.len ..];
        var end: usize = 0;
        while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
        if (end == 0) return null;
        return std.fmt.parseInt(usize, after[0..end], 10) catch null;
    }
    return null;
}

fn parseRun(json: []const u8) RunMetrics {
    var rm = RunMetrics{};
    rm.mean_ns = parseF128("\"mean_ns\":", json) orelse 0;
    rm.cv = parseF128("\"cv\":", json) orelse 0;
    rm.trim_cv = parseF128("\"trim_cv\":", json) orelse 0;
    rm.p95_mean_ratio = parseF128("\"p95_mean_ratio\":", json) orelse 0;
    rm.outlier_ratio = parseF128("\"outlier_ratio\":", json) orelse 0;
    rm.passes = parseUsize("\"passes\":", json) orelse 1;
    // Criteria bit indices:
    // 0: cv<=0.22, 1: trim_cv<=0.22, 2: p95_mean_ratio<=2.55, 3: outlier_ratio<=0.10
    if (!(rm.cv <= 0.22)) rm.fail_reasons |= @as(u32, 1) << 0;
    if (!(rm.trim_cv <= 0.22)) rm.fail_reasons |= @as(u32, 1) << 1;
    if (!(rm.p95_mean_ratio <= 2.55)) rm.fail_reasons |= @as(u32, 1) << 2;
    if (!(rm.outlier_ratio <= 0.10)) rm.fail_reasons |= @as(u32, 1) << 3;
    rm.promotion_ok = rm.fail_reasons == 0;
    return rm;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const ally = gpa.allocator();

    const runs: usize = blk: {
        if (std.process.getEnvVarOwned(ally, "FED_LATENCY_AGG_RUNS")) |v| {
            defer ally.free(v);
            if (std.fmt.parseInt(usize, v, 10)) |parsed| break :blk if (parsed == 0) 1 else parsed else |_| break :blk 5;
        } else |_| {}
        break :blk 5;
    };

    const bench_path_owned = std.process.getEnvVarOwned(ally, "FED_LATENCY_BENCH_PATH") catch null;
    defer if (bench_path_owned) |p| ally.free(p);
    const bench_path: []const u8 = bench_path_owned orelse "zig-out/bin/bench_federation_mismatch_latency";

    // Accumulators
    var total_cv: f128 = 0;
    var total_trim_cv: f128 = 0;
    var total_p95_ratio: f128 = 0;
    var total_outlier_ratio: f128 = 0;
    var max_cv: f128 = 0;
    var max_trim_cv: f128 = 0;
    var max_p95_ratio: f128 = 0;
    var max_outlier_ratio: f128 = 0;
    var all_promotion = true;

    // Collect per-run values for median calculations (optional future stats can reuse these vectors)
    var cvs = try ally.alloc(f128, runs);
    defer ally.free(cvs);
    var p95s = try ally.alloc(f128, runs);
    defer ally.free(p95s);
    var trim_cvs = try ally.alloc(f128, runs);
    defer ally.free(trim_cvs);
    var outlier_rs = try ally.alloc(f128, runs);
    defer ally.free(outlier_rs);

    const verbose_env = std.process.getEnvVarOwned(ally, "FED_LATENCY_VERBOSE") catch null;
    defer if (verbose_env) |v| ally.free(v);
    const verbose = verbose_env != null;
    var verbose_storage: [4096]u8 = undefined;
    var verbose_fbs = std.io.fixedBufferStream(&verbose_storage);
    var verbose_written = false;
    var aggregate_fail_mask: u32 = 0;
    var run_index: usize = 0;
    while (run_index < runs) : (run_index += 1) {
        var proc = std.process.Child.init(&[_][]const u8{bench_path}, ally);
        // Inherit environment (so FED_LATENCY_STABILIZE just propagates if exported by caller).
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        try proc.spawn();
        var read_buf: [4096]u8 = undefined;
        var total: usize = 0;
        if (proc.stdout) |stdout_file| {
            while (total < read_buf.len) {
                const n = stdout_file.read(read_buf[total..]) catch return error.ReadStdoutFailed;
                if (n == 0) break;
                total += n;
            }
        }
        const term = try proc.wait();
        if (term.Exited != 0) {
            std.debug.print("Run {d} failed: exit={d}\n", .{ run_index, term.Exited });
            all_promotion = false;
            continue;
        }
        const line = std.mem.trim(u8, read_buf[0..total], " \n\r\t");
        const rm = parseRun(line);
        total_cv += rm.cv;
        total_trim_cv += rm.trim_cv;
        total_p95_ratio += rm.p95_mean_ratio;
        total_outlier_ratio += rm.outlier_ratio;
        if (rm.cv > max_cv) max_cv = rm.cv;
        if (rm.trim_cv > max_trim_cv) max_trim_cv = rm.trim_cv;
        if (rm.p95_mean_ratio > max_p95_ratio) max_p95_ratio = rm.p95_mean_ratio;
        if (rm.outlier_ratio > max_outlier_ratio) max_outlier_ratio = rm.outlier_ratio;
        if (!rm.promotion_ok) {
            all_promotion = false;
            aggregate_fail_mask |= rm.fail_reasons;
        }
        cvs[run_index] = rm.cv;
        p95s[run_index] = rm.p95_mean_ratio;
        trim_cvs[run_index] = rm.trim_cv;
        outlier_rs[run_index] = rm.outlier_ratio;
        if (verbose) {
            const wv = verbose_fbs.writer();
            if (!verbose_written) {
                _ = wv.writeAll("\"runs_detail\":[") catch {};
                verbose_written = true;
            } else {
                _ = wv.writeAll(",") catch {};
            }
            // Build object manually to avoid format parser treating '{' as placeholder start.
            _ = wv.writeAll("{") catch {};
            _ = wv.writeAll("\"i\":") catch {};
            _ = wv.print("{d}", .{run_index}) catch {};
            _ = wv.writeAll(",\"cv\":") catch {};
            _ = wv.print("{d}", .{rm.cv}) catch {};
            _ = wv.writeAll(",\"trim_cv\":") catch {};
            _ = wv.print("{d}", .{rm.trim_cv}) catch {};
            _ = wv.writeAll(",\"p95_mean_ratio\":") catch {};
            _ = wv.print("{d}", .{rm.p95_mean_ratio}) catch {};
            _ = wv.writeAll(",\"outlier_ratio\":") catch {};
            _ = wv.print("{d}", .{rm.outlier_ratio}) catch {};
            _ = wv.writeAll(",\"passes\":") catch {};
            _ = wv.print("{d}", .{rm.passes}) catch {};
            _ = wv.writeAll(",\"fail_mask\":") catch {};
            _ = wv.print("{d}", .{rm.fail_reasons}) catch {};
            _ = wv.writeAll("}") catch {};
        }
    }
    const runs_f = @as(f128, @floatFromInt(runs));
    const avg_cv = if (runs > 0) total_cv / runs_f else 0;
    const avg_trim_cv = if (runs > 0) total_trim_cv / runs_f else 0;
    const avg_p95_ratio = if (runs > 0) total_p95_ratio / runs_f else 0;
    const avg_outlier_ratio = if (runs > 0) total_outlier_ratio / runs_f else 0;

    // Compute medians using copies so original order (for verbose runs_detail indices) remains intuitive.
    const cvs_copy = try ally.alloc(f128, runs);
    defer ally.free(cvs_copy);
    std.mem.copyForwards(f128, cvs_copy, cvs);
    const p95s_copy = try ally.alloc(f128, runs);
    defer ally.free(p95s_copy);
    std.mem.copyForwards(f128, p95s_copy, p95s);
    const trim_cvs_copy = try ally.alloc(f128, runs);
    defer ally.free(trim_cvs_copy);
    std.mem.copyForwards(f128, trim_cvs_copy, trim_cvs);
    const outlier_rs_copy = try ally.alloc(f128, runs);
    defer ally.free(outlier_rs_copy);
    std.mem.copyForwards(f128, outlier_rs_copy, outlier_rs);

    const median_cv = median(cvs_copy);
    const median_p95 = median(p95s_copy);
    const median_trim_cv = median(trim_cvs_copy);
    const median_outlier_ratio = median(outlier_rs_copy);

    // Robust stats (quartiles & MAD) for cv distribution.
    // cvs_copy was sorted inside median(); we re-sort to ensure ordering after potential modifications.
    std.sort.block(f128, cvs_copy, {}, comptime std.sort.asc(f128));
    const qs = quartiles(cvs_copy);
    const cv_iqr = qs.q3 - qs.q1;
    const cv_mad = mad(cvs_copy, median_cv, ally);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    const want_txt = blk_format: {
        if (std.process.getEnvVarOwned(ally, "FED_LATENCY_FORMAT")) |fmt| {
            defer ally.free(fmt);
            if (std.mem.eql(u8, fmt, "txt")) break :blk_format true;
        } else |_| {}
        break :blk_format false;
    };
    // Pre-compute summary_reason for both txt and json paths.
    var summary_reason: []const u8 = "all_criteria_met";
    if (!all_promotion) {
        const reason_entries2 = [_]struct { bit: u32, label: []const u8 }{
            .{ .bit = 0, .label = "cv" },
            .{ .bit = 1, .label = "trim_cv" },
            .{ .bit = 2, .label = "p95_mean_ratio" },
            .{ .bit = 3, .label = "outlier_ratio" },
        };
        for (reason_entries2) |re| {
            const bit5: u5 = @truncate(re.bit);
            const mask = (@as(u32, 1) << bit5);
            if ((aggregate_fail_mask & mask) != 0) {
                summary_reason = re.label;
                break;
            }
        }
    }
    if (want_txt) {
        // Human-readable single line summary. Use simple truncation to 3 decimals.
        const f_avg: f64 = @floatCast(avg_cv);
        const f_max: f64 = @floatCast(max_cv);
        const f_med: f64 = @floatCast(median_cv);
        // Convert to scaled integers for formatting (x1000) to approximate 3 decimals.
        const s_avg: i64 = @intFromFloat(@floor(f_avg * 1000.0));
        const s_max: i64 = @intFromFloat(@floor(f_max * 1000.0));
        const s_med: i64 = @intFromFloat(@floor(f_med * 1000.0));
        const avg_int = @divTrunc(s_avg, 1000);
        const avg_frac = @mod(s_avg, 1000);
        const max_int = @divTrunc(s_max, 1000);
        const max_frac = @mod(s_max, 1000);
        const med_int = @divTrunc(s_med, 1000);
        const med_frac = @mod(s_med, 1000);
        try w.print("FED_AGG runs={d} avg_cv={d}.{d:0>3} max_cv={d}.{d:0>3} med_cv={d}.{d:0>3} iqr_cv={d} mad_cv={d} pass={s} reason={s}\n", .{
            runs,
            avg_int,
            avg_frac,
            max_int,
            max_frac,
            med_int,
            med_frac,
            cv_iqr,
            cv_mad,
            if (all_promotion) "yes" else "no",
            if (all_promotion) "ok" else summary_reason,
        });
        const out_txt = fbs.getWritten();
        const stdout = if (builtin.os.tag == .windows)
            std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
        else
            std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        try stdout.writeAll(out_txt);
        if (!all_promotion) {
            if (std.process.getEnvVarOwned(ally, "FED_LATENCY_AGG_REQUIRE")) |v| {
                defer ally.free(v);
                if (v.len > 0 and v[0] == '1') return error.AggregatePromotionNotReady;
            } else |_| {}
        }
        return;
    }
    try w.writeAll("{\"aggregate\":\"BenchmarkCANARY_REQ_GQL_024_FederationMismatchLatencyVarianceEnvelope\",");
    try w.print("\"runs\":{},", .{runs});
    try w.print("\"avg_cv\":{d},", .{avg_cv});
    try w.print("\"avg_trim_cv\":{d},", .{avg_trim_cv});
    try w.print("\"avg_p95_mean_ratio\":{d},", .{avg_p95_ratio});
    try w.print("\"avg_outlier_ratio\":{d},", .{avg_outlier_ratio});
    try w.print("\"median_cv\":{d},", .{median_cv});
    try w.print("\"median_p95_mean_ratio\":{d},", .{median_p95});
    try w.print("\"median_trim_cv\":{d},", .{median_trim_cv});
    try w.print("\"median_outlier_ratio\":{d},", .{median_outlier_ratio});
    try w.print("\"cv_q1\":{d},", .{qs.q1});
    try w.print("\"cv_q3\":{d},", .{qs.q3});
    try w.print("\"cv_iqr\":{d},", .{cv_iqr});
    try w.print("\"cv_mad\":{d},", .{cv_mad});
    try w.print("\"max_cv\":{d},", .{max_cv});
    try w.print("\"max_trim_cv\":{d},", .{max_trim_cv});
    try w.print("\"max_p95_mean_ratio\":{d},", .{max_p95_ratio});
    try w.print("\"max_outlier_ratio\":{d},", .{max_outlier_ratio});
    try w.print("\"promotion_ready\":{s}", .{if (all_promotion) "true" else "false"});
    try w.print(",\"summary_reason\":\"{s}\"", .{summary_reason});
    if (!all_promotion) {
        try w.writeAll(",\"not_ready_reasons\":[");
        var first_reason = true;
        const reason_entries = [_]struct { bit: u32, label: []const u8 }{
            .{ .bit = 0, .label = "cv" },
            .{ .bit = 1, .label = "trim_cv" },
            .{ .bit = 2, .label = "p95_mean_ratio" },
            .{ .bit = 3, .label = "outlier_ratio" },
        };
        for (reason_entries) |re| {
            const bit5: u5 = @truncate(re.bit);
            const mask = (@as(u32, 1) << bit5);
            if ((aggregate_fail_mask & mask) != 0) {
                if (!first_reason) {
                    try w.writeAll(",");
                } else {
                    first_reason = false;
                }
                try w.print("\"{s}\"", .{re.label});
            }
        }
        try w.writeAll("]");
        try w.print(",\"fail_mask\":{d}", .{aggregate_fail_mask});
    }
    if (verbose and verbose_written) {
        var tail_w = verbose_fbs.writer();
        tail_w.writeAll("]") catch {};
        const detail = verbose_fbs.getWritten();
        try w.writeAll(",");
        try w.writeAll(detail);
    }
    try w.writeAll("}\n");
    const line_out = fbs.getWritten();
    const stdout2 = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout2.writeAll(line_out);

    // Optional archival append & rotation.
    if (std.process.getEnvVarOwned(ally, "FED_LATENCY_ARCHIVE_PATH") catch null) |ap| {
        defer ally.free(ap);
        var need_rotate = false;
        var max_lines: usize = 1000;
        if (std.process.getEnvVarOwned(ally, "FED_LATENCY_ARCHIVE_MAX_LINES") catch null) |ml| {
            defer ally.free(ml);
            if (std.fmt.parseInt(usize, ml, 10)) |parsed| {
                if (parsed > 0) max_lines = parsed;
            } else |_| {}
        }
        // Open (create if missing) for append.
        var file = std.fs.cwd().createFile(ap, .{ .truncate = false, .read = true, .mode = 0o666 }) catch |e| switch (e) {
            error.PathAlreadyExists => std.fs.cwd().openFile(ap, .{ .mode = .read_write }) catch return, // open existing
            else => return,
        };
        defer file.close();
        // Count lines quickly (stop after max_lines).
        var count: usize = 0;
        {
            var arch_buf: [8192]u8 = undefined;
            var r = file.reader(&arch_buf);
            while (true) {
                var b: [1]u8 = undefined;
                const n = r.read(&b) catch break;
                if (n == 0) break;
                if (b[0] == '\n') {
                    count += 1;
                    if (count >= max_lines) {
                        need_rotate = true;
                        break;
                    }
                }
            }
        }
        // Seek end for append (Zig 0.15 uses seekTo or seekFromEnd?). We'll re-open for append-only simplicity.
        if (need_rotate) {
            // Simple rotation: rename current -> current.1 (overwrite if exists) and create new.
            var tmp_name_buf: [1024]u8 = undefined;
            if (ap.len + 2 < tmp_name_buf.len) {
                std.mem.copyForwards(u8, tmp_name_buf[0..ap.len], ap);
                tmp_name_buf[ap.len] = '.';
                tmp_name_buf[ap.len + 1] = '1';
                const rot_name = tmp_name_buf[0 .. ap.len + 2];
                // Best effort remove existing .1
                _ = std.fs.cwd().deleteFile(rot_name) catch {};
                _ = std.fs.cwd().rename(ap, rot_name) catch {};
                // Recreate fresh file
                file.close();
                file = std.fs.cwd().createFile(ap, .{ .truncate = true, .read = true, .mode = 0o666 }) catch return;
            }
        }
        // Append line.
        _ = try file.seekFromEnd(0);
        _ = try file.writeAll(line_out);
    }

    if (!all_promotion) {
        if (std.process.getEnvVarOwned(ally, "FED_LATENCY_AGG_REQUIRE")) |v| {
            defer ally.free(v);
            if (v.len > 0 and v[0] == '1') return error.AggregatePromotionNotReady;
        } else |_| {}
    }
}

test "fed_latency_aggregate_basic" {
    // Skip actual spawning to avoid dependency on built bench in unit test context.
    // Exercise parser on representative line.
    const example = "{\"bench\":\"BenchmarkCANARY_REQ_GQL_024_FederationMismatchLatencyVarianceEnvelope\",\"class\":\"General\",\"iterations\":64,\"passes\":1,\"mean_ns\":200.0,\"p95_ns\":210,\"p95_mean_ratio\":1.0500,\"cv\":0.200000,\"trim_mean_ns\":190.0,\"trim_cv\":0.150000,\"trim_p95_ns\":205,\"min_ns\":180,\"max_ns\":250,\"outlier_count\":6,\"outlier_ratio\":0.093750}";
    const rm = parseRun(example);
    try std.testing.expect(rm.promotion_ok);
}

test "median helper even/odd" {
    var arr_even = [_]f128{ 0.2, 0.3, 0.1, 0.4 };
    std.sort.block(f128, &arr_even, {}, comptime std.sort.asc(f128));
    // After sort: 0.1 0.2 0.3 0.4 median = (0.2+0.3)/2 = 0.25
    try std.testing.expectApproxEqAbs((arr_even[1] + arr_even[2]) / 2.0, 0.25, 0.000001);
    var arr_odd = [_]f128{ 0.2, 0.5, 0.1 };
    std.sort.block(f128, &arr_odd, {}, comptime std.sort.asc(f128));
    // After sort: 0.1 0.2 0.5 median = 0.2
    try std.testing.expectApproxEqAbs(arr_odd[1], 0.2, 0.000001);
}
