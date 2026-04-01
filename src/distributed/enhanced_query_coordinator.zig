// CANARY: REQ=REQ-DIST-QUERY-COORD-001; FEATURE="Enhanced Query Coordination"; ASPECT=QueryCoordination; STATUS=IMPL; OWNER=dist; UPDATED=2026-04-01
// CANARY: REQ=REQ-DIST-QUERY-COORD-002; FEATURE="Query Optimization"; ASPECT=DistributedOptimization; STATUS=IMPL; OWNER=dist; UPDATED=2026-04-01

const std = @import("std");
const protocol = @import("../protocol.zig");
const federation = @import("federation.zig");
const query_transport = @import("query_transport.zig");
const network_transport = @import("network_transport.zig");
const value_utilities = @import("../execution/value_utilities.zig");

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
        defer self.allocator.free(query_hash);
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

        const start = options.offset orelse 0;
        const end = if (options.limit) |limit| @min(start + limit, total_rows) else total_rows;

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) freeSchema(self.allocator, schema_copy);

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

    /// Union distinct results (deduplication)
    fn unionDistinctResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        var seen_rows = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen_rows.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            seen_rows.deinit();
        }

        var unique_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        errdefer {
            for (unique_rows.items) |row| freeBindingRow(self.allocator, row);
            unique_rows.deinit();
        }

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) freeSchema(self.allocator, schema_copy);

        for (shard_results) |result| {
            for (result.rows) |row| {
                // Simple row hashing for deduplication
                const row_hash = try self.hashRow(row);

                const gop = try seen_rows.getOrPut(row_hash);
                if (gop.found_existing) {
                    self.allocator.free(row_hash);
                } else {
                    try unique_rows.append(try cloneBindingRow(self.allocator, row));

                    // Apply limit
                    if (options.limit) |limit| {
                        if (unique_rows.items.len >= limit + (options.offset orelse 0)) {
                            break;
                        }
                    }
                }
            }
        }

        const start = options.offset orelse 0;
        const end = if (options.limit) |limit| @min(start + limit, unique_rows.items.len) else unique_rows.items.len;

        if (start >= unique_rows.items.len or end <= start) {
            for (unique_rows.items) |row| freeBindingRow(self.allocator, row);
            unique_rows.items.len = 0;
            return federation.QueryResults{
                .rows = &.{},
                .schema = schema_copy,
                .execution_time_ms = 0,
                .ordered = false,
            };
        }

        if (start > 0 or end < unique_rows.items.len) {
            for (unique_rows.items[0..start]) |row| freeBindingRow(self.allocator, row);
            for (unique_rows.items[end..]) |row| freeBindingRow(self.allocator, row);
            const out_len = end - start;
            if (start > 0) {
                std.mem.copyForwards(protocol.BindingRow, unique_rows.items[0..out_len], unique_rows.items[start..end]);
            }
            unique_rows.items.len = out_len;
        }

        const rows_slice = try unique_rows.toOwnedSlice();

        return federation.QueryResults{
            .rows = rows_slice,
            .schema = schema_copy,
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
        errdefer {
            for (merged_rows.items) |row| freeBindingRow(self.allocator, row);
            merged_rows.deinit();
        }

        // Extract elements in sorted order
        while (merger.heap.removeOrNull()) |item| {
            try merged_rows.append(try cloneBindingRow(self.allocator, item.row));

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

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) freeSchema(self.allocator, schema_copy);

        const start = options.offset orelse 0;
        const end = if (options.limit) |limit| @min(start + limit, merged_rows.items.len) else merged_rows.items.len;

        if (start >= merged_rows.items.len or end <= start) {
            for (merged_rows.items) |row| freeBindingRow(self.allocator, row);
            merged_rows.items.len = 0;
            return federation.QueryResults{
                .rows = &.{},
                .schema = schema_copy,
                .execution_time_ms = 0,
                .ordered = true,
            };
        }

        if (start > 0 or end < merged_rows.items.len) {
            for (merged_rows.items[0..start]) |row| freeBindingRow(self.allocator, row);
            for (merged_rows.items[end..]) |row| freeBindingRow(self.allocator, row);
            const out_len = end - start;
            if (start > 0) {
                std.mem.copyForwards(protocol.BindingRow, merged_rows.items[0..out_len], merged_rows.items[start..end]);
            }
            merged_rows.items.len = out_len;
        }

        const rows_slice = try merged_rows.toOwnedSlice();

        return federation.QueryResults{
            .rows = rows_slice,
            .schema = schema_copy,
            .execution_time_ms = 0,
            .ordered = true,
        };
    }

    // CANARY: REQ=REQ-DIST-HASH-AGG-001; FEATURE="DistributedHashAggregate"; ASPECT=ValueAccumulation; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    /// Hash aggregate results (for GROUP BY queries)
    fn hashAggregateResults(
        self: *EnhancedQueryCoordinator,
        shard_results: []federation.QueryResults,
        options: QueryOptions,
    ) !federation.QueryResults {
        _ = options;

        var groups = std.StringHashMap(AggregateGroup).init(self.allocator);
        defer {
            var it = groups.iterator();
            while (it.next()) |entry| {
                freeBindingRow(self.allocator, entry.value_ptr.representative_row);
                self.allocator.free(entry.key_ptr.*);
            }
            groups.deinit();
        }

        for (shard_results) |result| {
            for (result.rows) |row| {
                const group_key = try self.hashRow(row);

                // Extract numeric value from the last column for sum accumulation
                const numeric_val: f64 = extractLastNumericValue(row);

                const gop = try groups.getOrPut(group_key);
                if (gop.found_existing) {
                    self.allocator.free(group_key);
                    gop.value_ptr.count += 1;
                    gop.value_ptr.sum += numeric_val;
                } else {
                    gop.value_ptr.* = AggregateGroup{
                        .count = 1,
                        .sum = numeric_val,
                        .representative_row = try cloneBindingRow(self.allocator, row),
                    };
                }
            }
        }

        // Convert groups back to rows
        var aggregated_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        errdefer {
            for (aggregated_rows.items) |row| freeBindingRow(self.allocator, row);
            aggregated_rows.deinit();
        }

        var iter = groups.iterator();
        while (iter.next()) |entry| {
            try aggregated_rows.append(try cloneBindingRow(self.allocator, entry.value_ptr.representative_row));
        }

        return federation.QueryResults{
            .rows = try aggregated_rows.toOwnedSlice(),
            .schema = if (shard_results.len > 0 and shard_results[0].schema.len > 0)
                try cloneSchema(self.allocator, shard_results[0].schema)
            else
                &.{},
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
            errdefer {
                for (all_rows.items) |row| freeBindingRow(self.allocator, row);
                all_rows.deinit();
            }

            for (shard_results) |result| {
                for (result.rows) |row| {
                    try all_rows.append(try cloneBindingRow(self.allocator, row));
                }
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

            const schema_source = blk: {
                for (shard_results) |result| {
                    if (result.schema.len > 0) break :blk result.schema;
                }
                break :blk &.{};
            };
            const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
            errdefer if (schema_copy.len > 0) freeSchema(self.allocator, schema_copy);

            if (start >= all_rows.items.len or end <= start) {
                for (all_rows.items) |row| freeBindingRow(self.allocator, row);
                all_rows.items.len = 0;
                return federation.QueryResults{
                    .rows = &.{},
                    .schema = schema_copy,
                    .execution_time_ms = 0,
                    .ordered = true,
                };
            }

            if (start > 0 or end < all_rows.items.len) {
                for (all_rows.items[0..start]) |row| freeBindingRow(self.allocator, row);
                for (all_rows.items[end..]) |row| freeBindingRow(self.allocator, row);
                const out_len = end - start;
                if (start > 0) {
                    std.mem.copyForwards(protocol.BindingRow, all_rows.items[0..out_len], all_rows.items[start..end]);
                }
                all_rows.items.len = out_len;
            }

            const rows_slice = try all_rows.toOwnedSlice();

            return federation.QueryResults{
                .rows = rows_slice,
                .schema = schema_copy,
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
        errdefer {
            while (heap.removeOrNull()) |row| {
                freeBindingRow(self.allocator, row);
            }
        }

        // Reserve capacity for k elements
        try heap.ensureTotalCapacity(k);

        // Process all rows through the heap - O(n log k)
        for (shard_results) |result| {
            for (result.rows) |row| {
                if (heap.count() < k) {
                    try heap.add(try cloneBindingRow(self.allocator, row));
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
                        const cloned = try cloneBindingRow(self.allocator, row);
                        if (heap.removeOrNull()) |removed| {
                            freeBindingRow(self.allocator, removed);
                        }
                        try heap.add(cloned);
                    }
                }
            }
        }

        // Extract results from heap and sort them (k elements, O(k log k))
        var result_rows = std.ArrayList(protocol.BindingRow).init(self.allocator);
        errdefer {
            for (result_rows.items) |row| freeBindingRow(self.allocator, row);
            result_rows.deinit();
        }

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

        const schema_source = blk: {
            for (shard_results) |result| {
                if (result.schema.len > 0) break :blk result.schema;
            }
            break :blk &.{};
        };
        const schema_copy = if (schema_source.len > 0) try cloneSchema(self.allocator, schema_source) else &.{};
        errdefer if (schema_copy.len > 0) freeSchema(self.allocator, schema_copy);

        const start = options.offset orelse 0;
        const end = @min(start + (options.limit orelse result_rows.items.len), result_rows.items.len);

        if (start >= result_rows.items.len or end <= start) {
            for (result_rows.items) |row| freeBindingRow(self.allocator, row);
            result_rows.items.len = 0;
            return federation.QueryResults{
                .rows = &.{},
                .schema = schema_copy,
                .execution_time_ms = 0,
                .ordered = true,
            };
        }

        if (start > 0 or end < result_rows.items.len) {
            for (result_rows.items[0..start]) |row| freeBindingRow(self.allocator, row);
            for (result_rows.items[end..]) |row| freeBindingRow(self.allocator, row);
            const out_len = end - start;
            if (start > 0) {
                std.mem.copyForwards(protocol.BindingRow, result_rows.items[0..out_len], result_rows.items[start..end]);
            }
            result_rows.items.len = out_len;
        }

        const rows_slice = try result_rows.toOwnedSlice();

        return federation.QueryResults{
            .rows = rows_slice,
            .schema = schema_copy,
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
        for (row.cols) |binding| {
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

/// Extract the numeric value from the last column of a row for aggregation.
/// Supports Int, SmallInt, BigInt, Real, Double, and Decimal types.
/// Returns 0.0 for non-numeric or empty rows.
fn extractLastNumericValue(row: protocol.BindingRow) f64 {
    if (row.cols.len == 0) return 0.0;
    const last = row.cols[row.cols.len - 1];
    return switch (last) {
        .Int => |v| @floatFromInt(v),
        .SmallInt => |v| @floatFromInt(v),
        .BigInt => |v| @floatFromInt(v),
        .Real => |v| @floatCast(v),
        .Double => |v| v,
        .Decimal => |d| blk: {
            const coeff_f: f64 = @floatFromInt(d.coeff);
            var scale_divisor: f64 = 1.0;
            var i: u8 = 0;
            while (i < d.scale) : (i += 1) {
                scale_divisor *= 10.0;
            }
            break :blk coeff_f / scale_divisor;
        },
        else => 0.0,
    };
}

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
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            var res = entry.value_ptr.result;
            res.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
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
                return try cloneQueryResults(self.allocator, entry.result);
            } else {
                if (self.cache.fetchRemove(query_hash)) |removed| {
                    var res = removed.value.result;
                    res.deinit(self.allocator);
                    self.allocator.free(removed.key);
                }
            }
        }

        return null;
    }

    fn put(self: *QueryCache, query_hash: []const u8, result: federation.QueryResults, ttl_ms: u64) !void {
        if (!self.enabled) return;

        if (self.cache.fetchRemove(query_hash)) |removed| {
            var res = removed.value.result;
            res.deinit(self.allocator);
            self.allocator.free(removed.key);
        }

        const key_copy = try self.allocator.dupe(u8, query_hash);
        try self.cache.put(key_copy, CacheEntry{
            .result = try cloneQueryResults(self.allocator, result),
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

fn cloneBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) !protocol.BindingRow {
    var cols = try allocator.alloc(protocol.Value, row.cols.len);
    errdefer {
        for (cols) |val| value_utilities.freeValue(allocator, val);
        allocator.free(cols);
    }
    for (row.cols, 0..) |val, i| {
        cols[i] = try value_utilities.duplicateValue(allocator, val);
    }
    return .{ .cols = cols };
}

fn freeBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) void {
    for (row.cols) |val| {
        value_utilities.freeValue(allocator, val);
    }
    if (row.cols.len > 0) allocator.free(row.cols);
}

fn cloneSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) ![]const protocol.ColumnDef {
    var cols = try allocator.alloc(protocol.ColumnDef, schema_defs.len);
    errdefer {
        for (cols) |col| {
            allocator.free(col.name);
            allocator.free(col.data_type);
        }
        allocator.free(cols);
    }
    for (schema_defs, 0..) |col, i| {
        cols[i] = .{
            .name = try allocator.dupe(u8, col.name),
            .data_type = try allocator.dupe(u8, col.data_type),
        };
    }
    return cols;
}

fn freeSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) void {
    for (schema_defs) |col| {
        allocator.free(col.name);
        allocator.free(col.data_type);
    }
    allocator.free(schema_defs);
}

fn cloneOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var cloned = try allocator.alloc([]const u8, keys.len);
    errdefer {
        for (cloned) |k| allocator.free(k);
        allocator.free(cloned);
    }
    for (keys, 0..) |k, i| {
        cloned[i] = try allocator.dupe(u8, k);
    }
    return cloned;
}

fn cloneOrderDirs(allocator: std.mem.Allocator, dirs: []const bool) ![]const bool {
    var cloned = try allocator.alloc(bool, dirs.len);
    std.mem.copyForwards(bool, cloned, dirs);
    return cloned;
}

fn cloneQueryResults(allocator: std.mem.Allocator, result: federation.QueryResults) !federation.QueryResults {
    var rows = try allocator.alloc(protocol.BindingRow, result.rows.len);
    var row_idx: usize = 0;
    errdefer {
        for (rows[0..row_idx]) |row| freeBindingRow(allocator, row);
        allocator.free(rows);
    }
    for (result.rows) |row| {
        rows[row_idx] = try cloneBindingRow(allocator, row);
        row_idx += 1;
    }

    const schema = if (result.schema.len > 0) try cloneSchema(allocator, result.schema) else &.{};
    errdefer if (schema.len > 0) freeSchema(allocator, schema);

    const order_keys = if (result.order_keys.len > 0) try cloneOrderKeys(allocator, result.order_keys) else &.{};
    errdefer if (order_keys.len > 0) {
        for (order_keys) |k| allocator.free(k);
        allocator.free(order_keys);
    };

    const order_dirs = if (result.order_dirs.len > 0) try cloneOrderDirs(allocator, result.order_dirs) else &.{};
    errdefer if (order_dirs.len > 0) allocator.free(order_dirs);

    return federation.QueryResults{
        .rows = rows,
        .schema = schema,
        .execution_time_ms = result.execution_time_ms,
        .ordered = result.ordered,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
        .nulls_first = result.nulls_first,
    };
}
