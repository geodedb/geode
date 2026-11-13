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
const session_graph = @import("session_graph.zig");
const catalog_mod = @import("../schema/catalog.zig");
const tenant_visibility = @import("tenant_visibility.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
// SONNY-6351 item 2: the session's RLS label policies.
const rls_types = @import("rls_types");

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

// CANARY: REQ=REQ-SONNY-6351-DB-LABELS-RLS; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabelsRLSDeny; STATUS=TESTED; TEST=tests/test_sonny6351_labels_parse_default.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6351 item 2: the RLS label policies that apply to the session's user
/// in the session's graph, or null when no RLS engine is configured or the
/// session has no user (no policy applies, as for a MATCH: `passesRLSFilter`).
/// The user is the forwarded principal's when one is attached (GPS Phase 7),
/// else the connection's.
fn sessionLabelPolicies(allocator: std.mem.Allocator, ctx: ExecutionContext) !?rls_types.RLSFilterEngine.LabelPolicySnapshot {
    const engine = rls_types.getGlobalRLSFilterEngine() orelse return null;
    const principal_user: ?[]const u8 = if (ctx.principal) |p| p.username else null;
    const username = principal_user orelse ctx.user orelse return null;
    const graph: []const u8 = if (ctx.session_state) |session| session.graph orelse graph_store.DEFAULT_GRAPH_NAME else graph_store.DEFAULT_GRAPH_NAME;
    return try engine.snapshotLabelPolicies(allocator, graph, username);
}

fn executeDbLabels(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    // GAP-0840: route through the shared strict-tenancy decision instead of
    // passing raw ctx.tenant_id. An unscoped/"default" session would otherwise
    // get the all-tenants metadata view; in strict mode this is rejected with
    // error.TenantScopeRequired (propagated to the wire via the !ExecutionResult).
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    // Use the tenant-indexed helper; filter_tenant == null → admin all-tenant view.
    // SONNY-6344: a parent tenant also sees its descendants' labels, as its MATCH does.
    const labels = try tenant_visibility.listNodeLabelsVisible(allocator, store, filter_tenant);
    defer {
        for (labels) |lbl| allocator.free(lbl);
        allocator.free(labels);
    }

    // SONNY-6351 item 2: a label the session's RLS policy denies is omitted.
    // A deny entry hides every node carrying the label (`passesRLSFilter`:
    // every label's policies apply), so no row of it is visible; the label
    // was listed all the same.
    var policies = try sessionLabelPolicies(allocator, ctx);
    defer if (policies) |*p| p.deinit();

    // listNodeLabels returns labels in hash-iteration order; sort for stability.
    var sorted = try std.ArrayList([]const u8).initCapacity(allocator, labels.len);
    defer sorted.deinit(allocator);
    for (labels) |lbl| {
        if (policies) |*p| if (p.entries(lbl).denied) continue;
        try sorted.append(allocator, lbl);
    }
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

// CANARY: REQ=REQ-SONNY-6437-META-RLS; FEATURE="GPS Metadata Isolation"; ASPECT=DbRelationshipTypesRLSDeny; STATUS=TESTED; TEST=tests/test_sonny6437_query_residuals.zig; OWNER=security; UPDATED=2026-11-12
fn executeDbRelationshipTypes(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) !ExecutionResult {
    // GAP-0840: route through the shared strict-tenancy decision (see executeDbLabels).
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    // Use the tenant-indexed helper; filter_tenant == null → admin all-tenant view.
    // SONNY-6344: hierarchy-aware, as executeDbLabels.
    const types = try tenant_visibility.listEdgeTypesVisible(allocator, store, filter_tenant);
    defer {
        for (types) |t| allocator.free(t);
        allocator.free(types);
    }

    // SONNY-6437 item 5: an edge type the session's RLS policy denies is
    // omitted, as `executeDbLabels` omits a denied label: a type is a table as
    // a label is (SONNY-2710), and a deny on it hides every edge of it.
    var policies = try sessionLabelPolicies(allocator, ctx);
    defer if (policies) |*p| p.deinit();

    // SONNY-6460 item 5: under a deny, a type is listed only when one of its
    // edges is visible (`edgeVisible`): the type index also counts edges
    // whose endpoint the policy hides, which a MATCH never reaches.
    const reached = try allocator.alloc(bool, types.len);
    defer allocator.free(reached);
    @memset(reached, true);
    if (policies) |*p| if (p.denied.count() > 0) {
        @memset(reached, false);
        const edge_ids = try store.allEdgeIds(allocator);
        defer allocator.free(edge_ids);
        for (edge_ids) |edge_id| {
            const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
            if (!tenant_visibility.passesTenantFilterSlice(edge.tenant_id, filter_tenant)) continue;
            if (!edgeVisible(store, p, edge)) continue;
            for (types, reached) |t, *r| {
                if (std.mem.eql(u8, t, edge.label)) r.* = true;
            }
        }
    };

    // listEdgeTypes returns types in hash-iteration order; sort for stability.
    var sorted = try std.ArrayList([]const u8).initCapacity(allocator, types.len);
    defer sorted.deinit(allocator);
    for (types, reached) |t, r| {
        if (policies) |*p| if (p.entries(t).denied) continue;
        if (!r) continue;
        try sorted.append(allocator, t);
    }
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

// CANARY: REQ=REQ-SONNY-6437-META-RLS; FEATURE="GPS Metadata Isolation"; ASPECT=DbPropertyKeysRLSDeny; STATUS=TESTED; TEST=tests/test_sonny6437_query_residuals.zig; OWNER=security; UPDATED=2026-11-12
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

    // SONNY-6437 item 5: the keys of rows the session's RLS label policies
    // hide are omitted, as `executeDbLabels` omits a denied label. A deny on
    // any of a node's labels hides the node (SONNY-2690), so the per-label
    // key index, which lists a `:Pub:Sec` node's keys under `:Pub` too,
    // cannot answer under a deny: the visible nodes are read instead.
    var policies = try sessionLabelPolicies(allocator, ctx);
    defer if (policies) |*p| p.deinit();
    const denies = if (policies) |p| p.denied.count() > 0 else false;

    if (denies) {
        // Every graph's nodes, then the MATCH tenant rule (a parent sees
        // its descendants' rows, SONNY-6344).
        const node_ids = try store.getAllNodesForTenant(allocator, null);
        defer allocator.free(node_ids);
        for (node_ids) |node_id| {
            const node = store.getNodePtrHydrated(node_id) orelse continue;
            if (!tenant_visibility.passesTenantFilterSlice(node.tenant_id, filter_tenant)) continue;
            if (nodeDenied(&policies.?, node.labels)) continue;
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |p| {
                const key = p.key_ptr.*;
                if (!graph_storage_adapter.shouldExposePropertyKey(key)) continue;
                if (seen.contains(key)) continue;
                const owned = try allocator.dupe(u8, key);
                errdefer allocator.free(owned);
                try seen.put(owned, {});
                try ordered.append(allocator, owned);
            }
        }
    }

    // --- Node property keys via the tenant-indexed PERF-C structures ---
    // 1. Get the labels visible to this tenant (or all if admin).
    // SONNY-6344: hierarchy-aware (a parent also sees its descendants' rows).
    const labels = try tenant_visibility.listNodeLabelsVisible(allocator, store, filter_tenant);
    defer {
        for (labels) |lbl| allocator.free(lbl);
        allocator.free(labels);
    }

    // 2. For each label, collect the property keys indexed under that label+tenant.
    for (labels) |label| {
        if (denies) break;
        const keys = try tenant_visibility.listPropertiesForLabelVisible(allocator, store, filter_tenant, label);
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
        // Honour tenant filter; null means admin sees everything. SONNY-6344:
        // the edge's own tag by the MATCH rule (a parent sees its
        // descendants' edges), not the exact tag.
        if (!tenant_visibility.passesTenantFilterSlice(edge.tenant_id, filter_tenant)) continue;
        // SONNY-6437 item 5: an edge of a denied type is hidden.
        // SONNY-6460 item 5: and so is one with an endpoint the policy
        // hides (`edgeVisible`), as a MATCH does not reach it.
        if (denies) if (!edgeVisible(store, &policies.?, edge)) continue;
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

// CANARY: REQ=REQ-SONNY-6460-META-ENDPOINT-RLS; FEATURE="GPS Metadata Isolation"; ASPECT=EdgeEndpointVisibility; STATUS=TESTED; TEST=tests/test_sonny6460_meta_rls.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6460 item 5: whether a session under the label policies `policies`
/// reaches `edge`, as a MATCH does (SONNY-2679): its type is not denied and
/// neither endpoint is hidden (`nodeDenied`). An endpoint that cannot be read
/// counts as hidden (fail closed).
fn edgeVisible(store: *graph_store.GraphStore, policies: *const rls_types.RLSFilterEngine.LabelPolicySnapshot, edge: anytype) bool {
    if (policies.entries(edge.label).denied) return false;
    for ([_]u64{ edge.from_id, edge.to_id }) |node_id| {
        const node = store.getNodePtrHydrated(node_id) orelse return false;
        if (nodeDenied(policies, node.labels)) return false;
    }
    return true;
}

/// SONNY-6437 item 5: whether a label policy hides a node with `labels`: a
/// deny on any of them (SONNY-2690). A node with no label is the table
/// "default", as `passesRLSFilter` looks it up.
fn nodeDenied(policies: *const rls_types.RLSFilterEngine.LabelPolicySnapshot, labels: []const []const u8) bool {
    if (labels.len == 0) return policies.entries("default").denied;
    for (labels) |label| if (policies.entries(label).denied) return true;
    return false;
}

// ===========================================================================
// db.indexes() — list all indexes from the catalog
// Columns: name, type, label, properties (comma-joined)
// ===========================================================================

fn executeDbIndexes(allocator: std.mem.Allocator, context: ExecutionContext) !ExecutionResult {
    const catalog = context.catalog;
    // CANARY: REQ=REQ-SONNY-2795-DROP-INDEX-CATALOG; FEATURE="SchemaCatalog"; ASPECT=DbIndexesLocked; STATUS=TESTED; TEST=tests/test_sonny2795_drop_index_catalog.zig; OWNER=catalog; UPDATED=2026-11-11
    // SONNY-1319: the session's graph's catalog, as SHOW INDEXES lists it.
    // SONNY-2795: each row's strings are copied under the catalog lock, as
    // SHOW INDEXES does. `listIndexesForGraph` hands back rows that borrow
    // the catalog's strings, and they were read after the lock was dropped,
    // while DROP INDEX could free them.
    var catalog_rows = std.ArrayList([]Value).empty;
    defer catalog_rows.deinit(allocator);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const graph = session_graph.current(context);
        catalog.rwlock.lockSharedUncancelable(io);
        defer catalog.rwlock.unlockShared(io);
        var it = catalog.indexes.valueIterator();
        while (it.next()) |idx| {
            if (!catalog_mod.rowInGraph(idx.graph, graph)) continue;
            const row = try allocator.alloc(Value, 4);
            row[0] = .{ .Str = try allocator.dupe(u8, idx.name) };
            row[1] = .{ .Str = try allocator.dupe(u8, idx.index_type) };
            row[2] = .{ .Str = try allocator.dupe(u8, idx.table_name) };
            row[3] = .{ .Str = try joinStrings(allocator, idx.columns, ", ") };
            try catalog_rows.append(allocator, row);
        }
    }
    const indexes = catalog_rows.items;

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
    @memcpy(rows[0..indexes.len], indexes);
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
    // CANARY: REQ=REQ-SHOW-CONSTRAINTS-001; FEATURE="SHOW CONSTRAINTS"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    // CANARY: REQ=REQ-SONNY-6270-DROP-CONSTRAINT; FEATURE="SchemaCatalog"; ASPECT=DbConstraintsLocked; STATUS=TESTED; TEST=tests/test_sonny6270_drop_constraint.zig; OWNER=catalog; UPDATED=2026-11-11
    // SONNY-1319: the session's graph's catalog, as SHOW CONSTRAINTS lists it.
    // SONNY-6270: each row's strings are copied under the catalog lock, as
    // SHOW CONSTRAINTS does (and db.indexes(), SONNY-2795). The rows were
    // borrowed from the catalog and read after the lock was released, which
    // DROP CONSTRAINT, now that it frees them, would have made a
    // use-after-free.
    var catalog_rows = std.ArrayList([]Value).empty;
    defer catalog_rows.deinit(allocator);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const graph = session_graph.current(context);
        catalog.rwlock.lockSharedUncancelable(io);
        defer catalog.rwlock.unlockShared(io);
        var it = catalog.constraints.valueIterator();
        while (it.next()) |c| {
            if (!catalog_mod.rowInGraph(c.graph, graph)) continue;
            const row = try allocator.alloc(Value, 5);
            row[0] = .{ .Str = try allocator.dupe(u8, c.name) };
            row[1] = .{ .Str = try allocator.dupe(u8, constraintTypeName(c.constraint_type)) };
            row[2] = .{ .Str = try allocator.dupe(u8, c.label) };
            row[3] = .{ .Str = try joinStrings(allocator, c.properties, ", ") };
            row[4] = .{ .Bool = c.is_enforced };
            try catalog_rows.append(allocator, row);
        }
    }

    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "name");
    columns[1] = try allocator.dupe(u8, "type");
    columns[2] = try allocator.dupe(u8, "label");
    columns[3] = try allocator.dupe(u8, "properties");
    columns[4] = try allocator.dupe(u8, "enforced");

    const rows = try catalog_rows.toOwnedSlice(allocator);

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
