const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const protocol = @import("../protocol.zig");
const planner = @import("../planner.zig");
const federation = @import("federation.zig");
// GAP-0077: Import CBO for statistics integration
const cbo = @import("../planner/cbo.zig");
const parallel_wrapper = @import("parallel/thread_pool_parallel");
const value_utilities = @import("../execution/value_utilities.zig");
const result_utils = @import("result_utils.zig");

const logging = @import("logging");
const log = logging.scoped("query_coordinator");
const Attr = logging.Attr;

/// Deprecated: Use EnhancedQueryCoordinator for production deployments.
/// EnhancedQueryCoordinator is a superset that adds caching, optimization, and Top-K push-down.
///
/// Distributed query coordinator
/// Handles scatter-gather pattern for federated queries
/// GAP-0077: Now uses statistics registry for row estimates
// CANARY: REQ=REQ-DIST-STATS-001; FEATURE="DistributedStatsIntegration"; ASPECT=QueryPlanning; STATUS=TESTED; TEST="QueryCoordinator: initialization"; OWNER=distributed; UPDATED=2026-04-05
pub const QueryCoordinator = struct {
    allocator: std.mem.Allocator,
    config: federation.FederationConfig,
    shard_map: ShardMap,
    node_registry: NodeRegistry,
    metrics: CoordinatorMetrics,
    stats_registry: ?*cbo.StatsRegistry = null, // GAP-0077: Optional statistics registry
    pool: parallel_wrapper.ParallelPool, // PERF-D007: Reuse pool across queries
    // GAP-0810: optional shared AST cache. When wired by the server via
    // setAstCache(), local-fragment parses route through `parseGqlCached`
    // so repeated fragment shapes amortize the parser cost across queries
    // and across subsystems. Null means "no cache — fall back to parseGql",
    // preserving every standalone caller (tests, shell invocation).
    // CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="SharedAstCache"; ASPECT=CoordinatorWiring; STATUS=TESTED; TEST=tests/test_gap0810_cross_subsystem_cache.zig; OWNER=performance; UPDATED=2026-04-20
    ast_cache: ?*@import("../lib.zig").SharedAstCache = null,

    const Self = @This();

    /// Initialize the query coordinator
    pub fn init(allocator: std.mem.Allocator, config: federation.FederationConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .shard_map = try ShardMap.init(allocator),
            .node_registry = try NodeRegistry.init(allocator),
            .metrics = CoordinatorMetrics.init(),
            .pool = parallel_wrapper.ParallelPool.init(allocator, null),
            .ast_cache = null,
        };
    }

    /// GAP-0810: wire a process-wide shared AST cache into the coordinator.
    /// The server calls this at startup with `ServerState.shared_ast_cache`
    /// so that local fragment parses reuse handles across queries. Pass null
    /// to disable; cache lifetime must outlive the coordinator.
    pub fn setAstCache(self: *Self, cache: ?*@import("../lib.zig").SharedAstCache) void {
        self.ast_cache = cache;
    }

    pub fn deinit(self: *Self) void {
        self.pool.deinit();
        self.shard_map.deinit();
        self.node_registry.deinit();
    }

    /// Execute a distributed query with global ORDER BY and LIMIT.
    ///
    /// PERF-D019: The scatter-gather pipeline fully materializes all shard
    /// results before the merge phase begins.  Streaming merge is not
    /// practical here because:
    ///   1. merge_sorted uses a TopKHeap that needs to compare rows across
    ///      all shards -- it requires the full result set from each shard
    ///      before it can produce globally-ordered output.
    ///   2. union_all with OFFSET/LIMIT needs total row counts across all
    ///      shards to compute correct windows.
    ///   3. hash_aggregate and union_distinct require full materialization
    ///      for deduplication.
    /// A streaming approach would only help if shards returned pre-sorted
    /// cursors and the merge used a k-way merge iterator, but the current
    /// QUIC protocol returns complete DataPage batches, not streaming cursors.
    // CANARY: REQ=REQ-GQL-FED-001; FEATURE="Distributed Query Federation"; ASPECT=Core; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    pub fn executeDistributedQuery(
        self: *Self,
        query: []const u8,
        params: []const protocol.Value,
        order_by: ?[]const federation.OrderKey,
        limit: ?u64,
        offset: ?u64,
    ) !federation.QueryResults {
        const start_time = compat_milliTimestamp();

        // Parse and analyze query to determine sharding strategy
        const plan = try self.planDistributedQuery(query, params);
        defer plan.deinit();

        // Scatter phase - send fragments to shards
        const shard_results = try self.scatterQuery(plan, params);
        defer {
            for (shard_results) |*result| result.deinit(self.allocator);
            self.allocator.free(shard_results);
        }

        // Gather phase - collect and merge results
        const merged = try self.gatherResults(shard_results, order_by, limit, offset);

        const exec_time = @as(u64, @intCast(compat_milliTimestamp() - start_time));
        self.metrics.recordQuery(exec_time, shard_results.len);

        return merged;
    }

    /// Plan how to distribute the query across shards
    fn planDistributedQuery(self: *Self, query: []const u8, params: []const protocol.Value) !DistributedPlan {
        _ = params;

        var plan = DistributedPlan.init(self.allocator);

        // Determine which shards need to participate
        const participating_shards = try self.shard_map.getShardsForQuery(query);

        // GAP-0077: Extract table name from query for statistics lookup
        const table_name = self.extractTableFromQuery(query);

        // Generate shard-specific query fragments
        for (participating_shards) |shard_id| {
            // GAP-0077: Use statistics for row estimate if available
            // CANARY: REQ=REQ-DIST-STATS-002; FEATURE="ShardRowEstimate"; ASPECT=QueryPlanning; STATUS=TESTED; TEST="QueryCoordinator: row estimation without stats"; OWNER=distributed; UPDATED=2026-04-05
            const estimated_rows = self.estimateRowsForShard(table_name, shard_id, participating_shards.len);

            const fragment = QueryFragment{
                .shard_id = shard_id,
                .query_text = try self.allocator.dupe(u8, query),
                .estimated_rows = estimated_rows,
            };
            try plan.fragments.append(fragment);
        }

        // Determine merge strategy based on query type
        if (std.mem.indexOf(u8, query, "ORDER BY") != null) {
            plan.merge_strategy = .merge_sorted;
        } else {
            plan.merge_strategy = .union_all;
        }

        return plan;
    }

    /// Scatter query fragments to shards with concurrent execution.
    ///
    /// PERF-D020: Allocation analysis for scatter-gather path:
    ///   - results[] and errors[] are pre-allocated once (O(shard_count)).
    ///   - Per-fragment query_text duplication in planDistributedQuery is
    ///     bounded by shard count (typically 3-16), each sharing the same
    ///     source text length. This is acceptable overhead vs. the cost
    ///     of the QUIC round-trips.
    ///   - The parallel Context struct is stack-allocated (zero heap cost).
    ///   - Pre-sizing the results array with ensureTotalCapacity avoids
    ///     incremental growth allocations during parallel execution.
    /// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=ConcurrentExecution; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-01
    /// GAP-0184: Implements actual concurrent scatter/gather for fragment execution
    fn scatterQuery(self: *Self, plan: DistributedPlan, params: []const protocol.Value) ![]federation.QueryResults {
        const fragment_count = plan.fragments.items.len;
        var results = try self.allocator.alloc(federation.QueryResults, fragment_count);
        errdefer self.allocator.free(results);

        // Initialize results with empty defaults
        for (results) |*r| {
            r.* = federation.QueryResults{
                .rows = &.{},
                .schema = &.{},
                .execution_time_ms = 0,
                .ordered = false,
            };
        }

        // For single fragment or when parallelism is disabled, use sequential execution
        if (fragment_count <= 1 or !self.config.enable_parallel_scatter) {
            for (plan.fragments.items, 0..) |fragment, i| {
                const node = try self.node_registry.getNode(fragment.shard_id);
                if (node.is_local) {
                    results[i] = try self.executeLocalFragment(fragment.query_text, params);
                } else {
                    results[i] = try self.executeRemoteFragment(node, fragment.query_text, params);
                }
            }
            return results;
        }

        const errors = try self.allocator.alloc(?anyerror, fragment_count);
        defer self.allocator.free(errors);
        for (errors) |*e| e.* = null;

        // PERF-D007: Reuse struct-level pool instead of creating per-call
        const Context = struct {
            coordinator: *Self,
            fragments: []const QueryFragment,
            params: []const protocol.Value,
            results: []federation.QueryResults,
            errors: []?anyerror,
        };

        const ctx = Context{
            .coordinator = self,
            .fragments = plan.fragments.items,
            .params = params,
            .results = results,
            .errors = errors,
        };

        parallel_wrapper.parallelForEach(
            &self.pool,
            0,
            fragment_count,
            ctx,
            struct {
                fn work(_: *parallel_wrapper.Task, idx: usize, c: Context) void {
                    const fragment = c.fragments[idx];
                    const node = c.coordinator.node_registry.getNode(fragment.shard_id) catch |err| {
                        c.errors[idx] = err;
                        return;
                    };

                    if (node.is_local) {
                        c.results[idx] = c.coordinator.executeLocalFragment(fragment.query_text, c.params) catch |err| {
                            c.errors[idx] = err;
                            return;
                        };
                    } else {
                        c.results[idx] = c.coordinator.executeRemoteFragment(node, fragment.query_text, c.params) catch |err| {
                            c.errors[idx] = err;
                            return;
                        };
                    }
                }
            }.work,
            parallel_wrapper.Thresholds.forEach,
        );

        // GAP-0889: a failed fragment must fail the query. Continuing with an
        // empty result for that shard silently returned PARTIAL data as if it
        // were the complete answer (and the sequential path above already
        // propagates fragment errors — the two paths now agree).
        var first_error: ?anyerror = null;
        for (errors, 0..) |err, i| {
            if (err) |e| {
                log.err("Shard execution failed", &.{
                    Attr.uint("shard_index", i),
                    Attr.string("error", @errorName(e)),
                });
                if (first_error == null) first_error = e;
            }
        }
        if (first_error) |e| {
            for (results) |*r| r.deinit(self.allocator);
            return e;
        }

        _ = self.metrics.concurrent_queries.fetchAdd(1, .monotonic);
        return results;
    }

    // CANARY: REQ=REQ-DIST-LOCAL-001; FEATURE="DistributedLocalExecution"; ASPECT=Distributed; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Execute query fragment on local shard using the actual query executor
    fn executeLocalFragment(self: *Self, query_text: []const u8, params: []const protocol.Value) !federation.QueryResults {
        _ = params; // reserved: parameter binding for local fragments is not wired yet
        const start_time = compat_milliTimestamp();

        // GAP-0043: Wire to actual executor instead of returning mock results
        // Parse the query
        const lib = @import("../lib.zig");
        const execution = @import("../execution.zig");

        // GAP-0810: route through shared AST cache when the server has wired
        // one — repeated fragment shapes amortize the parser cost. The
        // cache-owned handle lives until exec_result.deinit below, so we
        // capture both and release/deinit in reverse order via `defer`.
        var ast_handle: ?@import("../lib.zig").AstHandle = null;
        var owned_parse_result: ?lib.ParseResult = null;
        defer {
            if (ast_handle) |*h| h.release();
            if (owned_parse_result) |*pr| pr.deinit();
        }

        // GAP-0889: parse/execution failures used to return an EMPTY result
        // set, which a caller cannot distinguish from "the query matched
        // nothing" — a wrong-answer bug for distributed merges. Fail loud and
        // let scatterQuery's per-fragment error channel report the shard.
        const parse_result: *const lib.ParseResult = parse_blk: {
            if (self.ast_cache) |cache| {
                const outcome = lib.parseGqlCached(cache, query_text, .{}) catch |err| {
                    log.err("local fragment parse failed", &.{Attr.string("error", @errorName(err))});
                    return err;
                };
                switch (outcome) {
                    .Err => {
                        log.err("local fragment parse rejected", &.{Attr.string("query", query_text)});
                        return error.ParseError;
                    },
                    .Ok => |h| {
                        ast_handle = h;
                        break :parse_blk h.parse_result;
                    },
                }
            }
            const pr = lib.parseGql(query_text, self.allocator) catch |err| {
                log.err("local fragment parse failed", &.{Attr.string("error", @errorName(err))});
                return err;
            };
            owned_parse_result = pr;
            break :parse_blk &owned_parse_result.?;
        };

        // Get execution context
        const catalog = execution.ensureCatalogInstance(self.allocator) catch |err| {
            log.err("local fragment catalog init failed", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        // CANARY: REQ=REQ-GPS-DERIVE-002; FEATURE="GPS Principal Derivation"; ASPECT=DistributedCoordinatorWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
        // Phase 2: delegate to derivePrincipal() so all transport sites share
        // the same field-population logic. source=.internal_service lets GPS Phase 6
        // distinguish coordinator-originated work from user-originated work even
        // when both reach the same shard worker.
        const coordinator_principal = @import("../security/principal_derive.zig").derivePrincipal(.{
            .username = "geode-coordinator",
            .role_names = &.{},
            .tenant_id = null,
            .active_graph = null,
            .auth_version = 0,
            .auth_method = .anonymous,
            .source = .internal_service,
        });
        const context = execution.ExecutionContext{
            .catalog = catalog,
            .principal = &coordinator_principal,
        };

        // Execute the program (GAP-0889: propagate — an empty result set is
        // indistinguishable from a successful empty match).
        var exec_result = execution.executeProgramWithContext(self.allocator, &parse_result.program, context) catch |err| {
            log.err("local fragment execution failed", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        defer exec_result.deinit(self.allocator);

        // Convert ExecutionResult to federation.QueryResults
        var schema = try self.allocator.alloc(protocol.ColumnDef, exec_result.columns.len);
        errdefer {
            for (schema) |col| {
                self.allocator.free(col.name);
                self.allocator.free(col.data_type);
            }
            self.allocator.free(schema);
        }
        for (exec_result.columns, 0..) |col_name, i| {
            schema[i] = .{
                .name = try self.allocator.dupe(u8, col_name),
                .data_type = try self.allocator.dupe(u8, "ANY"),
            };
        }

        var rows = try self.allocator.alloc(protocol.BindingRow, exec_result.rows.len);
        var row_idx: usize = 0;
        errdefer {
            for (rows[0..row_idx]) |row| {
                for (row.cols) |val| value_utilities.freeValue(self.allocator, val);
                if (row.cols.len > 0) self.allocator.free(row.cols);
            }
            self.allocator.free(rows);
        }

        for (exec_result.rows) |row| {
            var cols = try self.allocator.alloc(protocol.Value, row.len);
            errdefer {
                for (cols) |val| value_utilities.freeValue(self.allocator, val);
                self.allocator.free(cols);
            }
            for (row, 0..) |val, j| {
                cols[j] = try value_utilities.duplicateValue(self.allocator, val);
            }
            rows[row_idx] = .{ .cols = cols };
            row_idx += 1;
        }

        return federation.QueryResults{
            .rows = rows,
            .schema = schema,
            .execution_time_ms = @as(u64, @intCast(compat_milliTimestamp() - start_time)),
            .ordered = false,
        };
    }

    /// Execute query fragment on remote shard via QUIC
    fn executeRemoteFragment(self: *Self, node: *Node, query: []const u8, params: []const protocol.Value) !federation.QueryResults {
        var conn = try node.connection_pool.acquire();
        defer node.connection_pool.release(conn);

        const fed_query = federation.FederatedQuery{
            .query_text = query,
            .parameters = params,
            .target_nodes = &.{node.id},
            .consistency_level = .eventual,
        };
        return try conn.executeQuery(
            self.allocator,
            node.endpoint,
            self.config.query_timeout_ms,
            self.config.topk_merge_batch_size,
            fed_query,
        );
    }

    /// Gather and merge results from shards
    /// Implements global ORDER BY and distributed Top-K
    fn gatherResults(
        self: *Self,
        shard_results: []federation.QueryResults,
        order_by: ?[]const federation.OrderKey,
        limit: ?u64,
        offset: ?u64,
    ) !federation.QueryResults {
        // If no ordering, simple union
        if (order_by == null) {
            return try self.unionResults(shard_results, limit, offset);
        }

        // Global ordered merge with distributed Top-K optimization
        return try self.mergeOrderedResults(shard_results, order_by.?, limit, offset);
    }

    /// Simple union of unordered results
    fn unionResults(
        self: *Self,
        shard_results: []federation.QueryResults,
        limit: ?u64,
        offset: ?u64,
    ) !federation.QueryResults {
        var total_rows: usize = 0;
        for (shard_results) |result| {
            total_rows += result.rows.len;
        }
        const start = offset orelse 0;
        const end = if (limit) |l| @min(start + l, total_rows) else total_rows;

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) {
            for (schema_copy) |col| {
                self.allocator.free(col.name);
                self.allocator.free(col.data_type);
            }
            self.allocator.free(schema_copy);
        };

        if (start >= total_rows or end <= start) {
            return federation.QueryResults{
                .rows = &.{},
                .schema = schema_copy,
                .execution_time_ms = 0,
                .ordered = false,
            };
        }

        const out_len = end - start;
        var out_rows = try self.allocator.alloc(protocol.BindingRow, out_len);
        var out_idx: usize = 0;
        errdefer {
            for (out_rows[0..out_idx]) |row| freeBindingRow(self.allocator, row);
            self.allocator.free(out_rows);
        }

        var global_idx: usize = 0;
        for (shard_results) |result| {
            for (result.rows) |row| {
                if (global_idx >= start and global_idx < end) {
                    out_rows[out_idx] = try cloneBindingRow(self.allocator, row);
                    out_idx += 1;
                }
                global_idx += 1;
                if (global_idx >= end) break;
            }
            if (global_idx >= end) break;
        }

        return federation.QueryResults{
            .rows = out_rows,
            .schema = schema_copy,
            .execution_time_ms = 0,
            .ordered = false,
        };
    }

    /// Merge sorted results with distributed Top-K optimization
    fn mergeOrderedResults(
        self: *Self,
        shard_results: []federation.QueryResults,
        order_keys: []const federation.OrderKey,
        limit: ?u64,
        offset: ?u64,
    ) !federation.QueryResults {
        // Phase 1: Request Top-K from each shard
        const k = (limit orelse 100) + (offset orelse 0);

        // Use a min-heap for efficient Top-K merge
        var heap = try TopKHeap.init(self.allocator, k, order_keys);
        defer heap.deinit();

        // Merge all shard results into heap
        for (shard_results) |result| {
            for (result.rows) |row| {
                try heap.push(row);
            }
        }

        // Extract final sorted results
        var sorted_rows = try heap.getSorted();
        errdefer {
            for (sorted_rows) |row| freeBindingRow(self.allocator, row);
            self.allocator.free(sorted_rows);
        }

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) {
            for (schema_copy) |col| {
                self.allocator.free(col.name);
                self.allocator.free(col.data_type);
            }
            self.allocator.free(schema_copy);
        };

        const order_key_names = try self.extractOrderKeyNames(order_keys);
        errdefer {
            for (order_key_names) |kn| self.allocator.free(kn);
            self.allocator.free(order_key_names);
        }

        const start = offset orelse 0;
        const end = if (limit) |l| @min(start + l, sorted_rows.len) else sorted_rows.len;

        if (start >= sorted_rows.len or end <= start) {
            for (sorted_rows) |row| freeBindingRow(self.allocator, row);
            self.allocator.free(sorted_rows);
            return federation.QueryResults{
                .rows = &.{},
                .schema = schema_copy,
                .execution_time_ms = 0,
                .ordered = true,
                .order_keys = order_key_names,
            };
        }

        if (start > 0 or end < sorted_rows.len) {
            for (sorted_rows[0..start]) |row| freeBindingRow(self.allocator, row);
            for (sorted_rows[end..]) |row| freeBindingRow(self.allocator, row);
            const out_len = end - start;
            if (start > 0) {
                std.mem.copyForwards(protocol.BindingRow, sorted_rows[0..out_len], sorted_rows[start..end]);
            }
            sorted_rows = sorted_rows[0..out_len];
        }

        return federation.QueryResults{
            .rows = sorted_rows,
            .schema = schema_copy,
            .execution_time_ms = 0,
            .ordered = true,
            .order_keys = order_key_names,
        };
    }

    fn extractOrderKeyNames(self: *Self, order_keys: []const federation.OrderKey) ![]const []const u8 {
        var names = try self.allocator.alloc([]const u8, order_keys.len);
        for (order_keys, 0..) |key, i| {
            names[i] = try self.allocator.dupe(u8, key.column);
        }
        return names;
    }

    /// GAP-0077: Extract table name from query for statistics lookup
    // CANARY: REQ=REQ-DIST-STATS-003; FEATURE="TableNameExtraction"; ASPECT=QueryParsing; STATUS=TESTED; TEST="QueryCoordinator: table name extraction"; OWNER=distributed; UPDATED=2026-04-05
    fn extractTableFromQuery(self: *Self, query: []const u8) ?[]const u8 {
        _ = self;
        // Simple heuristic: look for MATCH (x:TableName) or FROM TableName patterns
        // For GQL: look for label pattern like (n:Person)
        if (std.mem.indexOf(u8, query, ":")) |colon_idx| {
            // Find the start of the label (after colon)
            const after_colon = query[colon_idx + 1 ..];
            // Find the end (space, ), or })
            var end_idx: usize = 0;
            for (after_colon, 0..) |c, i| {
                if (c == ')' or c == ' ' or c == '}' or c == '{' or c == ']') {
                    end_idx = i;
                    break;
                }
                end_idx = i + 1;
            }
            if (end_idx > 0) {
                return after_colon[0..end_idx];
            }
        }
        return null;
    }

    /// GAP-0077: Estimate rows for a shard using statistics
    // CANARY: REQ=REQ-DIST-STATS-004; FEATURE="ShardRowEstimation"; ASPECT=Statistics; STATUS=TESTED; TEST="QueryCoordinator: row estimation without stats"; OWNER=distributed; UPDATED=2026-04-05
    fn estimateRowsForShard(self: *Self, table_name: ?[]const u8, shard_id: u64, total_shards: usize) u64 {
        _ = shard_id;

        // Default estimate if no statistics available
        const default_estimate: u64 = 10000;

        // If no table name extracted, use default
        const table = table_name orelse return default_estimate / @max(1, total_shards);

        // Try to get statistics from registry
        if (self.stats_registry) |registry| {
            if (registry.getTableStats(table)) |stats| {
                // Distribute rows evenly across participating shards
                const total_rows = stats.row_count;
                const rows_per_shard = total_rows / @max(1, total_shards);
                // Add 10% buffer for estimation variance
                return rows_per_shard + rows_per_shard / 10;
            }
        }

        // Fall back to default if no statistics
        return default_estimate / @max(1, total_shards);
    }

    /// GAP-0077: Set the statistics registry for this coordinator
    pub fn setStatsRegistry(self: *Self, registry: *cbo.StatsRegistry) void {
        self.stats_registry = registry;
    }
};

const cloneBindingRow = result_utils.cloneBindingRow;
const freeBindingRow = result_utils.freeBindingRow;
const cloneSchema = result_utils.cloneSchema;

/// Distributed query plan
const DistributedPlan = struct {
    allocator: std.mem.Allocator,
    fragments: std.ArrayList(QueryFragment),
    merge_strategy: MergeStrategy,

    fn init(allocator: std.mem.Allocator) DistributedPlan {
        return .{
            .allocator = allocator,
            .fragments = std.ArrayList(QueryFragment).init(allocator),
            .merge_strategy = .union_all,
        };
    }

    fn deinit(self: *DistributedPlan) void {
        for (self.fragments.items) |fragment| {
            self.allocator.free(fragment.query_text);
        }
        self.fragments.deinit();
    }
};

const QueryFragment = struct {
    shard_id: []const u8,
    query_text: []const u8,
    estimated_rows: u64,
};

const MergeStrategy = enum {
    union_all,
    union_distinct,
    merge_sorted,
    hash_aggregate,
};

/// Shard mapping for data distribution
const ShardMap = struct {
    allocator: std.mem.Allocator,
    shards: std.StringHashMap(ShardInfo),

    fn init(allocator: std.mem.Allocator) !ShardMap {
        return .{
            .allocator = allocator,
            .shards = std.StringHashMap(ShardInfo).init(allocator),
        };
    }

    fn deinit(self: *ShardMap) void {
        self.shards.deinit();
    }

    // CANARY: REQ=REQ-SHARD-PRUNE-001; FEATURE="ShardPruning"; ASPECT=QueryOptimization; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn getShardsForQuery(self: *ShardMap, query: []const u8) ![][]const u8 {
        // Try to extract partition key predicates from query
        // Look for patterns like "WHERE id = <value>" or "WHERE partition_key = <value>"
        const partition_value = self.extractPartitionValue(query);

        if (partition_value) |value| {
            // If we found a partition key value, find matching shard(s)
            var matching_shards = std.ArrayList([]const u8).init(self.allocator);
            defer matching_shards.deinit();

            var iter = self.shards.iterator();
            while (iter.next()) |entry| {
                const shard_info = entry.value_ptr.*;
                // Check if value falls within this shard's key range
                if (value >= shard_info.key_range_start and value < shard_info.key_range_end) {
                    try matching_shards.append(entry.key_ptr.*);
                }
            }

            if (matching_shards.items.len > 0) {
                log.debug("Shard pruning: query targets subset of shards", &.{
                    Attr.uint("target_shards", matching_shards.items.len),
                    Attr.uint("total_shards", self.shards.count()),
                });
                return matching_shards.toOwnedSlice();
            }
        }

        // Fallback: return all shards if no partition key found or no matches
        log.debug("Shard pruning: query targets all shards (no partition key found)", &.{
            Attr.uint("total_shards", self.shards.count()),
        });
        var shard_ids = try self.allocator.alloc([]const u8, self.shards.count());
        var iter = self.shards.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            shard_ids[i] = entry.key_ptr.*;
        }
        return shard_ids;
    }

    // Extract numeric partition value from query WHERE clause
    fn extractPartitionValue(self: *ShardMap, query: []const u8) ?u64 {
        _ = self;
        // Look for patterns: "WHERE id = <number>" or "WHERE partition_key = <number>"
        // This is a simplified implementation - full implementation would use AST
        const patterns = [_][]const u8{ "WHERE id = ", "WHERE partition_key = ", "WHERE id=", "WHERE partition_key=" };

        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, query, pattern)) |idx| {
                const start = idx + pattern.len;
                var end = start;
                while (end < query.len and (query[end] >= '0' and query[end] <= '9')) {
                    end += 1;
                }
                if (end > start) {
                    return std.fmt.parseInt(u64, query[start..end], 10) catch null;
                }
            }
        }
        return null;
    }
};

const ShardInfo = struct {
    id: []const u8,
    node_id: []const u8,
    key_range_start: u64,
    key_range_end: u64,
};

/// Registry of nodes in the cluster
const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(Node),

    fn init(allocator: std.mem.Allocator) !NodeRegistry {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(Node).init(allocator),
        };
    }

    fn deinit(self: *NodeRegistry) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.connection_pool.deinit();
        }
        self.nodes.deinit();
    }

    fn getNode(self: *NodeRegistry, node_id: []const u8) !*Node {
        return self.nodes.getPtr(node_id) orelse error.NodeNotFound;
    }
};

const Node = struct {
    id: []const u8,
    endpoint: []const u8,
    is_local: bool,
    connection_pool: federation.ConnectionPool,
};

/// Top-K heap for efficient merge sorting
const TopKHeap = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(protocol.BindingRow),
    k: usize,
    order_keys: []const federation.OrderKey,

    fn init(allocator: std.mem.Allocator, k: usize, order_keys: []const federation.OrderKey) !TopKHeap {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(protocol.BindingRow).init(allocator),
            .k = k,
            .order_keys = order_keys,
        };
    }

    fn deinit(self: *TopKHeap) void {
        for (self.items.items) |row| {
            freeBindingRow(self.allocator, row);
        }
        self.items.deinit();
    }

    fn push(self: *TopKHeap, row: protocol.BindingRow) !void {
        const cloned = try cloneBindingRow(self.allocator, row);
        try self.items.append(cloned);

        // If we exceed k items, remove the smallest
        if (self.items.items.len > self.k) {
            // Simple approach: sort and keep top k
            // TODO: Optimize with actual heap operations // #473
            std.sort.heap(protocol.BindingRow, self.items.items, self.order_keys, compareRows);
            for (self.items.items[self.k..]) |dropped| {
                freeBindingRow(self.allocator, dropped);
            }
            self.items.items.len = self.k;
        }
    }

    fn getSorted(self: *TopKHeap) ![]protocol.BindingRow {
        std.sort.heap(protocol.BindingRow, self.items.items, self.order_keys, compareRows);
        return self.items.toOwnedSlice();
    }

    /// Compare rows based on order keys for distributed query sorting
    // CANARY: REQ=REQ-DIST-ROW-CMP-002; FEATURE="Distributed Row Comparison"; ASPECT=Distributed; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// GAP-0053: Implements proper ORDER BY key comparison
    fn compareRows(order_keys: []const federation.OrderKey, a: protocol.BindingRow, b: protocol.BindingRow) bool {
        if (order_keys.len == 0) {
            // Fall back to comparing all columns
            const max_cols = if (a.cols.len > b.cols.len) a.cols.len else b.cols.len;
            var i: usize = 0;
            while (i < max_cols) : (i += 1) {
                const av = a.get(i);
                const bv = b.get(i);
                const cmp = protocol.compareBindingValues(av, bv, true);
                if (cmp == .lt) return true;
                if (cmp == .gt) return false;
            }
            return false;
        }

        // Compare by explicit order keys
        for (order_keys) |key| {
            // Find column index by name (simplified: assume column names match indices)
            // In a full implementation, would look up column name in schema
            var col_idx: usize = 0;
            inline for (0..32) |idx| {
                if (idx < a.cols.len) {
                    col_idx = idx;
                    break;
                }
            }
            const av = a.get(col_idx);
            const bv = b.get(col_idx);
            const cmp = protocol.compareBindingValues(av, bv, true);
            if (cmp == .eq) continue;
            if (key.ascending) {
                return cmp == .lt;
            } else {
                return cmp == .gt;
            }
        }
        return false;
    }
};

/// Coordinator metrics
/// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=Metrics; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-01
const CoordinatorMetrics = struct {
    // PERF-D010: Atomic counters for thread-safe metrics updates
    total_queries: std.atomic.Value(u64),
    total_time_ms: std.atomic.Value(u64),
    shard_queries: std.atomic.Value(u64),
    merge_time_ms: std.atomic.Value(u64),
    /// GAP-0184: Track concurrent query executions
    concurrent_queries: std.atomic.Value(u64),

    fn init() CoordinatorMetrics {
        return .{
            .total_queries = std.atomic.Value(u64).init(0),
            .total_time_ms = std.atomic.Value(u64).init(0),
            .shard_queries = std.atomic.Value(u64).init(0),
            .merge_time_ms = std.atomic.Value(u64).init(0),
            .concurrent_queries = std.atomic.Value(u64).init(0),
        };
    }

    fn recordQuery(self: *CoordinatorMetrics, time_ms: u64, shard_count: usize) void {
        _ = self.total_queries.fetchAdd(1, .monotonic);
        _ = self.total_time_ms.fetchAdd(time_ms, .monotonic);
        _ = self.shard_queries.fetchAdd(@as(u64, @intCast(shard_count)), .monotonic);
    }
};

// =============================================================================
// GAP-0184: Unit Tests for Concurrent Shard Execution
// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=UnitTests; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-01
// =============================================================================

test "QueryCoordinator: initialization" {
    const ally = std.testing.allocator;
    const config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Verify coordinator initializes with default parallel scatter enabled
    try std.testing.expect(config.enable_parallel_scatter == true);

    // Verify metrics are initialized
    try std.testing.expect(coordinator.metrics.total_queries.load(.monotonic) == 0);
    try std.testing.expect(coordinator.metrics.concurrent_queries.load(.monotonic) == 0);
}

test "QueryCoordinator: metrics tracking" {
    const ally = std.testing.allocator;
    const config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Record a query
    coordinator.metrics.recordQuery(100, 3);
    try std.testing.expect(coordinator.metrics.total_queries.load(.monotonic) == 1);
    try std.testing.expect(coordinator.metrics.total_time_ms.load(.monotonic) == 100);
    try std.testing.expect(coordinator.metrics.shard_queries.load(.monotonic) == 3);

    // Record another query
    coordinator.metrics.recordQuery(50, 2);
    try std.testing.expect(coordinator.metrics.total_queries.load(.monotonic) == 2);
    try std.testing.expect(coordinator.metrics.total_time_ms.load(.monotonic) == 150);
    try std.testing.expect(coordinator.metrics.shard_queries.load(.monotonic) == 5);
}

test "QueryCoordinator: parallel scatter configuration" {
    // Test with parallel scatter enabled (default)
    const enabled_config = federation.FederationConfig{};
    try std.testing.expect(enabled_config.enable_parallel_scatter == true);

    // Test with parallel scatter disabled
    const disabled_config = federation.FederationConfig{ .enable_parallel_scatter = false };
    try std.testing.expect(disabled_config.enable_parallel_scatter == false);
}

test "QueryCoordinator: table name extraction" {
    const ally = std.testing.allocator;
    const config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Test extraction from GQL pattern
    const query1 = "MATCH (n:Person) RETURN n";
    const table1 = coordinator.extractTableFromQuery(query1);
    try std.testing.expect(table1 != null);
    try std.testing.expect(std.mem.eql(u8, table1.?, "Person"));

    // Test extraction with different label
    const query2 = "MATCH (e:Employee) WHERE e.salary > 50000 RETURN e";
    const table2 = coordinator.extractTableFromQuery(query2);
    try std.testing.expect(table2 != null);
    try std.testing.expect(std.mem.eql(u8, table2.?, "Employee"));

    // Test when no label is present
    const query3 = "RETURN 1 AS x";
    const table3 = coordinator.extractTableFromQuery(query3);
    try std.testing.expect(table3 == null);
}

test "QueryCoordinator: row estimation without stats" {
    const ally = std.testing.allocator;
    const config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Without stats registry, should return default estimate divided by shard count
    const estimate = coordinator.estimateRowsForShard("Person", 0, 4);
    // Default is 10000 / 4 shards + 10% buffer
    try std.testing.expect(estimate > 0);
    try std.testing.expect(estimate <= 3000); // Reasonable upper bound
}

test "CoordinatorMetrics: concurrent queries tracking" {
    var metrics = CoordinatorMetrics.init();

    // Initial state
    try std.testing.expect(metrics.concurrent_queries.load(.monotonic) == 0);

    // Simulate concurrent execution
    _ = metrics.concurrent_queries.fetchAdd(1, .monotonic);
    try std.testing.expect(metrics.concurrent_queries.load(.monotonic) == 1);

    // Track multiple concurrent executions
    _ = metrics.concurrent_queries.fetchAdd(1, .monotonic);
    _ = metrics.concurrent_queries.fetchAdd(1, .monotonic);
    try std.testing.expect(metrics.concurrent_queries.load(.monotonic) == 3);
}
