const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Regression Check"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchRegressionCompare; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Regression JSON Summary"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchRegressionJsonSummary; OWNER=engine; UPDATED=2025-09-20

pub const Metric = struct {
    kind: []const u8,
    // dynamic map of metric name -> value (all numeric u64 parsed)
    values: std.StringHashMap(u64),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const args = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, args);
    if (args.len < 3) {
        std.log.err("usage: bench_regress <baseline.jsonl> <current.jsonl> [tolerance_pct=15] [--write-baseline <out.jsonl>] [--force]", .{});
        return error.InvalidArgs;
    }
    const baseline_path = args[1];
    const current_path = args[2];
    var tolerance_pct: f64 = 15.0;
    var write_baseline: ?[]const u8 = null;
    var force = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--write-baseline")) {
            if (a.len == "--write-baseline".len) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                write_baseline = args[i];
            } else if (a["--write-baseline".len] == '=') {
                write_baseline = a["--write-baseline=".len..];
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.indexOfScalar(u8, a, '.') != null or (a[0] >= '0' and a[0] <= '9')) {
            // treat as tolerance float
            const parsed = std.fmt.parseFloat(f64, a) catch null;
            if (parsed) |v| tolerance_pct = v;
        } else {
            std.log.warn("unrecognized arg: {s}", .{a});
        }
    }

    var baseline_map = try loadFile(ally, baseline_path);
    defer freeMetricMap(ally, &baseline_map);
    var current_map = try loadFile(ally, current_path);
    defer freeMetricMap(ally, &current_map);

    var failures: usize = 0;
    var total_compared: usize = 0;
    var regression_list = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer regression_list.deinit(ally);
    var it = baseline_map.iterator();
    while (it.next()) |entry| {
        const kind = entry.key_ptr.*;
        const base_metrics = entry.value_ptr.*; // *MetricData = map of metric name -> value
        if (current_map.get(kind)) |cur_metrics| {
            // iterate metrics present in baseline
            var b_it = base_metrics.iterator();
            while (b_it.next()) |m_entry| {
                const metric_name = m_entry.key_ptr.*;
                const base_val = m_entry.value_ptr.*;
                if (cur_metrics.get(metric_name)) |cur_val| {
                    total_compared += 1;
                    if (!withinTolerance(base_val, cur_val, tolerance_pct)) {
                        failures += 1;
                        const msg = try std.fmt.allocPrint(ally, "{s}:{s}", .{ kind, metric_name });
                        try regression_list.append(ally, msg);
                        std.log.err("REGRESSION kind={s} metric={s} baseline={d} current={d} tol_pct={d:.2}", .{ kind, metric_name, base_val, cur_val, tolerance_pct });
                    }
                }
            }
        } else {
            std.log.warn("Missing current metrics for kind={s}", .{kind});
        }
    }

    // Write baseline if requested and allowed
    if (write_baseline) |out_path| {
        if (failures > 0 and !force) {
            std.log.err("Refusing to write new baseline due to regressions (use --force)", .{});
            return error.RegressionDetected;
        }
        try writeBaseline(out_path, &current_map);
    }

    // Emit JSON summary to stdout (single line)
    try emitSummary(&.{ .baseline_path = baseline_path, .current_path = current_path }, tolerance_pct, failures, total_compared, regression_list.items);

    if (failures > 0) return error.RegressionDetected;
}

fn withinTolerance(base: u64, cur: u64, tol_pct: f64) bool {
    if (base == 0) return true; // nothing to compare
    const diff = if (cur > base) cur - base else 0;
    const pct = (@as(f64, @floatFromInt(diff)) * 100.0) / @as(f64, @floatFromInt(base));
    return pct <= tol_pct;
}

const MetricMap = std.StringHashMap(std.StringHashMap(u64)); // kind -> (metric -> value)

fn loadFile(ally: std.mem.Allocator, path: []const u8) !MetricMap {
    var map = MetricMap.init(ally);
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const cap = @min(stat.size, 10_000_000); // 10MB safety
    var buf = try ally.alloc(u8, cap);
    defer ally.free(buf);
    const read_len = try file.readAll(buf);
    var slice = buf[0..read_len];
    while (slice.len > 0) {
        const nl_idx = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
        const line = slice[0..nl_idx];
        if (line.len > 0) {
            parseLine(ally, line, &map) catch {};
        }
        if (nl_idx == slice.len) break;
        slice = slice[nl_idx + 1 ..];
    }
    return map;
}
fn parseLine(ally: std.mem.Allocator, line: []const u8, map: *MetricMap) !void {
    // naive scan: extract kind string and any top-level numeric fields (u64)
    const kind_key = "\"kind\":\"";
    const kind_pos = std.mem.indexOfPos(u8, line, 0, kind_key) orelse return error.Skip;
    const kind_start = kind_pos + kind_key.len;
    const end_quote = std.mem.indexOfScalarPos(u8, line, kind_start, '"') orelse return error.Skip;
    const kind = line[kind_start..end_quote];
    var metrics = std.StringHashMap(u64).init(ally);
    // scan for pattern "<name>":<number>
    var scan_index: usize = 0;
    while (scan_index < line.len) : (scan_index += 1) {
        if (line[scan_index] == '"') {
            const name_start = scan_index + 1;
            const name_end = std.mem.indexOfScalarPos(u8, line, name_start, '"') orelse break;
            const name = line[name_start..name_end];
            var j = name_end + 1;
            while (j < line.len and (line[j] == ' ' or line[j] == ':')) : (j += 1) {}
            if (j >= line.len) break;
            // collect digits
            var k = j;
            var any_digit = false;
            while (k < line.len and line[k] >= '0' and line[k] <= '9') : (k += 1) any_digit = true;
            if (any_digit) {
                const num_slice = line[j..k];
                if (std.fmt.parseInt(u64, num_slice, 10)) |val| {
                    // skip kind itself (string) and timestamp-like big ints only if name not recognized? we keep all numeric
                    if (!std.mem.eql(u8, name, "ts_ms")) { // exclude timestamp from regression comparison
                        try metrics.put(try allyDup(ally, name), val);
                    }
                } else |_| {}
                scan_index = k;
            }
        }
    }
    try map.put(try allyDup(ally, kind), metrics);
}

fn allyDup(ally: std.mem.Allocator, s: []const u8) ![]u8 {
    return ally.dupe(u8, s);
}

fn freeMetricMap(ally: std.mem.Allocator, map: *MetricMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        // free nested metrics map
        var inner_it = entry.value_ptr.*.iterator();
        while (inner_it.next()) |m_entry| {
            ally.free(m_entry.key_ptr.*);
        }
        entry.value_ptr.*.deinit();
        ally.free(entry.key_ptr.*);
    }
    map.deinit();
}

fn writeBaseline(path: []const u8, map: *MetricMap) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var it = map.iterator();
    while (it.next()) |entry| {
        const metrics = entry.value_ptr.*;
        var line_buf: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&line_buf);
        const ally = fba.allocator();
        var arr = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        const w = arr.writer(ally);
        try std.fmt.format(w, "{{\"kind\":\"{s}\"", .{entry.key_ptr.*});
        var m_it = metrics.iterator();
        while (m_it.next()) |m_entry| {
            try std.fmt.format(w, ",\"{s}\":{d}", .{ m_entry.key_ptr.*, m_entry.value_ptr.* });
        }
        try w.writeAll("}\n");
        try file.writeAll(arr.items);
    }
}

fn emitSummary(paths: *const struct { baseline_path: []const u8, current_path: []const u8 }, tol_pct: f64, failures: usize, total: usize, regressions: []const []const u8) !void {
    const ts = std.time.milliTimestamp();
    var stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ally = fba.allocator();
    var arr = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    const tol_int: u64 = @intFromFloat(tol_pct + 0.5);
    // Build JSON manually to avoid format brace escaping issues.
    try arr.appendSlice(ally, "{\"type\":\"bench_regress_summary\",");
    try arr.appendSlice(ally, "\"baseline\":\"");
    try arr.appendSlice(ally, paths.baseline_path);
    try arr.appendSlice(ally, "\",\"current\":\"");
    try arr.appendSlice(ally, paths.current_path);
    try arr.appendSlice(ally, "\",\"tolerance_pct\":");
    try appendInt(ally, &arr, tol_int);
    try arr.appendSlice(ally, ",\"compared\":");
    try appendInt(ally, &arr, total);
    try arr.appendSlice(ally, ",\"regressions\":");
    try appendInt(ally, &arr, failures);
    try arr.appendSlice(ally, ",\"regression_keys\":[");
    for (regressions, 0..) |key, idx| {
        if (idx > 0) try arr.appendSlice(ally, ",");
        try arr.appendSlice(ally, "\"");
        try arr.appendSlice(ally, key);
        try arr.appendSlice(ally, "\"");
    }
    try arr.appendSlice(ally, "],\"ts_ms\":");
    try appendInt(ally, &arr, ts);
    try arr.appendSlice(ally, "}\n");
    try stdout_file.writeAll(arr.items);
}

fn writeAll(w: anytype, data: []const u8) !void {
    _ = w;
    _ = data;
}

fn appendInt(ally: std.mem.Allocator, list: *std.ArrayList(u8), value: anytype) !void {
    var tmp: [32]u8 = undefined;
    const written = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try list.appendSlice(ally, written);
}

test "TestCANARY_REQ_GQL_010_BenchRegressionCompare" {
    // direct tolerance checks
    try std.testing.expect(withinTolerance(1000, 1080, 15.0)); // 8% increase OK
    try std.testing.expect(!withinTolerance(1000, 1200, 15.0));
}

test "TestCANARY_REQ_GQL_010_BenchRegressionJsonSummary" {
    // Build small in-memory metric maps and emit summary
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var baseline = MetricMap.init(ally);
    defer freeMetricMap(ally, &baseline);
    var cur = MetricMap.init(ally);
    defer freeMetricMap(ally, &cur);
    var inner_b = std.StringHashMap(u64).init(ally);
    try inner_b.put(try allyDup(ally, "elapsed_ns"), 1000);
    try baseline.put(try allyDup(ally, "K1"), inner_b);
    var inner_c = std.StringHashMap(u64).init(ally);
    try inner_c.put(try allyDup(ally, "elapsed_ns"), 1090);
    try cur.put(try allyDup(ally, "K1"), inner_c);
    var regressions = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer regressions.deinit(ally);
    // Should be within tolerance 15%
    // call emitSummary to ensure JSON summary path works
    try emitSummary(&.{ .baseline_path = "b", .current_path = "c" }, 15.0, 0, 1, regressions.items);
}
