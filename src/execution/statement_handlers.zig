const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");
const tenant_visibility = @import("tenant_visibility.zig");
/// SONNY-6606 (1): SHOW TABLES lists the session graph's labels, as db.labels.
const meta_dispatch = @import("meta_dispatch.zig");
const value_types = @import("../value_types.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const admin_ddl = @import("admin_ddl.zig");
const session_graph = @import("session_graph.zig");
const catalog_mod = @import("../schema/catalog.zig");
const planned_read_runtime = @import("planned_read_runtime.zig");
const result_utils = @import("result_utils.zig");
const value_utilities = @import("value_utilities.zig");
const query_arena = @import("../server/query_arena.zig");

// Import helper functions used by statement handlers
const getCatalog = execution.getCatalog;
const executeMatchQueryWithParams = execution.executeMatchQueryWithParams;
const executeStatementWithContext = execution.executeStatementWithContext;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

/// CLOCK_MONOTONIC nanoseconds (GAP-0868: real PROFILE wall-clock timing).
/// Same compat pattern as graph_storage_adapter.monoNanosNow.
fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// CANARY: REQ=REQ-EXEC-REFACTOR-007; FEATURE="ExecutionRefactoring"; ASPECT=STATEMENT_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted statement handlers (SHOW, FOR, VALUES, EXPLAIN, PROFILE) from execution.zig for better modularity (M1 Phase 7)

pub fn executeShow(allocator: std.mem.Allocator, s: ast.ShowStatement, context: ExecutionContext) !ExecutionResult {
    // M2: Get catalog from context via dependency injection
    const cat = getCatalog(allocator, context);
    const writable_store = graph_store.getWritableGlobalStore(allocator);
    var read_session = try graph_store.QueryReadSession.initIfAvailable(allocator, writable_store);
    defer if (read_session) |*session| session.deinit();
    const read_store: *graph_store.GraphStore = if (read_session) |*session|
        session.store()
    else
        writable_store;

    const column_list = switch (s.show_type) {
        .indexes => &[_][]const u8{ "name", "type", "table", "columns" },
        .constraints => &[_][]const u8{ "name", "type", "table", "columns" },
        .tables => &[_][]const u8{ "name", "type" },
        .graphs => &[_][]const u8{"name"},
        .procedures => &[_][]const u8{ "name", "signature" },
        .functions => &[_][]const u8{ "name", "signature", "return_type" },
        .users => return admin_ddl.executeShowUsers(allocator, context),
        .roles => return admin_ddl.executeShowRoles(allocator, context),
        .permissions => return admin_ddl.executeShowPermissions(allocator, s.target, context),
        .version => return admin_ddl.executeShowVersion(allocator),
        .capabilities => return admin_ddl.executeShowCapabilities(allocator),
        // CANARY: REQ=REQ-DIST-SHOW-CLUSTER-STATUS; FEATURE="SHOW CLUSTER STATUS"; ASPECT=ShowDispatch; STATUS=TESTED; TEST=tests/test_show_cluster_status.zig; OWNER=distributed; UPDATED=2026-05-26
        // Early-return: cluster_status builds its own columns / rows from the
        // global ClusterCoordinator pointer rather than the catalog, so it
        // does not pass through the catalog-locked column-and-row builder
        // below.
        .cluster_status => return admin_ddl.executeShowClusterStatus(allocator, context),
        // GPS policy DDL (Phase 4): SHOW POLICIES returns empty result set until
        // Phase 5 wires the persistent catalog.  Column schema matches Phase 5 plan.
        // SONNY-2732: `valid` is false for a stored policy whose expression no
        // longer compiles (kept fail-closed until rewritten).
        .policies => &[_][]const u8{ "name", "graph", "actions", "enabled", "valid" },
        // SONNY-1333: SHOW GRANTS builds its own rows (policies, then the
        // stored per-graph grants) outside the catalog lock: reading the
        // grants takes the security graph's locks.
        .grants_for => return admin_ddl.executeShowGrants(allocator, s.target, context),
    };

    // Allocate and copy column names
    var columns = try allocator.alloc([]const u8, column_list.len);
    for (column_list, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Build rows based on show type
    var rows_list = std.ArrayList([]Value).empty;

    // Phase 3: Shared lock for SHOW (read-only, allows concurrent access)
    cat.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cat.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

    switch (s.show_type) {
        .indexes => {
            // CANARY: REQ=REQ-GPS-METADATA-003; FEATURE="GPS Metadata Isolation"; ASPECT=ShowIndexesFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
            // Task 3-8: Gate SHOW INDEXES by tenant + active graph. When the
            // execution context carries a Principal with an active_graph, verify
            // the principal can bind that graph via gps.decide(.bind_graph). If
            // denied, return an empty result. When principal is null
            // (legacy/test paths) the bind check is skipped.
            // CANARY: REQ=REQ-SONNY-1319-GRAPH-SCOPED-CATALOG; FEATURE="SchemaCatalog"; ASPECT=ShowGraphScope; STATUS=TESTED; TEST=tests/test_sonny1319_graph_scoped_catalog.zig; OWNER=catalog; UPDATED=2026-11-11
            // SONNY-1319: only the session's graph's catalog is listed (its own
            // rows and the engine-wide ones), not every graph's.
            const gps_mod_idx = @import("../security/gps.zig");
            const active_graph_idx: ?[]const u8 = if (context.session_state) |ss| ss.graph else null;
            const idx_allowed = blk: {
                if (context.principal) |princ| {
                    if (active_graph_idx) |graph| {
                        const req_bind = gps_mod_idx.DecisionRequest{
                            .principal = princ,
                            .action = .bind_graph,
                            .resource = .{ .graph = graph },
                        };
                        const decision = try gps_mod_idx.decide(std.heap.smp_allocator, &req_bind);
                        break :blk decision.kind == .allow;
                    }
                }
                break :blk true;
            };
            if (idx_allowed) {
                const show_graph = session_graph.current(context);
                var iter = cat.indexes.iterator();
                while (iter.next()) |entry| {
                    const info = entry.value_ptr.*;
                    if (!catalog_mod.rowInGraph(info.graph, show_graph)) continue;
                    var row = try allocator.alloc(Value, 4);
                    row[0] = Value{ .Str = try allocator.dupe(u8, info.name) };
                    row[1] = Value{ .Str = try allocator.dupe(u8, info.index_type) };
                    row[2] = Value{ .Str = try allocator.dupe(u8, info.table_name) };

                    // Join columns with comma
                    var columns_str = std.ArrayList(u8).empty;
                    for (info.columns, 0..) |col, i| {
                        if (i > 0) try columns_str.appendSlice(allocator, ", ");
                        try columns_str.appendSlice(allocator, col);
                    }
                    row[3] = Value{ .Str = try columns_str.toOwnedSlice(allocator) };

                    try rows_list.append(allocator, row);
                }
            }
        },
        .graphs => {
            // CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=ShowGraphsFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
            // Task 3-7: Filter SHOW GRAPHS by bind_graph access. When the
            // execution context carries a Principal, each graph is checked via
            // gps.decide(.bind_graph). Only graphs that return .allow are
            // included in the result. When principal is null (legacy/test paths)
            // all graphs are returned to preserve backward compatibility.
            const gps_mod = @import("../security/gps.zig");
            // CANARY: REQ=REQ-SONNY-6547-SHOW-GRAPHS-ERRORS; FEATURE="SHOW GRAPHS"; ASPECT=ListingErrorPropagates; STATUS=TESTED; TEST=tests/test_sonny6547_show_graphs_errors.zig; OWNER=execution; UPDATED=2026-11-14
            // SONNY-6547 (2): a listing that fails fails the statement; it
            // answered no rows (`catch null`), as SHOW TABLES did (SONNY-6541).
            const names = try read_store.listGraphNames(allocator);
            defer {
                for (names) |name| allocator.free(name);
                allocator.free(names);
            }
            for (names) |name| {
                // GPS filter: skip graphs the principal cannot bind
                if (context.principal) |princ| {
                    const req_bind = gps_mod.DecisionRequest{
                        .principal = princ,
                        .action = .bind_graph,
                        .resource = .{ .graph = name },
                    };
                    const decision = try gps_mod.decide(std.heap.smp_allocator, &req_bind);
                    if (decision.kind != .allow) continue;
                }
                var row = try allocator.alloc(Value, 1);
                row[0] = Value{ .Str = try allocator.dupe(u8, name) };
                try rows_list.append(allocator, row);
            }
        },
        .constraints => {
            // GAP-0139: SHOW CONSTRAINTS implementation
            // CANARY: REQ=REQ-SHOW-CONSTRAINTS-002; FEATURE="SHOW CONSTRAINTS"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // CANARY: REQ=REQ-GPS-METADATA-004; FEATURE="GPS Metadata Isolation"; ASPECT=ShowConstraintsFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
            // Task 3-8: Gate SHOW CONSTRAINTS by tenant + active graph. Same
            // policy as SHOW INDEXES above — when a Principal with an active_graph
            // is present, verify bind_graph access before exposing constraint
            // metadata. Legacy paths without a principal see everything.
            const gps_mod_con = @import("../security/gps.zig");
            const active_graph_con: ?[]const u8 = if (context.session_state) |ss| ss.graph else null;
            const con_allowed = blk: {
                if (context.principal) |princ| {
                    if (active_graph_con) |graph| {
                        const req_bind = gps_mod_con.DecisionRequest{
                            .principal = princ,
                            .action = .bind_graph,
                            .resource = .{ .graph = graph },
                        };
                        const decision = try gps_mod_con.decide(std.heap.smp_allocator, &req_bind);
                        break :blk decision.kind == .allow;
                    }
                }
                break :blk true;
            };
            if (con_allowed) {
                // SONNY-1319: the session's graph's constraints only.
                const show_graph = session_graph.current(context);
                var iter = cat.constraints.iterator();
                while (iter.next()) |entry| {
                    const info = entry.value_ptr.*;
                    if (!catalog_mod.rowInGraph(info.graph, show_graph)) continue;
                    var row = try allocator.alloc(Value, 4);
                    row[0] = Value{ .Str = try allocator.dupe(u8, info.name) };

                    // Convert constraint type enum to string
                    const type_str = switch (info.constraint_type) {
                        .unique => "UNIQUE",
                        .node_key => "NODE KEY",
                        .not_null => "NOT NULL",
                        .exists => "EXISTS",
                    };
                    row[1] = Value{ .Str = try allocator.dupe(u8, type_str) };
                    row[2] = Value{ .Str = try allocator.dupe(u8, info.label) };

                    // Join properties with comma
                    var props_str = std.ArrayList(u8).empty;
                    for (info.properties, 0..) |prop, i| {
                        if (i > 0) try props_str.appendSlice(allocator, ", ");
                        try props_str.appendSlice(allocator, prop);
                    }
                    row[3] = Value{ .Str = try props_str.toOwnedSlice(allocator) };

                    try rows_list.append(allocator, row);
                }
            }
        },
        .tables => {
            // GAP-0139: SHOW TABLES implementation
            // CANARY: REQ=REQ-SHOW-TABLES-001; FEATURE="SHOW TABLES"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // In a graph database, node labels act as "tables"
            // Return unique node labels from the graph storage
            // GAP-0509: pass the session tenant filter so SHOW TABLES
            // only returns labels the current tenant actually uses.
            // GAP-0840: route through the shared strict-tenancy decision so an
            // unscoped/"default" SHOW TABLES is rejected in strict mode rather
            // than leaking every tenant's label set (same footgun as the
            // read paths).
            const session_tenant: ?[]const u8 = try tenancy.resolveTenantFilter(context.tenant_id);
            // SONNY-6344: a parent tenant also lists its descendants' labels.
            // CANARY: REQ=REQ-SONNY-6541-SHOW-TABLES-ERRORS; FEATURE="SHOW TABLES"; ASPECT=ListingErrorPropagates; STATUS=TESTED; TEST=tests/test_sonny6541_show_tables_errors.zig; OWNER=execution; UPDATED=2026-11-14
            // SONNY-6541 (4): a listing that fails fails the statement; it
            // answered no rows (out of memory, a quarantined graph).
            // SONNY-6606 (1): of the session's graph only (it listed every
            // graph's, __geode_security's included).
            const labels = try meta_dispatch.sessionGraphLabels(allocator, read_store, context, session_tenant);
            defer {
                for (labels) |label| {
                    allocator.free(label);
                }
                allocator.free(labels);
            }
            for (labels) |label| {
                var row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = try allocator.dupe(u8, label) };
                row[1] = Value{ .Str = try allocator.dupe(u8, "NODE") }; // All are node labels
                try rows_list.append(allocator, row);
            }
        },
        .procedures => {
            // GAP-0139: SHOW PROCEDURES implementation
            // CANARY: REQ=REQ-SHOW-PROCEDURES-001; FEATURE="SHOW PROCEDURES"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // Geode currently has no user-defined stored procedures
            // Return empty result set (procedures might be added in future)
        },
        // The first switch returns early for these; this arm is unreachable in practice (defensive)
        .users, .roles, .permissions, .version, .capabilities, .cluster_status, .grants_for => unreachable,
        // GPS policy DDL (Phase 4, Task 4-4): enumerate in-memory PolicyCatalog.
        // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=ShowPoliciesExecution; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
        .policies => {
            const policy_catalog_mod = @import("../security/policy_catalog.zig");
            if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
                // SONNY-2756: the rows copy each policy under a shared hold
                // of the catalog; a policy change waits for it.
                const view = pol_cat.acquireRead();
                defer view.release();
                for (view.policies()) |*pol| {
                    // Build "actions" column: comma-separated action names.
                    var actions_buf = std.ArrayList(u8).empty;
                    for (pol.actions, 0..) |a, ai| {
                        if (ai > 0) try actions_buf.appendSlice(allocator, ", ");
                        try actions_buf.appendSlice(allocator, @tagName(a));
                    }
                    const actions_str = try actions_buf.toOwnedSlice(allocator);

                    var row = try allocator.alloc(Value, 5);
                    row[0] = Value{ .Str = try allocator.dupe(u8, pol.name) };
                    row[1] = Value{ .Str = try allocator.dupe(u8, pol.scope_graph) };
                    row[2] = Value{ .Str = actions_str };
                    row[3] = Value{ .Bool = pol.enabled };
                    row[4] = Value{ .Bool = policy_catalog_mod.PolicyCatalog.policyIsValid(pol) };
                    try rows_list.append(allocator, row);
                }
            }
            // If catalog not yet initialized, return empty rows (safe for pre-startup tests).
        },
        .functions => {
            // GAP-0139: SHOW FUNCTIONS implementation
            // CANARY: REQ=REQ-SHOW-FUNCTIONS-001; FEATURE="SHOW FUNCTIONS"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // Return built-in functions list
            const builtin_functions = [_]struct { name: []const u8, signature: []const u8, return_type: []const u8 }{
                // String functions
                .{ .name = "substring", .signature = "(string, start, [length])", .return_type = "STRING" },
                .{ .name = "replace", .signature = "(string, search, replace)", .return_type = "STRING" },
                .{ .name = "trim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "ltrim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "rtrim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "left", .signature = "(string, length)", .return_type = "STRING" },
                .{ .name = "right", .signature = "(string, length)", .return_type = "STRING" },
                .{ .name = "upper", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "lower", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "reverse", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "split", .signature = "(string, delimiter)", .return_type = "LIST" },
                .{ .name = "toString", .signature = "(value)", .return_type = "STRING" },
                // Collection functions
                .{ .name = "size", .signature = "(list|map|string)", .return_type = "INTEGER" },
                .{ .name = "length", .signature = "(list|path)", .return_type = "INTEGER" },
                .{ .name = "keys", .signature = "(map|node)", .return_type = "LIST" },
                .{ .name = "values", .signature = "(map)", .return_type = "LIST" },
                .{ .name = "head", .signature = "(list)", .return_type = "ANY" },
                .{ .name = "tail", .signature = "(list)", .return_type = "LIST" },
                .{ .name = "last", .signature = "(list)", .return_type = "ANY" },
                .{ .name = "range", .signature = "(start, end, [step])", .return_type = "LIST" },
                // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="SHOW FUNCTIONS"; ASPECT=ReduceUnadvertised; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
                // FN-DISPATCH-PARITY: `reduce(acc = seed, x IN list | expr)` is NOT
                // implemented — the higher-order form is not even accepted by
                // the parser (`RETURN reduce(acc = 0, x IN [1,2,3] | acc + x)`
                // is a syntax error), let alone dispatched. Advertising it here
                // told users a construct exists that cannot be written at all,
                // so the row is removed rather than faked. Re-add it in the
                // same commit that lands the grammar + evaluator.
                // Numeric functions
                .{ .name = "abs", .signature = "(number)", .return_type = "NUMBER" },
                .{ .name = "ceil", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "floor", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "round", .signature = "(number, [precision])", .return_type = "NUMBER" },
                .{ .name = "sign", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "sqrt", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "log", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "log10", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "exp", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "sin", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "cos", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "tan", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "rand", .signature = "()", .return_type = "FLOAT" },
                // Aggregation functions
                .{ .name = "count", .signature = "(expr)", .return_type = "INTEGER" },
                .{ .name = "sum", .signature = "(expr)", .return_type = "NUMBER" },
                .{ .name = "avg", .signature = "(expr)", .return_type = "FLOAT" },
                .{ .name = "min", .signature = "(expr)", .return_type = "ANY" },
                .{ .name = "max", .signature = "(expr)", .return_type = "ANY" },
                .{ .name = "collect", .signature = "(expr)", .return_type = "LIST" },
                // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="SHOW FUNCTIONS"; ASPECT=UnimplementedAggregatesUnadvertised; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=execution; UPDATED=2026-08-25
                // UNSUPPORTED-AGGREGATES: stdev / percentileCont / percentileDisc were listed
                // here but are the same unimplemented aggregates the parser now
                // refuses by their snake_case spellings. They are removed rather
                // than left advertised — src/execution/aggregation_evaluation.zig
                // implements exactly count/sum/avg/min/max/collect. Re-add them
                // in the same commit that lands the implementations.
                // Predicate functions
                .{ .name = "all", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "any", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "none", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "single", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "exists", .signature = "(pattern)", .return_type = "BOOLEAN" },
                // Type functions
                .{ .name = "type", .signature = "(relationship)", .return_type = "STRING" },
                // valueType(value): the value's type name (Cypher/GQL-alignment
                // spelling over getTypeName; edges report "RELATIONSHIP", not
                // the relationship label — that is type()'s job).
                .{ .name = "valueType", .signature = "(value)", .return_type = "STRING" },
                .{ .name = "labels", .signature = "(node)", .return_type = "LIST" },
                .{ .name = "id", .signature = "(node|relationship)", .return_type = "INTEGER" },
                // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="SHOW FUNCTIONS"; ASPECT=ElementIdUnadvertised; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
                // FN-DISPATCH-PARITY: `elementId(node|relationship)` is NOT
                // implemented — `MATCH (n) RETURN elementId(n)` was
                // error.UnknownFunction. It is the ISO/Neo4j *element id*
                // scheme (an opaque, database-scoped string identity), and
                // this engine has made no decision about what that string
                // would be; `id()` immediately above is the implemented
                // identity surface. Advertising a second, absent identity
                // function invited clients to key on it. Re-add this row in
                // the same commit that lands an element-id scheme.
                .{ .name = "properties", .signature = "(node|relationship|map)", .return_type = "MAP" },
                // Path functions
                .{ .name = "nodes", .signature = "(path)", .return_type = "LIST" },
                .{ .name = "relationships", .signature = "(path)", .return_type = "LIST" },
                // Temporal functions
                .{ .name = "date", .signature = "([map|string])", .return_type = "DATE" },
                .{ .name = "time", .signature = "([map|string])", .return_type = "TIME" },
                // datetime: the map constructor form is NOT implemented (only
                // the string/no-arg forms dispatch); advertising "[map|string]"
                // was a FN-DISPATCH-PARITY lie of the elementId/point kind.
                // Re-widen the signature in the commit that lands the map form.
                .{ .name = "datetime", .signature = "([string])", .return_type = "DATETIME" },
                .{ .name = "localtime", .signature = "([map|string])", .return_type = "LOCAL_TIME" },
                .{ .name = "localdatetime", .signature = "([map|string])", .return_type = "LOCAL_DATETIME" },
                .{ .name = "duration", .signature = "(map|string)", .return_type = "DURATION" },
                // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="SHOW FUNCTIONS"; ASPECT=PointUnadvertised; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
                // FN-DISPATCH-PARITY: `point(map)` is NOT implemented —
                // `RETURN point({x: 1.0, y: 2.0})` was error.UnknownFunction.
                // It is the Cypher spatial constructor, whose map form carries
                // a CRS decision (cartesian vs wgs-84, 2D vs 3D) this engine
                // has not made. The implemented geometry constructors are the
                // `st_*` family (`st_point(x, y)`, `geometryfromtext(wkt)`)
                // plus `latlon`/`latlonalt`; a fourth, incompatible spelling
                // was advertised and answered nowhere. Re-add this row in the
                // same commit that lands a CRS-carrying point constructor.
                // Vector functions. docs/@BUGS_731.md bug 8f: `distance` was
                // advertised here as a GEOSPATIAL point-to-point function — a
                // fourth, incompatible scheme. It is a VECTOR distance (the
                // geospatial distance is ST_Distance), so this row is now
                // aligned with src/gql/language_metadata.zig and the engine.
                .{ .name = "distance", .signature = "(v1, v2[, metric])", .return_type = "FLOAT" },
                .{ .name = "similarity", .signature = "(v1, v2[, metric])", .return_type = "FLOAT" },
                .{ .name = "cosine", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "euclidean", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "manhattan", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "vector_l2", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "vector_cosine", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "vector_dot", .signature = "(v1, v2)", .return_type = "FLOAT" },
                .{ .name = "vector_knn", .signature = "(property, query_vector, k, metric)", .return_type = "LIST" },
                .{ .name = "knn", .signature = "(property, query_vector, k, metric)", .return_type = "LIST" },
                // Coalesce/null handling
                .{ .name = "coalesce", .signature = "(expr...)", .return_type = "ANY" },
                .{ .name = "nullIf", .signature = "(value1, value2)", .return_type = "ANY" },
            };

            for (builtin_functions) |func| {
                var row = try allocator.alloc(Value, 3);
                row[0] = Value{ .Str = try allocator.dupe(u8, func.name) };
                row[1] = Value{ .Str = try allocator.dupe(u8, func.signature) };
                row[2] = Value{ .Str = try allocator.dupe(u8, func.return_type) };
                try rows_list.append(allocator, row);
            }
        },
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try rows_list.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        // All Str values in the rows are freshly dupe()'d above; set this flag
        // so that ExecutionResult.deinit() calls freeValue() on each value and
        // does not leak under the debug allocator or in test harnesses.
        .owns_value_memory = true,
    };
}

// CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876; FEATURE="ForStatement"; ASPECT=BodyResultAggregation; STATUS=TESTED; TEST=tests/test_for_write_body.zig; OWNER=engine; UPDATED=2026-08-29
/// Accumulator that folds the per-iteration results of a FOR body into a single
/// ExecutionResult without leaking or double-freeing any of the ownership-
/// carrying fields (values, column buffer, flags, graph entities, bindings).
const ForBodyAccumulator = struct {
    rows: std.ArrayList([]Value) = .empty,
    columns: ?[][]const u8 = null,
    column_buffer: ?[]u8 = null,
    flags: ?std.ArrayList([]const u8) = null,
    owns_value_memory: bool = false,
    seen_result: bool = false,
    entities: ?*execution.OwnedGraphEntities = null,
    bindings: ?*std.StringHashMap(u64) = null,

    /// Take everything the iteration result owns; `result` owns nothing after
    /// this returns (so it must NOT be deinit'd by the caller).
    fn absorb(self: *ForBodyAccumulator, allocator: std.mem.Allocator, result: *ExecutionResult) !void {
        // Value-memory ownership folds with AND. Every iteration runs the SAME
        // body shape, so the flag is uniform in practice; a hypothetical mixed
        // batch degrades to "borrowed", which can only leak — never free memory
        // the result did not own.
        if (!self.seen_result) {
            self.owns_value_memory = result.owns_value_memory;
            self.seen_result = true;
        } else if (!result.owns_value_memory) {
            self.owns_value_memory = false;
        }

        // CANARY: REQ=REQ-SONNY-6613-FOR-WRITE-RESULT; FEATURE="ForStatement"; ASPECT=NoRowsWithoutReturn; STATUS=TESTED; TEST=tests/test_sonny6613_for_write_result.zig; OWNER=engine; UPDATED=2026-11-15
        // SONNY-6613 item 3: a body with no RETURN has no result rows (ISO/IEC
        // 39075:2024 14.1); its run's row of no columns was kept, one per
        // element. A row of no columns owns no values.
        if (result.columns.len == 0) {
            for (result.rows) |row| allocator.free(row);
            allocator.free(result.rows);
            result.rows = &.{};
        }
        // Reserve first: every transfer below must be infallible so a failure
        // can never leave a row owned by BOTH the accumulator and `result`.
        try self.rows.ensureUnusedCapacity(allocator, result.rows.len);
        for (result.rows) |row| self.rows.appendAssumeCapacity(row);
        allocator.free(result.rows);
        result.rows = &.{};

        if (self.columns == null and result.columns.len > 0) {
            self.columns = result.columns;
            self.column_buffer = result.column_buffer;
        } else {
            if (result.column_buffer) |buffer| {
                allocator.free(buffer);
            } else {
                for (result.columns) |col| allocator.free(col);
            }
            allocator.free(result.columns);
        }
        result.columns = &.{};
        result.column_buffer = null;

        if (self.flags == null) {
            self.flags = result.flags;
        } else {
            if (result.owns_value_memory) {
                for (result.flags.items) |flag| allocator.free(flag);
            }
            result.flags.deinit(allocator);
        }
        result.flags = .empty;

        if (result.owned_graph_entities) |entities| {
            // SONNY-2463: the merged nodes are freed with the accumulator's
            // `destroy_node`, so both trackers must free their nodes the same
            // way: `adopt` absorbs a tracker that does (it moves the path
            // arrays it keeps too, SONNY-6613, and frees the tracker,
            // SONNY-2394) and keeps one that does not (SONNY-6740: an
            // element's copies free in full, a body without a RETURN's nodes
            // do not) alive with it.
            try execution.OwnedGraphEntities.adopt(&self.entities, entities);
            result.owned_graph_entities = null;
        }

        if (result.variable_bindings) |vb| {
            if (self.bindings == null) {
                self.bindings = vb;
            } else {
                vb.deinit();
                allocator.destroy(vb);
            }
            result.variable_bindings = null;
        }
    }

    fn finish(self: *ForBodyAccumulator, allocator: std.mem.Allocator) !ExecutionResult {
        return ExecutionResult{
            .columns = self.columns orelse try allocator.alloc([]const u8, 0),
            .rows = try self.rows.toOwnedSlice(allocator),
            .flags = self.flags orelse std.ArrayList([]const u8).empty,
            .owns_value_memory = self.owns_value_memory,
            .column_buffer = self.column_buffer,
            .owned_graph_entities = self.entities,
            .variable_bindings = self.bindings,
        };
    }

    fn deinit(self: *ForBodyAccumulator, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            if (self.owns_value_memory) {
                for (row) |value| execution.freeValue(allocator, value);
            }
            allocator.free(row);
        }
        self.rows.deinit(allocator);
        if (self.columns) |cols| {
            if (self.column_buffer) |buffer| {
                allocator.free(buffer);
            } else {
                for (cols) |col| allocator.free(col);
            }
            allocator.free(cols);
        }
        if (self.flags) |*flags| flags.deinit(allocator);
        if (self.entities) |entities| {
            entities.deinit(); // also frees the tracker (SONNY-2394)
        }
        if (self.bindings) |bindings| {
            bindings.deinit();
            allocator.destroy(bindings);
        }
    }
};

// CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876; FEATURE="ForStatement"; ASPECT=BodyExecution; STATUS=TESTED; TEST=tests/test_for_write_body.zig; OWNER=engine; UPDATED=2026-08-29
/// geode#876: execute the FOR body once per collection element. The loop
/// variable (plus WITH ORDINALITY / WITH OFFSET counters and any enclosing WITH
/// bindings) rides as query parameters, which is how the body's CREATE / MERGE /
/// MATCH...SET clauses already resolve bare identifiers (Env.get falls back to
/// param bindings, value_types.zig:186). Dispatch goes through the ordinary
/// executeQueryWithContext path, so cluster write gating, budgets, RLS/tenancy
/// and the FTS live-maintenance hooks all fire exactly as they do for a
/// standalone statement.
fn executeForBody(
    allocator: std.mem.Allocator,
    for_stmt: ast.ForStatement,
    body: *const ast.Query,
    items: []const Value,
    base_names: []const []const u8,
    base_values: []const Value,
    context: ExecutionContext,
) !ExecutionResult {
    std.debug.assert(base_names.len == base_values.len);
    std.debug.assert(context.query_param_names.len == context.query_param_values.len);

    var acc = ForBodyAccumulator{};
    errdefer acc.deinit(allocator);
    try runForBodyInto(allocator, for_stmt, body, items, base_names, base_values, context, &acc);
    return acc.finish(allocator);
}

/// `body` once per element of `items` with `base_values` bound, each run's
/// result absorbed into `acc` (`executeForBody`'s loop).
fn runForBodyInto(
    allocator: std.mem.Allocator,
    for_stmt: ast.ForStatement,
    body: *const ast.Query,
    items: []const Value,
    base_names: []const []const u8,
    base_values: []const Value,
    context: ExecutionContext,
    acc: *ForBodyAccumulator,
) !void {
    const loop_binding_count = 1 +
        (if (for_stmt.ordinality_var != null) @as(usize, 1) else 0) +
        (if (for_stmt.offset_var != null) @as(usize, 1) else 0);
    const binding_capacity = loop_binding_count + base_names.len + context.query_param_names.len;

    var param_names = try std.ArrayList([]const u8).initCapacity(allocator, binding_capacity);
    defer param_names.deinit(allocator);
    var param_values = try std.ArrayList(Value).initCapacity(allocator, binding_capacity);
    defer param_values.deinit(allocator);

    for (items, 0..) |item, idx| {
        param_names.clearRetainingCapacity();
        param_values.clearRetainingCapacity();

        // Loop bindings come FIRST so the iteration variable shadows an outer
        // binding or parameter of the same name (lookups take the first match).
        try param_names.append(allocator, for_stmt.variable);
        try param_values.append(allocator, item);

        if (for_stmt.ordinality_var) |ord_var| {
            try param_names.append(allocator, ord_var);
            try param_values.append(allocator, Value{ .Int = @intCast(idx + 1) });
        }

        if (for_stmt.offset_var) |off_var| {
            try param_names.append(allocator, off_var);
            try param_values.append(allocator, Value{ .Int = @intCast(idx) });
        }

        for (base_names, base_values) |name, value| {
            try param_names.append(allocator, name);
            try param_values.append(allocator, value);
        }

        for (context.query_param_names, context.query_param_values) |name, value| {
            try param_names.append(allocator, name);
            try param_values.append(allocator, value);
        }

        var iter_ctx = context;
        iter_ctx.query_param_names = param_names.items;
        iter_ctx.query_param_values = param_values.items;

        var iter_result = try execution.executeQueryWithContext(allocator, body.*, iter_ctx);
        errdefer iter_result.deinit(allocator);
        // SONNY-6740: the rows are read after the later elements have run (a
        // staged RETURN, the whole result). A node or relationship a row holds
        // is the store's own, which a later element's CREATE moves when it
        // grows the shard: each element's rows own copies of theirs.
        try value_utilities.ownGraphEntities(allocator, &iter_result);
        try acc.absorb(allocator, &iter_result);
    }
}

/// SONNY-3144: `body` once per element of `items`, with `variable` bound to
/// the element as a parameter (ahead of the context's), as a FOR body runs;
/// the results appended in order. An UNWIND before a write runs this way.
pub fn executeQueryPerElement(
    allocator: std.mem.Allocator,
    variable: []const u8,
    items: []const Value,
    body: *const ast.Query,
    context: ExecutionContext,
) anyerror!ExecutionResult {
    const for_stmt = ast.ForStatement{ .variable = variable, .collection = .Null, .body = @constCast(body) };
    return executeForBody(allocator, for_stmt, body, items, &.{}, &.{}, context);
}

pub fn executeForWithBindings(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, with_result: ExecutionResult, context: ExecutionContext) !ExecutionResult {
    // A FOR with a RETURN runs over every row of the WITH, and its RETURN
    // projects (and aggregates over) all of the loop's rows at once.
    const body = for_stmt.body orelse
        return executeForReturn(allocator, for_stmt, with_result.columns, with_result.rows, context);
    // SONNY-6555 item 7: a body that reads runs over the FOR's whole working
    // table: every row of the WITH (only the first was read), its stages
    // (an aggregate, DISTINCT, ORDER BY, SKIP / LIMIT) over all of them.
    if (readsOnlyBody(body)) return @import("query_execution.zig").runReadForBody(allocator, for_stmt, body, with_result.columns, with_result.rows, context);

    // geode#876: a composed body (CREATE / MERGE / MATCH ... SET) runs once per
    // element with the WITH bindings still in scope.
    if (with_result.rows.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // CANARY: REQ=REQ-SONNY-6587-FOR-WRITE-EVERY-ROW; FEATURE="ForStatement"; ASPECT=WriteBodyAfterWith; STATUS=TESTED; TEST=tests/test_sonny6587_for_write_after_with.zig; OWNER=engine; UPDATED=2026-11-15
    // SONNY-6587 item 5: every row of the WITH, each with its own list (ISO/IEC
    // 39075:2024 14.8); the first row only was used. The write allowlist
    // admits a WITH of values (write_shape.allowWithFor) and, SONNY-6613,
    // MATCH ... WITH (write_shape.allowMatchWithFor) here. The list
    // is the statement's (`lentAllocator`), as a header's in
    // `expandForTable` (SONNY-6449): it leaked on every run.
    const staged = @import("write_shape.zig").returnStagesNeedWholeTable(body.*);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const carrier = if (staged) try @import("write_shape.zig").stagedCarrierBody(arena.allocator(), body.*) else null;
    const run_body: *const ast.Query = if (carrier) |*c| c else body;
    var acc = ForBodyAccumulator{};
    errdefer acc.deinit(allocator);
    for (with_result.rows) |row| {
        // The request params are in scope so a `$param` collection resolves
        // to the bound value instead of Null.
        const env = Env{
            .names = with_result.columns,
            .values = row,
            .allocator = allocator,
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };
        const collection_value = try eval.evalExpr(value_utilities.lentAllocator(allocator), for_stmt.collection, env);
        const items = try forElements(allocator, collection_value);
        defer if (items.owned) allocator.free(items.values);
        try runForBodyInto(allocator, for_stmt, run_body, items.values, with_result.columns, row, context, &acc);
    }
    if (staged) return stageForReturn(allocator, body.*, &acc, context);
    return acc.finish(allocator);
}

/// SONNY-6717: the RETURN of a writing FOR body over the rows every element
/// contributed (`acc`, `stagedCarrierBody`'s columns): its items projected and
/// aggregated over all of them, then DISTINCT, ORDER BY, SKIP and LIMIT, as
/// `executeForReturn` stages a FOR's RETURN.
fn stageForReturn(allocator: std.mem.Allocator, body: ast.Query, acc: *ForBodyAccumulator, context: ExecutionContext) !ExecutionResult {
    const return_clause = body.ret;
    try execution.validateGroupBy(return_clause, body.group_by);
    try execution.validateNoNestedAggregate(return_clause);
    var input = try acc.finish(allocator);
    defer {
        // The projection below holds the values; free the arrays only.
        input.owns_value_memory = false;
        input.deinit(allocator);
    }
    const projection = ast.WithClause{ .items = return_clause.items };
    var result = try execution.executeWithClauseWithGroupByAndParams(
        allocator,
        input,
        projection,
        body.group_by,
        body.having,
        context.query_param_names,
        context.query_param_values,
    );
    errdefer result.deinit(allocator);
    if (result.owned_graph_entities == null) {
        result.owned_graph_entities = input.owned_graph_entities;
        input.owned_graph_entities = null;
    }

    const columns = try result_utils.generateUniqueColumnNames(allocator, return_clause.items);
    for (result.columns) |col| allocator.free(col);
    allocator.free(result.columns);
    result.columns = columns;

    if (return_clause.distinct) try result_utils.applyDistinct(allocator, &result);
    if (body.order_by) |order| try execution.sortRowsEx(allocator, &result, order, return_clause.items);

    const start = try forWindowValue(body.offset, body.offset_param, context) orelse 0;
    const limit = try forWindowValue(body.limit, body.limit_param, context);
    var end = result.rows.len;
    if (limit) |l| end = @min(end, std.math.add(usize, start, l) catch std.math.maxInt(usize));
    if (start != 0 or end != result.rows.len) try execution.applyRowWindow(allocator, &result, start, end);
    return result;
}

/// The elements a FOR iterates for its list's value: a list's elements; none
/// for a Null (e.g. an unbound/absent $param yields ZERO iterations, never one
/// spurious null iteration); any other value alone.
const ForElements = struct { values: []const Value, owned: bool };

fn forElements(allocator: std.mem.Allocator, collection_value: Value) !ForElements {
    return switch (collection_value) {
        .List => |list| .{ .values = list, .owned = false },
        .Null => .{ .values = &.{}, .owned = false },
        else => blk: {
            const one = try allocator.alloc(Value, 1);
            one[0] = collection_value;
            break :blk .{ .values = one, .owned = true };
        },
    };
}

/// A binding table: column names and rows of values.
const ForTable = struct {
    columns: []const []const u8,
    rows: []const []Value,
};

/// `table` extended by one FOR header, as ISO/IEC 39075 FOR extends the
/// working table: every row once per element of the header's list
/// (evaluated in that row), with the loop variable (and its ORDINALITY or
/// OFFSET) bound. The loop's names come first, so they shadow an outer name.
/// The new table's columns and rows are allocated; the values are borrowed.
fn expandForTable(allocator: std.mem.Allocator, header: ast.ForLoop, table: ForTable, context: ExecutionContext) !ForTable {
    const extra: usize = 1 + @as(usize, @intFromBool(header.ordinality_var != null)) + @as(usize, @intFromBool(header.offset_var != null));
    const columns = try allocator.alloc([]const u8, extra + table.columns.len);
    errdefer allocator.free(columns);
    var c: usize = 0;
    columns[c] = header.variable;
    c += 1;
    if (header.ordinality_var) |name| {
        columns[c] = name;
        c += 1;
    }
    if (header.offset_var) |name| {
        columns[c] = name;
        c += 1;
    }
    @memcpy(columns[extra..], table.columns);

    var rows = std.ArrayList([]Value).empty;
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    for (table.rows) |row| {
        // The request params ride along so a `$param` list resolves.
        const env = Env{
            .names = table.columns,
            .values = row,
            .allocator = allocator,
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };
        // SONNY-6449: a list the header computes is the statement's (its
        // scratch arena): the rows borrow its elements, and it leaked.
        const collection_value = try eval.evalExpr(value_utilities.lentAllocator(allocator), header.collection, env);
        const items = try forElements(allocator, collection_value);
        defer if (items.owned) allocator.free(items.values);
        try rows.ensureUnusedCapacity(allocator, items.values.len);
        for (items.values, 0..) |item, idx| {
            const new_row = try allocator.alloc(Value, extra + row.len);
            var v: usize = 0;
            new_row[v] = item;
            v += 1;
            if (header.ordinality_var != null) {
                new_row[v] = Value{ .Int = @intCast(idx + 1) };
                v += 1;
            }
            if (header.offset_var != null) {
                new_row[v] = Value{ .Int = @intCast(idx) };
                v += 1;
            }
            @memcpy(new_row[extra..], row);
            rows.appendAssumeCapacity(new_row);
        }
    }
    return .{ .columns = columns, .rows = try rows.toOwnedSlice(allocator) };
}

fn freeForTable(allocator: std.mem.Allocator, table: ForTable) void {
    for (table.rows) |row| allocator.free(row);
    allocator.free(table.rows);
    allocator.free(table.columns);
}

// CANARY: REQ=REQ-SONNY-6555-FOR-CHAIN-STAGE; FEATURE="ForStatement"; ASPECT=ReadBodyOverWholeTable; STATUS=TESTED; TEST=tests/test_sonny6555_for_chain_stage.zig; OWNER=engine; UPDATED=2026-11-14
/// SONNY-6555 item 7: the working table every FOR header of `for_stmt`
/// extends from `in_columns` / `in_rows` (ISO/IEC 39075:2024 14.8: a record
/// per element of each incoming record's list), as a result the chain
/// executor reads as the part before the FOR's body: its column names and
/// row arrays are its own, its values are borrowed (`owns_value_memory`
/// false).
pub fn forTableResult(
    allocator: std.mem.Allocator,
    for_stmt: ast.ForStatement,
    in_columns: []const []const u8,
    in_rows: []const []Value,
    context: ExecutionContext,
) !ExecutionResult {
    var table = ForTable{ .columns = in_columns, .rows = in_rows };
    var owns_table = false;
    defer if (owns_table) freeForTable(allocator, table);
    const first = ast.ForLoop{
        .variable = for_stmt.variable,
        .collection = for_stmt.collection,
        .ordinality_var = for_stmt.ordinality_var,
        .offset_var = for_stmt.offset_var,
    };
    for (0..1 + for_stmt.nested.len) |i| {
        const header = if (i == 0) first else for_stmt.nested[i - 1];
        const next = try expandForTable(allocator, header, table, context);
        if (owns_table) freeForTable(allocator, table);
        table = next;
        owns_table = true;
    }
    const columns = try allocator.alloc([]const u8, table.columns.len);
    var filled: usize = 0;
    errdefer {
        for (columns[0..filled]) |c| allocator.free(c);
        allocator.free(columns);
    }
    for (table.columns, columns) |c, *o| {
        o.* = try allocator.dupe(u8, c);
        filled += 1;
    }
    // The rows move to the result; the column-name slice is freed.
    allocator.free(table.columns);
    owns_table = false;
    return ExecutionResult{
        .columns = columns,
        .rows = @constCast(table.rows),
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// SONNY-6555 item 7: whether a FOR's body runs over the FOR's whole working
/// table (`query_execution.runReadForBody`): a body that reads. A body that
/// writes still runs once per element (geode#876).
fn readsOnlyBody(body: *const ast.Query) bool {
    return !@import("../query/query_traits.zig").isQueryMutating(body);
}

/// A FOR's SKIP or LIMIT: the literal, else the named parameter's value.
fn forWindowValue(literal: ?usize, param: ?[]const u8, context: ExecutionContext) !?usize {
    if (literal) |v| return v;
    const name = param orelse return null;
    for (context.query_param_names, context.query_param_values) |pn, pv| {
        if (std.mem.eql(u8, pn, name)) return switch (pv) {
            .Int => |i| if (i >= 0) @as(usize, @intCast(i)) else error.InvalidWindowParameter,
            else => error.InvalidWindowParameter,
        };
    }
    return null;
}

// CANARY: REQ=REQ-GQL-FOR-RETURN-AGGREGATION; FEATURE="ForStatement"; ASPECT=ReturnAggregation; STATUS=TESTED; TEST=tests/test_for_aggregation.zig; OWNER=engine; UPDATED=2026-10-11
/// `FOR ... RETURN ...` over the rows `in_columns`/`in_rows` (one empty row
/// for a FOR that starts a statement; the rows of a WITH or MATCH before it).
/// Each FOR header extends the rows (`expandForTable`); the RETURN then
/// projects the resulting table the way a RETURN after a MATCH does: an
/// aggregate (sum, count, avg, min, max, collect) is computed over all of its
/// rows (one row when nothing is grouped, even with no rows: sum NULL, count
/// 0); a non-aggregated item next to one needs a GROUP BY (42803 otherwise);
/// then DISTINCT, ORDER BY, SKIP and LIMIT. A bare variable names its
/// column after itself (`generateUniqueColumnNames`).
///
/// Each element's RETURN was evaluated on its own, so `FOR x IN [1, 2, 3]
/// RETURN sum(x)` returned three rows of NULL, ORDER BY, SKIP and LIMIT were
/// ignored, and every unaliased column was named `?column?`.
pub fn executeForReturn(
    allocator: std.mem.Allocator,
    for_stmt: ast.ForStatement,
    in_columns: []const []const u8,
    in_rows: []const []Value,
    context: ExecutionContext,
) !ExecutionResult {
    const return_clause = for_stmt.return_clause orelse return error.InvalidForStatement;
    try execution.validateGroupBy(return_clause, for_stmt.group_by);
    try execution.validateNoNestedAggregate(return_clause);

    // The loops, outermost first.
    var table = ForTable{ .columns = in_columns, .rows = in_rows };
    var owns_table = false;
    defer if (owns_table) freeForTable(allocator, table);
    const first = ast.ForLoop{
        .variable = for_stmt.variable,
        .collection = for_stmt.collection,
        .ordinality_var = for_stmt.ordinality_var,
        .offset_var = for_stmt.offset_var,
    };
    for (0..1 + for_stmt.nested.len) |i| {
        const header = if (i == 0) first else for_stmt.nested[i - 1];
        const next = try expandForTable(allocator, header, table, context);
        if (owns_table) freeForTable(allocator, table);
        table = next;
        owns_table = true;
    }

    // The projection: the WITH projection's, which aggregates and groups
    // as a RETURN after a MATCH does (validated above).
    const input = ExecutionResult{
        .columns = @constCast(table.columns),
        .rows = @constCast(table.rows),
        .flags = std.ArrayList([]const u8).empty,
    };
    const projection = ast.WithClause{ .items = return_clause.items };
    var result = try execution.executeWithClauseWithGroupByAndParams(
        allocator,
        input,
        projection,
        for_stmt.group_by,
        null,
        context.query_param_names,
        context.query_param_values,
    );
    errdefer result.deinit(allocator);

    // Column names as a RETURN after a MATCH names them.
    const columns = try result_utils.generateUniqueColumnNames(allocator, return_clause.items);
    for (result.columns) |col| allocator.free(col);
    allocator.free(result.columns);
    result.columns = columns;

    if (return_clause.distinct) try result_utils.applyDistinct(allocator, &result);
    if (for_stmt.order_by) |order| try execution.sortRowsEx(allocator, &result, order, return_clause.items);

    const start = try forWindowValue(for_stmt.offset, for_stmt.offset_param, context) orelse 0;
    const limit = try forWindowValue(for_stmt.limit, for_stmt.limit_param, context);
    var end = result.rows.len;
    if (limit) |l| end = @min(end, std.math.add(usize, start, l) catch std.math.maxInt(usize));
    if (start != 0 or end != result.rows.len) try execution.applyRowWindow(allocator, &result, start, end);
    return result;
}

// PERF: PHASE5_COLUMN_BATCH_ALLOC - Helper function for batch column allocation
// CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=HELPER_FN; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
/// Phase 5.1.1 optimization: Allocate all column strings in a single buffer
/// Reduces N allocations to 1 allocation for N columns (20-30% performance gain)
///
/// Returns a struct containing:
/// - columns: Array of string slices pointing into the buffer
/// - buffer: The allocated buffer (must be stored in ExecutionResult.column_buffer)
fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
    // Calculate total size needed
    var total_size: usize = 0;
    for (strings) |s| {
        total_size += s.len;
    }

    // Allocate single buffer for all strings
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    // Allocate columns array
    const columns = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(columns);

    // Copy strings into buffer and create slices
    var offset: usize = 0;
    for (strings, 0..) |s, i| {
        const slice = buffer[offset .. offset + s.len];
        @memcpy(slice, s);
        columns[i] = slice;
        offset += s.len;
    }

    return .{ .columns = columns, .buffer = buffer };
}

pub fn executeFor(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, context: ExecutionContext) !ExecutionResult {
    // geode#876: `FOR x IN <list> <data-modifying statement>` — run the body
    // once per element instead of projecting a RETURN. An empty collection
    // therefore writes nothing (zero iterations).
    if (for_stmt.body) |body| {
        // SONNY-6555 item 7: a body that reads runs over the FOR's whole
        // working table (one empty row in), not once per element: its
        // aggregate, DISTINCT, ORDER BY, SKIP / LIMIT read every element's
        // rows (ISO/IEC 39075:2024 14.8, 14.11).
        if (readsOnlyBody(body)) {
            var no_values = [_]Value{};
            const one_row = [_][]Value{&no_values};
            return @import("query_execution.zig").runReadForBody(allocator, for_stmt, body, &.{}, &one_row, context);
        }
        // Evaluate the collection expression with the request params in scope
        // so a `$param` collection (FOR..IN parameter-bound list) resolves to
        // the bound value instead of Null.
        const empty_env = Env{
            .allocator = allocator,
            .names = &.{},
            .values = &.{},
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };
        // SONNY-6449: on the statement's scratch arena, as in `expandForTable`.
        const collection_value = try eval.evalExpr(value_utilities.lentAllocator(allocator), for_stmt.collection, empty_env);
        const items = try forElements(allocator, collection_value);
        defer if (items.owned) allocator.free(items.values);
        return executeForBody(allocator, for_stmt, body, items.values, &.{}, &.{}, context);
    }

    // One empty row in: the FOR's rows come from its list alone.
    var empty_row = [_]Value{};
    const input_rows = [_][]Value{&empty_row};
    return executeForReturn(allocator, for_stmt, &.{}, &input_rows, context);
}

pub fn executeValues(allocator: std.mem.Allocator, values_stmt: ast.ValuesStatement, context: ExecutionContext) !ExecutionResult {
    // Evaluate all row expressions with the request params in scope so a
    // `VALUES ($param, ...)` row resolves the bound value instead of Null.
    const empty_env = Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };

    // Prepare result rows
    var result_rows = try std.ArrayList([]Value).initCapacity(allocator, values_stmt.rows.len);

    // Evaluate each row
    for (values_stmt.rows) |row_exprs| {
        var row_values = try allocator.alloc(Value, row_exprs.len);
        for (row_exprs, 0..) |expr, i| {
            row_values[i] = try eval.evalExpr(allocator, expr, empty_env);
        }
        try result_rows.append(allocator, row_values);
    }

    // If there's a next statement (like MATCH or RETURN), evaluate it with VALUES bindings
    if (values_stmt.next_statement) |next_stmt| {
        switch (next_stmt.*) {
            .Query => |query| {
                // Check if query has MATCH clause - if so, execute full query with parameters
                if (query.match.chains.len > 0) {
                    // The VALUES rows are this branch's own: they are bound
                    // as parameters for each run below and never returned.
                    // They leaked. (Their values are not freed: a row of the
                    // result may share one, such as a string it projects.)
                    defer {
                        for (result_rows.items) |row| allocator.free(row);
                        result_rows.deinit(allocator);
                    }
                    // CANARY: REQ=REQ-SONNY-6351-VALUES-MATCH-STRINGS; FEATURE="ValuesStatement"; ASPECT=RowValueOwnership; STATUS=TESTED; TEST=tests/test_sonny2672_read_semantics_batch.zig; OWNER=engine; UPDATED=2026-11-12
                    // SONNY-6351 item 4: what a VALUES row computed (a string
                    // concatenation, a list or map literal, an allocating
                    // call) moves to the query's scratch arena, which the
                    // transports release after the result is sent, and its
                    // first copy is freed: a row of the result may borrow it,
                    // so it cannot be freed here, and it leaked. As a WITH
                    // stage's computed values do (SONNY-3148,
                    // `match_operations.ownWithStageValues`). SONNY-6383
                    // item 8: without a scratch arena (an embedded caller)
                    // the result copies its rows' values and owns them, and
                    // what the VALUES rows computed is freed after the last
                    // MATCH run (it leaked).
                    const values_scratch = query_arena.currentScratchAllocator();
                    if (values_scratch) |scratch| {
                        for (values_stmt.rows, result_rows.items) |row_exprs, row_values| {
                            for (row_exprs, row_values) |expr, *cell| {
                                if (!value_utilities.evaluatesFresh(expr)) continue;
                                const computed = cell.*;
                                cell.* = try value_utilities.duplicateValue(scratch, computed);
                                value_utilities.freeEvaluatedValue(allocator, expr, computed);
                            }
                        }
                    }
                    // SONNY-2682: the RETURN is checked as any query's is: a
                    // mix of aggregates and plain items with no GROUP BY is
                    // refused (42000), as without the VALUES.
                    // SONNY-6383 item 3: the RETURN's own GROUP BY.
                    try execution.validateGroupBy(query.ret, query.returnStageGroupBy());
                    // VALUES ... MATCH pattern: execute MATCH for each VALUES row and collect results
                    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, result_rows.items.len * 4); // Estimate
                    var final_columns: ?[]const []const u8 = null;

                    // PERF: PHASE5_PARAM_ALLOC - Allocate parameter arrays once instead of per-iteration
                    // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE="ExecutionOptimization"; ASPECT=PARAM_REUSE; STATUS=BENCHED; BENCH=docs/benchmarks/phase5_allocation.md; OWNER=performance; UPDATED=2026-01-25
                    // Phase 5.1.2: Pre-allocate parameter arrays before loop (reduces N allocations to 1)
                    var param_names = try allocator.alloc([]const u8, values_stmt.column_names.len);
                    defer allocator.free(param_names);
                    var param_values = try allocator.alloc(Value, values_stmt.column_names.len);
                    defer allocator.free(param_values);

                    // For each VALUES row, execute the full MATCH query with bindings as parameters
                    for (result_rows.items) |row_values| {
                        // Build parameter names and values from VALUES columns (reuse arrays)
                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                param_names[i] = col_name;
                                param_values[i] = row_values[i];
                            }
                        }

                        // Execute the query with VALUES bindings as parameters
                        // CANARY: REQ=REQ-MULTI-GRAPH-014; FEATURE="MultiGraphIsolation"; ASPECT=ValuesMatch; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                        const values_graph = if (context.session_state) |session| session.graph else null;
                        const match_result = try executeMatchQueryWithParams(allocator, query, param_names, param_values, query.inline_let_bindings, values_graph);

                        // Collect results from this execution
                        for (match_result.rows) |row| {
                            try final_rows.append(allocator, row);
                        }

                        // Use column names from first result
                        if (final_columns == null) {
                            final_columns = match_result.columns;
                        } else {
                            // Free duplicate column arrays
                            for (match_result.columns) |col| {
                                allocator.free(col);
                            }
                            allocator.free(match_result.columns);
                        }

                        // Free the rows array (but not the individual rows, which are now owned by final_rows)
                        allocator.free(match_result.rows);
                    }

                    var owns_values = false;
                    if (values_scratch == null) {
                        const computed_any = computed: {
                            for (values_stmt.rows) |row_exprs| {
                                for (row_exprs) |expr| if (value_utilities.evaluatesFresh(expr)) break :computed true;
                            }
                            break :computed false;
                        };
                        if (computed_any) {
                            for (final_rows.items) |row| {
                                for (row) |*cell| cell.* = try value_utilities.duplicateValue(allocator, cell.*);
                            }
                            owns_values = true;
                            for (values_stmt.rows, result_rows.items) |row_exprs, row_values| {
                                for (row_exprs, row_values) |expr, cell| {
                                    if (value_utilities.evaluatesFresh(expr)) value_utilities.freeEvaluatedValue(allocator, expr, cell);
                                }
                            }
                        }
                    }

                    return ExecutionResult{
                        .columns = if (final_columns) |cols| @constCast(cols) else try allocator.alloc([]const u8, 0),
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = std.ArrayList([]const u8).empty,
                        .owns_value_memory = owns_values,
                    };
                } else {
                    // VALUES ... RETURN pattern (no MATCH): evaluate RETURN for each VALUES row
                    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, result_rows.items.len);

                    // Build arrays for environment (pre-sized)
                    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, values_stmt.column_names.len);
                    var env_values_list = try std.ArrayList(Value).initCapacity(allocator, values_stmt.column_names.len);

                    // For each VALUES row, create environment and evaluate RETURN
                    for (result_rows.items) |row_values| {
                        env_names_list.clearRetainingCapacity();
                        env_values_list.clearRetainingCapacity();

                        // Bind column names to row values
                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                try env_names_list.append(allocator, col_name);
                                try env_values_list.append(allocator, row_values[i]);
                            }
                        }

                        // Create environment for this row. The request params
                        // ride along so a RETURN item referencing `$param`
                        // resolves.
                        const row_env = Env{
                            .allocator = allocator,
                            .names = env_names_list.items,
                            .values = env_values_list.items,
                            .param_names = context.query_param_names,
                            .param_values = context.query_param_values,
                        };

                        // Evaluate RETURN items for this row (pre-sized)
                        var result_row = try std.ArrayList(Value).initCapacity(allocator, query.ret.items.len);

                        for (query.ret.items) |ret_item| {
                            const value = try eval.evalExpr(allocator, ret_item.expr, row_env);
                            try result_row.append(allocator, value);
                        }

                        try final_rows.append(allocator, try result_row.toOwnedSlice(allocator));
                    }

                    // Build column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
                    var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, query.ret.items.len);
                    defer col_name_strings.deinit(allocator);

                    for (query.ret.items) |ret_item| {
                        const col_name = if (ret_item.alias) |alias|
                            alias
                        else
                            "?column?";
                        try col_name_strings.append(allocator, col_name);
                    }

                    const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

                    return ExecutionResult{
                        .columns = col_result.columns,
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = std.ArrayList([]const u8).empty,
                        .column_buffer = col_result.buffer,
                    };
                }
            },
            else => return error.UnsupportedValuesChain,
        }
    }

    // No continuation - return VALUES table directly
    // Copy column names
    var columns = try allocator.alloc([]const u8, values_stmt.column_names.len);
    for (values_stmt.column_names, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };
}

pub fn executeExplain(allocator: std.mem.Allocator, exp: ast.ExplainStatement, context: ExecutionContext) anyerror!ExecutionResult {
    // M2: context now used for catalog access via dependency injection
    // EXPLAIN shows the query execution plan with cost estimates

    switch (exp.query.*) {
        .Query => |q| {
            var planned_query = q;
            if (try planned_read_runtime.buildPlanIfSupported(allocator, &planned_query, context)) |plan| {
                var owned_plan = plan;
                defer owned_plan.deinit(allocator);
                return buildPlannedExplainResult(allocator, owned_plan);
            }
        },
        else => {},
    }

    // Helper to format plan operations with stack buffer (performance optimization)
    const formatPlanOp = struct {
        fn format(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
            var buf: [256]u8 = undefined;
            const result = try std.fmt.bufPrint(&buf, fmt, args);
            return try alloc.dupe(u8, result);
        }
    }.format;

    // Generate plan steps with cost information (pre-size for typical query)
    var plan_steps = try std.ArrayList(struct { op: []const u8, cost: i64 }).initCapacity(allocator, 10);
    defer plan_steps.deinit(allocator);
    // SONNY-6498: the rows copy each step's text; it was never freed.
    defer for (plan_steps.items) |step| allocator.free(step.op);

    // Track cumulative cost
    var total_cost: i64 = 0;

    // Analyze the query and build plan with cost estimates
    const query_stmt = exp.query.*;
    switch (query_stmt) {
        .Query => |q| {
            if (q.match.chains.len > 0) {
                const chain = q.match.chains[0];
                if (chain.head != null) {
                    // SONNY-6276: this plan is built only when the planned
                    // runtime declines the query (above), so the legacy
                    // executor runs it, and it scans: it never reports a
                    // catalog index seek (SONNY-1335). It said IndexSeek for
                    // any catalog index on the first inline property or an
                    // indexed equality anywhere in the WHERE.
                    // NodeScan base cost: 100 per node
                    const node_cost: i64 = 100;
                    total_cost += node_cost;
                    try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "NodeScan (cost: {})", .{node_cost}), .cost = node_cost });
                }
                if (chain.hops.len > 0) {
                    // ExpandRelationships cost: 50 per hop
                    const expand_cost: i64 = @intCast(chain.hops.len * 50);
                    total_cost += expand_cost;
                    try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "ExpandRelationships (cost: {})", .{expand_cost}), .cost = expand_cost });
                }
            }
            if (q.where_clause != null) {
                // Filter cost: 10 per condition
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Filter (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.filter_clause != null) {
                // Additional filter cost
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Filter FILTER clause (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.group_by != null) {
                // Aggregate cost: 200 for grouping
                const agg_cost: i64 = 200;
                total_cost += agg_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Aggregate (cost: {})", .{agg_cost}), .cost = agg_cost });
            }
            if (q.order_by != null) {
                // Sort cost: 150 for sorting
                const sort_cost: i64 = 150;
                total_cost += sort_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Sort (cost: {})", .{sort_cost}), .cost = sort_cost });
            }
            if (q.limit != null or q.offset != null) {
                // Limit cost: 5
                const limit_cost: i64 = 5;
                total_cost += limit_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Limit (cost: {})", .{limit_cost}), .cost = limit_cost });
            }
            if (q.ret.distinct) {
                // Distinct cost: 100
                const distinct_cost: i64 = 100;
                total_cost += distinct_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Distinct (cost: {})", .{distinct_cost}), .cost = distinct_cost });
            }
            // Project cost: 5
            const project_cost: i64 = 5;
            total_cost += project_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Project (cost: {})", .{project_cost}), .cost = project_cost });
        },
        .Create => {
            // CREATE costs
            const create_node_cost: i64 = 50;
            const create_rel_cost: i64 = 75;
            total_cost += create_node_cost + create_rel_cost;

            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "CreateNodes (cost: {})", .{create_node_cost}), .cost = create_node_cost });
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "CreateRelationships (cost: {})", .{create_rel_cost}), .cost = create_rel_cost });
        },
        .Delete => {
            // DELETE cost
            const delete_cost: i64 = 100;
            total_cost += delete_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "DeleteNodes (cost: {})", .{delete_cost}), .cost = delete_cost });
        },
        else => {
            const generic_cost: i64 = 50;
            total_cost += generic_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "ExecuteStatement (cost: {})", .{generic_cost}), .cost = generic_cost });
        },
    }

    // Create result with plan column. SONNY-6498: built so that a failed
    // allocation frees what was made (`ResultBuilder`); the result owns its
    // cells (they leaked with it).
    var b = result_utils.ResultBuilder.init(allocator);
    errdefer b.deinit();
    try b.column("plan");
    // Add header row
    try b.textRow(&.{"EXPLAIN"});
    // Add operation rows
    var line_buf: [512]u8 = undefined;
    for (plan_steps.items) |step| {
        try b.textRow(&.{try std.fmt.bufPrint(&line_buf, "  {s}", .{step.op})});
    }
    // Add total cost row
    try b.textRow(&.{try std.fmt.bufPrint(&line_buf, "Total cost: {}", .{total_cost})});
    return b.finish();
}

// CANARY: REQ=GAP-0868; FEATURE="PROFILE runtime telemetry"; ASPECT=WallClockTiming; STATUS=TESTED; TEST=tests/test_gap0868_profile_timing.zig; OWNER=execution; UPDATED=2026-06-10
// PROFILE executes the wrapped statement and returns execution statistics.
//
// Two result shapes:
//   - planned_query_profile: storage-native reads carry a RuntimeTrace with
//     REAL per-operator timing (time_ns, input_rows, rows per RuntimeOp) —
//     see planned_read_runtime.executeProfiledIfSupported.
//   - query_profile (fallback): non-Query statements (SHOW, DDL, ...) and
//     reads demoted by the concrete-tenant guard (GAP-0846/GAP-0509) are
//     executed through the generic dispatcher; GAP-0868 wraps that execution
//     in a CLOCK_MONOTONIC window and reports real statement-level `time_ms`
//     (previously a hard-coded `time = 1` placeholder). Per-operator timing
//     is NOT available on this path — the generic dispatcher exposes no
//     operator hooks; that residual is documented in docs/EXPLAIN_PROFILE.md.
pub fn executeProfile(allocator: std.mem.Allocator, prof: ast.ProfileStatement, context: ExecutionContext) anyerror!ExecutionResult {
    switch (prof.query.*) {
        .Query => |q| {
            var planned_query = q;
            if (try planned_read_runtime.executeProfiledIfSupported(
                allocator,
                &planned_query,
                context,
                context.query_param_names,
                context.query_param_values,
                true,
            )) |planned| {
                var owned_planned = planned;
                defer owned_planned.deinitMetadata(allocator);
                defer owned_planned.result.deinit(allocator);
                return buildPlannedProfileResult(allocator, owned_planned);
            }
        },
        else => {},
    }

    // Execute the wrapped statement under a real monotonic wall-clock window
    // (GAP-0868). The window covers exactly the statement's execution — not
    // parse (already done by the caller) and not profile-row construction.
    const profile_start_ns = monoNanosNow();
    var query_result = try executeStatementWithContext(allocator, prof.query.*, context);
    const profile_elapsed_ns = monoNanosNow() -| profile_start_ns;
    defer query_result.deinit(allocator);

    // Return profiling statistics. SONNY-6498: built so that a failed
    // allocation frees what was made (`ResultBuilder`).
    var b = result_utils.ResultBuilder.init(allocator);
    errdefer b.deinit();
    try b.column("metric");
    try b.column("value");
    // Profile type indicator
    try b.textRow(&.{ "profile", "query_profile" });
    // Row count
    try profileMetric(&b, "rows", .{ .Int = @intCast(query_result.rows.len) });
    // Column count
    try profileMetric(&b, "columns", .{ .Int = @intCast(query_result.columns.len) });
    // Execution time: real wall-clock milliseconds measured around the
    // wrapped statement (GAP-0868; replaces the old `time = 1` placeholder).
    try profileMetric(&b, "time_ms", .{ .Int = @intCast(profile_elapsed_ns / std.time.ns_per_ms) });
    // GAP-0535: every row value above is a fresh dupe (metric-name strings)
    // or a scalar — the result fully owns its value memory, so deinit is
    // leak-free under a strict allocator (this was the leak the GAP-0868
    // test originally had to hide behind an arena).
    return b.finish();
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ExecutorFunction; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
// CANARY: REQ=REQ-SONNY-6313-EXPLAIN-POLICY-GATES; FEATURE="GPS EXPLAIN POLICY"; ASPECT=SameQuestionsAsTheGates; STATUS=TESTED; TEST=tests/test_sonny6313_explain_policy_gates.zig; OWNER=security; UPDATED=2026-11-12
// EXPLAIN POLICY FOR <inner_query>
//
// Reports, one row per question, the GPS decisions the QUIC and gRPC
// handlers' gates would ask for the inner statement in this session, with
// columns:
//
//   step | action | resource | decision | reason_code
//
// SONNY-6313: the questions are the gates' own, for the session's graph:
//   * the read gate (`session_graph.programReadPermitted`):
//     `decide(match_, graph)` on every graph the statement reads
//     (`query_traits.programReadGraphList`), unless it reads no store;
//   * the write gate (`session_graph.requestChangePermitted`), for a
//     statement that changes data (`write_walk.statementActions`): the
//     actions `gps.changePermittedOn` asks on the graph it changes (CREATE,
//     UPDATE, DELETE; WRITE and SCHEMA for DDL; WRITE, CREATE, UPDATE and
//     DELETE for a change no finer action names), or, for a self-locking
//     procedure, `gps.writePermitted` (write on the database, refused by a
//     deny of a write on any graph).
// SONNY-6369: then the checks the executor makes itself: USE GRAPH's
// `mayBind`, the procedure gate (`gps.procedurePermitted`), and the DDL
// schema gates (`maySchema` on the graph, `maySchemaDatabase` for DDL
// catalogued database-wide).
// A statement nothing asks about (the security DDL, SHOW, session
// statements) reports the one action `classifyAction` derives, on the
// database. It used to report that one action on the database for every
// statement, which no graph-scoped policy matches (SONNY-2753) and which
// is not what the per-action gates ask (SONNY-2781).
//
// When the execution context carries no Principal, an unauthenticated decision
// is returned (reason_code = "no_principal") — GPS's standard behaviour.
pub fn executeExplainPolicy(allocator: std.mem.Allocator, ep: ast.ExplainPolicyStatement, context: ExecutionContext) anyerror!ExecutionResult {
    const gps = @import("../security/gps.zig");
    const principal_mod = @import("../security/principal.zig");
    const query_traits = @import("../query/query_traits.zig");
    const write_walk = @import("write_walk.zig");

    // Use the context's canonical Principal when available; otherwise fall back
    // to an anonymous stub so the call always reaches gps.decide().
    const anon_principal = principal_mod.Principal{
        .user_id = null,
        .username = null,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
        .custom_roles = &.{},
        .auth_method = .anonymous,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = .unknown,
        .source = .internal_service,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
    };
    const principal: *const principal_mod.Principal = if (context.principal) |p| p else &anon_principal;

    // The inner statement as the one statement of a program, from the
    // session's graph, as the handlers plan a request.
    var stmts = [_]ast.Statement{ep.inner.*};
    const program = ast.Program{ .statements = &stmts };
    const start_graph = session_graph.current(context);
    const home_graph = if (context.graph_bound) start_graph else graph_store.DEFAULT_GRAPH_NAME;

    var asks = std.ArrayList(PolicyAsk).empty;
    defer asks.deinit(allocator);

    // The read gate.
    const analysis = query_traits.analyzeProgram(&program);
    const store_free = analysis.kind == .rows and analysis.is_store_free and query_traits.restOfProgramIsNoop(&analysis, start_graph);
    if (!store_free) {
        const graphs = try query_traits.programReadGraphList(allocator, &program, start_graph, home_graph);
        defer allocator.free(graphs);
        for (graphs) |g| try addPolicyAsk(allocator, &asks, .match_, g);
    }

    // The write gate.
    const actions = write_walk.statementActions(ep.inner, .{});
    var self_locking_write = false;
    if (actions.writesData()) {
        if (query_traits.isSelfLockingProgram(&program)) {
            self_locking_write = true;
            try addPolicyAsk(allocator, &asks, .write, null);
        } else {
            const g = query_traits.programGraph(&program, start_graph, home_graph) orelse start_graph;
            if (actions.create) try addPolicyAsk(allocator, &asks, .create, g);
            if (actions.update) try addPolicyAsk(allocator, &asks, .update, g);
            if (actions.delete) try addPolicyAsk(allocator, &asks, .delete, g);
            if (actions.schema) {
                try addPolicyAsk(allocator, &asks, .write, g);
                try addPolicyAsk(allocator, &asks, .schema, g);
            }
            if (actions.write) {
                for ([_]gps.Action{ .write, .create, .update, .delete }) |a| try addPolicyAsk(allocator, &asks, a, g);
            }
        }
    }

    // CANARY: REQ=REQ-SONNY-6369-EXPLAIN-POLICY-EXECUTOR-CHECKS; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ExecutorGates; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6369: the checks the executor makes itself, after the handlers'
    // gates. They were not reported, so a statement those refused looked
    // allowed.
    var proc_name: ?[]u8 = null;
    defer if (proc_name) |n| allocator.free(n);
    switch (ep.inner.*) {
        // USE GRAPH (`session_graph.change`): `mayBind` on the graph it moves
        // to. A DSN-bound session does not move; the default graph needs no
        // check.
        .UseGraph => |ug| if (!context.graph_bound) {
            const target: ?[]const u8 = switch (query_traits.graphTarget(ug.graph_name)) {
                .current => null,
                .home => home_graph,
                .named => |n| n,
            };
            if (target) |g| {
                if (!std.mem.eql(u8, g, graph_store.DEFAULT_GRAPH_NAME)) try addPolicyAsk(allocator, &asks, .bind_graph, g);
            }
        },
        // The procedure gate (`procedure_registry.executeCallProcedure`):
        // read or write by the procedure's class, on the procedure, and no
        // deny on the graph it runs on (`gps.procedurePermitted`).
        .Call => |c| switch (c) {
            .Procedure => |proc| {
                const procedure_registry = @import("procedure_registry.zig");
                const procedure_access = @import("procedure_access.zig");
                proc_name = try procedure_registry.extractNormalizedProcName(allocator, proc);
                const action: gps.Action = switch (procedure_access.classifyProcedureName(proc_name.?)) {
                    .read_only => .read,
                    .mutating => .write,
                };
                const g = if (procedure_access.isDefaultGraphProcedure(proc)) graph_store.DEFAULT_GRAPH_NAME else start_graph;
                try addAsk(allocator, &asks, .{ .action = action, .graph = g, .procedure = proc_name.? });
            },
            .Subquery => {},
        },
        // The DDL schema gates (`session_graph.authorizeSchemaChange`,
        // `authorizeCatalogSchemaChange`, `maySchemaDatabase`): schema and
        // bind on the graph the statement names or runs on, and, for DDL
        // catalogued database-wide, schema on every graph.
        .CreateGraph => |cg| try addSchemaAsks(allocator, &asks, cg.name),
        .DropGraph => |dg| try addSchemaAsks(allocator, &asks, dg.name),
        .CreateIndex => |ci| {
            try addSchemaAsks(allocator, &asks, if (ci.index_type == .fulltext) graph_store.DEFAULT_GRAPH_NAME else start_graph);
            try addAsk(allocator, &asks, .{ .action = .schema, .graph = "*", .everywhere = true });
        },
        .DropIndex => {
            try addSchemaAsks(allocator, &asks, graph_store.DEFAULT_GRAPH_NAME);
            try addAsk(allocator, &asks, .{ .action = .schema, .graph = "*", .everywhere = true });
        },
        .CreateConstraint, .DropConstraint => {
            try addSchemaAsks(allocator, &asks, start_graph);
            try addAsk(allocator, &asks, .{ .action = .schema, .graph = "*", .everywhere = true });
        },
        .CreateSchema, .DropSchema => try addAsk(allocator, &asks, .{ .action = .schema, .graph = "*", .everywhere = true }),
        else => {},
    }

    // Nothing asks: the one action the statement names, on the database.
    if (asks.items.len == 0) try addPolicyAsk(allocator, &asks, classifyAction(ep.inner.*), null);

    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "step");
    columns[1] = try allocator.dupe(u8, "action");
    columns[2] = try allocator.dupe(u8, "resource");
    columns[3] = try allocator.dupe(u8, "decision");
    columns[4] = try allocator.dupe(u8, "reason_code");

    const rows = try allocator.alloc([]Value, asks.items.len);
    for (asks.items, 0..) |ask, i| {
        const req = gps.DecisionRequest{
            .principal = principal,
            .action = ask.action,
            .resource = if (ask.procedure) |name|
                gps.ResourceRef{ .procedure = name }
            else if (ask.graph) |g|
                gps.ResourceRef{ .graph = g }
            else
                gps.ResourceRef{ .database = {} },
        };
        var decision = try gps.decide(allocator, &req);
        if (decision.kind == .allow) {
            // `gps.writePermitted` also refuses a change of every graph when
            // a write is denied on any one graph; `schemaPermittedEverywhere`
            // likewise for schema; `procedurePermitted` when the action is
            // denied on the graph the procedure runs on.
            if (self_locking_write and ask.graph == null and ask.procedure == null and !gps.writePermitted(allocator, principal)) {
                decision = .{ .kind = .deny, .reason_code = "deny_on_a_graph" };
            } else if (ask.everywhere and !gps.schemaPermittedEverywhere(allocator, principal)) {
                decision = .{ .kind = .deny, .reason_code = "deny_on_a_graph" };
            } else if (ask.procedure) |name| {
                if (!try gps.procedurePermitted(allocator, principal, ask.action, name, ask.graph.?)) {
                    decision = .{ .kind = .deny, .reason_code = "deny_on_graph" };
                }
            }
        }
        const row = try allocator.alloc(Value, 5);
        row[0] = Value{ .Int = @intCast(i + 1) };
        row[1] = Value{ .Str = try allocator.dupe(u8, @tagName(ask.action)) };
        row[2] = Value{ .Str = if (ask.procedure) |name|
            try std.fmt.allocPrint(allocator, "procedure:{s}", .{name})
        else if (ask.graph) |g|
            try std.fmt.allocPrint(allocator, "graph:{s}", .{g})
        else
            try allocator.dupe(u8, "database") };
        row[3] = Value{ .Str = try allocator.dupe(u8, @tagName(decision.kind)) };
        row[4] = Value{ .Str = try allocator.dupe(u8, decision.reason_code) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

/// One question EXPLAIN POLICY reports: `action` on `graph`, or on the
/// database when null; on `procedure` when set (`graph` is then the graph it
/// runs on, whose denies also refuse it). `everywhere`: schema on every
/// graph (`graph` "*", and no deny on any graph).
const PolicyAsk = struct {
    action: @import("../security/gps.zig").Action,
    graph: ?[]const u8,
    procedure: ?[]const u8 = null,
    everywhere: bool = false,
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn addAsk(allocator: std.mem.Allocator, asks: *std.ArrayList(PolicyAsk), ask: PolicyAsk) !void {
    for (asks.items) |a| {
        if (a.action == ask.action and a.everywhere == ask.everywhere and optEql(a.graph, ask.graph) and optEql(a.procedure, ask.procedure)) return;
    }
    try asks.append(allocator, ask);
}

fn addPolicyAsk(allocator: std.mem.Allocator, asks: *std.ArrayList(PolicyAsk), action: @import("../security/gps.zig").Action, graph: ?[]const u8) !void {
    try addAsk(allocator, asks, .{ .action = action, .graph = graph });
}

/// SONNY-6369: what `session_graph.maySchema` asks for DDL on `graph`:
/// schema on it, and bind (`mayBind`; the default graph needs none).
fn addSchemaAsks(allocator: std.mem.Allocator, asks: *std.ArrayList(PolicyAsk), graph: []const u8) !void {
    try addPolicyAsk(allocator, asks, .schema, graph);
    if (!std.mem.eql(u8, graph, graph_store.DEFAULT_GRAPH_NAME)) try addPolicyAsk(allocator, asks, .bind_graph, graph);
}

/// Map an AST Statement to the GPS Action it primarily requires. EXPLAIN
/// POLICY reports it for a statement neither handler gate asks about.
fn classifyAction(stmt: ast.Statement) @import("../security/gps.zig").Action {
    const gps = @import("../security/gps.zig");
    _ = gps; // Action enum values referenced via return type
    return switch (stmt) {
        // Read operations
        .Query, .Union, .Intersect, .Except, .ScanValues, .InsertValue => .match_,
        // Write / graph mutation
        .Create, .Insert, .Merge => .create,
        .Delete => .delete,
        // Schema / DDL
        .CreateIndex, .DropIndex, .CreateConstraint, .DropConstraint, .CreateSchema, .DropSchema, .CreateGraph, .DropGraph, .CreateGraphType, .DropGraphType, .CreatePolicy, .DropPolicy, .AlterPolicy => .schema,
        // Auth admin
        .CreateUser, .AlterUser, .DropUser, .CreateRole, .DropRole, .Grant, .Revoke => .admin_user,
        // geode#876: a FOR carrying a data-modifying body is a WRITE, and GPS
        // must see it as one. A read-only `FOR ... RETURN` keeps .show_metadata.
        // CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876-CLASSIFY; FEATURE="ForStatement"; ASPECT=GpsActionClassification; STATUS=TESTED; TEST=tests/test_for_write_body.zig; OWNER=query_traits; UPDATED=2026-08-29
        .For => |f| if (f.body) |body| classifyQueryAction(body) else .show_metadata,
        // Metadata / introspection
        .Show, .Values, .Explain, .ExplainPolicy, .Profile, .Call, .Backup, .Restore, .SessionSet, .SessionReset, .SessionClose, .UseGraph, .StartTransaction, .Commit, .Rollback => .show_metadata,
    };
}

/// Map a Query body to the GPS Action its clauses require. Mirrors the
/// statement-level mapping above: DELETE > CREATE/MERGE > SET/REMOVE > read.
fn classifyQueryAction(q: *const ast.Query) @import("../security/gps.zig").Action {
    if (q.delete_items.len > 0) return .delete;
    if (q.create_pattern != null or q.merge_statement != null) return .create;
    if (q.set_clauses.len > 0 or q.remove_clauses.len > 0) return .update;
    return .match_;
}

fn buildPlannedExplainResult(allocator: std.mem.Allocator, plan: planned_read_runtime.Plan) !ExecutionResult {
    // SONNY-6498: built so that a failed allocation frees what was made.
    var b = result_utils.ResultBuilder.init(allocator);
    errdefer b.deinit();
    try b.column("plan");
    for (plan.ops) |op| try b.textRow(&.{plannedOpName(op.kind)});
    // GAP-0535: all row values are fresh dupes — fully owned.
    return b.finish();
}

/// One `metric, value` row of a PROFILE result.
fn profileMetric(b: *result_utils.ResultBuilder, metric: []const u8, value: Value) !void {
    const r = try b.row(2);
    r[0] = try b.text(metric);
    r[1] = value;
}

fn buildPlannedProfileResult(allocator: std.mem.Allocator, planned: planned_read_runtime.ProfiledExecution) !ExecutionResult {
    // SONNY-6498: built so that a failed allocation frees what was made.
    var b = result_utils.ResultBuilder.init(allocator);
    errdefer b.deinit();
    try b.column("metric");
    try b.column("value");
    try b.textRow(&.{ "profile", "planned_query_profile" });
    try profileMetric(&b, "rows", .{ .Int = @intCast(planned.result.rows.len) });
    try profileMetric(&b, "columns", .{ .Int = @intCast(planned.result.columns.len) });
    try profileMetric(&b, "time_ns", .{ .Int = @intCast(planned.trace.totalTimeNs()) });
    try profileMetric(&b, "operators", .{ .Int = @intCast(planned.trace.ops.len) });
    // GAP-0535: all row values are fresh dupes or scalars — fully owned.
    return b.finish();
}

fn plannedOpName(kind: planned_read_runtime.OpKind) []const u8 {
    return switch (kind) {
        .ConstProjection => "ConstProjection",
        .AllNodesScan => "AllNodesScan",
        .LabelScan => "LabelScan",
        .ExpandOut => "ExpandOut",
        .ExpandIn => "ExpandIn",
        .ExpandEither => "ExpandEither",
        .OptionalMatch => "OptionalMatch",
        .VarLengthExpand => "VarLengthExpand",
        .ShortestPath => "ShortestPath",
        .PathModeExpand => "PathModeExpand",
        .PathCapture => "PathCapture",
        .CallProcedure => "CallProcedure",
        .CallSubquery => "CallSubquery",
        .Create => "Create",
        .Merge => "Merge",
        .Unwind => "Unwind",
        .Set => "Set",
        .Remove => "Remove",
        .Delete => "Delete",
        .RecursiveCTE => "RecursiveCTE",
        .QueryChain => "QueryChain",
        .LegacyExecute => "LegacyExecute",
        .Filter => "Filter",
        .Aggregate => "Aggregate",
        .Project => "Project",
        .Distinct => "Distinct",
        .Limit => "Limit",
        .Sort => "Sort",
        .IndexSeek => "IndexSeek",
    };
}
const Catalog = @import("../schema/catalog.zig").Catalog;
const testing = std.testing;

test "executeShow tables reads persisted snapshot state" {
    const saved_override = graph_store.saveDataDirOverride();
    defer saved_override.restore();
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();

    var store_tmp = testing.tmpDir(.{});
    defer store_tmp.cleanup();

    const store_dir = try tmpDirRealpathAlloc(testing.allocator, &store_tmp.sub_path);
    defer testing.allocator.free(store_dir);

    const store = try graph_store.initGlobalStore(testing.allocator, store_dir);
    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "default");

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    // Simulate a stale compatibility cache; SHOW TABLES must re-read persisted storage.
    try store.clearNodes();

    var catalog_tmp = testing.tmpDir(.{});
    defer catalog_tmp.cleanup();

    const catalog_dir = try tmpDirRealpathAlloc(testing.allocator, &catalog_tmp.sub_path);
    defer testing.allocator.free(catalog_dir);

    const catalog = try Catalog.init(testing.allocator, catalog_dir);
    defer {
        catalog.deinit();
        testing.allocator.destroy(catalog);
    }

    var result = try executeShow(
        testing.allocator,
        .{ .show_type = .tables },
        .{ .catalog = catalog },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expect(result.rows[0].len >= 1);
    try testing.expect(result.rows[0][0] == .Str);
    try testing.expectEqualStrings("Person", result.rows[0][0].Str);
}
