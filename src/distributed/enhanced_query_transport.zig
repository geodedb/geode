// CANARY: REQ=REQ-DISTRIBUTED-QUERY-004; FEATURE="Enhanced Query Transport Integration"; ASPECT=NetworkTransport; STATUS=IMPL; OWNER=distributed; UPDATED=2026-06-11
// NOTE(GAP-0514 P3): stays IMPL — every test constructs the transport with an undefined
// NetworkTransport pointer (dispatch/tracker/LB paths never dereference it), so the
// real network-send integration is not executed by any green test. Promoting this
// requires a loopback NetworkTransport harness.
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-005; FEATURE="Cross-Shard Query Coordination"; ASPECT=QueryCoordination; STATUS=TESTED; TEST="dispatch: FRAGMENT_RESULT routes to handleQueryResult (GAP-0870)"; OWNER=distributed; UPDATED=2026-06-11
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-006; FEATURE="Shard-Aware Query Execution"; ASPECT=ShardOptimization; STATUS=TESTED; TEST="selectShardForQuery: load balancing strategies (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11

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
const Allocator = std.mem.Allocator;
const network_transport = @import("network_transport.zig");
const NetworkTransport = network_transport.NetworkTransport;
const ClusterMessage = network_transport.ClusterMessage;
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");
// GAP-0870: the vestigial query_coordinator / raft_consensus /
// txn_coordinator imports were dropped — none were used, and removing them
// keeps this module compilable as a standalone test root (see
// `test-gap0870` in build.zig) without dragging the whole lib graph in.

const logging = @import("logging");
const log = logging.scoped("enhanced_query_transport");
const Attr = logging.Attr;

// GAP-0870: pub so dispatch tests can construct inbound messages.
pub const QueryMessageType = dist_schema.QueryMessageType;
pub const QueryMessage = dist_schema.QueryMessage;
const QueryMetadata = dist_schema.QueryMetadata;
const ProtoQueryFragment = dist_schema.QueryFragment;
const ProtoQueryResult = dist_schema.QueryResult;

/// Enhanced query transport with network integration
pub const EnhancedQueryTransport = struct {
    allocator: Allocator,
    network_transport: *NetworkTransport,
    shard_registry: ShardRegistry,
    connection_pool: ConnectionPool,
    message_handlers: MessageHandlers,
    statistics: TransportStatistics,
    stats_mutex: std.Io.Mutex = std.Io.Mutex.init, // PERF-D010: Thread-safe statistics access
    config: TransportConfig,
    // CANARY: REQ=REQ-DIST-TRACKER-001; FEATURE="Query Tracker Storage"; ASPECT=Query; STATUS=TESTED; TEST="query tracker lifecycle: track, lookup, remove (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
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
        load_balancing_strategy: enum { round_robin, least_connections, hash_based, adaptive } = .round_robin,
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
    ) !EnhancedQueryTransport {
        var transport = EnhancedQueryTransport{
            .allocator = allocator,
            .network_transport = net_transport,
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

        // Register message handlers.  GAP-0870: the old code also installed
        // a `handleNetworkMessage` no-op on the network transport that
        // silently dropped every inbound ClusterMessage; the honest entry
        // point is now `dispatchQueryMessage`, which the owner of the
        // network loop calls with a decoded QueryMessage and which surfaces
        // handler errors to the caller.
        transport.setupMessageHandlers();

        return transport;
    }

    pub fn deinit(self: *EnhancedQueryTransport) void {
        // GAP-0870: free any trackers still active at shutdown (previously
        // leaked: the map itself was never deinitialized either).
        var it = self.active_trackers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.fragment_results.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_trackers.deinit();
        self.shard_registry.deinit();
        self.connection_pool.deinit();
        self.statistics.shard_utilization.deinit();
    }

    /// GAP-0870: single honest dispatch entry point for inbound query
    /// messages.  Routes to the registered handler for the message type and
    /// PROPAGATES handler errors to the caller — nothing is silently
    /// log-and-dropped.  Message types with no real counterpart yet return
    /// `error.NotImplemented`.
    // CANARY: REQ=REQ-DIST-QUERY-MSG-DISPATCH; FEATURE="Enhanced Query Transport"; ASPECT=MessageDispatch; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
    pub fn dispatchQueryMessage(self: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
        const handler: ?MessageHandlers.HandlerFn = switch (message.msg_type) {
            .EXECUTE_FRAGMENT => self.message_handlers.execute_fragment,
            .FRAGMENT_RESULT => self.message_handlers.fragment_result,
            .QUERY_CANCEL => self.message_handlers.query_cancel,
            .SHARD_HEARTBEAT => self.message_handlers.shard_heartbeat,
            .SHARD_REGISTRATION => self.message_handlers.shard_registration,
            .QUERY_PLAN_REQUEST => self.message_handlers.query_plan_request,
            .QUERY_PLAN_RESPONSE => self.message_handlers.query_plan_response,
            .CROSS_SHARD_JOIN => self.message_handlers.cross_shard_join,
            .AGGREGATE_PARTIAL => self.message_handlers.aggregate_partial,
            .COORDINATOR_MERGE => self.message_handlers.coordinator_merge,
            .QUERY_MESSAGE_TYPE_UNSPECIFIED => return error.InvalidMessage,
        };
        const h = handler orelse return error.NotImplemented;
        try h(self, message);
    }

    /// GAP-0870: cancel an in-flight distributed query — real counterpart
    /// for QUERY_CANCEL messages.  Unknown query ids fail loud (the cancel
    /// raced completion or targeted a query this node never tracked).
    pub fn cancelQuery(self: *EnhancedQueryTransport, query_id: u64) !void {
        if (self.getQueryTracker(query_id) == null) return error.UnknownQuery;
        self.removeQueryTracker(query_id);
        log.info("Cancelled distributed query", &.{Attr.uint("query_id", query_id)});
    }

    /// GAP-0870: record a shard heartbeat — real counterpart for
    /// SHARD_HEARTBEAT messages.  Marks the shard online in the registry;
    /// a heartbeat from an unregistered shard fails loud.
    pub fn recordShardHeartbeat(self: *EnhancedQueryTransport, shard_id: u64) !void {
        const shard = self.shard_registry.getShardPtr(shard_id) orelse return error.ShardNotFound;
        shard.status = .online;
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
        _ = compat_milliTimestamp(); // Query start time for logging

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

        // Update statistics (PERF-D010: thread-safe)
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        self.statistics.messages_sent += target_shards.len;
        self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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

        var deps: std.ArrayList(u64) = .empty;
        defer deps.deinit(self.allocator);
        try deps.appendSlice(self.allocator, fragment.dependencies);

        const proto_fragment = ProtoQueryFragment{
            .fragment_id = fragment.fragment_id,
            .shard_id = fragment.shard_id,
            .query_text = fragment.query_text,
            .dependencies = deps,
            .result_schema = fragment.result_schema,
            .estimated_rows = fragment.estimated_rows,
        };

        // Create query message
        const query_msg = QueryMessage{
            .msg_type = .EXECUTE_FRAGMENT,
            .query_id = query_id,
            .fragment_id = fragment.fragment_id,
            .shard_id = fragment.shard_id,
            .timestamp = compat_milliTimestamp(),
            .fragment = proto_fragment,
            .metadata = QueryMetadata{
                .estimated_rows = fragment.estimated_rows,
                .memory_limit_mb = 256,
                .timeout_ms = self.config.message_timeout_ms,
                .priority = .NORMAL,
                .requires_transaction = false,
                .isolation_level = .READ_COMMITTED,
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
                self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                self.statistics.connection_errors += 1;
                self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

                if (attempts + 1 < max_attempts) {
                    // Exponential backoff
                    const delay_ms = @as(u64, 100) << @intCast(attempts);
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                    self.statistics.retry_count += 1;
                    self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                    continue;
                }

                log.err("Failed to send message to node after retries", &.{
                    Attr.uint("node_id", @as(u64, node_id)),
                    Attr.uint("max_attempts", @as(u64, max_attempts)),
                });
                return err;
            };

            // Success (PERF-D010: thread-safe)
            self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            self.statistics.messages_sent += 1;
            self.statistics.bytes_transferred += message.payload.len;
            self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        var results: std.ArrayList(QueryResult) = .empty;
        defer results.deinit(self.allocator);

        var result_it = query_tracker.fragment_results.iterator();
        while (result_it.next()) |entry| {
            try results.append(self.allocator, entry.value_ptr.*);
        }

        // Merge results using coordinator
        const merged_result = try self.mergeFragmentResults(results.items);

        // Calculate final execution time
        const total_time = compat_milliTimestamp() - query_tracker.start_time;

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
        var merged_data: std.ArrayList(u8) = .empty;
        defer merged_data.deinit(self.allocator);

        try merged_data.appendSlice(self.allocator, "{\"merged_results\":[");
        for (results, 0..) |result, i| {
            if (i > 0) try merged_data.appendSlice(self.allocator, ",");
            try merged_data.appendSlice(self.allocator, result.data);
        }
        try merged_data.appendSlice(self.allocator, "]}");

        return QueryResult{
            .query_id = results[0].query_id,
            .fragment_id = 0, // Merged result
            .shard_id = 0, // Coordinator result
            .status = .success,
            .data = try merged_data.toOwnedSlice(self.allocator),
            .error_message = null,
            .execution_time_ms = total_time,
            .rows_returned = total_rows,
        };
    }

    /// Register a new shard in the registry
    pub fn registerShard(self: *EnhancedQueryTransport, shard: ShardInfo) !void {
        try self.shard_registry.addShard(shard);

        // Initialize shard utilization tracking (PERF-D010: thread-safe)
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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

    /// Get transport statistics (PERF-D010: thread-safe snapshot)
    pub fn getStatistics(self: *EnhancedQueryTransport) TransportStatistics {
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        return @as(u64, @intCast(compat_milliTimestamp()));
    }

    /// Update query execution statistics (PERF-D010: thread-safe)
    fn updateQueryStatistics(self: *EnhancedQueryTransport, execution_time_ms: f64) void {
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.statistics.messages_received == 0) {
            self.statistics.query_latency_ms = execution_time_ms;
        } else {
            const count = @as(f64, @floatFromInt(self.statistics.messages_received));
            self.statistics.query_latency_ms =
                (self.statistics.query_latency_ms * count + execution_time_ms) / (count + 1.0);
        }
    }

    /// Update shard utilization metrics (PERF-D010: thread-safe)
    fn updateShardUtilization(self: *EnhancedQueryTransport, shard_id: u64, execution_time_ms: u64) !void {
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
    /// Serialize a QueryFragment to protobuf for distributed transport
    // CANARY: REQ=REQ-DIST-FRAG-001; FEATURE="Fragment Serialization"; ASPECT=Core; STATUS=TESTED; TEST="serializeFragment produces protobuf payload"; OWNER=distributed; UPDATED=2026-06-11
    /// GAP-0162: Implements fragment serialization using protobuf encoding
    fn serializeFragment(allocator: Allocator, fragment: QueryFragment) ![]u8 {
        var deps: std.ArrayList(u64) = .empty;
        defer deps.deinit(allocator);
        try deps.appendSlice(allocator, fragment.dependencies);

        const proto_fragment = ProtoQueryFragment{
            .fragment_id = fragment.fragment_id,
            .shard_id = fragment.shard_id,
            .query_text = fragment.query_text,
            .dependencies = deps,
            .result_schema = fragment.result_schema,
            .estimated_rows = fragment.estimated_rows,
        };

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, allocator, proto_fragment);
        const body = aw.writer.buffer[0..aw.writer.end];
        return allocator.dupe(u8, body);
    }

    /// Deserialize a QueryFragment from protobuf for distributed transport
    // CANARY: REQ=REQ-DIST-FRAG-002; FEATURE="Fragment Deserialization"; ASPECT=Core; STATUS=TESTED; TEST="deserializeFragment recovers fragment data"; OWNER=distributed; UPDATED=2026-06-11
    /// GAP-0162: Implements fragment deserialization from protobuf
    fn deserializeFragment(allocator: Allocator, data: []const u8) !QueryFragment {
        var reader: std.Io.Reader = .fixed(data);
        var parsed = try protobuf.decode(ProtoQueryFragment, &reader, allocator);
        defer parsed.deinit(allocator);

        const query_text = try allocator.dupe(u8, parsed.query_text);
        const dependencies = try allocator.dupe(u64, parsed.dependencies.items);
        const result_schema = try allocator.dupe(u8, parsed.result_schema);

        return QueryFragment{
            .fragment_id = parsed.fragment_id,
            .shard_id = parsed.shard_id,
            .query_text = query_text,
            .dependencies = dependencies,
            .result_schema = result_schema,
            .estimated_rows = parsed.estimated_rows,
        };
    }

    fn convertToClusterMessage(self: *EnhancedQueryTransport, query_msg: QueryMessage, dest_node: u32) !ClusterMessage {
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 512);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, query_msg);
        const body = aw.writer.buffer[0..aw.writer.end];
        const payload = try self.allocator.dupe(u8, body);

        return ClusterMessage{
            .msg_type = .CLIENT_REQUEST, // Reuse existing cluster message type
            .source_node = self.network_transport.node_id,
            .dest_node = dest_node,
            .term = 0,
            .payload = payload,
        };
    }

    /// Track an active query for coordination and cancellation support
    // CANARY: REQ=REQ-DIST-TRACKER-002; FEATURE="Query Tracking"; ASPECT=Query; STATUS=TESTED; TEST="query tracker lifecycle: track, lookup, remove (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    /// GAP-0054: Implements actual query tracking using HashMap storage
    fn trackActiveQuery(self: *EnhancedQueryTransport, query_id: u64, plan: *const ExecutionPlan, callback: QueryCompletionCallback) !void {
        // Allocate and initialize tracker
        const tracker = try self.allocator.create(QueryTracker);
        tracker.* = QueryTracker{
            .query_id = query_id,
            .start_time = compat_milliTimestamp(),
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
    // CANARY: REQ=REQ-DIST-TRACKER-003; FEATURE="Query Tracker Lookup"; ASPECT=Query; STATUS=TESTED; TEST="query tracker lifecycle: track, lookup, remove (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    /// GAP-0054: Implements actual tracker retrieval from HashMap
    fn getQueryTracker(self: *EnhancedQueryTransport, query_id: u64) ?*QueryTracker {
        return self.active_trackers.get(query_id);
    }

    /// Remove and clean up a query tracker after completion or cancellation
    // CANARY: REQ=REQ-DIST-TRACKER-004; FEATURE="Query Tracker Cleanup"; ASPECT=Query; STATUS=TESTED; TEST="query tracker lifecycle: track, lookup, remove (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
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

    // CANARY: REQ=REQ-DIST-LB-001; FEATURE="Load Balancing"; ASPECT=ShardSelection; STATUS=TESTED; TEST="selectShardForQuery: load balancing strategies (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
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
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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

        {
            self.stats_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.stats_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            for (all_shards, 0..) |shard_id, i| {
                var score: f64 = 0;
                if (self.statistics.shard_utilization.get(shard_id)) |util| {
                    score = util.avg_response_time_ms + @as(f64, util.error_rate) * 1000.0;
                }
                scored_shards[i] = .{ .id = shard_id, .score = score };
            }
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

    /// GAP-0870: mutable lookup for in-place status updates (heartbeats).
    pub fn getShardPtr(self: *ShardRegistry, shard_id: u64) ?*ShardInfo {
        return self.shards.getPtr(shard_id);
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
    pub const HandlerFn = *const fn (*EnhancedQueryTransport, *const QueryMessage) anyerror!void;

    execute_fragment: ?HandlerFn = null,
    fragment_result: ?HandlerFn = null,
    query_cancel: ?HandlerFn = null,
    shard_heartbeat: ?HandlerFn = null,
    shard_registration: ?HandlerFn = null,
    query_plan_request: ?HandlerFn = null,
    query_plan_response: ?HandlerFn = null,
    cross_shard_join: ?HandlerFn = null,
    aggregate_partial: ?HandlerFn = null,
    coordinator_merge: ?HandlerFn = null,

    pub fn init() MessageHandlers {
        return MessageHandlers{};
    }
};

// ---------------------------------------------------------------------------
// Message handler implementations (GAP-0870)
//
// HONESTY CONTRACT: every handler either routes to its real counterpart on
// EnhancedQueryTransport, or returns explicit `error.NotImplemented`, which
// `dispatchQueryMessage` surfaces to the caller.  The previous bodies only
// logged at debug level and dropped the message.
// ---------------------------------------------------------------------------

fn handleExecuteFragment(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    // No local fragment-execution engine is wired to this transport yet —
    // executing an inbound fragment requires routing through the GQL
    // executor with the shard's local store, which is a coordinator-side
    // concern this module does not own.
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleFragmentResult(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    // Real counterpart: handleQueryResult (tracker bookkeeping, completion
    // detection, merge + callback, shard utilization stats).
    const proto_result = message.result orelse return error.InvalidMessage;
    if (proto_result.page != null) {
        // DataPage → row-data conversion is not implemented; refusing is
        // honest — accepting would record a result whose payload we dropped.
        return error.NotImplemented;
    }
    const status: @FieldType(QueryResult, "status") = switch (proto_result.status) {
        .SUCCESS => .success,
        .FAILED => .failed,
        .TIMEOUT => .timeout,
        .CANCELLED => .cancelled,
        .QUERY_STATUS_UNSPECIFIED => return error.InvalidMessage,
    };
    try transport.handleQueryResult(.{
        .query_id = proto_result.query_id,
        .fragment_id = proto_result.fragment_id,
        .shard_id = proto_result.shard_id,
        .status = status,
        .data = "",
        .error_message = proto_result.error_message,
        .execution_time_ms = proto_result.execution_time_ms,
        .rows_returned = proto_result.rows_returned,
    });
}

fn handleQueryCancel(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    // Real counterpart: cancelQuery (tracker removal, fail-loud on unknown id).
    try transport.cancelQuery(message.query_id);
}

fn handleShardHeartbeat(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    // Real counterpart: recordShardHeartbeat (marks the shard online in the
    // registry, fail-loud for unregistered shards).
    try transport.recordShardHeartbeat(message.shard_id);
}

fn handleShardRegistration(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    // The QueryMessage proto carries no registration payload (endpoint,
    // port, partitions) — there is nothing honest to register from this
    // message.  `registerShard` is the real API; callers with shard
    // topology must use it directly.
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleQueryPlanRequest(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleQueryPlanResponse(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleCrossShardJoin(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleAggregatePartial(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

fn handleCoordinatorMerge(transport: *EnhancedQueryTransport, message: *const QueryMessage) anyerror!void {
    _ = transport;
    _ = message;
    return error.NotImplemented;
}

// Unit tests for fragment serialization
// CANARY: REQ=REQ-DIST-FRAG-003; FEATURE="Fragment Serialization Tests"; ASPECT=Testing; STATUS=TESTED; TEST="serializeFragment round-trip preserves data"; OWNER=distributed; UPDATED=2026-06-11
// GAP-0162: Tests for fragment serialization/deserialization

test "serializeFragment produces protobuf payload" {
    const allocator = std.testing.allocator;

    const deps = [_]u64{ 1, 2, 3 };
    const fragment = QueryFragment{
        .fragment_id = 42,
        .shard_id = 7,
        .query_text = "MATCH (n) RETURN n",
        .dependencies = &deps,
        .result_schema = "n:Node",
        .estimated_rows = 1000,
    };

    const payload = try EnhancedQueryTransport.serializeFragment(allocator, fragment);
    defer allocator.free(payload);
    try std.testing.expect(payload.len > 0);

    const recovered = try EnhancedQueryTransport.deserializeFragment(allocator, payload);
    defer {
        allocator.free(recovered.query_text);
        allocator.free(recovered.dependencies);
        allocator.free(recovered.result_schema);
    }

    try std.testing.expectEqual(fragment.fragment_id, recovered.fragment_id);
    try std.testing.expectEqual(fragment.shard_id, recovered.shard_id);
    try std.testing.expectEqualStrings(fragment.query_text, recovered.query_text);
    try std.testing.expectEqual(fragment.dependencies.len, recovered.dependencies.len);
    try std.testing.expectEqualStrings(fragment.result_schema, recovered.result_schema);
    try std.testing.expectEqual(fragment.estimated_rows, recovered.estimated_rows);
}

test "deserializeFragment recovers fragment data" {
    const allocator = std.testing.allocator;

    const deps = [_]u64{ 10, 20 };
    const fragment = QueryFragment{
        .fragment_id = 99,
        .shard_id = 5,
        .query_text = "RETURN 1",
        .dependencies = &deps,
        .result_schema = "x:Int",
        .estimated_rows = 50,
    };

    const payload = try EnhancedQueryTransport.serializeFragment(allocator, fragment);
    defer allocator.free(payload);

    const recovered = try EnhancedQueryTransport.deserializeFragment(allocator, payload);
    defer {
        allocator.free(recovered.query_text);
        allocator.free(recovered.dependencies);
        allocator.free(recovered.result_schema);
    }

    try std.testing.expectEqual(@as(u64, 99), recovered.fragment_id);
    try std.testing.expectEqual(@as(u64, 5), recovered.shard_id);
    try std.testing.expectEqualStrings("RETURN 1", recovered.query_text);
    try std.testing.expectEqual(@as(usize, 2), recovered.dependencies.len);
    try std.testing.expectEqual(@as(u64, 10), recovered.dependencies[0]);
    try std.testing.expectEqual(@as(u64, 20), recovered.dependencies[1]);
    try std.testing.expectEqualStrings("x:Int", recovered.result_schema);
    try std.testing.expectEqual(@as(u64, 50), recovered.estimated_rows);
}

test "serializeFragment round-trip preserves data" {
    const allocator = std.testing.allocator;

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
    const payload = try EnhancedQueryTransport.serializeFragment(allocator, original);
    defer allocator.free(payload);

    const recovered = try EnhancedQueryTransport.deserializeFragment(allocator, payload);
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

    // Create fragment with no dependencies
    const fragment = QueryFragment{
        .fragment_id = 1,
        .shard_id = 1,
        .query_text = "RETURN 42",
        .dependencies = &[_]u64{},
        .result_schema = "x:Int",
        .estimated_rows = 1,
    };

    const payload = try EnhancedQueryTransport.serializeFragment(allocator, fragment);
    defer allocator.free(payload);

    const recovered = try EnhancedQueryTransport.deserializeFragment(allocator, payload);
    defer {
        allocator.free(recovered.query_text);
        allocator.free(recovered.dependencies);
        allocator.free(recovered.result_schema);
    }

    try std.testing.expectEqual(@as(usize, 0), recovered.dependencies.len);
}

// ---------------------------------------------------------------------------
// GAP-0870 dispatch honesty tests — every message type either routes to its
// real counterpart or fails loud through dispatchQueryMessage.
// ---------------------------------------------------------------------------

fn makeTestTransport(allocator: Allocator) !EnhancedQueryTransport {
    // The network transport is never dereferenced by the dispatch paths
    // under test; init only stores the pointer.
    return EnhancedQueryTransport.init(allocator, undefined);
}

test "dispatch: unimplemented message types return error.NotImplemented (GAP-0870)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    const unimplemented = [_]QueryMessageType{
        .EXECUTE_FRAGMENT,
        .SHARD_REGISTRATION,
        .QUERY_PLAN_REQUEST,
        .QUERY_PLAN_RESPONSE,
        .CROSS_SHARD_JOIN,
        .AGGREGATE_PARTIAL,
        .COORDINATOR_MERGE,
    };
    for (unimplemented) |mt| {
        const m = QueryMessage{ .msg_type = mt, .query_id = 1 };
        try std.testing.expectError(error.NotImplemented, transport.dispatchQueryMessage(&m));
    }

    // Unspecified message type is invalid, not ignored.
    const bad = QueryMessage{ .msg_type = .QUERY_MESSAGE_TYPE_UNSPECIFIED };
    try std.testing.expectError(error.InvalidMessage, transport.dispatchQueryMessage(&bad));
}

test "dispatch: QUERY_CANCEL routes to cancelQuery (GAP-0870)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    // Cancel of an untracked query fails loud.
    const unknown = QueryMessage{ .msg_type = .QUERY_CANCEL, .query_id = 404 };
    try std.testing.expectError(error.UnknownQuery, transport.dispatchQueryMessage(&unknown));

    // Track a query, then cancel it through dispatch.
    const tracker = try allocator.create(QueryTracker);
    tracker.* = .{
        .query_id = 42,
        .start_time = 0,
        .fragment_results = std.AutoHashMap(u64, QueryResult).init(allocator),
        .completion_callback = null,
    };
    try transport.active_trackers.put(42, tracker);
    try std.testing.expectEqual(@as(usize, 1), transport.active_trackers.count());

    const cancel = QueryMessage{ .msg_type = .QUERY_CANCEL, .query_id = 42 };
    try transport.dispatchQueryMessage(&cancel);
    try std.testing.expectEqual(@as(usize, 0), transport.active_trackers.count());
}

test "dispatch: FRAGMENT_RESULT routes to handleQueryResult (GAP-0870)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    // A result message without a result payload is invalid, not dropped.
    const empty = QueryMessage{ .msg_type = .FRAGMENT_RESULT, .query_id = 7 };
    try std.testing.expectError(error.InvalidMessage, transport.dispatchQueryMessage(&empty));

    // Track a query, then deliver its (only) fragment result through
    // dispatch: the tracker completes, merges, and is removed.
    const tracker = try allocator.create(QueryTracker);
    tracker.* = .{
        .query_id = 7,
        .start_time = 0,
        .fragment_results = std.AutoHashMap(u64, QueryResult).init(allocator),
        .completion_callback = null,
    };
    try transport.active_trackers.put(7, tracker);

    const msg = QueryMessage{
        .msg_type = .FRAGMENT_RESULT,
        .query_id = 7,
        .fragment_id = 1,
        .shard_id = 3,
        .result = .{
            .query_id = 7,
            .fragment_id = 1,
            .shard_id = 3,
            .status = .SUCCESS,
            .execution_time_ms = 12,
            .rows_returned = 2,
        },
    };
    try transport.dispatchQueryMessage(&msg);
    try std.testing.expectEqual(@as(usize, 0), transport.active_trackers.count());
}

test "dispatch: SHARD_HEARTBEAT routes to recordShardHeartbeat (GAP-0870)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    // Heartbeat from an unregistered shard fails loud.
    const unknown = QueryMessage{ .msg_type = .SHARD_HEARTBEAT, .shard_id = 99 };
    try std.testing.expectError(error.ShardNotFound, transport.dispatchQueryMessage(&unknown));

    // Register a degraded shard; a heartbeat marks it online.
    try transport.registerShard(.{
        .shard_id = 99,
        .node_id = 2,
        .endpoint = "127.0.0.1",
        .port = 3141,
        .status = .degraded,
        .data_partitions = &.{},
    });
    const hb = QueryMessage{ .msg_type = .SHARD_HEARTBEAT, .shard_id = 99 };
    try transport.dispatchQueryMessage(&hb);
    const shard = try transport.shard_registry.getShard(99);
    try std.testing.expect(shard.status == .online);
}

test "query tracker lifecycle: track, lookup, remove (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    // Nothing tracked yet: lookup misses, removal of unknown id is a no-op.
    try std.testing.expectEqual(@as(?*QueryTracker, null), transport.getQueryTracker(11));
    transport.removeQueryTracker(11);

    // Track a query against a minimal execution plan.
    var fragments = [_]QueryFragment{.{
        .fragment_id = 1,
        .shard_id = 3,
        .query_text = "MATCH (n) RETURN n",
        .dependencies = &.{},
        .estimated_rows = 10,
        .result_schema = "mixed",
    }};
    const plan = ExecutionPlan{
        .query_text = "MATCH (n) RETURN n",
        .parameters = &.{},
        .target_shards = &.{3},
        .fragments = &fragments,
        .coordination_strategy = .scatter_gather,
        .estimated_cost = 1.0,
    };
    const noop_cb = struct {
        fn cb(query_id: u64, result: QueryResult) void {
            _ = query_id;
            _ = result;
        }
    }.cb;
    try transport.trackActiveQuery(11, &plan, noop_cb);
    try std.testing.expectEqual(@as(usize, 1), transport.active_trackers.count());

    // Lookup returns the live tracker with the recorded query id.
    const tracker = transport.getQueryTracker(11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 11), tracker.query_id);

    // Removal deallocates and clears the map entry; lookup misses again.
    transport.removeQueryTracker(11);
    try std.testing.expectEqual(@as(usize, 0), transport.active_trackers.count());
    try std.testing.expectEqual(@as(?*QueryTracker, null), transport.getQueryTracker(11));
}

test "selectShardForQuery: load balancing strategies (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var transport = try makeTestTransport(allocator);
    defer transport.deinit();

    // No shards: fail loud.
    try std.testing.expectError(error.NoShardsAvailable, transport.selectShardForQuery(&.{}, null));

    // Single shard: always selected regardless of strategy.
    try std.testing.expectEqual(@as(u64, 7), try transport.selectShardForQuery(&.{7}, null));

    const shards = [_]u64{ 1, 2, 3 };

    // Round-robin: three consecutive picks hit three distinct shards.
    transport.config.load_balancing_strategy = .round_robin;
    const a = try transport.selectShardForQuery(&shards, null);
    const b = try transport.selectShardForQuery(&shards, null);
    const c = try transport.selectShardForQuery(&shards, null);
    try std.testing.expect(a != b and b != c and a != c);

    // Hash-based: same key always routes to the same shard.
    transport.config.load_balancing_strategy = .hash_based;
    const h1 = try transport.selectShardForQuery(&shards, "tenant-42");
    const h2 = try transport.selectShardForQuery(&shards, "tenant-42");
    try std.testing.expectEqual(h1, h2);

    // Least-connections: the shard with the lowest executed-query count wins.
    transport.config.load_balancing_strategy = .least_connections;
    try transport.statistics.shard_utilization.put(1, .{
        .queries_executed = 100,
        .avg_response_time_ms = 1.0,
        .cpu_usage_percent = 0.5,
        .memory_usage_mb = 10.0,
        .error_rate = 0.0,
    });
    try transport.statistics.shard_utilization.put(2, .{
        .queries_executed = 5,
        .avg_response_time_ms = 1.0,
        .cpu_usage_percent = 0.5,
        .memory_usage_mb = 10.0,
        .error_rate = 0.0,
    });
    try transport.statistics.shard_utilization.put(3, .{
        .queries_executed = 50,
        .avg_response_time_ms = 1.0,
        .cpu_usage_percent = 0.5,
        .memory_usage_mb = 10.0,
        .error_rate = 0.0,
    });
    try std.testing.expectEqual(@as(u64, 2), try transport.selectShardForQuery(&shards, null));
}
