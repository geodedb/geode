const std = @import("std");

// Shared helper for variance benchmarks: parses environment overrides, provides
// minimal JSON emission, and trimming utility.
// CANARY: REQ=REQ-GQL-021; FEATURE="Bench Variance Infra"; ASPECT=VarianceConfigHelper; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_VarianceConfigHelper; OWNER=tooling; UPDATED=2025-09-22

pub const Config = struct {
    samples: usize,
    inner: usize,
    json: bool,
    trim_edges: usize, // number of extreme values to drop each side (post-sort)
    legacy_mode: bool = false, // optional backward-compatible variance evaluation
};

pub const Stats = struct {
    mean: f128,
    median: f128,
    mad: f128, // median absolute deviation
    p95: f128,
    cv: f128,
    p95_ratio: f128,
    min: f128,
    max: f128,
    len: usize,
};

pub const ThresholdSet = struct {
    cv_max: f128,
    p95_ratio_max: f128,
    min_mean: f128, // 0 when not enforced
};

fn envFloat(allocator: std.mem.Allocator, name: []const u8, def: f128) f128 {
    if (std.process.getEnvVarOwned(allocator, name)) |val| {
        defer allocator.free(val);
        return std.fmt.parseFloat(f128, val) catch def;
    } else |_| return def;
}

pub fn load(allocator: std.mem.Allocator, prefix: []const u8, default_samples: usize, default_inner: usize, default_trim: usize) Config {
    // Build env variable names at runtime to avoid comptime concat requirement.
    const samples_name = buildName(allocator, prefix, "_SAMPLES") catch return .{ .samples = default_samples, .inner = default_inner, .json = false, .trim_edges = default_trim };
    defer allocator.free(samples_name);
    const inner_name = buildName(allocator, prefix, "_INNER") catch unreachable;
    defer allocator.free(inner_name);
    const trim_name = buildName(allocator, prefix, "_TRIM") catch unreachable;
    defer allocator.free(trim_name);
    return Config{
        .samples = envInt(allocator, samples_name, default_samples),
        .inner = envInt(allocator, inner_name, default_inner),
        .json = envBool(allocator, "GEODE_BENCH_JSON", false),
        .trim_edges = envInt(allocator, trim_name, default_trim),
        .legacy_mode = envBool(allocator, "GEODE_BENCH_LEGACY", false),
    };
}

fn buildName(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ a, b });
}

fn envInt(allocator: std.mem.Allocator, name: []const u8, def: usize) usize {
    if (std.process.getEnvVarOwned(allocator, name)) |val| {
        defer allocator.free(val);
        return std.fmt.parseInt(usize, val, 10) catch def;
    } else |_| return def;
}

fn envBool(allocator: std.mem.Allocator, name: []const u8, def: bool) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |val| {
        defer allocator.free(val);
        return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on");
    } else |_| return def;
}

pub fn trimSlice(comptime T: type, slice: []const T, edges: usize) []const T {
    if (slice.len <= edges * 2 or edges == 0) return slice;
    return slice[edges .. slice.len - edges];
}

pub fn emitJson(metrics: anytype) void {
    // Extremely small JSON emitter (objects only, known primitive fields) with escaped braces.
    std.debug.print("{{", .{}); // opening '{'
    var first = true;
    inline for (.{ "schema_version", "benchmark", "samples", "variants", "inner", "trim_edges", "trimmed_len", "speedup_mean_trimmed", "speedup_mean_raw", "mean_trimmed", "median_trimmed", "mad_trimmed", "cv", "cv_threshold", "p95", "p95_ratio", "p95_ratio_threshold", "min_speedup_threshold", "pass" }) |field_name| {
        if (!@hasField(@TypeOf(metrics), field_name)) continue;
        if (!first) std.debug.print(",", .{}) else first = false;
        std.debug.print("\"{s}\":", .{field_name});
        const val = @field(metrics, field_name);
        const VT = @TypeOf(val);
        if (comptime std.mem.eql(u8, field_name, "benchmark")) {
            emitString(val);
        } else if (VT == []const u8) {
            emitString(val);
        } else if (VT == bool) {
            std.debug.print("{s}", .{if (val) "true" else "false"});
        } else {
            // assume numeric
            std.debug.print("{d}", .{val});
        }
    }
    std.debug.print("}}\n", .{}); // closing '}'
}

fn emitString(s: []const u8) void {
    std.debug.print("\"", .{});
    for (s) |c| switch (c) {
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        else => std.debug.print("{c}", .{c}),
    };
    std.debug.print("\"", .{});
}

pub fn computeStatsF128(allocator: std.mem.Allocator, data: []const f128) Stats {
    if (data.len == 0) return .{ .mean = 0, .median = 0, .mad = 0, .p95 = 0, .cv = 0, .p95_ratio = 0, .min = 0, .max = 0, .len = 0 };
    // Copy & sort for order statistics
    const tmp = allocator.alloc(f128, data.len) catch @panic("OOM stats alloc");
    defer allocator.free(tmp);
    @memcpy(tmp, data);
    std.sort.pdq(f128, tmp, {}, comptime std.sort.asc(f128));
    var sum: f128 = 0;
    for (data) |v| sum += v;
    const mean: f128 = sum / @as(f128, @floatFromInt(data.len));
    var var_acc: f128 = 0;
    for (data) |v| {
        const d = v - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(data.len));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    const mid = data.len / 2;
    const median: f128 = if ((data.len % 2) == 1) tmp[mid] else (tmp[mid - 1] + tmp[mid]) / 2.0;
    // MAD
    const deviations = allocator.alloc(f128, data.len) catch @panic("OOM mad alloc");
    defer allocator.free(deviations);
    var i: usize = 0;
    while (i < data.len) : (i += 1) deviations[i] = if (data[i] > median) data[i] - median else median - data[i];
    std.sort.pdq(f128, deviations, {}, comptime std.sort.asc(f128));
    const mad: f128 = if ((data.len % 2) == 1) deviations[mid] else (deviations[mid - 1] + deviations[mid]) / 2.0;
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = if (mean == 0) 0 else p95 / mean;
    return .{ .mean = mean, .median = median, .mad = mad, .p95 = p95, .cv = cv, .p95_ratio = p95_ratio, .min = tmp[0], .max = tmp[tmp.len - 1], .len = data.len };
}

pub fn thresholdsForBenchmark(name: []const u8) ThresholdSet {
    // P2-3: Use GeneralPurposeAllocator for arena backing
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    var gpa = std.heap.ArenaAllocator.init(gpa_instance.allocator());
    defer gpa.deinit();
    const a = gpa.allocator();
    // NOTE: Uses substring matching; if none match, fall back to general class thresholds (cv<=0.22, p95/mean<=2.60)
    var base: ThresholdSet = undefined;
    if (std.mem.indexOf(u8, name, "redo_optimization_delta")) |_| {
        // Adjusted cv/p95 thresholds (cv 0.18->0.22, p95_ratio 1.35->1.45) to account for
        // added logging overhead jitter while maintaining mean speedup >=1.0 guarantee.
        base = .{ .cv_max = 0.22, .p95_ratio_max = 1.45, .min_mean = 1.0 };
    } else if (std.mem.indexOf(u8, name, "path_cache_degree_bucket_utilization")) |_| {
        base = .{ .cv_max = 0.22, .p95_ratio_max = 2.55, .min_mean = 0.0 };
    } else {
        base = .{ .cv_max = 0.22, .p95_ratio_max = 2.60, .min_mean = 0.0 };
    }
    // Allow environment overrides: <UPPER_BENCH_NAME>_CV_MAX, _P95R_MAX, _MIN_MEAN
    // Convert benchmark name to upper and replace non-alnum with underscore for override names.
    var norm = a.alloc(u8, name.len) catch return base;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        norm[i] = if ((c >= 'a' and c <= 'z')) (c - 32) else if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z')) c else '_';
    }
    const cv_key = std.fmt.allocPrint(a, "{s}_CV_MAX", .{norm}) catch return base;
    const p95_key = std.fmt.allocPrint(a, "{s}_P95R_MAX", .{norm}) catch return base;
    const mean_key = std.fmt.allocPrint(a, "{s}_MIN_MEAN", .{norm}) catch return base;
    const cv_override = envFloat(a, cv_key, base.cv_max);
    const p95_override = envFloat(a, p95_key, base.p95_ratio_max);
    const mean_override = envFloat(a, mean_key, base.min_mean);
    return .{ .cv_max = cv_override, .p95_ratio_max = p95_override, .min_mean = mean_override };
}

pub inline fn scaledPpm(val: f128) u64 {
    // scale by 1e4 (not true ppm, but consistent with earlier doc usage) and clamp
    if (val <= 0) return 0;
    const scaled = val * 10000.0;
    if (scaled > 9.22e18) return 9220000000000000000; // clamp near u64 max safety
    return @intCast(@as(u128, @intFromFloat(scaled)));
}
