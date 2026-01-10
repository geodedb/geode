// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-001; FEATURE="Distributed Query Transport"; ASPECT=QueryTransport; STATUS=IMPL; TEST=TestCANARY_REQ_DIST_QUERY_TRANSPORT_001_QueryTransport; OWNER=dist; UPDATED=2025-10-05
// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-002; FEATURE="Remote Query Execution"; ASPECT=RemoteExecution; STATUS=IMPL; TEST=TestCANARY_REQ_DIST_QUERY_TRANSPORT_002_RemoteExecution; OWNER=dist; UPDATED=2025-10-05

const std = @import("std");
const protocol = @import("../protocol.zig");
const quic = @import("../transport/quic.zig");
const federation = @import("federation.zig");
const network_transport = @import("network_transport.zig");

/// Query-specific transport for distributed execution
pub const QueryTransport = struct {
    allocator: std.mem.Allocator,
    network_transport: *network_transport.NetworkTransport,
    connection_pool: ConnectionPool,
    timeout_ms: u32 = 30000, // 30 second default timeout
    retry_attempts: u32 = 3,

    pub fn init(allocator: std.mem.Allocator, network_transport: *network_transport.NetworkTransport) !QueryTransport {
        return QueryTransport{
            .allocator = allocator,
            .network_transport = network_transport,
            .connection_pool = try ConnectionPool.init(allocator),
        };
    }

    pub fn deinit(self: *QueryTransport) void {
        self.connection_pool.deinit();
    }

    /// Execute query on remote node
    pub fn executeRemoteQuery(
        self: *QueryTransport,
        node_id: u32,
        query: federation.FederatedQuery,
    ) !federation.QueryResults {
        const start_time = std.time.milliTimestamp();

        // Get or create connection to node
        var connection = try self.connection_pool.getConnection(node_id);
        defer self.connection_pool.releaseConnection(connection);

        // Send query request
        const request = QueryRequest{
            .query_id = generateQueryId(),
            .query_text = query.query_text,
            .parameters = query.parameters,
            .timeout_ms = self.timeout_ms,
            .consistency_level = query.consistency_level,
        };

        try self.sendQueryRequest(connection, request);

        // Wait for response with timeout
        const response = try self.receiveQueryResponse(connection);

        const execution_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

        return federation.QueryResults{
            .rows = response.rows,
            .schema = response.schema,
            .execution_time_ms = execution_time,
            .ordered = response.ordered,
            .node_id = node_id,
        };
    }

    /// Send batch of queries to multiple nodes in parallel
    pub fn executeBatchQueries(
        self: *QueryTransport,
        queries: []const NodeQuery,
    ) ![]federation.QueryResults {
        var results = try self.allocator.alloc(federation.QueryResults, queries.len);
        errdefer self.allocator.free(results);

        // Use thread pool for parallel execution
        var threads = try self.allocator.alloc(std.Thread, queries.len);
        defer self.allocator.free(threads);

        var contexts = try self.allocator.alloc(QueryContext, queries.len);
        defer self.allocator.free(contexts);

        // Start all queries in parallel
        for (queries, 0..) |query, i| {
            contexts[i] = QueryContext{
                .transport = self,
                .query = query,
                .result = &results[i],
                .error_state = null,
            };

            threads[i] = try std.Thread.spawn(.{}, executeQueryThread, .{&contexts[i]});
        }

        // Wait for all queries to complete
        for (threads) |thread| {
            thread.join();
        }

        // Check for errors
        for (contexts) |context| {
            if (context.error_state) |err| {
                return err;
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

        const request = QueryRequest{
            .query_id = generateQueryId(),
            .query_text = query.query_text,
            .parameters = query.parameters,
            .timeout_ms = self.timeout_ms,
            .consistency_level = query.consistency_level,
            .streaming = true,
        };

        try self.sendQueryRequest(connection, request);

        // Stream results as they arrive
        while (true) {
            const chunk = self.receiveResultChunk(connection) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            try result_handler(chunk);

            if (chunk.is_final) break;
        }
    }

    // Private implementation methods

    fn sendQueryRequest(self: *QueryTransport, connection: *Connection, request: QueryRequest) !void {
        // Serialize request to JSON
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try serializeQueryRequest(buffer.writer(), request);

        // Send with retry logic
        var attempts: u32 = 0;
        while (attempts < self.retry_attempts) : (attempts += 1) {
            connection.send(buffer.items) catch |err| {
                if (attempts == self.retry_attempts - 1) return err;

                // Exponential backoff
                const delay_ms = @as(u64, 100) << @intCast(attempts);
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            };

            break;
        }
    }

    fn receiveQueryResponse(self: *QueryTransport, connection: *Connection) !QueryResponse {
        // Receive with timeout
        const timeout_ns = @as(u64, self.timeout_ms) * std.time.ns_per_ms;
        const data = try connection.receiveWithTimeout(self.allocator, timeout_ns);
        defer self.allocator.free(data);

        return try deserializeQueryResponse(self.allocator, data);
    }

    fn receiveResultChunk(self: *QueryTransport, connection: *Connection) !ResultChunk {
        const data = try connection.receive(self.allocator);
        defer self.allocator.free(data);

        return try deserializeResultChunk(self.allocator, data);
    }

    fn generateQueryId() u64 {
        // Simple timestamp-based query ID
        return @bitCast(std.time.nanoTimestamp());
    }
};

/// Connection pool for efficient connection reuse
const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoHashMap(u32, *Connection),
    mutex: std.Thread.Mutex = .{},
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
        self.mutex.lock();
        defer self.mutex.unlock();

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

// CANARY: REQ=REQ-DIST-CONN-001; FEATURE="Distributed Query Connection"; ASPECT=ConnectionInit; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
/// Individual connection to a remote node
const Connection = struct {
    allocator: std.mem.Allocator,
    node_id: u32,
    quic_client: ?quic.QuicClient = null,
    last_activity: i64,
    is_connected: bool = false,
    node_registry: ?*NodeRegistry = null,

    pub fn init(allocator: std.mem.Allocator, node_id: u32) !Connection {
        return Connection{
            .allocator = allocator,
            .node_id = node_id,
            .last_activity = std.time.milliTimestamp(),
        };
    }

    pub fn initWithRegistry(allocator: std.mem.Allocator, node_id: u32, registry: *NodeRegistry) !Connection {
        return Connection{
            .allocator = allocator,
            .node_id = node_id,
            .last_activity = std.time.milliTimestamp(),
            .node_registry = registry,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.quic_client) |*client| {
            client.deinit();
        }
    }

    pub fn isHealthy(self: *Connection) bool {
        if (!self.is_connected) return false;

        // Check if connection is too old (5 minutes)
        const max_age_ms = 5 * 60 * 1000;
        const age = std.time.milliTimestamp() - self.last_activity;

        return age < max_age_ms;
    }

    pub fn send(self: *Connection, data: []const u8) !void {
        if (!self.is_connected) {
            try self.connect();
        }

        if (self.quic_client) |*client| {
            try client.send(data);
            self.last_activity = std.time.milliTimestamp();
        } else {
            return error.NotConnected;
        }
    }

    pub fn receive(self: *Connection, allocator: std.mem.Allocator) ![]u8 {
        if (self.quic_client) |*client| {
            const data = try client.receive(allocator);
            self.last_activity = std.time.milliTimestamp();
            return data;
        } else {
            return error.NotConnected;
        }
    }

    pub fn receiveWithTimeout(self: *Connection, allocator: std.mem.Allocator, timeout_ns: u64) ![]u8 {
        if (self.quic_client) |*client| {
            const data = try client.receiveWithTimeout(allocator, timeout_ns);
            self.last_activity = std.time.milliTimestamp();
            return data;
        } else {
            return error.NotConnected;
        }
    }

    fn connect(self: *Connection) !void {
        // Get node address from registry if available, otherwise use default pattern
        const node_info = self.getNodeAddress();

        // Initialize QUIC client
        self.quic_client = quic.QuicClient.init(self.allocator);

        // Connect to the remote node using insecure connection for cluster-internal communication
        // In production, use proper TLS with cluster certificates
        self.quic_client.?.connectInsecure(node_info.host, node_info.port, true) catch |err| {
            // Log connection failure
            std.log.err("Failed to connect to node {d} at {s}:{d}: {}", .{ self.node_id, node_info.host, node_info.port, err });
            return error.ConnectionFailed;
        };

        self.is_connected = true;
        self.last_activity = std.time.milliTimestamp();
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

/// Node registry for distributed cluster - tracks node addresses
// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=IMPL; OWNER=distributed; UPDATED=2026-01-10
pub const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u32, NodeInfo),

    pub const NodeInfo = struct {
        node_id: u32,
        host: []const u8,
        port: u16,
        status: NodeStatus,
        last_heartbeat: i64,
    };

    pub const NodeStatus = enum {
        active,
        inactive,
        unknown,
    };

    pub fn init(allocator: std.mem.Allocator) !NodeRegistry {
        return NodeRegistry{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u32, NodeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.nodes.deinit();
    }

    pub fn registerNode(self: *NodeRegistry, node_id: u32, host: []const u8, port: u16) !void {
        try self.nodes.put(node_id, NodeInfo{
            .node_id = node_id,
            .host = host,
            .port = port,
            .status = .active,
            .last_heartbeat = std.time.milliTimestamp(),
        });
    }

    pub fn getNodeInfo(self: *NodeRegistry, node_id: u32) ?NodeInfo {
        return self.nodes.get(node_id);
    }

    pub fn updateHeartbeat(self: *NodeRegistry, node_id: u32) void {
        if (self.nodes.getPtr(node_id)) |info| {
            info.last_heartbeat = std.time.milliTimestamp();
            info.status = .active;
        }
    }

    pub fn markInactive(self: *NodeRegistry, node_id: u32) void {
        if (self.nodes.getPtr(node_id)) |info| {
            info.status = .inactive;
        }
    }
};

/// Query request message
const QueryRequest = struct {
    query_id: u64,
    query_text: []const u8,
    parameters: []const protocol.Value,
    timeout_ms: u32,
    consistency_level: federation.ConsistencyLevel,
    streaming: bool = false,
};

/// Query response message
const QueryResponse = struct {
    query_id: u64,
    rows: []protocol.BindingRow,
    schema: []protocol.Column,
    ordered: bool,
    error_message: ?[]const u8 = null,
};

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
};

/// Query execution context for parallel processing
const QueryContext = struct {
    transport: *QueryTransport,
    query: NodeQuery,
    result: *federation.QueryResults,
    error_state: ?anyerror,
};

/// Result handler for streaming queries
pub const ResultHandler = fn (ResultChunk) anyerror!void;

// Thread function for parallel query execution
fn executeQueryThread(context: *QueryContext) void {
    context.result.* = context.transport.executeRemoteQuery(
        context.query.node_id,
        context.query.query,
    ) catch |err| {
        context.error_state = err;
        return;
    };
}

// Serialization functions
fn serializeQueryRequest(writer: anytype, request: QueryRequest) !void {
    try std.json.stringify(request, .{}, writer);
}

fn deserializeQueryResponse(allocator: std.mem.Allocator, data: []const u8) !QueryResponse {
    const parsed = try std.json.parseFromSlice(QueryResponse, allocator, data, .{});
    defer parsed.deinit();
    return parsed.value;
}

fn deserializeResultChunk(allocator: std.mem.Allocator, data: []const u8) !ResultChunk {
    const parsed = try std.json.parseFromSlice(ResultChunk, allocator, data, .{});
    defer parsed.deinit();
    return parsed.value;
}
