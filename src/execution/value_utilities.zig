//! Value Utilities Module (M1 Phase 12)
//! CANARY: REQ-EXEC-REFACTOR-012 - Value manipulation and serialization utilities
//!
//! This module contains utility functions for working with Values and ExecutionResults:
//! - Value duplication and memory management
//! - JSON serialization with FLE support
//! - Result set duplication

const std = @import("std");
const ast_mod = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
const property_codec = @import("../property_value_codec.zig");
const execution = @import("../execution.zig");
const value_types = @import("../value_types.zig");
const decimal_text = @import("../types/decimal_text.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-019; FEATURE="JSON Library Migration"; ASPECT=ValueUtilities; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
const json_lib = @import("json");

// Type aliases
const ExecutionResult = execution.ExecutionResult;
const Value = value_types.Value;

// GAP-0852 follow-up: the context-preferring role/tenant helpers used to live
// here as `currentUserRolePreferringContext` / `currentTenantIdPreferringContext`.
// They were duplicated across four modules and are now consolidated as
// `fle_integration.rolePreferringActiveContext` / `.tenantPreferringActiveContext`.

/// Write a string with proper RFC 8259 JSON escaping
/// Handles GQL doubled single quotes ('') -> single quote (')
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-020; FEATURE="JSON Library Migration"; ASPECT=StringEscaping; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '\'' => {
                // Check for doubled single quote (GQL escape)
                if (i + 1 < s.len and s[i + 1] == '\'') {
                    // Skip the second quote - output only one
                    try writer.writeByte('\'');
                    i += 2;
                } else {
                    // Single quote not doubled
                    try writer.writeByte('\'');
                    i += 1;
                }
            },
            '"' => {
                try writer.writeAll("\\\"");
                i += 1;
            },
            '\\' => {
                try writer.writeAll("\\\\");
                i += 1;
            },
            '\n' => {
                try writer.writeAll("\\n");
                i += 1;
            },
            '\r' => {
                try writer.writeAll("\\r");
                i += 1;
            },
            '\t' => {
                try writer.writeAll("\\t");
                i += 1;
            },
            0x08 => { // backspace
                try writer.writeAll("\\b");
                i += 1;
            },
            0x0C => { // form feed
                try writer.writeAll("\\f");
                i += 1;
            },
            else => {
                if (c < 0x20) {
                    // Control characters: escape as \u00XX
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
                i += 1;
            },
        }
    }
}

/// Duplicate an ExecutionResult, allocating new memory for all fields
pub fn duplicateResult(allocator: std.mem.Allocator, original: ExecutionResult) !ExecutionResult {
    // Duplicate columns
    const columns = try allocator.alloc([]const u8, original.columns.len);
    for (original.columns, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Duplicate rows
    const rows = try allocator.alloc([]Value, original.rows.len);
    for (original.rows, 0..) |row, i| {
        const new_row = try allocator.alloc(Value, row.len);
        for (row, 0..) |val, j| {
            new_row[j] = try duplicateValue(allocator, val);
        }
        rows[i] = new_row;
    }

    // Duplicate flags
    var flags = try std.ArrayList([]const u8).initCapacity(allocator, original.flags.items.len);
    for (original.flags.items) |flag| {
        try flags.append(allocator, try allocator.dupe(u8, flag));
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = flags,
        .owns_value_memory = true, // Duplicated result owns its value memory
    };
}

// CANARY: REQ=REQ-SONNY-3385-GRPC-OWNED-ENTITIES; FEATURE="GrpcStreaming"; ASPECT=OwnedGraphEntities; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=transport; UPDATED=2026-09-29
/// SONNY-3385: make every node and relationship `result`'s rows hold (in a
/// list, a map or a path too) a copy `result` owns in full: its labels,
/// properties, graph and tenant. For a result kept past the request that
/// produced it (the gRPC stored result, pulled page by page): a planned read
/// materializes a node's interior on the request's scratch arena, which the
/// transport returns to its pool when the request ends, so the next Pull
/// read freed memory (`MATCH (g:G {i: 1}) WITH g MATCH (n:Q) RETURN n`
/// aborted the server with an integer overflow in `nodeToProto`; a release
/// build would have sent freed memory). One element held twice is copied
/// once.
pub fn ownGraphEntities(allocator: std.mem.Allocator, result: *ExecutionResult) !void {
    const entities = try execution.OwnedGraphEntities.init(allocator);
    entities.destroy_node = destroyOwnedNode;
    entities.destroy_edge = destroyOwnedEdge;
    var copier = EntityCopier{ .allocator = allocator, .entities = entities };
    defer copier.nodes.deinit(allocator);
    defer copier.edges.deinit(allocator);
    errdefer entities.deinit();
    for (result.rows) |row| for (row) |*value| try copier.own(value);
    if (entities.nodes.items.len == 0 and entities.edges.items.len == 0) {
        entities.deinit();
        return;
    }
    // The entities the result tracked before: no row points at them now.
    if (result.owned_graph_entities) |old| old.deinit();
    result.owned_graph_entities = entities;
}

const EntityCopier = struct {
    allocator: std.mem.Allocator,
    entities: *execution.OwnedGraphEntities,
    nodes: std.AutoHashMapUnmanaged(usize, *graph_store.Node) = .empty,
    edges: std.AutoHashMapUnmanaged(usize, *graph_store.Edge) = .empty,

    fn own(self: *EntityCopier, value: *Value) anyerror!void {
        switch (value.*) {
            .Node => |n| value.* = .{ .Node = try self.node(n) },
            .Edge => |e| value.* = .{ .Edge = try self.edge(e) },
            .List => |items| for (items) |*item| try self.own(item),
            .Map => |map| {
                var it = map.valueIterator();
                while (it.next()) |item| try self.own(item);
            },
            // The executors allocate a path's arrays for the row (as
            // `match_operations.stabilizeValue` rewrites them).
            .Path => |path| {
                for (@constCast(path.nodes)) |*n| n.* = try self.node(n.*);
                for (@constCast(path.edges)) |*e| e.* = try self.edge(e.*);
            },
            else => {},
        }
    }

    fn node(self: *EntityCopier, src: *const graph_store.Node) !*graph_store.Node {
        const gop = try self.nodes.getOrPut(self.allocator, @intFromPtr(src));
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.nodes.remove(@intFromPtr(src));
        const labels = try self.allocator.alloc([]const u8, src.labels.len);
        for (labels) |*l| l.* = "";
        const copy = self.allocator.create(graph_store.Node) catch |err| {
            self.allocator.free(labels);
            return err;
        };
        copy.* = .{ .id = src.id, .labels = labels, .properties = graph_store.CompactPropertyMap.init(self.allocator), .graph_name = "", .tenant_id = "" };
        errdefer destroyOwnedNode(self.allocator, copy);
        for (src.labels, labels) |label, *out| out.* = try self.allocator.dupe(u8, label);
        try copyProperties(self.allocator, &src.properties, &copy.properties);
        copy.graph_name = try self.allocator.dupe(u8, src.graph_name);
        copy.tenant_id = try self.allocator.dupe(u8, src.tenant_id);
        try self.entities.trackNode(copy);
        gop.value_ptr.* = copy;
        return copy;
    }

    fn edge(self: *EntityCopier, src: *const graph_store.Edge) !*graph_store.Edge {
        const gop = try self.edges.getOrPut(self.allocator, @intFromPtr(src));
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.edges.remove(@intFromPtr(src));
        const copy = try self.allocator.create(graph_store.Edge);
        copy.* = .{ .id = src.id, .from_id = src.from_id, .to_id = src.to_id, .label = "", .properties = graph_store.CompactPropertyMap.init(self.allocator), .graph_name = "", .tenant_id = "" };
        errdefer destroyOwnedEdge(self.allocator, copy);
        copy.label = try self.allocator.dupe(u8, src.label);
        try copyProperties(self.allocator, &src.properties, &copy.properties);
        copy.graph_name = try self.allocator.dupe(u8, src.graph_name);
        copy.tenant_id = try self.allocator.dupe(u8, src.tenant_id);
        try self.entities.trackEdge(copy);
        gop.value_ptr.* = copy;
        return copy;
    }
};

fn copyProperties(allocator: std.mem.Allocator, src: *const graph_store.CompactPropertyMap, dst: *graph_store.CompactPropertyMap) !void {
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value: graph_store.PropertyValue = switch (entry.value_ptr.*) {
            .String => |str| .{ .String = try allocator.dupe(u8, str) },
            .ExtValue => |ext| .{ .ExtValue = try property_codec.cloneExtValue(allocator, ext) },
            else => entry.value_ptr.*,
        };
        errdefer property_codec.freePropertyValue(allocator, value);
        try dst.put(key, value);
    }
}

fn freeProperties(allocator: std.mem.Allocator, props: *graph_store.CompactPropertyMap) void {
    var it = props.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        property_codec.freePropertyValue(allocator, entry.value_ptr.*);
    }
    props.deinit();
}

fn freeNodeInterior(allocator: std.mem.Allocator, node: *graph_store.Node) void {
    freeProperties(allocator, &node.properties);
    for (node.labels) |label| if (label.len > 0) allocator.free(label);
    allocator.free(node.labels);
    if (node.graph_name.len > 0) allocator.free(node.graph_name);
    if (node.tenant_id.len > 0) allocator.free(node.tenant_id);
}

fn freeEdgeInterior(allocator: std.mem.Allocator, edge: *graph_store.Edge) void {
    freeProperties(allocator, &edge.properties);
    if (edge.label.len > 0) allocator.free(edge.label);
    if (edge.graph_name.len > 0) allocator.free(edge.graph_name);
    if (edge.tenant_id.len > 0) allocator.free(edge.tenant_id);
}

fn destroyOwnedNode(allocator: std.mem.Allocator, node: *graph_store.Node) void {
    freeNodeInterior(allocator, node);
    allocator.destroy(node);
}

fn destroyOwnedEdge(allocator: std.mem.Allocator, edge: *graph_store.Edge) void {
    freeEdgeInterior(allocator, edge);
    allocator.destroy(edge);
}

/// Helper function to duplicate a Value
pub fn duplicateValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .Null, .Int, .Bool, .Decimal => value, // These are copy-by-value
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .List => |list| blk: {
            const new_list = try allocator.alloc(Value, list.len);
            for (list, 0..) |item, i| {
                new_list[i] = try duplicateValue(allocator, item);
            }
            break :blk .{ .List = new_list };
        },
        .Map => |map_const| blk: {
            var map = map_const;
            var new_map = std.StringHashMap(Value).init(allocator);
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try duplicateValue(allocator, entry.value_ptr.*);
                try new_map.put(key, val);
            }
            break :blk .{ .Map = new_map };
        },
        .Node, .Edge, .Path => value, // These contain pointers but we'll shallow copy for now
        else => value, // Fallback for any other types
    };
}

// GAP-0535: functions whose eval implementation provably returns FRESH
// allocations on every .Str-producing path (verified against
// src/eval/call_handlers.zig — upper/lower always `allocator.alloc` a new
// buffer; non-Str inputs yield scalar Null). Projection adopts these results
// directly instead of duplicating them, which is what makes
// `RETURN UPPER('x')` leak-free under a strict allocator.
pub fn callAlwaysAllocates(callee: ast_mod.Expr) bool {
    const name = switch (callee) {
        .Ident => |ident| ident.orig,
        else => return false,
    };
    const owned_fns = [_][]const u8{ "upper", "toupper", "lower", "tolower" };
    for (owned_fns) |f| {
        if (std.ascii.eqlIgnoreCase(name, f)) return true;
    }
    return false;
}

/// GAP-0535: produce a row value the ExecutionResult fully OWNS.
///
/// eval.evalExpr has mixed ownership: string literals borrow AST memory,
/// identifiers borrow Env memory, and store-derived values borrow store
/// memory — while most function results are fresh allocations. A projection
/// result that sets `owns_value_memory = true` must never hold a borrowed
/// pointer, so:
///   - top-level calls to provably-allocating functions are adopted as-is;
///   - everything else is deep-duplicated (duplicateValue), leaving the
///     original with its real owner.
/// Residual (documented in docs/GQL_GAP_ANALYSIS.md): a non-whitelisted
/// expression that internally allocated (e.g. `CASE WHEN x THEN UPPER(y)
/// END`) leaks its intermediate under a strict allocator — same magnitude
/// as the pre-GAP-0535 behavior, and absorbed by the per-request arena
/// (GAP-0755) in production.
pub fn ensureOwnedProjectionValue(allocator: std.mem.Allocator, expr: ast_mod.Expr, value: Value) !Value {
    switch (expr) {
        .Call => |call| if (callAlwaysAllocates(call.callee.*)) return value,
        else => {},
    }
    return duplicateValue(allocator, value);
}

/// GAP-0535: convert a projected result into one that fully OWNS its row
/// values, using the projection item expressions to decide adopt-vs-duplicate
/// per column (see ensureOwnedProjectionValue). Cells without a matching item
/// (defensive) are always duplicated. Sets `owns_value_memory = true`.
pub fn adoptProjectionRowValues(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    items: []const ast_mod.ReturnItem,
) !void {
    if (result.owns_value_memory) return; // already owned
    for (result.rows) |row| {
        for (row, 0..) |val, i| {
            const adopt = i < items.len and adoptable: {
                switch (items[i].expr) {
                    .Call => |call| break :adoptable callAlwaysAllocates(call.callee.*),
                    else => break :adoptable false,
                }
            };
            if (!adopt) {
                row[i] = try duplicateValue(allocator, val);
            }
        }
    }
    result.owns_value_memory = true;
}

// CANARY: REQ=REQ-SONNY-3148-WRITE-LEAKS; FEATURE="WriteStatementOwnership"; ASPECT=EvaluatedValueOwnership; STATUS=TESTED; TEST=tests/test_sonny3148_write_leaks.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3148: whether `eval.evalExpr` allocates the value of `expr` for it:
/// a list literal's list, a map literal's map, a string concatenation, and a
/// call that always allocates (`callAlwaysAllocates`). Every other
/// expression may borrow its value (an identifier or a parameter the
/// caller's, a string literal the AST's, a property the store's).
pub fn evaluatesFresh(expr: ast_mod.Expr) bool {
    return switch (expr) {
        .ArrayLit, .Map => true,
        .Binary => |b| b.op == .Concat,
        .Call => |call| callAlwaysAllocates(call.callee.*),
        else => false,
    };
}

/// SONNY-3148: free what `eval.evalExpr` allocated when it evaluated `expr`
/// to `value`, and nothing it borrowed. A list literal frees its list and,
/// per element, what that element's expression allocated; a map literal its
/// map (its keys are the AST's) and what each value's expression allocated;
/// a string concatenation or an always-allocating call its string. Any other
/// expression is left: its value may be borrowed (see `evaluatesFresh`), so
/// an allocation it made stays a leak rather than becoming an invalid free.
/// `value` must be the value `evalExpr` returned for `expr`, not a copy, and
/// nothing may hold it after this returns.
pub fn freeEvaluatedValue(allocator: std.mem.Allocator, expr: ast_mod.Expr, value: Value) void {
    switch (expr) {
        .ArrayLit => |elems| {
            if (value != .List or value.List.len != elems.len) return;
            for (elems, value.List) |elem, item| freeEvaluatedValue(allocator, elem.*, item);
            allocator.free(value.List);
        },
        .Map => |props| {
            if (value != .Map) return;
            var map = value.Map;
            for (props, 0..) |prop, i| {
                // A later property with the same key replaced this one's value.
                if (propertyKeyRepeats(props[i + 1 ..], prop.key)) continue;
                if (map.get(prop.key)) |item| freeEvaluatedValue(allocator, prop.value.*, item);
            }
            map.deinit();
        },
        .Binary => |b| if (b.op == .Concat and value == .Str) allocator.free(value.Str),
        .Call => |call| if (callAlwaysAllocates(call.callee.*) and value == .Str) allocator.free(value.Str),
        else => {},
    }
}

fn propertyKeyRepeats(props: []const ast_mod.Property, key: []const u8) bool {
    for (props) |prop| if (std.mem.eql(u8, prop.key, key)) return true;
    return false;
}

/// SONNY-3148: whether any value of `rows` (walked through its lists and
/// maps) holds memory `freeEvaluatedValue(expr, value)` would free.
pub fn rowsHoldEvaluated(rows: []const []Value, expr: ast_mod.Expr, value: Value) bool {
    switch (expr) {
        .ArrayLit => |elems| {
            if (value != .List or value.List.len != elems.len) return false;
            if (rowsHoldBytes(rows, std.mem.sliceAsBytes(value.List))) return true;
            for (elems, value.List) |elem, item| if (rowsHoldEvaluated(rows, elem.*, item)) return true;
            return false;
        },
        .Map => |props| {
            if (value != .Map) return false;
            if (rowsHoldMap(rows, value.Map)) return true;
            for (props, 0..) |prop, i| {
                if (propertyKeyRepeats(props[i + 1 ..], prop.key)) continue;
                if (value.Map.get(prop.key)) |item| if (rowsHoldEvaluated(rows, prop.value.*, item)) return true;
            }
            return false;
        },
        .Binary, .Call => return evaluatesFresh(expr) and value == .Str and rowsHoldBytes(rows, value.Str),
        else => return false,
    }
}

fn rowsHoldBytes(rows: []const []Value, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (rows) |row| for (row) |v| if (valueHoldsBytes(v, bytes)) return true;
    return false;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_lo = @intFromPtr(a.ptr);
    const b_lo = @intFromPtr(b.ptr);
    return a_lo < b_lo + b.len and b_lo < a_lo + a.len;
}

fn valueHoldsBytes(v: Value, bytes: []const u8) bool {
    switch (v) {
        .Str => |s| return overlaps(s, bytes),
        .List => |items| {
            if (overlaps(std.mem.sliceAsBytes(items), bytes)) return true;
            for (items) |item| if (valueHoldsBytes(item, bytes)) return true;
        },
        .Map => |m| {
            var it = m.valueIterator();
            while (it.next()) |item| if (valueHoldsBytes(item.*, bytes)) return true;
        },
        else => {},
    }
    return false;
}

fn rowsHoldMap(rows: []const []Value, map: std.StringHashMap(Value)) bool {
    const metadata = map.unmanaged.metadata orelse return false;
    for (rows) |row| for (row) |v| if (valueHoldsMap(v, metadata)) return true;
    return false;
}

fn valueHoldsMap(v: Value, metadata: anytype) bool {
    switch (v) {
        .List => |items| for (items) |item| if (valueHoldsMap(item, metadata)) return true,
        .Map => |m| {
            if (m.unmanaged.metadata) |md| if (md == metadata) return true;
            var it = m.valueIterator();
            while (it.next()) |item| if (valueHoldsMap(item.*, metadata)) return true;
        },
        else => {},
    }
    return false;
}

/// SONNY-3148: make `result` own its row values (deep copies, and copies of
/// its flag strings, which `deinit` then frees too), so that memory its rows
/// borrowed can be freed. An owned result is left as it is: it holds copies.
/// On an OOM part-way, the copies made so far leak and the rows still borrow
/// (the flag is set last): the caller must then not free what they borrow.
pub fn ownResultValues(allocator: std.mem.Allocator, result: *ExecutionResult) !void {
    if (result.owns_value_memory) return;
    // A custom free applies to owned values only; a borrowed result with one
    // is not a shape any producer builds. Copying under it would pair
    // `duplicateValue` with a free that is not its inverse.
    if (result.free_value != null) return error.Unsupported;
    for (result.rows) |row| {
        for (row) |*val| val.* = try duplicateValue(allocator, val.*);
    }
    for (result.flags.items) |*flag| flag.* = try allocator.dupe(u8, flag.*);
    result.owns_value_memory = true;
}

/// Re-point the allocator captured INSIDE a result value at `allocator`.
///
/// A `Value.Map` is a managed `std.StringHashMap` that stores the allocator it
/// was created with. When a read/write budget scope is active, result rows are
/// built on a stack-local `MeteredAllocator` wrapper (a pass-through over the
/// real allocator); that wrapper dies with the dispatching frame. The map's
/// backing memory is fine to free via the inner allocator, but `map.deinit()`
/// calls through the map's *stored* allocator — the dangling stack wrapper —
/// segfaulting during ExecutionResult.deinit (the map-free crash exposed by the
/// gql_compliance suite's `RETURN {..}` once geode#875(i) widened read-scope
/// activation to MATCH-free reads; also latent for `MATCH .. RETURN {..}`).
/// Repointing to the inner allocator is safe because the wrapper is pass-through.
/// Recurses into nested maps and lists; other Value types are either unmanaged
/// (slices freed via the passed-in allocator) or not deinit'd through a captured
/// allocator, so they need no repoint.
pub fn repointValueAllocators(val: *Value, allocator: std.mem.Allocator) void {
    switch (val.*) {
        .Map => {
            val.Map.allocator = allocator;
            var it = val.Map.iterator();
            while (it.next()) |entry| {
                repointValueAllocators(entry.value_ptr, allocator);
            }
        },
        .List => |list| {
            for (list) |*item| repointValueAllocators(item, allocator);
        },
        else => {},
    }
}

/// Helper function to free a Value's allocated memory
pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .List => |list| {
            for (list) |item| {
                freeValue(allocator, item);
            }
            allocator.free(list);
        },
        .Map => |map_const| {
            var map = map_const;
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        else => {}, // Other types don't own memory or are shallow copies
    }
}

/// P2-3: Now accepts allocator parameter for temporary allocations
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-021; FEATURE="JSON Library Migration"; ASPECT=WriteValue; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
pub fn writeValue(allocator: std.mem.Allocator, writer: anytype, value: Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Int => |n| try writer.print("{d}", .{n}),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Str => |s| {
            try writer.writeByte('"');
            // Use RFC 8259 compliant JSON string escaping with GQL quote handling
            try writeJsonEscapedString(writer, s);
            try writer.writeByte('"');
        },
        .Decimal => |d| {
            // Format decimal with proper scale
            if (d.scale == 0) {
                try writer.print("{d}", .{d.coeff});
            } else {
                // SONNY-2769: `std.math.pow(i64, 10, scale)` panicked past
                // scale 18; an exact whole value is checked with the i128
                // power (the value is fractional past 10^38).
                const divisor = @import("../types/narrowing.zig").pow10(d.scale);
                if (divisor != null and @rem(d.coeff, divisor.?) == 0) {
                    try writer.print("{d}", .{@divTrunc(d.coeff, divisor.?)});
                } else {
                    // Format with decimal point
                    const f: f64 = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                    try writer.print("{d}", .{f});
                }
            }
        },
        .List => |list| {
            try writer.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .Node => |node| {
            // For now, output node as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d}", .{node.id});
            if (node.labels.len > 0) {
                try writer.writeAll(",\"labels\":[");
                for (node.labels, 0..) |label, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.writeByte('"');
                    try writer.writeAll(label);
                    try writer.writeByte('"');
                }
                try writer.writeAll("]");
            }
            // Add properties if any
            if (node.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = node.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    switch (entry.value_ptr.*) {
                        .String => |s| {
                            // GAP-0203: Skip FLE entirely when no encrypted fields configured
                            // CANARY: REQ=REQ-PERF-FLE-SKIP-003; FEATURE="FLESkipOptimization"; ASPECT=NodePropertyWrite; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
                            if (fle_integration.hasEncryptedFields()) {
                                // Field-Level Encryption: decrypt if configured
                                const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                                const user_role = fle_integration.rolePreferringActiveContext();
                                const fle_ctx = fle_integration.EncryptionContext{
                                    .tenant_id = fle_integration.tenantPreferringActiveContext(),
                                    .schema_name = type_name,
                                    .allocator = allocator,
                                    .current_user_role = user_role,
                                };
                                const record_id_buf = try std.fmt.allocPrint(allocator, "{d}", .{node.id});
                                defer allocator.free(record_id_buf);

                                const decrypted = fle_integration.decryptFieldIfNeeded(
                                    fle_ctx,
                                    type_name,
                                    entry.key_ptr.*,
                                    s,
                                    record_id_buf,
                                    true,
                                ) catch |err| blk_decrypt: {
                                    if (err == error.SearchNotPermitted) {
                                        break :blk_decrypt "[REDACTED]";
                                    }
                                    // SONNY-6324: fail closed, never the stored bytes.
                                    if (err == error.FleCatalogUnavailable) return error.FleCatalogUnavailable;
                                    break :blk_decrypt s;
                                };

                                try writer.writeByte('"');
                                try writer.writeAll(decrypted);
                                try writer.writeByte('"');
                            } else {
                                // Fast path: no FLE configured, write string directly
                                try writer.writeByte('"');
                                try writeJsonEscapedString(writer, s);
                                try writer.writeByte('"');
                            }
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        // SONNY-2769: at any scale (`divisor *= 10` overflowed
                        // past 38; a value between -1 and 0 lost its sign).
                        .Decimal => |d| try decimal_text.write(writer, d.coeff, d.scale),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => {
                            const projected = try property_codec.propertyValueToProjectedValue(allocator, entry.value_ptr.*);
                            defer property_codec.freeValue(allocator, projected);
                            try writeValue(allocator, writer, projected);
                        },
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Edge => |edge| {
            // Output edge as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d},\"from\":{d},\"to\":{d},\"type\":\"{s}\"", .{ edge.id, edge.from_id, edge.to_id, edge.label });
            // Add properties if any
            if (edge.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = edge.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    const prop_value = entry.value_ptr.*;
                    switch (prop_value) {
                        .String => |s| {
                            // GAP-0203: Skip FLE entirely when no encrypted fields configured
                            // CANARY: REQ=REQ-PERF-FLE-SKIP-004; FEATURE="FLESkipOptimization"; ASPECT=EdgePropertyWrite; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
                            if (fle_integration.hasEncryptedFields()) {
                                const type_name = edge.label;
                                const fle_ctx = fle_integration.EncryptionContext{
                                    .tenant_id = fle_integration.tenantPreferringActiveContext(),
                                    .schema_name = type_name,
                                    .allocator = allocator,
                                    .current_user_role = fle_integration.rolePreferringActiveContext(),
                                };
                                const record_id_buf = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge.id});
                                defer allocator.free(record_id_buf);

                                const decrypted = fle_integration.decryptFieldIfNeeded(
                                    fle_ctx,
                                    type_name,
                                    entry.key_ptr.*,
                                    s,
                                    record_id_buf,
                                    true,
                                ) catch |err| blk_decrypt: {
                                    if (err == error.SearchNotPermitted) {
                                        break :blk_decrypt "[REDACTED]";
                                    }
                                    // SONNY-6324: fail closed, never the stored bytes.
                                    if (err == error.FleCatalogUnavailable) return error.FleCatalogUnavailable;
                                    break :blk_decrypt s;
                                };

                                try writer.writeByte('"');
                                try writer.writeAll(decrypted);
                                try writer.writeByte('"');
                            } else {
                                // Fast path: no FLE configured, write string directly
                                try writer.writeByte('"');
                                try writeJsonEscapedString(writer, s);
                                try writer.writeByte('"');
                            }
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        // SONNY-2769: at any scale (`divisor *= 10` overflowed
                        // past 38; a value between -1 and 0 lost its sign).
                        .Decimal => |d| try decimal_text.write(writer, d.coeff, d.scale),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => {
                            const projected = try property_codec.propertyValueToProjectedValue(allocator, prop_value);
                            defer property_codec.freeValue(allocator, projected);
                            try writeValue(allocator, writer, projected);
                        },
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Map => |map| {
            try writer.writeByte('{');
            var iter = map.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeByte('"');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\":");
                try writeValue(allocator, writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .ExtValue => |ext| {
            // Convert extended types to JSON strings
            switch (ext) {
                .Null => try writer.writeAll("null"),
                .Int => |n| try writer.print("{d}", .{n}),
                .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                .Str => |s| {
                    try writer.writeByte('"');
                    try writeJsonEscapedString(writer, s);
                    try writer.writeByte('"');
                },
                .Decimal => |d| {
                    // Format decimal with proper scale
                    if (d.scale == 0) {
                        try writer.print("{d}", .{d.coeff});
                    } else {
                        // SONNY-2769: see above (f64, not a panicking i64 power).
                        const f: f64 = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                        try writer.print("{d}", .{f});
                    }
                },
                .VectorF32 => {
                    try writer.writeAll("\"[vector]\"");
                },
                .IpAddr => |ip| {
                    try writer.writeByte('"');
                    switch (ip) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7] });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Subnet => |subnet| {
                    try writer.writeByte('"');
                    switch (subnet.addr) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}/{d}", .{ octets[0], octets[1], octets[2], octets[3], subnet.prefix_len }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}/{d}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7], subnet.prefix_len });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Mac => |mac| {
                    try writer.print("\"{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}\"", .{ mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5] });
                },
                .Hash => |hash| {
                    try writer.print("\"[hash:{s}]\"", .{@tagName(hash.alg)});
                },
                .LatLon => |latlon| {
                    try writer.print("\"({d:.6},{d:.6})\"", .{ latlon.lat, latlon.lon });
                },
                .LatLonAlt => |latlonalt| {
                    try writer.print("\"({d:.6},{d:.6},{d:.2}m)\"", .{ latlonalt.lat, latlonalt.lon, latlonalt.alt });
                },
                .Date => |date| {
                    // Format date as YYYY-MM-DD using civil calendar algorithm
                    // Convert days since Unix epoch (1970-01-01) to Gregorian Y-M-D

                    // Shift from Unix epoch to use algorithm starting from 0000-03-01
                    const z: i64 = @as(i64, date.days_since_epoch) + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}\"", .{ @abs(y), m, d });
                },
                .Time => |time| {
                    // Format time as HH:MM:SS.ffffff
                    const micros = time.micros_since_midnight;
                    const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
                    const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
                    const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(remaining_after_mins - @as(i64, seconds) * 1_000_000);

                    try writer.print("\"{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ hours, minutes, seconds, microseconds });
                },
                .TimestampTZ => |ts| {
                    // Format timestamp as ISO8601: YYYY-MM-DDTHH:MM:SS.ffffffZ
                    const micros = ts.micros_since_epoch_utc;
                    const seconds_since_epoch = @divFloor(micros, 1_000_000);
                    const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);

                    // Calculate time of day, handling negative timestamps correctly
                    var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
                    if (time_of_day_micros < 0) {
                        time_of_day_micros += 86400 * 1_000_000;
                    }

                    // Date part using civil calendar algorithm
                    const z: i64 = days_since_epoch + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    // Time part
                    const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
                    const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
                    const rem_after_mins = rem_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z\"", .{ @abs(y), m, d, hours, minutes, secs, microseconds });
                },
                else => try writer.writeAll("\"[advanced_type]\""),
            }
        },
        .Path => |path| {
            // Output path as JSON object with nodes and edges
            try writer.writeAll("{\"nodes\":[");
            for (path.nodes, 0..) |node, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{node.id});
            }
            try writer.writeAll("],\"edges\":[");
            for (path.edges, 0..) |edge, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{edge.id});
            }
            try writer.writeAll("]}");
        },
        // Advanced numeric types
        .SmallInt => |n| try writer.print("{d}", .{n}),
        .BigInt => |n| try writer.print("{d}", .{n}),
        .Real => |f| try writer.print("{d}", .{f}),
        .Double => |f| try writer.print("{d}", .{f}),
        // String types
        .Char => |c| {
            try writer.writeByte('"');
            try writer.writeAll(c.data);
            try writer.writeByte('"');
        },
        .Varchar => |v| {
            try writer.writeByte('"');
            try writer.writeAll(v.data);
            try writer.writeByte('"');
        },
        .Text => |t| {
            try writer.writeByte('"');
            try writer.writeAll(t);
            try writer.writeByte('"');
        },
        // Date/time types
        .Date => |date| {
            // Format date as YYYY-MM-DD
            const z: i64 = @as(i64, date.days_since_epoch) + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const m: u32 = if (mp < 10) mp + 3 else mp - 9;
            const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}\"", .{ @abs(y), m, d });
        },
        .Time => |time| {
            const micros = time.micros_since_midnight;
            const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
            const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
            const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
            const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
            const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(remaining_after_mins - @as(i64, seconds) * 1_000_000);
            try writer.print("\"{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ hours, minutes, seconds, microseconds });
        },
        .TimeTZ => |t| {
            const micros = t.time.micros_since_midnight;
            const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
            const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
            const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
            const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
            const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
            // offset_seconds is in seconds, convert to hours:minutes
            const offset_hours = @divTrunc(@abs(t.offset_seconds), 3600);
            const offset_mins = @divTrunc(@rem(@abs(t.offset_seconds), 3600), 60);
            if (t.offset_seconds >= 0) {
                try writer.print("\"{:0>2}:{:0>2}:{:0>2}+{:0>2}:{:0>2}\"", .{ hours, minutes, seconds, offset_hours, offset_mins });
            } else {
                try writer.print("\"{:0>2}:{:0>2}:{:0>2}-{:0>2}:{:0>2}\"", .{ hours, minutes, seconds, offset_hours, offset_mins });
            }
        },
        .Timestamp => |ts| {
            const micros = ts.micros_since_epoch;
            const seconds_since_epoch = @divFloor(micros, 1_000_000);
            const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);
            var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
            if (time_of_day_micros < 0) time_of_day_micros += 86400 * 1_000_000;
            const z: i64 = days_since_epoch + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const day: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const month: u32 = if (mp < 10) mp + 3 else mp - 9;
            const year: i64 = y_tmp + @as(i64, if (month <= 2) @as(u32, 1) else @as(u32, 0));
            const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
            const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
            const mins: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
            const rem_after_mins = rem_after_hours - @as(i64, mins) * 60 * 1_000_000;
            const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ @abs(year), month, day, hours, mins, secs, microseconds });
        },
        .TimestampTZ => |ts| {
            const micros = ts.micros_since_epoch_utc;
            const seconds_since_epoch = @divFloor(micros, 1_000_000);
            const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);
            var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
            if (time_of_day_micros < 0) time_of_day_micros += 86400 * 1_000_000;
            const z: i64 = days_since_epoch + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const day: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const month: u32 = if (mp < 10) mp + 3 else mp - 9;
            const year: i64 = y_tmp + @as(i64, if (month <= 2) @as(u32, 1) else @as(u32, 0));
            const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
            const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
            const mins: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
            const rem_after_mins = rem_after_hours - @as(i64, mins) * 60 * 1_000_000;
            const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z\"", .{ @abs(year), month, day, hours, mins, secs, microseconds });
        },
        .Interval => |i| {
            try writer.print("\"P{d}M{d}DT{d}S\"", .{ i.months, i.days, @divFloor(i.micros, 1_000_000) });
        },
        // Binary and document types
        .Bytea => |b| {
            try writer.writeAll("\"\\\\x");
            for (b) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeByte('"');
        },
        .Json => |j| {
            // JSON is already valid JSON, write directly
            try writer.writeAll(j);
        },
        .Jsonb => |j| {
            try writer.writeAll(j.data);
        },
        .Xml => |x| {
            try writer.writeByte('"');
            try writer.writeAll(x.data);
            try writer.writeByte('"');
        },
        // Network and identifier types
        .Url => |u| {
            try writer.writeByte('"');
            try writer.writeAll(u.scheme);
            try writer.writeAll("://");
            try writer.writeAll(u.host);
            if (u.port) |port| {
                try writer.print(":{d}", .{port});
            }
            try writer.writeAll(u.path);
            if (u.query) |query| {
                try writer.writeByte('?');
                try writer.writeAll(query);
            }
            if (u.fragment) |fragment| {
                try writer.writeByte('#');
                try writer.writeAll(fragment);
            }
            try writer.writeByte('"');
        },
        .Domain => |d| {
            try writer.writeByte('"');
            for (d.labels, 0..) |label, i| {
                if (i > 0) try writer.writeByte('.');
                try writer.writeAll(label);
            }
            try writer.writeByte('"');
        },
        .UUID => |u| {
            try writer.print("\"{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}\"", .{
                std.mem.readInt(u32, u.bytes[0..4], .big),
                std.mem.readInt(u16, u.bytes[4..6], .big),
                std.mem.readInt(u16, u.bytes[6..8], .big),
                std.mem.readInt(u16, u.bytes[8..10], .big),
                std.mem.readInt(u48, u.bytes[10..16], .big),
            });
        },
        // Other types
        .Enum => |e| {
            try writer.print("\"enum({d}:{d})\"", .{ e.type_id, e.value_ordinal });
        },
        .BitString => |b| {
            try writer.writeAll("\"B'");
            for (0..b.bit_length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                const bit = (b.bytes[byte_idx] >> bit_idx) & 1;
                try writer.writeByte(if (bit == 1) '1' else '0');
            }
            try writer.writeAll("'\"");
        },
        .VarBit => |b| {
            try writer.writeAll("\"B'");
            for (0..b.bit_length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                const bit = (b.bytes[byte_idx] >> bit_idx) & 1;
                try writer.writeByte(if (bit == 1) '1' else '0');
            }
            try writer.writeAll("'\"");
        },
        .IntRange => |r| {
            // Output range with proper bounds notation
            const bounds_str = r.bounds.toString();
            const lower_str = if (r.lower) |l| l else null;
            const upper_str = if (r.upper) |u| u else null;
            try writer.writeByte('"');
            try writer.writeByte(bounds_str[0]);
            if (lower_str) |l| {
                try writer.print("{d}", .{l});
            }
            try writer.writeByte(',');
            if (upper_str) |u| {
                try writer.print("{d}", .{u});
            }
            try writer.writeByte(bounds_str[1]);
            try writer.writeByte('"');
        },
    }
}
