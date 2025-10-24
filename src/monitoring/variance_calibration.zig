const std = @import("std");

// Variance Auto-Calibration module
// Reads a sequence of benchmark JSON lines (historical outputs) and computes
// suggested thresholds (suggested_cv_max, suggested_p95_mean_ratio_max) using
// trimmed statistics (drop top/bottom 5%). Deterministic given ordered input.
//
// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationVarianceAutoCalibration"; ASPECT=AutoCalibrationLogic; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_004_PaginationVarianceAutoCalibration; OWNER=planner; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-075; FEATURE="CostModelVarianceAutoCalibration"; ASPECT=AutoCalibrationLogic; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_075_CostModelVarianceAutoCalibration; OWNER=planner; UPDATED=2025-09-27

pub const Suggestion = struct {
    suggested_cv_max: f64,
    suggested_p95_mean_ratio_max: f64,
};

pub fn calibrate(reader: anytype, allocator: std.mem.Allocator, maximum: usize) !Suggestion {
    var cvs = std.ArrayListUnmanaged(f64){};
    defer cvs.deinit(allocator);
    var ratios = std.ArrayListUnmanaged(f64){};
    defer ratios.deinit(allocator);

    // Read entire stream up to a sane cap (8 MiB) then tokenize by newlines.
    const MaxBytes = 8 * 1024 * 1024;
    const data = try reader.readAllAlloc(allocator, MaxBytes);
    defer allocator.free(data);

    var it = std.mem.tokenizeScalar(u8, data, '\n');
    var count: usize = 0;
    while (it.next()) |line| : (count += 1) {
        if (line.len == 0) continue;
        if (count >= maximum) break;
        if (std.mem.indexOf(u8, line, "\"cv\":")) |cv_idx| {
            const tail = line[cv_idx + 6 ..];
            if (parseFloatPrefix(tail)) |cv| try cvs.append(allocator, cv);
        }
        if (std.mem.indexOf(u8, line, "p95_mean_ratio")) |p_idx| {
            const tail2 = line[p_idx + 15 ..];
            if (parseFloatPrefix(tail2)) |ratio| try ratios.append(allocator, ratio);
        }
    }

    const calc = struct {
        fn trimmed(values: []f64) f64 {
            if (values.len == 0) return 0;
            std.sort.heap(f64, values, {}, comptime struct {
                fn lt(_: void, a: f64, b: f64) bool {
                    return a < b;
                }
            }.lt);
            const trim = if (values.len < 20) 0 else values.len / 20; // 5%
            const start = trim;
            const end = values.len - trim;
            var maxv: f64 = 0;
            var i: usize = start;
            while (i < end) : (i += 1) {
                if (values[i] > maxv) maxv = values[i];
            }
            return maxv;
        }
    };

    const cvs_slice = try allocator.alloc(f64, cvs.items.len);
    defer allocator.free(cvs_slice);
    std.mem.copyForwards(f64, cvs_slice, cvs.items);
    const ratios_slice = try allocator.alloc(f64, ratios.items.len);
    defer allocator.free(ratios_slice);
    std.mem.copyForwards(f64, ratios_slice, ratios.items);

    const suggested = Suggestion{
        .suggested_cv_max = calc.trimmed(cvs_slice) * 1.05, // 5% headroom
        .suggested_p95_mean_ratio_max = calc.trimmed(ratios_slice) * 1.10, // 10% headroom
    };
    return suggested;
}

fn parseFloatPrefix(bytes: []const u8) ?f64 {
    var i: usize = 0;
    while (i < bytes.len and (bytes[i] == ' ' or bytes[i] == ':' or bytes[i] == '"')) : (i += 1) {}
    const start = i;
    while (i < bytes.len and (bytes[i] == '.' or (bytes[i] >= '0' and bytes[i] <= '9'))) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, bytes[start..i]) catch null;
}
