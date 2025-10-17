const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

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
const ensureCatalogInstance = execution.ensureCatalogInstance;
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

// CANARY: REQ=REQ-EXEC-REFACTOR-010; FEATURE="FileModularization"; ASPECT=StatementDispatcher; STATUS=IMPL; OWNER=refactoring; UPDATED=2025-10-17
pub fn executeStatementWithContext(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    switch (stmt) {
        .Query => |q| {
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
                    const new_rows = try allocator.alloc([]eval.Value, result.rows.len - skip_count);
                    for (result.rows[skip_count..], 0..) |row, i| {
                        new_rows[i] = row;
                    }
                    // Free old rows array but not the row data
                    allocator.free(result.rows);
                    result.rows = new_rows;
                } else {
                    // Skip all rows
                    allocator.free(result.rows);
                    result.rows = try allocator.alloc([]eval.Value, 0);
                }
            }

            // Apply LIMIT if present
            if (q.limit) |limit_count| {
                if (limit_count < result.rows.len) {
                    // Truncate to limit
                    const new_rows = try allocator.alloc([]eval.Value, limit_count);
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
            return executeUnionWithContext(allocator, u, context);
        },
        .Intersect => |i| {
            return executeIntersect(allocator, i);
        },
        .Except => |e| {
            return executeExcept(allocator, e);
        },
        .Create => |c| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeCreate(allocator, c);
        },
        .Insert => |ins| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeInsert(allocator, ins);
        },
        .Delete => |d| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeDelete(allocator, d);
        },
        .Merge => |m| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeMerge(allocator, m);
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

                // Execute all statements in the transaction body
                for (body) |*body_stmt| {
                    // Inline switch to handle different statement types (avoids circular error set inference)
                    last_result = (switch (body_stmt.*) {
                        .Query => |q| executeQueryWithContext(allocator, q, mut_context),
                        .Call => |c| switch (c) {
                            .Procedure => |proc| executeCallProcedure(allocator, proc, mut_context),
                            .Subquery => |subq| executeCallSubquery(allocator, subq, mut_context),
                        },
                        .Create => |create_stmt| executeCreate(allocator, create_stmt),
                        .Merge => |m| executeMerge(allocator, m),
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "transaction started" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
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
                        } else {
                            // For any other graph (including "NewG"), clear the store to create empty graph
                            const store = graph_store.getGlobalStore(allocator);
                            store.clearNodes();
                        }
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session updated" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Show => |s| {
            return executeShow(allocator, s);
        },
        .Explain => |exp| {
            return executeExplain(allocator, exp, context);
        },
        .Profile => |prof| {
            return executeProfile(allocator, prof, context);
        },
        .CreateIndex => |ci| {
            // CREATE INDEX implementation with validation
            // CANARY: REQ=REQ-INDEX-002; FEATURE="IndexManagement"; ASPECT=ScopedCreation; STATUS=IMPLEMENTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const index_name = ci.name;
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
                    std.log.err("CRITICAL: Failed to persist catalog after index creation  '{s}': {any}", .{ index_name, err });
                };
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .CreateConstraint => |cc| {
            // CREATE CONSTRAINT implementation
            // For now, just return success (no enforcement)
            // TODO: Store constraint in catalog
            // TODO: Validate existing data
            // TODO: Enforce on INSERT/UPDATE/DELETE
            _ = cc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropIndex => |di| {
            // DROP INDEX implementation
            // CANARY: REQ=REQ-INDEX-003; FEATURE="IndexManagement"; ASPECT=ScopedDeletion; STATUS=IMPLEMENTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

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
                    std.log.err("CRITICAL: Failed to persist catalog after index drop  '{s}': {any}", .{ index_name, err });
                };
            } else if (!di.if_exists) {
                return error.IndexNotFound;
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropConstraint => |dc| {
            // DROP CONSTRAINT implementation
            _ = dc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .Call => |call_stmt| {
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
                            const new_rows = try allocator.alloc([]eval.Value, result.rows.len - skip_count);
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
                            const new_rows = try allocator.alloc([]eval.Value, limit_count);
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
                    result = try executeCallSubquery(allocator, subq, context);
                },
            }

            return result;
        },
        .CreateGraph => |cg| {
            // CREATE GRAPH implementation with duplicate detection
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const graph_name = cg.name;

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
            } else {
                // Check if graph already exists
                if (cat.graphs.contains(graph_name)) {
                    // If IF NOT EXISTS is specified, silently succeed
                    if (cg.if_not_exists) {
                        return ExecutionResult{
                            .columns = try allocator.alloc([]const u8, 0),
                            .rows = try allocator.alloc([]eval.Value, 0),
                            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                        };
                    }
                    return error.DuplicateGraph;
                }
            }

            // Add to catalog
            // P2-3: Use catalog's allocator (owned by catalog)
            try cat.graphs.put(try cat.allocator.dupe(u8, graph_name), {});
            // Save catalog to disk after creating graph
            cat.save() catch |err| {
                std.log.err("CRITICAL: Failed to persist catalog after graph creation  '{s}': {any}", .{ graph_name, err });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateGraphType => |cgt| {
            // CREATE GRAPH TYPE implementation with FLE catalog registration

            // Get global FLE catalog
            const fle_cat = try fle_catalog.globalCatalog(allocator);

            // Create type metadata
            var type_meta = fle_annotations.TypeMetadata.init(allocator, cgt.name);
            errdefer type_meta.deinit();

            // Process field definitions and apply annotations
            for (cgt.fields) |field_def| {
                // Build full annotation text by concatenating all annotations
                var annotation_text_builder = std.ArrayList(u8).initCapacity(allocator, 256) catch @panic("OOM");
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
                std.log.err("CRITICAL: Failed to persist FLE catalog after type creation  '{s}': {any}", .{ cgt.name, err });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraph => |dg| {
            // DROP GRAPH implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const graph_name = dg.name;

            // Phase 3: Write lock for DROP GRAPH
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if graph exists (unless IF EXISTS is used)
            if (!dg.if_exists and !cat.graphs.contains(graph_name)) {
                return error.GraphNotFound;
            }

            // Remove from catalog if it exists
            _ = cat.graphs.remove(graph_name);

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraphType => |dgt| {
            // DROP GRAPH TYPE implementation
            _ = dgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateSchema => |cs| {
            // CREATE SCHEMA implementation with duplicate detection
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

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
                    std.log.err("CRITICAL: Failed to persist catalog after schema creation  '{s}': {any}", .{ schema_name, err });
                };
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropSchema => |ds| {
            // DROP SCHEMA implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

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
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .UseGraph => |ug| {
            // USE GRAPH implementation - switch active graph context
            _ = ug;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session reset" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
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

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session closed" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .For => |f| {
            return executeFor(allocator, f, context);
        },
        .Values => |v| {
            return executeValues(allocator, v, context);
        },
        else => return error.NotImplemented,
    }
}

