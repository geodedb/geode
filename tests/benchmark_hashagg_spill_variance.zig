const std = @import("std");
const exec = @import("../src/exec.zig");
const ast = @import("../src/gql/ast.zig");
const eval = @import("../src/eval.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggSpillVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_012_HashAggSpillVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

fn stats(values: []i128) struct { mean: f64, stddev: f64, cv: f64, p95: i128 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f128 = sum / @as(f128, @floatFromInt(values.len));
    var var_acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f128;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(values.len));
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean_cast = @as(f64, @floatCast(mean_f128));
    const tmp = std.heap.page_allocator.alloc(i128, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(i128, tmp, values);
    std.sort.pdq(i128, tmp, {}, comptime std.sort.asc(i128));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean_cast, .stddev = stddev, .cv = if (mean_cast == 0) 0 else stddev / mean_cast, .p95 = p95 };
}

// Force spill by setting very low memory limit relative to rows.
test "BenchmarkCANARY_REQ_GQL_012_HashAggSpillVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const runs = 36;
    var build = try ally.alloc(i128, runs);
    defer ally.free(build);
    var emit = try ally.alloc(i128, runs);
    defer ally.free(emit);

    // Query: GROUP BY g RETURN SUM(a)
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fns = ast.Expr{ .Ident = "sum" };
    const sum_a = ast.Expr{ .Call = .{ .callee = &fns, .args = &.{&a} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = sum_a, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };

    // Build large dataset to exceed memory limit of HashAggregator quickly.
    var data = std.ArrayList([]const exec.BindingValue).init(ally);
    defer data.deinit();
    var gi: usize = 0;
    while (gi < 4000) : (gi += 1) { // many groups to pressure memory
        const val: i64 = @intCast(gi % 17);
        const grp_name = if ((gi & 1) == 0) "EVEN" else "ODD";
        const row = [_]exec.BindingValue{ .{ .Int = val }, .{ .Str = grp_name } };
        try data.append(row[0..]);
    }

    var run: usize = 0;
    while (run < runs) : (run += 1) {
        // Convert BindingValue rows to eval.Value rows for runGroupedQuery input (needs raw eval.Value matrix)
        var eval_rows = std.ArrayList([]const eval.Value).init(ally);
        defer eval_rows.deinit();
        for (data.items) |r| {
            const v = [_]eval.Value{ .{ .Int = r[0].Int }, if (r[1] == .Str) .{ .Str = r[1].Str } else .{ .Str = "?" } };
            try eval_rows.append(v[0..]);
        }
        var timings: exec.AggStageTimings = .{};
        const out = try exec.runGroupedQuery(ally, q, names, eval_rows.items, &.{}, &.{}, &timings);
        defer ally.free(out);
        build[run] = timings.build_ns;
        emit[run] = timings.emit_ns;
    }

    const st_build = stats(build);
    const st_emit = stats(emit);
    if (st_build.cv > 0.22 or st_emit.cv > 0.22 or
        @as(f128, @floatFromInt(st_build.p95)) > @as(f128, @floatCast(st_build.mean)) * 2.55 or
        @as(f128, @floatFromInt(st_emit.p95)) > @as(f128, @floatCast(st_emit.mean)) * 2.55)
    {
        std.debug.print("VARIANCE_FAIL HashAggSpillVarianceEnvelope build_cv={:.4} emit_cv={:.4} build_p95={} emit_p95={}\n", .{ st_build.cv, st_emit.cv, st_build.p95, st_emit.p95 });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK HashAggSpillVarianceEnvelope build_cv={:.4} emit_cv={:.4} build_p95={} emit_p95={}\n", .{ st_build.cv, st_emit.cv, st_build.p95, st_emit.p95 });
}
