// Meta-Procedure Dispatch — db.* and dbms.* introspection
//
// Implements the standard graph-database introspection procedures that any
// CLI/IDE/LSP integration expects to be available:
//
//   db.labels()             -> rows of (label STRING)
//   db.relationshipTypes()  -> rows of (relationshipType STRING)
//   db.propertyKeys()       -> rows of (propertyKey STRING)
//   db.indexes()            -> rows of (name, type, label, properties)
//   db.constraints()        -> rows of (name, type, label, properties)
//   dbms.procedures()       -> rows of (name, signature, description)
//   dbms.functions()        -> rows of (name, signature, description, category)
//
// Procedure names are received in canonical lowercase form because
// `procedure_registry.executeCallProcedure` calls `extractNormalizedProcName`
// at the dispatch entry point (see GAP-0528). All comparisons in this file
// therefore use exact-match against lowercase literals.
//
// CANARY: REQ=GAP-0531; FEATURE="DB/DBMS Introspection Procedures"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_meta_procedures.zig; OWNER=execution; UPDATED=2026-04-10

const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");
const language_metadata = @import("../gql/language_metadata.zig");

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table — O(1) lookup replaces sequential if-else chain.
// All handlers share a uniform signature; unused parameters are discarded.
// ---------------------------------------------------------------------------
const MetaHandler = *const fn (std.mem.Allocator, *graph_store.GraphStore, ExecutionContext) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(MetaHandler).initComptime(.{
    // db.* graph introspection
    .{ "db.labels", handleDbLabels },
    .{ "db.relationshiptypes", handleDbRelationshipTypes },
    .{ "db.propertykeys", handleDbPropertyKeys },
    .{ "db.indexes", handleDbIndexes },
    .{ "db.constraints", handleDbConstraints },
    // dbms.* server introspection
    .{ "dbms.procedures", handleDbmsProcedures },
    .{ "dbms.functions", handleDbmsFunctions },
});

// ---- Uniform-signature wrappers ----

// CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=ContextThreading; STATUS=TESTED; TEST=tests/test_gps_show_metadata.zig; OWNER=security; UPDATED=2026-05-20
fn handleDbLabels(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) anyerror!ExecutionResult {
    return executeDbLabels(allocator, store, ctx);
}
fn handleDbRelationshipTypes(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) anyerror!ExecutionResult {
    return executeDbRelationshipTypes(allocator, store, ctx);
}
fn handleDbPropertyKeys(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) anyerror!ExecutionResult {
    return executeDbPropertyKeys(allocator, store, ctx);
}
fn handleDbIndexes(allocator: std.mem.Allocator, _: *graph_store.GraphStore, context: ExecutionContext) anyerror!ExecutionResult {
    return executeDbIndexes(allocator, context);
}
fn handleDbConstraints(allocator: std.mem.Allocator, _: *graph_store.GraphStore, context: ExecutionContext) anyerror!ExecutionResult {
    return executeDbConstraints(allocator, context);
}
fn handleDbmsProcedures(allocator: std.mem.Allocator, _: *graph_store.GraphStore, _: ExecutionContext) anyerror!ExecutionResult {
    return executeDbmsProcedures(allocator);
}
fn handleDbmsFunctions(allocator: std.mem.Allocator, _: *graph_store.GraphStore, _: ExecutionContext) anyerror!ExecutionResult {
    return executeDbmsFunctions(allocator);
}

/// Execute a db.* or dbms.* introspection procedure.
/// Returns null if the procedure name is not recognized by this dispatcher
/// (caller falls through to other dispatchers).
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    store: *graph_store.GraphStore,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    _ = call_stmt;

    if (dispatch_table.get(proc_name)) |handler| {
        return try handler(allocator, store, context);
    }

    return null;
}

// ===========================================================================
// db.labels() — distinct node labels across all nodes in the store
// ===========================================================================

fn executeDbLabels(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    _ = ctx; // TODO(task 3-4): use ctx for tenant+graph filtering
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);

    var iter = store.nodes.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.labels) |lbl| {
            const gop = try seen.getOrPut(lbl);
            if (!gop.found_existing) {
                try ordered.append(allocator, lbl);
            }
        }
    }

    std.mem.sort([]const u8, ordered.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "label");

    const rows = try allocator.alloc([]Value, ordered.items.len);
    for (ordered.items, 0..) |lbl, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = .{ .Str = try allocator.dupe(u8, lbl) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// db.relationshipTypes() — distinct edge labels across all edges
// ===========================================================================

fn executeDbRelationshipTypes(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    _ = ctx; // TODO(task 3-5): use ctx for tenant+graph filtering
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);

    var iter = store.edges.iterator();
    while (iter.next()) |entry| {
        const ty = entry.value_ptr.label;
        const gop = try seen.getOrPut(ty);
        if (!gop.found_existing) {
            try ordered.append(allocator, ty);
        }
    }

    std.mem.sort([]const u8, ordered.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "relationshipType");

    const rows = try allocator.alloc([]Value, ordered.items.len);
    for (ordered.items, 0..) |ty, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = .{ .Str = try allocator.dupe(u8, ty) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// db.propertyKeys() — distinct property keys across all nodes and edges
// ===========================================================================

fn executeDbPropertyKeys(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    _ = ctx; // TODO(task 3-6): use ctx for tenant+graph filtering
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);

    // Collect from nodes
    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        var prop_iter = entry.value_ptr.properties.iterator();
        while (prop_iter.next()) |p| {
            const key = p.key_ptr.*;
            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) {
                try ordered.append(allocator, key);
            }
        }
    }

    // Collect from edges
    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        var prop_iter = entry.value_ptr.properties.iterator();
        while (prop_iter.next()) |p| {
            const key = p.key_ptr.*;
            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) {
                try ordered.append(allocator, key);
            }
        }
    }

    std.mem.sort([]const u8, ordered.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "propertyKey");

    const rows = try allocator.alloc([]Value, ordered.items.len);
    for (ordered.items, 0..) |key, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = .{ .Str = try allocator.dupe(u8, key) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// db.indexes() — list all indexes from the catalog
// Columns: name, type, label, properties (comma-joined)
// ===========================================================================

fn executeDbIndexes(allocator: std.mem.Allocator, context: ExecutionContext) !ExecutionResult {
    const catalog = context.catalog;
    const indexes = try catalog.listAllIndexes(allocator);
    defer allocator.free(indexes);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "type");
    columns[2] = try allocator.dupe(u8, "label");
    columns[3] = try allocator.dupe(u8, "properties");

    const rows = try allocator.alloc([]Value, indexes.len);
    for (indexes, 0..) |idx, i| {
        const row = try allocator.alloc(Value, 4);
        row[0] = .{ .Str = try allocator.dupe(u8, idx.name) };
        row[1] = .{ .Str = try allocator.dupe(u8, idx.index_type) };
        row[2] = .{ .Str = try allocator.dupe(u8, idx.table_name) };
        row[3] = .{ .Str = try joinStrings(allocator, idx.columns, ", ") };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// db.constraints() — list all constraints from the catalog
// Columns: name, type, label, properties (comma-joined), enforced
// ===========================================================================

fn executeDbConstraints(allocator: std.mem.Allocator, context: ExecutionContext) !ExecutionResult {
    const catalog = context.catalog;
    const constraints = try catalog.listAllConstraints(allocator);
    defer allocator.free(constraints);

    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "type");
    columns[2] = try allocator.dupe(u8, "label");
    columns[3] = try allocator.dupe(u8, "properties");
    columns[4] = try allocator.dupe(u8, "enforced");

    const rows = try allocator.alloc([]Value, constraints.len);
    for (constraints, 0..) |c, i| {
        const row = try allocator.alloc(Value, 5);
        row[0] = .{ .Str = try allocator.dupe(u8, c.name) };
        row[1] = .{ .Str = try allocator.dupe(u8, constraintTypeName(c.constraint_type)) };
        row[2] = .{ .Str = try allocator.dupe(u8, c.label) };
        row[3] = .{ .Str = try joinStrings(allocator, c.properties, ", ") };
        row[4] = .{ .Bool = c.is_enforced };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// dbms.procedures() — list every procedure from the language metadata catalog
// Columns: name, signature, description
// ===========================================================================

fn executeDbmsProcedures(allocator: std.mem.Allocator) !ExecutionResult {
    const procs = language_metadata.procedures;

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "signature");
    columns[2] = try allocator.dupe(u8, "description");

    const rows = try allocator.alloc([]Value, procs.len);
    for (procs, 0..) |p, i| {
        const row = try allocator.alloc(Value, 3);
        row[0] = .{ .Str = try allocator.dupe(u8, p.name) };
        row[1] = .{ .Str = try buildProcedureSignature(allocator, p) };
        row[2] = .{ .Str = try allocator.dupe(u8, p.doc) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ===========================================================================
// dbms.functions() — list every built-in function from language metadata
// Columns: name, signature, description, category
// ===========================================================================

fn executeDbmsFunctions(allocator: std.mem.Allocator) !ExecutionResult {
    const funcs = language_metadata.functions;

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "signature");
    columns[2] = try allocator.dupe(u8, "description");
    columns[3] = try allocator.dupe(u8, "category");

    const rows = try allocator.alloc([]Value, funcs.len);
    for (funcs, 0..) |f, i| {
        const row = try allocator.alloc(Value, 4);
        row[0] = .{ .Str = try allocator.dupe(u8, f.name) };
        row[1] = .{ .Str = try buildFunctionSignature(allocator, f) };
        row[2] = .{ .Str = try allocator.dupe(u8, f.doc) };
        row[3] = .{ .Str = try allocator.dupe(u8, functionCategoryName(f.category)) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .owns_value_memory = true,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn joinStrings(allocator: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var total: usize = 0;
    for (parts) |p| total += p.len;
    total += sep.len * (parts.len - 1);

    var buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        @memcpy(buf[pos .. pos + p.len], p);
        pos += p.len;
    }
    return buf;
}

fn constraintTypeName(t: @import("../schema/catalog.zig").ConstraintInfo.ConstraintType) []const u8 {
    return switch (t) {
        .unique => "UNIQUE",
        .node_key => "NODE KEY",
        .not_null => "NOT NULL",
        .exists => "EXISTS",
    };
}

fn functionCategoryName(c: language_metadata.FunctionCategory) []const u8 {
    return switch (c) {
        .aggregate => "aggregate",
        .scalar_math => "scalar_math",
        .scalar_string => "scalar_string",
        .scalar_list => "scalar_list",
        .conversion => "conversion",
        .temporal => "temporal",
        .graph => "graph",
        .path => "path",
        .vector => "vector",
        .predicate => "predicate",
        .null_handling => "null_handling",
    };
}

fn buildProcedureSignature(allocator: std.mem.Allocator, p: language_metadata.ProcedureInfo) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, p.name);
    try buf.appendSlice(allocator, "() :: (");
    for (p.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, col.name);
        try buf.appendSlice(allocator, " :: ");
        try buf.appendSlice(allocator, col.type_name);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

fn buildFunctionSignature(allocator: std.mem.Allocator, f: language_metadata.FunctionInfo) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, f.name);
    try buf.append(allocator, '(');
    for (f.params, 0..) |param, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, param.name);
        try buf.appendSlice(allocator, " :: ");
        try buf.appendSlice(allocator, param.type_name);
    }
    try buf.appendSlice(allocator, ") :: ");
    try buf.appendSlice(allocator, f.return_type);
    return buf.toOwnedSlice(allocator);
}
