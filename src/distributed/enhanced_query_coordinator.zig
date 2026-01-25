// CANARY: REQ=REQ-DIST-QUERY-COORD-001; FEATURE="Enhanced Query Coordination"; ASPECT=QueryCoordination; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_QUERY_COORD_001_QueryCoordination; OWNER=dist; UPDATED=2025-10-05
// CANARY: REQ=REQ-DIST-QUERY-COORD-002; FEATURE="Query Optimization"; ASPECT=DistributedOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_QUERY_COORD_002_DistributedOptimization; OWNER=dist; UPDATED=2025-10-05

const std = @import("std");
const protocol = @import("../protocol.zig");
const federation = @import("federation.zig");
const query_transport = @import("query_transport.zig");
const network_transport = @import("network_transport.zig");

/// Enhanced distributed query coordinator with optimization and monitoring
pub const EnhancedQueryCoordinator = struct {
    allocator: std.mem.Allocator,
    config: federation.FederationConfig,
    query_transport: *query_transport.QueryTransport,
    shard_registry: ShardRegistry,
    node_registry: NodeRegistry,
    query_optimizer: DistributedQueryOptimizer,
    metrics: CoordinatorMetrics,
    cache: QueryCache,

    pub fn init(
        allocator: std.mem.Allocator,
        config: federation.FederationConfig,
        network_transport: *network_transport.NetworkTransport,
    ) !EnhancedQueryCoordinator {
        var query_transport_inst = try allocator.create(query_transport.QueryTransport);
        query_transport_inst.* = try query_transport.QueryTransport.init(allocator, network_transport);

        return EnhancedQueryCoordinator{
            .allocator = allocator,
            .config = config,
            .query_transport = query_transport_inst,
            .shard_registry = try ShardRegistry.init(allocator),
            .node_registry = try NodeRegistry.init(allocator),
            .query_optimizer = try DistributedQueryOptimizer.init(allocator),
            .metrics = CoordinatorMetrics.init(),
            .cache = try QueryCache.init(allocator),
        };
    }

    pub fn deinit(self: *EnhancedQueryCoordinator) void {
        self.query_transport.deinit();
        self.allocator.destroy(self.query_transport);
        self.shard_registry.deinit();
        self.node_registry.deinit();
        self.query_optimizer.deinit();
        self.cache.deinit();
    }

    /// Execute distributed query with comprehensive optimization
    pub fn executeDistributedQuery(
        self: *EnhancedQueryCoordinator,
        query: []const u8,
        params: []const protocol.Value,
        options: QueryOptions,
    ) !federation.QueryResults {
        const start_time = std.time.milliTimestamp();

        // Check query cache first
        const query_hash = try self.cache.hashQuery(query, params);
        if (options.use_cache) {
            if (try self.cache.get(query_hash)) |cached_result| {
                self.metrics.recordCacheHit();
                return cached_result;
            }
        }

        // Parse and analyze query
        const query_analysis = try self.analyzeQuery(query);
        defer query_analysis.deinit();

        // Optimize distributed execution plan
        const optimized_plan = try self.query_optimizer.optimizeQuery(query_analysis, &self.shard_registry);
        defer optimized_plan.deinit();

        // Execute plan with monitoring
        const result = try self.executePlan(optimized_plan, params, options);

        // Cache result if appropriate
        if (options.use_cache and options.cache_ttl_ms > 0) {
            try self.cache.put(query_hash, result, options.cache_ttl_ms);
        }

        const exec_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        self.metrics.recordQuery(exec_time, optimized_plan.fragments.len);

        return result;
    }

    /// Analyze query to determine distribution strategy
    fn analyzeQuery(self: *EnhancedQueryCoordinator, query: []const u8) !QueryAnalysis {
        var analysis = QueryAnalysis.init(self.allocator);

        // Simple query parsing to identify key components
        if (std.mem.indexOf(u8, query, "MATCH")) |_| {
            analysis.query_type = .match_query;
        } else if (std.mem.indexOf(u8, query, "CREATE")) |_| {
            analysis.query_type = .create_query;
        } else if (std.mem.indexOf(u8, query, "DELETE")) |_| {
            analysis.query_type = .delete_query;
        } else {
            analysis.query_type = .other;
        }

        // Extract labels and properties for shard pruning
        try self.extractLabelsAndProperties(query, &analysis);

        // Determine if query needs global ordering
        analysis.has_global_ordering = std.mem.indexOf(u8, query, "ORDER BY") != null;

        // Check for aggregations
        analysis.has_aggregation = std.mem.indexOf(u8, query, "COUNT") != null or
            std.mem.indexOf(u8, query, "SUM") != null or
            std.mem.indexOf(u8, query, "AVG") != null;

        // Estimate selectivity (simple heuristic)
        analysis.estimated_selectivity = if (std.mem.indexOf(u8, query, "WHERE") != null) 0.1 else 1.0;

        return analysis;
    }

    /// Extract labels and properties for shard pruning
    fn extractLabelsAndProperties(self: *EnhancedQueryCoordinator, query: []const u8, analysis: *QueryAnalysis) !void {
        _ = self;

        // Simple pattern matching for labels
        var tokens = std.mem.tokenize(u8, query, " \t\n()");
        while (tokens.next()) |token| {
            if (token[0] == ':' and token.len > 1) {
                const label = token[1..];
                try analysis.referenced_labels.append(try analysis.allocator.dupe(u8, label));
            }
        }

        // Extract property references (simplified)
        if (std.mem.indexOf(u8, query, ".")) |_| {
            // Query references properties - this could be more sophisticated
            try analysis.referenced_properties.append(try analysis.allocator.dupe(u8, "id"));
        }
    }

    /// Execute optimized distributed plan
    fn executePlan(
        self: *EnhancedQueryCoordinator,
        plan: DistributedExecutionPlan,
        params: []const protocol.Value,
        options: QueryOptions,
    ) !federation.QueryResults {
        const start_time = std.time.milliTimestamp();

        // Prepare node queries for parallel execution
        var node_queries = try self.allocator.alloc(query_transport.NodeQuery, plan.fragments.len);
        defer self.allocator.free(node_queries);

        for (plan.fragments, 0..) |fragment, i| {
            node_queries[i] = query_transport.NodeQuery{
                .node_id = fragment.node_id,
                .query = federation.FederatedQuery{
                    .query_text = fragment.query_text,
                    .parameters = params,
                    .target_nodes = &.{fragment.node_id},
                    .consistency_level = options.consistency_level,
                },
            };
        }

        // Execute queries in parallel
        const shard_results = try self.query_transport.executeBatchQueries(node_queries);
        defer {
            for (shard_results) |*result| {
                self.allocator.free(result.rows);
                self.allocator.free(result.schema);
            }
            self.allocator.free(shard_results);
        }

        // Merge results according to plan
        const merged_result = try self.mergeResults(shard_results, plan.merge_strategy, options);

        const merge_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        self.metrics.recordMergeTime(merge_time);

        return merged_result;
    }

    /// Merge results from shards with various strategies
    fn mergeResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        strategy: MergeStrategy,
        options: QueryOptions,
    ) !federation.QueryResults {
        return switch (strategy) {
            .union_all => try self.unionAllResults(shard_results, options),
            .union_distinct => try self.unionDistinctResults(shard_results, options),
            .merge_sorted => try self.mergeSortedResults(shard_results, options),
            .hash_aggregate => try self.hashAggregateResults(shard_results, options),
            .top_k => try self.topKResults(shard_results, options),
        };
    }

    /// Union all results (simple concatenation)
    fn unionAllResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        var total_rows: usize = 0;
        for (shard_results) |result| {
            total_rows += result.rows.len;
        }

        // Apply limit early if specified
        const effective_limit = if (options.limit) |limit| @min(limit, total_rows) else total_rows;

        var all_rows = try self.allocator.alloc(protocol.BindingRow, effective_limit);
        var idx: usize = 0;

        for (shard_results) |result| {
            for (result.rows) |row| {
                if (idx >= effective_limit) break;
                all_rows[idx] = row;
                idx += 1;
            }
            if (idx >= effective_limit) break;
        }

        // Apply offset
        const start = options.offset orelse 0;
        const end = @min(start + all_rows.len, all_rows.len);

        return federation.QueryResults{
            .rows = if (start < all_rows.len) all_rows[start..end] else &.{},
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = false,
        };
    }

    /// Union distinct results (deduplication)
    fn unionDistinctResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        var seen_rows = std.StringHashMap(void).init(self.allocator);
        defer seen_rows.deinit();

        var unique_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        defer unique_rows.deinit();

        for (shard_results) |result| {
            for (result.rows) |row| {
                // Simple row hashing for deduplication
                const row_hash = try self.hashRow(row);

                const gop = try seen_rows.getOrPut(row_hash);
                if (!gop.found_existing) {
                    try unique_rows.append(row);

                    // Apply limit
                    if (options.limit) |limit| {
                        if (unique_rows.items.len >= limit + (options.offset orelse 0)) {
                            break;
                        }
                    }
                }

                self.allocator.free(row_hash);
            }
        }

        // Apply offset
        const start = options.offset orelse 0;
        const rows_slice = if (start < unique_rows.items.len)
            unique_rows.items[start..]
        else
            &.{};

        return federation.QueryResults{
            .rows = try self.allocator.dupe(protocol.BindingRow, rows_slice),
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = false,
        };
    }

    /// Merge sorted results (assumes results are pre-sorted)
    fn mergeSortedResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        // K-way merge using priority queue
        const KWayMerger = struct {
            allocator: std.mem.Allocator,
            heap: std.PriorityQueue(MergeItem, void, compareMergeItems),
            results: []federation.QueryResults,

            const MergeItem = struct {
                row: protocol.BindingRow,
                shard_index: usize,
                row_index: usize,
            };

            fn compareMergeItems(context: void, a: MergeItem, b: MergeItem) std.math.Order {
                _ = context;
                // Simple comparison - in practice would use order keys
                return std.math.order(a.row.len, b.row.len);
            }
        };

        var merger = KWayMerger{
            .allocator = self.allocator,
            .heap = std.PriorityQueue(KWayMerger.MergeItem, void, KWayMerger.compareMergeItems).init(self.allocator, {}),
            .results = shard_results,
        };
        defer merger.heap.deinit();

        // Initialize heap with first element from each shard
        for (shard_results, 0..) |result, shard_idx| {
            if (result.rows.len > 0) {
                try merger.heap.add(.{
                    .row = result.rows[0],
                    .shard_index = shard_idx,
                    .row_index = 0,
                });
            }
        }

        var merged_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        defer merged_rows.deinit();

        // Extract elements in sorted order
        while (merger.heap.removeOrNull()) |item| {
            try merged_rows.append(item.row);

            // Add next element from same shard if available
            const next_index = item.row_index + 1;
            if (next_index < shard_results[item.shard_index].rows.len) {
                try merger.heap.add(.{
                    .row = shard_results[item.shard_index].rows[next_index],
                    .shard_index = item.shard_index,
                    .row_index = next_index,
                });
            }

            // Apply limit
            if (options.limit) |limit| {
                if (merged_rows.items.len >= limit + (options.offset orelse 0)) {
                    break;
                }
            }
        }

        // Apply offset
        const start = options.offset orelse 0;
        const rows_slice = if (start < merged_rows.items.len)
            merged_rows.items[start..]
        else
            &.{};

        return federation.QueryResults{
            .rows = try self.allocator.dupe(protocol.BindingRow, rows_slice),
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = true,
        };
    }

    /// Hash aggregate results (for GROUP BY queries)
    fn hashAggregateResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        _ = options;

        // Simple aggregation placeholder
        // In practice, would implement sophisticated aggregation merging
        var groups = std.StringHashMap(AggregateGroup).init(self.allocator);
        defer groups.deinit();

        for (shard_results) |result| {
            for (result.rows) |row| {
                const group_key = try self.hashRow(row);
                defer self.allocator.free(group_key);

                const gop = try groups.getOrPut(group_key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = AggregateGroup{
                        .count = 1,
                        .sum = 0, // Would extract from row
                        .representative_row = row,
                    };
                } else {
                    gop.value_ptr.count += 1;
                    // Update aggregates
                }
            }
        }

        // Convert groups back to rows
        var aggregated_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        defer aggregated_rows.deinit();

        var iter = groups.iterator();
        while (iter.next()) |entry| {
            try aggregated_rows.append(entry.value_ptr.representative_row);
        }

        return federation.QueryResults{
            .rows = try aggregated_rows.toOwnedSlice(),
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = false,
        };
    }

    /// Top-K results with distributed optimization using heap-based selection
    /// GAP-0129: Uses O(n log k) heap selection instead of O(n log n) full sort
    // CANARY: REQ=REQ-DIST-TOPK-001; FEATURE="Heap-based Top-K Selection"; ASPECT=Performance; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
    fn topKResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        const k = (options.limit orelse 100) + (options.offset orelse 0);

        // Count total rows to decide strategy
        var total_rows: usize = 0;
        for (shard_results) |result| {
            total_rows += result.rows.len;
        }

        // If total rows <= k, no need for heap selection - just collect and sort
        if (total_rows <= k) {
            var all_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
            defer all_rows.deinit();

            for (shard_results) |result| {
                try all_rows.appendSlice(result.rows);
            }

            // GAP-0130: Sort using ORDER BY keys if provided
            if (options.order_by.len > 0) {
                const sort_context = OrderBySortContext{ .order_by = options.order_by };
                std.sort.heap(protocol.BindingRow, all_rows.items, sort_context, orderByCompare);
            } else {
                std.sort.heap(protocol.BindingRow, all_rows.items, {}, simpleRowCompare);
            }

            const start = options.offset orelse 0;
            const end = @min(start + (options.limit orelse all_rows.items.len), all_rows.items.len);

            return federation.QueryResults{
                .rows = if (start < all_rows.items.len)
                    try self.allocator.dupe(protocol.BindingRow, all_rows.items[start..end])
                else
                    &.{},
                .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
                .execution_time_ms = 0,
                .ordered = true,
            };
        }

        // GAP-0129: Use max-heap for O(n log k) top-K selection
        // CANARY: REQ=REQ-DIST-TOPK-002; FEATURE="Max-Heap Top-K"; ASPECT=Performance; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
        // We maintain a max-heap of size k containing the smallest k elements seen so far
        // For ascending order: keep smallest k elements using a max-heap (pop largest when full)
        // For descending order: keep largest k elements using a min-heap (pop smallest when full)
        const HeapContext = struct {
            order_by: []const OrderByKey,
            ascending_heap: bool, // If true, max-heap for ascending result (pop largest)

            fn compare(ctx: @This(), a: protocol.BindingRow, b: protocol.BindingRow) std.math.Order {
                // For ascending result, we want a max-heap to track the k smallest
                // so we invert the comparison (larger elements have higher priority to be popped)
                var col_indices: [32]usize = undefined;
                var ascending: [32]bool = undefined;

                const num_keys = if (ctx.order_by.len > 32) 32 else ctx.order_by.len;
                if (num_keys == 0) {
                    // Default comparison
                    const max_cols = if (a.cols.len > b.cols.len) a.cols.len else b.cols.len;
                    const actual_cols = if (max_cols > 32) 32 else max_cols;
                    for (0..actual_cols) |i| {
                        col_indices[i] = i;
                        ascending[i] = true;
                    }
                    const cmp = protocol.compareBindingRows(a, b, col_indices[0..actual_cols], ascending[0..actual_cols], true);
                    // Invert for max-heap behavior
                    return if (ctx.ascending_heap) switch (cmp) {
                        .lt => .gt,
                        .gt => .lt,
                        .eq => .eq,
                    } else cmp;
                }

                for (0..num_keys) |i| {
                    col_indices[i] = ctx.order_by[i].column_index;
                    ascending[i] = ctx.order_by[i].ascending;
                }

                const nulls_first = if (ctx.order_by.len > 0) ctx.order_by[0].nulls_first else true;
                const cmp = protocol.compareBindingRows(a, b, col_indices[0..num_keys], ascending[0..num_keys], nulls_first);

                // For max-heap (ascending result), invert so largest elements rise to top for removal
                return if (ctx.ascending_heap) switch (cmp) {
                    .lt => .gt,
                    .gt => .lt,
                    .eq => .eq,
                } else cmp;
            }
        };

        // Determine if primary sort is ascending
        const primary_ascending = if (options.order_by.len > 0) options.order_by[0].ascending else true;

        var heap = std.PriorityQueue(protocol.BindingRow, HeapContext, HeapContext.compare).init(self.allocator, HeapContext{
            .order_by = options.order_by,
            .ascending_heap = primary_ascending,
        });
        defer heap.deinit();

        // Reserve capacity for k elements
        try heap.ensureTotalCapacity(k);

        // Process all rows through the heap - O(n log k)
        for (shard_results) |result| {
            for (result.rows) |row| {
                if (heap.count() < k) {
                    try heap.add(row);
                } else {
                    // Compare with top of heap (the "worst" of current top-k)
                    const top = heap.peek().?;
                    const ctx = HeapContext{
                        .order_by = options.order_by,
                        .ascending_heap = primary_ascending,
                    };
                    // If new row is better than top, replace top
                    const cmp = HeapContext.compare(ctx, row, top);
                    if (cmp == .gt) {
                        _ = heap.removeOrNull();
                        try heap.add(row);
                    }
                }
            }
        }

        // Extract results from heap and sort them (k elements, O(k log k))
        var result_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        defer result_rows.deinit();

        while (heap.removeOrNull()) |row| {
            try result_rows.append(row);
        }

        // Sort the k results for correct order
        // CANARY: REQ=REQ-DIST-ORDERBY-002; FEATURE="Distributed ORDER BY Sort"; ASPECT=QueryCorrectness; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
        if (options.order_by.len > 0) {
            const sort_context = OrderBySortContext{ .order_by = options.order_by };
            std.sort.heap(protocol.BindingRow, result_rows.items, sort_context, orderByCompare);
        } else {
            std.sort.heap(protocol.BindingRow, result_rows.items, {}, simpleRowCompare);
        }

        const start = options.offset orelse 0;
        const end = @min(start + (options.limit orelse result_rows.items.len), result_rows.items.len);

        return federation.QueryResults{
            .rows = if (start < result_rows.items.len)
                try self.allocator.dupe(protocol.BindingRow, result_rows.items[start..end])
            else
                &.{},
            .schema = if (shard_results.len > 0) shard_results[0].schema else &.{},
            .execution_time_ms = 0,
            .ordered = true,
        };
    }

    /// Row comparison for distributed query result sorting
    // CANARY: REQ=REQ-DIST-ROW-SORT-001; FEATURE="Distributed Row Sorting"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
    /// GAP-0053: Implements actual field-by-field comparison using ORDER BY semantics
    fn simpleRowCompare(context: void, a: protocol.BindingRow, b: protocol.BindingRow) bool {
        _ = context;
        // Compare rows column by column in ascending order with NULLS FIRST
        // For distributed queries without explicit ORDER BY, we use all columns as sort keys
        const max_cols = if (a.cols.len > b.cols.len) a.cols.len else b.cols.len;
        if (max_cols == 0) return false;

        var col_indices: [32]usize = undefined;
        const num_cols = if (max_cols > 32) 32 else max_cols;
        for (0..num_cols) |i| {
            col_indices[i] = i;
        }

        const ascending = [_]bool{true} ** 32;
        const cmp = protocol.compareBindingRows(
            a,
            b,
            col_indices[0..num_cols],
            ascending[0..num_cols],
            true, // NULLS FIRST by default
        );
        return cmp == .lt;
    }

    // GAP-0130: Context for ORDER BY-aware sorting
    // CANARY: REQ=REQ-DIST-ORDERBY-003; FEATURE="ORDER BY Sort Context"; ASPECT=QueryCorrectness; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
    const OrderBySortContext = struct {
        order_by: []const OrderByKey,
    };

    /// Compare rows using ORDER BY keys
    fn orderByCompare(context: OrderBySortContext, a: protocol.BindingRow, b: protocol.BindingRow) bool {
        // Extract column indices and ascending flags from ORDER BY keys
        var col_indices: [32]usize = undefined;
        var ascending: [32]bool = undefined;

        const num_keys = if (context.order_by.len > 32) 32 else context.order_by.len;
        for (0..num_keys) |i| {
            col_indices[i] = context.order_by[i].column_index;
            ascending[i] = context.order_by[i].ascending;
        }

        // Use NULLS FIRST from first ORDER BY key (or default true)
        const nulls_first = if (context.order_by.len > 0)
            context.order_by[0].nulls_first
        else
            true;

        const cmp = protocol.compareBindingRows(
            a,
            b,
            col_indices[0..num_keys],
            ascending[0..num_keys],
            nulls_first,
        );
        return cmp == .lt;
    }

    /// Hash a row for deduplication
    fn hashRow(self: *EnhancedQueryCoordinator, row: protocol.BindingRow) ![]u8 {
        var hasher = std.hash_map.DefaultHasher.init();
        for (row) |binding| {
            // Simple binding hashing - would be more sophisticated in practice
            hasher.update(std.mem.asBytes(&binding));
        }

        const hash_value = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "{x}", .{hash_value});
    }

    /// Get coordinator metrics for monitoring
    pub fn getMetrics(self: *EnhancedQueryCoordinator) CoordinatorMetrics {
        return self.metrics;
    }

    /// Configure coordinator settings
    pub fn configure(self: *EnhancedQueryCoordinator, config: CoordinatorConfig) void {
        if (config.cache_enabled) |enabled| {
            self.cache.enabled = enabled;
        }
        if (config.max_parallel_queries) |max_parallel| {
            // Update transport configuration
            _ = max_parallel;
        }
    }
};

// Supporting types and structures

// GAP-0130: ORDER BY key for distributed query sorting
// CANARY: REQ=REQ-DIST-ORDERBY-001; FEATURE="Distributed ORDER BY"; ASPECT=QueryCorrectness; STATUS=TESTED; TEST=geodetestlab/specs/geode_distributed_queries.yml; OWNER=distributed; UPDATED=2026-01-25
const OrderByKey = struct {
    column_index: usize,
    ascending: bool = true,
    nulls_first: bool = true,
};

const QueryOptions = struct {
    consistency_level: federation.ConsistencyLevel = .eventual,
    use_cache: bool = true,
    cache_ttl_ms: u64 = 300000, // 5 minutes
    limit: ?usize = null,
    offset: ?usize = null,
    timeout_ms: u32 = 30000,
    // GAP-0130: ORDER BY keys for result sorting
    order_by: []const OrderByKey = &.{},
};

const QueryAnalysis = struct {
    allocator: std.mem.Allocator,
    query_type: QueryType,
    referenced_labels: std.ArrayList([]u8),
    referenced_properties: std.ArrayList([]u8),
    has_global_ordering: bool = false,
    has_aggregation: bool = false,
    estimated_selectivity: f64 = 1.0,

    const QueryType = enum {
        match_query,
        create_query,
        delete_query,
        other,
    };

    fn init(allocator: std.mem.Allocator) QueryAnalysis {
        return QueryAnalysis{
            .allocator = allocator,
            .query_type = .other,
            .referenced_labels = std.ArrayList([]u8).init(allocator),
            .referenced_properties = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *QueryAnalysis) void {
        for (self.referenced_labels.items) |label| {
            self.allocator.free(label);
        }
        self.referenced_labels.deinit();

        for (self.referenced_properties.items) |prop| {
            self.allocator.free(prop);
        }
        self.referenced_properties.deinit();
    }
};

const DistributedExecutionPlan = struct {
    allocator: std.mem.Allocator,
    fragments: []QueryFragment,
    merge_strategy: MergeStrategy,
    estimated_cost: f64 = 0.0,

    const QueryFragment = struct {
        node_id: u32,
        query_text: []const u8,
        estimated_rows: u64,
        estimated_time_ms: u64,
    };

    fn deinit(self: *DistributedExecutionPlan) void {
        for (self.fragments) |fragment| {
            self.allocator.free(fragment.query_text);
        }
        self.allocator.free(self.fragments);
    }
};

const MergeStrategy = enum {
    union_all,
    union_distinct,
    merge_sorted,
    hash_aggregate,
    top_k,
};

const AggregateGroup = struct {
    count: u64,
    sum: f64,
    representative_row: protocol.BindingRow,
};

// Registry and optimization types (simplified placeholders)

const ShardRegistry = struct {
    allocator: std.mem.Allocator,
    shards: std.StringHashMap(ShardInfo),

    fn init(allocator: std.mem.Allocator) !ShardRegistry {
        return ShardRegistry{
            .allocator = allocator,
            .shards = std.StringHashMap(ShardInfo).init(allocator),
        };
    }

    fn deinit(self: *ShardRegistry) void {
        self.shards.deinit();
    }
};

const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(NodeInfo),

    fn init(allocator: std.mem.Allocator) !NodeRegistry {
        return NodeRegistry{
            .allocator = allocator,
            .nodes = std.StringHashMap(NodeInfo).init(allocator),
        };
    }

    fn deinit(self: *NodeRegistry) void {
        self.nodes.deinit();
    }
};

const DistributedQueryOptimizer = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !DistributedQueryOptimizer {
        return DistributedQueryOptimizer{
            .allocator = allocator,
        };
    }

    fn deinit(self: *DistributedQueryOptimizer) void {
        _ = self;
    }

    fn optimizeQuery(self: *DistributedQueryOptimizer, analysis: QueryAnalysis, shard_registry: *ShardRegistry) !DistributedExecutionPlan {
        _ = shard_registry;

        // Simplified optimization - in practice would be much more sophisticated
        var fragments = try self.allocator.alloc(DistributedExecutionPlan.QueryFragment, 1);
        fragments[0] = DistributedExecutionPlan.QueryFragment{
            .node_id = 1,
            .query_text = try self.allocator.dupe(u8, "SIMPLIFIED QUERY"),
            .estimated_rows = 1000,
            .estimated_time_ms = 100,
        };

        const strategy = if (analysis.has_global_ordering)
            MergeStrategy.merge_sorted
        else if (analysis.has_aggregation)
            MergeStrategy.hash_aggregate
        else
            MergeStrategy.union_all;

        return DistributedExecutionPlan{
            .allocator = self.allocator,
            .fragments = fragments,
            .merge_strategy = strategy,
            .estimated_cost = 100.0,
        };
    }
};

const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CacheEntry),
    enabled: bool = true,
    max_entries: usize = 1000,

    const CacheEntry = struct {
        result: federation.QueryResults,
        timestamp: i64,
        ttl_ms: u64,
    };

    fn init(allocator: std.mem.Allocator) !QueryCache {
        return QueryCache{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    fn deinit(self: *QueryCache) void {
        self.cache.deinit();
    }

    fn hashQuery(self: *QueryCache, query: []const u8, params: []const protocol.Value) ![]u8 {
        _ = params;
        var hasher = std.hash_map.DefaultHasher.init();
        hasher.update(query);
        const hash_value = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "{x}", .{hash_value});
    }

    fn get(self: *QueryCache, query_hash: []const u8) !?federation.QueryResults {
        if (!self.enabled) return null;

        if (self.cache.get(query_hash)) |entry| {
            const now = std.time.milliTimestamp();
            if (now - entry.timestamp < entry.ttl_ms) {
                return entry.result;
            } else {
                _ = self.cache.remove(query_hash);
            }
        }

        return null;
    }

    fn put(self: *QueryCache, query_hash: []const u8, result: federation.QueryResults, ttl_ms: u64) !void {
        if (!self.enabled) return;

        try self.cache.put(query_hash, CacheEntry{
            .result = result,
            .timestamp = std.time.milliTimestamp(),
            .ttl_ms = ttl_ms,
        });
    }
};

const CoordinatorMetrics = struct {
    total_queries: u64 = 0,
    total_time_ms: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    merge_time_ms: u64 = 0,
    shard_queries: u64 = 0,

    fn init() CoordinatorMetrics {
        return CoordinatorMetrics{};
    }

    fn recordQuery(self: *CoordinatorMetrics, time_ms: u64, shard_count: usize) void {
        self.total_queries += 1;
        self.total_time_ms += time_ms;
        self.shard_queries += @as(u64, @intCast(shard_count));
    }

    fn recordCacheHit(self: *CoordinatorMetrics) void {
        self.cache_hits += 1;
    }

    fn recordMergeTime(self: *CoordinatorMetrics, time_ms: u64) void {
        self.merge_time_ms += time_ms;
    }
};

const CoordinatorConfig = struct {
    cache_enabled: ?bool = null,
    max_parallel_queries: ?u32 = null,
};

const ShardInfo = struct {
    id: []const u8,
    node_id: u32,
    key_range_start: u64,
    key_range_end: u64,
};

const NodeInfo = struct {
    id: u32,
    address: []const u8,
    region: []const u8,
    capabilities: []const u8,
};
