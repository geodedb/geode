const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");
const value_types = @import("../value_types.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const admin_ddl = @import("admin_ddl.zig");
const planned_read_runtime = @import("planned_read_runtime.zig");

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
        .policies => &[_][]const u8{ "name", "graph", "actions", "enabled" },
        // CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ShowGrantsColumns; STATUS=TESTED; TEST=tests/test_gps_show_grants_for.zig; OWNER=security; UPDATED=2026-05-21
        .grants_for => &[_][]const u8{ "policy_name", "graph", "actions", "effect", "enabled" },
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
            // denied, return an empty result. Catalog indexes have no per-graph
            // field (they are registered globally); the active_graph gate is the
            // practical proxy for scoping visibility. When principal is null
            // (legacy/test paths) all indexes are returned unchanged.
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
                var iter = cat.indexes.iterator();
                while (iter.next()) |entry| {
                    const info = entry.value_ptr.*;
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
            const storage_graphs = read_store.listGraphNames(allocator) catch null;
            if (storage_graphs) |names| {
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
                var iter = cat.constraints.iterator();
                while (iter.next()) |entry| {
                    const info = entry.value_ptr.*;
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
            const labels = read_store.listNodeLabels(allocator, session_tenant) catch &.{};
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
        .users, .roles, .permissions, .version, .capabilities, .cluster_status => unreachable,
        // CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ShowGrantsRows; STATUS=TESTED; TEST=tests/test_gps_show_grants_for.zig; OWNER=security; UPDATED=2026-05-21
        .grants_for => {
            // Enumerate policies applicable to the requested username.
            // Phase 7 filter: include a policy if
            //   (a) its expression_source == "true" (universally applicable), OR
            //   (b) its expression_source contains the literal substring
            //       "current_user() = '<username>'" (text match; Phase 8 will
            //       evaluate compiled expressions properly).
            const policy_catalog_mod = @import("../security/policy_catalog.zig");
            const user_name = s.target orelse "";
            if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
                for (pol_cat.listPolicies()) |pol| {
                    const is_universal = std.mem.eql(u8, pol.expression_source, "true");
                    // Build the per-user substring we look for: current_user() = '<name>'
                    const user_expr = try std.fmt.allocPrint(allocator, "current_user() = '{s}'", .{user_name});
                    defer allocator.free(user_expr);
                    const is_user_specific = std.mem.indexOf(u8, pol.expression_source, user_expr) != null;

                    if (!is_universal and !is_user_specific) continue;

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
                    row[3] = Value{ .Str = try allocator.dupe(u8, @tagName(pol.effect)) };
                    row[4] = Value{ .Bool = pol.enabled };
                    try rows_list.append(allocator, row);
                }
            }
            // If catalog not yet initialized, return empty rows.
        },
        // GPS policy DDL (Phase 4, Task 4-4): enumerate in-memory PolicyCatalog.
        // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=ShowPoliciesExecution; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
        .policies => {
            const policy_catalog_mod = @import("../security/policy_catalog.zig");
            if (policy_catalog_mod.getGlobalCatalog()) |pol_cat| {
                for (pol_cat.listPolicies()) |pol| {
                    // Build "actions" column: comma-separated action names.
                    var actions_buf = std.ArrayList(u8).empty;
                    for (pol.actions, 0..) |a, ai| {
                        if (ai > 0) try actions_buf.appendSlice(allocator, ", ");
                        try actions_buf.appendSlice(allocator, @tagName(a));
                    }
                    const actions_str = try actions_buf.toOwnedSlice(allocator);

                    var row = try allocator.alloc(Value, 4);
                    row[0] = Value{ .Str = try allocator.dupe(u8, pol.name) };
                    row[1] = Value{ .Str = try allocator.dupe(u8, pol.scope_graph) };
                    row[2] = Value{ .Str = actions_str };
                    row[3] = Value{ .Bool = pol.enabled };
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
            if (self.entities) |acc_entities| {
                try acc_entities.nodes.ensureUnusedCapacity(acc_entities.allocator, entities.nodes.items.len);
                try acc_entities.edges.ensureUnusedCapacity(acc_entities.allocator, entities.edges.items.len);
                acc_entities.nodes.appendSliceAssumeCapacity(entities.nodes.items);
                acc_entities.edges.appendSliceAssumeCapacity(entities.edges.items);
                // Ownership of the pointers moved to the accumulator.
                entities.nodes.clearRetainingCapacity();
                entities.edges.clearRetainingCapacity();
                entities.deinit();
                entities.allocator.destroy(entities);
            } else {
                self.entities = entities;
            }
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
            entities.deinit();
            entities.allocator.destroy(entities);
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

    const loop_binding_count = 1 +
        (if (for_stmt.ordinality_var != null) @as(usize, 1) else 0) +
        (if (for_stmt.offset_var != null) @as(usize, 1) else 0);
    const binding_capacity = loop_binding_count + base_names.len + context.query_param_names.len;

    var param_names = try std.ArrayList([]const u8).initCapacity(allocator, binding_capacity);
    defer param_names.deinit(allocator);
    var param_values = try std.ArrayList(Value).initCapacity(allocator, binding_capacity);
    defer param_values.deinit(allocator);

    var acc = ForBodyAccumulator{};
    errdefer acc.deinit(allocator);

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
        try acc.absorb(allocator, &iter_result);
    }

    return acc.finish(allocator);
}

pub fn executeForWithBindings(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, with_result: ExecutionResult, context: ExecutionContext) !ExecutionResult {
    // We expect only one row from WITH clause, use it as the environment
    if (with_result.rows.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Create environment from WITH results, with the request params in scope so
    // a `$param` collection (FOR..IN parameter-bound list) resolves to the bound
    // value instead of Null.
    const env = Env{
        .names = with_result.columns,
        .values = with_result.rows[0], // Use first row
        .allocator = allocator,
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, env);

    // Extract list items from the collection
    var items = std.ArrayList(Value).empty;

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        .Null => {
            // A Null collection (e.g. an unbound/absent $param) yields ZERO
            // iterations — never one spurious null iteration.
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // geode#876: a composed body (CREATE / MERGE / MATCH ... SET) runs once per
    // element with the WITH bindings still in scope.
    if (for_stmt.body) |body| {
        return executeForBody(allocator, for_stmt, body, items.items, with_result.columns, with_result.rows[0], context);
    }

    const return_clause = for_stmt.return_clause orelse return error.InvalidForStatement;

    // Build result rows by iterating over collection
    var result_rows = std.ArrayList([]Value).empty;

    // Build arrays for iteration environment
    var env_names_list = std.ArrayList([]const u8).empty;
    var env_values_list = std.ArrayList(Value).empty;

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // First add WITH clause bindings
        for (with_result.columns, with_result.rows[0]) |name, value| {
            try env_names_list.append(allocator, name);
            try env_values_list.append(allocator, value);
        }

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration. The request params ride along
        // so a per-iteration RETURN item referencing `$param` resolves.
        const iteration_env = Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };

        // Evaluate RETURN items for this iteration
        var row = std.ArrayList(Value).empty;

        for (return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause
    var columns = std.ArrayList([]const u8).empty;

    for (return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            try allocator.dupe(u8, alias)
        else
            try allocator.dupe(u8, "?column?");
        try columns.append(allocator, col_name);
    }

    return ExecutionResult{
        .columns = try columns.toOwnedSlice(allocator),
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };
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
    // Evaluate the collection expression with the request params in scope so a
    // `$param` collection (FOR..IN parameter-bound list) resolves to the bound
    // value instead of Null.
    const empty_env = Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, empty_env);

    // Extract list items from the collection
    var items = std.ArrayList(Value).empty;

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        .Null => {
            // A Null collection (e.g. an unbound/absent $param) yields ZERO
            // iterations — never one spurious null iteration.
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // geode#876: `FOR x IN <list> <data-modifying statement>` — run the body
    // once per element instead of projecting a RETURN. An empty collection
    // therefore writes nothing (zero iterations).
    if (for_stmt.body) |body| {
        return executeForBody(allocator, for_stmt, body, items.items, &.{}, &.{}, context);
    }

    const return_clause = for_stmt.return_clause orelse return error.InvalidForStatement;

    // Build result rows by iterating over collection (pre-sized to collection length)
    var result_rows = try std.ArrayList([]Value).initCapacity(allocator, items.items.len);

    // Build arrays for iteration environment (pre-sized for variable + optionals)
    const env_capacity = 1 + (if (for_stmt.ordinality_var != null) @as(usize, 1) else 0) +
        (if (for_stmt.offset_var != null) @as(usize, 1) else 0);
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, env_capacity);
    var env_values_list = try std.ArrayList(Value).initCapacity(allocator, env_capacity);

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration. The request params ride along
        // so a per-iteration RETURN item referencing `$param` resolves; the loop
        // variable in `names` still shadows a same-named param (Env.get scans
        // `names` first).
        const iteration_env = Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };

        // Evaluate RETURN items for this iteration (pre-sized to return clause length)
        var row = try std.ArrayList(Value).initCapacity(allocator, return_clause.items.len);

        for (return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
    // First, collect column name strings (no allocation yet)
    var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, return_clause.items.len);
    defer col_name_strings.deinit(allocator);

    for (return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            alias
        else
            "?column?";
        try col_name_strings.append(allocator, col_name);
    }

    // Batch allocate all column strings in one buffer (reduces N allocations to 1)
    const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

    return ExecutionResult{
        .columns = col_result.columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .column_buffer = col_result.buffer,
    };
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

                    return ExecutionResult{
                        .columns = if (final_columns) |cols| @constCast(cols) else try allocator.alloc([]const u8, 0),
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = std.ArrayList([]const u8).empty,
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

// CANARY: REQ=REQ-AUTO-INDEX-EXPLAIN-002; FEATURE="AutoIdIndex"; ASPECT=WhereClauseIndexCheck; STATUS=IMPL; OWNER=engine; UPDATED=2026-02-07
/// Check if a WHERE expression contains an equality predicate on a given variable
/// that matches an indexed property in the catalog.
/// Extract variable name and property name from a property access expression.
/// Handles both PropertyAccess (object.property) and Member (Ident.field) forms.
fn extractVarProp(expr: ast.Expr) ?struct { variable: []const u8, property: []const u8 } {
    if (expr == .PropertyAccess) {
        const pa = expr.PropertyAccess;
        return .{ .variable = pa.object, .property = pa.property };
    }
    if (expr == .Member) {
        const m = expr.Member;
        if (m.target.* == .Ident) {
            return .{ .variable = m.target.Ident.orig, .property = m.field };
        }
    }
    return null;
}

fn whereHasIndexedEquality(where_expr: ast.Expr, var_name: []const u8, label: []const u8, cat: anytype) bool {
    switch (where_expr) {
        .Binary => |bin| {
            if (bin.op == .And) {
                if (whereHasIndexedEquality(bin.left.*, var_name, label, cat)) return true;
                if (whereHasIndexedEquality(bin.right.*, var_name, label, cat)) return true;
                return false;
            } else if (bin.op == .Eq) {
                // Check: PropertyAccess or Member = Literal (or reversed)
                const prop_name = blk: {
                    if (extractVarProp(bin.left.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    if (extractVarProp(bin.right.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    break :blk @as(?[]const u8, null);
                };
                if (prop_name) |pn| {
                    var idx_iter = cat.indexes.valueIterator();
                    while (idx_iter.next()) |index_info| {
                        if (std.mem.eql(u8, index_info.table_name, label) and
                            index_info.columns.len > 0 and
                            std.mem.eql(u8, index_info.columns[0], pn))
                        {
                            return true;
                        }
                    }
                }
                return false;
            }
            return false;
        },
        else => return false,
    }
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

    // Track cumulative cost
    var total_cost: i64 = 0;

    // Analyze the query and build plan with cost estimates
    const query_stmt = exp.query.*;
    switch (query_stmt) {
        .Query => |q| {
            if (q.match.chains.len > 0) {
                const chain = q.match.chains[0];
                if (chain.head) |head| {
                    // Check if we can use an IndexSeek
                    var use_index_seek = false;

                    // Check if node pattern has label and properties that match an index
                    if (head.labels.len > 0 and head.props != null and head.props.?.len > 0) {
                        const label = head.labels[0];
                        const prop_name = head.props.?[0].key;

                        // Check catalog for matching index
                        // M2: Get catalog from context via dependency injection
                        const cat = getCatalog(allocator, context);
                        // Phase 3: Shared lock for EXPLAIN (read-only, allows concurrent query planning)
                        cat.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                        defer cat.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

                        var index_iter = cat.indexes.valueIterator();
                        while (index_iter.next()) |index_info| {
                            // Check if index matches this label and property
                            if (std.mem.eql(u8, index_info.table_name, label) and
                                index_info.columns.len > 0 and
                                std.mem.eql(u8, index_info.columns[0], prop_name))
                            {
                                use_index_seek = true;
                                break;
                            }
                        }
                    }

                    // CANARY: REQ=REQ-AUTO-INDEX-EXPLAIN-001; FEATURE="AutoIdIndex"; ASPECT=ExplainWhereClause; STATUS=IMPL; OWNER=engine; UPDATED=2026-02-07
                    // Also check WHERE clause for equality on indexed properties
                    if (!use_index_seek and head.labels.len > 0) {
                        if (q.where_clause) |where_expr| {
                            if (head.name) |vn| {
                                const cat_w = getCatalog(allocator, context);
                                cat_w.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                                defer cat_w.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

                                use_index_seek = whereHasIndexedEquality(where_expr, vn, head.labels[0], cat_w);
                            }
                        }
                    }

                    if (use_index_seek) {
                        // IndexSeek cost: 10 (much cheaper than NodeScan)
                        const index_cost: i64 = 10;
                        total_cost += index_cost;
                        try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "IndexSeek (cost: {})", .{index_cost}), .cost = index_cost });
                    } else {
                        // NodeScan base cost: 100 per node
                        const node_cost: i64 = 100;
                        total_cost += node_cost;
                        try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "NodeScan (cost: {})", .{node_cost}), .cost = node_cost });
                    }
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

    // Create result with plan column
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "plan");

    // Create rows with operation descriptions and add total cost at the end
    const rows = try allocator.alloc([]Value, plan_steps.items.len + 2);

    // Add header row
    const header_row = try allocator.alloc(Value, 1);
    header_row[0] = Value{ .Str = try allocator.dupe(u8, "EXPLAIN") };
    rows[0] = header_row;

    // Add operation rows
    for (plan_steps.items, 0..) |step, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = try formatPlanOp(allocator, "  {s}", .{step.op}) };
        rows[i + 1] = row;
    }

    // Add total cost row
    const total_row = try allocator.alloc(Value, 1);
    total_row[0] = Value{ .Str = try formatPlanOp(allocator, "Total cost: {}", .{total_cost}) };
    rows[plan_steps.items.len + 1] = total_row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
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

    // Return profiling statistics
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "metric");
    columns[1] = try allocator.dupe(u8, "value");

    // Create statistics rows
    var stats = std.ArrayList([]Value).empty;
    defer stats.deinit(allocator);

    // Profile type indicator
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "profile") };
        row[1] = Value{ .Str = try allocator.dupe(u8, "query_profile") };
        try stats.append(allocator, row);
    }

    // Row count
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "rows") };
        row[1] = Value{ .Int = @intCast(query_result.rows.len) };
        try stats.append(allocator, row);
    }

    // Column count
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "columns") };
        row[1] = Value{ .Int = @intCast(query_result.columns.len) };
        try stats.append(allocator, row);
    }

    // Execution time: real wall-clock milliseconds measured around the
    // wrapped statement (GAP-0868; replaces the old `time = 1` placeholder).
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "time_ms") };
        row[1] = Value{ .Int = @intCast(profile_elapsed_ns / std.time.ns_per_ms) };
        try stats.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try stats.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        // GAP-0535: every row value above is a fresh dupe (metric-name
        // strings) or a scalar — the result fully owns its value memory, so
        // deinit is leak-free under a strict allocator (this was the leak
        // the GAP-0868 test originally had to hide behind an arena).
        .owns_value_memory = true,
    };
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ExecutorFunction; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
// EXPLAIN POLICY FOR <inner_query>
//
// Classifies the top-level action of the inner parsed statement, builds a
// DecisionRequest with the current principal, calls gps.decide() once, and
// returns a single result row with columns:
//
//   step | action | resource | decision | reason_code
//
// For Phase 7 only the top-level classification is performed (one row).
// Multi-step decomposition (e.g. MATCH + CREATE in a single query) is Phase 8+.
//
// When the execution context carries no Principal, an unauthenticated decision
// is returned (reason_code = "no_principal") — GPS's standard behaviour.
pub fn executeExplainPolicy(allocator: std.mem.Allocator, ep: ast.ExplainPolicyStatement, context: ExecutionContext) anyerror!ExecutionResult {
    const gps = @import("../security/gps.zig");
    const principal_mod = @import("../security/principal.zig");

    // --- Step 1: classify the inner statement's top-level action ---------------
    const action: gps.Action = classifyAction(ep.inner.*);

    // --- Step 2: build a DecisionRequest --------------------------------------
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

    const resource = gps.ResourceRef{ .database = {} };
    const req = gps.DecisionRequest{
        .principal = principal,
        .action = action,
        .resource = resource,
    };

    // --- Step 3: call gps.decide() -------------------------------------------
    const decision = try gps.decide(allocator, &req);

    // --- Step 4: emit result row ----------------------------------------------
    // Columns: step, action, resource, decision, reason_code
    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "step");
    columns[1] = try allocator.dupe(u8, "action");
    columns[2] = try allocator.dupe(u8, "resource");
    columns[3] = try allocator.dupe(u8, "decision");
    columns[4] = try allocator.dupe(u8, "reason_code");

    const row = try allocator.alloc(Value, 5);
    row[0] = Value{ .Int = 1 }; // step 1 (top-level classification only in Phase 7)
    row[1] = Value{ .Str = try allocator.dupe(u8, @tagName(action)) };
    row[2] = Value{ .Str = try allocator.dupe(u8, "database") };
    row[3] = Value{ .Str = try allocator.dupe(u8, @tagName(decision.kind)) };
    row[4] = Value{ .Str = try allocator.dupe(u8, decision.reason_code) };

    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

/// Map an AST Statement to the GPS Action it primarily requires.
/// Phase 7: top-level classification only.  Phase 8+ can decompose sub-statements.
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
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "plan");

    const rows = try allocator.alloc([]Value, plan.ops.len);
    errdefer allocator.free(rows);

    for (plan.ops, 0..) |op, idx| {
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = try allocator.dupe(u8, plannedOpName(op.kind)) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // GAP-0535: all row values are fresh dupes — fully owned.
        .owns_value_memory = true,
    };
}

fn buildPlannedProfileResult(allocator: std.mem.Allocator, planned: planned_read_runtime.ProfiledExecution) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "metric");
    columns[1] = try allocator.dupe(u8, "value");

    const rows = try allocator.alloc([]Value, 5);
    errdefer allocator.free(rows);

    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Str = try allocator.dupe(u8, "profile") };
    rows[0][1] = Value{ .Str = try allocator.dupe(u8, "planned_query_profile") };

    rows[1] = try allocator.alloc(Value, 2);
    rows[1][0] = Value{ .Str = try allocator.dupe(u8, "rows") };
    rows[1][1] = Value{ .Int = @intCast(planned.result.rows.len) };

    rows[2] = try allocator.alloc(Value, 2);
    rows[2][0] = Value{ .Str = try allocator.dupe(u8, "columns") };
    rows[2][1] = Value{ .Int = @intCast(planned.result.columns.len) };

    rows[3] = try allocator.alloc(Value, 2);
    rows[3][0] = Value{ .Str = try allocator.dupe(u8, "time_ns") };
    rows[3][1] = Value{ .Int = @intCast(planned.trace.totalTimeNs()) };

    rows[4] = try allocator.alloc(Value, 2);
    rows[4][0] = Value{ .Str = try allocator.dupe(u8, "operators") };
    rows[4][1] = Value{ .Int = @intCast(planned.trace.ops.len) };

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // GAP-0535: all row values are fresh dupes or scalars — fully owned.
        .owns_value_memory = true,
    };
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
    store.clearNodes();

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
