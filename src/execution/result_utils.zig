// CANARY: REQ=REQ-REFACTOR-MATCH-009; FEATURE="MatchOperationsRefactor"; ASPECT=ResultUtils; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Result processing utilities extracted from match_operations.zig
/// Contains column name generation and DISTINCT deduplication helpers
const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");
const Value = value_types.Value;

// Import ExecutionResult from execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// NOTE: This file uses `catch {}` for stdout/stderr I/O operations.
// Output write failures are non-critical — the query result is correct
// even if display fails.  See docs/FULL_AUDIT_2026_04_07.md.

// ============================================================================
// Column Name Generation
// ============================================================================

// CANARY: REQ=REQ-GQL-COLNAME-001; FEATURE="UniqueColumnNames"; ASPECT=DEDUP; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Generate unique column names for RETURN items, using qualified names for duplicates
/// For example, if both p.name and c.name exist, they become "p.name" and "c.name"
pub fn generateUniqueColumnNames(allocator: std.mem.Allocator, items: []const ast.ReturnItem) ![][]const u8 {
    var columns = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(columns);

    // First pass: collect raw column names and their qualified forms
    var raw_names = try allocator.alloc([]const u8, items.len);
    defer allocator.free(raw_names);
    var qualified_names = try allocator.alloc([]const u8, items.len);
    defer allocator.free(qualified_names);

    for (items, 0..) |item, i| {
        if (item.alias) |alias| {
            raw_names[i] = alias;
            qualified_names[i] = alias;
        } else {
            switch (item.expr) {
                .Ident => |ident| {
                    raw_names[i] = ident.orig;
                    qualified_names[i] = ident.orig;
                },
                .PropertyAccess => |prop| {
                    raw_names[i] = prop.property;
                    // Build qualified name: object.property
                    const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop.object, prop.property });
                    qualified_names[i] = qualified;
                },
                .Member => |mem| {
                    raw_names[i] = mem.field;
                    // Build qualified name if target is an identifier (e.g., p.name -> "p.name")
                    if (mem.target.* == .Ident) {
                        const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ mem.target.Ident.orig, mem.field });
                        qualified_names[i] = qualified;
                    } else {
                        qualified_names[i] = mem.field;
                    }
                },
                .Call => |call| {
                    if (call.callee.* == .Ident) {
                        raw_names[i] = call.callee.Ident.orig;
                        qualified_names[i] = call.callee.Ident.orig;
                    } else {
                        raw_names[i] = "column";
                        qualified_names[i] = "column";
                    }
                },
                else => {
                    raw_names[i] = "column";
                    qualified_names[i] = "column";
                },
            }
        }
    }

    // Second pass: detect duplicates and use qualified names where needed
    for (items, 0..) |_, i| {
        var is_duplicate = false;
        for (0..items.len) |j| {
            if (i != j and std.mem.eql(u8, raw_names[i], raw_names[j])) {
                is_duplicate = true;
                break;
            }
        }
        if (is_duplicate) {
            // Use qualified name for duplicates
            columns[i] = try allocator.dupe(u8, qualified_names[i]);
        } else {
            // Use raw name when no conflict
            columns[i] = try allocator.dupe(u8, raw_names[i]);
        }
    }

    // Clean up allocated qualified names (PropertyAccess and Member with Ident target allocate)
    for (items, 0..) |item, i| {
        if (item.alias == null) {
            switch (item.expr) {
                .PropertyAccess => allocator.free(qualified_names[i]),
                .Member => |mem| {
                    if (mem.target.* == .Ident) {
                        allocator.free(qualified_names[i]);
                    }
                },
                else => {},
            }
        }
    }

    return columns;
}

// ============================================================================
// Value Hash Helpers for DISTINCT
// ============================================================================

/// Write a hash representation of a Value (non-error version for applyDistinct)
fn writeValueHash(writer: anytype, val: Value) void {
    switch (val) {
        .Null => writer.writeAll("NULL") catch {},
        .Bool => |b| writer.print("{}", .{b}) catch {},
        .Int => |n| writer.print("{}", .{n}) catch {},
        .Str => |s| writer.writeAll(s) catch {},
        .Decimal => |d| writer.print("{}.{}", .{ d.coeff, d.scale }) catch {},
        .Node => |node| writer.print("Node:{}", .{node.id}) catch {},
        .Edge => |e| writer.print("Edge:{}", .{e.id}) catch {},
        .List => |list| {
            writer.writeAll("List[") catch {};
            for (list, 0..) |elem, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writeValueHash(writer, elem);
            }
            writer.writeAll("]") catch {};
        },
        .Map => |map| {
            writer.writeAll("Map{") catch {};
            var map_iter = map.iterator();
            var first = true;
            while (map_iter.next()) |entry| {
                if (!first) writer.writeAll(",") catch {};
                first = false;
                writer.writeAll(entry.key_ptr.*) catch {};
                writer.writeAll(":") catch {};
                writeValueHash(writer, entry.value_ptr.*);
            }
            writer.writeAll("}") catch {};
        },
        .Path => |path| {
            writer.writeAll("Path[") catch {};
            for (path.nodes, 0..) |node, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writer.print("Node:{}", .{node.id}) catch {};
            }
            writer.writeAll("]") catch {};
        },
        .ExtValue => writer.writeAll("ExtValue") catch {},
        else => writer.writeAll("Other") catch {},
    }
}

/// Write a hash representation of a Value (error-returning version for createRowHashKey)
fn writeValueHashChecked(writer: anytype, val: Value) !void {
    switch (val) {
        .Null => try writer.writeAll("NULL"),
        .Bool => |b| try writer.print("{}", .{b}),
        .Int => |n| try writer.print("{}", .{n}),
        .Str => |s| try writer.writeAll(s),
        .Decimal => |d| try writer.print("{}.{}", .{ d.coeff, d.scale }),
        .Node => |node| try writer.print("Node:{}", .{node.id}),
        .Edge => |e| try writer.print("Edge:{}", .{e.id}),
        .List => |list| {
            try writer.writeAll("List[");
            for (list, 0..) |elem, j| {
                if (j > 0) try writer.writeAll(",");
                try writeValueHashChecked(writer, elem);
            }
            try writer.writeAll("]");
        },
        .Map => |map| {
            try writer.writeAll("Map{");
            var map_iter = map.iterator();
            var first = true;
            while (map_iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll(":");
                try writeValueHashChecked(writer, entry.value_ptr.*);
            }
            try writer.writeAll("}");
        },
        .Path => |path| {
            try writer.writeAll("Path[");
            for (path.nodes, 0..) |node, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.print("Node:{}", .{node.id});
            }
            try writer.writeAll("]");
        },
        .ExtValue => try writer.writeAll("ExtValue"),
        else => try writer.writeAll("Other"),
    }
}

// ============================================================================
// DISTINCT Deduplication
// ============================================================================

// CANARY: REQ=REQ-GQL-DISTINCT-001; FEATURE="DISTINCT"; ASPECT=DEDUPLICATION; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Apply DISTINCT deduplication to result rows
pub fn applyDistinct(allocator: std.mem.Allocator, result: *ExecutionResult) !void {
    if (result.rows.len <= 1) return;

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Track keys for cleanup - StringHashMap doesn't own its keys
    var keys_to_free = try std.ArrayList([]u8).initCapacity(allocator, result.rows.len);
    defer {
        for (keys_to_free.items) |key| {
            allocator.free(key);
        }
        keys_to_free.deinit(allocator);
    }

    var unique_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
    defer unique_rows.deinit(allocator);

    for (result.rows) |row| {
        // Create a hash key from row values
        var key_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch continue;
        const writer = key_buf.writer(allocator);

        for (row, 0..) |val, i| {
            if (i > 0) writer.writeAll("|") catch {};
            switch (val) {
                .Null => writer.writeAll("NULL") catch {},
                .Bool => |b| writer.print("{}", .{b}) catch {},
                .Int => |n| writer.print("{}", .{n}) catch {},
                .Str => |s| writer.writeAll(s) catch {},
                .Decimal => |d| writer.print("{}.{}", .{ d.coeff, d.scale }) catch {},
                .Node => |node| writer.print("Node:{}", .{node.id}) catch {},
                .Edge => |e| writer.print("Edge:{}", .{e.id}) catch {},
                .List => |list| {
                    writer.writeAll("List[") catch {};
                    for (list, 0..) |elem, j| {
                        if (j > 0) writer.writeAll(",") catch {};
                        writeValueHash(writer, elem);
                    }
                    writer.writeAll("]") catch {};
                },
                .Map => |map| {
                    writer.writeAll("Map{") catch {};
                    var map_iter = map.iterator();
                    var first = true;
                    while (map_iter.next()) |entry| {
                        if (!first) writer.writeAll(",") catch {};
                        first = false;
                        writer.writeAll(entry.key_ptr.*) catch {};
                        writer.writeAll(":") catch {};
                        writeValueHash(writer, entry.value_ptr.*);
                    }
                    writer.writeAll("}") catch {};
                },
                .Path => |path| {
                    writer.writeAll("Path[") catch {};
                    for (path.nodes, 0..) |node, j| {
                        if (j > 0) writer.writeAll(",") catch {};
                        writer.print("Node:{}", .{node.id}) catch {};
                    }
                    writer.writeAll("]") catch {};
                },
                .ExtValue => writer.writeAll("ExtValue") catch {},
                else => writer.writeAll("Other") catch {},
            }
        }

        const key = key_buf.toOwnedSlice(allocator) catch {
            key_buf.deinit(allocator);
            continue;
        };

        if (!seen.contains(key)) {
            seen.put(key, {}) catch {
                allocator.free(key);
                continue;
            };
            // Track key for cleanup at end of function
            keys_to_free.append(allocator, key) catch {};
            try unique_rows.append(allocator, row);
        } else {
            // Duplicate - free the key immediately since we don't need it
            allocator.free(key);
            allocator.free(row);
        }
    }

    // Free the old rows slice and replace with deduplicated rows
    allocator.free(result.rows);
    result.rows = try unique_rows.toOwnedSlice(allocator);
}

// ============================================================================
// Row Hashing Utilities
// ============================================================================

/// Create a hash key string from a row of values for deduplication
pub fn createRowHashKey(allocator: std.mem.Allocator, row: []const Value) ![]u8 {
    var key_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer key_buf.deinit(allocator);
    const writer = key_buf.writer(allocator);

    for (row, 0..) |val, i| {
        if (i > 0) try writer.writeAll("|");
        switch (val) {
            .Null => try writer.writeAll("NULL"),
            .Bool => |b| try writer.print("{}", .{b}),
            .Int => |n| try writer.print("{}", .{n}),
            .Str => |s| try writer.writeAll(s),
            .Decimal => |d| try writer.print("{}.{}", .{ d.coeff, d.scale }),
            .Node => |node| try writer.print("Node:{}", .{node.id}),
            .Edge => |e| try writer.print("Edge:{}", .{e.id}),
            .List => |list| {
                try writer.writeAll("List[");
                for (list, 0..) |elem, j| {
                    if (j > 0) try writer.writeAll(",");
                    try writeValueHashChecked(writer, elem);
                }
                try writer.writeAll("]");
            },
            .Map => |map| {
                try writer.writeAll("Map{");
                var map_iter = map.iterator();
                var first = true;
                while (map_iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll(":");
                    try writeValueHashChecked(writer, entry.value_ptr.*);
                }
                try writer.writeAll("}");
            },
            .Path => |path| {
                try writer.writeAll("Path[");
                for (path.nodes, 0..) |node, j| {
                    if (j > 0) try writer.writeAll(",");
                    try writer.print("Node:{}", .{node.id});
                }
                try writer.writeAll("]");
            },
            .ExtValue => try writer.writeAll("ExtValue"),
            else => try writer.writeAll("Other"),
        }
    }

    return key_buf.toOwnedSlice(allocator);
}
