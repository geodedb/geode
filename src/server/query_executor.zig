const std = @import("std");
const eval = @import("../eval.zig");
const exec = @import("../execution.zig");
const protocol = @import("../lib.zig").protocol;
const geode = @import("geode");
const diagnostics = geode.diagnostics;
const ast = geode.ast;
const graph_exec = @import("../graph_exec.zig");
const eval_extended = @import("../eval_extended.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-006; FEATURE="ServerRefactoring"; ASPECT=QUERY_EXECUTOR; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.3 - Query Executor Module (Incremental Extraction)
// Extracted query utility, diagnostic, and AST analysis functions from server/main.zig for better separation of concerns

/// Query execution stage timing metrics for performance profiling and optimization
pub const StageTimings = struct {
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
    // Net allocator snapshots (used to derive per-stage allocation deltas)
    net_after_project: usize = 0,
    net_after_distinct: usize = 0,
    net_after_sort: usize = 0,
    net_after_offset: usize = 0,
    net_after_limit: usize = 0,
};

/// Memory allocation tracker for query execution profiling
pub const AllocTracker = struct {
    ctx: *anyopaque,
    getFn: *const fn (*anyopaque) usize,
};

/// Get current allocation count from tracking allocator
pub fn trackerGet(ctx: *anyopaque) usize {
    const T = @import("tracking_alloc").TrackingAllocator;
    const t: *T = @ptrCast(@alignCast(ctx));
    return t.net();
}

/// Map eval.Value type to human-readable type name string
pub fn valueTypeName(v: eval.Value) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

/// Map aggregation BindingValue (exec module) to schema type string
pub inline fn bindingValueTypeName(v: anytype) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

/// Serialize a single aggregation BindingValue row to JSON using provided column metadata
/// (names only used; types informational)
pub fn bindingValueRowToJson(allocator: std.mem.Allocator, cols: []const protocol.SchemaCol, brow: []const exec.BindingValue) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return &.{};
    const w = buf.writer(allocator);
    w.writeAll("{") catch {};
    var i: usize = 0;
    while (i < cols.len and i < brow.len) : (i += 1) {
        if (i > 0) w.writeAll(",") catch {};
        const name = cols[i].name;
        w.print("\"{s}\":", .{name}) catch {};
        const v = brow[i];
        switch (v) {
            .Null => w.writeAll("null") catch {},
            .Int => |n| w.print("{d}", .{n}) catch {},
            .Bool => |b| w.writeAll(if (b) "true" else "false") catch {},
            .Str => |s| blk: {
                w.writeAll("\"") catch {};
                w.writeAll(s) catch {};
                w.writeAll("\"") catch {};
                break :blk;
            },
            .Decimal => |d| blkdec: {
                const coeff = d.coeff;
                const scale = d.scale;
                if (scale == 0) {
                    w.print("{d}", .{coeff}) catch {};
                    break :blkdec;
                }
                var pow: i128 = 1;
                var si: u8 = 0;
                while (si < scale) : (si += 1) pow *= 10;
                const whole: i128 = @divTrunc(coeff, pow);
                const frac: i128 = @mod(if (coeff < 0) -coeff else coeff, pow);
                var fracbuf: [32]u8 = undefined;
                const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
                if (ftmp.len < scale) {
                    const missing = scale - @as(u8, @intCast(ftmp.len));
                    var pad: [32]u8 = undefined;
                    @memset(pad[0..missing], '0');
                    w.print("{d}.{s}{s}", .{ whole, pad[0..missing], ftmp }) catch {};
                } else {
                    w.print("{d}.{s}", .{ whole, ftmp }) catch {};
                }
            },
        }
    }
    w.writeAll("}") catch {};
    return buf.toOwnedSlice(allocator) catch &.{};
}

/// Write eval.Value to JSON writer with proper type formatting
pub fn writeJsonValue(w: anytype, v: eval.Value) !void {
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
            // If original literal representation preserved, emit it directly for fidelity.
            if (d.orig_repr) |orig| {
                try w.writeAll(orig);
                break :blkdec;
            }
            var buf: [64]u8 = undefined;
            const coeff = d.coeff;
            const scale = d.scale;
            if (scale == 0) {
                const s = std.fmt.bufPrint(&buf, "{d}", .{coeff}) catch "0";
                try w.writeAll(s);
                break :blkdec;
            }
            // Use exact scale (no trimming) because orig_repr absent (computed value); show full precision.
            var pow: i128 = 1;
            var i: u8 = 0;
            while (i < scale) : (i += 1) pow *= 10;
            const abs_coeff: i128 = if (coeff < 0) -coeff else coeff;
            const whole: i128 = @divTrunc(coeff, pow);
            const frac: i128 = @mod(abs_coeff, pow);
            var fracbuf: [32]u8 = undefined;
            const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
            // Pad leading zeros in fractional part to required scale
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

/// Parse JSON parameters into parameter names and row matrix
/// Support single array param (tests only need this)
pub fn parseParams(allocator: std.mem.Allocator, params_json: ?[]const u8, out_names: *[][]const u8, out_rows: *[][]const eval.Value) void {
    if (params_json == null) return;
    const src = params_json.?;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, src, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    // Support single array param (tests only need this)
    if (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .array) return;
        const arr = val.array.items;
        // Empty array -> zero rows (handled by caller when constructing row pages)
        var names = allocator.alloc([]const u8, 1) catch return;
        names[0] = allocator.dupe(u8, key) catch key;
        // Collect raw scalar values first
        var rows = allocator.alloc(eval.Value, arr.len) catch return;
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const v = arr[i];
            rows[i] = switch (v) {
                .integer => |iv| eval.Value{ .Int = @intCast(iv) },
                .bool => |bv| eval.Value{ .Bool = bv },
                .string => |sv| eval.Value{ .Str = sv },
                .null => eval.Value{ .Null = {} },
                .float => eval.Value{ .Null = {} },
                .number_string => eval.Value{ .Null = {} },
                .array => eval.Value{ .Null = {} },
                .object => eval.Value{ .Null = {} },
            };
        }
        out_names.* = names;
        // Wrap each into a single-column row matrix later during evaluation
        // We'll store as param vector values, not full rows yet.
        out_rows.* = allocator.alloc([]const eval.Value, rows.len) catch return;
        var j: usize = 0;
        while (j < rows.len) : (j += 1) out_rows.*[j] = rows[j .. j + 1];
    }
}

/// Build EXPLAIN JSON with logical query plan
/// Canonical pipeline order with monotonic id: Project(0), Distinct(1), Sort(2), Offset(3), Limit(4), SetOpUnion(5)
pub fn buildExplainJson(allocator: std.mem.Allocator, params: struct { ordered: bool, limit: ?usize, offset: ?usize, union_mode: ?[]const u8, distinct: bool, setop_kind: ?[]const u8 }) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return "{\"logical\":[]}";
    const w = buf.writer(allocator);
    w.writeAll("{\"profile_version\":2,\"logical\":[") catch {};
    var id: usize = 0;
    // Project always present first
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
        const sop = if (params.setop_kind) |sk| sk else "SetOpUnion";
        w.writeAll(",{\"op\":\"") catch {};
        w.writeAll(sop) catch {};
        w.writeAll("\",\"id\":") catch {};
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
    w.writeAll("}}") catch {}; // Close properties object and outer JSON object
    return buf.toOwnedSlice(allocator) catch "{\"logical\":[]}";
}

/// Build canonical key for value-based row deduplication
/// Encodes row values directly to avoid JSON reparsing
pub fn canonicalValuesKey(allocator: std.mem.Allocator, vals: []const eval.Value) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return &.{};
    const w = buf.writer(allocator);
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
    return buf.toOwnedSlice(allocator) catch &.{};
}

/// Aggregate diagnostics discovered during parsing / surface analysis for a single statement
/// Currently detects:
///  - US001 (unordered pagination): presence of LIMIT/OFFSET without ORDER BY
///  - IllegalOrderKey: parser policy violation captured via parse error message
/// Returns number of collected codes placed into out_codes (deduplicated) sorted by precedence
pub fn collectTextDiagnostics(text: []const u8, parse_err_msg: ?[]const u8, out_codes: *[4]diagnostics.Code) usize {
    var tmp: [4]diagnostics.Code = undefined;
    var n: usize = 0;
    // LIMIT alone is allowed without ORDER BY (has_limit removed since not used)
    const has_offset = std.mem.indexOf(u8, text, "OFFSET") != null or std.mem.indexOf(u8, text, "SKIP") != null;
    const has_order_kw = std.mem.indexOf(u8, text, "ORDER BY") != null;
    var parsed_illegal = false;
    if (parse_err_msg) |msg| {
        if (diagnostics.mapParserMessage(msg)) |_| {
            parsed_illegal = true;
        }
    }
    // US001: LIMIT with SKIP/OFFSET requires ORDER BY for deterministic pagination
    // LIMIT alone is allowed without ORDER BY
    if (has_offset and (!has_order_kw or parsed_illegal)) {
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

/// Planner diagnostics aggregation: include primary planner code plus US001 if unordered pagination also applies
pub fn collectPlannerDiagnostics(q: geode.ast.Query, primary: diagnostics.Code, out_codes: *[4]diagnostics.Code) usize {
    out_codes.*[0] = primary;
    var n: usize = 1;
    const unordered_pagination = (q.limit != null or q.offset != null) and q.order_by == null;
    if (unordered_pagination and primary != .US001) {
        out_codes.*[n] = .US001;
        n += 1;
    }
    return diagnostics.foldCodes(out_codes.*[0..n]);
}

/// Check if expression contains equality predicate (recursively)
/// Useful for index selection heuristics
pub fn hasEqualityPredicate(expr: anytype) bool {
    // Attempt to match Binary nodes; AST uses union(enum) with .Binary carrying op + left/right.
    if (@hasField(@TypeOf(expr), "op") and @hasField(@TypeOf(expr), "left") and @hasField(@TypeOf(expr), "right")) {
        // best-effort: assume equality op tag name contains Eq
        // Use @tagName on op if enum
        if (@typeInfo(@TypeOf(expr.op)) == .Enum) {
            const opname = @tagName(expr.op);
            if (std.mem.eql(u8, opname, "Eq")) return true;
            if (std.mem.eql(u8, opname, "And") or std.mem.eql(u8, opname, "Or")) {
                if (hasEqualityPredicate(expr.left.*) or hasEqualityPredicate(expr.right.*)) return true;
            }
        }
        if (hasEqualityPredicate(expr.left.*)) return true;
        if (hasEqualityPredicate(expr.right.*)) return true;
    }
    // Generic recursion for other containers
    const T = @TypeOf(expr);
    if (@hasField(T, "left") and @hasField(T, "right")) {
        if (hasEqualityPredicate(expr.left)) return true;
        if (hasEqualityPredicate(expr.right)) return true;
    }
    if (@hasField(T, "expr")) if (hasEqualityPredicate(expr.expr)) return true;
    if (@hasField(T, "terms")) for (expr.terms) |t| if (hasEqualityPredicate(t)) return true;
    if (@hasField(T, "args")) for (expr.args) |a| if (hasEqualityPredicate(a)) return true;
    return false;
}

/// Check if expression contains aggregation function call (count, sum, avg, min, max)
pub fn hasAggregationFunction(expr: ast.Expr) bool {
    return switch (expr) {
        .Call => |call| {
            const callee = call.callee.*;
            if (callee == .Ident) {
                const func_name = callee.Ident.orig;
                if (std.mem.eql(u8, func_name, "count") or
                    std.mem.eql(u8, func_name, "sum") or
                    std.mem.eql(u8, func_name, "avg") or
                    std.mem.eql(u8, func_name, "min") or
                    std.mem.eql(u8, func_name, "max"))
                {
                    return true;
                }
            }
            // Check arguments recursively
            for (call.args) |arg| {
                if (hasAggregationFunction(arg.*)) {
                    return true;
                }
            }
            return false;
        },
        .Binary => |bin| {
            return hasAggregationFunction(bin.left.*) or hasAggregationFunction(bin.right.*);
        },
        .Unary => |un| {
            return hasAggregationFunction(un.expr.*);
        },
        else => false,
    };
}

/// Build canonical key for a row JSON string so that numerically equal values with different scales map identically
pub fn canonicalRowKey(allocator: std.mem.Allocator, row: []const u8) []const u8 {
    if (row.len < 2) return row; // fallback
    var idx: usize = 0;
    if (row[idx] == '{') idx += 1;
    var key_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return row;
    const w = key_buf.writer(allocator);
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
    return key_buf.toOwnedSlice(allocator) catch row;
}

/// Build additional status codes array for diagnostics (excluding primary code)
pub fn buildAdditionalStatusesAlloc(allocator: std.mem.Allocator, codes: []const diagnostics.Code, primary: diagnostics.Code) []const []const u8 {
    if (codes.len <= 1) return &.{};
    var extras = allocator.alloc([]const u8, codes.len - 1) catch return &.{};
    var ei: usize = 0;
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        if (codes[i] == primary) continue;
        extras[ei] = diagnostics.codeName(codes[i]);
        ei += 1;
    }
    return extras[0..ei];
}

/// Custom bindings writer: include final flag only if (has_params or multi_page_needed or explicit pagination triggered)
pub fn writeBindingsAdaptive(file: std.fs.File, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final_flag: bool, include_final: bool, flags: []const []const u8) void {
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

/// Shared DISTINCT dedup helper: mutates rows_json in-place, frees removed row value slices when provided.
pub fn distinctDedup(allocator: std.mem.Allocator, have_values: bool, value_arity: usize, rows_json: *std.ArrayList([]const u8), rows_values: *std.ArrayList([]const eval.Value), out_hash_size: ?*usize) void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out_rows = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
    defer out_rows.deinit(allocator);
    var out_values = if (have_values) std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch return else std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch return;
    defer out_values.deinit(allocator);
    var alloc_keys = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
    defer {
        for (alloc_keys.items) |k| allocator.free(k);
        alloc_keys.deinit(allocator);
    }
    var idx: usize = 0;
    while (idx < rows_json.items.len) : (idx += 1) {
        const row = rows_json.items[idx];
        const key = if (have_values and idx < rows_values.items.len) canonicalValuesKey(allocator, rows_values.items[idx][0..value_arity]) else canonicalRowKey(allocator, row);
        if (!seen.contains(key)) {
            seen.put(key, {}) catch {};
            out_rows.append(allocator, row) catch {};
            if (have_values and idx < rows_values.items.len) out_values.append(allocator, rows_values.items[idx]) catch {};
            if (key.ptr != row.ptr) alloc_keys.append(allocator, key) catch {};
        } else {
            allocator.free(row);
            allocator.free(key);
            if (have_values and idx < rows_values.items.len) allocator.free(rows_values.items[idx]);
        }
    }
    const unique = seen.count();
    rows_json.clearRetainingCapacity();
    for (out_rows.items) |r| rows_json.append(allocator, r) catch {};
    if (out_hash_size) |p| p.* = unique;
    if (have_values) {
        // Replace original rows_values with compacted out_values (ownership of slices moves as-is)
        for (rows_values.items) |v| allocator.free(v);
        rows_values.clearRetainingCapacity();
        for (out_values.items) |v| rows_values.append(allocator, v) catch {};
    }
}

/// Convert eval.Value to graph_exec.BindingValue for graph operations
pub fn convertEvalValueToBindingValue(val: eval.Value) graph_exec.BindingValue {
    return switch (val) {
        .Null => .Null,
        .Bool => |b| .{ .Value = .{ .Bool = b } },
        .Int => |i| .{ .Value = .{ .Int = i } },
        .Str => |s| .{ .Value = .{ .String = s } },
        .Decimal => |d| .{ .Value = .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } } },
        else => .Null,
    };
}

/// Convert AST expression to graph property value with support for advanced types
pub fn evalExprToPropertyValue(allocator: std.mem.Allocator, expr: ast.Expr) !graph_exec.PropertyValue {
    return switch (expr) {
        .Null => .{ .Null = {} },
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .String => |s| .{ .String = try allocator.dupe(u8, s) }, // Deep copy string to prevent dangling pointers
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .Call => |call| blk_call: {
            // Handle function calls for advanced types (VectorF32, IpAddr, etc.)
            const function_name = switch (call.callee.*) {
                .Ident => |ident| ident.orig,
                else => break :blk_call .{ .Null = {} },
            };

            // Convert arguments from ast.Expr to eval_extended.ExtValue
            var args = try allocator.alloc(eval_extended.ExtValue, call.args.len);
            defer allocator.free(args);

            for (call.args, 0..) |arg, i| {
                args[i] = switch (arg.*) {
                    .Null => .{ .Null = {} },
                    .Bool => |b| .{ .Bool = b },
                    .Int => |n| .{ .Int = n },
                    .String => |s| .{ .Str = s },
                    .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                    .ArrayLit => |arr| blk_arr: {
                        // Convert array literal to list of ExtValue
                        var list = try allocator.alloc(eval_extended.ExtValue, arr.len);
                        for (arr, 0..) |elem, j| {
                            list[j] = switch (elem.*) {
                                .Int => |n| .{ .Int = n },
                                .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                                else => .{ .Null = {} },
                            };
                        }
                        break :blk_arr .{ .List = list };
                    },
                    else => .{ .Null = {} },
                };
            }

            // Initialize function registry and call the function
            var registry = try eval_extended.initFunctionRegistry(allocator);
            defer registry.deinit();

            // Convert function name to lowercase for registry lookup
            const lowercase_name = try std.ascii.allocLowerString(allocator, function_name);
            defer allocator.free(lowercase_name);

            if (registry.get(lowercase_name)) |func| {
                const result = func(allocator, args) catch |err| {
                    std.log.err("Function {s} failed with error: {}", .{ function_name, err });
                    break :blk_call .{ .Null = {} };
                };

                // Convert ExtValue result to PropertyValue
                break :blk_call switch (result) {
                    .Null => .{ .Null = {} },
                    .Bool => |b| .{ .Bool = b },
                    .Int => |i| .{ .Int = i },
                    .Str => |s| .{ .String = try allocator.dupe(u8, s) },
                    .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                    .VectorF32 => |v| .{ .VectorF32 = v },
                    else => .{ .Null = {} },
                };
            }

            std.log.err("Function {s} (lowercase: {s}) not found in registry", .{ function_name, lowercase_name });
            break :blk_call .{ .Null = {} };
        },
        else => .{ .Null = {} }, // Default for unsupported expressions
    };
}

/// Convert graph property value to index key string for indexing operations
pub fn propertyValueToIndexKey(allocator: std.mem.Allocator, value: graph_exec.PropertyValue) ![]u8 {
    switch (value) {
        .String => |s| return allocator.dupe(u8, s),
        .Int => |i| return std.fmt.allocPrint(allocator, "{d}", .{i}),
        .Bool => |b| return allocator.dupe(u8, if (b) "true" else "false"),
        .Null => return allocator.dupe(u8, "null"),
        .Decimal => |d| return std.fmt.allocPrint(allocator, "{d}", .{d.coeff}),
        .VectorF32 => |v| return std.fmt.allocPrint(allocator, "vector:{d}x{d}", .{ v.dim, v.data.len }),
    }
}
