// CANARY: REQ=REQ-DISTRIBUTED-QUERY-004; FEATURE="Enhanced Query Transport Integration"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_DISTRIBUTED_QUERY_004_EnhancedTransport; OWNER=distributed; UPDATED=2025-10-05
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-005; FEATURE="Cross-Shard Query Coordination"; ASPECT=QueryCoordination; STATUS=TESTED; TEST=TestCANARY_DISTRIBUTED_QUERY_005_CrossShardCoordination; OWNER=distributed; UPDATED=2025-10-05
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-006; FEATURE="Shard-Aware Query Execution"; ASPECT=ShardOptimization; STATUS=TESTED; TEST=TestCANARY_DISTRIBUTED_QUERY_006_ShardOptimization; OWNER=distributed; UPDATED=2025-10-05

const std = @import("std");
const Allocator = std.mem.Allocator;
const network_transport = @import("network_transport.zig");
const NetworkTransport = network_transport.NetworkTransport;
const ClusterMessage = network_transport.ClusterMessage;
const query_coordinator = @import("query_coordinator.zig");
const raft_consensus = @import("raft_consensus.zig");
const txn_coordinator = @import("txn_coordinator.zig");

const logging = @import("logging");
const log = logging.scoped("enhanced_query_transport");
const Attr = logging.Attr;

/// Enhanced query message types for distributed execution
pub const QueryMessageType = enum(u8) {
    execute_fragment = 20, // Start after existing cluster message types
    fragment_result = 21,
    query_cancel = 22,
    shard_heartbeat = 23,
    shard_registration = 24,
    query_plan_request = 25,
    query_plan_response = 26,
    cross_shard_join = 27,
    aggregate_partial = 28,
    coordinator_merge = 29,
};

/// Query execution message for cross-shard operations
pub const QueryMessage = struct {
    msg_type: QueryMessageType,
    query_id: u64,
    fragment_id: u64,
    shard_id: u64,
    timestamp: i64,
    payload: []const u8, // JSON-encoded query data
    metadata: QueryMetadata,

    pub const QueryMetadata = struct {
        estimated_rows: u64,
        memory_limit_mb: u64,
        timeout_ms: u64,
        priority: enum { low, normal, high, critical },
        requires_transaction: bool,
        isolation_level: enum { read_uncommitted, read_committed, repeatable_read, serializable },
    };
};

/// Enhanced query transport with network integration
pub const EnhancedQueryTransport = struct {
    allocator: Allocator,
    network_transport: *NetworkTransport,
    query_coordinator: *query_coordinator.QueryCoordinator,
    shard_registry: ShardRegistry,
    connection_pool: ConnectionPool,
    message_handlers: MessageHandlers,
    statistics: TransportStatistics,
    config: TransportConfig,
    // CANARY: REQ=REQ-DIST-TRACKER-001; FEATURE="Query Tracker Storage"; ASPECT=Query; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
    // GAP-0054: Added active_trackers map for query tracking
    active_trackers: std.AutoHashMap(u64, *QueryTracker),

    pub const TransportConfig = struct {
        max_concurrent_queries: u32 = 200,
        connection_pool_size: u32 = 50,
        message_timeout_ms: u64 = 30_000,
        retry_attempts: u32 = 3,
        heartbeat_interval_ms: u64 = 5_000,
        compression_enabled: bool = true,
        encryption_required: bool = true,
        load_balancing_strategy: enum { round_robin, least_connections, hash_based, adaptive },
    };

    pub const TransportStatistics = struct {
        messages_sent: u64,
        messages_received: u64,
        bytes_transferred: u64,
        query_latency_ms: f64,
        connection_errors: u64,
        retry_count: u64,
        active_connections: u32,
        shard_utilization: std.AutoHashMap(u64, ShardUtilization),

        pub const ShardUtilization = struct {
            queries_executed: u64,
            avg_response_time_ms: f64,
            cpu_usage_percent: f32,
            memory_usage_mb: f64,
            error_rate: f32,
        };
    };

    pub fn init(
        allocator: Allocator,
        net_transport: *NetworkTransport,
        coordinator: *query_coordinator.QueryCoordinator,
    ) !EnhancedQueryTransport {
        var transport = EnhancedQueryTransport{
            .allocator = allocator,
            .network_transport = net_transport,
            .query_coordinator = coordinator,
            .shard_registry = try ShardRegistry.init(allocator),
            .connection_pool = try ConnectionPool.init(allocator, 50),
            .message_handlers = MessageHandlers.init(),
            .statistics = TransportStatistics{
                .messages_sent = 0,
                .messages_received = 0,
                .bytes_transferred = 0,
                .query_latency_ms = 0.0,
                .connection_errors = 0,
                .retry_count = 0,
                .active_connections = 0,
                .shard_utilization = std.AutoHashMap(u64, TransportStatistics.ShardUtilization).init(allocator),
            },
            .config = TransportConfig{},
            // GAP-0054: Initialize active query trackers map
            .active_trackers = std.AutoHashMap(u64, *QueryTracker).init(allocator),
        };

        // Register message handlers
        transport.network_transport.onMessage(handleNetworkMessage);
        transport.setupMessageHandlers();

        return transport;
    }

    pub fn deinit(self: *EnhancedQueryTransport) void {
        self.shard_registry.deinit();
        self.connection_pool.deinit();
        self.statistics.shard_utilization.deinit();
    }

    /// Setup query-specific message handlers
    fn setupMessageHandlers(self: *EnhancedQueryTransport) void {
        self.message_handlers = MessageHandlers{
            .execute_fragment = handleExecuteFragment,
            .fragment_result = handleFragmentResult,
            .query_cancel = handleQueryCancel,
            .shard_heartbeat = handleShardHeartbeat,
            .shard_registration = handleShardRegistration,
            .query_plan_request = handleQueryPlanRequest,
            .query_plan_response = handleQueryPlanResponse,
            .cross_shard_join = handleCrossShardJoin,
            .aggregate_partial = handleAggregatePartial,
            .coordinator_merge = handleCoordinatorMerge,
        };
    }

    /// Execute a distributed query across multiple shards
    pub fn executeDistributedQuery(
        self: *EnhancedQueryTransport,
        query_text: []const u8,
        parameters: []const QueryParameter,
        target_shards: []const u64,
        completion_callback: QueryCompletionCallback,
    ) !u64 {
        const query_id = self.generateQueryId();
        _ = std.time.milliTimestamp(); // Query start time for logging

        log.info("Executing distributed query across shards", &.{
            Attr.uint("query_id", query_id),
            Attr.uint("shard_count", target_shards.len),
        });

        // Create query execution plan
        const execution_plan = try self.createExecutionPlan(query_text, parameters, target_shards);
        defer self.deallocateExecutionPlan(execution_plan);

        // Track query execution
        try self.trackActiveQuery(query_id, execution_plan, completion_callback);

        // Execute query fragments in parallel
        try self.executeQueryFragments(query_id, execution_plan);

        // Update statistics
        self.statistics.messages_sent += target_shards.len;

        return query_id;
    }

    /// Create a distributed execution plan
    fn createExecutionPlan(
        self: *EnhancedQueryTransport,
        query_text: []const u8,
        parameters: []const QueryParameter,
        target_shards: []const u64,
    ) !*ExecutionPlan {
        const plan = try self.allocator.create(ExecutionPlan);
        plan.* = ExecutionPlan{
            .query_text = try self.allocator.dupe(u8, query_text),
            .parameters = try self.allocator.dupe(QueryParameter, parameters),
            .target_shards = try self.allocator.dupe(u64, target_shards),
            .fragments = try self.allocator.alloc(QueryFragment, target_shards.len),
            .coordination_strategy = self.determineCoordinationStrategy(query_text),
            .estimated_cost = self.estimateQueryCost(query_text, target_shards.len),
        };

        // Create fragments for each shard
        for (target_shards, 0..) |shard_id, i| {
            plan.fragments[i] = QueryFragment{
                .fragment_id = i + 1,
                .shard_id = shard_id,
                .query_text = try self.optimizeFragmentForShard(query_text, shard_id),
                .dependencies = &[_]u64{},
                .result_schema = try self.inferResultSchema(query_text),
                .estimated_rows = try self.estimateShardRows(shard_id, query_text),
            };
        }

        return plan;
    }

    /// Execute query fragments across shards
    fn executeQueryFragments(self: *EnhancedQueryTransport, query_id: u64, plan: *const ExecutionPlan) !void {
        log.info("Executing fragments for query", &.{
            Attr.uint("fragment_count", plan.fragments.len),
            Attr.uint("query_id", query_id),
        });

        // Send fragments to shards in parallel
        for (plan.fragments) |fragment| {
            try self.sendFragmentToShard(query_id, fragment);
        }
    }

    /// Send a query fragment to a specific shard
    fn sendFragmentToShard(self: *EnhancedQueryTransport, query_id: u64, fragment: QueryFragment) !void {
        const shard = try self.shard_registry.getShard(fragment.shard_id);

        // Create query message
        const query_msg = QueryMessage{
            .msg_type = .execute_fragment,
            .query_id = query_id,
            .fragment_id = fragment.fragment_id,
            .shard_id = fragment.shard_id,
            .timestamp = std.time.milliTimestamp(),
            .payload = try self.serializeFragment(fragment),
            .metadata = QueryMessage.QueryMetadata{
                .estimated_rows = fragment.estimated_rows,
                .memory_limit_mb = 256,
                .timeout_ms = self.config.message_timeout_ms,
                .priority = .normal,
                .requires_transaction = false,
                .isolation_level = .read_committed,
            },
        };

        // Convert to cluster message
        const cluster_msg = try self.convertToClusterMessage(query_msg, shard.node_id);
        defer self.allocator.free(cluster_msg.payload);

        // Send via network transport with retry logic
        try self.sendWithRetry(shard.node_id, cluster_msg);

        log.debug("Sent fragment to shard", &.{
            Attr.uint("fragment_id", fragment.fragment_id),
            Attr.uint("shard_id", fragment.shard_id),
            Attr.uint("node_id", @as(u64, shard.node_id)),
        });
    }

    /// Send message with retry logic and error handling
    fn sendWithRetry(self: *EnhancedQueryTransport, node_id: u32, message: ClusterMessage) !void {
        var attempts: u32 = 0;
        const max_attempts = self.config.retry_attempts;

        while (attempts < max_attempts) : (attempts += 1) {
            self.network_transport.sendToNode(node_id, &message) catch |err| {
                self.statistics.connection_errors += 1;

                if (attempts + 1 < max_attempts) {
                    // Exponential backoff
                    const delay_ms = @as(u64, 100) << @intCast(attempts);
                    std.time.sleep(delay_ms * std.time.ns_per_ms);
                    self.statistics.retry_count += 1;
                    continue;
                }

                log.err("Failed to send message to node after retries", &.{
                    Attr.uint("node_id", @as(u64, node_id)),
                    Attr.uint("max_attempts", @as(u64, max_attempts)),
                });
                return err;
            };

            // Success
            self.statistics.messages_sent += 1;
            self.statistics.bytes_transferred += message.payload.len;
            return;
        }
    }

    /// Handle incoming query results from shards
    pub fn handleQueryResult(self: *EnhancedQueryTransport, result: QueryResult) !void {
        const query_tracker = self.getQueryTracker(result.query_id) orelse {
            log.warn("Received result for unknown query", &.{
                Attr.uint("query_id", result.query_id),
            });
            return;
        };

        // Store fragment result
        try query_tracker.addFragmentResult(result);

        // Check if query is complete
        if (query_tracker.isComplete()) {
            try self.finalizeDistributedQuery(result.query_id);
        }

        // Update shard utilization statistics
        try self.updateShardUtilization(result.shard_id, result.execution_time_ms);

        log.debug("Processed result for query fragment from shard", &.{
            Attr.uint("query_id", result.query_id),
            Attr.uint("fragment_id", result.fragment_id),
            Attr.uint("shard_id", result.shard_id),
        });
    }

    /// Finalize distributed query by merging results
    fn finalizeDistributedQuery(self: *EnhancedQueryTransport, query_id: u64) !void {
        const query_tracker = self.getQueryTracker(query_id) orelse return;

        log.info("Finalizing distributed query", &.{
            Attr.uint("query_id", query_id),
            Attr.uint("fragment_count", query_tracker.fragment_results.count()),
        });

        // Collect all fragment results
        var results = std.ArrayList(QueryResult).init(self.allocator);
        defer results.deinit();

        var result_it = query_tracker.fragment_results.iterator();
        while (result_it.next()) |entry| {
            try results.append(entry.value_ptr.*);
        }

        // Merge results using coordinator
        const merged_result = try self.mergeFragmentResults(results.items);

        // Calculate final execution time
        const total_time = std.time.milliTimestamp() - query_tracker.start_time;

        // Update statistics
        self.updateQueryStatistics(@as(f64, @floatFromInt(total_time)));

        // Notify completion callback
        if (query_tracker.completion_callback) |callback| {
            callback(query_id, merged_result);
        }

        // Cleanup query tracker
        self.removeQueryTracker(query_id);
    }

    /// Merge results from multiple fragments
    fn mergeFragmentResults(self: *EnhancedQueryTransport, results: []const QueryResult) !QueryResult {
        if (results.len == 0) {
            return QueryResult{
                .query_id = 0,
                .fragment_id = 0,
                .shard_id = 0,
                .status = .success,
                .data = "{}",
                .error_message = null,
                .execution_time_ms = 0,
                .rows_returned = 0,
            };
        }

        if (results.len == 1) {
            return results[0];
        }

        // Multiple results - need to merge
        var total_rows: u64 = 0;
        var total_time: u64 = 0;

        for (results) |result| {
            total_rows += result.rows_returned;
            total_time += result.execution_time_ms;
        }

        // For now, simple concatenation of JSON results
        // In production, this would need sophisticated merging logic
        var merged_data = std.ArrayList(u8).init(self.allocator);
        defer merged_data.deinit();

        try merged_data.appendSlice("{\"merged_results\":[");
        for (results, 0..) |result, i| {
            if (i > 0) try merged_data.appendSlice(",");
            try merged_data.appendSlice(result.data);
        }
        try merged_data.appendSlice("]}");

        return QueryResult{
            .query_id = results[0].query_id,
            .fragment_id = 0, // Merged result
            .shard_id = 0, // Coordinator result
            .status = .success,
            .data = try merged_data.toOwnedSlice(),
            .error_message = null,
            .execution_time_ms = total_time,
            .rows_returned = total_rows,
        };
    }

    /// Register a new shard in the registry
    pub fn registerShard(self: *EnhancedQueryTransport, shard: ShardInfo) !void {
        try self.shard_registry.addShard(shard);

        // Initialize shard utilization tracking
        try self.statistics.shard_utilization.put(shard.shard_id, TransportStatistics.ShardUtilization{
            .queries_executed = 0,
            .avg_response_time_ms = 0.0,
            .cpu_usage_percent = 0.0,
            .memory_usage_mb = 0.0,
            .error_rate = 0.0,
        });

        log.info("Registered shard on node", &.{
            Attr.uint("shard_id", shard.shard_id),
            Attr.uint("node_id", @as(u64, shard.node_id)),
            Attr.string("endpoint", shard.endpoint),
            Attr.uint("port", @as(u64, shard.port)),
        });
    }

    /// Get transport statistics
    pub fn getStatistics(self: *const EnhancedQueryTransport) TransportStatistics {
        return self.statistics;
    }

    /// Optimize query fragment for specific shard
    fn optimizeFragmentForShard(self: *EnhancedQueryTransport, query_text: []const u8, shard_id: u64) ![]u8 {
        _ = shard_id;
        // For now, return the original query
        // In production, this would apply shard-specific optimizations
        return try self.allocator.dupe(u8, query_text);
    }

    /// Estimate query cost for planning
    fn estimateQueryCost(self: *EnhancedQueryTransport, query_text: []const u8, shard_count: usize) f64 {
        _ = self;
        // Simple cost estimation based on query complexity and shard count
        const base_cost = @as(f64, @floatFromInt(query_text.len)) * 0.1;
        const distribution_cost = @as(f64, @floatFromInt(shard_count)) * 10.0;
        return base_cost + distribution_cost;
    }

    /// Generate unique query ID
    fn generateQueryId(self: *EnhancedQueryTransport) u64 {
        _ = self;
        return @as(u64, @intCast(std.time.milliTimestamp()));
    }

    /// Update query execution statistics
    fn updateQueryStatistics(self: *EnhancedQueryTransport, execution_time_ms: f64) void {
        if (self.statistics.messages_received == 0) {
            self.statistics.query_latency_ms = execution_time_ms;
        } else {
            const count = @as(f64, @floatFromInt(self.statistics.messages_received));
            self.statistics.query_latency_ms =
                (self.statistics.query_latency_ms * count + execution_time_ms) / (count + 1.0);
        }
    }

    /// Update shard utilization metrics
    fn updateShardUtilization(self: *EnhancedQueryTransport, shard_id: u64, execution_time_ms: u64) !void {
        if (self.statistics.shard_utilization.getPtr(shard_id)) |util| {
            util.queries_executed += 1;

            const exec_time_f = @as(f64, @floatFromInt(execution_time_ms));
            if (util.queries_executed == 1) {
                util.avg_response_time_ms = exec_time_f;
            } else {
                const count = @as(f64, @floatFromInt(util.queries_executed - 1));
                util.avg_response_time_ms =
                    (util.avg_response_time_ms * count + exec_time_f) / (count + 1.0);
            }
        }
    }

    // Helper functions for message handling and type conversion
    /// Serialize a QueryFragment to JSON for distributed transport
    // CANARY: REQ=REQ-DIST-FRAG-001; FEATURE="Fragment Serialization"; ASPECT=Core; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-14
    /// GAP-0162: Implements actual fragment serialization using JSON encoding
    fn serializeFragment(self: *EnhancedQueryTransport, fragment: QueryFragment) ![]u8 {
        // Build a serializable representation that handles slices properly
        const SerializableFragment = struct {
            fragment_id: u64,
            shard_id: u64,
            query_text: []const u8,
            dependencies: []const u64,
            result_schema: []const u8,
            estimated_rows: u64,
        };

        const serializable = SerializableFragment{
            .fragment_id = fragment.fragment_id,
            .shard_id = fragment.shard_id,
            .query_text = fragment.query_text,
            .dependencies = fragment.dependencies,
            .result_schema = fragment.result_schema,
            .estimated_rows = fragment.estimated_rows,
        };

        return try std.json.stringifyAlloc(self.allocator, serializable, .{});
    }

    /// Deserialize a QueryFragment from JSON for distributed transport
    // CANARY: REQ=REQ-DIST-FRAG-002; FEATURE="Fragment Deserialization"; ASPECT=Core; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-14
    /// GAP-0162: Implements actual fragment deserialization from JSON
    fn deserializeFragment(self: *EnhancedQueryTransport, data: []const u8) !QueryFragment {
        const ParsedFragment = struct {
            fragment_id: u64,
            shard_id: u64,
            query_text: []const u8,
            dependencies: []const u64,
            result_schema: []const u8,
            estimated_rows: u64,
        };

        const parsed = try std.json.parseFromSlice(ParsedFragment, self.allocator, data, .{});
        defer parsed.deinit();

        // Copy the data into allocator-owned memory
        const query_text = try self.allocator.dupe(u8, parsed.value.query_text);
        const dependencies = try self.allocator.dupe(u64, parsed.value.dependencies);
        const result_schema = try self.allocator.dupe(u8, parsed.value.result_schema);

        return QueryFragment{
            .fragment_id = parsed.value.fragment_id,
            .shard_id = parsed.value.shard_id,
            .query_text = query_text,
            .dependencies = dependencies,
            .result_schema = result_schema,
            .estimated_rows = parsed.value.estimated_rows,
        };
    }

    fn convertToClusterMessage(self: *EnhancedQueryTransport, query_msg: QueryMessage, dest_node: u32) !ClusterMessage {
        const payload = try std.json.stringifyAlloc(self.allocator, query_msg, .{});

        return ClusterMessage{
            .msg_type = .client_request, // Reuse existing cluster message type
            .source_node = self.network_transport.node_id,
            .dest_node = dest_node,
            .term = 0,
            .payload = payload,
        };
    }

    /// Track an active query for coordination and cancellation support
    // CANARY: REQ=REQ-DIST-TRACKER-002; FEATURE="Query Tracking"; ASPECT=Query; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
    /// GAP-0054: Implements actual query tracking using HashMap storage
    fn trackActiveQuery(self: *EnhancedQueryTransport, query_id: u64, plan: *const ExecutionPlan, callback: QueryCompletionCallback) !void {
        // Allocate and initialize tracker
        const tracker = try self.allocator.create(QueryTracker);
        tracker.* = QueryTracker{
            .query_id = query_id,
            .start_time = std.time.milliTimestamp(),
            .fragment_results = std.AutoHashMap(u64, QueryResult).init(self.allocator),
            .completion_callback = callback,
        };

        // Pre-populate expected fragments from plan
        for (plan.fragments) |fragment| {
            _ = fragment;
            // Fragment tracking will be added when results arrive
        }

        // Store in active trackers map
        try self.active_trackers.put(query_id, tracker);

        log.debug("Tracking query with fragments", &.{
            Attr.uint("query_id", query_id),
            Attr.uint("fragment_count", plan.fragments.len),
        });
    }

    /// Get the tracker for an active query
    // CANARY: REQ=REQ-DIST-TRACKER-003; FEATURE="Query Tracker Lookup"; ASPECT=Query; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
    /// GAP-0054: Implements actual tracker retrieval from HashMap
    fn getQueryTracker(self: *EnhancedQueryTransport, query_id: u64) ?*QueryTracker {
        return self.active_trackers.get(query_id);
    }

    /// Remove and clean up a query tracker after completion or cancellation
    // CANARY: REQ=REQ-DIST-TRACKER-004; FEATURE="Query Tracker Cleanup"; ASPECT=Query; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
    /// GAP-0054: Implements actual tracker cleanup with proper memory deallocation
    fn removeQueryTracker(self: *EnhancedQueryTransport, query_id: u64) void {
        if (self.active_trackers.fetchRemove(query_id)) |entry| {
            const tracker = entry.value;
            // Clean up fragment results
            tracker.fragment_results.deinit();
            // Deallocate tracker
            self.allocator.destroy(tracker);
            log.debug("Removed tracker for query", &.{
                Attr.uint("query_id", query_id),
            });
        }
    }

    fn deallocateExecutionPlan(self: *EnhancedQueryTransport, plan: *ExecutionPlan) void {
        self.allocator.free(plan.query_text);
        self.allocator.free(plan.parameters);
        self.allocator.free(plan.target_shards);

        for (plan.fragments) |fragment| {
            self.allocator.free(fragment.query_text);
            self.allocator.free(fragment.result_schema);
        }
        self.allocator.free(plan.fragments);
        self.allocator.destroy(plan);
    }

    fn determineCoordinationStrategy(self: *EnhancedQueryTransport, query_text: []const u8) CoordinationStrategy {
        _ = self;
        _ = query_text;
        return .scatter_gather; // Default strategy
    }

    fn inferResultSchema(self: *EnhancedQueryTransport, query_text: []const u8) ![]u8 {
        _ = query_text;
        return try self.allocator.dupe(u8, "mixed");
    }

    fn estimateShardRows(self: *EnhancedQueryTransport, shard_id: u64, query_text: []const u8) !u64 {
        _ = self;
        _ = shard_id;
        _ = query_text;
        return 1000; // Default estimate
    }

    // CANARY: REQ=REQ-DIST-LB-001; FEATURE="Load Balancing"; ASPECT=ShardSelection; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=distributed; UPDATED=2026-01-08
    /// Select the best shard for a query using the configured load balancing strategy
    pub fn selectShardForQuery(self: *EnhancedQueryTransport, available_shards: []const u64, query_key: ?[]const u8) !u64 {
        if (available_shards.len == 0) return error.NoShardsAvailable;
        if (available_shards.len == 1) return available_shards[0];

        return switch (self.config.load_balancing_strategy) {
            .round_robin => self.selectRoundRobin(available_shards),
            .least_connections => self.selectLeastConnections(available_shards),
            .hash_based => self.selectHashBased(available_shards, query_key),
            .adaptive => self.selectAdaptive(available_shards),
        };
    }

    // Round-robin load balancing
    var round_robin_counter: usize = 0;
    fn selectRoundRobin(self: *EnhancedQueryTransport, shards: []const u64) u64 {
        _ = self;
        const idx = @atomicRmw(usize, &round_robin_counter, .Add, 1, .seq_cst) % shards.len;
        return shards[idx];
    }

    // Least connections - select shard with lowest active query count
    fn selectLeastConnections(self: *EnhancedQueryTransport, shards: []const u64) u64 {
        var best_shard: u64 = shards[0];
        var min_queries: u64 = std.math.maxInt(u64);

        for (shards) |shard_id| {
            if (self.statistics.shard_utilization.get(shard_id)) |util| {
                // Use queries_executed as proxy for current load (in production would track active queries)
                if (util.queries_executed < min_queries) {
                    min_queries = util.queries_executed;
                    best_shard = shard_id;
                }
            } else {
                // Prefer shards with no utilization data (new shards)
                return shard_id;
            }
        }

        return best_shard;
    }

    // Hash-based - consistent selection based on query key
    fn selectHashBased(self: *EnhancedQueryTransport, shards: []const u64, key: ?[]const u8) u64 {
        _ = self;
        if (key) |k| {
            var hash: u64 = 0;
            for (k) |c| {
                hash = hash *% 31 +% c;
            }
            return shards[hash % shards.len];
        }
        // Fallback to first shard if no key provided
        return shards[0];
    }

    // Adaptive - consider response time, error rate, and current load
    fn selectAdaptive(self: *EnhancedQueryTransport, shards: []const u64) u64 {
        var best_shard: u64 = shards[0];
        var best_score: f64 = std.math.inf(f64);

        for (shards) |shard_id| {
            if (self.statistics.shard_utilization.get(shard_id)) |util| {
                // Calculate weighted score (lower is better)
                // Weights: response_time=0.4, error_rate=0.4, cpu_usage=0.2
                const response_score = util.avg_response_time_ms * 0.4;
                const error_score = @as(f64, util.error_rate) * 1000.0 * 0.4; // Scale error rate
                const load_score = @as(f64, util.cpu_usage_percent) * 0.2;

                const total_score = response_score + error_score + load_score;

                if (total_score < best_score) {
                    best_score = total_score;
                    best_shard = shard_id;
                }
            } else {
                // Prefer shards with no metrics (new, untested shards get a chance)
                return shard_id;
            }
        }

        return best_shard;
    }

    /// Get multiple shards for parallel execution with load balancing
    pub fn selectShardsForParallelQuery(
        self: *EnhancedQueryTransport,
        all_shards: []const u64,
        max_shards: usize,
    ) ![]u64 {
        if (all_shards.len == 0) return error.NoShardsAvailable;

        const count = @min(all_shards.len, max_shards);
        var selected = try self.allocator.alloc(u64, count);

        // Sort shards by adaptive score and select top N
        var scored_shards = try self.allocator.alloc(struct { id: u64, score: f64 }, all_shards.len);
        defer self.allocator.free(scored_shards);

        for (all_shards, 0..) |shard_id, i| {
            var score: f64 = 0;
            if (self.statistics.shard_utilization.get(shard_id)) |util| {
                score = util.avg_response_time_ms + @as(f64, util.error_rate) * 1000.0;
            }
            scored_shards[i] = .{ .id = shard_id, .score = score };
        }

        // Sort by score (lower is better)
        std.mem.sort(@TypeOf(scored_shards[0]), scored_shards, {}, struct {
            fn lessThan(_: void, a: @TypeOf(scored_shards[0]), b: @TypeOf(scored_shards[0])) bool {
                return a.score < b.score;
            }
        }.lessThan);

        // Select top N shards
        for (scored_shards[0..count], 0..) |s, i| {
            selected[i] = s.id;
        }

        return selected;
    }
};

// Supporting data structures and type definitions

pub const QueryParameter = struct {
    name: []const u8,
    value: []const u8,
    param_type: enum { string, integer, float, boolean, list, object },
};

pub const QueryResult = struct {
    query_id: u64,
    fragment_id: u64,
    shard_id: u64,
    status: enum { success, failed, timeout, cancelled },
    data: []const u8, // JSON-encoded result data
    error_message: ?[]const u8,
    execution_time_ms: u64,
    rows_returned: u64,
};

pub const ExecutionPlan = struct {
    query_text: []const u8,
    parameters: []const QueryParameter,
    target_shards: []const u64,
    fragments: []QueryFragment,
    coordination_strategy: CoordinationStrategy,
    estimated_cost: f64,
};

pub const QueryFragment = struct {
    fragment_id: u64,
    shard_id: u64,
    query_text: []const u8,
    dependencies: []const u64,
    result_schema: []const u8,
    estimated_rows: u64,
};

pub const CoordinationStrategy = enum {
    scatter_gather,
    streaming_merge,
    hash_join,
    broadcast_join,
    adaptive,
};

pub const ShardInfo = struct {
    shard_id: u64,
    node_id: u32,
    endpoint: []const u8,
    port: u16,
    status: enum { online, offline, degraded },
    data_partitions: []const DataPartition,

    pub const DataPartition = struct {
        partition_key: []const u8,
        start_range: []const u8,
        end_range: []const u8,
        row_count: u64,
    };
};

pub const QueryCompletionCallback = *const fn (query_id: u64, result: QueryResult) void;

pub const QueryTracker = struct {
    query_id: u64,
    start_time: i64,
    fragment_results: std.AutoHashMap(u64, QueryResult),
    completion_callback: ?QueryCompletionCallback,

    pub fn addFragmentResult(self: *QueryTracker, result: QueryResult) !void {
        try self.fragment_results.put(result.fragment_id, result);
    }

    pub fn isComplete(self: *const QueryTracker) bool {
        // Implementation would check if all expected fragments have results
        return self.fragment_results.count() > 0;
    }
};

// Supporting infrastructure

const ShardRegistry = struct {
    allocator: Allocator,
    shards: std.AutoHashMap(u64, ShardInfo),

    pub fn init(allocator: Allocator) !ShardRegistry {
        return ShardRegistry{
            .allocator = allocator,
            .shards = std.AutoHashMap(u64, ShardInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ShardRegistry) void {
        self.shards.deinit();
    }

    pub fn addShard(self: *ShardRegistry, shard: ShardInfo) !void {
        try self.shards.put(shard.shard_id, shard);
    }

    pub fn getShard(self: *ShardRegistry, shard_id: u64) !ShardInfo {
        return self.shards.get(shard_id) orelse error.ShardNotFound;
    }
};

const ConnectionPool = struct {
    allocator: Allocator,
    size: u32,

    pub fn init(allocator: Allocator, size: u32) !ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .size = size,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        _ = self;
        // Implementation would clean up connections
    }
};

const MessageHandlers = struct {
    execute_fragment: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    fragment_result: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    query_cancel: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    shard_heartbeat: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    shard_registration: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    query_plan_request: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    query_plan_response: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    cross_shard_join: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    aggregate_partial: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,
    coordinator_merge: ?*const fn (*EnhancedQueryTransport, *const QueryMessage) void = null,

    pub fn init() MessageHandlers {
        return MessageHandlers{};
    }
};

// Message handler implementations (placeholders)
fn handleNetworkMessage(transport: *NetworkTransport, message: *const ClusterMessage) void {
    _ = transport;
    _ = message;
    // Implementation would route to enhanced query transport
}

fn handleExecuteFragment(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling execute fragment message", &.{});
}

fn handleFragmentResult(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling fragment result message", &.{});
}

fn handleQueryCancel(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling query cancel message", &.{});
}

fn handleShardHeartbeat(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling shard heartbeat message", &.{});
}

fn handleShardRegistration(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling shard registration message", &.{});
}

fn handleQueryPlanRequest(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling query plan request message", &.{});
}

fn handleQueryPlanResponse(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling query plan response message", &.{});
}

fn handleCrossShardJoin(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling cross-shard join message", &.{});
}

fn handleAggregatePartial(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling aggregate partial message", &.{});
}

fn handleCoordinatorMerge(transport: *EnhancedQueryTransport, message: *const QueryMessage) void {
    _ = transport;
    _ = message;
    log.debug("Handling coordinator merge message", &.{});
}

// Unit tests for fragment serialization
// CANARY: REQ=REQ-DIST-FRAG-003; FEATURE="Fragment Serialization Tests"; ASPECT=Testing; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-14
// GAP-0162: Tests for fragment serialization/deserialization

test "serializeFragment produces valid JSON" {
    const allocator = std.testing.allocator;

    // Create minimal test infrastructure
    var net_transport = try NetworkTransport.init(allocator, .{
        .node_id = 1,
        .bind_address = "127.0.0.1",
        .bind_port = 9000,
    });
    defer net_transport.deinit();

    var coordinator = try query_coordinator.QueryCoordinator.init(allocator, &net_transport);
    defer coordinator.deinit();

    var transport = try EnhancedQueryTransport.init(allocator, &net_transport, &coordinator);
    defer transport.deinit();

    // Create a test fragment
    const deps = [_]u64{ 1, 2, 3 };
    const fragment = QueryFragment{
        .fragment_id = 42,
        .shard_id = 7,
        .query_text = "MATCH (n) RETURN n",
        .dependencies = &deps,
        .result_schema = "n:Node",
        .estimated_rows = 1000,
    };

    // Serialize the fragment
    const json = try transport.serializeFragment(fragment);
    defer allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fragment_id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shard_id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"query_text\":\"MATCH (n) RETURN n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"estimated_rows\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"result_schema\":\"n:Node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dependencies\":[1,2,3]") != null);
}

test "deserializeFragment recovers fragment data" {
    const allocator = std.testing.allocator;

    var net_transport = try NetworkTransport.init(allocator, .{
        .node_id = 1,
        .bind_address = "127.0.0.1",
        .bind_port = 9001,
    });
    defer net_transport.deinit();

    var coordinator = try query_coordinator.QueryCoordinator.init(allocator, &net_transport);
    defer coordinator.deinit();

    var transport = try EnhancedQueryTransport.init(allocator, &net_transport, &coordinator);
    defer transport.deinit();

    // JSON data to deserialize
    const json =
        \\{"fragment_id":99,"shard_id":5,"query_text":"RETURN 1","dependencies":[10,20],"result_schema":"x:Int","estimated_rows":50}
    ;

    // Deserialize the fragment
    const fragment = try transport.deserializeFragment(json);
    defer {
        allocator.free(fragment.query_text);
        allocator.free(fragment.dependencies);
        allocator.free(fragment.result_schema);
    }

    // Verify fields match
    try std.testing.expectEqual(@as(u64, 99), fragment.fragment_id);
    try std.testing.expectEqual(@as(u64, 5), fragment.shard_id);
    try std.testing.expectEqualStrings("RETURN 1", fragment.query_text);
    try std.testing.expectEqual(@as(usize, 2), fragment.dependencies.len);
    try std.testing.expectEqual(@as(u64, 10), fragment.dependencies[0]);
    try std.testing.expectEqual(@as(u64, 20), fragment.dependencies[1]);
    try std.testing.expectEqualStrings("x:Int", fragment.result_schema);
    try std.testing.expectEqual(@as(u64, 50), fragment.estimated_rows);
}

test "serializeFragment round-trip preserves data" {
    const allocator = std.testing.allocator;

    var net_transport = try NetworkTransport.init(allocator, .{
        .node_id = 1,
        .bind_address = "127.0.0.1",
        .bind_port = 9002,
    });
    defer net_transport.deinit();

    var coordinator = try query_coordinator.QueryCoordinator.init(allocator, &net_transport);
    defer coordinator.deinit();

    var transport = try EnhancedQueryTransport.init(allocator, &net_transport, &coordinator);
    defer transport.deinit();

    // Create original fragment
    const deps = [_]u64{ 100, 200, 300 };
    const original = QueryFragment{
        .fragment_id = 123,
        .shard_id = 456,
        .query_text = "MATCH (a)-[r]->(b) WHERE a.x > 10 RETURN b",
        .dependencies = &deps,
        .result_schema = "b:Node",
        .estimated_rows = 5000,
    };

    // Serialize then deserialize
    const json = try transport.serializeFragment(original);
    defer allocator.free(json);

    const recovered = try transport.deserializeFragment(json);
    defer {
        allocator.free(recovered.query_text);
        allocator.free(recovered.dependencies);
        allocator.free(recovered.result_schema);
    }

    // Verify round-trip preserves all fields
    try std.testing.expectEqual(original.fragment_id, recovered.fragment_id);
    try std.testing.expectEqual(original.shard_id, recovered.shard_id);
    try std.testing.expectEqualStrings(original.query_text, recovered.query_text);
    try std.testing.expectEqual(original.dependencies.len, recovered.dependencies.len);
    for (original.dependencies, 0..) |dep, i| {
        try std.testing.expectEqual(dep, recovered.dependencies[i]);
    }
    try std.testing.expectEqualStrings(original.result_schema, recovered.result_schema);
    try std.testing.expectEqual(original.estimated_rows, recovered.estimated_rows);
}

test "serializeFragment handles empty dependencies" {
    const allocator = std.testing.allocator;

    var net_transport = try NetworkTransport.init(allocator, .{
        .node_id = 1,
        .bind_address = "127.0.0.1",
        .bind_port = 9003,
    });
    defer net_transport.deinit();

    var coordinator = try query_coordinator.QueryCoordinator.init(allocator, &net_transport);
    defer coordinator.deinit();

    var transport = try EnhancedQueryTransport.init(allocator, &net_transport, &coordinator);
    defer transport.deinit();

    // Create fragment with no dependencies
    const fragment = QueryFragment{
        .fragment_id = 1,
        .shard_id = 1,
        .query_text = "RETURN 42",
        .dependencies = &[_]u64{},
        .result_schema = "x:Int",
        .estimated_rows = 1,
    };

    const json = try transport.serializeFragment(fragment);
    defer allocator.free(json);

    // Verify empty dependencies array
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dependencies\":[]") != null);

    // Round-trip test
    const recovered = try transport.deserializeFragment(json);
    defer {
        allocator.free(recovered.query_text);
        allocator.free(recovered.dependencies);
        allocator.free(recovered.result_schema);
    }

    try std.testing.expectEqual(@as(usize, 0), recovered.dependencies.len);
}
