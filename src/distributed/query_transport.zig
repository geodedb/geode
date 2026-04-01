// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-001; FEATURE="Distributed Query Transport"; ASPECT=QueryTransport; STATUS=IMPL; OWNER=dist; UPDATED=2026-04-01
// CANARY: REQ=REQ-DIST-QUERY-TRANSPORT-002; FEATURE="Remote Query Execution"; ASPECT=RemoteExecution; STATUS=IMPL; OWNER=dist; UPDATED=2026-04-01

const std = @import("std");
const protocol = @import("../protocol.zig");
const quic = @import("../transport/quic.zig");
const federation = @import("federation.zig");
const network_transport = @import("network_transport.zig");
const schema = @import("schema");
const protobuf = @import("protobuf");
const proto_util = @import("../server/proto_util.zig");
const value_utilities = @import("../execution/value_utilities.zig");
const spice_wrapper = @import("parallel/spice");

const logging = @import("logging");
const log = logging.scoped("query_transport");
const Attr = logging.Attr;

/// Query-specific transport for distributed execution
pub const QueryTransport = struct {
    allocator: std.mem.Allocator,
    network_transport: *network_transport.NetworkTransport,
    connection_pool: ConnectionPool,
    timeout_ms: u32 = 30000, // 30 second default timeout
    retry_attempts: u32 = 3,
    page_size: u32 = 1000,
    pool: spice_wrapper.SpicePool, // PERF-D007: Reuse pool across queries

    pub fn init(allocator: std.mem.Allocator, net_transport: *network_transport.NetworkTransport) !QueryTransport {
        return QueryTransport{
            .allocator = allocator,
            .network_transport = net_transport,
            .connection_pool = try ConnectionPool.init(allocator),
            .pool = spice_wrapper.SpicePool.init(allocator, null),
        };
    }

    pub fn deinit(self: *QueryTransport) void {
        self.pool.deinit();
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

        try connection.ensureSession(self.timeout_ms);
        var result = try connection.executeQuery(self.allocator, query, self.timeout_ms, self.page_size);
        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        return result;
    }

    /// Send batch of queries to multiple nodes in parallel
    pub fn executeBatchQueries(
        self: *QueryTransport,
        queries: []const NodeQuery,
    ) ![]federation.QueryResults {
        var results = try self.allocator.alloc(federation.QueryResults, queries.len);
        errdefer self.allocator.free(results);

        if (queries.len == 0) {
            return results;
        }

        if (!spice_wrapper.shouldUseParallelism(queries.len, spice_wrapper.Thresholds.forEach)) {
            for (queries, 0..) |query, i| {
                results[i] = self.executeRemoteQuery(query.node_id, query.query) catch |err| {
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

        spice_wrapper.parallelForEach(
            &self.pool,
            0,
            queries.len,
            ctx,
            struct {
                fn work(_: *spice_wrapper.Task, idx: usize, c: Context) void {
                    c.results[idx] = c.transport.executeRemoteQuery(
                        c.queries[idx].node_id,
                        c.queries[idx].query,
                    ) catch |err| {
                        c.errors[idx] = err;
                        return;
                    };
                }
            }.work,
            spice_wrapper.Thresholds.forEach,
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

// CANARY: REQ=REQ-DIST-CONN-001; FEATURE="Distributed Query Connection"; ASPECT=ConnectionInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=distributed; UPDATED=2026-01-10
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
        const age = std.time.milliTimestamp() - self.last_activity;

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
        if (self.stream == null or self.quic_client == null or self.session_id == null) {
            return error.NotConnected;
        }

        var params = try buildParams(allocator, query.parameters);
        defer freeParams(allocator, &params);

        const exec_req = schema.ExecuteRequest{
            .session_id = self.session_id.?,
            .query = query.query_text,
            .params = params,
        };
        try writeProtoMessage(allocator, self.stream.?, .{ .execute = exec_req });

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
        var schema_received = false;
        var saw_inline_page = false;
        var inline_final = false;
        var need_pull = false;

        var loop_arena = std.heap.ArenaAllocator.init(allocator);
        defer loop_arena.deinit();

        while (!schema_received) {
            const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, timeout_ms) catch |err| {
                if (err == error.EndOfStream or err == error.Timeout) break;
                return err;
            };

            switch (resp) {
                .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                    .schema => |s| {
                        schema_received = true;
                        for (s.columns.items) |col| {
                            const name = try allocator.dupe(u8, col.name);
                            const dtype = if (col.type.len > 0)
                                try allocator.dupe(u8, col.type)
                            else
                                try allocator.dupe(u8, "ANY");
                            try columns.append(allocator, .{ .name = name, .data_type = dtype });
                        }
                    },
                    .page => |p| {
                        saw_inline_page = true;
                        try captureOrderMeta(allocator, p, &ordered, &order_keys);
                        try appendPageRows(allocator, p, &rows);
                        if (p.final) {
                            inline_final = true;
                        } else {
                            need_pull = true;
                        }
                    },
                    .@"error" => |e| return error.RemoteExecutionFailed,
                    .explain, .profile => return error.Unsupported,
                    .metrics, .heartbeat => {},
                },
                .hello => |h| if (!h.success) return error.AuthFailed,
                else => {},
            }

            _ = loop_arena.reset(.retain_capacity);
        }

        if (!saw_inline_page and !inline_final) {
            const maybe_resp: ?schema.QuicServerMessage = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, 1) catch |err| switch (err) {
                error.Timeout, error.EndOfStream => null,
                else => return err,
            };
            if (maybe_resp) |resp| switch (resp) {
                .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                    .page => |p| {
                        saw_inline_page = true;
                        try captureOrderMeta(allocator, p, &ordered, &order_keys);
                        try appendPageRows(allocator, p, &rows);
                        if (p.final) {
                            inline_final = true;
                        } else {
                            need_pull = true;
                        }
                    },
                    .@"error" => return error.RemoteExecutionFailed,
                    else => {},
                },
                else => {},
            };

            _ = loop_arena.reset(.retain_capacity);
        }

        if (!inline_final or need_pull) {
            var request_id: u64 = 1;
            var done = false;
            while (!done) : (request_id += 1) {
                const pull_req = schema.PullRequest{
                    .request_id = request_id,
                    .page_size = page_size,
                    .session_id = self.session_id.?,
                };
                try writeProtoMessage(allocator, self.stream.?, .{ .pull = pull_req });

                const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, timeout_ms) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };

                switch (resp) {
                    .pull => |pull_resp| {
                        const exec_resp = pull_resp.response orelse break;
                        if (exec_resp.payload) |val| switch (val) {
                            .page => |p| {
                                try captureOrderMeta(allocator, p, &ordered, &order_keys);
                                try appendPageRows(allocator, p, &rows);
                                if (p.final) done = true;
                            },
                            .@"error" => return error.RemoteExecutionFailed,
                            else => {},
                        };
                    },
                    .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                        .page => |p| {
                            try captureOrderMeta(allocator, p, &ordered, &order_keys);
                            try appendPageRows(allocator, p, &rows);
                            if (p.final) done = true;
                        },
                        .@"error" => return error.RemoteExecutionFailed,
                        else => {},
                    },
                    else => {},
                }

                _ = loop_arena.reset(.retain_capacity);
            }
        }

        const rows_slice = try rows.toOwnedSlice(allocator);
        const schema_slice = try columns.toOwnedSlice(allocator);
        const order_keys_slice = try order_keys.toOwnedSlice(allocator);

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

        var params = try buildParams(allocator, query.parameters);
        defer freeParams(allocator, &params);

        const exec_req = schema.ExecuteRequest{
            .session_id = self.session_id.?,
            .query = query.query_text,
            .params = params,
        };
        try writeProtoMessage(allocator, self.stream.?, .{ .execute = exec_req });

        var loop_arena = std.heap.ArenaAllocator.init(allocator);
        defer loop_arena.deinit();

        var saw_inline_page = false;
        var inline_final = false;
        var need_pull = false;

        while (true) {
            const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, timeout_ms) catch |err| {
                if (err == error.EndOfStream or err == error.Timeout) break;
                return err;
            };

            switch (resp) {
                .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                    .page => |p| {
                        saw_inline_page = true;
                        try emitChunkFromPage(allocator, p, handler, 0);
                        if (p.final) {
                            inline_final = true;
                        } else {
                            need_pull = true;
                        }
                        break;
                    },
                    .@"error" => return error.RemoteExecutionFailed,
                    .explain, .profile => return error.Unsupported,
                    else => {},
                },
                .hello => |h| if (!h.success) return error.AuthFailed,
                else => {},
            }

            _ = loop_arena.reset(.retain_capacity);
        }

        if (!saw_inline_page and !inline_final) {
            const maybe_resp: ?schema.QuicServerMessage = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, 1) catch |err| switch (err) {
                error.Timeout, error.EndOfStream => null,
                else => return err,
            };
            if (maybe_resp) |resp| switch (resp) {
                .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                    .page => |p| {
                        saw_inline_page = true;
                        try emitChunkFromPage(allocator, p, handler, 0);
                        if (p.final) {
                            inline_final = true;
                        } else {
                            need_pull = true;
                        }
                    },
                    .@"error" => return error.RemoteExecutionFailed,
                    else => {},
                },
                else => {},
            };

            _ = loop_arena.reset(.retain_capacity);
        }

        if (inline_final and !need_pull) return;

        var request_id: u64 = 1;
        var done = false;
        while (!done) : (request_id += 1) {
            const pull_req = schema.PullRequest{
                .request_id = request_id,
                .page_size = page_size,
                .session_id = self.session_id.?,
            };
            try writeProtoMessage(allocator, self.stream.?, .{ .pull = pull_req });

            const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.quic_client.?, timeout_ms) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            switch (resp) {
                .pull => |pull_resp| {
                    const exec_resp = pull_resp.response orelse break;
                    if (exec_resp.payload) |val| switch (val) {
                        .page => |p| {
                            try emitChunkFromPage(allocator, p, handler, request_id);
                            if (p.final) done = true;
                        },
                        .@"error" => return error.RemoteExecutionFailed,
                        else => {},
                    };
                },
                .execute => |exec_resp| if (exec_resp.payload) |val| switch (val) {
                    .page => |p| {
                        try emitChunkFromPage(allocator, p, handler, request_id);
                        if (p.final) done = true;
                    },
                    .@"error" => return error.RemoteExecutionFailed,
                    else => {},
                },
                else => {},
            }

            _ = loop_arena.reset(.retain_capacity);
        }
    }

    // GAP-0144: Secure TLS connections for distributed queries
    // CANARY: REQ=REQ-DIST-TLS-001; FEATURE="Distributed TLS"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=distributed; UPDATED=2026-01-13
    fn connect(self: *Connection, timeout_ms: u32) !void {
        // Get node address from registry if available, otherwise use default pattern
        const node_info = self.getNodeAddress();

        // Initialize QUIC client
        self.quic_client = quic.QuicClient.init(self.allocator);

        // GAP-0144: Use TLS verification for inter-node communication
        // Check if insecure mode is explicitly allowed via environment variable
        const allow_insecure = blk: {
            const env = std.process.getEnvVarOwned(self.allocator, "GEODE_CLUSTER_INSECURE") catch null;
            if (env) |v| {
                defer self.allocator.free(v);
                if (std.mem.eql(u8, v, "1")) {
                    log.warn("SECURITY WARNING: Inter-node TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
                    break :blk true;
                }
            }
            break :blk false;
        };

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
// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-10
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

fn freeBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) void {
    for (row.cols) |val| {
        value_utilities.freeValue(allocator, val);
    }
    allocator.free(row.cols);
}

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
    const start = std.time.milliTimestamp();
    while (total_read < len_buf.len) {
        const n = stream.read(len_buf[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (std.time.milliTimestamp() - start > timeout_ms) return error.Timeout;
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
                if (std.time.milliTimestamp() - start > timeout_ms) return error.Timeout;
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
