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
    // PROFILE mode staging: we emit SCHEMA immediately and defer PROFILE frame until first PULL.
    profile_json: ?[]const u8 = null,
    profile_flags: []const []const u8 = &.{},
    // Simulated spill counters (future: real spill logic). Populated from env vars GEODE_FORCE_*.
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_threshold: usize = 0,

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
        if (self.profile_json) |pj| self.allocator.free(pj);
        self.profile_json = null;
        self.profile_flags = &.{};
    }
};

// TODO(counting-alloc): Reintroduce a stats-enabled allocator for accurate bytes_alloc metrics.
// TODO(counting-alloc): Zig 0.15 allocator API changes make lightweight custom vtable here noisy.
// Revert to heuristic bytes until a proper stats allocator is integrated.

// Dynamic flag construction (avoids large matrix now that NULL policy is runtime configurable).
var g_nulls_last: bool = false; // default NullsFirstPolicy unless overridden by env

fn computeBaseFlags(ordered: bool, distinct: bool) []const []const u8 {
    // Maximum 4 findings: IllegalOrderKey policy, NullsPolicy, OrderTiebreak, DistinctOutputUnordered
    var tmp: [4][]const u8 = undefined;
    var n: usize = 0;
    tmp[n] = "I:IllegalOrderKeyPolicy=ident-only";
    n += 1;
    tmp[n] = if (g_nulls_last) "U:NullsLastPolicy" else "U:NullsFirstPolicy";
    n += 1;
    if (ordered) {
        tmp[n] = "U:OrderTiebreak=LexJSON";
        n += 1;
    }
    if (!ordered and distinct) {
        tmp[n] = "U:DistinctOutputUnordered";
        n += 1;
    }
    return tmp[0..n];
}

fn computeFlagsExtended(ordered: bool, distinct: bool, union_phases: bool) []const []const u8 {
    if (!union_phases) return computeBaseFlags(ordered, distinct);
    const base = computeBaseFlags(ordered, distinct);
    // Append UnionPhaseTimings
    var tmp: [5][]const u8 = undefined;
    var i: usize = 0;
    while (i < base.len) : (i += 1) tmp[i] = base[i];
    tmp[base.len] = "U:UnionPhaseTimings";
    return tmp[0 .. base.len + 1];
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

fn writeErrorWithFlags(ally: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, has_us001_any: bool) void {
    var flags_buf: [2][]const u8 = .{ "I:IllegalOrderKeyPolicy=ident-only", "U:US001/enforced" };
    const flag_slice = if (has_us001_any) flags_buf[0..2] else flags_buf[0..1];
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
    var tmp: [4]diagnostics.Code = undefined;
    var n: usize = 0;
    const has_limit = std.mem.indexOf(u8, text, "LIMIT") != null;
    const has_offset = std.mem.indexOf(u8, text, "OFFSET") != null;
    const has_order_kw = std.mem.indexOf(u8, text, "ORDER BY") != null;
    var parsed_illegal = false;
    if (parse_err_msg) |msg| {
        if (diagnostics.mapParserMessage(msg)) |_| {
            parsed_illegal = true;
        }
    }
    if ((has_limit or has_offset) and (!has_order_kw or parsed_illegal)) {
        tmp[n] = .US001;
        n += 1;
    }
    if (parsed_illegal) {
        tmp[n] = .IllegalOrderKey;
        n += 1;
    }
    // Dedup + precedence
    var i: usize = 0;
    while (i < n) : (i += 1) out_codes.*[i] = tmp[i];
    return diagnostics.foldCodes(out_codes.*[0..n]);
}

// Planner diagnostics aggregation: include primary planner code plus US001 if unordered pagination also applies.
fn collectPlannerDiagnostics(q: geode.ast.Query, primary: diagnostics.Code, out_codes: *[4]diagnostics.Code) usize {
    out_codes.*[0] = primary;
    var n: usize = 1;
    const unordered_pagination = (q.limit != null or q.offset != null) and q.order_by == null;
    if (unordered_pagination and primary != .US001) {
        out_codes.*[n] = .US001;
        n += 1;
    }
    return diagnostics.foldCodes(out_codes.*[0..n]);
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
    // Canonical pipeline order with monotonic id: Project(0), Distinct(1), Sort(2), Offset(3), Limit(4), SetOpUnion(5)
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return "{\"logical\":[]}";
    const w = buf.writer(ally);
    w.writeAll("{\"profile_version\":1,\"logical\":[") catch {};
    var id: usize = 0;
    // Project always present first
    // Project
    w.writeAll("{\"op\":\"Project\",\"id\":") catch {};
    w.print("{d}", .{id}) catch {};
    w.writeAll("}") catch {};
    id += 1;
    if (params.distinct) {
        w.writeAll(",{\"op\":\"Distinct\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.ordered) {
        w.writeAll(",{\"op\":\"Sort\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.offset) |_| {
        w.writeAll(",{\"op\":\"Offset\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.limit) |_| {
        w.writeAll(",{\"op\":\"Limit\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.union_mode) |um| {
        w.writeAll(",{\"op\":\"SetOpUnion\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll(",\"mode\":\"") catch {};
        w.writeAll(um) catch {};
        w.writeAll("\"}") catch {};
        id += 1;
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
    agg_build_ns: i128 = 0,
    agg_emit_ns: i128 = 0,
    expand_ns: i128 = 0,
    project_rows_out: usize = 0,
    distinct_rows_out: usize = 0,
    sort_rows_out: usize = 0,
    offset_rows_out: usize = 0,
    limit_rows_out: usize = 0,
    agg_rows_out: usize = 0,
    expand_rows_out: usize = 0,
    project_rows_in: usize = 0,
    distinct_rows_in: usize = 0,
    sort_rows_in: usize = 0,
    offset_rows_in: usize = 0,
    limit_rows_in: usize = 0,
    agg_rows_in: usize = 0,
    expand_rows_in: usize = 0,
    // Approximate bytes processed/emitted per stage (JSON row bytes) for profiling.
    project_bytes_out: usize = 0,
    distinct_bytes_out: usize = 0,
    sort_bytes_out: usize = 0,
    offset_bytes_out: usize = 0,
    limit_bytes_out: usize = 0,
    expand_bytes_out: usize = 0,
    // Approximate allocated bytes attributable to each stage (heuristic: bytes_out currently; future: real allocator diff)
    project_bytes_alloc: usize = 0,
    distinct_bytes_alloc: usize = 0,
    sort_bytes_alloc: usize = 0,
    offset_bytes_alloc: usize = 0,
    limit_bytes_alloc: usize = 0,
    agg_build_bytes_alloc: usize = 0,
    agg_emit_bytes_alloc: usize = 0,
    expand_bytes_alloc: usize = 0,
};
// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

// Value-based canonical key: encodes row values directly to avoid JSON reparsing.
fn canonicalValuesKey(ally: std.mem.Allocator, vals: []const eval.Value) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return &.{};
    const w = buf.writer(ally);
    var i: usize = 0;
    while (i < vals.len) : (i += 1) {
        if (i > 0) w.writeAll("|") catch {};
        const v = vals[i];
        switch (v) {
            .Null => w.writeAll("n") catch {},
            .Int => |iv| w.print("i:{d}", .{iv}) catch {},
            .Bool => |bv| w.writeAll(if (bv) "s:4:true" else "s:5:false") catch {},
            .Str => |s| blk: {
                w.writeAll("s:") catch {};
                w.print("{d}:", .{s.len}) catch {};
                w.writeAll(s) catch {};
                break :blk;
            },
            .Decimal => |d| blk2: {
                var coeff = d.coeff;
                var scale = d.scale;
                if (scale > 0) {
                    while (scale > 0 and @mod(coeff, 10) == 0) : (scale -= 1) coeff = @divTrunc(coeff, 10);
                }
                if (scale == 0) {
                    w.print("i:{d}", .{coeff}) catch {};
                } else {
                    w.print("d:{d}:{d}", .{ coeff, scale }) catch {};
                }
                break :blk2;
            },
        }
    }
    return buf.toOwnedSlice(ally) catch &.{};
}

// Build canonical key for a row JSON string so that numerically equal values with different scales map identically.
fn canonicalRowKey(ally: std.mem.Allocator, row: []const u8) []const u8 {
    if (row.len < 2) return row; // fallback
    var idx: usize = 0;
    if (row[idx] == '{') idx += 1;
    var key_buf = std.ArrayList(u8).initCapacity(ally, 0) catch return row;
    const w = key_buf.writer(ally);
    var field_i: usize = 0;
    while (idx < row.len) : (idx += 1) {
        while (idx < row.len and (row[idx] == ' ' or row[idx] == ',')) idx += 1;
        if (idx >= row.len or row[idx] == '}') break;
        if (row[idx] != '"') break; // malformed
        idx += 1; // skip opening quote of key
        while (idx < row.len and row[idx] != '"') idx += 1; // skip key chars
        if (idx >= row.len) break;
        idx += 1; // skip closing quote
        while (idx < row.len and row[idx] != ':') idx += 1;
        if (idx >= row.len) break;
        idx += 1; // colon
        while (idx < row.len and row[idx] == ' ') idx += 1;
        if (idx >= row.len) break;
        if (field_i > 0) w.writeAll("|") catch {};
        const ch = row[idx];
        if (ch == 'n') { // null
            w.writeAll("n") catch {};
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else if (ch == '"') { // string
            idx += 1;
            const start = idx;
            while (idx < row.len and row[idx] != '"') idx += 1;
            const s = if (idx <= row.len) row[start..idx] else &.{};
            w.writeAll("s:") catch {};
            w.print("{d}:", .{s.len}) catch {};
            w.writeAll(s) catch {};
            if (idx < row.len) idx += 1;
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else {
            // number or bool token
            const startn = idx;
            var neg = false;
            if (row[idx] == '-') {
                neg = true;
                idx += 1;
            }
            var mantissa: i128 = 0;
            var saw_digit = false;
            while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                mantissa = mantissa * 10 + (row[idx] - '0');
                saw_digit = true;
            }
            var scale: u8 = 0;
            var is_dec = false;
            if (idx < row.len and row[idx] == '.') {
                is_dec = true;
                idx += 1;
                while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                    mantissa = mantissa * 10 + (row[idx] - '0');
                    scale += 1;
                    saw_digit = true;
                }
            }
            if (!saw_digit) {
                // bool token -> canonical as string
                var endtok = startn;
                while (endtok < row.len and row[endtok] != ',' and row[endtok] != '}') endtok += 1;
                const tok = row[startn..endtok];
                w.writeAll("s:") catch {};
                w.print("{d}:", .{tok.len}) catch {};
                w.writeAll(tok) catch {};
                idx = endtok;
            } else {
                if (neg) mantissa = -mantissa;
                if (is_dec) {
                    while (scale > 0 and @mod(mantissa, 10) == 0) : (scale -= 1) mantissa = @divTrunc(mantissa, 10);
                    if (scale == 0) {
                        // becomes int
                        w.writeAll("i:") catch {};
                        w.print("{d}", .{mantissa}) catch {};
                    } else {
                        w.writeAll("d:") catch {};
                        w.print("{d}:", .{mantissa}) catch {};
                        w.print("{d}", .{scale}) catch {};
                    }
                } else {
                    w.writeAll("i:") catch {};
                    w.print("{d}", .{mantissa}) catch {};
                }
            }
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        }
    }
    return key_buf.toOwnedSlice(ally) catch row;
}

fn buildAdditionalStatusesAlloc(ally: std.mem.Allocator, codes: []const diagnostics.Code, primary: diagnostics.Code) []const []const u8 {
    if (codes.len <= 1) return &.{};
    var extras = ally.alloc([]const u8, codes.len - 1) catch return &.{};
    var ei: usize = 0;
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        if (codes[i] == primary) continue;
        extras[ei] = diagnostics.codeName(codes[i]);
        ei += 1;
    }
    return extras[0..ei];
}

// Shared DISTINCT dedup helper: mutates rows_json in-place, frees removed row value slices when provided.
fn distinctDedup(ally: std.mem.Allocator, have_values: bool, value_arity: usize, rows_json: *std.ArrayList([]const u8), rows_values: *std.ArrayList([]const eval.Value), out_hash_size: ?*usize) void {
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    var out_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return;
    defer out_rows.deinit(ally);
    var alloc_keys = std.ArrayList([]const u8).initCapacity(ally, 0) catch return;
    defer {
        for (alloc_keys.items) |k| ally.free(k);
        alloc_keys.deinit(ally);
    }
    var idx: usize = 0;
    while (idx < rows_json.items.len) : (idx += 1) {
        const row = rows_json.items[idx];
        const key = if (have_values and idx < rows_values.items.len) canonicalValuesKey(ally, rows_values.items[idx][0..value_arity]) else canonicalRowKey(ally, row);
        if (!seen.contains(key)) {
            seen.put(key, {}) catch {};
            out_rows.append(ally, row) catch {};
            if (key.ptr != row.ptr) alloc_keys.append(ally, key) catch {};
        } else {
            ally.free(row);
            ally.free(key);
            if (have_values and idx < rows_values.items.len) ally.free(rows_values.items[idx]);
        }
    }
    const unique = seen.count();
    rows_json.clearRetainingCapacity();
    for (out_rows.items) |r| rows_json.append(ally, r) catch {};
    if (out_hash_size) |p| p.* = unique;
    if (have_values) {
        var vi: usize = 0;
        while (vi < rows_values.items.len) : (vi += 1) {
            if (vi < out_rows.items.len) ally.free(rows_values.items[vi]);
        }
    }
}

const AllocTracker = struct { ctx: *anyopaque, getFn: *const fn (*anyopaque) usize };

fn trackerGet(ctx: *anyopaque) usize {
    const T = @import("tracking_alloc").TrackingAllocator;
    const t: *T = @ptrCast(@alignCast(ctx));
    return t.net();
}

fn evaluateSimpleQuery(ally: std.mem.Allocator, q: geode.ast.Query, param_names: [][]const u8, param_matrix: [][]const eval.Value, ordered_meta: *bool, order_keys: *[][]const u8, cols_out: *[]const protocol.SchemaCol, timings: ?*StageTimings, eval_diag: ?*diagnostics.Code, alloc_tracker: ?AllocTracker) ![][]const u8 {
    // Build rows
    var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(ally);

    // Structured row arena (phase 1): only enabled when DISTINCT required so we can build canonical keys without reparsing JSON.
    const need_row_values = q.ret.distinct or (q.order_by != null); // future: GROUP BY, aggregation
    var rows_values = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch unreachable; // flattened; each slice length = q.ret.items.len
    defer if (need_row_values) rows_values.deinit(ally) else rows_values.deinit(ally); // always deinit; capacity small in tests.

    const t_start = if (timings) |_| std.time.nanoTimestamp() else 0;

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    // Capture per-row evaluation environments for later ORDER BY key evaluation.
    var envs = try ally.alloc(eval.Env, num_rows);
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        envs[r] = env;
        // Build JSON row
        var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        const w = buf.writer(ally);
        w.writeAll("{") catch {};
        var j: usize = 0;
        var row_vals: []eval.Value = &.{};
        if (need_row_values and q.ret.items.len > 0) {
            row_vals = try ally.alloc(eval.Value, q.ret.items.len);
        }
        while (j < q.ret.items.len) : (j += 1) {
            const it = q.ret.items[j];
            const alias = it.alias orelse blk: {
                const tmp = geode.printer.stringifyExprAlloc(ally, it.expr, .{}) catch "col";
                break :blk tmp;
            };
            const val = eval.evalExpr(ally, it.expr, env) catch |e| blk_evalerr: {
                if (eval_diag) |ed| {
                    if (diagnostics.mapEvalError(e)) |c| ed.* = c;
                }
                break :blk_evalerr eval.Value{ .Null = {} };
            };
            if (r == 0) cols[j] = .{ .name = alias, .type = valueTypeName(val) };
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\":", .{alias}) catch {};
            writeJsonValue(w, val) catch {};
            if (need_row_values) row_vals[j] = val;
        }
        w.writeAll("}") catch {};
        rows_json.append(ally, buf.toOwnedSlice(ally) catch "{}") catch {};
        if (need_row_values) rows_values.append(ally, row_vals) catch {};
    }

    if (timings) |tptr| {
        tptr.project_ns = std.time.nanoTimestamp() - t_start;
        tptr.project_rows_in = num_rows;
        tptr.project_rows_out = rows_json.items.len;
        tptr.expand_rows_in = num_rows; // stub: no expansion yet
        tptr.expand_rows_out = num_rows;
        // Accumulate bytes for project output
        var tb: usize = 0;
        for (rows_json.items) |s| tb += s.len;
        tptr.project_bytes_out = tb;
        tptr.project_bytes_alloc = if (alloc_tracker) |tr| tr.getFn(tr.ctx) else tb;
        tptr.expand_bytes_out = 0;
        tptr.expand_bytes_alloc = 0;
    }

    // Build column name -> index map (for ORDER BY identifier key fast path)
    var col_index = std.StringHashMap(usize).init(ally);
    defer col_index.deinit();
    var ci: usize = 0;
    while (ci < q.ret.items.len) : (ci += 1) {
        const cname = cols[ci].name;
        col_index.put(cname, ci) catch {};
    }

    // DISTINCT delta attribution baseline captured after project
    var alloc_after_project: usize = if (alloc_tracker) |trp| trp.getFn(trp.ctx) else 0;
    if (q.ret.distinct and rows_json.items.len > 1) {
        const t_d_start = if (timings) |_| std.time.nanoTimestamp() else 0;
        distinctDedup(ally, need_row_values, q.ret.items.len, &rows_json, &rows_values, null);
        if (timings) |tptr| {
            tptr.distinct_ns = std.time.nanoTimestamp() - t_d_start;
            tptr.distinct_rows_in = tptr.project_rows_out;
            tptr.distinct_rows_out = rows_json.items.len;
            var tb2: usize = 0;
            for (rows_json.items) |s| tb2 += s.len;
            tptr.distinct_bytes_out = tb2;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                tptr.distinct_bytes_alloc = after - alloc_after_project;
                alloc_after_project = after;
            } else tptr.distinct_bytes_alloc = tb2;
        }
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
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            // Flattened matrix: row-major [row * key_count + key]
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = ally.alloc(KeyVal, rows_json.items.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) ally.free(key_matrix);
            // For each row, re-evaluate each ORDER BY expression in the same environment used originally.
            // NOTE: For correctness with aliases/ordinals, planner already validated keys are simple identifiers/ordinals.
            var row_index: usize = 0;
            while (row_index < rows_json.items.len) : (row_index += 1) {
                // Reconstruct evaluation environment identical to projection (params only in current prototype).
                var key_i: usize = 0;
                while (key_i < key_count) : (key_i += 1) {
                    const key_expr = ob.keys[key_i].expr;
                    var val: eval.Value = .{ .Null = {} };
                    if (need_row_values and key_expr == .Ident) {
                        if (col_index.get(key_expr.Ident)) |colpos| {
                            if (row_index < rows_values.items.len) {
                                const rv = rows_values.items[row_index];
                                if (colpos < rv.len) val = rv[colpos];
                            }
                        } else {
                            val = eval.evalExpr(ally, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                        }
                    } else {
                        val = eval.evalExpr(ally, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                    }
                    const slot_index = row_index * key_count + key_i;
                    key_matrix[slot_index] = switch (val) {
                        .Null => KeyVal{ .kind = .Null },
                        .Int => |iv| KeyVal{ .kind = .Int, .mantissa = iv },
                        .Decimal => |d| KeyVal{ .kind = .Dec, .mantissa = d.coeff, .scale = d.scale },
                        .Str => |s| KeyVal{ .kind = .Str, .str = s },
                        .Bool => |b| KeyVal{ .kind = .Str, .str = if (b) "true" else "false" },
                    };
                }
            }
            const Ctx = struct {
                rows: [][]const u8,
                ob: *const @TypeOf(ob),
                keys: []KeyVal,
                key_count: usize,
                fn cmpNumeric(a: KeyVal, b: KeyVal) i2 {
                    if (a.kind == .Int and b.kind == .Int) {
                        if (a.mantissa < b.mantissa) return -1;
                        if (a.mantissa > b.mantissa) return 1;
                        return 0;
                    }
                    var ma = a.mantissa;
                    var mb = b.mantissa;
                    var ascale: u8 = if (a.kind == .Dec) a.scale else 0;
                    var bscale: u8 = if (b.kind == .Dec) b.scale else 0;
                    if (ascale > 0 and a.kind == .Dec) {
                        while (ascale > 0 and @mod(ma, 10) == 0) : (ascale -= 1) {
                            ma = @divTrunc(ma, 10);
                        }
                    }
                    if (bscale > 0 and b.kind == .Dec) {
                        while (bscale > 0 and @mod(mb, 10) == 0) : (bscale -= 1) {
                            mb = @divTrunc(mb, 10);
                        }
                    }
                    if (ascale == bscale) {
                        if (ma < mb) return -1;
                        if (ma > mb) return 1;
                        return 0;
                    }
                    if (ascale < bscale) {
                        var diff = bscale - ascale;
                        while (diff > 0) : (diff -= 1) ma *= 10;
                    } else {
                        var diff = ascale - bscale;
                        while (diff > 0) : (diff -= 1) mb *= 10;
                    }
                    if (ma < mb) return -1;
                    if (ma > mb) return 1;
                    return 0;
                }
            };
            std.sort.block([]const u8, rows_json.items, Ctx{ .rows = rows_json.items, .ob = &ob, .keys = key_matrix, .key_count = key_count }, struct {
                fn less(c: Ctx, a: []const u8, b: []const u8) bool {
                    var ai: usize = 0;
                    var bi: usize = 0;
                    while (ai < c.rows.len and !std.mem.eql(u8, c.rows[ai], a)) : (ai += 1) {}
                    while (bi < c.rows.len and !std.mem.eql(u8, c.rows[bi], b)) : (bi += 1) {}
                    var ki: usize = 0;
                    while (ki < c.ob.keys.len) : (ki += 1) {
                        const key_expr = c.ob.keys[ki];
                        const av = c.keys[ai * c.key_count + ki];
                        const bv = c.keys[bi * c.key_count + ki];
                        if (av.kind == .Null and bv.kind != .Null) {
                            if (g_nulls_last) {
                                // Nulls last: treat av > bv
                                if (key_expr.desc) return true; // descending: larger first -> null considered largest
                                return false; // ascending: null goes after non-null
                            } else {
                                // Nulls first (default)
                                return !key_expr.desc;
                            }
                        }
                        if (bv.kind == .Null and av.kind != .Null) {
                            if (g_nulls_last) {
                                // Nulls last: bv is null so av < bv
                                if (key_expr.desc) return false; // descending: larger first, null last so av < bv -> false
                                return true; // ascending: av < bv -> true
                            } else {
                                return key_expr.desc;
                            }
                        }
                        var ord: i2 = 0;
                        switch (av.kind) {
                            .Null => ord = 0,
                            .Str => ord = blk: {
                                if (bv.kind == .Str) {
                                    if (std.mem.lessThan(u8, av.str, bv.str)) break :blk -1;
                                    if (std.mem.lessThan(u8, bv.str, av.str)) break :blk 1;
                                    break :blk 0;
                                } else break :blk 1; // strings after numbers
                            },
                            .Int, .Dec => ord = blk: {
                                switch (bv.kind) {
                                    .Int, .Dec => break :blk Ctx.cmpNumeric(av, bv),
                                    .Str => break :blk -1,
                                    .Null => break :blk 1,
                                }
                            },
                        }
                        if (ord != 0) return if (key_expr.desc) ord > 0 else ord < 0;
                    }
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            if (timings) |tptr| {
                tptr.sort_ns = std.time.nanoTimestamp() - t_sort_start;
                tptr.sort_rows_in = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
                tptr.sort_rows_out = rows_json.items.len;
                var tbs: usize = 0;
                for (rows_json.items) |s| tbs += s.len;
                tptr.sort_bytes_out = tbs;
                if (alloc_tracker) |tr| {
                    const after = tr.getFn(tr.ctx);
                    tptr.sort_bytes_alloc = after - alloc_after_project;
                    alloc_after_project = after;
                } else tptr.sort_bytes_alloc = tbs;
            }
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
        if (timings) |tptr| {
            tptr.offset_ns = std.time.nanoTimestamp() - t_offset_start;
            tptr.offset_rows_in = if (tptr.sort_rows_out != 0) tptr.sort_rows_out else if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
            tptr.offset_rows_out = if (off < rows_json.items.len) rows_json.items.len - off else 0;
            var tbo: usize = 0;
            if (tptr.offset_rows_out > 0) {
                var si: usize = start;
                while (si < rows_json.items.len) : (si += 1) tbo += rows_json.items[si].len;
            }
            tptr.offset_bytes_out = tbo;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                tptr.offset_bytes_alloc = after - alloc_after_project;
                alloc_after_project = after;
            } else tptr.offset_bytes_alloc = tbo;
        }
    }
    var end: usize = rows_json.items.len;
    var t_limit_start: i128 = 0;
    if (q.limit) |lim| {
        if (timings) |_| t_limit_start = std.time.nanoTimestamp();
        if (start + lim < end) end = start + lim;
        if (timings) |tptr| {
            tptr.limit_ns = std.time.nanoTimestamp() - t_limit_start;
            tptr.limit_rows_in = if (tptr.offset_rows_out != 0) tptr.offset_rows_out else if (tptr.sort_rows_out != 0) tptr.sort_rows_out else tptr.project_rows_out;
            const effective = if (start + lim < rows_json.items.len) lim else rows_json.items.len - start;
            tptr.limit_rows_out = effective;
            var tbl: usize = 0;
            var li: usize = start;
            const end_calc = start + effective;
            while (li < end_calc and li < rows_json.items.len) : (li += 1) tbl += rows_json.items[li].len;
            tptr.limit_bytes_out = tbl;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                tptr.limit_bytes_alloc = after - alloc_after_project;
                alloc_after_project = after;
            } else tptr.limit_bytes_alloc = tbl;
        }
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

    // If some phases not executed, propagate previous row counts for clarity
    if (timings) |tptr| {
        if (tptr.distinct_rows_out == 0) tptr.distinct_rows_out = tptr.project_rows_out;
        if (tptr.expand_rows_out == 0) tptr.expand_rows_out = tptr.project_rows_in;
        if (tptr.sort_rows_out == 0) tptr.sort_rows_out = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
        if (tptr.offset_rows_out == 0) tptr.offset_rows_out = tptr.sort_rows_out;
        if (tptr.limit_rows_out == 0) tptr.limit_rows_out = if (q.limit != null) @min(rows_json.items.len, tptr.offset_rows_out) else rows_json.items.len;
        if (tptr.distinct_rows_in == 0) tptr.distinct_rows_in = tptr.project_rows_out;
        if (tptr.expand_rows_in == 0) tptr.expand_rows_in = tptr.expand_rows_out;
        if (tptr.sort_rows_in == 0) tptr.sort_rows_in = tptr.distinct_rows_out;
        if (tptr.offset_rows_in == 0) tptr.offset_rows_in = tptr.sort_rows_out;
        if (tptr.limit_rows_in == 0) tptr.limit_rows_in = tptr.offset_rows_out;
        if (tptr.distinct_bytes_out == 0) tptr.distinct_bytes_out = tptr.project_bytes_out;
        if (tptr.expand_bytes_out == 0) tptr.expand_bytes_out = 0;
        if (tptr.sort_bytes_out == 0) tptr.sort_bytes_out = tptr.distinct_bytes_out;
        if (tptr.offset_bytes_out == 0) tptr.offset_bytes_out = tptr.sort_bytes_out;
        if (tptr.limit_bytes_out == 0) tptr.limit_bytes_out = if (q.limit != null) tptr.limit_bytes_out else tptr.offset_bytes_out;
        if (tptr.distinct_bytes_alloc == 0) tptr.distinct_bytes_alloc = tptr.project_bytes_alloc;
        if (tptr.expand_bytes_alloc == 0) tptr.expand_bytes_alloc = 0;
        if (tptr.sort_bytes_alloc == 0) tptr.sort_bytes_alloc = tptr.distinct_bytes_alloc;
        if (tptr.offset_bytes_alloc == 0) tptr.offset_bytes_alloc = tptr.sort_bytes_alloc;
        if (tptr.limit_bytes_alloc == 0) tptr.limit_bytes_alloc = if (q.limit != null) tptr.limit_bytes_alloc else tptr.offset_bytes_alloc;
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(ally) catch &.{};
}

fn evaluateUnion(ally: std.mem.Allocator, u: geode.ast.UnionQuery, param_names: [][]const u8, param_matrix: [][]const eval.Value, union_mode_out: *[]const u8, metrics: *UnionMetrics) ![][]const u8 {
    // Evaluate each component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols, null, null, null);
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
        const rows = try evaluateSimpleQuery(ally, part.query, param_names, param_matrix, &ordered, &order_keys, &oc, null, null, null);
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
    if (all_rows.items.len <= 1) {
        metrics.out = all_rows.items.len;
        metrics.hash_size = all_rows.items.len;
        return all_rows.toOwnedSlice(ally) catch &.{};
    }
    // Reuse shared helper directly on all_rows (in-place). We pass a dummy values list.
    var dummy_vals = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer dummy_vals.deinit(ally);
    var hash_size: usize = 0;
    distinctDedup(ally, false, 0, &all_rows, &dummy_vals, &hash_size);
    metrics.out = all_rows.items.len;
    metrics.hash_size = hash_size;
    return all_rows.toOwnedSlice(ally) catch &.{};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    // Parse server CLI args for optional result format.
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var result_format_txt = false;
    var disable_estimates = false;
    var compact_profile = false;
    var memcurve_profile = false;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--result-format") and ai + 1 < args.len) {
            const f = args[ai + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) result_format_txt = true;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--no-estimates")) {
            disable_estimates = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-compact")) {
            compact_profile = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-memcurve")) {
            memcurve_profile = true;
        }
    }
    var state = ServerState{ .allocator = gpa };
    // Read environment once for spill simulation flags.
    if (std.process.getEnvMap(gpa)) |*env_ptr| {
        var env = env_ptr.*; // make mutable copy handle
        defer env.deinit();
        if (env.get("GEODE_FORCE_SORT_SPILL")) |_| state.spill_sort = 1;
        if (env.get("GEODE_FORCE_DISTINCT_SPILL")) |_| state.spill_distinct = 1;
        if (env.get("GEODE_FORCE_UNION_SPILL")) |_| state.spill_union = 1;
        if (env.get("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
            state.spill_threshold = std.fmt.parseInt(usize, th, 10) catch 0;
        }
        if (env.get("GEODE_NULLS_LAST")) |_| {
            g_nulls_last = true;
        }
    } else |_| {}
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [8192]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    // (Removed buffered writer; direct file writes used.)
    var line_storage: [65536]u8 = undefined;

    // Robust line loop: handle EOF with partial line, ignore blank lines, no spin.
    while (true) {
        var read_len: usize = 0;
        var got_newline = false;
        while (!got_newline and read_len < line_storage.len) {
            var one: [1]u8 = undefined;
            const amt = stdin.read(&one) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (amt == 0) break; // EOF or error
            const b = one[0];
            if (b == '\n') {
                got_newline = true;
                break;
            }
            line_storage[read_len] = b;
            read_len += 1;
        }
        if (read_len == 0) {
            // No bytes collected. If we didn't get a newline and next read is EOF, terminate.
            // Attempt a single probe read to distinguish between blank line and EOF.
            var probe: [1]u8 = undefined;
            const probe_amt = stdin.read(&probe) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (probe_amt == 0) break; // real EOF
            if (probe[0] == '\n') continue; // blank line
            // Start new line with probe byte.
            line_storage[0] = probe[0];
            read_len = 1;
            // Continue filling remainder of line until newline/EOF.
            while (read_len < line_storage.len) {
                var nxt: [1]u8 = undefined;
                const na = stdin.read(&nxt) catch |e| switch (e) {
                    error.EndOfStream => 0,
                    else => 0,
                };
                if (na == 0) break;
                if (nxt[0] == '\n') break;
                line_storage[read_len] = nxt[0];
                read_len += 1;
            }
        }
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue; // ignore
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {},
            .BEGIN => |_| {
                if (state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "already in transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                } else {
                    state.in_txn = true;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .COMMIT => |_| {
                if (!state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "no active transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .ROLLBACK => |_| {
                if (!state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "no active transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
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
                if (std.mem.startsWith(u8, text, "PROFILE ")) {
                    profile_mode = true;
                    text = text[8..];
                }
                if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                    explain_mode = true;
                    text = text[8..];
                }

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                    // Aggregate all parse-time diagnostics (policy + US001) and emit with precedence.
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, @errorName(e), &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        // Fallback: treat as IllegalOrderKey for now to satisfy existing tests.
                        writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                        return;
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) @errorName(e) else diagnostics.defaultMessage(primary);
                    writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        var codes_buf: [4]diagnostics.Code = undefined;
                        const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                        const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                        if (n == 0) {
                            if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const primary = codes_buf[0];
                        const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                        const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                        writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
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
                                        var codes_buf_pl: [4]diagnostics.Code = undefined;
                                        const n_codes_pl_raw = collectPlannerDiagnostics(q, code, &codes_buf_pl);
                                        const n_codes_pl = diagnostics.foldCodes(codes_buf_pl[0..n_codes_pl_raw]);
                                        const primary_pl = if (n_codes_pl > 0) codes_buf_pl[0] else code;
                                        const add_slice_pl = buildAdditionalStatusesAlloc(gpa, codes_buf_pl[0..n_codes_pl], primary_pl);
                                        const pmsg = diagnostics.defaultMessage(primary_pl);
                                        writeErrorWithFlags(gpa, stdout_file, primary_pl, pmsg, diagnostics.anchorFor(primary_pl), add_slice_pl, primary_pl == .US001);
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
                                    // PROFILE mode: we stage PROFILE json and emit SCHEMA now; PROFILE frame on first PULL.
                                    const start_time = std.time.nanoTimestamp();
                                    // Counting allocator wrapper for profiling.
                                    var track = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track.init(gpa);
                                    const prof_ally = track.allocator;
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(prof_ally, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols_mut: []protocol.SchemaCol = &.{}; // mutable during build
                                    var cols: []const protocol.SchemaCol = &.{}; // const view stored in state
                                    var timings: StageTimings = .{};
                                    var row_count: usize = 0;
                                    if (q.group_by != null) {
                                        var agg_timings: exec.AggStageTimings = .{};
                                        // Derive aggregate input rows from parameter bindings (each param row treated as one logical input row)
                                        const agg_in = if (param_rows.len > 0) param_rows.len else 1;
                                        // Build placeholder input_rows slice of empty value arrays (expressions reference params only in this prototype)
                                        var input_rows_placeholder = try prof_ally.alloc([]eval.Value, agg_in);
                                        var ipi: usize = 0;
                                        while (ipi < agg_in) : (ipi += 1) input_rows_placeholder[ipi] = &.{};
                                        const first_param_values: []const eval.Value = if (param_rows.len > 0) param_rows[0] else &.{};
                                        const input_rows_const: []const []eval.Value = input_rows_placeholder;
                                        const g_out = exec.runGroupedQuery(prof_ally, q, &.{}, input_rows_const, param_names, first_param_values, &agg_timings) catch &.{};
                                        row_count = g_out.len;
                                        timings.agg_rows_in = agg_in;
                                        timings.agg_rows_out = row_count;
                                        timings.project_rows_in = row_count;
                                        timings.project_rows_out = row_count;
                                        timings.agg_build_ns = agg_timings.build_ns;
                                        timings.agg_emit_ns = agg_timings.emit_ns;
                                        // Build synthetic columns from RETURN items
                                        var mut_cols_slice: []protocol.SchemaCol = prof_ally.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                        var idx_fill: usize = 0;
                                        while (idx_fill < q.ret.items.len) : (idx_fill += 1) {
                                            const it2 = q.ret.items[idx_fill];
                                            const alias2 = it2.alias orelse geode.printer.stringifyExprAlloc(prof_ally, it2.expr, .{}) catch "col";
                                            mut_cols_slice[idx_fill] = .{ .name = alias2, .type = "INT" };
                                        }
                                        // Approximate bytes_out for aggregate/project by creating minimal JSON row strings
                                        // (We don't retain them; only measure.)
                                        var rb: usize = 0;
                                        rb = row_count * 2; // braces overhead approx
                                        // Each column adds alias + constant small value (8 chars avg heuristic). This is a coarse metric.
                                        rb += row_count * q.ret.items.len * 8;
                                        timings.project_bytes_out = rb;
                                        timings.distinct_bytes_out = rb;
                                        timings.sort_bytes_out = rb;
                                        timings.offset_bytes_out = rb;
                                        timings.limit_bytes_out = rb;
                                        // Placeholder; actual allocation deltas captured below after build/emit phases
                                        timings.project_bytes_alloc = rb;
                                        timings.distinct_bytes_alloc = rb;
                                        timings.sort_bytes_alloc = rb;
                                        timings.offset_bytes_alloc = rb;
                                        timings.limit_bytes_alloc = rb;
                                        cols_mut = mut_cols_slice;
                                        cols = cols_mut;
                                        // Delta-based allocation: capture after aggregate build+emit (no separate row materialization phases yet)
                                        const alloc_after_build = track.net();
                                        timings.agg_build_bytes_alloc = alloc_after_build; // build delta (since start)
                                        // Emit phase currently trivial for prototype; treat emit alloc delta as zero additional unless net grows later
                                        const alloc_after_emit = track.net();
                                        timings.agg_emit_bytes_alloc = if (alloc_after_emit > alloc_after_build) alloc_after_emit - alloc_after_build else 0;
                                        const total_after_agg = alloc_after_emit;
                                        timings.project_bytes_alloc = if (timings.project_bytes_alloc == 0) total_after_agg else timings.project_bytes_alloc;
                                    } else {
                                        var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                        const at: AllocTracker = .{ .ctx = @ptrCast(&track), .getFn = trackerGet };
                                        const rows_prof = evaluateSimpleQuery(prof_ally, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, &timings, &run_code, at) catch &.{};
                                        if (run_code == .TypeMismatch) {
                                            var buf_codes: [2]diagnostics.Code = undefined;
                                            var len_codes: usize = 0;
                                            buf_codes[len_codes] = .TypeMismatch;
                                            len_codes += 1;
                                            if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                                buf_codes[len_codes] = .US001;
                                                len_codes += 1;
                                            }
                                            const slice_codes = buf_codes[0..len_codes];
                                            const folded_len = diagnostics.foldCodes(slice_codes);
                                            const primary_eval = slice_codes[0];
                                            const add_eval = buildAdditionalStatusesAlloc(gpa, slice_codes[0..folded_len], primary_eval);
                                            var has_us001_any = primary_eval == .US001;
                                            if (!has_us001_any) {
                                                var ci: usize = 1;
                                                while (ci < folded_len) : (ci += 1) {
                                                    if (slice_codes[ci] == .US001) {
                                                        has_us001_any = true;
                                                        break;
                                                    }
                                                }
                                            }
                                            writeErrorWithFlags(gpa, stdout_file, primary_eval, diagnostics.defaultMessage(primary_eval), diagnostics.anchorFor(primary_eval), add_eval, has_us001_any);
                                            var fre: usize = 0;
                                            while (fre < rows_prof.len) : (fre += 1) gpa.free(rows_prof[fre]);
                                            continue;
                                        }
                                        row_count = rows_prof.len;
                                        if (timings.project_rows_out == 0) {
                                            // Fallback (should not trigger unless evaluateSimpleQuery skipped metrics)
                                            timings.project_rows_in = row_count;
                                            timings.project_rows_out = row_count;
                                            timings.distinct_rows_in = timings.project_rows_out;
                                            timings.distinct_rows_out = timings.project_rows_out;
                                            timings.sort_rows_in = timings.distinct_rows_out;
                                            timings.sort_rows_out = timings.distinct_rows_out;
                                            timings.offset_rows_in = timings.sort_rows_out;
                                            timings.offset_rows_out = if (q.offset) |offv| if (offv < timings.sort_rows_out) timings.sort_rows_out - offv else 0 else timings.sort_rows_out;
                                            timings.limit_rows_in = timings.offset_rows_out;
                                            timings.limit_rows_out = if (q.limit) |limv| if (limv < timings.offset_rows_out) limv else timings.offset_rows_out else timings.offset_rows_out;
                                        }
                                        // Free rows; PROFILE does not return them
                                        var frp: usize = 0;
                                        while (frp < rows_prof.len) : (frp += 1) prof_ally.free(rows_prof[frp]);
                                        // After evaluateSimpleQuery we can snapshot bytes for distinct/sort/offset/limit based on timings ordering.
                                        const alloc_after_project = track.net();
                                        if (timings.project_bytes_alloc == 0) timings.project_bytes_alloc = alloc_after_project; // baseline
                                        // Heuristic attribution: since we free nothing yet, additional growth after each stage boundary approximated by bytes_out delta.
                                        // For now treat all later stage alloc equal to net usage (will refine once stage-level alloc hooks added).
                                        timings.distinct_bytes_alloc = timings.distinct_bytes_out;
                                        timings.sort_bytes_alloc = timings.sort_bytes_out;
                                        timings.offset_bytes_alloc = timings.offset_bytes_out;
                                        timings.limit_bytes_alloc = timings.limit_bytes_out;
                                    }
                                    const total_ns: i128 = std.time.nanoTimestamp() - start_time;
                                    // net_alloc skipped (counting allocator not active)
                                    // Replace heuristic bytes_alloc metrics with net allocations at time of each stage end if captured.
                                    // For now we approximate by proportionally distributing total peak across stages that produced bytes_out.
                                    // bytes_alloc remain heuristic (mirrors bytes_out) until counting allocator lands.
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"profile_version\":1,\"ops\":[") catch {};
                                    var first_op_profile = true;
                                    const peak_bytes: usize = track.peakBytes();
                                    if (state.spill_threshold > 0 and peak_bytes >= state.spill_threshold) {
                                        if (ordered_meta) state.spill_sort = 1;
                                        if (q.ret.distinct) state.spill_distinct = 1;
                                    }
                                    const emit = struct {
                                        const TopTracker = struct { names: [3][24]u8 = .{ [_]u8{0} ** 24, [_]u8{0} ** 24, [_]u8{0} ** 24 }, lens: [3]usize = .{ 0, 0, 0 }, vals: [3]usize = .{ 0, 0, 0 } };
                                        fn maybeRecord(tt: *TopTracker, name: []const u8, val: usize) void {
                                            var min_i: usize = 0;
                                            var min_v: usize = tt.vals[0];
                                            var i: usize = 1;
                                            while (i < 3) : (i += 1) {
                                                if (tt.vals[i] < min_v) {
                                                    min_v = tt.vals[i];
                                                    min_i = i;
                                                }
                                            }
                                            if (val > min_v) {
                                                const copy_len = if (name.len < tt.names[min_i].len) name.len else tt.names[min_i].len;
                                                std.mem.copyForwards(u8, tt.names[min_i][0..copy_len], name[0..copy_len]);
                                                tt.lens[min_i] = copy_len;
                                                tt.vals[min_i] = val;
                                            }
                                        }
                                        fn op(
                                            wr: anytype,
                                            tt: *TopTracker,
                                            op_index: *usize,
                                            cum_time: *i128,
                                            prev_net: *usize,
                                            net_after_sum: *usize,
                                            first_ptr: *bool,
                                            error_min_pct: *usize,
                                            error_max_pct: *usize,
                                            error_sum_pct: *usize,
                                            error_count: *usize,
                                            name: []const u8,
                                            in_rows: usize,
                                            out_rows: usize,
                                            time_ns: i128,
                                            bytes_out: usize,
                                            bytes_alloc: usize,
                                            est_bytes: usize,
                                            peak_total: usize,
                                            net_total: usize,
                                            compact: bool,
                                        ) void {
                                            if (first_ptr.*) wr.writeAll("{") catch {} else wr.writeAll(",{") catch {};
                                            wr.writeAll("\"op\":\"") catch {};
                                            wr.writeAll(name) catch {};
                                            // Derive phase from op name (stable mapping, additive field)
                                            const phase = if (std.mem.eql(u8, name, "NodeScan")) "SCAN" else if (std.mem.eql(u8, name, "Expand")) "EXPAND" else if (std.mem.eql(u8, name, "AggregateBuild") or std.mem.eql(u8, name, "AggregateEmit")) "AGGREGATE" else if (std.mem.eql(u8, name, "Project")) "PROJECT" else if (std.mem.eql(u8, name, "Distinct")) "DISTINCT" else if (std.mem.eql(u8, name, "Sort")) "ORDER" else if (std.mem.eql(u8, name, "Offset") or std.mem.eql(u8, name, "Limit")) "PAGE" else "OTHER";
                                            wr.writeAll("\",\"phase\":\"") catch {};
                                            wr.writeAll(phase) catch {};
                                            // Emit stable id field (alias op_index for v1)
                                            wr.writeAll(",\"id\":") catch {};
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll(",\"op_index\":") catch {}; // legacy field retained
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll("\",\"input_rows\":") catch {};
                                            wr.print("{d}", .{in_rows}) catch {};
                                            wr.writeAll(",\"rows\":") catch {};
                                            wr.print("{d}", .{out_rows}) catch {};
                                            wr.writeAll(",\"time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            // Placeholder cpu_time_ns (single-threaded prototype): equal to time_ns; future: process CPU diff attribution.
                                            wr.writeAll(",\"cpu_time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            wr.writeAll(",\"bytes_out\":") catch {};
                                            wr.print("{d}", .{bytes_out}) catch {};
                                            wr.writeAll(",\"bytes_alloc\":") catch {};
                                            wr.print("{d}", .{bytes_alloc}) catch {};
                                            if (!compact or est_bytes != 0) {
                                                wr.writeAll(",\"estimate_bytes\":") catch {};
                                                wr.print("{d}", .{est_bytes}) catch {};
                                            }
                                            const estimate_vs_actual: usize = if (est_bytes > 0 and bytes_alloc > 0) (bytes_alloc * 100) / est_bytes else 0;
                                            if (!compact or estimate_vs_actual != 0) {
                                                wr.writeAll(",\"estimate_vs_actual\":") catch {};
                                                wr.print("{d}", .{estimate_vs_actual}) catch {};
                                            }
                                            // percent_peak = allocation share of peak (delta attribution already applied to bytes_alloc)
                                            const percent_peak: usize = if (peak_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / peak_total else 0;
                                            if (!compact or percent_peak != 0) {
                                                wr.writeAll(",\"percent_peak\":") catch {};
                                                wr.print("{d}", .{percent_peak}) catch {};
                                            }
                                            const percent_net: usize = if (net_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / net_total else 0;
                                            if (!compact or percent_net != 0) {
                                                wr.writeAll(",\"percent_net\":") catch {};
                                                wr.print("{d}", .{percent_net}) catch {};
                                            }
                                            cum_time.* += time_ns;
                                            wr.writeAll(",\"cumulative_time_ns\":") catch {};
                                            wr.print("{d}", .{cum_time.*}) catch {};
                                            // freed_bytes & net_after_op tracking
                                            const net_after = net_total;
                                            const freed_bytes: usize = if (net_after < prev_net.*) prev_net.* - net_after else 0;
                                            if (!compact or freed_bytes != 0) {
                                                wr.writeAll(",\"freed_bytes\":") catch {};
                                                wr.print("{d}", .{freed_bytes}) catch {};
                                            }
                                            wr.writeAll(",\"net_after_op\":") catch {};
                                            wr.print("{d}", .{net_after}) catch {};
                                            prev_net.* = net_after;
                                            if (est_bytes > 0) net_after_sum.* += est_bytes;
                                            if (est_bytes > 0) {
                                                // error metrics
                                                const err_abs: isize = @as(isize, @intCast(bytes_alloc)) - @as(isize, @intCast(est_bytes));
                                                const err_bytes: usize = if (err_abs < 0) @intCast(-err_abs) else @intCast(err_abs);
                                                const err_pct: usize = if (est_bytes > 0 and err_bytes > 0) (err_bytes * 100) / est_bytes else 0;
                                                if (!compact or err_bytes != 0) {
                                                    wr.writeAll(",\"error_bytes\":") catch {};
                                                    wr.print("{d}", .{err_bytes}) catch {};
                                                }
                                                if (!compact or err_pct != 0) {
                                                    wr.writeAll(",\"error_abs_pct\":") catch {};
                                                    wr.print("{d}", .{err_pct}) catch {};
                                                }
                                                if (error_count.* == 0 or err_pct < error_min_pct.*) error_min_pct.* = err_pct;
                                                if (err_pct > error_max_pct.*) error_max_pct.* = err_pct;
                                                error_sum_pct.* += err_pct;
                                                error_count.* += 1;
                                            } else {
                                                if (!compact) wr.writeAll(",\"error_bytes\":0,\"error_abs_pct\":0") catch {};
                                            }
                                            op_index.* += 1;
                                            wr.writeAll("}") catch {};
                                            if (bytes_alloc > 0) maybeRecord(tt, name, bytes_alloc);
                                            first_ptr.* = false;
                                        }
                                    };
                                    var top_tracker: emit.TopTracker = .{};
                                    var cumulative_time_ns: i128 = 0;
                                    var prev_net_after: usize = 0;
                                    var sum_estimated: usize = 0;
                                    var sum_actual_estimated: usize = 0; // accumulate bytes_alloc for stages with estimates
                                    var op_index_counter: usize = 0;
                                    var err_min_pct: usize = 0;
                                    var err_max_pct: usize = 0;
                                    var err_sum_pct: usize = 0;
                                    var err_count: usize = 0;
                                    var op_index_distinct: ?usize = null;
                                    var op_index_sort: ?usize = null;
                                    var mem_curve_builder = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    defer mem_curve_builder.deinit(gpa);
                                    const MemCurve = struct {
                                        fn append(mc_alloc: std.mem.Allocator, b: *std.ArrayList(u8), op_index: usize, net_after: usize) void {
                                            var wmc = b.writer(mc_alloc);
                                            if (b.items.len == 0) {
                                                wmc.print("{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            } else {
                                                wmc.print(",{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            }
                                        }
                                    };
                                    // Allocate a synthetic scratch slab to demonstrate freed_bytes attribution.
                                    // We free it just before Sort emission (if ordering present) so freed_bytes appears on Sort stage.
                                    var scratch_slab: ?[]u8 = null;
                                    if (timings.project_rows_out > 0) {
                                        const slab_size = timings.project_rows_out * 16; // heuristic
                                        scratch_slab = prof_ally.alloc(u8, slab_size) catch null;
                                    }
                                    if (q.group_by != null) {
                                        const net_now = track.net();
                                        const est_build = if (disable_estimates) 0 else timings.agg_rows_in * 32;
                                        const est_emit = if (disable_estimates) 0 else timings.agg_rows_out * 16;
                                        const agg_build_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "AggregateBuild", timings.agg_rows_in, timings.agg_rows_out, timings.agg_build_ns, timings.project_bytes_out, timings.agg_build_bytes_alloc, est_build, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_build_idx, net_now);
                                        if (est_build > 0) sum_actual_estimated += timings.agg_build_bytes_alloc;
                                        const agg_emit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "AggregateEmit", timings.agg_rows_out, timings.agg_rows_out, timings.agg_emit_ns, timings.project_bytes_out, timings.agg_emit_bytes_alloc, est_emit, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_emit_idx, net_now);
                                        if (est_emit > 0) sum_actual_estimated += timings.agg_emit_bytes_alloc;
                                    }
                                    const net_post_group = track.net();
                                    // Insert synthetic NodeScan stage for simple queries (placeholder until real scans implemented)
                                    if (timings.project_rows_out > 0) {
                                        const est_nodescan = if (disable_estimates) 0 else timings.project_rows_out * 4; // small per-row placeholder
                                        const nodescan_idx = op_index_counter;
                                        const net_nodescan = track.net();
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "NodeScan", timings.project_rows_in, timings.project_rows_in, 0, 0, 0, est_nodescan, peak_bytes, net_nodescan, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, nodescan_idx, net_nodescan);
                                        if (est_nodescan > 0) sum_actual_estimated += 0;
                                        const est_expand = if (disable_estimates) 0 else timings.expand_rows_out * 8;
                                        const expand_idx = op_index_counter;
                                        const net_expand = track.net();
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Expand", timings.expand_rows_in, timings.expand_rows_out, timings.expand_ns, timings.expand_bytes_out, timings.expand_bytes_alloc, est_expand, peak_bytes, net_expand, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, expand_idx, net_expand);
                                        if (est_expand > 0) sum_actual_estimated += timings.expand_bytes_alloc;
                                    }
                                    const est_project = if (disable_estimates) 0 else timings.project_rows_out * 8;
                                    const project_idx = op_index_counter;
                                    emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc, est_project, peak_bytes, net_post_group, compact_profile);
                                    if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, project_idx, net_post_group);
                                    if (est_project > 0) sum_actual_estimated += timings.project_bytes_alloc;
                                    if (q.ret.distinct) {
                                        const est_distinct = if (disable_estimates) 0 else timings.distinct_rows_in * 24;
                                        op_index_distinct = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out, est_distinct, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_distinct.?, net_post_group);
                                        if (est_distinct > 0) sum_actual_estimated += if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out;
                                    }
                                    if (ordered_meta) {
                                        // Free scratch slab just before capturing Sort stage net to register freed_bytes on Sort.
                                        if (scratch_slab) |slab| {
                                            prof_ally.free(slab);
                                            scratch_slab = null;
                                        }
                                        const est_sort = if (disable_estimates) 0 else timings.sort_rows_in * 16;
                                        op_index_sort = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out, est_sort, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_sort.?, net_post_group);
                                        if (est_sort > 0) sum_actual_estimated += if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out;
                                    }
                                    if (q.offset != null) {
                                        const offset_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, if (timings.offset_bytes_alloc != 0) timings.offset_bytes_alloc else timings.offset_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, offset_idx, net_post_group);
                                    }
                                    if (q.limit != null) {
                                        const limit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_count, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, if (timings.limit_bytes_alloc != 0) timings.limit_bytes_alloc else timings.limit_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, limit_idx, net_post_group);
                                    }
                                    // If scratch not freed due to no sort stage, free now (freed_bytes will not appear in that case).
                                    if (scratch_slab) |slab2| prof_ally.free(slab2);
                                    // Emit peak_contributors array (filter zero entries, sort descending)
                                    // Simple selection sort of top_tracker arrays
                                    // Build temporary indices
                                    var order_idx: [3]usize = .{ 0, 1, 2 };
                                    var oi: usize = 0;
                                    while (oi < 3) : (oi += 1) {
                                        var oj: usize = oi + 1;
                                        while (oj < 3) : (oj += 1) {
                                            if (top_tracker.vals[oj] > top_tracker.vals[order_idx[oi]]) {
                                                const tmp = order_idx[oi];
                                                order_idx[oi] = oj;
                                                order_idx[oj] = tmp;
                                            }
                                        }
                                    }
                                    w.writeAll(",\"peak_contributors\":[") catch {};
                                    var pc_first = true;
                                    var pci: usize = 0;
                                    while (pci < 3) : (pci += 1) {
                                        const idx = order_idx[pci];
                                        if (top_tracker.vals[idx] == 0 or top_tracker.lens[idx] == 0) continue;
                                        if (!pc_first) w.writeAll(",") catch {} else pc_first = false;
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(top_tracker.names[idx][0..top_tracker.lens[idx]]) catch {};
                                        w.writeAll("\",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{top_tracker.vals[idx]}) catch {};
                                        w.writeAll("}") catch {};
                                    }
                                    w.writeAll("]") catch {};
                                    // Totals section (time + peak)
                                    w.writeAll(",\"totals\":{") catch {};
                                    w.writeAll("\"time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    w.writeAll(",\"peak_bytes\":") catch {};
                                    w.print("{d}", .{track.peakBytes()}) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    // Capture first spill op index & peak-at-spill if any (derive from previously recorded top tracker order / env flags)
                                    var first_spill_op: isize = -1;
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        // Approx heuristic: first operator among Sort/Distinct/NodeScan that had a spill flag set.
                                        if (state.spill_sort > 0) first_spill_op = 0; // NodeScan/Expand indices precede but spill tied to Sort stage -> refine when op indices known prior to emission.
                                    }
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    // spill_reason if any
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        var spill_reason: []const u8 = "forced";
                                        if (state.spill_threshold > 0 and peak_bytes >= state.spill_threshold) spill_reason = "threshold";
                                        w.writeAll(",\"spill_reason\":\"") catch {};
                                        w.writeAll(spill_reason) catch {};
                                        w.writeAll("\"") catch {};
                                        w.writeAll(",\"peak_bytes_at_spill\":") catch {};
                                        w.print("{d}", .{peak_bytes}) catch {};
                                        var first_spill_op_index: isize = -1;
                                        if (state.spill_distinct > 0) {
                                            if (op_index_distinct) |dix| first_spill_op_index = @intCast(dix);
                                        }
                                        if (state.spill_sort > 0) {
                                            if (op_index_sort) |six| {
                                                if (first_spill_op_index < 0 or six < @as(usize, @intCast(first_spill_op_index))) first_spill_op_index = @intCast(six);
                                            }
                                        }
                                        if (first_spill_op_index >= 0) {
                                            w.writeAll(",\"first_spill_op_index\":") catch {};
                                            w.print("{d}", .{first_spill_op_index}) catch {};
                                        }
                                    }
                                    if (memcurve_profile and mem_curve_builder.items.len > 0) {
                                        w.writeAll(",\"mem_curve\":[") catch {};
                                        w.writeAll(mem_curve_builder.items) catch {};
                                        w.writeAll("]") catch {};
                                    }
                                    // Memory summary (net/peak so far) - counting allocator 'track'
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track.total_alloc}) catch {};
                                    w.writeAll("}") catch {};
                                    // planner_estimates summary (only if estimates enabled)
                                    if (!disable_estimates) {
                                        // Derive median error: since we only tracked aggregate stats, approximate median as (min+max)/2 when >1 op, else err_min.
                                        var median_err: usize = 0;
                                        if (err_count == 0) median_err = 0 else if (err_count == 1) median_err = err_min_pct else median_err = (err_min_pct + err_max_pct) / 2;
                                        // adjusted_estimate_factor: factor to multiply future estimates by to reduce mean absolute error: actual/estimate ratio.
                                        const adjusted_estimate_factor: f64 = if (sum_estimated > 0 and sum_actual_estimated > 0) @as(f64, @floatFromInt(sum_actual_estimated)) / @as(f64, @floatFromInt(sum_estimated)) else 1.0;
                                        w.writeAll(",\"planner_estimates\":{") catch {};
                                        w.print("\"sum_estimate_bytes\":{d},", .{sum_estimated}) catch {};
                                        w.print("\"sum_actual_bytes\":{d},", .{sum_actual_estimated}) catch {};
                                        w.print("\"count_estimated_ops\":{d}", .{err_count}) catch {};
                                        if (err_count > 0) {
                                            const mean_err: usize = err_sum_pct / err_count;
                                            w.writeAll(",") catch {};
                                            w.print("\"min_error_abs_pct\":{d},\"max_error_abs_pct\":{d},\"mean_error_abs_pct\":{d},\"median_error_abs_pct\":{d}", .{ err_min_pct, err_max_pct, mean_err, median_err }) catch {};
                                            // Print factor with limited precision
                                            var buf: [32]u8 = undefined;
                                            const fac_str = std.fmt.bufPrint(&buf, "{d:.4}", .{adjusted_estimate_factor}) catch "1.0000";
                                            w.writeAll(",\"adjusted_estimate_factor\":") catch {};
                                            w.writeAll(fac_str) catch {};
                                        }
                                        w.writeAll("}") catch {};
                                    }
                                    state.profile_json = pb.toOwnedSlice(gpa) catch "{}";
                                    state.profile_flags = computeBaseFlags(ordered_meta, q.ret.distinct);
                                    state.last_columns = cols;
                                    state.last_ordered = ordered_meta;
                                    state.last_order_keys = order_keys;
                                    state.last_distinct = q.ret.distinct;
                                    state.active_result = true; // so PULL will emit PROFILE
                                    // Emit SCHEMA now
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, state.profile_flags)) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, null, &run_code, null) catch |e| blk_runerr: {
                                    if (diagnostics.mapEvalError(e)) |c| {
                                        writeErrorWithFlags(gpa, stdout_file, c, diagnostics.defaultMessage(c), diagnostics.anchorFor(c), &.{}, false);
                                        break :blk_runerr &.{};
                                    }
                                    break :blk_runerr &.{};
                                };
                                if (rows.len == 0 and run_code == .TypeMismatch) continue;
                                if (run_code == .TypeMismatch) {
                                    var buf_codes2: [2]diagnostics.Code = undefined;
                                    var len2: usize = 0;
                                    buf_codes2[len2] = .TypeMismatch;
                                    len2 += 1;
                                    if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                        buf_codes2[len2] = .US001;
                                        len2 += 1;
                                    }
                                    const slice2 = buf_codes2[0..len2];
                                    const n_fold2 = diagnostics.foldCodes(slice2);
                                    const primary2 = slice2[0];
                                    const add2 = buildAdditionalStatusesAlloc(gpa, slice2[0..n_fold2], primary2);
                                    writeErrorWithFlags(gpa, stdout_file, primary2, diagnostics.defaultMessage(primary2), diagnostics.anchorFor(primary2), add2, primary2 == .US001);
                                    // free row fragments
                                    var fr2: usize = 0;
                                    while (fr2 < rows.len) : (fr2 += 1) gpa.free(rows[fr2]);
                                    continue;
                                }
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.last_distinct = q.ret.distinct;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (result_format_txt) {
                                    // Plain text mode: emit header once then all rows (single page). Disable further pulls.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, q.ret.distinct))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
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
                                    // Counting allocator for union profiling (independent from simple query path typical usage)
                                    var track_u = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track_u.init(gpa);
                                    const u_ally = track_u.allocator;
                                    // Phase 1: left
                                    const left_start = std.time.nanoTimestamp();
                                    var dummy_cols_l: []const protocol.SchemaCol = &.{};
                                    var ordered_l = false;
                                    var order_keys_l: [][]const u8 = &.{};
                                    const left_rows = evaluateSimpleQuery(u_ally, u_stmt.first, param_names, param_rows, &ordered_l, &order_keys_l, &dummy_cols_l, null, null, null) catch &.{};
                                    metrics.left_in = left_rows.len;
                                    const time_left = std.time.nanoTimestamp() - left_start;
                                    const alloc_after_left = track_u.net();
                                    // Phase 2: tails
                                    const tails_start = std.time.nanoTimestamp();
                                    var all_rows = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                    defer all_rows.deinit(u_ally);
                                    for (left_rows) |lr| all_rows.append(u_ally, lr) catch {};
                                    var any_all = false;
                                    var right_total: usize = 0;
                                    var ti_prof: usize = 0;
                                    while (ti_prof < u_stmt.tails.len) : (ti_prof += 1) {
                                        const part = u_stmt.tails[ti_prof];
                                        if (part.all) any_all = true;
                                        var oc_prof: []const protocol.SchemaCol = &.{};
                                        ordered_l = false;
                                        order_keys_l = &.{};
                                        const pr = evaluateSimpleQuery(u_ally, part.query, param_names, param_rows, &ordered_l, &order_keys_l, &oc_prof, null, null, null) catch &.{};
                                        right_total += pr.len;
                                        for (pr) |rr| all_rows.append(u_ally, rr) catch {};
                                        u_ally.free(oc_prof);
                                    }
                                    metrics.right_in = right_total;
                                    const time_tails = std.time.nanoTimestamp() - tails_start;
                                    const alloc_after_tails = track_u.net();
                                    // Phase 3: dedup (if DISTINCT)
                                    var dedup_time: i128 = 0;
                                    var final_rows: [][]const u8 = &.{};
                                    if (!any_all) {
                                        const dedup_start = std.time.nanoTimestamp();
                                        var seen = std.StringHashMap(void).init(u_ally);
                                        defer seen.deinit();
                                        var dedup = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                        defer dedup.deinit(u_ally);
                                        for (all_rows.items) |s| {
                                            if (!seen.contains(s)) {
                                                seen.put(s, {}) catch {};
                                                dedup.append(u_ally, s) catch {};
                                            } else gpa.free(s);
                                        }
                                        metrics.out = dedup.items.len;
                                        metrics.hash_size = seen.count();
                                        final_rows = dedup.toOwnedSlice(u_ally) catch &.{};
                                        dedup_time = std.time.nanoTimestamp() - dedup_start;
                                        union_mode = "DISTINCT";
                                    } else {
                                        union_mode = "ALL";
                                        metrics.out = all_rows.items.len;
                                        metrics.hash_size = null;
                                        final_rows = all_rows.toOwnedSlice(u_ally) catch &.{};
                                    }
                                    const total_elapsed = std.time.nanoTimestamp() - total_start;
                                    const alloc_after_dedup = track_u.net();
                                    // Build profiling JSON with phase ops
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    const peak_u = track_u.peakBytes();
                                    if (state.spill_threshold > 0 and peak_u >= state.spill_threshold and std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        state.spill_union = 1;
                                    }
                                    // UnionLeft
                                    w.writeAll("{\"op\":\"UnionLeft\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_left}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    w.print("{d}", .{alloc_after_left}) catch {};
                                    const percent_left: usize = if (peak_u > 0 and alloc_after_left > 0) (alloc_after_left * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_left}) catch {};
                                    w.writeAll("},") catch {};
                                    // UnionTails
                                    w.writeAll("{\"op\":\"UnionTails\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_tails}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    const tails_delta = alloc_after_tails - alloc_after_left;
                                    w.print("{d}", .{tails_delta}) catch {};
                                    const percent_tails: usize = if (peak_u > 0 and tails_delta > 0) (tails_delta * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_tails}) catch {};
                                    w.writeAll("},") catch {};
                                    if (std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        w.writeAll("{\"op\":\"UnionDedup\",\"rows\":") catch {};
                                        w.print("{d}", .{metrics.out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{dedup_time}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        const dedup_delta = alloc_after_dedup - alloc_after_tails;
                                        w.print("{d}", .{dedup_delta}) catch {};
                                        const percent_dedup: usize = if (peak_u > 0 and dedup_delta > 0) (dedup_delta * 100) / peak_u else 0;
                                        w.writeAll(",\"percent_peak\":") catch {};
                                        w.print("{d}", .{percent_dedup}) catch {};
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
                                        const total_in: usize = metrics.left_in + metrics.right_in;
                                        if (total_in > 0) {
                                            const fill_pct: usize = (hs2 * 100) / total_in; // integer percent of distinct vs input
                                            w.writeAll(",\"distinct_fill_pct\":") catch {};
                                            w.print("{d}", .{fill_pct}) catch {};
                                        }
                                    }
                                    w.writeAll("},\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track_u.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track_u.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track_u.total_alloc}) catch {};
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
                                if (result_format_txt) {
                                    // Plain text emission for UNION similar to simple query path.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, true))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
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
                if (!state.active_result and state.profile_json == null) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                // If PROFILE staged, emit PROFILE frame and clear profile_json; no rows to paginate.
                if (state.profile_json) |pj| {
                    const pline = protocol.buildProfileLine(gpa, pj, state.profile_flags) catch null;
                    if (pline) |plj| {
                        defer gpa.free(plj);
                        _ = stdout_file.write(plj) catch {};
                    }
                    // PROFILE complete; clear state and mark no active result
                    state.allocator.free(pj);
                    state.profile_json = null;
                    state.profile_flags = &.{};
                    state.active_result = false;
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
