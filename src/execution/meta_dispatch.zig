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
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");

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
// db.labels() — distinct node labels scoped to the active tenant
// ===========================================================================

// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabelsFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
// Phase 3 (Task 3-4): delegate to store.listNodeLabels which honours the
// tenant_id index. Passing ctx.tenant_id == null is the admin/cross-tenant
// path that returns all labels; passing a non-null value restricts the
// result set to that tenant only — no cross-tenant label leakage.
pub fn executeDbLabelsForTest(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    return executeDbLabels(allocator, store, ctx);
}

fn executeDbLabels(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    // GAP-0840: route through the shared strict-tenancy decision instead of
    // passing raw ctx.tenant_id. An unscoped/"default" session would otherwise
    // get the all-tenants metadata view; in strict mode this is rejected with
    // error.TenantScopeRequired (propagated to the wire via the !ExecutionResult).
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    // Use the tenant-indexed helper; filter_tenant == null → admin all-tenant view.
    const labels = try store.listNodeLabels(allocator, filter_tenant);
    defer {
        for (labels) |lbl| allocator.free(lbl);
        allocator.free(labels);
    }

    // listNodeLabels returns labels in hash-iteration order; sort for stability.
    var sorted = try std.ArrayList([]const u8).initCapacity(allocator, labels.len);
    defer sorted.deinit(allocator);
    for (labels) |lbl| try sorted.append(allocator, lbl);
    std.mem.sort([]const u8, sorted.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "label");

    const rows = try allocator.alloc([]Value, sorted.items.len);
    for (sorted.items, 0..) |lbl, i| {
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
// db.relationshipTypes() — distinct edge types scoped to the active tenant
// ===========================================================================

// CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=DbRelationshipTypesFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
// Phase 3 (Task 3-5): delegate to store.listEdgeTypes which honours the
// tenant_id index (edge_types_by_tenant). Passing null is the admin path.
pub fn executeDbRelationshipTypesForTest(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    return executeDbRelationshipTypes(allocator, store, ctx);
}

fn executeDbRelationshipTypes(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    // GAP-0840: route through the shared strict-tenancy decision (see executeDbLabels).
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    // Use the tenant-indexed helper; filter_tenant == null → admin all-tenant view.
    const types = try store.listEdgeTypes(allocator, filter_tenant);
    defer {
        for (types) |t| allocator.free(t);
        allocator.free(types);
    }

    // listEdgeTypes returns types in hash-iteration order; sort for stability.
    var sorted = try std.ArrayList([]const u8).initCapacity(allocator, types.len);
    defer sorted.deinit(allocator);
    for (types) |t| try sorted.append(allocator, t);
    std.mem.sort([]const u8, sorted.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "relationshipType");

    const rows = try allocator.alloc([]Value, sorted.items.len);
    for (sorted.items, 0..) |ty, i| {
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
// db.propertyKeys() — distinct property keys scoped to the active tenant
// ===========================================================================

// CANARY: REQ=REQ-GPS-METADATA-003; FEATURE="GPS Metadata Isolation"; ASPECT=DbPropertyKeysFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
// Phase 3 (Task 3-6): collect node property keys via the tenant-indexed
// label_properties_by_tenant index (listNodeLabels → listPropertiesForLabel
// per label), then sweep only the tenant's edges for edge-level property keys.
// The label_properties_by_tenant index covers nodes only, so edges require a
// filtered scan — but this is O(edges_for_tenant) rather than O(all_edges).
pub fn executeDbPropertyKeysForTest(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    return executeDbPropertyKeys(allocator, store, ctx);
}

fn executeDbPropertyKeys(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    // Use a StringHashMap to deduplicate. The map OWNS each key string so that
    // freeing the intermediate label/prop-key slices returned by the store
    // helpers doesn't leave dangling pointers in the accumulator.
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var k_it = seen.keyIterator();
        while (k_it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(allocator);

    // GAP-0840: resolve once via the shared strict-tenancy decision and use the
    // result for BOTH the node-side label/prop scans and the edge filter below.
    // Strict mode rejects an unscoped/"default" session (error.TenantScopeRequired)
    // rather than serving the all-tenants property-key view.
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);

    // --- Node property keys via the tenant-indexed PERF-C structures ---
    // 1. Get the labels visible to this tenant (or all if admin).
    const labels = try store.listNodeLabels(allocator, filter_tenant);
    defer {
        for (labels) |lbl| allocator.free(lbl);
        allocator.free(labels);
    }

    // 2. For each label, collect the property keys indexed under that label+tenant.
    for (labels) |label| {
        const keys = try store.listPropertiesForLabel(allocator, filter_tenant, label);
        defer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }
        for (keys) |key| {
            // Check before duping to avoid an allocation on duplicates.
            if (seen.contains(key)) continue;
            const owned = try allocator.dupe(u8, key);
            errdefer allocator.free(owned);
            try seen.put(owned, {});
            try ordered.append(allocator, owned);
        }
    }

    // --- Edge property keys: label_properties_by_tenant covers nodes only.
    // Filter edges by tenant_id to avoid cross-tenant leakage. PHASE 1
    // (edge-engine-direct): enumerate the COMPLETE edge id set
    // (bounded-cache-safe) and hydrate each body, instead of iterating the
    // resident `store.edges` map (which under a bounded edge cache would miss
    // evicted edges' property keys).
    const edge_ids_for_keys = try store.allEdgeIds(allocator);
    defer allocator.free(edge_ids_for_keys);
    for (edge_ids_for_keys) |__eid| {
        const edge = store.getEdgePtrHydrated(__eid) orelse continue;
        // Honour tenant filter; null means admin sees everything.
        if (filter_tenant) |tid| {
            if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
        }
        var prop_iter = edge.properties.iterator();
        while (prop_iter.next()) |p| {
            const key = p.key_ptr.*;
            if (seen.contains(key)) continue;
            const owned = try allocator.dupe(u8, key);
            errdefer allocator.free(owned);
            try seen.put(owned, {});
            try ordered.append(allocator, owned);
        }
    }

    std.mem.sort([]const u8, ordered.items, {}, lessThanString);

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "propertyKey");

    // The rows dupe each key independently of the seen map so the result's
    // owns_value_memory = true path frees the row strings correctly.
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

    // #844: FULLTEXT indexes live in IndexManager.fulltext_indexes and were
    // never registered with the Catalog -- so SHOW INDEXES couldn't see them
    // even though BM25 search functions correctly against them. Iterate the
    // FTS map and surface each one alongside the catalog-registered indexes.
    const index_manager = @import("../index/index_manager.zig");
    var fts_names = std.ArrayList([]const u8).empty;
    defer fts_names.deinit(allocator);
    if (index_manager.getGlobalIndexManager()) |mgr| {
        var it = mgr.fulltext_indexes.keyIterator();
        while (it.next()) |key_ptr| {
            try fts_names.append(allocator, key_ptr.*);
        }
    }

    const total = indexes.len + fts_names.items.len;
    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "type");
    columns[2] = try allocator.dupe(u8, "label");
    columns[3] = try allocator.dupe(u8, "properties");

    const rows = try allocator.alloc([]Value, total);
    for (indexes, 0..) |idx, i| {
        const row = try allocator.alloc(Value, 4);
        row[0] = .{ .Str = try allocator.dupe(u8, idx.name) };
        row[1] = .{ .Str = try allocator.dupe(u8, idx.index_type) };
        row[2] = .{ .Str = try allocator.dupe(u8, idx.table_name) };
        row[3] = .{ .Str = try joinStrings(allocator, idx.columns, ", ") };
        rows[i] = row;
    }
    for (fts_names.items, 0..) |name, j| {
        const row = try allocator.alloc(Value, 4);
        row[0] = .{ .Str = try allocator.dupe(u8, name) };
        row[1] = .{ .Str = try allocator.dupe(u8, "FULLTEXT") };
        row[2] = .{ .Str = try allocator.dupe(u8, "") };
        row[3] = .{ .Str = try allocator.dupe(u8, "") };
        rows[indexes.len + j] = row;
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
