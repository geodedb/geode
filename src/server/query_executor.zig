const std = @import("std");
const eval = @import("../eval.zig");
const exec = @import("../execution.zig");
const protocol = @import("../lib.zig").protocol;
const geode = @import("geode");
const diagnostics = geode.diagnostics;

// CANARY: REQ=REQ-SERVER-REFACTOR-006; FEATURE="ServerRefactoring"; ASPECT=QUERY_EXECUTOR; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.3 - Query Executor Module (Incremental Extraction)
// Extracted query utility and diagnostic functions from server/main.zig for better separation of concerns

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
