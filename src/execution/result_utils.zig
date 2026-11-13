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
const value_utilities = @import("value_utilities.zig");
const distinct_set = @import("distinct_set.zig");

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
    // SONNY-6483 (5): the names are worked out on a scratch arena, and on a
    // failed allocation the columns already copied are freed (the qualified
    // names and the columns leaked).
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // First pass: collect raw column names and their qualified forms
    const raw_names = try sa.alloc([]const u8, items.len);
    const qualified_names = try sa.alloc([]const u8, items.len);

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
                    qualified_names[i] = try std.fmt.allocPrint(sa, "{s}.{s}", .{ prop.object, prop.property });
                },
                .Member => |mem| {
                    raw_names[i] = mem.field;
                    // Build qualified name if target is an identifier (e.g., p.name -> "p.name")
                    qualified_names[i] = if (mem.target.* == .Ident)
                        try std.fmt.allocPrint(sa, "{s}.{s}", .{ mem.target.Ident.orig, mem.field })
                    else
                        mem.field;
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

    const columns = try allocator.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (columns[0..filled]) |c| allocator.free(c);
        allocator.free(columns);
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
        // Use the qualified name for duplicates, the raw name otherwise.
        columns[i] = try allocator.dupe(u8, if (is_duplicate) qualified_names[i] else raw_names[i]);
        filled += 1;
    }

    return columns;
}

/// SONNY-6483: free what `generateUniqueColumnNames` returned.
pub fn freeColumnNames(allocator: std.mem.Allocator, columns: []const []const u8) void {
    for (columns) |c| allocator.free(c);
    allocator.free(columns);
}

// ============================================================================
// DISTINCT Deduplication
// ============================================================================

// CANARY: REQ=REQ-GQL-DISTINCT-001; FEATURE="DISTINCT"; ASPECT=DEDUPLICATION; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Apply DISTINCT deduplication to result rows. A row repeats an earlier row
/// when every cell has the same typed key (`distinct_set.writeGroupKeyPart`),
/// the identity GROUP BY and count(DISTINCT) use: 5 and '5' differ, 1 and 1.0
/// do not, NULL equals NULL.
///
/// SONNY-2735: the row key was a lossy rendering. Every double, date, time,
/// text, UUID or other typed value was the word "Other", so DISTINCT over
/// them returned one row whenever the streaming DISTINCT fast path declined
/// (with ORDER BY, say, or on the planned read); 5 and '5' were one value;
/// and a `|` inside a string could move a cell boundary.
pub fn applyDistinct(allocator: std.mem.Allocator, result: *ExecutionResult) !void {
    if (result.rows.len <= 1) return;

    // Keys first, so that nothing is freed until nothing can fail.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var key: std.Io.Writer.Allocating = .init(allocator);
    defer key.deinit();
    const keep = try allocator.alloc(bool, result.rows.len);
    defer allocator.free(keep);
    var kept: usize = 0;
    for (result.rows, keep) |row, *k| {
        key.clearRetainingCapacity();
        for (row) |val| try distinct_set.writeGroupKeyPart(&key.writer, scratch, val);
        const gop = try seen.getOrPut(scratch, key.written());
        k.* = !gop.found_existing;
        if (k.*) {
            gop.key_ptr.* = try scratch.dupe(u8, key.written());
            kept += 1;
        }
    }
    if (kept == result.rows.len) return;

    const unique_rows = try allocator.alloc([]Value, kept);
    var i: usize = 0;
    for (result.rows, keep) |row, k| {
        if (k) {
            unique_rows[i] = row;
            i += 1;
            continue;
        }
        // GAP-0535: free the dropped row's values when the result owns them
        if (result.owns_value_memory) {
            for (row) |val| value_utilities.freeValue(allocator, val);
        }
        allocator.free(row);
    }
    allocator.free(result.rows);
    result.rows = unique_rows;
}

// ============================================================================
// Row Hashing Utilities
// ============================================================================

/// A row's DISTINCT key: every cell's typed key (`distinct_set.writeGroupKeyPart`),
/// as `applyDistinct` compares rows (SONNY-2735: it was the same lossy
/// rendering). The caller owns the returned bytes.
pub fn createRowHashKey(allocator: std.mem.Allocator, row: []const Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var key: std.Io.Writer.Allocating = .init(allocator);
    defer key.deinit();
    for (row) |val| try distinct_set.writeGroupKeyPart(&key.writer, arena.allocator(), val);
    return allocator.dupe(u8, key.written());
}
