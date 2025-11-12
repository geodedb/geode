const std = @import("std");
const eval = @import("../eval.zig");
const exec = @import("../execution.zig");
const protocol = @import("../lib.zig").protocol;
const geode = @import("geode");
const diagnostics = geode.diagnostics;
const ast = geode.ast;
const graph_exec = @import("../graph_exec.zig");
const eval_extended = @import("../eval_extended.zig");
const server_state = @import("server_state.zig");
const server_flags = @import("server_flags.zig");
const graph_storage_mgr = @import("graph_storage_manager.zig");
const union_advanced = @import("../union_advanced.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-006; FEATURE="ServerRefactoring"; ASPECT=QUERY_EXECUTOR; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.3 - Query Executor Module (Incremental Extraction - Eighth Increment)
// Extracted query utility, diagnostic, AST analysis, and query evaluation functions from server/main.zig for better separation of concerns

// Import types from other modules
const UnionMetrics = server_state.UnionMetrics;
const getOrCreateGraphStorage = graph_storage_mgr.getOrCreateGraphStorage;

// Global configuration for MATCH query execution guards (set by server initialization)
pub var g_match_max_results_override: ?usize = null;
pub var g_match_max_frontier_override: ?usize = null;

// Import nulls ordering flag from server_flags
const g_nulls_last = &server_flags.g_nulls_last;

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

/// Evaluate a simple query (non-UNION) with support for MATCH, ORDER BY, DISTINCT, LIMIT/OFFSET
/// This is the core query evaluation function that handles both MATCH queries and RETURN-only queries
pub fn evaluateSimpleQuery(
    allocator: std.mem.Allocator,
    q: geode.ast.Query,
    param_names: [][]const u8,
    param_matrix: [][]const eval.Value,
    ordered_meta: *bool,
    order_keys: *[][]const u8,
    cols_out: *[]const protocol.SchemaCol,
    timings: ?*StageTimings,
    eval_diag: ?*diagnostics.Code,
    alloc_tracker: ?AllocTracker,
) ![][]const u8 {
    // Check if this is a MATCH query
    if (q.match.chains.len > 0) {
        // Initialize graph storage (for now, use a global singleton)
        // In production, this would be loaded from persistent storage
        const graph = getOrCreateGraphStorage(allocator);

        // Execute MATCH pattern
        // Read environment overrides for MATCH guard limits (deterministic test triggering of ExecutionGuardTrip)
        var m_opts = graph_exec.MatchOptions{};
        if (g_match_max_results_override) |ovr| m_opts.max_results = ovr;
        if (g_match_max_frontier_override) |ovf| m_opts.max_frontier = ovf;
        if (std.process.getEnvVarOwned(allocator, "GEODE_MATCH_MAX_RESULTS")) |mv| {
            defer allocator.free(mv);
            const parsed = std.fmt.parseInt(usize, mv, 10) catch null;
            if (parsed) |p| m_opts.max_results = p;
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "GEODE_MATCH_MAX_FRONTIER")) |fv| {
            defer allocator.free(fv);
            const parsedf = std.fmt.parseInt(usize, fv, 10) catch null;
            if (parsedf) |pf| m_opts.max_frontier = pf;
        } else |_| {}
        var bindings = try graph_exec.executeMatch(allocator, graph, &q, q.where_clause, m_opts, eval_diag, null);

        // Check if the query has aggregation functions
        var has_aggregation = false;
        for (q.ret.items) |item| {
            if (hasAggregationFunction(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        // If aggregation is detected, handle it directly
        if (has_aggregation) {
            // Create a single aggregated result
            var agg_binding = graph_exec.Binding.init(allocator);

            // Process each return item
            for (q.ret.items, 0..) |item, i| {
                const alias = item.alias orelse blk_al: {
                    const tmp = geode.printer.stringifyExprAlloc(allocator, item.expr, .{}) catch "col";
                    break :blk_al tmp;
                };

                // Handle aggregation functions
                if (item.expr == .Call) {
                    const call = item.expr.Call;
                    const callee = call.callee.*;
                    if (callee == .Ident) {
                        const func_name = callee.Ident.orig;
                        if (std.mem.eql(u8, func_name, "count")) {
                            // Count aggregation
                            const count_value = graph_exec.BindingValue{ .Value = .{ .Int = @intCast(bindings.len) } };
                            try agg_binding.vars.put(alias, count_value);

                            // Set as main binding value for the first item
                            if (i == 0) {
                                agg_binding.name = alias;
                                agg_binding.value = count_value;
                            }
                        } else {
                            // Other aggregations - TODO: implement sum, avg, min, max
                            const placeholder_value = graph_exec.BindingValue{ .Value = .{ .Int = 0 } };
                            try agg_binding.vars.put(alias, placeholder_value);

                            // Set as main binding value for the first item
                            if (i == 0) {
                                agg_binding.name = alias;
                                agg_binding.value = placeholder_value;
                            }
                        }
                    }
                } else {
                    // Non-aggregation expression in aggregation context
                    const null_value = graph_exec.BindingValue.Null;
                    try agg_binding.vars.put(alias, null_value);

                    // Set as main binding value for the first item
                    if (i == 0) {
                        agg_binding.name = alias;
                        agg_binding.value = null_value;
                    }
                }
            }

            // Replace bindings with single aggregated result
            var agg_bindings = try allocator.alloc(graph_exec.Binding, 1);
            agg_bindings[0] = agg_binding;
            bindings = agg_bindings;
        }

        // Apply WITH clause if present
        if (q.with_clause) |with_clause| {
            bindings = try graph_exec.executeWith(allocator, bindings, with_clause, q.where_clause, graph);
        }

        // Apply SET clauses if present
        if (q.set_clauses.len > 0) {
            for (q.set_clauses) |set_clause| {
                // For each binding, find the object and set its property
                for (bindings) |*binding| {
                    if (binding.vars.get(set_clause.target.object)) |obj| {
                        // Evaluate the expression as a simple value for now
                        // In the future, this should evaluate in the context of the binding
                        const prop_val = try evalExprToPropertyValue(allocator, set_clause.value);

                        switch (obj) {
                            .Node => |node| {
                                try graph.setNodeProperty(allocator, node.id, set_clause.target.property, prop_val);
                            },
                            .Edge => |edge| {
                                try graph.setEdgeProperty(allocator, edge.id, set_clause.target.property, prop_val);
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        // Apply REMOVE clauses if present
        if (q.remove_clauses.len > 0) {
            for (q.remove_clauses) |remove_clause| {
                // For each binding, find the object and remove its property
                for (bindings) |*binding| {
                    if (binding.vars.get(remove_clause.target.object)) |obj| {
                        switch (obj) {
                            .Node => |node| {
                                try graph.removeNodeProperty(node.id, remove_clause.target.property);
                            },
                            .Edge => |edge| {
                                try graph.removeEdgeProperty(edge.id, remove_clause.target.property);
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        // Build column metadata (names inferred from RETURN items; types set to MIXED placeholder)
        var cols = try allocator.alloc(protocol.SchemaCol, q.ret.items.len);
        for (q.ret.items, 0..) |item, i| {
            const alias = item.alias orelse blk_al: {
                const tmp = geode.printer.stringifyExprAlloc(allocator, item.expr, .{}) catch "col";
                break :blk_al tmp;
            };
            cols[i] = .{ .name = alias, .type = "MIXED" };
        }
        cols_out.* = cols;

        // Local helper to convert graph PropertyValue into eval.Value (mirror of exec.zig)
        const PropToEval = struct {
            fn conv(pv: graph_exec.PropertyValue) eval.Value {
                return switch (pv) {
                    .Null => eval.Value{ .Null = {} },
                    .Bool => |b| eval.Value{ .Bool = b },
                    .Int => |i| eval.Value{ .Int = i },
                    .String => |s| eval.Value{ .Str = s },
                    .Decimal => |d| eval.Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                    .VectorF32 => eval.Value{ .Null = {} }, // VectorF32 not supported in eval.Value
                };
            }
        };

        // Prepare per-row VALUEs for ORDER BY/DISTINCT evaluation
        var rows_values = std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch return error.OutOfMemory;
        defer rows_values.deinit(allocator);

        // Helper: evaluate a single return expression in binding context to eval.Value for ordering/aggregation
        const EvalInBinding = struct {
            fn evalRet(alloc: std.mem.Allocator, b: *const graph_exec.Binding, it: geode.ast.ReturnItem, g: *const graph_exec.GraphStorage) eval.Value {
                return switch (it.expr) {
                    .Ident => |id| blk_i: {
                        if (b.vars.get(id.orig)) |bv| {
                            switch (bv) {
                                .Value => |pv| break :blk_i PropToEval.conv(pv),
                                .Property => |pv| break :blk_i PropToEval.conv(pv),
                                .Node, .Edge, .Path, .Null => break :blk_i eval.Value{ .Null = {} },
                            }
                        }
                        break :blk_i eval.Value{ .Null = {} };
                    },
                    .PropertyAccess => |pa| blk_p: {
                        if (b.vars.get(pa.object)) |ov| {
                            switch (ov) {
                                .Node => |node| {
                                    if (g.nodes.get(node.id)) |fetched_node| {
                                        if (fetched_node.properties.get(pa.property)) |prop| {
                                            break :blk_p PropToEval.conv(prop);
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                        break :blk_p eval.Value{ .Null = {} };
                    },
                    else => blk_e: {
                        // Build an eval.Env from binding scalars only; non-scalars mapped to null
                        var env_names = std.ArrayList([]const u8).initCapacity(alloc, 0) catch unreachable;
                        var env_values = std.ArrayList(eval.Value).initCapacity(alloc, 0) catch unreachable;
                        var itv = b.vars.iterator();
                        while (itv.next()) |entry| {
                            env_names.append(alloc, entry.key_ptr.*) catch {};
                            const ev = switch (entry.value_ptr.*) {
                                .Value => |pv| PropToEval.conv(pv),
                                else => eval.Value{ .Null = {} },
                            };
                            env_values.append(alloc, ev) catch {};
                        }
                        const allocator_local = allocator; // Capture for closure
                        const env = eval.Env{ .names = env_names.items, .values = env_values.items, .allocator = allocator_local };
                        const v = eval.evalExpr(alloc, it.expr, env) catch eval.Value{ .Null = {} };
                        break :blk_e v;
                    },
                };
            }
        };

        // Precompute row values for all bindings
        var bi: usize = 0;
        while (bi < bindings.len) : (bi += 1) {
            var rvals = try allocator.alloc(eval.Value, q.ret.items.len);
            var ci2: usize = 0;
            while (ci2 < q.ret.items.len) : (ci2 += 1) {
                rvals[ci2] = EvalInBinding.evalRet(allocator, &bindings[bi], q.ret.items[ci2], graph);
            }
            rows_values.append(allocator, rvals) catch {};
        }

        // Deterministic base ordering (before DISTINCT) using graph binding structural comparator
        graph_exec.sortBindingsDeterministic(allocator, bindings);

        // DISTINCT stage for MATCH: deduplicate projected rows based on value semantics
        if (q.ret.distinct and rows_values.items.len > 1) {
            var seen = std.StringHashMap(void).init(allocator);
            defer seen.deinit();
            var kept_bindings = std.ArrayList(graph_exec.Binding).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer kept_bindings.deinit(allocator);
            var kept_values = std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer kept_values.deinit(allocator);
            var i_dist: usize = 0;
            while (i_dist < rows_values.items.len and i_dist < bindings.len) : (i_dist += 1) {
                const vals = rows_values.items[i_dist];
                const key = canonicalValuesKey(allocator, vals[0..q.ret.items.len]);
                if (!seen.contains(key)) {
                    seen.put(key, {}) catch {};
                    // keep this binding and its values
                    kept_bindings.append(allocator, bindings[i_dist]) catch {};
                    kept_values.append(allocator, vals) catch {};
                } else {
                    // drop duplicate row: free value slice and key if separately allocated
                    allocator.free(vals);
                    allocator.free(key);
                }
            }
            // Replace arrays; note: bindings contents were moved by value; subsequent code will not use old slice
            bindings = kept_bindings.toOwnedSlice(allocator) catch bindings;
            // rows_values: clear and move kept_values
            // Free any remaining unreferenced value slices
            var jv: usize = i_dist;
            while (jv < rows_values.items.len) : (jv += 1) allocator.free(rows_values.items[jv]);
            rows_values.clearRetainingCapacity();
            for (kept_values.items) |rv| rows_values.append(allocator, rv) catch {};
        }

        // ORDER BY
        var ordered_now = false;
        var order_keys_local: [][]const u8 = &.{};
        if (q.order_by) |ob| {
            ordered_now = true;
            // Build col index map
            var col_index = std.StringHashMap(usize).init(allocator);
            defer col_index.deinit();
            var ci_map: usize = 0;
            while (ci_map < cols.len) : (ci_map += 1) {
                col_index.put(cols[ci_map].name, ci_map) catch {};
            }
            // Build list of key names for metadata
            order_keys_local = try allocator.alloc([]const u8, ob.keys.len);
            var okm: usize = 0;
            while (okm < ob.keys.len) : (okm += 1) {
                const s = geode.printer.stringifyExprAlloc(allocator, ob.keys[okm].expr, .{}) catch "k";
                order_keys_local[okm] = s;
            }
            // Precompute key matrix from rows_values by alias position
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = allocator.alloc(KeyVal, bindings.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) allocator.free(key_matrix);
            var ri_k: usize = 0;
            while (ri_k < bindings.len) : (ri_k += 1) {
                var ki: usize = 0;
                while (ki < key_count) : (ki += 1) {
                    const key_expr = ob.keys[ki].expr;
                    var kv: KeyVal = .{ .kind = .Null };
                    if (key_expr == .Ident) {
                        if (col_index.get(key_expr.Ident.orig)) |posc| {
                            if (ri_k < rows_values.items.len and posc < rows_values.items[ri_k].len) {
                                const v = rows_values.items[ri_k][posc];
                                kv = switch (v) {
                                    .Null => .{ .kind = .Null },
                                    .Int => |iv| .{ .kind = .Int, .mantissa = iv },
                                    .Decimal => |d| .{ .kind = .Dec, .mantissa = d.coeff, .scale = d.scale },
                                    .Str => |s| .{ .kind = .Str, .str = s },
                                    .Bool => |b| .{ .kind = .Str, .str = if (b) "true" else "false" },
                                };
                            }
                        }
                    }
                    key_matrix[ri_k * key_count + ki] = kv;
                }
            }
            // Sort indices based on key_matrix; tie-break by rendered JSON row lexicographically
            const idx = allocator.alloc(usize, bindings.len) catch null;
            if (idx) |indices| {
                var fi: usize = 0;
                while (fi < indices.len) : (fi += 1) indices[fi] = fi;
                const Ctx = struct {
                    keys: []KeyVal,
                    key_count: usize,
                    ob: *const @TypeOf(ob),
                    // Lazily rendered for tie-break only
                    allocator: std.mem.Allocator,
                    g: *const graph_exec.GraphStorage,
                    ret_items: []const geode.ast.ReturnItem,
                    binds: []const graph_exec.Binding,
                };
                std.sort.block(usize, indices, Ctx{ .keys = key_matrix, .key_count = key_count, .ob = &ob, .allocator = allocator, .g = graph, .ret_items = q.ret.items, .binds = bindings }, struct {
                    fn less(c: Ctx, a: usize, b: usize) bool {
                        var ki2: usize = 0;
                        while (ki2 < c.ob.keys.len) : (ki2 += 1) {
                            const key_expr = c.ob.keys[ki2];
                            const av = c.keys[a * c.key_count + ki2];
                            const bv = c.keys[b * c.key_count + ki2];
                            // Null handling policy
                            if (av.kind == .Null and bv.kind != .Null) {
                                if (g_nulls_last.*) {
                                    if (key_expr.desc) return true;
                                    return false;
                                } else return !key_expr.desc;
                            }
                            if (bv.kind == .Null and av.kind != .Null) {
                                if (g_nulls_last.*) {
                                    if (key_expr.desc) return false;
                                    return true;
                                } else return key_expr.desc;
                            }
                            // Compare by kind
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
                                .Int, .Dec => ord = blk2: {
                                    switch (bv.kind) {
                                        .Int, .Dec => {
                                            var ma = av.mantissa;
                                            var mb = bv.mantissa;
                                            const as = av.scale;
                                            const bs = bv.scale;
                                            if (as < bs) {
                                                var d = bs - as;
                                                while (d > 0) : (d -= 1) ma *= 10;
                                            }
                                            if (bs < as) {
                                                var d2 = as - bs;
                                                while (d2 > 0) : (d2 -= 1) mb *= 10;
                                            }
                                            if (ma < mb) break :blk2 -1;
                                            if (ma > mb) break :blk2 1;
                                            break :blk2 0;
                                        },
                                        .Str => break :blk2 -1,
                                        .Null => break :blk2 1,
                                    }
                                },
                            }
                            if (ord != 0) return if (key_expr.desc) ord > 0 else ord < 0;
                        }
                        // Tie-break: render both rows and compare bytes
                        const ra = graph_exec.bindingsToJson(c.allocator, c.binds[a .. a + 1], c.ret_items, c.g) catch &.{};
                        const rb = graph_exec.bindingsToJson(c.allocator, c.binds[b .. b + 1], c.ret_items, c.g) catch &.{};
                        // Free the JSON strings
                        defer if (ra.len > 0) c.allocator.free(ra);
                        defer if (rb.len > 0) c.allocator.free(rb);
                        const sa: []const u8 = ra;
                        const sb: []const u8 = rb;
                        return std.mem.lessThan(u8, sa, sb);
                    }
                }.less);
                // Apply permutation to bindings (so we can render in order)
                var ordered_bind = std.ArrayList(graph_exec.Binding).initCapacity(allocator, bindings.len) catch return error.OutOfMemory;
                defer ordered_bind.deinit(allocator);
                var oi: usize = 0;
                while (oi < indices.len) : (oi += 1) ordered_bind.append(allocator, try bindings[indices[oi]].clone(allocator)) catch {};
                bindings = ordered_bind.toOwnedSlice(allocator) catch bindings;
                allocator.free(indices);
            }
        }

        // OFFSET/LIMIT
        var start: usize = 0;
        if (q.offset) |off| start = if (off < bindings.len) off else bindings.len;
        var end: usize = bindings.len;
        if (q.limit) |lim| {
            if (start + lim < end) end = start + lim;
        }

        // Set metadata
        ordered_meta.* = ordered_now;
        order_keys.* = order_keys_local;

        // Render the final selected slice
        const json_result = try graph_exec.bindingsToJson(allocator, bindings[start..end], q.ret.items, graph);

        // Convert single JSON string to array of strings
        var result_array = try allocator.alloc([]const u8, 1);
        result_array[0] = json_result;

        // If a guard trip diagnostic occurred, mark eval_diag (already set upstream) and return rows.
        return result_array;
    }

    // Original implementation for non-MATCH queries
    // Build rows
    var cols = try allocator.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(allocator);

    // Structured row arena (phase 1): only enabled when DISTINCT required so we can build canonical keys without reparsing JSON.
    const need_row_values = q.ret.distinct or (q.order_by != null); // future: GROUP BY, aggregation
    var rows_values = std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch unreachable; // flattened; each slice length = q.ret.items.len
    defer if (need_row_values) rows_values.deinit(allocator) else rows_values.deinit(allocator); // always deinit; capacity small in tests.

    const t_start = if (timings) |_| std.time.nanoTimestamp() else 0;

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    // Capture per-row evaluation environments for later ORDER BY key evaluation.
    var envs = try allocator.alloc(eval.Env, num_rows);
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        envs[r] = env;
        // Build JSON row
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        const w = buf.writer(allocator);
        w.writeAll("{") catch {};
        var j: usize = 0;
        var row_vals: []eval.Value = &.{};
        if (need_row_values and q.ret.items.len > 0) {
            row_vals = try allocator.alloc(eval.Value, q.ret.items.len);
        }
        while (j < q.ret.items.len) : (j += 1) {
            const it = q.ret.items[j];
            const alias = it.alias orelse blk: {
                const tmp = geode.printer.stringifyExprAlloc(allocator, it.expr, .{}) catch "col";
                break :blk tmp;
            };
            const val = eval.evalExpr(allocator, it.expr, env) catch |e| blk_evalerr: {
                if (eval_diag) |ed| {
                    if (diagnostics.mapEvalError(e)) |c| ed.* = c;
                }

                // Check for critical errors that should fail the query
                if (e == eval.EvalError.DivisionByZero) {
                    return error.DivisionByZero;
                }
                if (e == eval.EvalError.DecimalDivZero) {
                    return error.DecimalDivZero;
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
        rows_json.append(allocator, buf.toOwnedSlice(allocator) catch "{}") catch {};
        if (need_row_values) rows_values.append(allocator, row_vals) catch {};
    }

    if (timings) |tptr| {
        tptr.project_ns = std.time.nanoTimestamp() - t_start;
        tptr.project_rows_in = num_rows;
        tptr.project_rows_out = rows_json.items.len;
        tptr.expand_rows_in = num_rows; // stub: no expansion yet
        tptr.expand_rows_out = num_rows;
        var tb: usize = 0;
        for (rows_json.items) |s| tb += s.len;
        tptr.project_bytes_out = tb;
        const net_now = if (alloc_tracker) |tr| tr.getFn(tr.ctx) else tb;
        tptr.project_bytes_alloc = net_now;
        tptr.net_after_project = net_now;
        tptr.expand_bytes_out = 0;
        tptr.expand_bytes_alloc = 0;
    }

    // Build column name -> index map (for ORDER BY identifier key fast path)
    var col_index = std.StringHashMap(usize).init(allocator);
    defer col_index.deinit();
    var ci: usize = 0;
    while (ci < q.ret.items.len) : (ci += 1) {
        const cname = cols[ci].name;
        col_index.put(cname, ci) catch {};
    }

    // DISTINCT delta attribution baseline captured after project
    // alloc_after_project no longer needed (per-stage deltas captured via net_after_* fields)
    if (q.ret.distinct and rows_json.items.len > 1) {
        const t_d_start = if (timings) |_| std.time.nanoTimestamp() else 0;
        distinctDedup(allocator, need_row_values, q.ret.items.len, &rows_json, &rows_values, null);
        if (timings) |tptr| {
            tptr.distinct_ns = std.time.nanoTimestamp() - t_d_start;
            tptr.distinct_rows_in = tptr.project_rows_out;
            tptr.distinct_rows_out = rows_json.items.len;
            var tb2: usize = 0;
            for (rows_json.items) |s| tb2 += s.len;
            tptr.distinct_bytes_out = tb2;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                tptr.distinct_bytes_alloc = if (after > tptr.net_after_project) after - tptr.net_after_project else 0;
                tptr.net_after_distinct = after;
            } else {
                tptr.distinct_bytes_alloc = tb2;
                tptr.net_after_distinct = tptr.net_after_project + tptr.distinct_bytes_alloc;
            }
        }
    }

    // ORDER BY (metadata always set when present; we will not reorder unless needed by tests with actual ordering semantics)
    if (q.order_by) |ob| {
        ordered_meta.* = true;
        if (ob.keys.len > 0) {
            order_keys.* = try allocator.alloc([]const u8, ob.keys.len);
            var ok: usize = 0;
            while (ok < ob.keys.len) : (ok += 1) {
                const s = geode.printer.stringifyExprAlloc(allocator, ob.keys[ok].expr, .{}) catch "k";
                order_keys.*[ok] = s;
            }
        }
        if (rows_json.items.len > 1 and ob.keys.len > 0) {
            const t_sort_start = if (timings) |_| std.time.nanoTimestamp() else 0;
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            // Flattened matrix: row-major [row * key_count + key]
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = allocator.alloc(KeyVal, rows_json.items.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) allocator.free(key_matrix);
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
                        if (col_index.get(key_expr.Ident.orig)) |colpos| {
                            if (row_index < rows_values.items.len) {
                                const rv = rows_values.items[row_index];
                                if (colpos < rv.len) val = rv[colpos];
                            }
                        } else {
                            val = eval.evalExpr(allocator, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                        }
                    } else {
                        val = eval.evalExpr(allocator, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
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
            // Optimized ORDER BY: instead of sorting the JSON row slices directly (which required
            // an O(n) scan to map slice->row index for every comparator call), sort a parallel
            // index array referencing precomputed key values. This drops comparator cost from
            // O(k * (n scan)) to O(k) where k = number of ORDER BY keys.
            const maybe_indices = allocator.alloc(usize, rows_json.items.len) catch null; // on OOM skip ordering optimization
            if (maybe_indices) |indices| {
                var fi: usize = 0;
                while (fi < indices.len) : (fi += 1) indices[fi] = fi;
                const ICtx = struct {
                    rows: [][]const u8,
                    ob: *const @TypeOf(ob),
                    keys: []KeyVal,
                    key_count: usize,
                };
                std.sort.block(usize, indices, ICtx{ .rows = rows_json.items, .ob = &ob, .keys = key_matrix, .key_count = key_count }, struct {
                    fn less(c: ICtx, a: usize, b: usize) bool {
                        var ki: usize = 0;
                        while (ki < c.ob.keys.len) : (ki += 1) {
                            const key_expr = c.ob.keys[ki];
                            const av = c.keys[a * c.key_count + ki];
                            const bv = c.keys[b * c.key_count + ki];
                            if (av.kind == .Null and bv.kind != .Null) {
                                if (g_nulls_last.*) {
                                    if (key_expr.desc) return true; // desc: null considered largest
                                    return false; // asc: null after non-null
                                } else {
                                    return !key_expr.desc; // nulls first
                                }
                            }
                            if (bv.kind == .Null and av.kind != .Null) {
                                if (g_nulls_last.*) {
                                    if (key_expr.desc) return false;
                                    return true;
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
                        // Stable deterministic tie-break: compare JSON row bytes.
                        const ra = c.rows[a];
                        const rb = c.rows[b];
                        if (std.mem.lessThan(u8, ra, rb)) return true;
                        return false;
                    }
                }.less);
                // Apply permutation to rows_json in new order.
                var new_rows_opt: ?std.ArrayList([]const u8) = std.ArrayList([]const u8).initCapacity(allocator, rows_json.items.len) catch null;
                if (new_rows_opt) |*new_rows| {
                    var oi: usize = 0;
                    while (oi < indices.len) : (oi += 1) new_rows.append(allocator, rows_json.items[indices[oi]]) catch {};
                    // Free old backing store but not individual row slices (still referenced).
                    allocator.free(rows_json.items);
                    rows_json.items = new_rows.items;
                    rows_json.capacity = new_rows.capacity;
                    // Prevent double free by disarming new_rows (we transferred ownership).
                    new_rows.items = &[_][]const u8{};
                    new_rows.capacity = 0;
                }
                allocator.free(indices);
            }
            if (timings) |tptr| {
                tptr.sort_ns = std.time.nanoTimestamp() - t_sort_start;
                tptr.sort_rows_in = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
                tptr.sort_rows_out = rows_json.items.len;
                var tbs: usize = 0;
                for (rows_json.items) |s| tbs += s.len;
                tptr.sort_bytes_out = tbs;
                if (alloc_tracker) |tr| {
                    const after = tr.getFn(tr.ctx);
                    const base = if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                    tptr.sort_bytes_alloc = if (after > base) after - base else 0;
                    tptr.net_after_sort = after;
                } else {
                    tptr.sort_bytes_alloc = tbs;
                    tptr.net_after_sort = (if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project) + tptr.sort_bytes_alloc;
                }
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
                const base = if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.offset_bytes_alloc = if (after > base) after - base else 0;
                tptr.net_after_offset = after;
            } else {
                tptr.offset_bytes_alloc = tbo;
                const base = if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.net_after_offset = base + tptr.offset_bytes_alloc;
            }
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
                const base = if (tptr.net_after_offset != 0) tptr.net_after_offset else if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.limit_bytes_alloc = if (after > base) after - base else 0;
                tptr.net_after_limit = after;
            } else {
                tptr.limit_bytes_alloc = tbl;
                const base = if (tptr.net_after_offset != 0) tptr.net_after_offset else if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.net_after_limit = base + tptr.limit_bytes_alloc;
            }
        }
    }
    if (start != 0 or end != rows_json.items.len) {
        var slice_rows = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        defer slice_rows.deinit(allocator);
        var start_i: usize = start;
        while (start_i < end) : (start_i += 1) slice_rows.append(allocator, rows_json.items[start_i]) catch {};
        // Free skipped rows
        var skip_i: usize = 0;
        while (skip_i < rows_json.items.len) : (skip_i += 1) if (skip_i < start or skip_i >= end) allocator.free(rows_json.items[skip_i]);
        rows_json.clearRetainingCapacity();
        for (slice_rows.items) |s| rows_json.append(allocator, s) catch {};
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
        if (tptr.distinct_bytes_alloc == 0) tptr.distinct_bytes_alloc = if (tptr.net_after_distinct != 0 and tptr.net_after_project != 0 and tptr.net_after_distinct >= tptr.net_after_project) tptr.net_after_distinct - tptr.net_after_project else tptr.project_bytes_alloc;
        if (tptr.expand_bytes_alloc == 0) tptr.expand_bytes_alloc = 0;
        if (tptr.sort_bytes_alloc == 0) tptr.sort_bytes_alloc = if (tptr.net_after_sort != 0) (if (tptr.net_after_distinct != 0) tptr.net_after_sort - tptr.net_after_distinct else tptr.net_after_sort - tptr.net_after_project) else tptr.distinct_bytes_alloc;
        if (tptr.offset_bytes_alloc == 0) tptr.offset_bytes_alloc = if (tptr.net_after_offset != 0) (if (tptr.net_after_sort != 0) tptr.net_after_offset - tptr.net_after_sort else tptr.net_after_offset - tptr.net_after_project) else tptr.sort_bytes_alloc;
        if (tptr.limit_bytes_alloc == 0) tptr.limit_bytes_alloc = if (q.limit != null and tptr.net_after_limit != 0) (if (tptr.net_after_offset != 0) tptr.net_after_limit - tptr.net_after_offset else tptr.net_after_limit - (if (tptr.net_after_sort != 0) tptr.net_after_sort else tptr.net_after_project)) else tptr.offset_bytes_alloc;
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(allocator) catch &.{};
}

/// Evaluate a UNION query with support for UNION, INTERSECT, EXCEPT operations
/// Supports both ALL and DISTINCT modifiers for each set operation
pub fn evaluateUnion(
    allocator: std.mem.Allocator,
    u: geode.ast.UnionQuery,
    param_names: [][]const u8,
    param_matrix: [][]const eval.Value,
    union_mode_out: *[]const u8,
    metrics: *UnionMetrics,
) ![][]const u8 {
    // Evaluate first component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    var result_rows = try evaluateSimpleQuery(allocator, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols, null, null, null);
    metrics.left_in = result_rows.len;

    // Import advanced set operations
    var set_ops = union_advanced.SetOperations.init(allocator);

    var any_all = false;
    var total_tail: usize = 0;
    var ti: usize = 0;
    while (ti < u.tails.len) : (ti += 1) {
        const part = u.tails[ti];
        if (part.all) any_all = true;
        var oc: []const protocol.SchemaCol = &.{};
        ordered = false;
        order_keys = &.{};
        const right_rows = try evaluateSimpleQuery(allocator, part.query, param_names, param_matrix, &ordered, &order_keys, &oc, null, null, null);
        total_tail += right_rows.len;

        // Apply the appropriate set operation
        const new_result = switch (part.operation) {
            .union_op => blk: {
                // Traditional UNION logic
                var all_rows = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
                defer all_rows.deinit(allocator);

                for (result_rows) |r| all_rows.append(allocator, r) catch {};
                for (right_rows) |r| all_rows.append(allocator, r) catch {};

                if (part.all) {
                    break :blk try all_rows.toOwnedSlice(allocator);
                } else {
                    // Apply DISTINCT
                    var hash_size: usize = 0;
                    var dummy_vals = std.ArrayList([]const eval.Value).initCapacity(allocator, 0) catch return error.OutOfMemory;
                    defer dummy_vals.deinit(allocator);
                    distinctDedup(allocator, false, 0, &all_rows, &dummy_vals, &hash_size);
                    metrics.hash_size = hash_size;
                    break :blk try all_rows.toOwnedSlice(allocator);
                }
            },
            .intersect => try set_ops.intersect(result_rows, right_rows, part.all),
            .except => try set_ops.except(result_rows, right_rows, part.all),
        };

        // Free previous result and update with new result
        allocator.free(result_rows);
        result_rows = new_result;
    }

    metrics.right_in = total_tail;
    metrics.out = result_rows.len;

    // Set operation mode for metrics
    if (u.tails.len > 0) {
        union_mode_out.* = switch (u.tails[0].operation) {
            .union_op => if (any_all) "UNION ALL" else "UNION DISTINCT",
            .intersect => if (any_all) "INTERSECT ALL" else "INTERSECT DISTINCT",
            .except => if (any_all) "EXCEPT ALL" else "EXCEPT DISTINCT",
        };
    } else {
        union_mode_out.* = "SINGLE";
    }

    if (metrics.hash_size == null) {
        metrics.hash_size = if (any_all) null else result_rows.len;
    }

    return result_rows;
}

/// Evaluate binary set operations (INTERSECT/EXCEPT) on two queries
/// Supports both ALL and DISTINCT modifiers with efficient hash-based implementation
pub fn evaluateBinarySet(
    allocator: std.mem.Allocator,
    left: geode.ast.Query,
    right: geode.ast.Query,
    param_names: [][]const u8,
    param_matrix: [][]const eval.Value,
    is_intersect: bool,
    all: bool,
) ![][]const u8 {
    var dcols: []const protocol.SchemaCol = &.{};
    var ord: bool = false;
    var oks: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(allocator, left, param_names, param_matrix, &ord, &oks, &dcols, null, null, null);
    ord = false;
    oks = &.{};
    dcols = &.{};
    const right_rows = try evaluateSimpleQuery(allocator, right, param_names, param_matrix, &ord, &oks, &dcols, null, null, null);

    if (all) {
        var lc = std.StringHashMap(usize).init(allocator);
        defer lc.deinit();
        var rc = std.StringHashMap(usize).init(allocator);
        defer rc.deinit();
        for (left_rows) |lr| {
            const key = canonicalRowKey(allocator, lr);
            const e = lc.getOrPut(key) catch continue;
            if (!e.found_existing) {
                e.key_ptr.* = key;
                e.value_ptr.* = 1;
            } else {
                e.value_ptr.* += 1;
                allocator.free(key);
            }
        }
        for (right_rows) |rr| {
            const key = canonicalRowKey(allocator, rr);
            const e = rc.getOrPut(key) catch continue;
            if (!e.found_existing) {
                e.key_ptr.* = key;
                e.value_ptr.* = 1;
            } else {
                e.value_ptr.* += 1;
                allocator.free(key);
            }
        }
        var out = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        defer out.deinit(allocator);
        var it = lc.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const lcnt = entry.value_ptr.*;
            const rcnt = rc.get(key) orelse 0;
            if (is_intersect) {
                const m = if (lcnt < rcnt) lcnt else rcnt;
                var i: usize = 0;
                while (i < m) : (i += 1) {
                    var found: []const u8 = &.{};
                    var li: usize = 0;
                    while (li < left_rows.len) : (li += 1) {
                        const k2 = canonicalRowKey(allocator, left_rows[li]);
                        const eq = std.mem.eql(u8, k2, key);
                        allocator.free(k2);
                        if (eq) {
                            found = left_rows[li];
                            break;
                        }
                    }
                    if (found.len == 0 and left_rows.len > 0) found = left_rows[0];
                    out.append(allocator, found) catch {};
                }
            } else {
                if (lcnt > rcnt) {
                    var d: usize = lcnt - rcnt;
                    while (d > 0) : (d -= 1) {
                        var found: []const u8 = &.{};
                        var li: usize = 0;
                        while (li < left_rows.len) : (li += 1) {
                            const k2 = canonicalRowKey(allocator, left_rows[li]);
                            const eq = std.mem.eql(u8, k2, key);
                            allocator.free(k2);
                            if (eq) {
                                found = left_rows[li];
                                break;
                            }
                        }
                        if (found.len == 0 and left_rows.len > 0) found = left_rows[0];
                        out.append(allocator, found) catch {};
                    }
                }
            }
        }
        var ri: usize = 0;
        while (ri < right_rows.len) : (ri += 1) allocator.free(right_rows[ri]);
        return out.toOwnedSlice(allocator) catch &.{};
    }

    var seen_left = std.StringHashMap(void).init(allocator);
    defer seen_left.deinit();
    var outd = std.StringHashMap([]const u8).init(allocator);
    defer outd.deinit();
    for (left_rows) |lr| {
        const key = canonicalRowKey(allocator, lr);
        if (!seen_left.contains(key)) {
            seen_left.put(key, {}) catch {};
            const e = outd.getOrPut(key) catch continue;
            if (!e.found_existing) e.value_ptr.* = lr else allocator.free(key);
        } else allocator.free(key);
    }
    var seen_right = std.StringHashMap(void).init(allocator);
    defer seen_right.deinit();
    for (right_rows) |rr| {
        const key = canonicalRowKey(allocator, rr);
        seen_right.put(key, {}) catch {};
        // do not free key; map holds reference for duration of function
    }
    var out_rows = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer out_rows.deinit(allocator);
    var it2 = outd.iterator();
    while (it2.next()) |entry| {
        const key = entry.key_ptr.*;
        const row = entry.value_ptr.*;
        const in_right = seen_right.contains(key);
        if (is_intersect) {
            if (in_right) out_rows.append(allocator, row) catch {};
        } else {
            if (!in_right) out_rows.append(allocator, row) catch {};
        }
    }
    var rr: usize = 0;
    while (rr < right_rows.len) : (rr += 1) allocator.free(right_rows[rr]);
    return out_rows.toOwnedSlice(allocator) catch &.{};
}
