// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-001; FEATURE="Distributed Query Transport"; ASPECT=QueryTransport; STATUS=EXEMPT; OWNER=dist; UPDATED=2026-06-11
// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-002; FEATURE="Remote Query Execution"; ASPECT=RemoteExecution; STATUS=EXEMPT; OWNER=dist; UPDATED=2026-06-11

// GAP-0514 Phase 6 P3 (2026-06-11): EVERY marker in this file is EXEMPT —
// query_transport.zig is OUTSIDE the build graph. Its only importer is
// enhanced_query_coordinator.zig, whose only importer is distributed/mod.zig,
// which has ZERO compiled importers (the geode root module imports the
// distributed files individually via src/lib.zig and never pulls mod.zig).
// Code that is never compiled cannot be honestly verified by a test; the
// testable NodeRegistry half was already extracted to node_registry.zig
// (GAP-0889) and is covered by test_query_transport_node_registry.zig.
// Promoting these requires either wiring the mod.zig subtree into the build
// or porting the remaining wire surface to compiled modules.

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
const quic = @import("transport/quic");
const federation = @import("federation.zig");
// GAP-0856: distributed EXPLAIN/PROFILE are node-local only.
const distributed_explain = @import("distributed_explain.zig");
const network_transport = @import("network_transport.zig");
const schema = @import("schema");
const protobuf = @import("protobuf");
const proto_util = @import("../server/proto_util.zig");
const value_utilities = @import("../execution/value_utilities.zig");
const query_runner = @import("../client/query_runner.zig");
const result_utils = @import("result_utils.zig");
const parallel_wrapper = @import("parallel/thread_pool_parallel");
const otel_metrics = @import("otel_metrics");

const logging = @import("logging");
const log = logging.scoped("query_transport");
const Attr = logging.Attr;

const ConnectionProtocolAdapter = struct {
    stream: *quic.QuicClientStream,
    quic_client: *quic.QuicClient,
    timeout_ms: u32,

    fn asProtocolClient(self: *@This()) query_runner.ProtocolClient {
        return .{
            .context = self,
            .sendClientMessageFn = sendClientMessage,
            .readServerMessageFn = readServerMessage,
        };
    }

    fn sendClientMessage(
        proto: *query_runner.ProtocolClient,
        allocator: std.mem.Allocator,
        msg: schema.QuicClientMessage,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(proto.context));
        try writeProtoMessage(allocator, self.stream, msg);
    }

    fn readServerMessage(
        proto: *query_runner.ProtocolClient,
        allocator: std.mem.Allocator,
        timeout_secs: u32,
    ) !schema.QuicServerMessage {
        const self: *@This() = @ptrCast(@alignCast(proto.context));
        const requested_ms_u64 = @max(@as(u64, timeout_secs), 1) * 1000;
        const requested_ms: u32 = if (requested_ms_u64 > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(requested_ms_u64);
        return try readProtoMessage(allocator, self.stream, self.quic_client, @min(self.timeout_ms, requested_ms));
    }
};

/// Query-specific transport for distributed execution
pub const QueryTransport = struct {
    allocator: std.mem.Allocator,
    network_transport: *network_transport.NetworkTransport,
    connection_pool: ConnectionPool,
    timeout_ms: u32 = 30000, // 30 second default timeout
    retry_attempts: u32 = 3,
    page_size: u32 = 1000,
    pool: parallel_wrapper.ParallelPool, // PERF-D007: Reuse pool across queries

    pub fn init(allocator: std.mem.Allocator, net_transport: *network_transport.NetworkTransport) !QueryTransport {
        return QueryTransport{
            .allocator = allocator,
            .network_transport = net_transport,
            .connection_pool = try ConnectionPool.init(allocator),
            .pool = parallel_wrapper.ParallelPool.init(allocator, null),
        };
    }

    pub fn deinit(self: *QueryTransport) void {
        self.pool.deinit();
        self.connection_pool.deinit();
    }

    /// Execute query on remote node
    // CANARY: REQ=REQ-OTEL-METRICS-014; FEATURE="OTel Instrumentation"; ASPECT=DbClientMetrics; STATUS=EXEMPT; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-06-11
    pub fn executeRemoteQuery(
        self: *QueryTransport,
        node_id: u32,
        query: federation.FederatedQuery,
    ) !federation.QueryResults {
        return self.executeRemoteQueryWithEnvelope(node_id, query, null);
    }

    // CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=ExecuteRemoteQuery; STATUS=EXEMPT; OWNER=security; UPDATED=2026-06-11
    // GPS Phase 7 Task 7-6: envelope-aware variant used by executeBatchQueries
    // when the NodeQuery carries a principal_envelope_bytes blob.
    pub fn executeRemoteQueryWithEnvelope(
        self: *QueryTransport,
        node_id: u32,
        query: federation.FederatedQuery,
        principal_envelope_bytes: ?[]const u8,
    ) !federation.QueryResults {
        const start_time = compat_milliTimestamp();

        // Get or create connection to node
        var connection = try self.connection_pool.getConnection(node_id);
        defer self.connection_pool.releaseConnection(connection);

        // Build a low-cardinality server_addr for db.client.* OTel attributes.
        // Derived from the connection's node registry entry (or the fallback
        // default) — always a static cluster peer address, never user data.
        var addr_buf: [64]u8 = undefined;
        const addr_info = connection.getNodeAddress();
        const server_addr: []const u8 = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ addr_info.host, addr_info.port }) catch "unknown";

        otel_metrics.incDbClientConnection(server_addr, .used);
        defer otel_metrics.decDbClientConnection(server_addr, .used);

        try connection.ensureSession(self.timeout_ms);
        var result = connection.executeQueryWithEnvelope(self.allocator, query, self.timeout_ms, self.page_size, principal_envelope_bytes) catch |err| {
            const elapsed_s: f64 = @as(f64, @floatFromInt(compat_milliTimestamp() - start_time)) / 1000.0;
            otel_metrics.recordDbClientOperation("REMOTE", server_addr, elapsed_s, .error_, @errorName(err));
            return err;
        };
        result.execution_time_ms = @as(u64, @intCast(compat_milliTimestamp() - start_time));
        const elapsed_s: f64 = @as(f64, @floatFromInt(result.execution_time_ms)) / 1000.0;
        otel_metrics.recordDbClientOperation("REMOTE", server_addr, elapsed_s, .success, null);
        return result;
    }

    /// Send batch of queries to multiple nodes in parallel
    // CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=BatchQueries; STATUS=EXEMPT; OWNER=security; UPDATED=2026-06-11
    pub fn executeBatchQueries(
        self: *QueryTransport,
        queries: []const NodeQuery,
    ) ![]federation.QueryResults {
        var results = try self.allocator.alloc(federation.QueryResults, queries.len);
        errdefer self.allocator.free(results);

        if (queries.len == 0) {
            return results;
        }

        if (!parallel_wrapper.shouldUseParallelism(queries.len, parallel_wrapper.Thresholds.forEach)) {
            for (queries, 0..) |query, i| {
                // GPS Phase 7 Task 7-6: forward per-query principal envelope bytes.
                results[i] = self.executeRemoteQueryWithEnvelope(query.node_id, query.query, query.principal_envelope_bytes) catch |err| {
                    for (results[0..i]) |*res| res.deinit(self.allocator);
                    return err;
                };
            }
            return results;
        }

        var errors = try self.allocator.alloc(?anyerror, queries.len);
        defer self.allocator.free(errors);
        for (errors) |*e| e.* = null;

        // PERF-D007: Reuse struct-level pool instead of creating per-call
        const Context = struct {
            transport: *QueryTransport,
            queries: []const NodeQuery,
            results: []federation.QueryResults,
            errors: []?anyerror,
        };

        const ctx = Context{
            .transport = self,
            .queries = queries,
            .results = results,
            .errors = errors,
        };

        parallel_wrapper.parallelForEach(
            &self.pool,
            0,
            queries.len,
            ctx,
            struct {
                fn work(_: *parallel_wrapper.Task, idx: usize, c: Context) void {
                    // GPS Phase 7 Task 7-6: forward per-query principal envelope bytes.
                    c.results[idx] = c.transport.executeRemoteQueryWithEnvelope(
                        c.queries[idx].node_id,
                        c.queries[idx].query,
                        c.queries[idx].principal_envelope_bytes,
                    ) catch |err| {
                        c.errors[idx] = err;
                        return;
                    };
                }
            }.work,
            parallel_wrapper.Thresholds.forEach,
        );

        for (errors, 0..) |err, idx| {
            if (err) |e| {
                for (results, 0..) |*res, j| {
                    if (errors[j] == null) res.deinit(self.allocator);
                }
                return e;
            }
        }

        return results;
    }

    /// Stream query results from remote node
    pub fn streamRemoteQuery(
        self: *QueryTransport,
        node_id: u32,
        query: federation.FederatedQuery,
        result_handler: ResultHandler,
    ) !void {
        var connection = try self.connection_pool.getConnection(node_id);
        defer self.connection_pool.releaseConnection(connection);

        try connection.ensureSession(self.timeout_ms);
        try connection.streamQuery(self.allocator, query, self.timeout_ms, self.page_size, result_handler);
    }
};

/// Connection pool for efficient connection reuse
const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoHashMap(u32, *Connection),
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    max_connections_per_node: u32 = 10,

    pub fn init(allocator: std.mem.Allocator) !ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .connections = std.AutoHashMap(u32, *Connection).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }

    pub fn getConnection(self: *ConnectionPool, node_id: u32) !*Connection {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.connections.get(node_id)) |conn| {
            if (conn.isHealthy()) {
                return conn;
            } else {
                // Connection unhealthy, recreate
                conn.deinit();
                self.allocator.destroy(conn);
                _ = self.connections.remove(node_id);
            }
        }

        // Create new connection
        const connection = try self.allocator.create(Connection);
        connection.* = try Connection.init(self.allocator, node_id);
        try self.connections.put(node_id, connection);

        return connection;
    }

    pub fn releaseConnection(self: *ConnectionPool, connection: *Connection) void {
        _ = self;
        _ = connection;
        // For now, keep connections alive for reuse
        // In the future, implement connection pooling limits
    }
};

// CANARY: REQ=REQ-DIST-CONN-001; FEATURE="Distributed Query Connection"; ASPECT=ConnectionInit; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-06-11
/// Individual connection to a remote node
const Connection = struct {
    allocator: std.mem.Allocator,
    node_id: u32,
    quic_client: ?quic.QuicClient = null,
    stream: ?*quic.QuicClientStream = null,
    session_id: ?[]u8 = null,
    last_activity: i64,
    is_connected: bool = false,
    node_registry: ?*NodeRegistry = null,

    pub fn init(allocator: std.mem.Allocator, node_id: u32) !Connection {
        return Connection{
            .allocator = allocator,
            .node_id = node_id,
            .last_activity = compat_milliTimestamp(),
        };
    }

    pub fn initWithRegistry(allocator: std.mem.Allocator, node_id: u32, registry: *NodeRegistry) !Connection {
        return Connection{
            .allocator = allocator,
            .node_id = node_id,
            .last_activity = compat_milliTimestamp(),
            .node_registry = registry,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.stream) |s| {
            s.deinit();
            self.stream = null;
        }
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
        if (self.quic_client) |*client| {
            client.deinit();
        }
    }

    pub fn isHealthy(self: *Connection) bool {
        if (!self.is_connected) return false;

        // Check if connection is too old (5 minutes)
        const max_age_ms = 5 * 60 * 1000;
        const age = compat_milliTimestamp() - self.last_activity;

        return age < max_age_ms;
    }

    pub fn ensureSession(self: *Connection, timeout_ms: u32) !void {
        if (!self.is_connected) {
            try self.connect(timeout_ms);
        }
        if (self.session_id == null) {
            return error.NotConnected;
        }
    }

    pub fn executeQuery(
        self: *Connection,
        allocator: std.mem.Allocator,
        query: federation.FederatedQuery,
        timeout_ms: u32,
        page_size: u32,
    ) !federation.QueryResults {
        return self.executeQueryWithEnvelope(allocator, query, timeout_ms, page_size, null);
    }

    // CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=ConnectionExecuteQuery; STATUS=EXEMPT; OWNER=security; UPDATED=2026-06-11
    // GPS Phase 7 Task 7-6: envelope-aware variant. When principal_envelope_bytes
    // is non-null it is forwarded to the QueryOptions so the server receives it
    // in ExecuteRequest field 4 and can reconstruct the caller's Principal.
    pub fn executeQueryWithEnvelope(
        self: *Connection,
        allocator: std.mem.Allocator,
        query: federation.FederatedQuery,
        timeout_ms: u32,
        page_size: u32,
        principal_envelope_bytes: ?[]const u8,
    ) !federation.QueryResults {
        if (self.stream == null or self.quic_client == null or self.session_id == null) {
            return error.NotConnected;
        }

        const params = try buildParams(allocator, query.parameters);

        var columns = std.ArrayList(protocol.ColumnDef).init(allocator);
        errdefer {
            for (columns.items) |col| {
                allocator.free(col.name);
                allocator.free(col.data_type);
            }
            columns.deinit(allocator);
        }
        var rows = std.ArrayList(protocol.BindingRow).init(allocator);
        errdefer {
            for (rows.items) |row| freeBindingRow(allocator, row);
            rows.deinit(allocator);
        }
        var order_keys = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (order_keys.items) |k| allocator.free(k);
            order_keys.deinit(allocator);
        }

        var ordered = false;
        const ResultsConsumer = struct {
            allocator: std.mem.Allocator,
            columns: *std.ArrayList(protocol.ColumnDef),
            rows: *std.ArrayList(protocol.BindingRow),
            order_keys: *std.ArrayList([]const u8),
            ordered: *bool,

            fn handleEvent(
                consumer: *query_runner.QueryEventConsumer,
                allocator_: std.mem.Allocator,
                event: query_runner.QueryEvent,
                request_id: u64,
            ) !query_runner.QueryEventSummary {
                _ = request_id;
                const self: *@This() = @ptrCast(@alignCast(consumer.context));
                _ = self.allocator;
                return switch (event) {
                    .hello_failure => error.AuthFailed,
                    .execute => |exec_resp| blk: {
                        if (exec_resp.payload) |payload| switch (payload) {
                            .schema => |s| {
                                for (s.columns.items) |col| {
                                    const name = try allocator_.dupe(u8, col.name);
                                    const dtype = if (col.type.len > 0)
                                        try allocator_.dupe(u8, col.type)
                                    else
                                        try allocator_.dupe(u8, "ANY");
                                    try self.columns.append(allocator_, .{ .name = name, .data_type = dtype });
                                }
                                break :blk .{ .schema_received = true };
                            },
                            .page => |page| {
                                try captureOrderMeta(allocator_, page, self.ordered, self.order_keys);
                                try appendPageRows(allocator_, page, self.rows);
                                break :blk .{
                                    .saw_page = true,
                                    .page_final = page.final,
                                };
                            },
                            .@"error" => return error.RemoteExecutionFailed,
                            // GAP-0856: node-local only — see distributed_explain.zig.
                            .explain => return distributed_explain.rejectDistributedPlanPayload(.explain),
                            .profile => return distributed_explain.rejectDistributedPlanPayload(.profile),
                            .metrics, .heartbeat => {},
                        };
                        break :blk .{};
                    },
                };
            }
        };

        var adapter = ConnectionProtocolAdapter{
            .stream = self.stream.?,
            .quic_client = &self.quic_client.?,
            .timeout_ms = timeout_ms,
        };
        var protocol_client = adapter.asProtocolClient();
        var consumer_state = ResultsConsumer{
            .allocator = allocator,
            .columns = &columns,
            .rows = &rows,
            .order_keys = &order_keys,
            .ordered = &ordered,
        };
        var consumer = query_runner.QueryEventConsumer{
            .context = &consumer_state,
            .handleEventFn = ResultsConsumer.handleEvent,
        };

        try query_runner.consumeQuery(allocator, &protocol_client, .{
            .session_id = self.session_id.?,
            .query_text = query.query_text,
            .format = "json",
            .timeout_secs = @max(@as(u32, @intCast((@as(u64, timeout_ms) + 999) / 1000)), 1),
            .page_size = page_size,
            .params = params,
            .principal_envelope_bytes = principal_envelope_bytes,
        }, &consumer);

        const rows_slice = try rows.toOwnedSlice(allocator);
        const schema_slice = try columns.toOwnedSlice(allocator);
        const order_keys_slice = try order_keys.toOwnedSlice(allocator);
        self.last_activity = compat_milliTimestamp();

        return federation.QueryResults{
            .rows = rows_slice,
            .schema = schema_slice,
            .execution_time_ms = 0,
            .ordered = ordered,
            .order_keys = order_keys_slice,
            .order_dirs = &.{},
            .nulls_first = true,
        };
    }

    pub fn streamQuery(
        self: *Connection,
        allocator: std.mem.Allocator,
        query: federation.FederatedQuery,
        timeout_ms: u32,
        page_size: u32,
        handler: ResultHandler,
    ) !void {
        if (self.stream == null or self.quic_client == null or self.session_id == null) {
            return error.NotConnected;
        }

        const params = try buildParams(allocator, query.parameters);
        const StreamConsumer = struct {
            handler: ResultHandler,

            fn handleEvent(
                consumer: *query_runner.QueryEventConsumer,
                allocator_: std.mem.Allocator,
                event: query_runner.QueryEvent,
                request_id: u64,
            ) !query_runner.QueryEventSummary {
                const self: *@This() = @ptrCast(@alignCast(consumer.context));
                return switch (event) {
                    .hello_failure => error.AuthFailed,
                    .execute => |exec_resp| blk: {
                        if (exec_resp.payload) |payload| switch (payload) {
                            .schema => break :blk .{ .schema_received = true },
                            .page => |page| {
                                try emitChunkFromPage(allocator_, page, self.handler, request_id);
                                break :blk .{
                                    .saw_page = true,
                                    .page_final = page.final,
                                };
                            },
                            .@"error" => return error.RemoteExecutionFailed,
                            // GAP-0856: node-local only — see distributed_explain.zig.
                            .explain => return distributed_explain.rejectDistributedPlanPayload(.explain),
                            .profile => return distributed_explain.rejectDistributedPlanPayload(.profile),
                            .metrics, .heartbeat => {},
                        };
                        break :blk .{};
                    },
                };
            }
        };

        var adapter = ConnectionProtocolAdapter{
            .stream = self.stream.?,
            .quic_client = &self.quic_client.?,
            .timeout_ms = timeout_ms,
        };
        var protocol_client = adapter.asProtocolClient();
        var consumer_state = StreamConsumer{ .handler = handler };
        var consumer = query_runner.QueryEventConsumer{
            .context = &consumer_state,
            .handleEventFn = StreamConsumer.handleEvent,
        };

        try query_runner.consumeQuery(allocator, &protocol_client, .{
            .session_id = self.session_id.?,
            .query_text = query.query_text,
            .format = "json",
            .timeout_secs = @max(@as(u32, @intCast((@as(u64, timeout_ms) + 999) / 1000)), 1),
            .page_size = page_size,
            .params = params,
        }, &consumer);
        self.last_activity = compat_milliTimestamp();
    }

    // GAP-0144: Secure TLS connections for distributed queries
    // CANARY: REQ=REQ-DIST-TLS-001; FEATURE="Distributed TLS"; ASPECT=Security; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-06-11
    fn connect(self: *Connection, timeout_ms: u32) !void {
        // Get node address from registry if available, otherwise use default pattern
        const node_info = self.getNodeAddress();

        // Initialize QUIC client
        self.quic_client = quic.QuicClient.init(self.allocator);

        // GAP-0144: Use TLS verification for inter-node communication
        // SEC-D006: Consolidated to cluster_auth.isInsecureModeAllowed()
        const allow_insecure = cluster_auth.isInsecureModeAllowed();
        if (allow_insecure) {
            log.warn("SECURITY WARNING: Inter-node TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
        }

        // Connect with TLS verification by default (skip_verify=false)
        self.quic_client.?.connectInsecure(node_info.host, node_info.port, allow_insecure) catch |err| {
            // Log connection failure
            log.err("Failed to connect to node", &.{
                Attr.uint("node_id", self.node_id),
                Attr.string("host", node_info.host),
                Attr.uint("port", node_info.port),
                Attr.string("error", @errorName(err)),
            });
            return error.ConnectionFailed;
        };

        try self.quic_client.?.waitForHandshake(5);
        self.stream = try self.quic_client.?.getStream();

        // HELLO handshake with cluster token authentication
        const cluster_auth = @import("cluster_auth.zig");
        const hello_req = cluster_auth.buildClusterHelloRequest(self.allocator) catch schema.HelloRequest{
            .username = "",
            .password = "",
            .tenant_id = null,
            .client_name = "geode-distributed",
            .client_version = "",
            .wanted_conformance = "",
        };
        try writeProtoMessage(self.allocator, self.stream.?, .{ .hello = hello_req });

        var hello_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer hello_arena.deinit();
        const resp = try readProtoMessage(hello_arena.allocator(), self.stream.?, &self.quic_client.?, timeout_ms);
        switch (resp) {
            .hello => |h| {
                if (!h.success) return error.AuthFailed;
                if (h.session_id.len > 0) {
                    self.session_id = try self.allocator.dupe(u8, h.session_id);
                }
            },
            else => return error.ProtocolError,
        }

        self.is_connected = true;
        self.last_activity = compat_milliTimestamp();
    }

    /// Get node address from registry or use default cluster naming convention
    fn getNodeAddress(self: *Connection) struct { host: []const u8, port: u16 } {
        if (self.node_registry) |registry| {
            if (registry.getNodeInfo(self.node_id)) |info| {
                return .{ .host = info.host, .port = info.port };
            }
        }

        // Default cluster naming convention: node-{id}.cluster.local:3141
        // Note: In production, always use registry for actual addresses
        return .{ .host = "localhost", .port = 3141 };
    }
};

/// Node registry for distributed cluster - tracks node addresses.
/// GAP-0889: canonical definition extracted to node_registry.zig so the
/// standalone unit tests exercise the real type (no drift-prone copy).
// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_REGISTRY_001_NodeCRUD; OWNER=distributed; UPDATED=2026-06-11
pub const NodeRegistry = @import("node_registry.zig").NodeRegistry;

/// Result chunk for streaming
const ResultChunk = struct {
    query_id: u64,
    rows: []protocol.BindingRow,
    is_final: bool,
    error_message: ?[]const u8 = null,
};

/// Node query for batch execution
pub const NodeQuery = struct {
    node_id: u32,
    query: federation.FederatedQuery,
    // CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=NodeQuery; STATUS=EXEMPT; OWNER=security; UPDATED=2026-06-11
    // GPS Phase 7 Task 7-6: optional serialised principal_envelope blob produced
    // by the coordinator calling distributed.principal_envelope.serialize().
    // When present, the shard worker unpacks it and uses the forwarded identity
    // instead of the generic "geode-coordinator" internal principal.
    // Null preserves the previous behaviour (identity = internal_service).
    principal_envelope_bytes: ?[]const u8 = null,
};

/// Result handler for streaming queries
pub const ResultHandler = fn (ResultChunk) anyerror!void;

fn buildParams(allocator: std.mem.Allocator, values: []const protocol.Value) !std.ArrayList(schema.Param) {
    var params = std.ArrayList(schema.Param).init(allocator);
    try params.ensureTotalCapacity(allocator, values.len);
    for (values, 0..) |val, idx| {
        const name = try std.fmt.allocPrint(allocator, "p{d}", .{idx + 1});
        const proto_val = try proto_util.valueToProto(allocator, val);
        try params.append(allocator, schema.Param{ .name = name, .value = proto_val });
    }
    return params;
}

fn freeParams(allocator: std.mem.Allocator, params: *std.ArrayList(schema.Param)) void {
    for (params.items) |*p| {
        p.deinit(allocator);
    }
    params.deinit(allocator);
}

fn appendPageRows(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    rows: *std.ArrayList(protocol.BindingRow),
) !void {
    for (page.rows.items) |row| {
        var cols = try allocator.alloc(protocol.Value, row.values.items.len);
        errdefer {
            for (cols) |v| value_utilities.freeValue(allocator, v);
            allocator.free(cols);
        }
        for (row.values.items, 0..) |val, idx| {
            cols[idx] = try proto_util.protoValueToValue(allocator, val, 0);
        }
        try rows.append(allocator, .{ .cols = cols });
    }
}

fn emitChunkFromPage(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    handler: ResultHandler,
    query_id: u64,
) !void {
    var rows = std.ArrayList(protocol.BindingRow).init(allocator);
    defer {
        for (rows.items) |row| freeBindingRow(allocator, row);
        rows.deinit(allocator);
    }
    try appendPageRows(allocator, page, &rows);
    const chunk = ResultChunk{
        .query_id = query_id,
        .rows = rows.items,
        .is_final = page.final,
    };
    try handler(chunk);
}

const freeBindingRow = result_utils.freeBindingRow;

fn captureOrderMeta(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    ordered: *bool,
    order_keys: *std.ArrayList([]const u8),
) !void {
    if (page.ordered) ordered.* = true;
    if (order_keys.items.len == 0 and page.order_keys.items.len > 0) {
        for (page.order_keys.items) |key| {
            try order_keys.append(allocator, try allocator.dupe(u8, key));
        }
    }
}

fn writeProtoMessage(allocator: std.mem.Allocator, stream: *quic.QuicClientStream, msg: schema.QuicClientMessage) !void {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    const packet = schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const written = aw.writer.buffer[0..aw.writer.end];
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(written.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(written);
}

fn readProtoMessage(
    allocator: std.mem.Allocator,
    stream: *quic.QuicClientStream,
    client: *quic.QuicClient,
    timeout_ms: u32,
) !schema.QuicServerMessage {
    var len_buf: [4]u8 = undefined;
    var total_read: usize = 0;
    const start = compat_milliTimestamp();
    while (total_read < len_buf.len) {
        const n = stream.read(len_buf[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (compat_milliTimestamp() - start > timeout_ms) return error.Timeout;
                try client.poll(5);
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidMessage;
    if (msg_len > 16 * 1024 * 1024) return error.FrameTooLarge;
    const msg_bytes = try allocator.alloc(u8, msg_len);
    defer allocator.free(msg_bytes);

    total_read = 0;
    while (total_read < msg_len) {
        const n = stream.read(msg_bytes[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (compat_milliTimestamp() - start > timeout_ms) return error.Timeout;
                try client.poll(5);
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    var reader: std.Io.Reader = .fixed(msg_bytes);
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}
