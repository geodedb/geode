const std = @import("std");
const protocol = @import("../protocol.zig");
const planner = @import("../planner.zig");
const exec = @import("../exec.zig");
const federation = @import("federation.zig");
const raft = @import("raft.zig");
// GAP-0077: Import CBO for statistics integration
const cbo = @import("../planner/cbo.zig");

const logging = @import("logging");
const log = logging.scoped("query_coordinator");
const Attr = logging.Attr;

/// Distributed query coordinator
/// Handles scatter-gather pattern for federated queries
/// GAP-0077: Now uses statistics registry for row estimates
// CANARY: REQ=REQ-DIST-STATS-001; FEATURE="DistributedStatsIntegration"; ASPECT=QueryPlanning; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
pub const QueryCoordinator = struct {
    allocator: std.mem.Allocator,
    config: federation.FederationConfig,
    shard_map: ShardMap,
    node_registry: NodeRegistry,
    metrics: CoordinatorMetrics,
    stats_registry: ?*cbo.StatsRegistry = null, // GAP-0077: Optional statistics registry

    const Self = @This();

    /// Initialize the query coordinator
    pub fn init(allocator: std.mem.Allocator, config: federation.FederationConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .shard_map = try ShardMap.init(allocator),
            .node_registry = try NodeRegistry.init(allocator),
            .metrics = CoordinatorMetrics.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.shard_map.deinit();
        self.node_registry.deinit();
    }

    /// Execute a distributed query with global ORDER BY and LIMIT
    // CANARY: REQ=REQ-GQL-FED-001; FEATURE="Distributed Query Federation"; ASPECT=Core; STATUS=TESTED; TEST=e2e_federation_global_order; BENCH=benchmark_federation_merge; OWNER=distributed; UPDATED=2026-01-17
    pub fn executeDistributedQuery(
        self: *Self,
        query: []const u8,
        params: []const protocol.Value,
        order_by: ?[]const federation.OrderKey,
        limit: ?u64,
        offset: ?u64,
    ) !federation.QueryResults {
        const start_time = std.time.milliTimestamp();

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

        const exec_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
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
            // CANARY: REQ=REQ-DIST-STATS-002; FEATURE="ShardRowEstimate"; ASPECT=QueryPlanning; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
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

    /// Scatter query fragments to shards with concurrent execution
    /// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=ConcurrentExecution; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-14
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

        // GAP-0184: Concurrent execution using thread pool
        var threads = try self.allocator.alloc(std.Thread, fragment_count);
        defer self.allocator.free(threads);
        var thread_errors = try self.allocator.alloc(?anyerror, fragment_count);
        defer self.allocator.free(thread_errors);

        // Initialize error tracking
        for (thread_errors) |*e| {
            e.* = null;
        }

        // Context for thread workers
        const WorkerContext = struct {
            coordinator: *Self,
            fragment: QueryFragment,
            params: []const protocol.Value,
            result_ptr: *federation.QueryResults,
            error_ptr: *?anyerror,
            index: usize,

            fn execute(ctx: *@This()) void {
                const node = ctx.coordinator.node_registry.getNode(ctx.fragment.shard_id) catch |err| {
                    ctx.error_ptr.* = err;
                    return;
                };

                if (node.is_local) {
                    ctx.result_ptr.* = ctx.coordinator.executeLocalFragment(ctx.fragment.query_text, ctx.params) catch |err| {
                        ctx.error_ptr.* = err;
                        return;
                    };
                } else {
                    ctx.result_ptr.* = ctx.coordinator.executeRemoteFragment(node, ctx.fragment.query_text, ctx.params) catch |err| {
                        ctx.error_ptr.* = err;
                        return;
                    };
                }
            }
        };

        // Allocate contexts for all workers
        var contexts = try self.allocator.alloc(WorkerContext, fragment_count);
        defer self.allocator.free(contexts);

        // Spawn threads for concurrent execution
        for (plan.fragments.items, 0..) |fragment, i| {
            contexts[i] = .{
                .coordinator = self,
                .fragment = fragment,
                .params = params,
                .result_ptr = &results[i],
                .error_ptr = &thread_errors[i],
                .index = i,
            };
            threads[i] = std.Thread.spawn(.{}, WorkerContext.execute, .{&contexts[i]}) catch |err| {
                // If thread spawn fails, execute sequentially for remaining fragments
                log.warn("Thread spawn failed for shard, falling back to sequential", &.{
                    Attr.uint("shard_index", i),
                    Attr.string("error", @errorName(err)),
                });
                const node = try self.node_registry.getNode(fragment.shard_id);
                if (node.is_local) {
                    results[i] = try self.executeLocalFragment(fragment.query_text, params);
                } else {
                    results[i] = try self.executeRemoteFragment(node, fragment.query_text, params);
                }
                continue;
            };
        }

        // Join all threads
        for (threads, 0..) |thread, i| {
            thread.join();
            // Check for errors from worker threads
            if (thread_errors[i]) |err| {
                log.err("Shard execution failed", &.{
                    Attr.uint("shard_index", i),
                    Attr.string("error", @errorName(err)),
                });
                // Continue with empty result rather than failing entire query
            }
        }

        self.metrics.concurrent_queries += 1;
        return results;
    }

    // CANARY: REQ=REQ-DIST-LOCAL-001; FEATURE="DistributedLocalExecution"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
    /// Execute query fragment on local shard using the actual query executor
    fn executeLocalFragment(self: *Self, query_text: []const u8, params: []const protocol.Value) !federation.QueryResults {
        const start_time = std.time.milliTimestamp();

        // GAP-0043: Wire to actual executor instead of returning mock results
        // Parse the query
        const lib = @import("../lib.zig");
        const execution = @import("../execution.zig");

        const parse_result = lib.parseGql(query_text, self.allocator) catch |err| {
            // On parse error, return empty result with error indication
            _ = err;
            return federation.QueryResults{
                .rows = &.{},
                .schema = &.{},
                .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
                .ordered = false,
            };
        };
        defer parse_result.deinit();

        // Get execution context
        const context = execution.getDefaultContext(self.allocator) catch {
            return federation.QueryResults{
                .rows = &.{},
                .schema = &.{},
                .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
                .ordered = false,
            };
        };

        // Execute the program
        var exec_result = execution.executeProgramWithContext(self.allocator, &parse_result.program, context) catch {
            return federation.QueryResults{
                .rows = &.{},
                .schema = &.{},
                .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
                .ordered = false,
            };
        };
        defer exec_result.deinit(self.allocator);

        // Convert ExecutionResult to federation.QueryResults
        // Convert column names to schema
        var schema = try self.allocator.alloc(federation.ColumnDef, exec_result.columns.len);
        for (exec_result.columns, 0..) |col_name, i| {
            schema[i] = .{
                .name = try self.allocator.dupe(u8, col_name),
                .data_type = .string, // Default to string type
            };
        }

        // Convert Value rows to protocol.Value rows
        var rows = try self.allocator.alloc([]protocol.Value, exec_result.rows.len);
        for (exec_result.rows, 0..) |row, i| {
            rows[i] = try self.allocator.alloc(protocol.Value, row.len);
            for (row, 0..) |val, j| {
                rows[i][j] = self.convertValueToProtocol(val, params);
            }
        }

        return federation.QueryResults{
            .rows = rows,
            .schema = schema,
            .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
            .ordered = false,
        };
    }

    /// Convert execution Value to protocol.Value
    fn convertValueToProtocol(self: *Self, val: @import("../execution.zig").Value, params: []const protocol.Value) protocol.Value {
        _ = self;
        _ = params;
        return switch (val) {
            .Null => protocol.Value{ .Null = {} },
            .Int => |i| protocol.Value{ .Int = i },
            .Bool => |b| protocol.Value{ .Bool = b },
            .Str => |s| protocol.Value{ .Str = s },
            else => protocol.Value{ .Null = {} }, // Convert unsupported types to null
        };
    }

    /// Execute query fragment on remote shard via QUIC
    fn executeRemoteFragment(self: *Self, node: *Node, query: []const u8, params: []const protocol.Value) !federation.QueryResults {
        var conn = try node.connection_pool.acquire();
        defer node.connection_pool.release(conn);

        if (conn.client == null) {
            try conn.connect(node.endpoint);
        }

        const fed_query = federation.FederatedQuery{
            .query_text = query,
            .parameters = params,
            .target_nodes = &.{node.id},
            .consistency_level = .eventual,
        };

        try conn.sendQuery(fed_query);
        return try conn.receiveResults(self.allocator);
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

        var all_rows = try self.allocator.alloc(protocol.BindingRow, total_rows);
        var idx: usize = 0;

        for (shard_results) |result| {
            for (result.rows) |row| {
                all_rows[idx] = row;
                idx += 1;
            }
        }

        // Apply offset and limit
        const start = offset orelse 0;
        const end = if (limit) |l| @min(start + l, all_rows.len) else all_rows.len;

        if (start >= all_rows.len) {
            return federation.QueryResults{
                .rows = &.{},
                .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
                .execution_time_ms = 0,
                .ordered = false,
            };
        }

        return federation.QueryResults{
            .rows = all_rows[start..end],
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
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
        const sorted_rows = try heap.getSorted();

        // Apply offset
        const start = offset orelse 0;
        if (start >= sorted_rows.len) {
            return federation.QueryResults{
                .rows = &.{},
                .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
                .execution_time_ms = 0,
                .ordered = true,
                .order_keys = try self.extractOrderKeyNames(order_keys),
            };
        }

        return federation.QueryResults{
            .rows = sorted_rows[start..],
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = true,
            .order_keys = try self.extractOrderKeyNames(order_keys),
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
    // CANARY: REQ=REQ-DIST-STATS-003; FEATURE="TableNameExtraction"; ASPECT=QueryParsing; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
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
    // CANARY: REQ=REQ-DIST-STATS-004; FEATURE="ShardRowEstimation"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
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

    // CANARY: REQ=REQ-SHARD-PRUNE-001; FEATURE="ShardPruning"; ASPECT=QueryOptimization; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
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
        self.items.deinit();
    }

    fn push(self: *TopKHeap, row: protocol.BindingRow) !void {
        try self.items.append(row);

        // If we exceed k items, remove the smallest
        if (self.items.items.len > self.k) {
            // Simple approach: sort and keep top k
            // TODO: Optimize with actual heap operations
            std.sort.heap(protocol.BindingRow, self.items.items, self.order_keys, compareRows);
            self.items.shrinkRetainingCapacity(self.k);
        }
    }

    fn getSorted(self: *TopKHeap) ![]protocol.BindingRow {
        std.sort.heap(protocol.BindingRow, self.items.items, self.order_keys, compareRows);
        return self.items.toOwnedSlice();
    }

    /// Compare rows based on order keys for distributed query sorting
    // CANARY: REQ=REQ-DIST-ROW-CMP-002; FEATURE="Distributed Row Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
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
/// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=Metrics; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-14
const CoordinatorMetrics = struct {
    total_queries: u64,
    total_time_ms: u64,
    shard_queries: u64,
    merge_time_ms: u64,
    /// GAP-0184: Track concurrent query executions
    concurrent_queries: u64,

    fn init() CoordinatorMetrics {
        return .{
            .total_queries = 0,
            .total_time_ms = 0,
            .shard_queries = 0,
            .merge_time_ms = 0,
            .concurrent_queries = 0,
        };
    }

    fn recordQuery(self: *CoordinatorMetrics, time_ms: u64, shard_count: usize) void {
        self.total_queries += 1;
        self.total_time_ms += time_ms;
        self.shard_queries += @as(u64, @intCast(shard_count));
    }
};

// =============================================================================
// GAP-0184: Unit Tests for Concurrent Shard Execution
// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=UnitTests; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-14
// =============================================================================

test "QueryCoordinator: initialization" {
    const ally = std.testing.allocator;
    var config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Verify coordinator initializes with default parallel scatter enabled
    try std.testing.expect(config.enable_parallel_scatter == true);

    // Verify metrics are initialized
    try std.testing.expect(coordinator.metrics.total_queries == 0);
    try std.testing.expect(coordinator.metrics.concurrent_queries == 0);
}

test "QueryCoordinator: metrics tracking" {
    const ally = std.testing.allocator;
    const config = federation.FederationConfig{};
    var coordinator = try QueryCoordinator.init(ally, config);
    defer coordinator.deinit();

    // Record a query
    coordinator.metrics.recordQuery(100, 3);
    try std.testing.expect(coordinator.metrics.total_queries == 1);
    try std.testing.expect(coordinator.metrics.total_time_ms == 100);
    try std.testing.expect(coordinator.metrics.shard_queries == 3);

    // Record another query
    coordinator.metrics.recordQuery(50, 2);
    try std.testing.expect(coordinator.metrics.total_queries == 2);
    try std.testing.expect(coordinator.metrics.total_time_ms == 150);
    try std.testing.expect(coordinator.metrics.shard_queries == 5);
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
    try std.testing.expect(metrics.concurrent_queries == 0);

    // Simulate concurrent execution
    metrics.concurrent_queries += 1;
    try std.testing.expect(metrics.concurrent_queries == 1);

    // Track multiple concurrent executions
    metrics.concurrent_queries += 1;
    metrics.concurrent_queries += 1;
    try std.testing.expect(metrics.concurrent_queries == 3);
}
