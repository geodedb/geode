// CANARY: REQ=REQ-GQL-009; FEATURE="Query Executor"; ASPECT=Engine; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-011; FEATURE="UNION/EXCEPT/INTERSECT"; ASPECT=Engine; STATUS=TESTED; TEST=tests/e2e_setops_all.zig; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=Engine; STATUS=TESTED; TEST=tests/e2e_protocol_groupby_basic.zig; OWNER=engine; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-012; FEATURE="Aggregation COUNT DISTINCT"; ASPECT=CountDistinct; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_CountDistinctExec; OWNER=engine; UPDATED=2025-09-21

const std = @import("std");
const ast = @import("gql/ast.zig");
const planner = @import("planner.zig");
const printer = @import("gql/print.zig");
const eval = @import("eval.zig");
const eval_extended = @import("eval_extended.zig");
const graph_store = @import("graph_store.zig");
const stdx = std;
const auth = @import("geode_auth");
const rls = @import("rls");
/// Tuning knobs for set-ops implementations.
pub const SetOpsTuning = struct {
    /// For UNION DISTINCT: if total input rows >= this, prefer hash-based dedup then sort; else sort+unique directly.
    pub const union_distinct_hash_threshold: usize = 2048;
};

pub const Row = struct {
    // For this minimal harness, a single key expression (temporal literal) to sort by.
    key: ast.Expr,
    // An identifier to test stability.
    id: usize,
    // Values for the projected columns (for DISTINCT deduplication)
    values: []eval.Value = &.{},
};

// Deduplicate rows if DISTINCT is specified
pub fn dedupRowsIfDistinct(rows: []Row, distinct: bool, order: ?ast.OrderBy, arena: std.mem.Allocator) ![]Row {
    if (!distinct or rows.len == 0) return rows;

    // Track seen rows using a hash map
    var seen = std.AutoHashMap(u64, void).init(arena);
    defer seen.deinit();

    var result = std.ArrayList(Row).init(arena);
    defer result.deinit();

    for (rows) |row| {
        // Compute hash of row values
        var hasher = std.hash.Wyhash.init(0);
        for (row.values) |val| {
            // Simple hash based on value type and content
            switch (val) {
                .Null => hasher.update("null"),
                .Bool => |b| hasher.update(if (b) "true" else "false"),
                .Int => |i| {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{}", .{i}) catch "0";
                    hasher.update(s);
                },
                .String => |s| hasher.update(s),
                else => hasher.update("other"),
            }
        }
        const hash = hasher.final();

        // Check if we've seen this row before
        const gop = try seen.getOrPut(hash);
        if (!gop.found_existing) {
            try result.append(row);
        }
    }

    // If ordered, maintain the order; otherwise return deduplicated rows
    if (order != null) {
        // Already maintained order by processing in sequence
    }

    return result.toOwnedSlice();
}

pub fn stableOrderByTemporal(rows: []Row, desc: bool, nulls_policy: ?ast.OrderBy.NullsPolicy, ctx: planner.SessionContext, allocator: std.mem.Allocator) !void {
    // Sort indices to keep original stability; break ties by original index.
    const idxs = try allocator.alloc(usize, rows.len);
    defer allocator.free(idxs);
    for (idxs, 0..) |*p, i| p.* = i;
    const Ctx = struct {
        rows: []Row,
        desc: bool,
        nulls_policy: ?ast.OrderBy.NullsPolicy,
        ctx: planner.SessionContext,
        /// P2-3: Added allocator for temporary allocations in sort comparison
        allocator: std.mem.Allocator,
    };
    const sctx = Ctx{ .rows = rows, .desc = desc, .nulls_policy = nulls_policy, .ctx = ctx, .allocator = allocator };
    std.sort.pdq(usize, idxs, sctx, struct {
        fn isNull(e: ast.Expr) bool {
            return e == .Null;
        }
        fn less(sc: Ctx, a: usize, b: usize) bool {
            const ra = sc.rows[a];
            const rb = sc.rows[b];
            const a_is_null = isNull(ra.key);
            const b_is_null = isNull(rb.key);
            if (a_is_null or b_is_null) {
                // If both null, stable tie-break
                if (a_is_null and b_is_null) return a < b;
                // If only one is null, use nulls_policy
                const np = sc.nulls_policy orelse ast.OrderBy.NullsPolicy.default;
                if (np == .first) return a_is_null;
                if (np == .last) return !a_is_null;
                // Default: nulls last for ASC, first for DESC (common SQL default)
                if (sc.desc) return !a_is_null; // DESC: nulls first
                return !b_is_null; // ASC: nulls last
            }
            const cmp = planner.compareTemporalForOrder(ra.key, rb.key, sc.ctx) catch {
                // Fallback to lexicographic stringify on error.Invalid
                // P2-3: Use provided allocator instead of page_allocator
                const tmp_ally = sc.allocator;
                const sa = printer.stringifyExprAlloc(tmp_ally, ra.key, .{}) catch return a < b;
                defer tmp_ally.free(sa);
                const sb = printer.stringifyExprAlloc(tmp_ally, rb.key, .{}) catch return a < b;
                defer tmp_ally.free(sb);
                // Unicode-aware ORDER BY comparison: normalize to NFC then compare bytes
                // CANARY: REQ=REQ-GQL-UNICODE-010; FEATURE="UnicodeOrderBy"; ASPECT=CompareNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_010_OrderByNfc; OWNER=unicode; UPDATED=2025-09-27
                const unicode = @import("unicode/geode_unicode.zig");
                const na = unicode.nfcNormalize(tmp_ally, sa) catch sa;
                defer if (na.ptr != sa.ptr) tmp_ally.free(na);
                const nb = unicode.nfcNormalize(tmp_ally, sb) catch sb;
                defer if (nb.ptr != sb.ptr) tmp_ally.free(nb);
                const ord = std.mem.order(u8, na, nb);
                if (sc.desc) return ord == .gt else return ord == .lt;
            };
            if (sc.desc) {
                if (cmp == 0) return a < b; // stable tie-breaker
                return cmp > 0;
            } else {
                if (cmp == 0) return a < b;
                return cmp < 0;
            }
        }
    }.less);
    // Reorder rows in-place according to idxs
    var tmp = try allocator.alloc(Row, rows.len);
    defer allocator.free(tmp);
    for (idxs, 0..) |i, j| tmp[j] = rows[i];
    std.mem.copyForwards(Row, rows, tmp);
}

test "stable ORDER BY with cross-timezone equivalence and local attach" {
    const allocator = std.testing.allocator;
    const ctx = planner.SessionContext{ .session_offset_minutes = 0 };
    var rows: [4]Row = .{
        .{ .id = 0, .key = .{ .DateTime = .{ .raw = "2024-01-01T10:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00Z", true) } } },
        .{ .id = 1, .key = .{ .DateTime = .{ .raw = "2024-01-01T11:00+01:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T11:00+01:00", true) } } },
        .{ .id = 2, .key = .{ .DateTime = .{ .raw = "2024-01-01T09:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T09:00Z", true) } } },
        .{ .id = 3, .key = .{ .LocalDateTime = .{ .raw = "2024-01-01T10:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00", false) } } },
    };
    // Ascending sort should place 09:00Z first; 10:00Z, 11:00+01:00, and local 10:00 (session 0) are equal instants.
    try stableOrderByTemporal(&rows, false, null, ctx, allocator);
    try std.testing.expect(rows[0].id == 2);
    // The next three can be in original relative order among equal keys due to stability: ids 0,1,3 should preserve input order 0,1,3.
    try std.testing.expect(rows[1].id == 0);
    try std.testing.expect(rows[2].id == 1);
    try std.testing.expect(rows[3].id == 3);
}

test "ORDER BY nulls policy: FIRST/LAST" {
    const allocator = std.testing.allocator;
    const ctx = planner.SessionContext{ .session_offset_minutes = 0 };
    var rows: [5]Row = .{
        .{
            .id = 0,
            .key = .{.Null},
        },
        .{ .id = 1, .key = .{ .DateTime = .{ .raw = "2024-01-01T10:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00Z", true) } } },
        .{
            .id = 2,
            .key = .{.Null},
        },
        .{ .id = 3, .key = .{ .DateTime = .{ .raw = "2024-01-01T09:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T09:00Z", true) } } },
        .{ .id = 4, .key = .{ .DateTime = .{ .raw = "2024-01-01T11:00+01:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T11:00+01:00", true) } } },
    };
    // ASC NULLS FIRST: nulls should be at the start
    try stableOrderByTemporal(&rows, false, .first, ctx, allocator);
    try std.testing.expect(rows[0].id == 0);
    try std.testing.expect(rows[1].id == 2);
    // ASC NULLS LAST: nulls should be at the end
    var rows2 = rows;
    try stableOrderByTemporal(&rows2, false, .last, ctx, allocator);
    try std.testing.expect(rows2[3].id == 0);
    try std.testing.expect(rows2[4].id == 2);
    // DESC NULLS FIRST: nulls should be at the start
    var rows3 = rows;
    try stableOrderByTemporal(&rows3, true, .first, ctx, allocator);
    try std.testing.expect(rows3[0].id == 0);
    try std.testing.expect(rows3[1].id == 2);
    // DESC NULLS LAST: nulls should be at the end
    var rows4 = rows;
    try stableOrderByTemporal(&rows4, true, .last, ctx, allocator);
    try std.testing.expect(rows4[3].id == 0);
    try std.testing.expect(rows4[4].id == 2);
}

// Skeleton set operations over integer rows for semantics tests
pub fn dedupInts(allocator: std.mem.Allocator, vals: []const i64) ![]i64 {
    var set = std.AutoHashMap(i64, void).init(allocator);
    defer set.deinit();
    for (vals) |v| _ = try set.put(v, {});
    var out = try allocator.alloc(i64, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) out[i] = p.*;
    std.sort.block(i64, out, {}, std.sort.asc(i64));
    return out;
}

pub fn multisetIntersect(allocator: std.mem.Allocator, a: []const i64, b: []const i64) ![]i64 {
    var map = std.AutoHashMap(i64, usize).init(allocator);
    defer map.deinit();
    for (a) |v| {
        const cur = map.get(v) orelse 0;
        _ = try map.put(v, cur + 1);
    }
    var out = std.ArrayList(i64).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (b) |v| if (map.get(v)) |cnt| if (cnt > 0) {
        try out.append(allocator, v);
        _ = try map.put(v, cnt - 1);
    };
    return out.toOwnedSlice(allocator);
}

// ===========================
// End-to-end grouped query executor (AST-driven)
// ===========================

/// Execute a GROUP BY query over an input binding table provided as evaluator Values.
/// Inputs:
/// - q: Query with GROUP BY and RETURN; HAVING optional; RETURN items must be grouped keys or aggregates.
/// - input_names: identifier names aligned with each column in input_rows
/// - input_rows: matrix of evaluator Values for each input row
/// - param_names/param_values: optional parameter bindings referenced in expressions
/// Output: rows of BindingValue containing exactly the RETURN item values (projected order).
pub const AggStageTimings = struct { build_ns: i128 = 0, emit_ns: i128 = 0 };

pub fn runGroupedQuery(
    allocator: std.mem.Allocator,
    q: ast.Query,
    input_names: []const []const u8,
    input_rows: []const []eval.Value,
    param_names: []const []const u8,
    param_values: []const eval.Value,
    timings: ?*AggStageTimings,
    timeseries_store: ?*const @import("timeseries/timeseries.zig").Store,
) ![]const []const BindingValue {
    // Validate GROUP BY legality using planner first
    // P2-3: Pass allocator to planQuery
    _ = try planner.planQuery(allocator, q, .{});
    if (q.group_by == null) return error.Invalid; // requires GROUP BY
    const gb = q.group_by.?;
    // 1) Collect aggregates from RETURN and HAVING
    var aggs = std.ArrayList(Agg).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer aggs.deinit(allocator);
    var arg_exprs = std.ArrayList(?ast.Expr).initCapacity(allocator, 0) catch return error.OutOfMemory; // one per agg; null for COUNT(*)
    defer arg_exprs.deinit(allocator);

    const addAggFromExpr = struct {
        fn go(allocator_inner: std.mem.Allocator, aggs_out: *std.ArrayList(Agg), args_out: *std.ArrayList(?ast.Expr), e: ast.Expr) void {
            switch (e) {
                .Call => |c| switch (c.callee.*) {
                    .Ident => |id| {
                        if (std.ascii.eqlIgnoreCase(id.orig, "count")) {
                            if (c.args.len == 0) {
                                aggs_out.append(allocator_inner, .CountStar) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT(*) aggregate (OOM, query will fail): {any}", .{err});
                                };
                                args_out.append(allocator_inner, null) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT(*) args (OOM, query will fail): {any}", .{err});
                                };
                            } else {
                                aggs_out.append(allocator_inner, .Count) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT aggregate (OOM, query will fail): {any}", .{err});
                                };
                                args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT args (OOM, query will fail): {any}", .{err});
                                };
                            }
                        } else if (std.ascii.eqlIgnoreCase(id.orig, "countdistinct") or std.ascii.eqlIgnoreCase(id.orig, "count_distinct")) {
                            // Interim syntax: COUNT_DISTINCT(expr) or countDistinct(expr) until parser supports COUNT(DISTINCT expr)
                            if (c.args.len == 1) {
                                aggs_out.append(allocator_inner, .CountDistinct) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT DISTINCT aggregate (OOM, query will fail): {any}", .{err});
                                };
                                args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                    std.log.err("CRITICAL: Failed to append COUNT DISTINCT args (OOM, query will fail): {any}", .{err});
                                };
                            }
                        } else if (std.ascii.eqlIgnoreCase(id.orig, "sum")) {
                            aggs_out.append(allocator_inner, .Sum) catch |err| {
                                std.log.err("CRITICAL: Failed to append SUM aggregate (OOM, query will fail): {any}", .{err});
                            };
                            args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                std.log.err("CRITICAL: Failed to append SUM args (OOM, query will fail): {any}", .{err});
                            };
                        } else if (std.ascii.eqlIgnoreCase(id.orig, "min")) {
                            aggs_out.append(allocator_inner, .Min) catch |err| {
                                std.log.err("CRITICAL: Failed to append MIN aggregate (OOM, query will fail): {any}", .{err});
                            };
                            args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                std.log.err("CRITICAL: Failed to append MIN args (OOM, query will fail): {any}", .{err});
                            };
                        } else if (std.ascii.eqlIgnoreCase(id.orig, "max")) {
                            aggs_out.append(allocator_inner, .Max) catch |err| {
                                std.log.err("CRITICAL: Failed to append MAX aggregate (OOM, query will fail): {any}", .{err});
                            };
                            args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                std.log.err("CRITICAL: Failed to append MAX args (OOM, query will fail): {any}", .{err});
                            };
                        } else if (std.ascii.eqlIgnoreCase(id.orig, "avg")) {
                            aggs_out.append(allocator_inner, .Avg) catch |err| {
                                std.log.err("CRITICAL: Failed to append AVG aggregate (OOM, query will fail): {any}", .{err});
                            };
                            args_out.append(allocator_inner, c.args[0].*) catch |err| {
                                std.log.err("CRITICAL: Failed to append AVG args (OOM, query will fail): {any}", .{err});
                            };
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }.go;
    for (q.ret.items) |it| addAggFromExpr(allocator, &aggs, &arg_exprs, it.expr);
    if (q.having) |hv| addAggFromExpr(allocator, &aggs, &arg_exprs, hv);
    if (aggs.items.len == 0) {
        // Default to COUNT(*)
        try aggs.append(allocator, .CountStar);
        try arg_exprs.append(allocator, null);
    }

    // 2) Build input binding rows: evaluate group keys and aggregate arguments per input row
    const key_len = gb.keys.len;
    var rows = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer rows.deinit(allocator);
    // Build a map to memoize argument expression stringified forms to index
    var arg_sig_to_idx = std.StringHashMap(usize).init(allocator);
    defer arg_sig_to_idx.deinit();
    // Precompute signatures for arg_exprs for memoization keys
    var arg_sigs = try allocator.alloc([]const u8, arg_exprs.items.len);
    defer {
        var ii: usize = 0;
        while (ii < arg_sigs.len) : (ii += 1) if (arg_sigs[ii].len > 0) allocator.free(arg_sigs[ii]);
        allocator.free(arg_sigs);
    }
    var ai_sig: usize = 0;
    while (ai_sig < arg_exprs.items.len) : (ai_sig += 1) {
        if (arg_exprs.items[ai_sig]) |earg| {
            const s = printer.stringifyExprAlloc(allocator, earg, .{}) catch "";
            arg_sigs[ai_sig] = s;
            if (s.len > 0) _ = try arg_sig_to_idx.put(s, ai_sig);
        } else {
            arg_sigs[ai_sig] = &.{};
        }
    }

    const t_build_start = if (timings) |_| std.time.nanoTimestamp() else 0;
    for (input_rows) |vals| {
        // Make eval env for this row
        const env: eval.Env = .{ .names = input_names, .values = vals, .param_names = param_names, .param_values = param_values, .allocator = allocator, .timeseries_store = timeseries_store };
        // Evaluate keys
        var out_row = try allocator.alloc(BindingValue, key_len + aggs.items.len);
        // Keys
        var ki: usize = 0;
        while (ki < key_len) : (ki += 1) {
            const kv = eval.evalExpr(allocator, gb.keys[ki], env) catch eval.Value{ .Null = {} };
            out_row[ki] = valueToBinding(kv);
        }
        // Values for each aggregate argument (placed sequentially after keys in same order as aggs)
        // Evaluate aggregate arguments; simple per-row memoization when multiple aggs share same expr
        var ai: usize = 0;
        while (ai < aggs.items.len) : (ai += 1) {
            if (arg_exprs.items[ai]) |arg_e| {
                // Check for identical previous argument to reuse value
                var reused = false;
                var pj: usize = 0;
                while (pj < ai) : (pj += 1) {
                    if (arg_exprs.items[pj] != null and arg_sigs[pj].len > 0 and arg_sigs[ai].len > 0) {
                        if (std.mem.eql(u8, arg_sigs[pj], arg_sigs[ai])) {
                            out_row[key_len + ai] = out_row[key_len + pj];
                            reused = true;
                            break;
                        }
                    }
                }
                if (!reused) {
                    const vv = eval.evalExpr(allocator, arg_e, env) catch eval.Value{ .Null = {} };
                    out_row[key_len + ai] = valueToBinding(vv);
                }
            } else {
                out_row[key_len + ai] = BindingValue{ .Null = {} };
            }
        }
        try rows.append(allocator, out_row);
    }

    // 3) Run grouping
    var key_idxs_buf = try allocator.alloc(usize, key_len);
    defer allocator.free(key_idxs_buf);
    var j: usize = 0;
    while (j < key_len) : (j += 1) key_idxs_buf[j] = j;
    const spec: GroupSpec = .{ .key_idxs = key_idxs_buf, .aggs = aggs.items };
    // value_idxs align with arguments placed right after keys
    var v_idxs = try allocator.alloc(usize, aggs.items.len);
    defer allocator.free(v_idxs);
    var vi: usize = 0;
    while (vi < aggs.items.len) : (vi += 1) v_idxs[vi] = key_len + vi;
    const grouped = try groupAndAggregate(allocator, rows.items, spec, v_idxs);
    defer allocator.free(grouped);

    // 4) HAVING filter: build maps and evaluate predicate on aggregated rows
    var key_map = std.StringHashMap(usize).init(allocator);
    defer key_map.deinit();
    // Map each key's stringified expr to its index
    var tmp_allocd = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer {
        for (tmp_allocd.items) |s| allocator.free(s);
        tmp_allocd.deinit(allocator);
    }
    var kx: usize = 0;
    while (kx < key_len) : (kx += 1) {
        const ks = printer.stringifyExprAlloc(allocator, gb.keys[kx], .{}) catch "";
        if (ks.len > 0) {
            try key_map.put(ks, kx);
            try tmp_allocd.append(allocator, ks);
        }
    }
    var agg_map = std.StringHashMap(usize).init(allocator);
    defer agg_map.deinit();
    // Build normalized signatures for collected aggregates
    var ai2: usize = 0;
    while (ai2 < aggs.items.len) : (ai2 += 1) {
        var sig = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        defer sig.deinit(allocator);
        switch (aggs.items[ai2]) {
            .CountStar => try sig.appendSlice(allocator, "count(*)"),
            .Count => {
                try sig.appendSlice(allocator, "count(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
            .CountDistinct => {
                // Normalized signature uses lowercase function name no spaces: countdistinct(expr)
                try sig.appendSlice(allocator, "countdistinct(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
            .Sum => {
                try sig.appendSlice(allocator, "sum(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
            .Min => {
                try sig.appendSlice(allocator, "min(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
            .Max => {
                try sig.appendSlice(allocator, "max(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
            .Avg => {
                try sig.appendSlice(allocator, "avg(");
                const s = printer.stringifyExprAlloc(allocator, arg_exprs.items[ai2].?, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig.appendSlice(allocator, s);
                try sig.append(allocator, ')');
            },
        }
        try agg_map.put(sig.items, ai2);
    }

    // Filtered aggregated rows
    var kept = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer kept.deinit(allocator);
    if (q.having) |hv| {
        for (grouped) |gr| {
            const rewritten = rewriteExprWithAggregates(allocator, hv, &key_map, &agg_map, gr, key_len) catch ast.Expr{ .Null = {} };
            const v = eval.evalExpr(allocator, rewritten, .{ .names = &.{}, .values = &.{}, .allocator = allocator }) catch eval.Value{ .Null = {} };
            if (v == .Bool and v.Bool) try kept.append(allocator, gr);
        }
    } else {
        // keep all
        for (grouped) |gr| try kept.append(allocator, gr);
    }

    // 5) Project RETURN items for each kept row
    // Build maps for projection reuse (as above): key_map and agg_map already exist.
    if (timings) |tp| tp.build_ns = std.time.nanoTimestamp() - t_build_start;
    const t_emit_start = if (timings) |_| std.time.nanoTimestamp() else 0;
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (kept.items) |gr| {
        var prow = try allocator.alloc(BindingValue, q.ret.items.len);
        var ri: usize = 0;
        while (ri < q.ret.items.len) : (ri += 1) {
            const expr = q.ret.items[ri].expr;
            var set = false;
            switch (expr) {
                .Call => |c| blk_c: {
                    const callee = c.callee.*;
                    const nm = switch (callee) {
                        .Ident => |id| id.orig,
                        else => break :blk_c,
                    };
                    var sig = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
                    defer sig.deinit(allocator);
                    // lowercase name
                    var ii: usize = 0;
                    while (ii < nm.len) : (ii += 1) try sig.append(allocator, std.ascii.toLower(nm[ii]));
                    try sig.append(allocator, '(');
                    if (c.args.len == 0) {
                        try sig.append(allocator, '*');
                    } else if (c.args.len == 1) {
                        const s = printer.stringifyExprAlloc(allocator, c.args[0].*, .{}) catch "";
                        defer if (s.len > 0) allocator.free(s);
                        try sig.appendSlice(allocator, s);
                    }
                    try sig.append(allocator, ')');
                    if (agg_map.get(sig.items)) |rel| {
                        prow[ri] = gr[key_len + rel];
                        set = true;
                    }
                },
                else => {
                    const ks = printer.stringifyExprAlloc(allocator, expr, .{}) catch "";
                    defer if (ks.len > 0) allocator.free(ks);
                    if (key_map.get(ks)) |idx| {
                        prow[ri] = gr[idx];
                        set = true;
                    }
                },
            }
            if (!set) prow[ri] = BindingValue{ .Null = {} };
        }
        try out.append(allocator, prow);
    }
    // 6) ORDER BY on aggregated output, if present
    if (q.order_by) |ob| {
        if (ob.keys.len > 0 and out.items.len > 1) {
            // Precompute order-by expression values against aggregated rows, supporting alias and ordinal forms
            var keyvals = try allocator.alloc([]BindingValue, out.items.len);
            defer allocator.free(keyvals);
            var rix: usize = 0;
            while (rix < out.items.len) : (rix += 1) {
                var kv = try allocator.alloc(BindingValue, ob.keys.len);
                var kk: usize = 0;
                while (kk < ob.keys.len) : (kk += 1) {
                    var expr = ob.keys[kk].expr;
                    // If ORDER BY uses an ordinal (Int literal), map to the corresponding RETURN item
                    if (expr == .Int) {
                        const pos = expr.Int;
                        if (pos > 0 and pos <= @as(i64, @intCast(q.ret.items.len))) {
                            const idx: usize = @intCast(pos - 1);
                            expr = q.ret.items[idx].expr;
                        }
                    } else if (expr == .Ident) {
                        // If it's an alias, replace with the aliased expression
                        const id = expr.Ident.orig;
                        var ridx: ?usize = null;
                        var ri2: usize = 0;
                        while (ri2 < q.ret.items.len) : (ri2 += 1) {
                            if (q.ret.items[ri2].alias) |al| {
                                if (std.ascii.eqlIgnoreCase(al, id)) {
                                    ridx = ri2;
                                    break;
                                }
                            }
                        }
                        if (ridx) |jidx| expr = q.ret.items[jidx].expr;
                    }
                    // Evaluate against the aggregated row gr (kept row), not projection
                    const gr = kept.items[rix];
                    const rewritten = rewriteExprWithAggregates(allocator, expr, &key_map, &agg_map, gr, key_len) catch ast.Expr{ .Null = {} };
                    const v = eval.evalExpr(allocator, rewritten, .{ .names = &.{}, .values = &.{}, .allocator = allocator }) catch eval.Value{ .Null = {} };
                    kv[kk] = valueToBinding(v);
                }
                keyvals[rix] = kv;
            }
            // Sort stable by indices with comparator using nulls policy and desc
            const idxs = try allocator.alloc(usize, out.items.len);
            defer allocator.free(idxs);
            for (idxs, 0..) |*p, i| p.* = i;
            const Ctx = struct { rows: []const []const BindingValue, keys: []const []const BindingValue, ob: ast.OrderBy };
            const ctx = Ctx{ .rows = out.items, .keys = keyvals, .ob = ob };
            std.sort.pdq(usize, idxs, ctx, struct {
                fn less(s: Ctx, a: usize, b: usize) bool {
                    const ka = s.keys[a];
                    const kb = s.keys[b];
                    var i: usize = 0;
                    while (i < s.ob.keys.len) : (i += 1) {
                        const pol = s.ob.keys[i].nulls;
                        const desc = s.ob.keys[i].desc;
                        const va = ka[i];
                        const vb = kb[i];
                        const a_null = (va == .Null);
                        const b_null = (vb == .Null);
                        if (a_null or b_null) {
                            if (a_null and b_null) continue; // equal on this key
                            const nulls_first = switch (pol) {
                                .first => true,
                                .last => false,
                                .default => if (desc) true else false,
                            };
                            if (a_null != b_null) return if (a_null) nulls_first else !nulls_first;
                            continue;
                        }
                        const ord = valueOrder(va, vb);
                        if (ord != .eq) return if (desc) ord == .gt else ord == .lt;
                    }
                    return a < b; // stable tie-break
                }
            }.less);
            // Apply permutation
            var sorted = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer sorted.deinit(allocator);
            for (idxs) |ix| try sorted.append(allocator, out.items[ix]);
            out.deinit(allocator);
            out = sorted;
        }
    }
    if (timings) |tp2| tp2.emit_ns = std.time.nanoTimestamp() - t_emit_start;
    return out.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-TYPE-CONVERSION-001; FEATURE="ComplexTypeConversion"; STATUS=IMPL; UPDATED=2026-01-10
fn valueToBinding(v: eval.Value) BindingValue {
    return switch (v) {
        .Null => BindingValue{ .Null = {} },
        .Int => |n| BindingValue{ .Int = n },
        .Bool => |b| BindingValue{ .Bool = b },
        .Decimal => |d| BindingValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .Str => |s| BindingValue{ .Str = s },
        .List => |l| blk: {
            // For now, cannot convert nested lists without allocator
            // Return null for lists until proper conversion is implemented
            _ = l;
            break :blk BindingValue{ .Null = {} };
        },
        // GAP-0045: Properly preserve complex graph types instead of converting to NULL
        .Node => |n| BindingValue{ .Node = n },
        .Edge => |e| BindingValue{ .Edge = e },
        .Map => |m| BindingValue{ .Map = m },
        .ExtValue => |ext| BindingValue{ .ExtValue = ext },
        .Path => |p| BindingValue{ .Path = .{ .nodes = p.nodes, .edges = p.edges } },
        else => BindingValue{ .Null = {} },
    };
}

// ---------------------------
// Acceptance tests for executor
// ---------------------------

test "executor: COUNT(expr) vs COUNT(*)" {
    const allocator = std.testing.allocator;
    // Query: GROUP BY s RETURN COUNT(a), COUNT(*)
    const cal = ast.Expr{ .Ident = "count" };
    const a_id = ast.Expr{ .Ident = "a" };
    const s_id = ast.Expr{ .Ident = "s" };
    const call_count_a = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{&a_id} } };
    const call_count_star = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{} } };
    var items: [2]ast.ReturnItem = .{ .{ .expr = call_count_a, .alias = null }, .{ .expr = call_count_star, .alias = null } };
    const q: ast.Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = .{ .keys = &.{s_id} },
        .having = null,
        .ret = .{ .items = items[0..], .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
    const names = &.{ "a", "s" };
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "g1" } };
    const r1 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "g1" } };
    const r2 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "g2" } };
    const r3 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "g2" } };
    const rows: []const []eval.Value = &.{ r0[0..], r1[0..], r2[0..], r3[0..] };
    const out = try runGroupedQuery(allocator, q, names, rows, &.{}, &.{}, null, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    // Validate both groups: counts should be (1,2)
    var seen = [_]bool{ false, false };
    for (out) |r| {
        try std.testing.expect(r.len == 2);
        try std.testing.expect(r[0] == .Int);
        try std.testing.expect(r[1] == .Int);
        if (r[0].Int == 1 and r[1].Int == 2) {
            if (!seen[0]) {
                seen[0] = true;
            } else {
                seen[1] = true;
            }
        }
    }
    try std.testing.expect(seen[0]);
}

test "executor: empty input yields no groups" {
    const allocator = std.testing.allocator;
    const cal = ast.Expr{ .Ident = "count" };
    const s_id = ast.Expr{ .Ident = "s" };
    const call_count_star = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = call_count_star, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{s_id} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{"s"};
    const rows: []const []eval.Value = &.{};
    const out = try runGroupedQuery(allocator, q, names, rows, &.{}, &.{}, null, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 0);
}

test "executor: multi-key GROUP BY counts" {
    const allocator = std.testing.allocator;
    const cal = ast.Expr{ .Ident = "count" };
    const s1 = ast.Expr{ .Ident = "s1" };
    const s2 = ast.Expr{ .Ident = "s2" };
    const count_star = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = count_star, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{ s1, s2 } }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "s1", "s2" };
    const r0 = [_]eval.Value{ .{ .Str = "x" }, .{ .Str = "y" } };
    const r1 = [_]eval.Value{ .{ .Str = "x" }, .{ .Str = "y" } };
    const r2 = [_]eval.Value{ .{ .Str = "x" }, .{ .Str = "z" } };
    const rows: []const []eval.Value = &.{ r0[0..], r1[0..], r2[0..] };
    const out = try runGroupedQuery(allocator, q, names, rows, &.{}, &.{}, null, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
}

test "executor: complex HAVING with SUM/AVG/COUNT and projection" {
    const allocator = std.testing.allocator;
    // Query: GROUP BY g HAVING COUNT(*) > 2 AND (SUM(a) > 2 OR AVG(a) = 1) RETURN g, SUM(a), AVG(a)
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fnc = ast.Expr{ .Ident = "count" };
    const fns = ast.Expr{ .Ident = "sum" };
    const fnv = ast.Expr{ .Ident = "avg" };
    const count_star = ast.Expr{ .Call = .{ .callee = &fnc, .args = &.{} } };
    const sum_a = ast.Expr{ .Call = .{ .callee = &fns, .args = &.{&a} } };
    const avg_a = ast.Expr{ .Call = .{ .callee = &fnv, .args = &.{&a} } };
    const two = ast.Expr{ .Int = 2 };
    const one = ast.Expr{ .Int = 1 };
    const gt = ast.Expr{ .Binary = .{ .op = .Gt, .left = &count_star, .right = &two } };
    const gt2 = ast.Expr{ .Binary = .{ .op = .Gt, .left = &sum_a, .right = &two } };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &avg_a, .right = &one } };
    const orp = ast.Expr{ .Binary = .{ .op = .Or, .left = &gt2, .right = &eq } };
    const having = ast.Expr{ .Binary = .{ .op = .And, .left = &gt, .right = &orp } };
    var items: [3]ast.ReturnItem = .{ .{ .expr = g, .alias = null }, .{ .expr = sum_a, .alias = null }, .{ .expr = avg_a, .alias = null } };
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = having, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "A" } };
    const r1 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "A" } };
    const r2 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "A" } };
    const r3 = [_]eval.Value{ .{ .Int = 10 }, .{ .Str = "B" } };
    const rows: []const []eval.Value = &.{ r0[0..], r1[0..], r2[0..], r3[0..] };
    const out = try runGroupedQuery(allocator, q, names, rows, &.{}, &.{}, null, null);
    defer allocator.free(out);
    // Expect only group A remains, with columns: g, SUM(a)=4, AVG(a)=1
    try std.testing.expect(out.len == 1);
    const r = out[0];
    try std.testing.expect(r.len == 3);
    try std.testing.expect(r[0] == .Str and std.mem.eql(u8, r[0].Str, "A"));
    try std.testing.expect(r[1] == .Int and r[1].Int == 4);
    try std.testing.expect(r[2] == .Int and r[2].Int == 1);
}

test "executor: COUNT on NULL-only inputs and COUNT(*)" {
    const allocator = std.testing.allocator;
    const cal = ast.Expr{ .Ident = "count" };
    const a = ast.Expr{ .Ident = "a" };
    const g = ast.Expr{ .Ident = "g" };
    const cnt_a = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{&a} } };
    const cnt_star = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{} } };
    var items: [2]ast.ReturnItem = .{ .{ .expr = cnt_a, .alias = null }, .{ .expr = cnt_star, .alias = null } };
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    const r0 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "X" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    try std.testing.expect(out[0][0] == .Int and out[0][0].Int == 0);
    try std.testing.expect(out[0][1] == .Int and out[0][1].Int == 3);
}

test "executor: HAVING 3VL nested boolean with NULL short-circuit" {
    const allocator = std.testing.allocator;
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fnc = ast.Expr{ .Ident = "count" };
    const fnv = ast.Expr{ .Ident = "avg" };
    const cnt_a = ast.Expr{ .Call = .{ .callee = &fnc, .args = &.{&a} } };
    const avg_a = ast.Expr{ .Call = .{ .callee = &fnv, .args = &.{&a} } };
    const zero = ast.Expr{ .Int = 0 };
    const one = ast.Expr{ .Int = 1 };
    const gt0 = ast.Expr{ .Binary = .{ .op = .Gt, .left = &cnt_a, .right = &zero } };
    const eq1 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &avg_a, .right = &one } };
    const having = ast.Expr{ .Binary = .{ .op = .And, .left = &gt0, .right = &eq1 } };
    var items: [1]ast.ReturnItem = .{.{ .expr = g, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = having, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    // Group A: a values [1, null] -> COUNT(a)>0 true, AVG(a)=1 true -> kept
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "A" } };
    const r1 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "A" } };
    // Group B: a values [null] -> COUNT(a)>0 false, AVG(a)=NULL; false AND NULL -> false -> dropped
    const r2 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "B" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    try std.testing.expect(out[0][0] == .Str and std.mem.eql(u8, out[0][0].Str, "A"));
}

test "executor: multi-key GROUP BY with NULL keys" {
    const allocator = std.testing.allocator;
    const k1 = ast.Expr{ .Ident = "k1" };
    const k2 = ast.Expr{ .Ident = "k2" };
    const cal = ast.Expr{ .Ident = "count" };
    const cnt = ast.Expr{ .Call = .{ .callee = &cal, .args = &.{} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = cnt, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{ k1, k2 } }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "k1", "k2" };
    const r0 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "x" } };
    const r1 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "x" } };
    const r2 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "y" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    // Expect two groups: (NULL,x) and (NULL,y)
    try std.testing.expect(out.len == 2);
}

test "executor: ORDER BY over aggregated outputs with NULLS policy" {
    const allocator = std.testing.allocator;
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fns = ast.Expr{ .Ident = "sum" };
    const sum_a = ast.Expr{ .Call = .{ .callee = &fns, .args = &.{&a} } };
    var items: [2]ast.ReturnItem = .{ .{ .expr = g, .alias = null }, .{ .expr = sum_a, .alias = null } };
    var ok1: [2]ast.OrderBy.OrderKey = .{ .{ .expr = sum_a, .desc = false, .nulls = .last }, .{ .expr = g, .desc = false, .nulls = .first } };
    const ob = ast.OrderBy{ .keys = ok1[0..] };
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = ob, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    // Groups: A(sum=3), B(sum=NULL), C(sum=1)
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "A" } };
    const r1 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "A" } };
    const r2 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "B" } };
    const r3 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "C" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..], r3[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    // Expect order by SUM ascending with NULLS LAST -> C(1), A(3), B(NULL)
    try std.testing.expect(out.len == 3);
    try std.testing.expect(out[0][0] == .Str and std.mem.eql(u8, out[0][0].Str, "C"));
    try std.testing.expect(out[1][0] == .Str and std.mem.eql(u8, out[1][0].Str, "A"));
    try std.testing.expect(out[2][0] == .Str and std.mem.eql(u8, out[2][0].Str, "B"));
}

test "grouping: Decimal SUM/AVG and MIN/MAX over strings and bools" {
    const allocator = std.testing.allocator;
    // rows: (g, d as Decimal literal via eval.Value, s, b)
    const rows: []const []BindingValue = &.{
        &.{ .{ .Str = "A" }, .{ .Decimal = .{ .coeff = 1234, .scale = 2 } }, .{ .Str = "z" }, .{ .Bool = true } }, // 12.34
        &.{ .{ .Str = "A" }, .{ .Decimal = .{ .coeff = 1, .scale = 0 } }, .{ .Str = "a" }, .{ .Bool = false } }, // 1
        &.{ .{ .Str = "B" }, .{ .Null = {} }, .{ .Str = "m" }, .{ .Bool = true } },
    };
    // Aggs: SUM(d), AVG(d), MIN(s), MAX(b)
    const spec = GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .Avg, .Min, .Max } };
    const vals = &.{ 1, 1, 2, 3 }; // indices for d,d,s,b
    const out = try groupAndAggregate(allocator, rows, spec, vals);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    var sawA = false;
    var sawB = false;
    for (out) |r| {
        if (r[0] == .Str and std.mem.eql(u8, r[0].Str, "A")) {
            sawA = true;
            // SUM = 12.34 + 1 = 13.34 (coeff=1334, scale=2)
            try std.testing.expect(r[1] == .Decimal and r[1].Decimal.scale == 2 and r[1].Decimal.coeff == 1334);
            // AVG = (12.34 + 1)/2 = 6.67 (truncation) => 13.34/2 = 6.67 -> 667 coeff @ scale 2
            try std.testing.expect(r[2] == .Decimal and r[2].Decimal.scale == 2 and r[2].Decimal.coeff == 667);
            // MIN(s) over ["z","a"] => "a"
            try std.testing.expect(r[3] == .Str and std.mem.eql(u8, r[3].Str, "a"));
            // MAX(b) over [true,false] => true
            try std.testing.expect(r[4] == .Bool and r[4].Bool == true);
        }
        if (r[0] == .Str and std.mem.eql(u8, r[0].Str, "B")) {
            sawB = true;
            // SUM/AVG NULL (no non-null decimals); MIN(s)="m"; MAX(b)=true
            try std.testing.expect(r[1] == .Null);
            try std.testing.expect(r[2] == .Null);
            try std.testing.expect(r[3] == .Str and std.mem.eql(u8, r[3].Str, "m"));
            try std.testing.expect(r[4] == .Bool and r[4].Bool == true);
        }
    }
    try std.testing.expect(sawA and sawB);
}

test "executor: HAVING with Decimal literal compares against decimal AVG" {
    const allocator = std.testing.allocator;
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fna = ast.Expr{ .Ident = "avg" };
    const avg_a = ast.Expr{ .Call = .{ .callee = &fna, .args = &.{&a} } };
    // HAVING AVG(a) > 1.50
    const one_five = ast.Expr{ .Decimal = .{ .coeff = 150, .scale = 2 } };
    const gt = ast.Expr{ .Binary = .{ .op = .Gt, .left = &avg_a, .right = &one_five } };
    var items: [1]ast.ReturnItem = .{.{ .expr = g, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = gt, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    // Groups: X -> [1.00, 2.20] avg = 1.60 -> kept; Y -> [1.00] avg = 1.00 -> dropped
    const r0 = [_]eval.Value{ .{ .Decimal = .{ .coeff = 100, .scale = 2 } }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Decimal = .{ .coeff = 220, .scale = 2 } }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Decimal = .{ .coeff = 100, .scale = 2 } }, .{ .Str = "Y" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    try std.testing.expect(out[0][0] == .Str and std.mem.eql(u8, out[0][0].Str, "X"));
}

test "executor: ORDER BY using ordinal and alias resolution on aggregated output" {
    const allocator = std.testing.allocator;
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fns = ast.Expr{ .Ident = "sum" };
    const sum_a = ast.Expr{ .Call = .{ .callee = &fns, .args = &.{&a} } };
    var items: [2]ast.ReturnItem = .{ .{ .expr = g, .alias = null }, .{ .expr = sum_a, .alias = "total" } };
    // ORDER BY 2 ASC, alias then
    var ok: [2]ast.OrderBy.OrderKey = .{ .{ .expr = .{ .Int = 2 }, .desc = false, .nulls = .last }, .{ .expr = .{ .Ident = "total" }, .desc = true, .nulls = .default } };
    const ob = ast.OrderBy{ .keys = ok[0..] };
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = ob, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    // Groups: X(sum=3), Y(sum=1)
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "Y" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    // ORDER BY 2 (sum) ASC: Y(1) then X(3). Second key orders by alias desc but distinct sums mean first key decides
    try std.testing.expect(out[0][0] == .Str and std.mem.eql(u8, out[0][0].Str, "Y"));
    try std.testing.expect(out[1][0] == .Str and std.mem.eql(u8, out[1][0].Str, "X"));
}

test "executor: COUNT_DISTINCT basic dedup and NULL exclusion" {
    const allocator = std.testing.allocator;
    // Query: GROUP BY g RETURN COUNT_DISTINCT(a)
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fnc = ast.Expr{ .Ident = "countDistinct" };
    const cntd_a = ast.Expr{ .Call = .{ .callee = &fnc, .args = &.{&a} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = cntd_a, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "X" } };
    const r3 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "X" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..], r3[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    // Distinct non-null values: {1,2} => 2
    try std.testing.expect(out[0].len == 1);
    try std.testing.expect(out[0][0] == .Int and out[0][0].Int == 2);
}

test "executor: COUNT_DISTINCT multi-group" {
    const allocator = std.testing.allocator;
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    const fnc2 = ast.Expr{ .Ident = "count_distinct" };
    const cntd_a = ast.Expr{ .Call = .{ .callee = &fnc2, .args = &.{&a} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = cntd_a, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    // Group X: values 1,1,2 -> 2 distinct; Group Y: values 5,5 -> 1 distinct
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "X" } };
    const r3 = [_]eval.Value{ .{ .Int = 5 }, .{ .Str = "Y" } };
    const r4 = [_]eval.Value{ .{ .Int = 5 }, .{ .Str = "Y" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..], r3[0..], r4[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    var sawX = false;
    var sawY = false;
    for (out) |r| {
        try std.testing.expect(r.len == 1);
        if (r[0] == .Int and r[0].Int == 2) sawX = true else if (r[0] == .Int and r[0].Int == 1) sawY = true;
    }
    try std.testing.expect(sawX and sawY);
}

test "TestCANARY_REQ_GQL_012_CountDistinctExec" {
    // E2E: parse source with COUNT(DISTINCT) and run grouping manually through runGroupedQuery using constructed AST.
    const allocator = std.testing.allocator;
    // Build AST manually similar to parser output: RETURN COUNT(DISTINCT a) GROUP BY g
    const g = ast.Expr{ .Ident = "g" };
    const a = ast.Expr{ .Ident = "a" };
    // Executor expects synthetic callee countDistinct produced by parser rewrite
    const fnc = ast.Expr{ .Ident = "countDistinct" };
    const cntd_a = ast.Expr{ .Call = .{ .callee = &fnc, .args = &.{&a} } };
    var items: [1]ast.ReturnItem = .{.{ .expr = cntd_a, .alias = null }};
    const q: ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = .{ .keys = &.{g} }, .having = null, .ret = .{ .items = items[0..], .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const names = &.{ "a", "g" };
    const r0 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "X" } };
    const r1 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "X" } };
    const r2 = [_]eval.Value{ .{ .Int = 2 }, .{ .Str = "X" } };
    const out = try runGroupedQuery(allocator, q, names, &.{ r0[0..], r1[0..], r2[0..] }, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    try std.testing.expect(out[0][0] == .Int and out[0][0].Int == 2);
}

pub fn multisetExcept(allocator: std.mem.Allocator, a: []const i64, b: []const i64) ![]i64 {
    var map = std.AutoHashMap(i64, usize).init(allocator);
    defer map.deinit();
    for (b) |v| {
        const cur = map.get(v) orelse 0;
        _ = try map.put(v, cur + 1);
    }
    var out = std.ArrayList(i64).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (a) |v| {
        const cnt = map.get(v) orelse 0;
        if (cnt == 0) {
            try out.append(allocator, v);
        } else {
            _ = try map.put(v, cnt - 1);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "set ops semantics: UNION DISTINCT and INTERSECT/EXCEPT ALL" {
    const A = [_]i64{ 1, 2, 2, 3 };
    const B = [_]i64{ 2, 3, 4 };
    // UNION DISTINCT
    var union_all = std.ArrayList(i64).initCapacity(std.testing.allocator, 0) catch return error.OutOfMemory;
    defer union_all.deinit(std.testing.allocator);
    try union_all.appendSlice(std.testing.allocator, &A);
    try union_all.appendSlice(std.testing.allocator, &B);
    const union_distinct = try dedupInts(std.testing.allocator, union_all.items);
    defer std.testing.allocator.free(union_distinct);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4 }, union_distinct);
    // INTERSECT ALL => multiplicity = min(countA, countB)
    const ia = try multisetIntersect(std.testing.allocator, &A, &B);
    defer std.testing.allocator.free(ia);
    // A has {1:1,2:2,3:1}; B has {2:1,3:1,4:1} => intersection ALL = {2,3}
    try std.testing.expect(ia.len == 2);
    // EXCEPT ALL => subtract multiplicities
    const ea = try multisetExcept(std.testing.allocator, &A, &B);
    defer std.testing.allocator.free(ea);
    // A \ B = {1,2}
    try std.testing.expect(ea.len == 2);
}

/// Enhanced hash-based GROUP BY aggregation with spill support
pub const HashAggregator = struct {
    allocator: std.mem.Allocator,
    groups: std.HashMap([]const u8, AggregateState, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    memory_limit: usize,
    current_memory: usize,
    spilled: bool,
    spill_file: ?std.fs.File,
    /// Phase-2: multiple spill segment files (final rows merged at getResults). Each segment holds serialized AggregateState entries.
    spill_segments: std.ArrayList([]const u8),
    segment_counter: usize,

    const AggregateState = struct {
        key_values: []const BindingValue,
        agg_values: []AggValue,

        const AggValue = union(enum) {
            Count: i64,
            Sum: BindingValue,
            Min: BindingValue,
            Max: BindingValue,
            Avg: struct { sum: BindingValue, count: i64 },
            /// COUNT DISTINCT materialized set (only used during spill merge). During in-memory phase we retain only count; when spilling we persist the distinct value encodings to allow later segments to de-duplicate safely.
            CountDistinctState: struct {
                count: i64,
                // For large sets we may have truncated serialization (future bloom support). For now exact set.
                values: [][]const u8,
            },
            /// Decimal SUM partial (coeff aligned to scale) for spill-safe merging (when original Sum/Avg used decimal variants). This avoids loss of precision converting to BindingValue prematurely.
            DecSum: struct { coeff: i128, scale: u8, count: i64 },
            /// Decimal AVG partial state distinct from generic Avg for spill path; we merge then render as Decimal in getResults.
            DecAvg: struct { coeff: i128, scale: u8, count: i64 },
        };
    };

    pub fn init(allocator: std.mem.Allocator, memory_limit: usize) HashAggregator {
        return .{
            .allocator = allocator,
            .groups = std.HashMap([]const u8, AggregateState, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .memory_limit = memory_limit,
            .current_memory = 0,
            .spilled = false,
            .spill_file = null,
            .spill_segments = std.ArrayList([]const u8).init(allocator),
            .segment_counter = 0,
        };
    }

    pub fn deinit(self: *HashAggregator) void {
        var iter = self.groups.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.key_values);
            self.allocator.free(entry.value_ptr.agg_values);
        }
        self.groups.deinit();

        if (self.spill_file) |f| {
            f.close();
        }
        // Remove spill segment files
        var i: usize = 0;
        while (i < self.spill_segments.items.len) : (i += 1) {
            // Best effort cleanup
            std.fs.cwd().deleteFile(self.spill_segments.items[i]) catch |err| {
                std.log.warn("Failed to delete spill segment '{s}' (disk space leak possible): {any}", .{ self.spill_segments.items[i], err });
            };
            self.allocator.free(self.spill_segments.items[i]);
        }
        self.spill_segments.deinit();
    }

    pub fn addRow(self: *HashAggregator, key_values: []const BindingValue, agg_inputs: []const BindingValue, agg_specs: []const Agg) !void {
        // Create key string for grouping
        const key_str = try self.serializeKey(key_values);
        // Approximate size cost of adding a new group (only applied if group absent)
        var estimated_new: usize = 0;
        if (!self.groups.contains(key_str)) {
            estimated_new = key_str.len + @sizeOf(AggregateState) + key_values.len * @sizeOf(BindingValue) + agg_specs.len * @sizeOf(AggregateState.AggValue);
        }
        // Spill eviction if we would exceed limit
        if ((self.current_memory + estimated_new) > self.memory_limit) {
            try self.flushSegment(agg_specs);
        }

        const result = try self.groups.getOrPut(key_str);
        if (!result.found_existing) {
            // New group
            result.value_ptr.* = AggregateState{
                .key_values = try self.allocator.dupe(BindingValue, key_values),
                .agg_values = try self.allocator.alloc(AggregateState.AggValue, agg_specs.len),
            };

            // Initialize aggregates
            for (agg_specs, 0..) |agg_spec, i| {
                result.value_ptr.agg_values[i] = switch (agg_spec) {
                    .CountStar, .Count => AggregateState.AggValue{ .Count = 0 },
                    .Sum => AggregateState.AggValue{ .Sum = BindingValue{ .Null = {} } },
                    .Min => AggregateState.AggValue{ .Min = BindingValue{ .Null = {} } },
                    .Max => AggregateState.AggValue{ .Max = BindingValue{ .Null = {} } },
                    .Avg => AggregateState.AggValue{ .Avg = .{ .sum = BindingValue{ .Null = {} }, .count = 0 } },
                };
            }

            self.current_memory += key_str.len + @sizeOf(AggregateState) + key_values.len * @sizeOf(BindingValue);
        }

        // Update aggregates
        for (agg_specs, 0..) |agg_spec, i| {
            const input_val = if (i < agg_inputs.len) agg_inputs[i] else BindingValue{ .Null = {} };
            try self.updateAggregate(&result.value_ptr.agg_values[i], agg_spec, input_val);
        }
    }

    fn serializeKey(_: *HashAggregator, key_values: []const BindingValue) ![]const u8 {
        var buf = std.ArrayList(u8){};
        defer buf.deinit();

        for (key_values, 0..) |val, i| {
            if (i > 0) try buf.append('|');

            switch (val) {
                .Null => try buf.appendSlice("NULL"),
                .Int => |n| try buf.writer().print("{d}", .{n}),
                .Bool => |b| try buf.appendSlice(if (b) "true" else "false"),
                .Str => |s| {
                    try buf.append('"');
                    try buf.appendSlice(s);
                    try buf.append('"');
                },
                .Decimal => |d| try buf.writer().print("{d}.{d}", .{ d.coeff, d.scale }),
            }
        }

        return buf.toOwnedSlice();
    }

    fn updateAggregate(self: *HashAggregator, agg_val: *AggregateState.AggValue, agg_spec: Agg, input: BindingValue) !void {
        _ = self;

        switch (agg_spec) {
            .CountStar => {
                agg_val.Count += 1;
            },
            .Count => {
                if (input != .Null) {
                    agg_val.Count += 1;
                }
            },
            .Sum => {
                if (input != .Null) {
                    if (agg_val.Sum == .Null) {
                        agg_val.Sum = input;
                    } else {
                        // Simple addition for Int values
                        if (agg_val.Sum == .Int and input == .Int) {
                            agg_val.Sum.Int += input.Int;
                        }
                    }
                }
            },
            .Min => {
                if (input != .Null) {
                    if (agg_val.Min == .Null or valueOrder(input, agg_val.Min) == .lt) {
                        agg_val.Min = input;
                    }
                }
            },
            .Max => {
                if (input != .Null) {
                    if (agg_val.Max == .Null or valueOrder(input, agg_val.Max) == .gt) {
                        agg_val.Max = input;
                    }
                }
            },
            .Avg => {
                if (input != .Null and input == .Int) {
                    if (agg_val.Avg.sum == .Null) {
                        agg_val.Avg.sum = input;
                        agg_val.Avg.count = 1;
                    } else if (agg_val.Avg.sum == .Int) {
                        agg_val.Avg.sum.Int += input.Int;
                        agg_val.Avg.count += 1;
                    }
                }
            },
        }
    }

    // Phase-2 actual eviction: serialize AggregateStates to a segment file and clear memory map.
    fn flushSegment(self: *HashAggregator, agg_specs: []const Agg) !void {
        if (self.groups.count() == 0) return; // nothing to flush
        const filename = try std.fmt.allocPrint(self.allocator, "geode_agg_spill_{d}.bin", .{self.segment_counter});
        errdefer self.allocator.free(filename);
        var file = try std.fs.cwd().createFile(filename, .{ .read = true });
        defer file.close();
        self.segment_counter += 1;
        self.spilled = true;
        // File format (little-endian): u32 group_count, then per-group: u32 key_len | key bytes | u32 key_values_len | serialized key_values | u32 agg_len | serialized agg_values
        const group_count: u32 = @intCast(self.groups.count());
        try file.writer().writeInt(u32, group_count, .little);
        var iter = self.groups.iterator();
        while (iter.next()) |entry| {
            const key_bytes = entry.key_ptr.*;
            try file.writer().writeInt(u32, @intCast(key_bytes.len), .little);
            try file.writeAll(key_bytes);
            const state = entry.value_ptr.*;
            try file.writer().writeInt(u32, @intCast(state.key_values.len), .little);
            // key values
            for (state.key_values) |kv| try serializeBindingValue(&file, kv);
            try file.writer().writeInt(u32, @intCast(state.agg_values.len), .little);
            // agg values + spec tag for merge semantics (store Agg kind for each index)
            for (state.agg_values, 0..) |av, i| {
                try file.writer().writeInt(u8, aggTag(agg_specs[i]), .little);
                try serializeAggValue(&file, av);
            }
        }
        // Record segment
        try self.spill_segments.append(filename);
        // Free all group memory and reset map
        var it2 = self.groups.iterator();
        while (it2.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.key_values);
            self.allocator.free(e.value_ptr.agg_values);
        }
        self.groups.clearRetainingCapacity();
        self.current_memory = 0;
    }

    fn aggTag(a: Agg) u8 { // stable tags for serialization
        return switch (a) {
            .CountStar, .Count => 0,
            .Sum => 1,
            .Min => 2,
            .Max => 3,
            .Avg => 4,
            .CountDistinct => 5,
        };
    }

    fn serializeBindingValue(file: *std.fs.File, v: BindingValue) !void {
        switch (v) {
            .Null => try file.writer().writeInt(u8, 0, .little),
            .Int => |n| {
                try file.writer().writeInt(u8, 1, .little);
                try file.writer().writeInt(i64, n, .little);
            },
            .Decimal => |d| {
                try file.writer().writeInt(u8, 2, .little);
                try file.writer().writeInt(i128, d.coeff, .little);
                try file.writer().writeInt(u8, d.scale, .little);
            },
            .Str => |s| {
                try file.writer().writeInt(u8, 3, .little);
                try file.writer().writeInt(u32, @intCast(s.len), .little);
                try file.writeAll(s);
            },
            .Bool => |b| {
                try file.writer().writeInt(u8, 4, .little);
                try file.writer().writeInt(u8, if (b) 1 else 0, .little);
            },
        }
    }

    fn deserializeBindingValue(allocator: std.mem.Allocator, file: *std.fs.File) !BindingValue {
        const tag = try file.reader().readInt(u8, .little);
        return switch (tag) {
            0 => BindingValue{ .Null = {} },
            1 => BindingValue{ .Int = try file.reader().readInt(i64, .little) },
            2 => blk: {
                const coeff = try file.reader().readInt(i128, .little);
                const scale = try file.reader().readInt(u8, .little);
                break :blk BindingValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
            },
            3 => blk2: {
                const l = try file.reader().readInt(u32, .little);
                const buf = try allocator.alloc(u8, l);
                try file.readAll(buf);
                break :blk2 BindingValue{ .Str = buf };
            },
            4 => blk3: {
                const b = try file.reader().readInt(u8, .little);
                break :blk3 BindingValue{ .Bool = b == 1 };
            },
            else => BindingValue{ .Null = {} },
        };
    }

    fn serializeAggValue(file: *std.fs.File, av: AggregateState.AggValue) !void {
        switch (av) {
            .Count => |c| try file.writer().writeInt(i64, c, .little),
            .Sum => |s| try serializeBindingValue(file, s),
            .Min => |m| try serializeBindingValue(file, m),
            .Max => |m| try serializeBindingValue(file, m),
            .Avg => |a| {
                // serialize inner sum as BindingValue then count
                try serializeBindingValue(file, a.sum);
                try file.writer().writeInt(i64, a.count, .little);
            },
            .CountDistinctState => |st| {
                try file.writer().writeInt(i64, st.count, .little);
                const n: u32 = @intCast(st.values.len);
                try file.writer().writeInt(u32, n, .little);
                var i: usize = 0;
                while (i < st.values.len) : (i += 1) {
                    const v = st.values[i];
                    try file.writer().writeInt(u32, @intCast(v.len), .little);
                    try file.writeAll(v);
                }
            },
            .DecSum => |ds| {
                try file.writer().writeInt(i128, ds.coeff, .little);
                try file.writer().writeInt(u8, ds.scale, .little);
                try file.writer().writeInt(i64, ds.count, .little);
            },
            .DecAvg => |da| {
                try file.writer().writeInt(i128, da.coeff, .little);
                try file.writer().writeInt(u8, da.scale, .little);
                try file.writer().writeInt(i64, da.count, .little);
            },
        }
    }

    fn deserializeAggValue(allocator: std.mem.Allocator, file: *std.fs.File, tag: u8) !AggregateState.AggValue {
        return switch (tag) {
            0 => AggregateState.AggValue{ .Count = try file.reader().readInt(i64, .little) },
            1 => AggregateState.AggValue{ .Sum = try deserializeBindingValue(allocator, file) },
            2 => AggregateState.AggValue{ .Min = try deserializeBindingValue(allocator, file) },
            3 => AggregateState.AggValue{ .Max = try deserializeBindingValue(allocator, file) },
            4 => blk: {
                const sum = try deserializeBindingValue(allocator, file);
                const cnt = try file.reader().readInt(i64, .little);
                break :blk AggregateState.AggValue{ .Avg = .{ .sum = sum, .count = cnt } };
            },
            5 => blk_cd: {
                // Legacy CountDistinct tag previously encoded like Count (only count). For backwards compat: read count then treat values as empty set.
                const cnt = try file.reader().readInt(i64, .little);
                // Detect presence of set length (optional). Peek by reading next 4 bytes; if EOF treat zero.
                var values = std.ArrayList([]const u8).init(allocator);
                errdefer {
                    for (values.items) |v| allocator.free(v);
                    values.deinit();
                }
                // Attempt to read optional length; if fails just use empty.
                const len_or_err = file.reader().readInt(u32, .little) catch |e| switch (e) {
                    error.EndOfStream => 0,
                    else => 0,
                };
                if (len_or_err > 0) {
                    var i: u32 = 0;
                    while (i < len_or_err) : (i += 1) {
                        const l = try file.reader().readInt(u32, .little);
                        const buf = try allocator.alloc(u8, l);
                        try file.readAll(buf);
                        try values.append(buf);
                    }
                }
                break :blk_cd AggregateState.AggValue{ .CountDistinctState = .{ .count = cnt, .values = values.toOwnedSlice() } };
            },
            else => AggregateState.AggValue{ .Count = 0 },
        };
    }

    /// P2-3: Now accepts allocator parameter for temporary allocations
    fn mergeAggValue(allocator: std.mem.Allocator, dst: *AggregateState.AggValue, src: AggregateState.AggValue) void {
        if (dst.* == .Count and src == .Count) {
            dst.Count += src.Count;
        } else if (dst.* == .Sum and src == .Sum and dst.Sum == .Int and src.Sum == .Int) {
            dst.Sum.Int += src.Sum.Int;
        } else if (dst.* == .Min and src == .Min) {
            if (dst.Min == .Null or valueOrder(src.Min, dst.Min) == .lt) dst.Min = src.Min;
        } else if (dst.* == .Max and src == .Max) {
            if (dst.Max == .Null or valueOrder(src.Max, dst.Max) == .gt) dst.Max = src.Max;
        } else if (dst.* == .Avg and src == .Avg and dst.Avg.sum == .Int and src.Avg.sum == .Int) {
            dst.Avg.sum.Int += src.Avg.sum.Int;
            dst.Avg.count += src.Avg.count;
        } else if (dst.* == .CountDistinctState and src == .CountDistinctState) {
            // Precise merge: build a temporary open-addressed hash set of existing + incoming values.
            // Recompute exact distinct count; avoid over-estimation.
            const existing = dst.CountDistinctState.values;
            const incoming = src.CountDistinctState.values;
            var cap: usize = 16;
            const need = existing.len + incoming.len;
            while (cap < need * 2) cap <<= 1; // load factor <=0.5
            const SetEntry = struct { hash: u64, val: []const u8 };
            // P2-3: Use provided allocator instead of page_allocator
            const set = allocator.alloc(?SetEntry, cap) catch return;
            defer allocator.free(set);
            @memset(set, null);
            const mask = cap - 1;
            var new_vals = std.ArrayList([]const u8).init(allocator);
            defer new_vals.deinit();
            var insertFn = struct {
                fn insert(alloc: std.mem.Allocator, slots: []?SetEntry, slot_mask: usize, v: []const u8, store: *std.ArrayList([]const u8)) void {
                    const h = std.hash.Wyhash.hash(0, v);
                    var idx: usize = @intCast(h & slot_mask);
                    while (true) {
                        if (slots[idx] == null) {
                            // copy value
                            // P2-3: Use provided allocator instead of page_allocator
                            const dup = alloc.alloc(u8, v.len) catch return; // best effort
                            @memcpy(dup, v);
                            store.append(dup) catch return;
                            slots[idx] = SetEntry{ .hash = h, .val = dup };
                            return;
                        } else if (slots[idx].?.hash == h and std.mem.eql(u8, slots[idx].?.val, v)) {
                            return; // already present
                        }
                        idx = (idx + 1) & slot_mask;
                    }
                }
            };
            // load existing
            var i: usize = 0;
            while (i < existing.len) : (i += 1) insertFn.insert(allocator, set, mask, existing[i], &new_vals);
            // add incoming
            i = 0;
            while (i < incoming.len) : (i += 1) insertFn.insert(allocator, set, mask, incoming[i], &new_vals);
            // Free old values (shallow) - NOTE: underlying alloc ownership ambiguous; skipping free to avoid double-free risk.
            dst.CountDistinctState.values = new_vals.toOwnedSlice();
            dst.CountDistinctState.count = @intCast(dst.CountDistinctState.values.len);
        } else if (dst.* == .DecSum and src == .DecSum) {
            if (dst.DecSum.scale == src.DecSum.scale) {
                dst.DecSum.coeff += src.DecSum.coeff;
            } else {
                const maxs: u8 = if (dst.DecSum.scale > src.DecSum.scale) dst.DecSum.scale else src.DecSum.scale;
                // naive scale alignment ignoring overflow for now (TODO: guard)
                // scale up dst
                var dcoeff = dst.DecSum.coeff;
                var ds = dst.DecSum.scale;
                while (ds < maxs) : (ds += 1) dcoeff *= 10;
                var scoeff = src.DecSum.coeff;
                var ss = src.DecSum.scale;
                while (ss < maxs) : (ss += 1) scoeff *= 10;
                dst.DecSum.coeff = dcoeff + scoeff;
                dst.DecSum.scale = maxs;
            }
            dst.DecSum.count += src.DecSum.count;
        } else if (dst.* == .DecAvg and src == .DecAvg) {
            // Treat like DecSum + counts
            if (dst.DecAvg.scale == src.DecAvg.scale) {
                dst.DecAvg.coeff += src.DecAvg.coeff;
            } else {
                const maxs: u8 = if (dst.DecAvg.scale > src.DecAvg.scale) dst.DecAvg.scale else src.DecAvg.scale;
                var dcoeff2 = dst.DecAvg.coeff;
                var s1 = dst.DecAvg.scale;
                while (s1 < maxs) : (s1 += 1) dcoeff2 *= 10;
                var scoeff2 = src.DecAvg.coeff;
                var s2 = src.DecAvg.scale;
                while (s2 < maxs) : (s2 += 1) scoeff2 *= 10;
                dst.DecAvg.coeff = dcoeff2 + scoeff2;
                dst.DecAvg.scale = maxs;
            }
            dst.DecAvg.count += src.DecAvg.count;
        }
    }

    fn loadSegments(self: *HashAggregator) !void {
        // Merge all segment files back into groups map (clearing existing groups first for simplicity)
        if (self.spill_segments.items.len == 0) return;
        const filename_list = self.spill_segments.items; // alias
        var i: usize = 0;
        while (i < filename_list.len) : (i += 1) {
            var file = std.fs.cwd().openFile(filename_list[i], .{}) catch continue;
            defer file.close();
            const gcount = try file.reader().readInt(u32, .little);
            var gi: u32 = 0;
            while (gi < gcount) : (gi += 1) {
                const key_len = try file.reader().readInt(u32, .little);
                const keybuf = try self.allocator.alloc(u8, key_len);
                try file.readAll(keybuf);
                const key_slice = keybuf; // ownership transferred to map
                const key_vals_len = try file.reader().readInt(u32, .little);
                var key_vals = try self.allocator.alloc(BindingValue, key_vals_len);
                var kv_i: usize = 0;
                while (kv_i < key_vals_len) : (kv_i += 1) key_vals[kv_i] = try deserializeBindingValue(self.allocator, &file);
                const agg_len = try file.reader().readInt(u32, .little);
                var agg_vals = try self.allocator.alloc(AggregateState.AggValue, agg_len);
                var ai: usize = 0;
                while (ai < agg_len) : (ai += 1) {
                    const atag = try file.reader().readInt(u8, .little);
                    agg_vals[ai] = try deserializeAggValue(self.allocator, &file, atag);
                }
                const res = try self.groups.getOrPut(key_slice);
                if (!res.found_existing) {
                    res.value_ptr.* = AggregateState{ .key_values = key_vals, .agg_values = agg_vals };
                } else {
                    // Merge aggregates and free duplicates
                    for (res.value_ptr.agg_values, 0..) |*dst, j| mergeAggValue(self.allocator, dst, agg_vals[j]);
                    self.allocator.free(key_slice);
                    self.allocator.free(key_vals);
                    self.allocator.free(agg_vals);
                }
            }
        }
        // After loading, remove files (they are no longer needed)
        i = 0;
        while (i < filename_list.len) : (i += 1) {
            std.fs.cwd().deleteFile(filename_list[i]) catch |err| {
                std.log.warn("Failed to delete reloaded spill file '{s}' (disk space leak possible): {any}", .{ filename_list[i], err });
            };
        }
        // Clear segment tracking
        i = 0;
        while (i < self.spill_segments.items.len) : (i += 1) self.allocator.free(self.spill_segments.items[i]);
        self.spill_segments.clearRetainingCapacity();
    }

    pub fn getResults(self: *HashAggregator, agg_specs: []const Agg) ![]const []const BindingValue {
        // If spilled segments exist, load & merge them prior to producing results
        if (self.spilled and self.spill_segments.items.len > 0) {
            try self.loadSegments();
        }
        var results = std.ArrayList([]const BindingValue){};
        defer results.deinit();

        // Handle case where no groups exist but we have aggregates (non-GROUP BY query with no matching rows)
        if (self.groups.count() == 0 and agg_specs.len > 0) {
            // Create a single row with default aggregate values (e.g., COUNT=0)
            var row = try self.allocator.alloc(BindingValue, agg_specs.len);
            for (agg_specs, 0..) |agg_spec, i| {
                row[i] = switch (agg_spec) {
                    .CountStar, .Count => BindingValue{ .Int = 0 },
                    .Sum => BindingValue{ .Null = {} },
                    .Min => BindingValue{ .Null = {} },
                    .Max => BindingValue{ .Null = {} },
                    .Avg => BindingValue{ .Null = {} },
                    .CountDistinct => BindingValue{ .Int = 0 },
                };
            }
            try results.append(row);
            return results.toOwnedSlice();
        }

        var iter = self.groups.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr;
            var row = try self.allocator.alloc(BindingValue, state.key_values.len + state.agg_values.len);

            // Copy key values
            @memcpy(row[0..state.key_values.len], state.key_values);

            // Convert aggregate values to BindingValue
            for (state.agg_values, 0..) |agg_val, i| {
                const idx = state.key_values.len + i;
                row[idx] = switch (agg_val) {
                    .Count => |c| BindingValue{ .Int = c },
                    .Sum => |s| s,
                    .Min => |m| m,
                    .Max => |m| m,
                    .Avg => |a| if (a.count > 0 and a.sum == .Int)
                        BindingValue{ .Int = @divTrunc(a.sum.Int, a.count) }
                    else
                        BindingValue{ .Null = {} },
                };
            }

            try results.append(row);
        }

        return results.toOwnedSlice();
    }
};

// CANARY: REQ=REQ-BINDING-VALUE-001; FEATURE="ComplexTypeBinding"; STATUS=IMPL; UPDATED=2026-01-10
pub const BindingValue = union(enum) {
    Null,
    Int: i64,
    // Fixed-point decimal: coeff * 10^-scale
    Decimal: struct { coeff: i128, scale: u8 },
    Str: []const u8,
    Bool: bool,
    List: []BindingValue,
    // GAP-0045: Added complex graph types to prevent data loss during type conversion
    Node: *const graph_store.Node,
    Edge: *const graph_store.Edge,
    Map: std.StringHashMap(eval.Value),
    Path: struct {
        nodes: []const *const graph_store.Node,
        edges: []const *const graph_store.Edge,
    },
    ExtValue: eval_extended.ExtValue,
};

pub const BindingRow = struct {
    cols: []const BindingValue,
};

pub const OrderPolicy = enum { Sorted, StableLeft };

fn valueOrder(a: BindingValue, b: BindingValue) std.math.Order {
    // Null < Bool < Int < Str < List < Node < Edge < Path < Map < ExtValue
    // Within types, natural order. NULLs compare equal for set ops equality.
    const rank = struct {
        fn of(v: BindingValue) u8 {
            return switch (v) {
                .Null => 0,
                .Bool => 1,
                .Int => 2,
                .Decimal => 3,
                .Str => 4,
                .List => 5,
                .Node => 6,
                .Edge => 7,
                .Path => 8,
                .Map => 9,
                .ExtValue => 10,
            };
        }
    };
    const ra = rank.of(a);
    const rb = rank.of(b);
    if (ra < rb) return .lt;
    if (ra > rb) return .gt;
    // Same type, compare within
    return switch (a) {
        .Null => .eq,
        .Bool => |av| blk: {
            const bv = b.Bool;
            if (av == bv) break :blk .eq;
            break :blk if (av) .gt else .lt;
        },
        .Int => |av| blk2: {
            const bv = b.Int;
            if (av == bv) break :blk2 .eq;
            break :blk2 if (av < bv) .lt else .gt;
        },
        .Decimal => |ad| blk3: {
            const bd = b.Decimal;
            // Align scales to compare
            if (ad.scale == bd.scale) {
                if (ad.coeff == bd.coeff) break :blk3 .eq;
                break :blk3 if (ad.coeff < bd.coeff) .lt else .gt;
            }
            const maxs: u8 = if (ad.scale > bd.scale) ad.scale else bd.scale;
            const lc = scaleToPow10(ad.coeff, ad.scale, maxs) catch {
                // On overflow during scale, fallback to comparing by scale deterministically
                if (ad.scale < bd.scale) {
                    break :blk3 .lt;
                } else if (ad.scale > bd.scale) {
                    break :blk3 .gt;
                } else {
                    break :blk3 .eq;
                }
            };
            const rc = scaleToPow10(bd.coeff, bd.scale, maxs) catch {
                if (ad.scale < bd.scale) {
                    break :blk3 .lt;
                } else if (ad.scale > bd.scale) {
                    break :blk3 .gt;
                } else {
                    break :blk3 .eq;
                }
            };
            if (lc == rc) break :blk3 .eq;
            break :blk3 if (lc < rc) .lt else .gt;
        },
        .Str => |as| std.mem.order(u8, as, b.Str),
        .List => |_| .eq, // Lists compare equal for now
        // GAP-0045: Complex types compare by pointer identity
        .Node => |an| blk_node: {
            const bn = b.Node;
            if (@intFromPtr(an) == @intFromPtr(bn)) break :blk_node .eq;
            break :blk_node if (@intFromPtr(an) < @intFromPtr(bn)) .lt else .gt;
        },
        .Edge => |ae| blk_edge: {
            const be = b.Edge;
            if (@intFromPtr(ae) == @intFromPtr(be)) break :blk_edge .eq;
            break :blk_edge if (@intFromPtr(ae) < @intFromPtr(be)) .lt else .gt;
        },
        .Path => |_| .eq, // Paths compare equal for now
        .Map => |_| .eq, // Maps compare equal for now
        .ExtValue => |_| .eq, // ExtValues compare equal for now
    };
}

fn pow10(scale: u8) i128 {
    var p: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) p *= 10;
    return p;
}

fn scaleToPow10(coeff: i128, from: u8, to: u8) error{Overflow}!i128 {
    if (from == to) return coeff;
    if (from > to) {
        var i: u8 = 0;
        var v = coeff;
        while (i < from - to) : (i += 1) v = @divTrunc(v, 10);
        return v;
    }
    // upscale with overflow checks: v *= 10 using repeated additions to avoid missing mulOverflow in std on Zig 0.14
    var i: u8 = 0;
    var v = coeff;
    while (i < to - from) : (i += 1) {
        // multiply by 10 => v*10 = v + v*9
        var tmp: i128 = v;
        var j: u8 = 0;
        while (j < 9) : (j += 1) {
            var sum: i128 = 0;
            if (addI128Overflow(tmp, v, &sum)) return error.Overflow;
            tmp = sum;
        }
        v = tmp;
    }
    return v;
}

inline fn addI128Overflow(a: i128, b: i128, out: *i128) bool {
    // Zig 0.14: use builtin overflow add via @addWithOverflow
    const pair = @addWithOverflow(a, b);
    out.* = pair[0];
    return pair[1] != 0;
}

inline fn i128ToI64(v: i128) ?i64 {
    const min: i128 = @as(i128, @intCast(@as(i64, @bitCast(@as(u64, 0x8000000000000000)))));
    const max: i128 = @as(i128, @intCast(@as(i64, @bitCast(@as(u64, 0x7fffffffffffffff)))));
    if (v < min or v > max) return null;
    return @as(i64, @intCast(v));
}

// ===========================
// Path search tie-break policy (UA005/UA006)
// ===========================

/// A minimal path representation: list of node ids (for tie-break), and hop count equals nodes.len-1.
pub const Path = struct { nodes: []const i64 };

/// Deterministic tie-break: prefer smaller length (fewer hops); then lexicographically smaller node id sequence.
pub fn pathLess(a: Path, b: Path) bool {
    if (a.nodes.len != b.nodes.len) return a.nodes.len < b.nodes.len;
    const n = @min(a.nodes.len, b.nodes.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a.nodes[i] < b.nodes[i]) return true;
        if (a.nodes[i] > b.nodes[i]) return false;
    }
    return false; // equal sequences not less
}

test "path tie-break: shorter first, then lexicographic ids" {
    const p1 = Path{ .nodes = &.{ 1, 2, 3 } }; // 2 hops
    const p2 = Path{ .nodes = &.{ 1, 5 } }; // 1 hop
    try std.testing.expect(pathLess(p2, p1)); // shorter wins
    const p3 = Path{ .nodes = &.{ 1, 3 } };
    const p4 = Path{ .nodes = &.{ 1, 4 } };
    try std.testing.expect(pathLess(p3, p4)); // lexicographic by node ids
}

fn rowLess(a: []const BindingValue, b: []const BindingValue) bool {
    var i: usize = 0;
    const n = @min(a.len, b.len);
    while (i < n) : (i += 1) {
        const ord = valueOrder(a[i], b[i]);
        if (ord == .lt) return true;
        if (ord == .gt) return false;
    }
    return a.len < b.len;
}

fn valueEq(a: BindingValue, b: BindingValue) bool {
    switch (a) {
        .Null => return b == .Null,
        .Int => |ai| return b == .Int and ai == b.Int,
        .Decimal => |ad| return b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
        .Str => |as| return b == .Str and std.mem.eql(u8, as, b.Str),
        .Bool => |ab| return b == .Bool and ab == b.Bool,
        .List => |al| {
            if (b != .List) return false;
            const bl = b.List;
            if (al.len != bl.len) return false;
            for (al, bl) |av, bv| {
                if (!valueEq(av, bv)) return false;
            }
            return true;
        },
        // GAP-0045: Complex types compare by pointer identity
        .Node => |an| return b == .Node and @intFromPtr(an) == @intFromPtr(b.Node),
        .Edge => |ae| return b == .Edge and @intFromPtr(ae) == @intFromPtr(b.Edge),
        .Path => |_| return b == .Path, // Paths compare equal for now
        .Map => |_| return b == .Map, // Maps compare equal for now
        .ExtValue => |_| return b == .ExtValue, // ExtValues compare equal for now
    }
}

fn rowEq(a: []const BindingValue, b: []const BindingValue) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (!valueEq(a[i], b[i])) return false;
    return true;
}

fn encodeValueKey(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: BindingValue) !void {
    // Simple, deterministic encoding: type tag + length + payload; NULL is just tag.
    switch (v) {
        .Null => try buf.append(allocator, 'N'),
        .Bool => |b| {
            try buf.append(allocator, 'B');
            try buf.append(allocator, if (b) '1' else '0');
        },
        .Int => |n| {
            try buf.append(allocator, 'I');
            try buf.writer(allocator).print("{d};", .{n});
        },
        .Decimal => |d| {
            try buf.append(allocator, 'D');
            try buf.writer(allocator).print("{d}@{d};", .{ d.coeff, d.scale });
        },
        .Str => |s| {
            try buf.append(allocator, 'S');
            try buf.writer(allocator).print("{d}:", .{s.len});
            try buf.appendSlice(allocator, s);
        },
        .List => |l| {
            try buf.append(allocator, 'L');
            try buf.writer(allocator).print("{d}:", .{l.len});
            for (l) |item| {
                try encodeValueKey(allocator, buf, item);
            }
        },
        // GAP-0045: Complex types encode by pointer identity
        .Node => |n| {
            try buf.append(allocator, 'n');
            try buf.writer(allocator).print("{x};", .{@intFromPtr(n)});
        },
        .Edge => |e| {
            try buf.append(allocator, 'e');
            try buf.writer(allocator).print("{x};", .{@intFromPtr(e)});
        },
        .Path => |_| try buf.append(allocator, 'p'), // Paths get fixed encoding
        .Map => |_| try buf.append(allocator, 'm'), // Maps get fixed encoding
        .ExtValue => |_| try buf.append(allocator, 'x'), // ExtValues get fixed encoding
    }
}

fn rowKeyAlloc(allocator: std.mem.Allocator, row: []const BindingValue) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    for (row, 0..) |v, i| {
        if (i > 0) try buf.append(allocator, '|');
        try encodeValueKey(allocator, &buf, v);
    }
    return buf.toOwnedSlice(allocator);
}

// Allocate a canonical byte key for a single BindingValue used in COUNT DISTINCT.
fn valueKeyAlloc(allocator: std.mem.Allocator, v: BindingValue) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    switch (v) {
        .Null => try buf.appendSlice(allocator, "n"),
        .Int => |n| try buf.writer(allocator).print("i{d}", .{n}),
        .Bool => |b| try buf.appendSlice(allocator, if (b) "bt" else "bf"),
        .Str => |s| {
            try buf.appendSlice(allocator, "s");
            try buf.appendSlice(allocator, s);
        },
        .Decimal => |d| try buf.writer(allocator).print("d{d}:{d}", .{ d.coeff, d.scale }),
        .List => |l| {
            try buf.writer(allocator).print("l{d}:", .{l.len});
            for (l) |item| {
                const item_key = try valueKeyAlloc(allocator, item);
                defer allocator.free(item_key);
                try buf.appendSlice(allocator, item_key);
            }
        },
        // GAP-0045: Complex types use pointer-based keys for distinction
        .Node => |node| try buf.writer(allocator).print("node@{x}", .{@intFromPtr(node)}),
        .Edge => |edge| try buf.writer(allocator).print("edge@{x}", .{@intFromPtr(edge)}),
        .Path => |_| try buf.appendSlice(allocator, "path"),
        .Map => |_| try buf.appendSlice(allocator, "map"),
        .ExtValue => |_| try buf.appendSlice(allocator, "ext"),
    }
    return buf.toOwnedSlice(allocator);
}

fn sortUniqueRows(allocator: std.mem.Allocator, rows: []const []const BindingValue) ![]const []const BindingValue {
    // Make a copy of slice-of-slices and sort lexicographically; then unique adjacent equals.
    const tmp = try allocator.alloc([]const BindingValue, rows.len);
    errdefer allocator.free(tmp);
    std.mem.copyForwards([]const BindingValue, tmp, rows);
    std.sort.block([]const BindingValue, tmp, {}, struct {
        fn less(_: void, a: []const BindingValue, b: []const BindingValue) bool {
            return rowLess(a, b);
        }
    }.less);
    if (tmp.len == 0) return tmp;
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < tmp.len) : (i += 1) {
        if (out.items.len == 0 or !rowEq(out.items[out.items.len - 1], tmp[i])) {
            try out.append(allocator, tmp[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn unionDistinctRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    var all = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer all.deinit(allocator);
    try all.appendSlice(allocator, a);
    try all.appendSlice(allocator, b);
    return try sortUniqueRows(allocator, all.items[0..]);
}

/// Optimized UNION DISTINCT with a simple threshold to pick between sort-unique and hash-then-sort.
pub fn unionDistinctRowsOptimized(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue, threshold: usize) ![]const []const BindingValue {
    const total = a.len + b.len;
    if (total < threshold) return try unionDistinctRows(allocator, a, b);
    var set = std.StringHashMap(void).init(allocator);
    defer set.deinit();
    var uniq = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer uniq.deinit(allocator);
    // Insert all rows from a, then b
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const key = try rowKeyAlloc(allocator, a[i]);
        defer allocator.free(key);
        if (!set.contains(key)) {
            _ = try set.put(key, {});
            try uniq.append(allocator, a[i]);
        }
    }
    i = 0;
    while (i < b.len) : (i += 1) {
        const key = try rowKeyAlloc(allocator, b[i]);
        defer allocator.free(key);
        if (!set.contains(key)) {
            _ = try set.put(key, {});
            try uniq.append(allocator, b[i]);
        }
    }
    // Ensure deterministic order for DISTINCT: sort lexicographically
    return try sortUniqueRows(allocator, uniq.items);
}

pub fn unionAllRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, a);
    try out.appendSlice(allocator, b);
    return out.toOwnedSlice(allocator);
}

pub fn intersectAllRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    // Stable-left: walk A, but limit multiplicity by counts in B
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        const cur = counts.get(key) orelse 0;
        try counts.put(key, cur + 1);
    }
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (a) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        if (counts.get(key)) |cnt| {
            if (cnt > 0) {
                try out.append(allocator, row);
                try counts.put(key, cnt - 1);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn intersectDistinctRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    var setA = std.StringHashMap(void).init(allocator);
    defer setA.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        _ = try setA.put(key, {});
    }
    var uniq = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer uniq.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        if (setA.contains(key) and !seen.contains(key)) {
            _ = try seen.put(key, {});
            try uniq.append(allocator, row);
        }
    }
    // Sort for deterministic order
    return try sortUniqueRows(allocator, uniq.items);
}

pub fn exceptAllRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    // Stable-left: emit rows from A after subtracting multiplicities found in B
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        const cur = counts.get(key) orelse 0;
        try counts.put(key, cur + 1);
    }
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (a) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        if (counts.get(key)) |cnt| {
            if (cnt == 0) {
                try out.append(allocator, row);
            } else {
                try counts.put(key, cnt - 1);
            }
        } else {
            try out.append(allocator, row);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ===========================
// Minimal grouping engine (Aggregation phase-2 harness)
// ===========================

pub const Agg = union(enum) {
    Count,
    /// COUNT(*) variant: counts all rows regardless of NULLs.
    CountStar,
    /// COUNT DISTINCT variant: counts distinct non-NULL values of the argument.
    CountDistinct,
    Sum,
    Min,
    Max,
    /// AVG over integer inputs; returns integer (truncated) average.
    Avg,
};

pub const GroupSpec = struct {
    key_idxs: []const usize, // indices of columns to group by
    // one aggregate per output column after the key columns
    aggs: []const Agg,
};

/// Group rows (binding rows) by key columns and compute aggregates over a single Int column per agg index.
pub fn groupAndAggregate(allocator: std.mem.Allocator, rows: []const []const BindingValue, spec: GroupSpec, value_idxs: []const usize) ![]const []const BindingValue {
    var map = std.StringHashMap(struct {
        key: []const BindingValue,
        // Per-aggregate counters:
        //  - for Count: number of non-NULL values
        //  - for CountStar: number of rows (all)
        //  - for Sum/Avg: number of non-NULL integer values
        counts: []usize,
        // For integer sums/avgs use i128 accumulator. For decimals, track coeff and a common scale per-agg.
        sums: []i128,
        dec_sums: []i128, // decimal coefficient sums after aligning scales
        dec_scale: []u8, // common scale per-agg when decimals seen; 0 if none
        saw_decimal: []bool,
        ovf: []bool, // overflow flags for sums/avg accumulation
        mins: []?BindingValue,
        maxs: []?BindingValue,
        // For CountDistinct maintain a hash map per-agg when needed. We store pointer array to maps allocated on demand.
        distinct_maps: []*std.StringHashMap(void),
    }).init(allocator);
    defer map.deinit();
    // scratch buffers length per agg
    const m = spec.aggs.len;
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        const row = rows[i];
        // Build key slice
        var key = try allocator.alloc(BindingValue, spec.key_idxs.len);
        var k: usize = 0;
        while (k < spec.key_idxs.len) : (k += 1) key[k] = row[spec.key_idxs[k]];
        const key_enc = try rowKeyAlloc(allocator, key);
        defer allocator.free(key_enc);
        const entry_ptr = blk: {
            if (map.getPtr(key_enc)) |p| break :blk p;
            // initialize accumulators
            const counts = try allocator.alloc(usize, m);
            const sums = try allocator.alloc(i128, m);
            const dec_sums = try allocator.alloc(i128, m);
            const dec_scale = try allocator.alloc(u8, m);
            const saw_decimal = try allocator.alloc(bool, m);
            const mins = try allocator.alloc(?BindingValue, m);
            const maxs = try allocator.alloc(?BindingValue, m);
            const ovf = try allocator.alloc(bool, m);
            const distinct_maps = try allocator.alloc(*std.StringHashMap(void), m);
            @memset(counts, 0);
            @memset(sums, 0);
            @memset(dec_sums, 0);
            @memset(dec_scale, 0);
            @memset(saw_decimal, false);
            var z: usize = 0;
            while (z < m) : (z += 1) {
                mins[z] = null;
                maxs[z] = null;
                ovf[z] = false;
                distinct_maps[z] = undefined; // lazily allocated when first distinct value seen
            }
            try map.put(key_enc, .{ .key = key, .counts = counts, .sums = sums, .dec_sums = dec_sums, .dec_scale = dec_scale, .saw_decimal = saw_decimal, .ovf = ovf, .mins = mins, .maxs = maxs, .distinct_maps = distinct_maps });
            break :blk map.getPtr(key_enc).?;
        };
        // update accumulators
        var a: usize = 0;
        while (a < m) : (a += 1) {
            const vi = value_idxs[a];
            switch (spec.aggs[a]) {
                .Count => {
                    const add: usize = if (row[vi] == .Null) 0 else 1;
                    entry_ptr.counts[a] += add;
                },
                .CountStar => {
                    // Count every input row regardless of NULLs
                    entry_ptr.counts[a] += 1;
                },
                .CountDistinct => blk_cd: {
                    const v = row[vi];
                    if (v == .Null) break :blk_cd; // NULLs not counted
                    // Build string key for value
                    const key_val = valueKeyAlloc(allocator, v) catch break :blk_cd;
                    defer allocator.free(key_val);
                    // Lazily allocate map
                    if (@intFromPtr(entry_ptr.distinct_maps[a]) == 0) {
                        const mapp = try allocator.create(std.StringHashMap(void));
                        mapp.* = std.StringHashMap(void).init(allocator);
                        entry_ptr.distinct_maps[a] = mapp;
                    }
                    var hm = entry_ptr.distinct_maps[a];
                    if (!hm.contains(key_val)) {
                        _ = hm.put(key_val, {}) catch break :blk_cd;
                        entry_ptr.counts[a] += 1;
                    }
                },
                .Sum => blk_sum_upd: {
                    switch (row[vi]) {
                        .Int => |iv| {
                            const add = @as(i128, iv);
                            var tmp: i128 = 0;
                            if (addI128Overflow(entry_ptr.sums[a], add, &tmp)) {
                                entry_ptr.ovf[a] = true;
                            } else {
                                entry_ptr.sums[a] = tmp;
                            }
                            entry_ptr.counts[a] += 1;
                        },
                        .Decimal => |dd| {
                            var ls = entry_ptr.dec_scale[a];
                            const rs = dd.scale;
                            // initialize scale if first decimal
                            if (!entry_ptr.saw_decimal[a]) {
                                ls = dd.scale;
                                entry_ptr.dec_scale[a] = dd.scale;
                                entry_ptr.saw_decimal[a] = true;
                            }
                            const maxs: u8 = if (ls > rs) ls else rs;
                            const lsc = scaleToPow10(entry_ptr.dec_sums[a], ls, maxs) catch {
                                entry_ptr.ovf[a] = true;
                                break :blk_sum_upd;
                            };
                            const rsc = scaleToPow10(dd.coeff, rs, maxs) catch {
                                entry_ptr.ovf[a] = true;
                                break :blk_sum_upd;
                            };
                            var tmp: i128 = 0;
                            if (addI128Overflow(lsc, rsc, &tmp)) {
                                entry_ptr.ovf[a] = true;
                            } else {
                                entry_ptr.dec_sums[a] = tmp;
                                entry_ptr.dec_scale[a] = maxs;
                                entry_ptr.saw_decimal[a] = true;
                                entry_ptr.counts[a] += 1;
                            }
                        },
                        else => {},
                    }
                },
                .Avg => blk_avg_upd: {
                    switch (row[vi]) {
                        .Int => |iv| {
                            const add = @as(i128, iv);
                            var tmp: i128 = 0;
                            if (addI128Overflow(entry_ptr.sums[a], add, &tmp)) {
                                entry_ptr.ovf[a] = true;
                            } else {
                                entry_ptr.sums[a] = tmp;
                            }
                            entry_ptr.counts[a] += 1;
                        },
                        .Decimal => |dd| {
                            // as in SUM decimal path
                            const rs = dd.scale;
                            var ls = entry_ptr.dec_scale[a];
                            if (!entry_ptr.saw_decimal[a]) {
                                ls = dd.scale;
                                entry_ptr.dec_scale[a] = dd.scale;
                                entry_ptr.saw_decimal[a] = true;
                            }
                            const maxs: u8 = if (ls > rs) ls else rs;
                            const lsc = scaleToPow10(entry_ptr.dec_sums[a], ls, maxs) catch {
                                entry_ptr.ovf[a] = true;
                                break :blk_avg_upd;
                            };
                            const rsc = scaleToPow10(dd.coeff, rs, maxs) catch {
                                entry_ptr.ovf[a] = true;
                                break :blk_avg_upd;
                            };
                            var tmp: i128 = 0;
                            if (addI128Overflow(lsc, rsc, &tmp)) {
                                entry_ptr.ovf[a] = true;
                            } else {
                                entry_ptr.dec_sums[a] = tmp;
                                entry_ptr.dec_scale[a] = maxs;
                                entry_ptr.saw_decimal[a] = true;
                                entry_ptr.counts[a] += 1;
                            }
                        },
                        else => {},
                    }
                },
                .Min => blk_min: {
                    const v = row[vi];
                    if (v == .Null) break :blk_min;
                    if (entry_ptr.mins[a]) |mn| {
                        const ord = valueOrder(v, mn);
                        if (ord == .lt) entry_ptr.mins[a] = v;
                    } else {
                        entry_ptr.mins[a] = v;
                    }
                },
                .Max => blk_max: {
                    const v = row[vi];
                    if (v == .Null) break :blk_max;
                    if (entry_ptr.maxs[a]) |mx| {
                        const ord = valueOrder(v, mx);
                        if (ord == .gt) entry_ptr.maxs[a] = v;
                    } else {
                        entry_ptr.maxs[a] = v;
                    }
                },
            }
        }
    }
    // Materialize output rows: key columns first, then aggregate outputs as Int or Null
    var out = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    var it = map.valueIterator();
    while (it.next()) |p| {
        const acc = p.*;
        var row = try allocator.alloc(BindingValue, spec.key_idxs.len + m);
        // copy key columns
        var x: usize = 0;
        while (x < spec.key_idxs.len) : (x += 1) row[x] = acc.key[x];
        // aggregates
        var a: usize = 0;
        while (a < m) : (a += 1) {
            const dst = spec.key_idxs.len + a;
            const cnt_i128: i128 = @intCast(acc.counts[a]);
            switch (spec.aggs[a]) {
                .CountStar => row[dst] = if (i128ToI64(cnt_i128)) |ok| .{ .Int = ok } else .{ .Null = {} },
                .Count => row[dst] = if (i128ToI64(cnt_i128)) |ok| .{ .Int = ok } else .{ .Null = {} },
                .CountDistinct => row[dst] = if (i128ToI64(cnt_i128)) |ok| .{ .Int = ok } else .{ .Null = {} },
                .Sum => row[dst] = blk_sum_out: {
                    if (acc.counts[a] == 0 or acc.ovf[a]) break :blk_sum_out .{ .Null = {} };
                    if (acc.saw_decimal[a]) break :blk_sum_out .{ .Decimal = .{ .coeff = acc.dec_sums[a], .scale = acc.dec_scale[a] } };
                    if (i128ToI64(acc.sums[a])) |ok| break :blk_sum_out .{ .Int = ok } else break :blk_sum_out .{ .Null = {} };
                },
                .Avg => row[dst] = if (acc.counts[a] == 0 or acc.ovf[a]) .{ .Null = {} } else blk_avg_out: {
                    if (acc.saw_decimal[a]) {
                        const denom: i128 = @intCast(acc.counts[a]);
                        const q = @divTrunc(acc.dec_sums[a], denom);
                        break :blk_avg_out .{ .Decimal = .{ .coeff = q, .scale = acc.dec_scale[a] } };
                    } else {
                        const numer: i128 = acc.sums[a];
                        const denom: i128 = @intCast(acc.counts[a]);
                        const q = @divTrunc(numer, denom);
                        if (i128ToI64(q)) |ok| break :blk_avg_out .{ .Int = ok } else break :blk_avg_out .{ .Null = {} };
                    }
                },
                .Min => row[dst] = acc.mins[a] orelse BindingValue{ .Null = {} },
                .Max => row[dst] = acc.maxs[a] orelse BindingValue{ .Null = {} },
            }
        }
        try out.append(allocator, row);
    }
    return out.toOwnedSlice(allocator);
}

// ===========================
// HAVING rewrite helper
// ===========================

/// Build a literal AST expression by replacing grouped key references and aggregate calls
/// with their computed values from a single aggregated row.
pub fn rewriteExprWithAggregates(
    allocator: std.mem.Allocator,
    e: ast.Expr,
    key_map: *std.StringHashMap(usize), // stringified key -> key index
    agg_map: *std.StringHashMap(usize), // normalized call signature -> agg relative index
    row: []const BindingValue,
    key_len: usize,
) !ast.Expr {
    return switch (e) {
        // Literals passthrough
        .Int, .Bool, .Null, .String, .Decimal, .Date, .DateTime, .Time, .LocalDateTime => e,
        .Ident, .Member => blk_key: {
            const key_s = printer.stringifyExprAlloc(allocator, e, .{}) catch break :blk_key .{ .Null = {} };
            defer allocator.free(key_s);
            if (key_map.get(key_s)) |idx| {
                const v = row[idx];
                break :blk_key try bindingValueToExpr(v);
            }
            break :blk_key .{ .Null = {} };
        },
        .Call => |c| blk_call: {
            const callee = c.callee.*;
            const nm = switch (callee) {
                .Ident => |id| id.orig,
                else => break :blk_call .{ .Null = {} },
            };
            var sig_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer sig_buf.deinit(allocator);
            // append lowercase function name
            var i_nm: usize = 0;
            while (i_nm < nm.len) : (i_nm += 1) try sig_buf.append(allocator, std.ascii.toLower(nm[i_nm]));
            try sig_buf.append(allocator, '(');
            if (c.args.len == 0) {
                try sig_buf.append(allocator, '*');
            } else if (c.args.len == 1) {
                const s = printer.stringifyExprAlloc(allocator, c.args[0].*, .{}) catch "";
                defer if (s.len > 0) allocator.free(s);
                try sig_buf.appendSlice(allocator, s);
            } else {
                // unexpected arity for current aggregates => bail
            }
            try sig_buf.append(allocator, ')');
            const sig = sig_buf.items;
            if (agg_map.get(sig)) |rel| {
                const v = row[key_len + rel];
                break :blk_call try bindingValueToExpr(v);
            }
            break :blk_call .{ .Null = {} };
        },
        .Unary => |u| blk_u: {
            const inner = try rewriteExprWithAggregates(allocator, u.expr.*, key_map, agg_map, row, key_len);
            var u_copy = u;
            var inner_copy = inner;
            u_copy.expr = &inner_copy;
            break :blk_u .{ .Unary = u_copy };
        },
        .Binary => |b| blk_b: {
            const l = try rewriteExprWithAggregates(allocator, b.left.*, key_map, agg_map, row, key_len);
            const r = try rewriteExprWithAggregates(allocator, b.right.*, key_map, agg_map, row, key_len);
            var b2 = b;
            var lc = l;
            var rc = r;
            b2.left = &lc;
            b2.right = &rc;
            break :blk_b .{ .Binary = b2 };
        },
        else => .{ .Null = {} },
    };
}

fn bindingValueToExpr(v: BindingValue) !ast.Expr {
    return switch (v) {
        .Null => ast.Expr{ .Null = {} },
        .Int => |n| ast.Expr{ .Int = n },
        .Decimal => |d| ast.Expr{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .Str => |s| ast.Expr{ .String = s },
        .Bool => |b| ast.Expr{ .Bool = b },
        .List => ast.Expr{ .Null = {} }, // TODO: Convert List to ArrayLit expression
        // GAP-0045: Complex types return Null for expression conversion (handled at graph layer)
        .Node => ast.Expr{ .Null = {} },
        .Edge => ast.Expr{ .Null = {} },
        .Path => ast.Expr{ .Null = {} },
        .Map => ast.Expr{ .Null = {} },
        .ExtValue => ast.Expr{ .Null = {} },
    };
}

pub fn exceptDistinctRows(allocator: std.mem.Allocator, a: []const []const BindingValue, b: []const []const BindingValue) ![]const []const BindingValue {
    var setB = std.StringHashMap(void).init(allocator);
    defer setB.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        _ = try setB.put(key, {});
    }
    var uniq = std.ArrayList([]const BindingValue).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer uniq.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(allocator, row);
        defer allocator.free(key);
        if (!setB.contains(key) and !seen.contains(key)) {
            _ = try seen.put(key, {});
            try uniq.append(allocator, row);
        }
    }
    return try sortUniqueRows(allocator, uniq.items);
}

test "binding table set ops: multi-column with NULLs" {
    const A0 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const A1 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const A2 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const B0 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const B1 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const B2 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const A: []const []BindingValue = &.{ A0[0..], A1[0..], A2[0..] };
    const B: []const []BindingValue = &.{ B0[0..], B1[0..], B2[0..] };
    const allocator = std.testing.allocator;
    const uD = try unionDistinctRows(allocator, A, B);
    defer allocator.free(uD);
    try std.testing.expect(uD.len == 2);
    const iA = try intersectAllRows(allocator, A, B);
    defer allocator.free(iA);
    // Counts: A has (1,"a"):2, (null,"x"):1; B has (1,"a"):1, (null,"x"):2 → min multiplicities ⇒ 1 copy of each
    try std.testing.expect(iA.len == 2);
    const eD = try exceptDistinctRows(allocator, A, B);
    defer allocator.free(eD);
    // Distinct A minus B => none (all A rows appear in B)
    try std.testing.expect(eD.len == 0);
    const eA = try exceptAllRows(allocator, A, B);
    defer allocator.free(eA);
    // All: (1,"a"): 2-1 = 1 left; (null,"x"): 1-2 = 0 left ⇒ total 1
    try std.testing.expect(eA.len == 1);
}

test "binding table set ops: DISTINCT sorted order with mixed types and NULLs" {
    // Build inputs with duplicates and mixed types across both sides
    const R0 = [_]BindingValue{ .{.Null}, .{ .Str = "n" } };
    const R1 = [_]BindingValue{ .{ .Bool = false }, .{ .Str = "b" } };
    const R2 = [_]BindingValue{ .{ .Int = 42 }, .{ .Str = "i" } };
    const R3 = [_]BindingValue{ .{ .Str = "aaa" }, .{ .Str = "s" } };
    const R4 = [_]BindingValue{ .{.Null}, .{ .Str = "n" } }; // duplicate of R0
    const A: []const []BindingValue = &.{ R2[0..], R3[0..], R4[0..] };
    const B: []const []BindingValue = &.{ R0[0..], R1[0..], R2[0..] };
    const allocator = std.testing.allocator;
    const ud = try unionDistinctRows(allocator, A, B);
    defer allocator.free(ud);
    // Expect sorted by row lexicographic with type precedence: Null < Bool < Int < Str
    // So order should be: R0/R4 (Null, "n") then R1 (Bool false, "b"), then R2 (Int 42, "i"), then R3 (Str "aaa", "s").
    try std.testing.expect(ud.len == 4);
    try std.testing.expect(rowEq(ud[0], R0[0..]));
    try std.testing.expect(rowEq(ud[1], R1[0..]));
    try std.testing.expect(rowEq(ud[2], R2[0..]));
    try std.testing.expect(rowEq(ud[3], R3[0..]));
    // Optimized path should yield the same
    const ud2 = try unionDistinctRowsOptimized(allocator, A, B, 1);
    defer allocator.free(ud2);
    try std.testing.expectEqual(ud.len, ud2.len);
    var i: usize = 0;
    while (i < ud.len) : (i += 1) try std.testing.expect(rowEq(ud[i], ud2[i]));
}
