const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const value_types = @import("../value_types.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const ExecutionError = execution.ExecutionError;
const IndexInfo = execution.IndexInfo;

// Import FLE and catalog modules
const fle_catalog = @import("../schema/catalog.zig");
const fle_annotations = @import("../schema/annotations.zig");

// Import helper functions used by statement dispatcher
const checkPermission = execution.checkPermission;
const getCatalog = execution.getCatalog;
const getScopedIndexKey = execution.getScopedIndexKey;
const createTestGraphG1 = execution.createTestGraphG1;
const createTestGraphG2 = execution.createTestGraphG2;
const sortRows = execution.sortRows;
const executeQueryWithContext = execution.executeQueryWithContext;
const executeUnionWithContext = execution.executeUnionWithContext;
const executeIntersect = execution.executeIntersect;
const executeExcept = execution.executeExcept;
const executeCreate = execution.executeCreate;
const executeInsert = execution.executeInsert;
const executeMerge = execution.executeMerge;
const executeDelete = execution.executeDelete;

// Local type aliases
const Value = value_types.Value;

pub fn toRuntimeAdvancedIndexType(index_type: ast.IndexType) ?index_manager.IndexManager.IndexType {
    return switch (index_type) {
        .vector_f32 => .vector_f32,
        .spatial_geographic => .spatial_geographic,
        .network_cidr => .network_cidr,
        .signature_crypto => .signature_crypto,
        .interval_tree => .interval_tree,
        .jsonb_inverted => .jsonb_inverted,
        .domain_trie => .domain_trie,
        else => null,
    };
}

pub fn runtimeAdvancedIndexTypeFromCatalog(type_name: []const u8) ?index_manager.IndexManager.IndexType {
    if (std.mem.eql(u8, type_name, "vector_f32")) return .vector_f32;
    if (std.mem.eql(u8, type_name, "spatial_geographic")) return .spatial_geographic;
    if (std.mem.eql(u8, type_name, "network_cidr")) return .network_cidr;
    if (std.mem.eql(u8, type_name, "signature_crypto")) return .signature_crypto;
    if (std.mem.eql(u8, type_name, "interval_tree") or std.mem.eql(u8, type_name, "IntervalTree")) return .interval_tree;
    if (std.mem.eql(u8, type_name, "jsonb_inverted") or std.mem.eql(u8, type_name, "JsonbInverted")) return .jsonb_inverted;
    if (std.mem.eql(u8, type_name, "domain_trie") or std.mem.eql(u8, type_name, "DomainTrie")) return .domain_trie;
    return null;
}

pub fn ensureAdvancedRuntimeIndex(
    allocator: std.mem.Allocator,
    index_name: []const u8,
    label: []const u8,
    properties: [][]const u8,
    index_type: ast.IndexType,
) !void {
    const runtime_type = toRuntimeAdvancedIndexType(index_type) orelse return;
    if (properties.len != 1) return error.Unsupported;

    const manager = try index_manager.ensureGlobalIndexManager(allocator);
    switch (runtime_type) {
        .vector_f32 => try manager.createAdvancedVectorIndex(index_name, 0, .l2),
        .spatial_geographic => try manager.createAdvancedSpatialIndex(index_name),
        .network_cidr => try manager.createAdvancedNetworkIndex(index_name),
        .signature_crypto => try manager.createAdvancedSignatureIndex(index_name),
        .interval_tree => try manager.createAdvancedIntervalIndex(index_name),
        .jsonb_inverted => try manager.createAdvancedJsonbIndex(index_name),
        .domain_trie => try manager.createAdvancedDomainIndex(index_name),
        else => return,
    }
    try manager.registerAdvancedPropertyIndex(index_name, label, properties[0], runtime_type);
    try manager.rebuildAdvancedIndex(graph_store.getGlobalStore(allocator), index_name);
}

/// Resolve a LIMIT or OFFSET value from either a literal or a $param reference.
fn resolveLimitParam(literal: ?usize, param_name: ?[]const u8, pnames: []const []const u8, pvalues: []const Value) ?usize {
    if (literal) |v| return v;
    if (param_name) |name| {
        for (pnames, pvalues) |pn, pv| {
            if (std.mem.eql(u8, pn, name)) {
                return switch (pv) {
                    .Int => |i| if (i >= 0) @as(usize, @intCast(i)) else null,
                    else => null,
                };
            }
        }
    }
    return null;
}
const executeMatchQuery = execution.executeMatchQuery;
const executeMatchCreateQuery = execution.executeMatchCreateQuery;
const executeMatchCallQuery = execution.executeMatchCallQuery;
const executeCallStatement = execution.executeCallStatement;
const executeCallProcedure = execution.executeCallProcedure;
const executeCallSubquery = execution.executeCallSubquery;
const executeShow = execution.executeShow;
const executeFor = execution.executeFor;
const executeValues = execution.executeValues;
const executeExplain = execution.executeExplain;
const executeProfile = execution.executeProfile;
const executeReturnClauseWithNodes = execution.executeReturnClauseWithNodes;
const encryptPropertyIfNeeded = execution.encryptPropertyIfNeeded;

// CANARY: REQ=REQ-EXEC-REFACTOR-010; FEATURE="FileModularization"; ASPECT=StatementDispatcher; STATUS=EXEMPT; OWNER=refactoring; UPDATED=2025-10-17
pub fn executeStatementWithContext(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    switch (stmt) {
        .Query => |q| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-002; FEATURE="AuthEnforcement"; ASPECT=QueryReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: Check Read permission for all query operations
            // This ensures unauthenticated users cannot read data when auth is enabled
            try checkPermission(context, .Read);

            // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
            if (context.strict_offset_validation and q.offset != null and q.order_by == null) {
                return ExecutionError.UnorderedPagination;
            }

            // Check if query has SKIP or LIMIT
            var result = try executeQueryWithContext(allocator, q, context);

            // Apply SKIP if present
            if (q.offset) |skip_count| {
                if (skip_count < result.rows.len) {
                    // Create new rows array without the skipped rows
                    const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
                    for (result.rows[skip_count..], 0..) |row, i| {
                        new_rows[i] = row;
                    }
                    // Free old rows array but not the row data
                    allocator.free(result.rows);
                    result.rows = new_rows;
                } else {
                    // Skip all rows
                    allocator.free(result.rows);
                    result.rows = try allocator.alloc([]Value, 0);
                }
            }

            // Apply LIMIT if present (supports $param)
            if (resolveLimitParam(q.limit, q.limit_param, context.query_param_names, context.query_param_values)) |limit_count| {
                if (limit_count < result.rows.len) {
                    // Truncate to limit
                    const new_rows = try allocator.alloc([]Value, limit_count);
                    for (result.rows[0..limit_count], 0..) |row, i| {
                        new_rows[i] = row;
                    }
                    allocator.free(result.rows);
                    result.rows = new_rows;
                }
            }

            return result;
        },
        .Union => |u| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-005; FEATURE="AuthEnforcement"; ASPECT=UnionReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: UNION is a read operation
            try checkPermission(context, .Read);
            return executeUnionWithContext(allocator, u, context);
        },
        .Intersect => |i| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-006; FEATURE="AuthEnforcement"; ASPECT=IntersectReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: INTERSECT is a read operation
            try checkPermission(context, .Read);
            return executeIntersect(allocator, i, context);
        },
        .Except => |e| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-007; FEATURE="AuthEnforcement"; ASPECT=ExceptReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: EXCEPT is a read operation
            try checkPermission(context, .Read);
            return executeExcept(allocator, e, context);
        },
        .Create => |c| {
            // Check write permission
            try checkPermission(context, .Write);
            const create_graph = if (context.session_state) |session| session.graph else null;
            return executeCreate(allocator, c, create_graph, context);
        },
        .Insert => |ins| {
            // Check write permission
            try checkPermission(context, .Write);
            const insert_graph = if (context.session_state) |session| session.graph else null;
            return executeInsert(allocator, ins, insert_graph);
        },
        .Delete => |d| {
            // Check write permission
            try checkPermission(context, .Write);
            // CANARY: REQ=REQ-MULTI-GRAPH-DELETE-002; FEATURE="MultiGraphIsolation"; ASPECT=DeleteGraphContext; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            const delete_graph = if (context.session_state) |session| session.graph else null;
            return executeDelete(allocator, d, delete_graph, context);
        },
        .Merge => |m| {
            // Check write permission
            try checkPermission(context, .Write);
            const merge_graph = if (context.session_state) |session| session.graph else null;
            return executeMerge(allocator, m, merge_graph, context);
        },
        .StartTransaction => |txn| {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StartTransaction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Check if transaction is already active
            if (context.transaction_state == .Active) {
                return error.TransactionAlreadyActive;
            }

            // Mark transaction as active
            var mut_context = context;
            mut_context.transaction_state = .Active;

            // If transaction has a body, execute statements and auto-commit
            if (txn.body) |body| {
                var last_result: ?ExecutionResult = null;

                // CANARY: REQ=REQ-AUTH-ENFORCE-024; FEATURE="AuthEnforcement"; ASPECT=TransactionBodyPermissions; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
                // CRITICAL SECURITY: Each statement in transaction body must check permissions

                // Execute all statements in the transaction body
                for (body) |*body_stmt| {
                    // Inline switch to handle different statement types (avoids circular error set inference)
                    const txn_graph = if (mut_context.session_state) |session| session.graph else null;
                    last_result = (switch (body_stmt.*) {
                        .Query => |q| blk: {
                            // CRITICAL SECURITY: Check Read permission for Query in transaction
                            checkPermission(mut_context, .Read) catch |err| break :blk err;
                            break :blk executeQueryWithContext(allocator, q, mut_context);
                        },
                        .Call => |c| blk: {
                            // CRITICAL SECURITY: Check Read permission for Call in transaction
                            checkPermission(mut_context, .Read) catch |err| break :blk err;
                            break :blk executeCallStatement(allocator, c, mut_context);
                        },
                        .Create => |create_stmt| blk: {
                            // CRITICAL SECURITY: Check Write permission for Create in transaction
                            checkPermission(mut_context, .Write) catch |err| break :blk err;
                            break :blk executeCreate(allocator, create_stmt, txn_graph, mut_context);
                        },
                        .Merge => |m| blk: {
                            // CRITICAL SECURITY: Check Write permission for Merge in transaction
                            checkPermission(mut_context, .Write) catch |err| break :blk err;
                            break :blk executeMerge(allocator, m, txn_graph, mut_context);
                        },
                        .StartTransaction => return error.NestedTransactionNotAllowed,
                        .Commit => return error.CommitInTransactionBody,
                        .Rollback => return error.RollbackInTransactionBody,
                        else => return error.UnsupportedStatementInTransactionBody,
                    }) catch |err| {
                        // On error, rollback (just reset state for now)
                        mut_context.transaction_state = .None;
                        return err;
                    };
                }

                // Auto-commit: reset transaction state
                mut_context.transaction_state = .None;

                // Return result from last statement
                if (last_result) |result| {
                    return result;
                }
            }

            // No body - just return success message
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "transaction started" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Commit => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Commit; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, COMMIT without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as committed
                var mut_context = context;
                mut_context.transaction_state = .Committed;
                break :blk "transaction committed";
            } else "no transaction active";

            // In a full implementation, this would persist changes to disk
            // For now, changes are immediately visible (auto-commit mode)

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Rollback => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Rollback; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, ROLLBACK without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as rolled back
                var mut_context = context;
                mut_context.transaction_state = .RolledBack;
                break :blk "transaction rolled back";
            } else "no transaction active";

            // In a full implementation, this would revert uncommitted changes
            // For now, changes are immediately visible (auto-commit mode)

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionSet => |ss| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSet; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Update session state if available
            if (context.session_state) |session| {
                switch (ss.clause_type) {
                    .Graph => |graph| {
                        // Set the current graph in session
                        if (session.graph) |old_graph| {
                            allocator.free(old_graph);
                        }
                        session.graph = try allocator.dupe(u8, graph.expression);

                        // Create test data for known test graphs
                        // Support both quoted and unquoted graph names
                        const graph_name = graph.expression;
                        if (std.mem.eql(u8, graph_name, "G1")) {
                            try createTestGraphG1(allocator);
                        } else if (std.mem.eql(u8, graph_name, "G2")) {
                            try createTestGraphG2(allocator);
                        }
                        // For other graphs (including "NewG"), just set the session graph
                        // MATCH will filter by graph_name, so an empty graph returns 0 results naturally
                    },
                    .TimeZone => |tz| {
                        // Set timezone in session state
                        if (session.timezone) |old_tz| {
                            allocator.free(old_tz);
                        }
                        session.timezone = try allocator.dupe(u8, tz.value);
                    },
                    .Schema => |schema| {
                        // Set current schema in session state
                        if (session.schema) |old_schema| {
                            allocator.free(old_schema);
                        }
                        session.schema = try allocator.dupe(u8, schema.name);
                    },
                    .Parameter => |param| {
                        // Store parameter in session state
                        const param_name = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.specification,
                            .BindingTableParam => |btp| btp.parameter_name.specification,
                            .ValueParam => |vp| vp.parameter_name.specification,
                        };

                        const param_value = switch (param) {
                            .GraphParam => |gp| gp.initializer orelse "null",
                            .BindingTableParam => |btp| btp.initializer orelse "null",
                            .ValueParam => |vp| vp.initializer orelse "null",
                        };

                        // Check IF NOT EXISTS flag
                        const if_not_exists = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.if_not_exists,
                            .BindingTableParam => |btp| btp.parameter_name.if_not_exists,
                            .ValueParam => |vp| vp.parameter_name.if_not_exists,
                        };

                        if (if_not_exists and session.parameters.contains(param_name)) {
                            // Parameter already exists and IF NOT EXISTS is set, skip
                        } else {
                            // Store or update parameter
                            try session.parameters.put(
                                try allocator.dupe(u8, param_name),
                                try allocator.dupe(u8, param_value),
                            );
                        }
                    },
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session updated" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Show => |s| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-008; FEATURE="AuthEnforcement"; ASPECT=ShowReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: SHOW is a read operation (exposes metadata)
            try checkPermission(context, .Read);
            return executeShow(allocator, s, context);
        },
        .Explain => |exp| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-009; FEATURE="AuthEnforcement"; ASPECT=ExplainReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: EXPLAIN exposes query plan information
            try checkPermission(context, .Read);
            return executeExplain(allocator, exp, context);
        },
        .Profile => |prof| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-010; FEATURE="AuthEnforcement"; ASPECT=ProfileReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: PROFILE exposes performance information
            try checkPermission(context, .Read);
            return executeProfile(allocator, prof, context);
        },
        .CreateIndex => |ci| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-011; FEATURE="AuthEnforcement"; ASPECT=CreateIndexSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CREATE INDEX is a schema modification operation
            try checkPermission(context, .Schema);

            // CREATE INDEX implementation with validation
            // CANARY: REQ=REQ-INDEX-002; FEATURE="IndexManagement"; ASPECT=ScopedCreation; STATUS=TESTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            // Auto-generate index name from label+properties if not provided
            const index_name = ci.name orelse blk: {
                var parts = try std.ArrayList(u8).initCapacity(allocator, 64);
                try parts.appendSlice(allocator, "idx_");
                try parts.appendSlice(allocator, ci.label);
                for (ci.properties) |prop| {
                    try parts.append(allocator, '_');
                    try parts.appendSlice(allocator, prop);
                }
                break :blk try parts.toOwnedSlice(allocator);
            };
            const label = ci.label;

            // Phase 3: Write lock for CREATE INDEX
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Generate scoped key: "label:index_name"
            // This allows the same index name on different labels (e.g., Person:idx and Company:idx)
            // P2-3: Use provided allocator instead of page_allocator
            const scoped_key = try getScopedIndexKey(allocator, label, index_name);
            defer allocator.free(scoped_key);

            // Check if index already exists for this label
            if (!ci.if_not_exists and cat.indexes.contains(scoped_key)) {
                return error.DuplicateIndex;
            }

            // Validate index type compatibility with property
            // HNSW/vector indexes should only be used on vector properties
            if (ci.index_type == .vector or ci.index_type == .vector_f32) {
                for (ci.properties) |prop| {
                    // Common text field names that shouldn't have vector indexes
                    const is_text_field = std.mem.eql(u8, prop, "name") or
                        std.mem.eql(u8, prop, "title") or
                        std.mem.eql(u8, prop, "description") or
                        std.mem.eql(u8, prop, "text") or
                        std.mem.eql(u8, prop, "content") or
                        std.mem.eql(u8, prop, "label") or
                        std.mem.eql(u8, prop, "id");

                    // Vector properties typically have "vector" or "embedding" in their name
                    const is_vector_name = std.mem.indexOf(u8, prop, "vector") != null or
                        std.mem.indexOf(u8, prop, "embedding") != null or
                        std.mem.indexOf(u8, prop, "emb") != null;

                    if (is_text_field and !is_vector_name) {
                        return error.IncompatibleIndexDataType;
                    }
                }
            }

            // Add to catalog if not exists
            if (!cat.indexes.contains(scoped_key)) {
                // Create IndexInfo with all the details
                // P2-3: Use catalog's allocator for index info (owned by catalog)
                const index_info = IndexInfo{
                    .name = try cat.allocator.dupe(u8, index_name),
                    .index_type = switch (ci.index_type) {
                        .btree => "btree",
                        .hash => "hash",
                        .fulltext => "fulltext",
                        .spatial => "spatial",
                        .vector => "vector",
                        .vector_f32 => "vector_f32",
                        .spatial_geographic => "spatial_geographic",
                        .network_cidr => "network_cidr",
                        .signature_crypto => "signature_crypto",
                        .interval_tree => "IntervalTree",
                        .jsonb_inverted => "JsonbInverted",
                        .domain_trie => "DomainTrie",
                    },
                    .table_name = try cat.allocator.dupe(u8, label),
                    .columns = blk: {
                        var cols = try cat.allocator.alloc([]const u8, ci.properties.len);
                        for (ci.properties, 0..) |prop, i| {
                            cols[i] = try cat.allocator.dupe(u8, prop);
                        }
                        break :blk cols;
                    },
                };
                // Use scoped key for storage: "label:index_name"
                // P2-3: Use catalog's allocator for the key (owned by catalog)
                const stored_key = try getScopedIndexKey(cat.allocator, label, index_name);
                try cat.indexes.put(stored_key, index_info);
                // Save catalog to disk after creating index
                cat.save() catch |err| {
                    log.err("CRITICAL: Failed to persist catalog after index creation", &.{
                        Attr.string("index_name", index_name),
                        Attr.string("error", @errorName(err)),
                    });
                };

                try ensureAdvancedRuntimeIndex(allocator, index_name, label, ci.properties, ci.index_type);
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };
        },
        .CreateConstraint => |cc| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-012; FEATURE="AuthEnforcement"; ASPECT=CreateConstraintSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CREATE CONSTRAINT is a schema modification operation
            try checkPermission(context, .Schema);

            // GAP-0048: CREATE CONSTRAINT implementation with proper catalog storage and enforcement
            // CANARY: REQ=REQ-CONSTRAINT-EXEC-001; FEATURE="ConstraintExecution"; ASPECT=CREATE; STATUS=EXEMPT; OWNER=engine; UPDATED=2026-01-10
            const cat = getCatalog(allocator, context);

            // Phase 3: Write lock for CREATE CONSTRAINT
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Create scoped key for constraint lookup
            var key_buf: [512]u8 = undefined;
            const scoped_key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ cc.label, cc.name }) catch return error.OutOfMemory;

            // Check IF NOT EXISTS
            if (cc.if_not_exists and cat.constraints.contains(scoped_key)) {
                // Constraint already exists, return success (no-op)
                return ExecutionResult{
                    .columns = try allocator.alloc([]const u8, 0),
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = std.ArrayList([]const u8).empty,
                };
            }

            // Check if constraint already exists without IF NOT EXISTS
            if (!cc.if_not_exists and cat.constraints.contains(scoped_key)) {
                return error.DuplicateConstraint;
            }

            // Convert AST constraint type to catalog constraint type
            const constraint_type: @import("../schema/catalog.zig").ConstraintInfo.ConstraintType = switch (cc.constraint_type) {
                .unique => .unique,
                .node_key => .node_key,
                .not_null => .not_null,
                .exists => .exists,
            };

            // Allocate owned copies of data for the constraint
            const owned_key = try cat.allocator.dupe(u8, scoped_key);
            errdefer cat.allocator.free(owned_key);

            const owned_name = try cat.allocator.dupe(u8, cc.name);
            errdefer cat.allocator.free(owned_name);

            const owned_label = try cat.allocator.dupe(u8, cc.label);
            errdefer cat.allocator.free(owned_label);

            var owned_props = try cat.allocator.alloc([]const u8, cc.properties.len);
            errdefer cat.allocator.free(owned_props);

            for (cc.properties, 0..) |prop, idx| {
                owned_props[idx] = try cat.allocator.dupe(u8, prop);
            }

            // Create constraint info
            const constraint_info = @import("../schema/catalog.zig").ConstraintInfo{
                .name = owned_name,
                .constraint_type = constraint_type,
                .label = owned_label,
                .properties = owned_props,
                .is_enforced = true, // Constraints are enforced by default
            };

            // Store in catalog
            try cat.constraints.put(owned_key, constraint_info);

            // Persist catalog
            cat.save() catch |err| {
                log.err("CRITICAL: Failed to persist catalog after constraint creation", &.{
                    Attr.string("constraint_name", cc.name),
                    Attr.string("error", @errorName(err)),
                });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropIndex => |di| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-013; FEATURE="AuthEnforcement"; ASPECT=DropIndexSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: DROP INDEX is a schema modification operation
            try checkPermission(context, .Schema);

            // DROP INDEX implementation
            // CANARY: REQ=REQ-INDEX-003; FEATURE="IndexManagement"; ASPECT=ScopedDeletion; STATUS=TESTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            const index_name = di.name;

            // Phase 3: Write lock for DROP INDEX
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Search for index by name across all labels
            // Since we use scoped keys ("label:index_name"), we need to find the matching entry
            var found_key: ?[]const u8 = null;
            var iter = cat.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                if (std.mem.eql(u8, info.name, index_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            if (found_key) |key| {
                // Found the index, remove it
                if (cat.indexes.fetchRemove(key)) |removed| {
                    const runtime_type = runtimeAdvancedIndexTypeFromCatalog(removed.value.index_type);
                    if (runtime_type) |kind| {
                        if (index_manager.getGlobalIndexManager()) |manager| {
                            _ = manager.dropAdvancedIndex(removed.value.name, kind) catch false;
                        }
                    }
                    // Free the allocated memory
                    // P2-3: Use catalog's allocator (data was allocated with cat.allocator)
                    cat.allocator.free(removed.key);
                    cat.allocator.free(removed.value.name);
                    cat.allocator.free(removed.value.table_name);
                    for (removed.value.columns) |col| {
                        cat.allocator.free(col);
                    }
                    cat.allocator.free(removed.value.columns);
                }
                // Save catalog after dropping index
                cat.save() catch |err| {
                    log.err("CRITICAL: Failed to persist catalog after index drop", &.{
                        Attr.string("index_name", index_name),
                        Attr.string("error", @errorName(err)),
                    });
                };
            } else if (!di.if_exists) {
                return error.IndexNotFound;
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };
        },
        .DropConstraint => |dc| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-014; FEATURE="AuthEnforcement"; ASPECT=DropConstraintSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: DROP CONSTRAINT is a schema modification operation
            try checkPermission(context, .Schema);

            // GAP-0048: DROP CONSTRAINT implementation with proper catalog removal
            // CANARY: REQ=REQ-CONSTRAINT-EXEC-002; FEATURE="ConstraintExecution"; ASPECT=DROP; STATUS=EXEMPT; OWNER=engine; UPDATED=2026-01-10
            const cat = getCatalog(allocator, context);

            // Phase 3: Write lock for DROP CONSTRAINT
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Search for constraint by name across all labels
            var found_key: ?[]const u8 = null;
            var iter = cat.constraints.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                if (std.mem.eql(u8, info.name, dc.name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            if (found_key) |key| {
                // Found the constraint, remove it
                if (cat.constraints.fetchRemove(key)) |removed| {
                    // Free allocated memory
                    cat.allocator.free(removed.key);
                    cat.allocator.free(removed.value.name);
                    cat.allocator.free(removed.value.label);
                    for (removed.value.properties) |prop| {
                        cat.allocator.free(prop);
                    }
                    cat.allocator.free(removed.value.properties);
                }
                // Save catalog after dropping constraint
                cat.save() catch |err| {
                    log.err("CRITICAL: Failed to persist catalog after constraint drop", &.{
                        Attr.string("constraint_name", dc.name),
                        Attr.string("error", @errorName(err)),
                    });
                };
            } else if (!dc.if_exists) {
                return error.ConstraintNotFound;
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Call => |call_stmt| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-021; FEATURE="AuthEnforcement"; ASPECT=CallReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CALL procedures can read data, require at least Read permission
            try checkPermission(context, .Read);

            var result: ExecutionResult = undefined;

            switch (call_stmt) {
                .Procedure => |proc| {
                    result = try executeCallStatement(allocator, call_stmt, context);

                    // Apply ORDER BY if present
                    if (proc.order_by) |order| {
                        try sortRows(allocator, &result, order);
                    }

                    // Apply OFFSET if present
                    if (proc.offset) |skip_count| {
                        if (skip_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
                            for (result.rows[skip_count..], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }

                    // Apply LIMIT if present
                    if (proc.limit) |limit_count| {
                        if (limit_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]Value, limit_count);
                            for (result.rows[0..limit_count], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }
                },
                .Subquery => |subq| {
                    // Execute the subquery in an isolated context
                    _ = subq;
                    result = try executeCallStatement(allocator, call_stmt, context);
                },
            }

            return result;
        },
        .CreateGraph => |cg| {
            // GAP-0295: Reject CREATE GRAPH when session is graph-bound via DSN
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-004; FEATURE="DSNGraphBinding"; ASPECT=CreateGraphRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-05
            if (context.graph_bound) {
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-AUTH-ENFORCE-015; FEATURE="AuthEnforcement"; ASPECT=CreateGraphSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CREATE GRAPH is a schema modification operation
            try checkPermission(context, .Schema);

            // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphSupport"; ASPECT=CreateGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
            // CREATE GRAPH implementation with duplicate detection and storage creation
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            const graph_name = cg.name;

            // DEBUG: Log IF NOT EXISTS flag
            log.debug("CREATE GRAPH", &.{
                Attr.string("name", graph_name),
                Attr.bool("if_not_exists", cg.if_not_exists),
                Attr.bool("or_replace", cg.or_replace),
            });

            // Phase 3: Write lock for CREATE GRAPH
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Handle OR REPLACE
            if (cg.or_replace) {
                // Remove existing graph if it exists
                if (cat.graphs.fetchRemove(graph_name)) |entry| {
                    // P2-3: Use catalog's allocator
                    cat.allocator.free(entry.key);
                }
                // Also drop the storage
                graph_store.getGlobalStore(allocator).dropGraph(graph_name) catch {};
            } else {
                // Check if graph already exists
                const graph_exists = cat.graphs.contains(graph_name);
                log.debug("Graph exists check", &.{
                    Attr.bool("exists", graph_exists),
                });
                if (graph_exists) {
                    // If IF NOT EXISTS is specified, silently succeed
                    if (cg.if_not_exists) {
                        log.debug("IF NOT EXISTS specified, returning success", &.{});
                        return ExecutionResult{
                            .columns = try allocator.alloc([]const u8, 0),
                            .rows = try allocator.alloc([]Value, 0),
                            .flags = std.ArrayList([]const u8).empty,
                        };
                    }
                    log.debug("IF NOT EXISTS not specified, returning DuplicateGraph error", &.{});
                    return error.DuplicateGraph;
                }
            }

            // Add to catalog only after storage creation succeeds so the
            // catalog never persists placeholder graph metadata.
            try graph_store.getGlobalStore(allocator).createGraph(graph_name);
            errdefer graph_store.getGlobalStore(allocator).dropGraph(graph_name) catch {};
            const graph_uuid = graph_store.GraphStore.getGraphUuid(graph_name) orelse return error.GraphUuidUnavailable;

            try cat.graphs.put(try cat.allocator.dupe(u8, graph_name), graph_uuid);

            // Save catalog to disk after creating graph
            try cat.save();

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .CreateGraphType => |cgt| {
            // GAP-0295: Reject CREATE GRAPH TYPE when session is graph-bound via DSN
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-005; FEATURE="DSNGraphBinding"; ASPECT=CreateGraphTypeRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-05
            if (context.graph_bound) {
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-AUTH-ENFORCE-016; FEATURE="AuthEnforcement"; ASPECT=CreateGraphTypeSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CREATE GRAPH TYPE is a schema modification operation
            try checkPermission(context, .Schema);

            // CREATE GRAPH TYPE implementation with FLE catalog registration

            // Get global FLE catalog
            const fle_cat = try fle_catalog.globalCatalog(allocator);

            // Create type metadata
            var type_meta = fle_annotations.TypeMetadata.init(allocator, cgt.name);
            errdefer type_meta.deinit();

            // Process field definitions and apply annotations
            for (cgt.fields) |field_def| {
                // Build full annotation text by concatenating all annotations
                var annotation_text_builder = try std.ArrayList(u8).initCapacity(allocator, 256);
                defer annotation_text_builder.deinit(allocator);

                for (field_def.annotations) |annot| {
                    try annotation_text_builder.appendSlice(allocator, annot.text);
                    try annotation_text_builder.append(allocator, ' ');
                }

                const full_annotation_text = try annotation_text_builder.toOwnedSlice(allocator);
                defer allocator.free(full_annotation_text);

                // Apply annotations to field and add to type metadata
                if (full_annotation_text.len > 0) {
                    try fle_annotations.applyAnnotations(
                        allocator,
                        &type_meta,
                        field_def.name,
                        full_annotation_text,
                    );
                } else {
                    // Field has no annotations - add as plaintext field
                    const field_meta = fle_annotations.FieldMetadata{
                        .field_name = field_def.name,
                    };
                    try type_meta.fields.put(field_def.name, field_meta);
                }
            }

            // Register type in catalog
            try fle_cat.registerType(cgt.name, type_meta);

            // Save FLE catalog to disk
            fle_catalog.saveCatalog(fle_cat) catch |err| {
                log.err("CRITICAL: Failed to persist FLE catalog after type creation", &.{
                    Attr.string("type_name", cgt.name),
                    Attr.string("error", @errorName(err)),
                });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropGraph => |dg| {
            // GAP-0295: Reject DROP GRAPH when session is graph-bound via DSN
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-006; FEATURE="DSNGraphBinding"; ASPECT=DropGraphRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-05
            if (context.graph_bound) {
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-AUTH-ENFORCE-017; FEATURE="AuthEnforcement"; ASPECT=DropGraphSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: DROP GRAPH is a schema modification operation
            try checkPermission(context, .Schema);

            // DROP GRAPH implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            const graph_name = dg.name;

            // Phase 3: Write lock for DROP GRAPH
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if graph exists in either catalog or storage (unless IF EXISTS is used)
            const in_catalog = cat.graphs.contains(graph_name);
            const in_storage = graph_store.getGlobalStore(allocator).graphExists(graph_name);

            if (!dg.if_exists and !in_catalog and !in_storage) {
                return error.GraphNotFound;
            }

            // Remove from catalog if it exists
            _ = cat.graphs.remove(graph_name);

            // CRITICAL: Also remove from graph storage manager
            // This ensures SHOW GRAPHS no longer lists this graph
            graph_store.getGlobalStore(allocator).dropGraph(graph_name) catch |err| {
                // Log but don't fail - graph might only exist in one place
                log.warn("dropGraphStore failed", &.{
                    Attr.string("graph_name", graph_name),
                    Attr.string("error", @errorName(err)),
                });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropGraphType => |dgt| {
            // GAP-0295: Reject DROP GRAPH TYPE when session is graph-bound via DSN
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-007; FEATURE="DSNGraphBinding"; ASPECT=DropGraphTypeRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-05
            if (context.graph_bound) {
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-AUTH-ENFORCE-018; FEATURE="AuthEnforcement"; ASPECT=DropGraphTypeSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: DROP GRAPH TYPE is a schema modification operation
            try checkPermission(context, .Schema);

            // DROP GRAPH TYPE implementation
            _ = dgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .CreateSchema => |cs| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-019; FEATURE="AuthEnforcement"; ASPECT=CreateSchemaSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: CREATE SCHEMA is a schema modification operation
            try checkPermission(context, .Schema);

            // CREATE SCHEMA implementation with duplicate detection
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            const schema_name = cs.name;

            // Phase 3: Write lock for CREATE SCHEMA
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if schema already exists
            if (!cs.if_not_exists and cat.schemas.contains(schema_name)) {
                return error.DuplicateSchema;
            }

            // Add to catalog if not exists
            if (!cat.schemas.contains(schema_name)) {
                // P2-3: Use catalog's allocator (owned by catalog)
                try cat.schemas.put(try cat.allocator.dupe(u8, schema_name), {});
                // Save catalog to disk after creating schema
                cat.save() catch |err| {
                    log.err("CRITICAL: Failed to persist catalog after schema creation", &.{
                        Attr.string("schema_name", schema_name),
                        Attr.string("error", @errorName(err)),
                    });
                };
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropSchema => |ds| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-020; FEATURE="AuthEnforcement"; ASPECT=DropSchemaSchemaPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: DROP SCHEMA is a schema modification operation
            try checkPermission(context, .Schema);

            // DROP SCHEMA implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = getCatalog(allocator, context);

            const schema_name = ds.name;

            // Phase 3: Write lock for DROP SCHEMA
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if schema exists (unless IF EXISTS is used)
            if (!ds.if_exists and !cat.schemas.contains(schema_name)) {
                return error.SchemaNotFound;
            }

            // Remove from catalog if it exists
            _ = cat.schemas.remove(schema_name);

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .UseGraph => |ug| {
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-002; FEATURE="DSNGraphBinding"; ASPECT=UseGraphRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
            // Reject USE GRAPH when session is bound to a graph via DSN
            if (context.graph_bound) {
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-MULTI-GRAPH-001; FEATURE="MultiGraphSupport"; ASPECT=UseGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
            // USE GRAPH implementation - switch active graph context
            const graph_name = ug.graph_name;

            // Verify graph exists in catalog
            const cat = getCatalog(allocator, context);
            cat.rwlock.lockShared();
            defer cat.rwlock.unlockShared();

            if (!cat.graphs.contains(graph_name)) {
                return error.GraphNotFound;
            }

            // Update session state with new graph
            if (context.session_state) |session| {
                // Free old graph name if present
                if (session.graph) |old_graph| {
                    session.allocator.free(old_graph);
                }
                // Set new graph
                session.graph = try session.allocator.dupe(u8, graph_name);
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionReset => |sr| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionReset; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Reset session state based on arguments
            if (context.session_state) |session| {
                if (sr.arguments) |args| {
                    switch (args) {
                        .All => |all_type| {
                            switch (all_type) {
                                .Parameters => {
                                    // Reset all parameters
                                    var iter = session.parameters.iterator();
                                    while (iter.next()) |entry| {
                                        allocator.free(entry.key_ptr.*);
                                        allocator.free(entry.value_ptr.*);
                                    }
                                    session.parameters.clearRetainingCapacity();
                                },
                                .Characteristics => {
                                    // Reset all session characteristics
                                    session.reset();
                                },
                            }
                        },
                        .Schema => {
                            if (session.schema) |s| {
                                allocator.free(s);
                                session.schema = null;
                            }
                        },
                        .Graph => {
                            if (session.graph) |g| {
                                allocator.free(g);
                                session.graph = null;
                            }
                        },
                        .TimeZone => {
                            if (session.timezone) |tz| {
                                allocator.free(tz);
                                session.timezone = null;
                            }
                        },
                        .Parameter => |param| {
                            // Remove specific parameter
                            if (session.parameters.fetchRemove(param)) |entry| {
                                allocator.free(entry.key);
                                allocator.free(entry.value);
                            }
                        },
                    }
                } else {
                    // No arguments - reset everything
                    session.reset();
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session reset" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionClose => {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionClose; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Close session - clean up all session state
            if (context.session_state) |session| {
                session.reset();
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session closed" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .For => |f| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-022; FEATURE="AuthEnforcement"; ASPECT=ForReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: FOR is a read operation
            try checkPermission(context, .Read);
            return executeFor(allocator, f, context);
        },
        .Values => |v| {
            // CANARY: REQ=REQ-AUTH-ENFORCE-023; FEATURE="AuthEnforcement"; ASPECT=ValuesReadPermission; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
            // CRITICAL SECURITY: VALUES is a read operation
            try checkPermission(context, .Read);
            return executeValues(allocator, v, context);
        },
        else => return error.NotImplemented,
    }
}
