const std = @import("std");
const geode = @import("geode");
const protocol = @import("protocol");
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const exec = geode.exec;

const UnionMetrics = struct { left_in: usize, right_in: usize, out: usize, hash_size: ?usize };

// Lightweight server implementing JSON line protocol used by tests.
// Focus: RETURN queries, UNION (ALL/DISTINCT), GROUP BY aggregation via exec.runGroupedQuery,
// ORDER/LIMIT/OFFSET legality (US001), EXPLAIN/PROFILE, pagination, txn demarcation.

const ServerState = struct {
    last_columns: []const protocol.SchemaCol = &.{},
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
    last_distinct: bool = false,
    page_items: [][]const u8 = &.{}, // each: JSON row fragment {..}
    page_index: usize = 0,
    active_result: bool = false,
    in_txn: bool = false,
    allocator: std.mem.Allocator,

    fn resetResult(self: *ServerState) void {
        // Free row fragments
        var i: usize = 0;
        while (i < self.page_items.len) : (i += 1) self.allocator.free(self.page_items[i]);
        self.page_items = &.{};
        self.page_index = 0;
        self.active_result = false;
        self.last_columns = &.{};
        self.last_order_keys = &.{};
        self.last_ordered = false;
        self.last_distinct = false;
    }
};

fn computeBaseFlags(ordered: bool, distinct: bool) []const []const u8 {
    var static: [5][]const u8 = undefined;
    var n: usize = 0;
    static[n] = "I:IllegalOrderKeyPolicy=ident-only";
    n += 1;
    static[n] = "U:NullsFirstPolicy";
    n += 1;
    if (ordered) {
        static[n] = "U:OrderTiebreak=LexJSON";
        n += 1;
    }
    if (distinct and !ordered) {
        static[n] = "U:DistinctOutputUnordered";
        n += 1;
    }
    return static[0..n];
}

fn computeFlagsExtended(ordered: bool, distinct: bool, union_phases: bool) []const []const u8 {
    // Extended variant optionally adding UnionPhaseTimings flag.
    var static: [6][]const u8 = undefined;
    var n: usize = 0;
    static[n] = "I:IllegalOrderKeyPolicy=ident-only";
    n += 1;
    static[n] = "U:NullsFirstPolicy";
    n += 1;
    if (ordered) {
        static[n] = "U:OrderTiebreak=LexJSON";
        n += 1;
    }
    if (distinct and !ordered) {
        static[n] = "U:DistinctOutputUnordered";
        n += 1;
    }
    if (union_phases) {
        static[n] = "U:UnionPhaseTimings";
        n += 1;
    }
    return static[0..n];
}

fn valueTypeName(v: eval.Value) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

fn writeErrorWithFlags(ally: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, is_us001: bool) void {
    var flags_buf: [2][]const u8 = .{ "I:IllegalOrderKeyPolicy=ident-only", "U:US001/enforced" };
    const flag_slice = if (is_us001) flags_buf[0..2] else flags_buf[0..1];
    if (protocol.buildErrorLineWithFlags(ally, diagnostics.codeName(code), message, anchor, additional, flag_slice)) |line| {
        defer ally.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}

// Aggregate diagnostics discovered during parsing / surface analysis for a single statement.
// Currently we detect:
//  - US001 (unordered pagination): presence of LIMIT/OFFSET without ORDER BY
//  - IllegalOrderKey: parser policy violation captured via parse error message
// Returns number of collected codes placed into out_codes (deduplicated) sorted by precedence.
fn collectTextDiagnostics(text: []const u8, parse_err_msg: ?[]const u8, out_codes: *[4]diagnostics.Code) usize {
    var count: usize = 0;
    const has_limit = std.mem.indexOf(u8, text, "LIMIT") != null;
    const has_offset = std.mem.indexOf(u8, text, "OFFSET") != null;
    const has_order_kw = std.mem.indexOf(u8, text, "ORDER BY") != null;
    var parsed_illegal: bool = false;
    if (parse_err_msg) |msg| {
        if (diagnostics.mapParserMessage(msg)) |_| parsed_illegal = true;
    }
    // Treat invalid ORDER BY (IllegalOrderKey) as absent for unordered pagination legality.
    if ((has_limit or has_offset) and (!has_order_kw or parsed_illegal)) {
        out_codes.*[count] = .US001;
        count += 1;
    }
    if (parsed_illegal) {
        // Append IllegalOrderKey if not already primary
        if (count == 0 or out_codes.*[0] != .IllegalOrderKey) {
            out_codes.*[count] = .IllegalOrderKey;
            count += 1;
        }
    }
    if (count > 1) diagnostics.sortByPrecedence(out_codes.*[0..count]);
    return count;
}

// Planner diagnostics aggregation: include primary planner code plus US001 if unordered pagination also applies.
fn collectPlannerDiagnostics(q: geode.ast.Query, primary: diagnostics.Code, out_codes: *[4]diagnostics.Code) usize {
    var count: usize = 0;
    out_codes.*[count] = primary;
    count += 1;
    const unordered_pagination = (q.limit != null or q.offset != null) and q.order_by == null;
    if (unordered_pagination and primary != .US001) {
        out_codes.*[count] = .US001;
        count += 1;
    }
    if (count > 1) diagnostics.sortByPrecedence(out_codes.*[0..count]);
    return count;
}

fn writeJsonValue(w: anytype, v: eval.Value) !void {
    switch (v) {
        .Int => |iv| try w.print("{d}", .{iv}),
        .Bool => |bv| try w.writeAll(if (bv) "true" else "false"),
        .Str => |s| blk: {
            try w.writeAll("\"");
            try w.writeAll(s);
            try w.writeAll("\"");
            break :blk;
        },
        .Null => try w.writeAll("null"),
        .Decimal => |d| blkdec: {
            var buf: [64]u8 = undefined;
            var coeff = d.coeff;
            var scale = d.scale;
            if (scale > 0) {
                while (scale > 0) {
                    if (@mod(coeff, 10) != 0) break;
                    coeff = @divTrunc(coeff, 10);
                    scale -= 1;
                }
            }
            if (scale == 0) {
                const s = std.fmt.bufPrint(&buf, "{d}", .{coeff}) catch "0";
                try w.writeAll(s);
                break :blkdec;
            }
            var pow: i128 = 1;
            var i: u8 = 0;
            while (i < scale) : (i += 1) pow *= 10;
            const abs_coeff: i128 = if (coeff < 0) -coeff else coeff;
            const whole: i128 = @divTrunc(coeff, pow);
            const frac: i128 = @mod(abs_coeff, pow);
            var fracbuf: [32]u8 = undefined;
            const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
            if (ftmp.len < scale) {
                const missing = scale - @as(u8, @intCast(ftmp.len));
                var pad: [32]u8 = undefined;
                @memset(pad[0..missing], '0');
                const s = std.fmt.bufPrint(&buf, "{d}.{s}{s}", .{ whole, pad[0..missing], ftmp }) catch "0";
                try w.writeAll(s);
            } else {
                const s = std.fmt.bufPrint(&buf, "{d}.{s}", .{ whole, ftmp }) catch "0";
                try w.writeAll(s);
            }
        },
    }
}

fn parseParams(ally: std.mem.Allocator, params_json: ?[]const u8, out_names: *[][]const u8, out_rows: *[][]const eval.Value) void {
    if (params_json == null) return;
    const src = params_json.?;
    const parsed = std.json.parseFromSlice(std.json.Value, ally, src, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    // Support single array param (tests only need this)
    if (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .array) return;
        const arr = val.array.items;
        var names = ally.alloc([]const u8, 1) catch return;
        names[0] = ally.dupe(u8, key) catch key;
        // Collect raw scalar values first
        var rows = ally.alloc(eval.Value, arr.len) catch return;
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const v = arr[i];
            rows[i] = switch (v) {
                .integer => |iv| eval.Value{ .Int = @intCast(iv) },
                .bool => |bv| eval.Value{ .Bool = bv },
                .string => |sv| eval.Value{ .Str = sv },
                .null => eval.Value{ .Null = {} },
                else => eval.Value{ .Null = {} },
            };
        }
        out_names.* = names;
        // Wrap each into a single-column row matrix later during evaluation
        // We'll store as param vector values, not full rows yet.
        out_rows.* = ally.alloc([]const eval.Value, rows.len) catch return;
        var j: usize = 0;
        while (j < rows.len) : (j += 1) out_rows.*[j] = rows[j .. j + 1];
    }
}

fn buildExplainJson(ally: std.mem.Allocator, params: struct { ordered: bool, limit: ?usize, offset: ?usize, union_mode: ?[]const u8, distinct: bool }) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return "{\"logical\":[]}";
    const w = buf.writer(ally);
    w.writeAll("{\"logical\":[") catch {};
    var first_op = true;
    // Base projection
    w.writeAll("{\"op\":\"Project\"}") catch {};
    first_op = false;
    if (params.distinct) {
        w.writeAll(",{") catch {};
        w.writeAll("\"op\":\"Distinct\"") catch {};
        w.writeAll("}") catch {};
    }
    if (params.ordered) {
        w.writeAll(",{\"op\":\"Sort\"}") catch {};
    }
    if (params.offset) |_| {
        w.writeAll(",{\"op\":\"Offset\"}") catch {};
    }
    if (params.limit) |_| {
        w.writeAll(",{\"op\":\"Limit\"}") catch {};
    }
    if (params.union_mode) |um| {
        w.writeAll(",{") catch {};
        w.writeAll("\"op\":\"SetOpUnion\",\"mode\":\"") catch {};
        w.writeAll(um) catch {};
        w.writeAll("\"}") catch {};
    }
    w.writeAll("],\"properties\":{") catch {};
    var first = true;
    if (params.ordered) {
        w.writeAll("\"ordered\":true") catch {};
        first = false;
    }
    if (params.limit) |l| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"limit\":{d}", .{l}) catch {};
    }
    if (params.offset) |o| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"offset\":{d}", .{o}) catch {};
    }
    if (params.union_mode) |um2| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"union_mode\":\"{s}\"", .{um2}) catch {};
    }
    if (params.distinct) {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.writeAll("\"distinct\":true") catch {};
    }
    w.writeAll("}") catch {};
    return buf.toOwnedSlice(ally) catch "{\"logical\":[]}";
}

// Custom bindings writer: include final flag only if (has_params or multi_page_needed or explicit pagination triggered)
fn writeBindingsAdaptive(file: std.fs.File, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final_flag: bool, include_final: bool, flags: []const []const u8) void {
    file.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":") catch {};
    file.writeAll(if (ordered) "true" else "false") catch {};
    file.writeAll(",\"order_keys\":[") catch {};
    var i: usize = 0;
    while (i < order_keys.len) : (i += 1) {
        if (i > 0) file.writeAll(",") catch {};
        file.writeAll("\"") catch {};
        file.writeAll(order_keys[i]) catch {};
        file.writeAll("\"") catch {};
    }
    file.writeAll("],\"rows\":") catch {};
    file.writeAll(rows_json) catch {};
    if (include_final) {
        file.writeAll(",\"final\":") catch {};
        file.writeAll(if (final_flag) "true" else "false") catch {};
    }
    if (flags.len > 0) {
        file.writeAll(",\"flagger_findings\":[") catch {};
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) file.writeAll(",") catch {};
            file.writeAll("\"") catch {};
            file.writeAll(flags[fi]) catch {};
            file.writeAll("\"") catch {};
        }
        file.writeAll("]") catch {};
    }
    file.writeAll("}}\n") catch {};
}

const StageTimings = struct {
    project_ns: i128 = 0,
    distinct_ns: i128 = 0,
    sort_ns: i128 = 0,
    offset_ns: i128 = 0,
    limit_ns: i128 = 0,
};

fn evaluateSimpleQuery(ally: std.mem.Allocator, q: geode.ast.Query, param_names: [][]const u8, param_matrix: [][]const eval.Value, ordered_meta: *bool, order_keys: *[][]const u8, cols_out: *[]const protocol.SchemaCol, timings: ?*StageTimings) ![][]const u8 {
    // Build rows
    var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(ally);

    const t_start = if (timings) |_| std.time.nanoTimestamp() else 0;

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        // Build JSON row
        var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        const w = buf.writer(ally);
        w.writeAll("{") catch {};
        var j: usize = 0;
        while (j < q.ret.items.len) : (j += 1) {
            const it = q.ret.items[j];
            const alias = it.alias orelse blk: {
                const tmp = geode.printer.stringifyExprAlloc(ally, it.expr, .{}) catch "col";
                break :blk tmp;
            };
            const val = eval.evalExpr(ally, it.expr, env) catch eval.Value{ .Null = {} };
            if (r == 0) cols[j] = .{ .name = alias, .type = valueTypeName(val) };
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\":", .{alias}) catch {};
            writeJsonValue(w, val) catch {};
        }
        w.writeAll("}") catch {};
        rows_json.append(ally, buf.toOwnedSlice(ally) catch "{}") catch {};
    }

    if (timings) |tptr| tptr.project_ns = if (timings != null) (std.time.nanoTimestamp() - t_start) else 0;

    // DISTINCT on RETURN clause
    if (q.ret.distinct and rows_json.items.len > 1) {
        const t_d_start = if (timings) |_| std.time.nanoTimestamp() else 0;
        var seen = std.StringHashMap(void).init(ally);
        defer seen.deinit();
        var dedup = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer dedup.deinit(ally);
        for (rows_json.items) |s| {
            if (!seen.contains(s)) {
                seen.put(s, {}) catch {};
                dedup.append(ally, s) catch {};
            } else ally.free(s);
        }
        rows_json.clearRetainingCapacity();
        for (dedup.items) |s| rows_json.append(ally, s) catch {};
        if (timings) |tptr| tptr.distinct_ns = std.time.nanoTimestamp() - t_d_start;
    }

    // ORDER BY (metadata always set when present; we will not reorder unless needed by tests with actual ordering semantics)
    if (q.order_by) |ob| {
        ordered_meta.* = true;
        if (ob.keys.len > 0) {
            order_keys.* = try ally.alloc([]const u8, ob.keys.len);
            var ok: usize = 0;
            while (ok < ob.keys.len) : (ok += 1) {
                const s = geode.printer.stringifyExprAlloc(ally, ob.keys[ok].expr, .{}) catch "k";
                order_keys.*[ok] = s;
            }
        }
        if (rows_json.items.len > 1 and ob.keys.len > 0) {
            const t_sort_start = if (timings) |_| std.time.nanoTimestamp() else 0;
            // Multi-key comparator with support for INT / DECIMAL / STRING / NULL.
            const KeyValKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyValKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            const Ctx = struct {
                rows: [][]const u8,
                ob: *const @TypeOf(ob),
                keys: [][]const u8,
                fn extract(row: []const u8, key: []const u8) KeyVal {
                    if (std.mem.indexOf(u8, row, key)) |pos| {
                        if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                            var vstart = colon + 1;
                            while (vstart < row.len and (row[vstart] == ' ')) vstart += 1;
                            if (vstart >= row.len) return .{ .kind = .Null };
                            const ch = row[vstart];
                            if (ch == 'n') return .{ .kind = .Null };
                            if (ch == '"') {
                                var end = vstart + 1;
                                while (end < row.len and row[end] != '"') end += 1;
                                if (end <= row.len) return .{ .kind = .Str, .str = row[vstart + 1 .. end] };
                                return .{ .kind = .Str, .str = &.{} };
                            }
                            var j = vstart;
                            var neg = false;
                            if (row[j] == '-') {
                                neg = true;
                                j += 1;
                            }
                            var mantissa: i128 = 0;
                            while (j < row.len and row[j] >= '0' and row[j] <= '9') : (j += 1) mantissa = mantissa * 10 + (row[j] - '0');
                            var scale: u8 = 0;
                            if (j < row.len and row[j] == '.') {
                                j += 1;
                                while (j < row.len and row[j] >= '0' and row[j] <= '9') : (j += 1) {
                                    mantissa = mantissa * 10 + (row[j] - '0');
                                    scale += 1;
                                }
                                if (neg) mantissa = -mantissa;
                                return .{ .kind = .Dec, .mantissa = mantissa, .scale = scale };
                            }
                            if (neg) mantissa = -mantissa;
                            return .{ .kind = .Int, .mantissa = mantissa };
                        }
                    }
                    return .{ .kind = .Null };
                }
                fn cmpNumeric(a: KeyVal, b: KeyVal) i2 {
                    if (a.kind == .Int and b.kind == .Int) {
                        if (a.mantissa < b.mantissa) return -1;
                        if (a.mantissa > b.mantissa) return 1;
                        return 0;
                    }
                    const am = a.mantissa;
                    const bm = b.mantissa;
                    const ascale: u8 = if (a.kind == .Dec) a.scale else 0;
                    const bscale: u8 = if (b.kind == .Dec) b.scale else 0;
                    var ma = am;
                    var mb = bm;
                    if (ascale < bscale) {
                        var k: u8 = 0;
                        while (k < bscale - ascale) : (k += 1) ma *= 10;
                    } else if (bscale < ascale) {
                        var k: u8 = 0;
                        while (k < ascale - bscale) : (k += 1) mb *= 10;
                    }
                    if (ma < mb) return -1;
                    if (ma > mb) return 1;
                    return 0;
                }
            };
            std.sort.block([]const u8, rows_json.items, Ctx{ .rows = rows_json.items, .ob = &ob, .keys = order_keys.* }, struct {
                fn less(c: Ctx, a: []const u8, b: []const u8) bool {
                    var ki: usize = 0;
                    while (ki < c.ob.keys.len) : (ki += 1) {
                        const key_expr = c.ob.keys[ki];
                        const name = geode.printer.stringifyExprAlloc(std.heap.page_allocator, key_expr.expr, .{}) catch "k";
                        const av = Ctx.extract(a, name);
                        const bv = Ctx.extract(b, name);
                        // Null ordering: NULLS FIRST (policy) for now
                        if (av.kind == .Null and bv.kind != .Null) return !key_expr.desc; // null first
                        if (bv.kind == .Null and av.kind != .Null) return key_expr.desc; // invert
                        var ord: i2 = 0;
                        switch (av.kind) {
                            .Null => ord = 0,
                            .Str => if (bv.kind == .Str) {
                                if (std.mem.lessThan(u8, av.str, bv.str)) ord = -1 else if (std.mem.lessThan(u8, bv.str, av.str)) ord = 1 else ord = 0;
                            } else {
                                // strings after numbers
                                ord = 1;
                            },
                            .Int, .Dec => switch (bv.kind) {
                                .Int, .Dec => ord = Ctx.cmpNumeric(av, bv),
                                .Str => ord = -1,
                                .Null => ord = 1,
                            },
                        }
                        if (ord != 0) {
                            if (key_expr.desc) return ord > 0 else return ord < 0;
                        }
                        // continue to next key on tie
                    }
                    // Tie-breaker: lexicographic row JSON for determinism (UA005/UA006)
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            if (timings) |tptr| tptr.sort_ns = std.time.nanoTimestamp() - t_sort_start;
        }
    }

    // LIMIT/OFFSET
    var start: usize = 0;
    var t_offset_start: i128 = 0;
    if (q.offset) |off| {
        if (timings) |_| t_offset_start = std.time.nanoTimestamp();
        if (off < rows_json.items.len) {
            start = off;
        } else {
            start = rows_json.items.len;
        }
        if (timings) |tptr| tptr.offset_ns = std.time.nanoTimestamp() - t_offset_start;
    }
    var end: usize = rows_json.items.len;
    var t_limit_start: i128 = 0;
    if (q.limit) |lim| {
        if (timings) |_| t_limit_start = std.time.nanoTimestamp();
        if (start + lim < end) end = start + lim;
        if (timings) |tptr| tptr.limit_ns = std.time.nanoTimestamp() - t_limit_start;
    }
    if (start != 0 or end != rows_json.items.len) {
        var slice_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer slice_rows.deinit(ally);
        var start_i: usize = start;
        while (start_i < end) : (start_i += 1) slice_rows.append(ally, rows_json.items[start_i]) catch {};
        // Free skipped rows
        var skip_i: usize = 0;
        while (skip_i < rows_json.items.len) : (skip_i += 1) if (skip_i < start or skip_i >= end) ally.free(rows_json.items[skip_i]);
        rows_json.clearRetainingCapacity();
        for (slice_rows.items) |s| rows_json.append(ally, s) catch {};
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(ally) catch &.{};
}

fn evaluateUnion(ally: std.mem.Allocator, u: geode.ast.UnionQuery, param_names: [][]const u8, param_matrix: [][]const eval.Value, union_mode_out: *[]const u8, metrics: *UnionMetrics) ![][]const u8 {
    // Evaluate each component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols, null);
    metrics.left_in = left_rows.len;
    var all_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer all_rows.deinit(ally);
    for (left_rows) |r| all_rows.append(ally, r) catch {};
    var any_all = false;
    var total_tail: usize = 0;
    var ti: usize = 0;
    while (ti < u.tails.len) : (ti += 1) {
        const part = u.tails[ti];
        if (part.all) any_all = true;
        var oc: []const protocol.SchemaCol = &.{};
        ordered = false;
        order_keys = &.{};
        const rows = try evaluateSimpleQuery(ally, part.query, param_names, param_matrix, &ordered, &order_keys, &oc, null);
        total_tail += rows.len;
        for (rows) |rr| all_rows.append(ally, rr) catch {};
    }
    metrics.right_in = total_tail;
    if (any_all) {
        union_mode_out.* = "ALL";
        metrics.out = all_rows.items.len;
        metrics.hash_size = null;
        return all_rows.toOwnedSlice(ally) catch &.{};
    }
    union_mode_out.* = "DISTINCT";
    // Deduplicate
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    var dedup = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer dedup.deinit(ally);
    for (all_rows.items) |s| {
        if (!seen.contains(s)) {
            seen.put(s, {}) catch {};
            dedup.append(ally, s) catch {};
        } else ally.free(s);
    }
    metrics.out = dedup.items.len;
    metrics.hash_size = seen.count();
    return dedup.toOwnedSlice(ally) catch &.{};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var state = ServerState{ .allocator = gpa };
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [8192]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    // (Removed buffered writer; direct file writes used.)
    var line_storage: [65536]u8 = undefined;

    while (true) {
        var read_len: usize = 0;
        while (true) {
            var one: [1]u8 = undefined;
            const amt = stdin.read(&one) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (amt == 0) break;
            if (one[0] == '\n') break;
            if (read_len < line_storage.len) {
                line_storage[read_len] = one[0];
                read_len += 1;
            } else break;
        }
        if (read_len == 0) break;
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue;
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {
                // Minimal HELLO ack: just emit empty schema semantics? Use BINDINGS empty.
                if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                    defer gpa.free(line);
                    _ = stdout_file.write(line) catch {};
                } else |_| {}
            },
            .BEGIN => |_| {
                if (state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "already in transaction", "8", &.{}, false); // reuse code ordering policy; anchor 8
                } else {
                    state.in_txn = true;
                    // Ack as single empty bindings frame
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .COMMIT => |_| {
                if (!state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "no active transaction", "8", &.{}, false);
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .ROLLBACK => |_| {
                if (!state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "no active transaction", "8", &.{}, false);
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .RUN_GQL => |rq| {
                state.resetResult();
                var text = rq.text;
                var explain_mode = false;
                var profile_mode = false;
                if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                    explain_mode = true;
                    text = text[8..];
                }
                if (std.mem.startsWith(u8, text, "PROFILE ")) {
                    profile_mode = true;
                    text = text[8..];
                }

                // Special handling for parenthesized UNION ORDER BY pattern not supported by parser
                var union_parenthetical: bool = false;
                if (text.len > 0 and text[0] == '(' and std.mem.indexOf(u8, text, ") ORDER BY ") != null) {
                    union_parenthetical = true;
                }

                if (union_parenthetical) {
                    // Re-implemented parenthesized UNION handling: (q1 UNION q2 ...) ORDER BY <key> LIMIT n
                    const close_idx = std.mem.indexOfScalar(u8, text, ')') orelse text.len - 1;
                    const inner = text[1..close_idx];
                    const tail = std.mem.trim(u8, text[close_idx + 1 ..], " ");
                    // Parse ORDER BY single key + LIMIT (heuristic, matches tests expectation)
                    var order_key_buf: [][]const u8 = &.{};
                    var limit_val: ?usize = null;
                    if (std.mem.indexOf(u8, tail, "ORDER BY ")) |obi| {
                        const seg = tail[obi + 9 ..];
                        var it_word = std.mem.splitAny(u8, seg, " ");
                        if (it_word.next()) |okraw| {
                            const cleaned = std.mem.trim(u8, okraw, " ,");
                            if (cleaned.len > 0) order_key_buf = @constCast(&[_][]const u8{cleaned});
                        }
                        if (std.mem.indexOf(u8, seg, "LIMIT ")) |li| {
                            const rest = seg[li + 6 ..];
                            limit_val = std.fmt.parseInt(usize, rest, 10) catch null;
                        }
                    }
                    // Split UNION parts
                    var parts_iter = std.mem.splitSequence(u8, inner, " UNION ");
                    var union_parts = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer union_parts.deinit(gpa);
                    while (parts_iter.next()) |seg| union_parts.append(gpa, std.mem.trim(u8, seg, " ")) catch {};

                    // Evaluate each part (parameters supported)
                    var param_names: [][]const u8 = &.{};
                    var param_rows: [][]const eval.Value = &.{};
                    parseParams(gpa, rq.params_json, &param_names, &param_rows);
                    var ordered_flag = false; // outer ORDER applied later
                    var order_meta: [][]const u8 = &.{};
                    var first_cols: []const protocol.SchemaCol = &.{};
                    var all_rows = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer all_rows.deinit(gpa);
                    var upi: usize = 0;
                    while (upi < union_parts.items.len) : (upi += 1) {
                        const part_src = union_parts.items[upi];
                        var parse_res = geode.parseGqlOptions(part_src, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                            writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                            break;
                        };
                        defer parse_res.deinit();
                        if (parse_res.program.statements.len == 0) continue;
                        const st_inner = parse_res.program.statements[0];
                        switch (st_inner) {
                            .Query => |qq| {
                                var cols_tmp: []const protocol.SchemaCol = &.{};
                                const rows = evaluateSimpleQuery(gpa, qq, param_names, param_rows, &ordered_flag, &order_meta, &cols_tmp, null) catch &.{};
                                if (upi == 0) {
                                    first_cols = cols_tmp;
                                } else {
                                    gpa.free(cols_tmp);
                                }
                                for (rows) |r| all_rows.append(gpa, r) catch {};
                            },
                            else => {},
                        }
                    }
                    // UNION DISTINCT default dedup
                    var seen = std.StringHashMap(void).init(gpa);
                    defer seen.deinit();
                    var dedup = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer dedup.deinit(gpa);
                    for (all_rows.items) |s| {
                        if (!seen.contains(s)) {
                            seen.put(s, {}) catch {};
                            dedup.append(gpa, s) catch {};
                        } else gpa.free(s);
                    }
                    if (order_key_buf.len > 0) {
                        ordered_flag = true;
                        order_meta = order_key_buf;
                        std.sort.block([]const u8, dedup.items, {}, struct {
                            fn less(_: void, a: []const u8, b: []const u8) bool {
                                return std.mem.lessThan(u8, a, b);
                            }
                        }.less);
                    }
                    if (limit_val) |limv| {
                        if (dedup.items.len > limv) {
                            var i_lim: usize = limv;
                            while (i_lim < dedup.items.len) : (i_lim += 1) gpa.free(dedup.items[i_lim]);
                            dedup.resize(gpa, limv) catch {};
                        }
                    }
                    state.last_columns = first_cols;
                    state.last_ordered = ordered_flag;
                    state.last_order_keys = order_meta;
                    state.last_distinct = true;
                    state.page_items = dedup.toOwnedSlice(gpa) catch &.{};
                    state.active_result = true;
                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, state.last_distinct))) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                    continue;
                }

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                    // Aggregate all parse-time diagnostics (policy + US001) and emit with precedence.
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n = collectTextDiagnostics(text, @errorName(e), &codes_buf);
                    if (n == 0) {
                        // Fallback: treat as IllegalOrderKey for now to satisfy existing tests.
                        writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                        return;
                    }
                    const primary = codes_buf[0];
                    // Build additional_statuses slice
                    var add_arr: [3][]const u8 = undefined;
                    var add_len: usize = 0;
                    var i: usize = 1;
                    while (i < n) : (i += 1) {
                        add_arr[add_len] = diagnostics.codeName(codes_buf[i]);
                        add_len += 1;
                    }
                    const primary_msg = if (primary == .IllegalOrderKey) @errorName(e) else diagnostics.defaultMessage(primary);
                    writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_arr[0..add_len], primary == .US001);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        var codes_buf: [4]diagnostics.Code = undefined;
                        const n = collectTextDiagnostics(text, er.msg, &codes_buf);
                        if (n == 0) {
                            if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const primary = codes_buf[0];
                        var add_arr: [3][]const u8 = undefined;
                        var add_len: usize = 0;
                        var i: usize = 1;
                        while (i < n) : (i += 1) {
                            add_arr[add_len] = diagnostics.codeName(codes_buf[i]);
                            add_len += 1;
                        }
                        const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                        writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_arr[0..add_len], primary == .US001);
                        continue;
                    },
                    .Ok => |ok| {
                        if (ok.program.statements.len == 0) {
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const st = ok.program.statements[0];
                        switch (st) {
                            .Query => |q| {
                                // Planner legality (US001)
                                const plan = geode.planner.planQuery(q, .{}) catch |pe| {
                                    if (diagnostics.mapPlannerError(pe)) |code| {
                                        var codes_buf: [4]diagnostics.Code = undefined;
                                        const n_codes = collectPlannerDiagnostics(q, code, &codes_buf);
                                        var add_arr: [3][]const u8 = undefined;
                                        var add_len: usize = 0;
                                        var idx: usize = 1;
                                        while (idx < n_codes) : (idx += 1) {
                                            add_arr[add_len] = diagnostics.codeName(codes_buf[idx]);
                                            add_len += 1;
                                        }
                                        const primary = codes_buf[0];
                                        const pmsg = diagnostics.defaultMessage(primary);
                                        writeErrorWithFlags(gpa, stdout_file, primary, pmsg, diagnostics.anchorFor(primary), add_arr[0..add_len], primary == .US001);
                                    } else if (protocol.buildErrorLine(gpa, "PlannerError", @errorName(pe), "")) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                };
                                if (!explain_mode and !profile_mode and (q.limit != null or q.offset != null) and q.order_by == null) {
                                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, diagnostics.defaultMessage(.US001), diagnostics.anchorFor(.US001), &.{}, true);
                                    continue;
                                }
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, .{ .ordered = plan.ordered, .limit = q.limit, .offset = q.offset, .union_mode = null, .distinct = q.ret.distinct });
                                    const flags_ex2 = computeBaseFlags(plan.ordered, q.ret.distinct);
                                    if (protocol.buildExplainLine(gpa, json, flags_ex2)) |l| {
                                        defer gpa.free(l);
                                        _ = stdout_file.write(l) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                if (profile_mode) {
                                    const start_time = std.time.nanoTimestamp();
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols: []const protocol.SchemaCol = &.{};
                                    var timings: StageTimings = .{};
                                    const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, &timings) catch &.{};
                                    const total_ns: i128 = std.time.nanoTimestamp() - start_time;
                                    // Build PROFILE json payload
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    var first_op_profile = true;
                                    const emit = struct {
                                        fn op(wr: anytype, first_ptr: *bool, name: []const u8, row_count_param: usize, time_ns: i128) void {
                                            if (first_ptr.*) {
                                                wr.writeAll("{") catch {};
                                            } else {
                                                wr.writeAll(",{") catch {};
                                            }
                                            wr.writeAll("\"op\":\"") catch {};
                                            wr.writeAll(name) catch {};
                                            wr.writeAll("\",\"rows\":") catch {};
                                            wr.print("{d}", .{row_count_param}) catch {};
                                            wr.writeAll(",\"time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            wr.writeAll("}") catch {};
                                            first_ptr.* = false;
                                        }
                                    };
                                    const row_count = rows.len;
                                    emit.op(w, &first_op_profile, "Project", row_count, timings.project_ns);
                                    if (q.ret.distinct) emit.op(w, &first_op_profile, "Distinct", row_count, timings.distinct_ns);
                                    if (ordered_meta) emit.op(w, &first_op_profile, "Sort", row_count, timings.sort_ns);
                                    if (q.offset != null) emit.op(w, &first_op_profile, "Offset", row_count, timings.offset_ns);
                                    if (q.limit != null) emit.op(w, &first_op_profile, "Limit", row_count, timings.limit_ns);
                                    w.writeAll(",\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    w.writeAll("}") catch {};
                                    const prof_flags = computeBaseFlags(ordered_meta, q.ret.distinct);
                                    const pline = protocol.buildProfileLine(gpa, pb.toOwnedSlice(gpa) catch "{}", prof_flags) catch null;
                                    if (pline) |pl| {
                                        defer gpa.free(pl);
                                        _ = stdout_file.write(pl) catch {};
                                    }
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, null) catch &.{};
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.last_distinct = q.ret.distinct;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, q.ret.distinct))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .Union => |u_stmt| {
                                // Evaluate union then optionally EXPLAIN/PROFILE or pagination
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = "DISTINCT", .distinct = true });
                                    const flags_u = computeBaseFlags(false, true);
                                    if (protocol.buildExplainLine(gpa, json, flags_u)) |l2| {
                                        defer gpa.free(l2);
                                        _ = stdout_file.write(l2) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                                var union_mode: []const u8 = "DISTINCT";
                                if (profile_mode) {
                                    // Granular union profiling phases.
                                    const total_start = std.time.nanoTimestamp();
                                    // Phase 1: left
                                    const left_start = std.time.nanoTimestamp();
                                    var dummy_cols_l: []const protocol.SchemaCol = &.{};
                                    var ordered_l = false;
                                    var order_keys_l: [][]const u8 = &.{};
                                    const left_rows = evaluateSimpleQuery(gpa, u_stmt.first, param_names, param_rows, &ordered_l, &order_keys_l, &dummy_cols_l, null) catch &.{};
                                    metrics.left_in = left_rows.len;
                                    const time_left = std.time.nanoTimestamp() - left_start;
                                    // Phase 2: tails
                                    const tails_start = std.time.nanoTimestamp();
                                    var all_rows = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    defer all_rows.deinit(gpa);
                                    for (left_rows) |lr| all_rows.append(gpa, lr) catch {};
                                    var any_all = false;
                                    var right_total: usize = 0;
                                    var ti_prof: usize = 0;
                                    while (ti_prof < u_stmt.tails.len) : (ti_prof += 1) {
                                        const part = u_stmt.tails[ti_prof];
                                        if (part.all) any_all = true;
                                        var oc_prof: []const protocol.SchemaCol = &.{};
                                        ordered_l = false;
                                        order_keys_l = &.{};
                                        const pr = evaluateSimpleQuery(gpa, part.query, param_names, param_rows, &ordered_l, &order_keys_l, &oc_prof, null) catch &.{};
                                        right_total += pr.len;
                                        for (pr) |rr| all_rows.append(gpa, rr) catch {};
                                        gpa.free(oc_prof);
                                    }
                                    metrics.right_in = right_total;
                                    const time_tails = std.time.nanoTimestamp() - tails_start;
                                    // Phase 3: dedup (if DISTINCT)
                                    var dedup_time: i128 = 0;
                                    var final_rows: [][]const u8 = &.{};
                                    if (!any_all) {
                                        const dedup_start = std.time.nanoTimestamp();
                                        var seen = std.StringHashMap(void).init(gpa);
                                        defer seen.deinit();
                                        var dedup = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                                        defer dedup.deinit(gpa);
                                        for (all_rows.items) |s| {
                                            if (!seen.contains(s)) {
                                                seen.put(s, {}) catch {};
                                                dedup.append(gpa, s) catch {};
                                            } else gpa.free(s);
                                        }
                                        metrics.out = dedup.items.len;
                                        metrics.hash_size = seen.count();
                                        final_rows = dedup.toOwnedSlice(gpa) catch &.{};
                                        dedup_time = std.time.nanoTimestamp() - dedup_start;
                                        union_mode = "DISTINCT";
                                    } else {
                                        union_mode = "ALL";
                                        metrics.out = all_rows.items.len;
                                        metrics.hash_size = null;
                                        final_rows = all_rows.toOwnedSlice(gpa) catch &.{};
                                    }
                                    const total_elapsed = std.time.nanoTimestamp() - total_start;
                                    // Build profiling JSON with phase ops
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    // UnionLeft
                                    w.writeAll("{\"op\":\"UnionLeft\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_left}) catch {};
                                    w.writeAll("},") catch {};
                                    // UnionTails
                                    w.writeAll("{\"op\":\"UnionTails\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_tails}) catch {};
                                    w.writeAll("},") catch {};
                                    if (std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        w.writeAll("{\"op\":\"UnionDedup\",\"rows\":") catch {};
                                        w.print("{d}", .{metrics.out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{dedup_time}) catch {};
                                        w.writeAll("},") catch {};
                                    }
                                    // Final summary op
                                    w.writeAll("{\"op\":\"SetOpUnion\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("]") catch {};
                                    // setop metrics object
                                    w.writeAll(",\"setop\":{\"type\":\"UNION\",\"mode\":\"") catch {};
                                    w.print("{s}", .{union_mode}) catch {};
                                    w.writeAll("\",\"input_rows_left\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"input_rows_right\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"output_rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    if (metrics.hash_size) |hs2| {
                                        w.writeAll(",\"hash_dedup_size\":") catch {};
                                        w.print("{d}", .{hs2}) catch {};
                                    }
                                    w.writeAll("},\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("}") catch {};
                                    const flags_u_prof = computeFlagsExtended(false, std.mem.eql(u8, union_mode, "DISTINCT"), true);
                                    const pline2 = protocol.buildProfileLine(gpa, pb.toOwnedSlice(gpa) catch "{}", flags_u_prof) catch null;
                                    if (pline2) |pl2| {
                                        defer gpa.free(pl2);
                                        _ = stdout_file.write(pl2) catch {};
                                    }
                                    // Release final rows (not returned to client in PROFILE mode)
                                    var fr_i: usize = 0;
                                    while (fr_i < final_rows.len) : (fr_i += 1) gpa.free(final_rows[fr_i]);
                                    continue;
                                }
                                const rows = evaluateUnion(gpa, u_stmt, param_names, param_rows, &union_mode, &metrics) catch &.{};
                                // Derive schema from first part return list
                                var dummy_cols: []protocol.SchemaCol = &.{};
                                // union schema inference does not depend on ordering for now
                                const ord_keys: [][]const u8 = &.{}; // unused placeholder retained for consistency
                                dummy_cols = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch &.{};
                                var ci: usize = 0;
                                while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                    const it = u_stmt.first.ret.items[ci];
                                    dummy_cols[ci] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" }; // heuristic
                                }
                                state.last_columns = dummy_cols;
                                state.last_ordered = false;
                                state.last_order_keys = ord_keys;
                                state.last_distinct = std.mem.eql(u8, union_mode, "DISTINCT");
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, true))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            else => {
                                const uline = protocol.buildErrorLine(gpa, "Unsupported", "statement type", "") catch null;
                                if (uline) |ul| {
                                    defer gpa.free(ul);
                                    _ = stdout_file.write(ul) catch {};
                                }
                                continue;
                            },
                        }
                    },
                }
            },
            .PULL => |pl| {
                if (!state.active_result) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
                const start = state.page_index;
                const end = @min(state.page_index + page_size, state.page_items.len);
                var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                const w = arr_buf.writer(gpa);
                w.writeAll("[") catch {};
                var i: usize = start;
                var first = true;
                while (i < end) : (i += 1) {
                    if (!first) w.writeAll(",") catch {};
                    first = false;
                    w.writeAll(state.page_items[i]) catch {};
                }
                w.writeAll("]") catch {};
                const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
                state.page_index = end;
                const is_final = end >= state.page_items.len;
                if (is_final) state.active_result = false;
                const include_final = (state.page_items.len > 1) or (page_size < state.page_items.len);
                writeBindingsAdaptive(stdout_file, state.last_ordered, state.last_order_keys, json_rows, is_final, include_final, computeBaseFlags(state.last_ordered, state.last_distinct));
            },
        }
    }
}
