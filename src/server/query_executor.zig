const std = @import("std");
const eval = @import("../eval.zig");
const exec = @import("../execution.zig");
const protocol = @import("../lib.zig").protocol;

// CANARY: REQ=REQ-SERVER-REFACTOR-006; FEATURE="ServerRefactoring"; ASPECT=QUERY_EXECUTOR; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.3 - Query Executor Module (Incremental Extraction)
// Extracted query utility functions from server/main.zig for better separation of concerns

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
