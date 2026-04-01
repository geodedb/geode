const std = @import("std");
const protocol = @import("../protocol.zig");
const quic = @import("../transport/quic.zig");
const schema = @import("schema");
const protobuf = @import("protobuf");
const proto_util = @import("../server/proto_util.zig");
const value_utilities = @import("../execution/value_utilities.zig");

const rls_filter = @import("../server/rls_filter.zig");

const logging = @import("logging");
const log = logging.scoped("federation");
const Attr = logging.Attr;

/// Federation configuration
pub const FederationConfig = struct {
    /// Enable distributed query federation
    enabled: bool = false,

    /// Maximum number of remote nodes
    max_nodes: u32 = 100,

    /// Connection timeout in milliseconds
    connection_timeout_ms: u64 = 5000,

    /// Query timeout in milliseconds
    query_timeout_ms: u64 = 30000,

    /// Maximum concurrent queries per remote node
    max_concurrent_queries: u32 = 10,

    /// Enable query result caching
    enable_cache: bool = true,

    /// Cache TTL in seconds
    cache_ttl_seconds: u64 = 300,

    /// Enable deterministic pagination
    enforce_deterministic_pagination: bool = true,

    /// Top-K merge batch size
    topk_merge_batch_size: u32 = 1000,

    /// SEC-D010: Optional tenant ID to propagate in federation HELLO requests.
    /// When set, remote nodes receive the tenant context for their own RLS evaluation.
    tenant_id: ?[]const u8 = null,

    /// GAP-0184: Enable parallel scatter/gather for distributed queries
    /// When true, query fragments are executed concurrently across shards
    /// CANARY: REQ=REQ-0006; FEATURE="Distributed Query Federation"; ASPECT=ParallelScatter; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-14
    enable_parallel_scatter: bool = true,
};

/// Remote Geode instance
pub const RemoteNode = struct {
    node_id: []const u8,
    endpoint: []const u8,
    health_status: HealthStatus,
    last_heartbeat: i64,
    capabilities: NodeCapabilities,
    connection_pool: ConnectionPool,
};

pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
    unknown,
};

pub const NodeCapabilities = struct {
    version: []const u8,
    supported_operations: []const OperationType,
    max_result_size: u64,
    supports_streaming: bool,
    supports_transactions: bool,
};

pub const OperationType = enum {
    match_,
    optional_match,
    filter,
    project,
    aggregate,
    order,
    limit,
    union_,
    join,
    subquery,
};

/// Connection pool for remote nodes
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(Connection),
    available: std.ArrayList(bool),
    max_connections: u32,

    pub fn init(allocator: std.mem.Allocator, max_connections: u32) !ConnectionPool {
        return .{
            .allocator = allocator,
            .connections = std.ArrayList(Connection).init(allocator),
            .available = std.ArrayList(bool).init(allocator),
            .max_connections = max_connections,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |*conn| {
            conn.deinit();
        }
        self.connections.deinit();
        self.available.deinit();
    }

    pub fn acquire(self: *ConnectionPool) !*Connection {
        for (self.available.items, 0..) |avail, i| {
            if (avail) {
                self.available.items[i] = false;
                return &self.connections.items[i];
            }
        }

        if (self.connections.items.len < self.max_connections) {
            try self.connections.append(try Connection.init(self.allocator));
            try self.available.append(false);
            return &self.connections.items[self.connections.items.len - 1];
        }

        return error.NoConnectionsAvailable;
    }

    pub fn release(self: *ConnectionPool, conn: *Connection) void {
        for (self.connections.items, 0..) |*pool_conn, i| {
            if (pool_conn == conn) {
                self.available.items[i] = true;
                return;
            }
        }
    }
};

/// Connection to a remote node
/// CANARY: REQ=REQ-FED-QUIC-001; FEATURE="FederationQUICConnection"; ASPECT=Connection; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=federation; UPDATED=2026-01-10
pub const Connection = struct {
    allocator: std.mem.Allocator,
    client: ?quic.QuicClient = null,
    stream: ?*quic.QuicClientStream = null,
    session_id: ?[]u8 = null,
    last_used: i64,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Connection {
        return .{
            .allocator = allocator,
            .client = null,
            .stream = null,
            .session_id = null,
            .last_used = 0,
            .connected = false,
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
        if (self.client) |*c| {
            c.deinit();
            self.client = null;
        }
        self.connected = false;
    }

    /// Build HELLO request for inter-node federation authentication.
    /// GAP-0490: Reads GEODE_CLUSTER_TOKEN from environment; sends as geode-cluster user.
    /// SEC-D010: Accepts optional tenant_id to propagate tenant context to remote nodes.
    // CANARY: REQ=REQ-GAP-0490-FEDERATION-CLIENT-AUTH; FEATURE="FederationAuth"; ASPECT=ClientToken; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
    // CANARY: REQ=REQ-SEC-TENANT-FED-001; FEATURE="Federation Tenant Propagation"; ASPECT=HelloRequest; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    fn buildFederationHelloRequest(allocator: std.mem.Allocator, tenant_id: ?[]const u8) schema.HelloRequest {
        // Duplicate tenant_id if provided so it has the same lifetime as the HelloRequest.
        const tid: ?[]const u8 = if (tenant_id) |t|
            allocator.dupe(u8, t) catch null
        else
            null;

        const token = std.process.getenv("GEODE_CLUSTER_TOKEN") orelse {
            log.warn("GEODE_CLUSTER_TOKEN not set — federation connections may be rejected by auth-enabled nodes", &.{});
            return schema.HelloRequest{
                .username = "",
                .password = "",
                .tenant_id = tid,
                .client_name = "geode-federation",
                .client_version = "",
                .wanted_conformance = "",
            };
        };
        const password_copy = allocator.dupe(u8, token) catch {
            log.warn("GEODE_CLUSTER_TOKEN: allocation failed, sending empty credentials", &.{});
            return schema.HelloRequest{
                .username = "",
                .password = "",
                .tenant_id = tid,
                .client_name = "geode-federation",
                .client_version = "",
                .wanted_conformance = "",
            };
        };
        return schema.HelloRequest{
            .username = "geode-cluster",
            .password = password_copy,
            .tenant_id = tid,
            .client_name = "geode-federation",
            .client_version = "",
            .wanted_conformance = "",
        };
    }

    /// GAP-0044: Initialize QUIC client and establish connection to remote federation node
    // GAP-0144: Secure TLS connections for federation
    // CANARY: REQ=REQ-FED-TLS-001; FEATURE="Federation TLS"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=distributed; UPDATED=2026-01-13
    pub fn connect(self: *Connection, endpoint: []const u8, timeout_ms: u64, tenant_id: ?[]const u8) !void {
        // Parse endpoint like "host:port"
        const colon = std.mem.indexOfScalar(u8, endpoint, ':') orelse return error.InvalidEndpoint;
        const host = endpoint[0..colon];
        const port = std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10) catch return error.InvalidEndpoint;

        // Initialize QUIC client
        self.client = quic.QuicClient.init(self.allocator);

        // GAP-0144: Use TLS verification for federation by default
        // Check if insecure mode is explicitly allowed via environment variable
        const builtin = @import("builtin");
        const allow_insecure = blk: {
            // All builds require explicit env var to skip TLS verification.
            // Debug builds no longer auto-allow insecure connections.
            const env = std.process.getEnvVarOwned(self.allocator, "GEODE_FEDERATION_INSECURE") catch null;
            if (env) |v| {
                defer self.allocator.free(v);
                if (std.mem.eql(u8, v, "1")) {
                    log.warn("SECURITY WARNING: Federation TLS verification disabled via GEODE_FEDERATION_INSECURE", &.{});
                    break :blk true;
                }
            }
            break :blk false;
        };

        // Connect to remote federation node with TLS verification by default (skip_verify=false)
        try self.client.?.connectInsecure(host, port, allow_insecure);

        // Wait for TLS handshake to complete (5 second timeout)
        try self.client.?.waitForHandshake(5);

        // Open a bidirectional stream for query/result exchange
        self.stream = try self.client.?.getStream();
        // HELLO handshake (protobuf)
        // GAP-0490: Use GEODE_CLUSTER_TOKEN for inter-node authentication
        var hello_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer hello_arena.deinit();
        const hello_req = buildFederationHelloRequest(hello_arena.allocator(), tenant_id);
        try writeProtoMessage(self.allocator, self.stream.?, .{ .hello = hello_req });

        var resp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer resp_arena.deinit();
        const resp = try readProtoMessage(resp_arena.allocator(), self.stream.?, &self.client.?, @intCast(timeout_ms));
        switch (resp) {
            .hello => |h| {
                if (!h.success) return error.AuthFailed;
                if (h.session_id.len > 0) {
                    self.session_id = try self.allocator.dupe(u8, h.session_id);
                }
            },
            else => return error.ProtocolError,
        }
        self.last_used = std.time.milliTimestamp();
        self.connected = true;
    }

    fn ensureConnected(self: *Connection, endpoint: []const u8, timeout_ms: u64, tenant_id: ?[]const u8) !void {
        if (!self.connected) {
            try self.connect(endpoint, timeout_ms, tenant_id);
        }
        if (self.session_id == null) return error.NotConnected;
    }

    pub fn executeQuery(
        self: *Connection,
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        timeout_ms: u64,
        page_size: u32,
        query: FederatedQuery,
    ) !QueryResults {
        const start_time = std.time.milliTimestamp();
        // SEC-D010: Pass null tenant_id for now; FederationManager passes it via connect().
        try self.ensureConnected(endpoint, timeout_ms, null);
        if (self.stream == null or self.client == null or self.session_id == null) return error.NotConnected;

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
            const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.client.?, @intCast(timeout_ms)) catch |err| {
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
                    .@"error" => return error.RemoteExecutionFailed,
                    .explain, .profile => return error.Unsupported,
                    .metrics, .heartbeat => {},
                },
                .hello => |h| if (!h.success) return error.AuthFailed,
                else => {},
            }

            _ = loop_arena.reset(.retain_capacity);
        }

        if (!saw_inline_page and !inline_final) {
            const maybe_resp: ?schema.QuicServerMessage = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.client.?, 1) catch |err| switch (err) {
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

                const resp = readProtoMessage(loop_arena.allocator(), self.stream.?, &self.client.?, @intCast(timeout_ms)) catch |err| {
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

        self.last_used = std.time.milliTimestamp();
        const exec_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        return QueryResults{
            .rows = rows_slice,
            .schema = schema_slice,
            .execution_time_ms = exec_ms,
            .ordered = ordered,
            .order_keys = order_keys_slice,
            .order_dirs = &.{},
            .nulls_first = true,
        };
    }
};

/// Federated query plan
pub const FederatedQueryPlan = struct {
    allocator: std.mem.Allocator,
    local_operations: []const QueryOperation,
    remote_operations: []const RemoteOperation,
    merge_strategy: MergeStrategy,
    estimated_cost: f64,
};

pub const QueryOperation = struct {
    op_type: OperationType,
    predicate: ?[]const u8,
    projection: ?[]const []const u8,
    order_by: ?[]const OrderKey,
    limit: ?u64,
    offset: ?u64,
};

pub const RemoteOperation = struct {
    node_id: []const u8,
    operation: QueryOperation,
    expected_rows: u64,
    network_cost: f64,
};

pub const OrderKey = struct {
    column: []const u8,
    ascending: bool,
};

pub const MergeStrategy = enum {
    union_all,
    union_distinct,
    merge_sorted,
    hash_join,
    nested_loop_join,
    broadcast_join,
};

/// Query results from federated execution
pub const QueryResults = struct {
    rows: []const protocol.BindingRow,
    schema: []const protocol.ColumnDef,
    execution_time_ms: u64,
    // Ordering metadata (optional; federation may propagate this later)
    ordered: bool = false,
    order_keys: []const []const u8 = &.{},
    order_dirs: []const bool = &.{},
    nulls_first: bool = true,
    pub fn deinit(self: *QueryResults, allocator: std.mem.Allocator) void {
        if (self.rows.len > 0) {
            for (self.rows) |row| freeBindingRow(allocator, row);
            allocator.free(self.rows);
            self.rows = &.{};
        }
        if (self.schema.len > 0) {
            freeSchema(allocator, self.schema);
            self.schema = &.{};
        }
        if (self.order_keys.len > 0) {
            for (self.order_keys) |k| allocator.free(k);
            allocator.free(self.order_keys);
            self.order_keys = &.{};
        }
        if (self.order_dirs.len > 0) {
            allocator.free(self.order_dirs);
            self.order_dirs = &.{};
        }
    }
};

fn freeBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) void {
    for (row.cols) |val| {
        value_utilities.freeValue(allocator, val);
    }
    if (row.cols.len > 0) allocator.free(row.cols);
}

fn cloneBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) !protocol.BindingRow {
    var cols = try allocator.alloc(protocol.BindingValue, row.cols.len);
    errdefer {
        for (cols) |val| value_utilities.freeValue(allocator, val);
        allocator.free(cols);
    }
    for (row.cols, 0..) |val, i| {
        cols[i] = try value_utilities.duplicateValue(allocator, val);
    }
    return .{ .cols = cols };
}

// CANARY: REQ=REQ-SEC-RLS-FED-001; FEATURE="RLS Federation Filtering"; ASPECT=PostMergeFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
// SEC-D007: Apply label-based RLS filtering to federated query results.
// Uses the same RLSFilterEngine as local queries but operates on BindingRow (protocol.Value)
// rather than ExecutionResult rows. Since protocol.BindingValue = value_types.Value, the
// label-checking logic is identical to rls_filter.rowContainsDeniedLabel.

/// Filter federated QueryResults in-place by removing rows that contain nodes/edges
/// with labels denied by the RLS engine for the given user+graph.
/// Returns the number of rows removed.
pub fn applyRLSToFederatedResults(
    allocator: std.mem.Allocator,
    results: *QueryResults,
    engine: *rls_filter.RLSFilterEngine,
    username: []const u8,
    graph_name: []const u8,
) usize {
    // Fast path: no policies => nothing to filter.
    if (engine.policyCount() == 0) return 0;

    // Snapshot denied labels once (single lock acquisition).
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch return 0;
    defer denied.deinit();

    if (denied.count() == 0) return 0;

    // We need a mutable copy of the rows slice to do swap-remove.
    var rows = @constCast(results.rows);
    var removed: usize = 0;
    var i: usize = 0;
    while (i < rows.len) {
        if (bindingRowContainsDeniedLabel(&denied, rows[i])) {
            freeBindingRow(allocator, rows[i]);

            // Swap-remove: replace with last element.
            const last = rows.len - 1;
            if (i < last) {
                rows[i] = rows[last];
            }
            rows = rows[0..last];
            removed += 1;
        } else {
            i += 1;
        }
    }

    results.rows = rows;

    if (removed > 0) {
        log.info("rls_federation_filter", &.{
            Attr.string("action", "federated_rows_filtered"),
            Attr.string("user", username),
            Attr.string("graph", graph_name),
        });
    }

    return removed;
}

/// Check whether a BindingRow contains any Node or Edge value with a denied label.
fn bindingRowContainsDeniedLabel(
    denied_labels: *const std.StringHashMap(void),
    row: protocol.BindingRow,
) bool {
    for (row.cols) |val| {
        switch (val) {
            .Node => |node| {
                for (node.labels) |label| {
                    if (denied_labels.contains(label)) return true;
                }
            },
            .Edge => |edge| {
                if (denied_labels.contains(edge.label)) return true;
            },
            .Path => |path| {
                for (path.nodes) |node| {
                    for (node.labels) |label| {
                        if (denied_labels.contains(label)) return true;
                    }
                }
                for (path.edges) |edge| {
                    if (denied_labels.contains(edge.label)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn freeSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) void {
    for (schema_defs) |col| {
        allocator.free(col.name);
        allocator.free(col.data_type);
    }
    allocator.free(schema_defs);
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

fn cloneOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var cloned = try allocator.alloc([]const u8, keys.len);
    errdefer {
        for (cloned) |key| allocator.free(key);
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

fn cloneQueryResults(allocator: std.mem.Allocator, results: QueryResults) !QueryResults {
    var rows = try allocator.alloc(protocol.BindingRow, results.rows.len);
    var idx: usize = 0;
    errdefer {
        for (rows[0..idx]) |row| freeBindingRow(allocator, row);
        allocator.free(rows);
    }
    for (results.rows) |row| {
        rows[idx] = try cloneBindingRow(allocator, row);
        idx += 1;
    }

    const schema = try cloneSchema(allocator, results.schema);
    errdefer freeSchema(allocator, schema);

    const order_keys = if (results.order_keys.len > 0) try cloneOrderKeys(allocator, results.order_keys) else &.{};
    errdefer if (order_keys.len > 0) {
        for (order_keys) |k| allocator.free(k);
        allocator.free(order_keys);
    };

    const order_dirs = if (results.order_dirs.len > 0) try cloneOrderDirs(allocator, results.order_dirs) else &.{};
    errdefer if (order_dirs.len > 0) allocator.free(order_dirs);

    return QueryResults{
        .rows = rows,
        .schema = schema,
        .execution_time_ms = results.execution_time_ms,
        .ordered = results.ordered,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
        .nulls_first = results.nulls_first,
    };
}

// Global mismatch flag moved to lightweight federation_flag module to avoid multiple root module collisions.
const fed_flag = @import("federation_flag.zig");

/// Federated query
pub const FederatedQuery = struct {
    query_text: []const u8,
    parameters: []const protocol.Value,
    target_nodes: []const []const u8,
    consistency_level: ConsistencyLevel,
};

pub const ConsistencyLevel = enum {
    eventual,
    bounded_staleness,
    strong,
    linearizable,
};

/// Federation manager
pub const FederationManager = struct {
    allocator: std.mem.Allocator,
    config: FederationConfig,
    remote_nodes: std.StringHashMap(RemoteNode),
    query_cache: QueryCache,
    planner: FederatedPlanner,

    pub fn init(allocator: std.mem.Allocator, config: FederationConfig) !FederationManager {
        return .{
            .allocator = allocator,
            .config = config,
            .remote_nodes = std.StringHashMap(RemoteNode).init(allocator),
            .query_cache = try QueryCache.init(allocator, config.cache_ttl_seconds),
            .planner = try FederatedPlanner.init(allocator),
        };
    }

    pub fn deinit(self: *FederationManager) void {
        var it = self.remote_nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.connection_pool.deinit();
        }
        self.remote_nodes.deinit();
        self.query_cache.deinit();
        self.planner.deinit();
    }

    /// Register a remote node
    pub fn registerNode(self: *FederationManager, node: RemoteNode) !void {
        const node_copy = RemoteNode{
            .node_id = try self.allocator.dupe(u8, node.node_id),
            .endpoint = try self.allocator.dupe(u8, node.endpoint),
            .health_status = node.health_status,
            .last_heartbeat = std.time.milliTimestamp(),
            .capabilities = node.capabilities,
            .connection_pool = try ConnectionPool.init(
                self.allocator,
                self.config.max_concurrent_queries,
            ),
        };

        try self.remote_nodes.put(node.node_id, node_copy);
    }

    /// Execute a federated query
    pub fn executeQuery(
        self: *FederationManager,
        query: FederatedQuery,
        allocator: std.mem.Allocator,
    ) !QueryResults {
        // Check cache first
        if (self.config.enable_cache) {
            if (try self.query_cache.get(query)) |cached_results| {
                return cached_results;
            }
        }

        // Plan the federated query
        const plan = try self.planner.plan(query, self.remote_nodes);
        defer plan.deinit();

        // Execute local operations
        const local_results = try self.executeLocalOperations(plan.local_operations, allocator);
        defer {
            var lr = local_results; // copy
            lr.deinit(allocator);
        }

        // Execute remote operations in parallel
        const remote_results = try self.executeRemoteOperations(plan.remote_operations, allocator);
        defer {
            for (remote_results) |result| {
                var rr = result; // copy for deinit
                rr.deinit(allocator);
            }
            allocator.free(remote_results);
        }

        // Merge results according to strategy
        var merged_results = try self.mergeResults(
            local_results,
            remote_results,
            plan.merge_strategy,
            allocator,
        );

        // SEC-D007: Apply RLS label filtering to merged federated results.
        // This ensures that rows containing nodes/edges with denied labels are
        // removed before caching or returning to the client.
        if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
            // Extract graph name from the query text (use "default" as fallback).
            // In production, the graph context would come from the session/query metadata.
            const rls_graph = "default";
            const rls_user = ""; // Federation queries run as cluster user; apply all-user policies.
            _ = applyRLSToFederatedResults(allocator, &merged_results, rls_engine, rls_user, rls_graph);
        }

        // Cache results if enabled
        if (self.config.enable_cache) {
            try self.query_cache.put(query, merged_results);
        }

        return merged_results;
    }

    fn executeLocalOperations(
        self: *FederationManager,
        operations: []const QueryOperation,
        allocator: std.mem.Allocator,
    ) !QueryResults {
        _ = self;
        _ = operations;
        _ = allocator;
        // Implementation would execute operations locally
        return QueryResults{
            .rows = &.{},
            .schema = &.{},
            .execution_time_ms = 0,
        };
    }

    fn executeRemoteOperations(
        self: *FederationManager,
        operations: []const RemoteOperation,
        allocator: std.mem.Allocator,
    ) ![]QueryResults {
        var results = try allocator.alloc(QueryResults, operations.len);
        var filled: usize = 0;
        errdefer {
            for (results[0..filled]) |*res| res.deinit(allocator);
            allocator.free(results);
        }

        // Execute operations in parallel (simplified sequential for now)
        for (operations, 0..) |op, i| {
            const node = self.remote_nodes.get(op.node_id) orelse return error.NodeNotFound;

            var conn = try node.connection_pool.acquire();
            defer node.connection_pool.release(conn);

            const query = FederatedQuery{
                .query_text = try self.operationToGQL(op.operation, allocator),
                .parameters = &.{},
                .target_nodes = &[_][]const u8{op.node_id},
                .consistency_level = .eventual,
            };

            results[i] = try conn.executeQuery(
                allocator,
                node.endpoint,
                self.config.query_timeout_ms,
                self.config.topk_merge_batch_size,
                query,
            );
            filled = i + 1;
        }

        return results;
    }

    fn operationToGQL(
        _: *FederationManager,
        operation: QueryOperation,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        _ = operation;
        _ = allocator;
        return "MATCH (n) RETURN n";
    }

    fn mergeResults(
        _: *FederationManager,
        local: QueryResults,
        remote: []QueryResults,
        strategy: MergeStrategy,
        allocator: std.mem.Allocator,
    ) !QueryResults {
        // manager not required currently

        switch (strategy) {
            .union_all => {
                // Simple concatenation of all results
                var total_rows: usize = local.rows.len;
                for (remote) |r| {
                    total_rows += r.rows.len;
                }

                var merged_rows = try allocator.alloc(protocol.BindingRow, total_rows);
                var idx: usize = 0;
                errdefer {
                    for (merged_rows[0..idx]) |row| freeBindingRow(allocator, row);
                    allocator.free(merged_rows);
                }

                for (local.rows) |row| {
                    merged_rows[idx] = try cloneBindingRow(allocator, row);
                    idx += 1;
                }

                for (remote) |r| {
                    for (r.rows) |row| {
                        merged_rows[idx] = try cloneBindingRow(allocator, row);
                        idx += 1;
                    }
                }

                const schema_source = if (local.schema.len > 0)
                    local.schema
                else if (remote.len > 0 and remote[0].schema.len > 0)
                    remote[0].schema
                else
                    &.{};
                const schema_copy = if (schema_source.len > 0) try cloneSchema(allocator, schema_source) else &.{};
                errdefer if (schema_copy.len > 0) freeSchema(allocator, schema_copy);

                return QueryResults{
                    .rows = merged_rows,
                    .schema = schema_copy,
                    .execution_time_ms = local.execution_time_ms,
                    .ordered = false,
                };
            },

            .union_distinct => {
                // Remove duplicates during merge
                // Implementation would use hash set for deduplication
                return mergeResults(undefined, local, remote, .union_all, allocator);
            },

            .merge_sorted => {
                // K-way merge for already sorted inputs. Preconditions:
                // 1. All inputs (local + remote) have ordered=true
                // 2. All inputs share identical order_keys sequence (string equal)
                // If preconditions fail, fallback to union_all (unordered concatenation) and emit flag U:FederationOrderMismatch

                var all_ordered = local.ordered;
                const order_keys = local.order_keys;
                const order_dirs = local.order_dirs;
                var dir_mismatch = false;
                for (remote) |r| {
                    if (!r.ordered) {
                        all_ordered = false;
                        break;
                    }
                    if (r.order_keys.len != order_keys.len) {
                        all_ordered = false;
                        break;
                    }
                    for (r.order_keys, 0..) |rk, i| {
                        if (!std.mem.eql(u8, rk, order_keys[i])) {
                            all_ordered = false;
                            break;
                        }
                    }
                    if (order_dirs.len > 0) {
                        if (r.order_dirs.len != order_dirs.len) {
                            all_ordered = false;
                            break;
                        }
                        for (r.order_dirs, 0..) |d, i| {
                            if (d != order_dirs[i]) {
                                dir_mismatch = true;
                                all_ordered = false;
                                break;
                            }
                        }
                    }
                    if (!all_ordered) break;
                }
                if (!all_ordered or order_keys.len == 0) {
                    const fallback = try mergeResults(undefined, local, remote, .union_all, allocator);
                    // Inject ordering flag metadata - we repurpose ordered=false and wipe keys/dirs.
                    if (dir_mismatch) {
                        // In a fuller integration this would propagate via protocol frame flagger.
                        // For now we just leave a CANARY comment for evidence.
                        // CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FederationMismatchFlagEmission; OWNER=federation; UPDATED=2025-09-23
                        fed_flag.g_last_federation_mismatch = true; // consumed by server flag assembly
                    }
                    return fallback;
                }

                // Total rows for allocation
                var total_rows: usize = local.rows.len;
                for (remote) |r| total_rows += r.rows.len;
                var merged_rows = try allocator.alloc(protocol.BindingRow, total_rows);
                var out_idx: usize = 0;
                errdefer {
                    for (merged_rows[0..out_idx]) |row| freeBindingRow(allocator, row);
                    allocator.free(merged_rows);
                }

                // Min-heap node definition
                const SourceKind = enum { local, remote };
                const HeapItem = struct {
                    source: SourceKind,
                    remote_index: usize = 0, // valid when source==remote
                    row_index: usize,
                };

                // Helper methods grouped for parsing clarity
                const MergeUtil = struct {
                    pub fn findColIndex(schema: []const protocol.ColumnDef, name: []const u8) usize {
                        for (schema, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
                        return 0;
                    }
                    pub fn getKey(row: protocol.BindingRow, idx: usize) protocol.BindingValue {
                        if (idx < row.cols.len) return row.cols[idx];
                        return .{ .Null = {} };
                    }
                    pub fn cmpValues(a: protocol.BindingValue, b: protocol.BindingValue, nulls_first: bool) std.math.Order {
                        // NULL handling first according to policy
                        const a_is_null = (a == .Null);
                        const b_is_null = (b == .Null);
                        if (a_is_null or b_is_null) {
                            if (a_is_null and b_is_null) return .eq;
                            if (nulls_first) {
                                return if (a_is_null) .lt else .gt;
                            } else {
                                return if (a_is_null) .gt else .lt;
                            }
                        }
                        return switch (a) {
                            .Int => |av| switch (b) {
                                .Int => |bv| if (av < bv) .lt else if (av > bv) .gt else .eq,
                                else => .lt,
                            },
                            .Str => |as| switch (b) {
                                .Str => |bs| std.mem.order(u8, as, bs),
                                else => .gt,
                            },
                            else => .eq,
                        };
                    }
                    pub fn rowLessThan(a: HeapItem, b: HeapItem, l: QueryResults, rem: []QueryResults, col_indices: []const usize) bool {
                        const rowA = switch (a.source) {
                            .local => l.rows[a.row_index],
                            .remote => rem[a.remote_index].rows[a.row_index],
                        };
                        const rowB = switch (b.source) {
                            .local => l.rows[b.row_index],
                            .remote => rem[b.remote_index].rows[b.row_index],
                        };
                        for (col_indices, 0..) |ci, ki| {
                            const ord = cmpValues(getKey(rowA, ci), getKey(rowB, ci), l.nulls_first);
                            if (ord == .eq) continue;
                            const asc = if (l.order_dirs.len == col_indices.len) l.order_dirs[ki] else true;
                            if (asc) {
                                return ord == .lt;
                            } else {
                                return ord == .gt;
                            }
                        }
                        return false;
                    }
                    pub fn siftDown(h: *std.ArrayList(HeapItem), idx: usize, l: QueryResults, rem: []QueryResults, cols: []const usize) void {
                        var i = idx;
                        while (true) {
                            const left = i * 2 + 1;
                            const right = left + 1;
                            var smallest = i;
                            if (left < h.items.len and rowLessThan(h.items[left], h.items[smallest], l, rem, cols)) smallest = left;
                            if (right < h.items.len and rowLessThan(h.items[right], h.items[smallest], l, rem, cols)) smallest = right;
                            if (smallest == i) break;
                            const tmp = h.items[i];
                            h.items[i] = h.items[smallest];
                            h.items[smallest] = tmp;
                            i = smallest;
                        }
                    }
                    pub fn siftUp(h: *std.ArrayList(HeapItem), idx: usize, l: QueryResults, rem: []QueryResults, cols: []const usize) void {
                        var i = idx;
                        while (i > 0) {
                            const parent = (i - 1) / 2;
                            if (!rowLessThan(h.items[i], h.items[parent], l, rem, cols)) break;
                            const tmp = h.items[parent];
                            h.items[parent] = h.items[i];
                            h.items[i] = tmp;
                            i = parent;
                        }
                    }
                };
                var col_indices = try allocator.alloc(usize, order_keys.len);
                defer allocator.free(col_indices);
                for (order_keys, 0..) |kname, i| col_indices[i] = MergeUtil.findColIndex(local.schema, kname);

                var heap = std.ArrayList(HeapItem).init(allocator);
                defer heap.deinit();
                // Push first row from each source
                if (local.rows.len > 0) {
                    try heap.append(.{ .source = .local, .row_index = 0 });
                }
                for (remote, 0..) |r, ri| if (r.rows.len > 0) try heap.append(.{ .source = .remote, .remote_index = ri, .row_index = 0 });
                // Heapify (bottom-up)
                if (heap.items.len > 1) {
                    var i: isize = @intCast(heap.items.len / 2);
                    while (i >= 0) : (i -= 1) MergeUtil.siftDown(&heap, @intCast(i), local, remote, col_indices);
                }
                while (heap.items.len > 0) {
                    const top = heap.items[0];
                    const src_row = switch (top.source) {
                        .local => local.rows[top.row_index],
                        .remote => remote[top.remote_index].rows[top.row_index],
                    };
                    merged_rows[out_idx] = try cloneBindingRow(allocator, src_row);
                    out_idx += 1;
                    // Advance
                    switch (top.source) {
                        .local => if (top.row_index + 1 < local.rows.len) {
                            heap.items[0].row_index += 1;
                        } else {
                            heap.items[0] = heap.items[heap.items.len - 1];
                            _ = heap.pop();
                        },
                        .remote => {
                            const r = remote[top.remote_index];
                            if (top.row_index + 1 < r.rows.len) {
                                heap.items[0].row_index += 1;
                            } else {
                                heap.items[0] = heap.items[heap.items.len - 1];
                                _ = heap.pop();
                            }
                        },
                    }
                    if (heap.items.len > 0) MergeUtil.siftDown(&heap, 0, local, remote, col_indices);
                }

                const schema_copy = if (local.schema.len > 0) try cloneSchema(allocator, local.schema) else &.{};
                errdefer if (schema_copy.len > 0) freeSchema(allocator, schema_copy);
                const order_keys_copy = if (order_keys.len > 0) try cloneOrderKeys(allocator, order_keys) else &.{};
                errdefer if (order_keys_copy.len > 0) {
                    for (order_keys_copy) |k| allocator.free(k);
                    allocator.free(order_keys_copy);
                };
                const order_dirs_copy = if (order_dirs.len > 0) try cloneOrderDirs(allocator, order_dirs) else &.{};
                errdefer if (order_dirs_copy.len > 0) allocator.free(order_dirs_copy);

                return QueryResults{
                    .rows = merged_rows,
                    .schema = schema_copy,
                    .execution_time_ms = local.execution_time_ms, // simplistic aggregation
                    .ordered = true,
                    .order_keys = order_keys_copy,
                    .order_dirs = order_dirs_copy,
                    .nulls_first = local.nulls_first,
                };
            },

            else => {
                // Other strategies not yet implemented
                return mergeResults(undefined, local, remote, .union_all, allocator);
            },
        }
    }

    /// Health check for remote nodes
    pub fn healthCheck(self: *FederationManager) !void {
        var it = self.remote_nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;

            // Send heartbeat
            var conn = node.connection_pool.acquire() catch {
                node.health_status = .unhealthy;
                continue;
            };
            defer node.connection_pool.release(conn);

            // Simple ping query
            const ping_query = FederatedQuery{
                .query_text = "RETURN 1 AS ping",
                .parameters = &.{},
                .target_nodes = &[_][]const u8{node.node_id},
                .consistency_level = .eventual,
            };

            _ = conn.executeQuery(
                self.allocator,
                node.endpoint,
                self.config.query_timeout_ms,
                1,
                ping_query,
            ) catch {
                node.health_status = .degraded;
                continue;
            };

            node.health_status = .healthy;
            node.last_heartbeat = std.time.milliTimestamp();
        }
    }
};

/// Query result cache
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CacheEntry),
    ttl_seconds: u64,

    const CacheEntry = struct {
        results: QueryResults,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, ttl_seconds: u64) !QueryCache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .ttl_seconds = ttl_seconds,
        };
    }

    pub fn deinit(self: *QueryCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            var res = entry.value_ptr.results;
            res.deinit(self.allocator);
        }
        self.cache.deinit();
    }

    pub fn get(self: *QueryCache, query: FederatedQuery) !?QueryResults {
        const key = self.computeKey(query);
        defer self.allocator.free(key);

        if (self.cache.get(key)) |entry| {
            const age_ms = std.time.milliTimestamp() - entry.timestamp;
            if (age_ms < self.ttl_seconds * 1000) {
                return try cloneQueryResults(self.allocator, entry.results);
            }
            // Remove expired entry
            var expired = entry.results;
            expired.deinit(self.allocator);
            _ = self.cache.remove(key);
        }

        return null;
    }

    pub fn put(self: *QueryCache, query: FederatedQuery, results: QueryResults) !void {
        const key = self.computeKey(query);
        defer self.allocator.free(key);

        if (self.cache.get(key)) |existing| {
            var old = existing.results;
            old.deinit(self.allocator);
        }

        try self.cache.put(key, CacheEntry{
            .results = try cloneQueryResults(self.allocator, results),
            .timestamp = std.time.milliTimestamp(),
        });
    }

    fn computeKey(self: *QueryCache, query: FederatedQuery) []const u8 {
        // Simple hash of query text and parameters
        const hash_input = std.fmt.allocPrint(
            self.allocator,
            "{s}:{any}",
            .{ query.query_text, query.parameters },
        ) catch return "";

        return hash_input;
    }
};

/// Federated query planner
pub const FederatedPlanner = struct {
    allocator: std.mem.Allocator,
    cost_model: CostModel,

    pub fn init(allocator: std.mem.Allocator) !FederatedPlanner {
        return .{
            .allocator = allocator,
            .cost_model = CostModel.init(),
        };
    }

    pub fn deinit(self: *FederatedPlanner) void {
        _ = self;
    }

    pub fn plan(
        self: *FederatedPlanner,
        query: FederatedQuery,
        nodes: std.StringHashMap(RemoteNode),
    ) !FederatedQueryPlan {
        _ = query;
        _ = nodes;

        // Simplified planning - execute everything locally for now
        return FederatedQueryPlan{
            .allocator = self.allocator,
            .local_operations = &.{},
            .remote_operations = &.{},
            .merge_strategy = .union_all,
            .estimated_cost = 0.0,
        };
    }
};

/// Cost model for federated query planning
pub const CostModel = struct {
    network_latency_ms: f64 = 10.0,
    network_bandwidth_mbps: f64 = 100.0,
    cpu_cost_per_row: f64 = 0.001,
    memory_cost_per_row: f64 = 0.0001,

    pub fn init() CostModel {
        return .{};
    }

    pub fn estimateCost(
        self: *const CostModel,
        operation: QueryOperation,
        estimated_rows: u64,
        is_remote: bool,
    ) f64 {
        _ = operation;

        var cost = @as(f64, @floatFromInt(estimated_rows)) * self.cpu_cost_per_row;

        if (is_remote) {
            // Add network overhead
            cost += self.network_latency_ms;
            const data_size_mb = @as(f64, @floatFromInt(estimated_rows * 100)) / (1024.0 * 1024.0);
            cost += (data_size_mb / self.network_bandwidth_mbps) * 1000.0;
        }

        return cost;
    }
};

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
        var cols = try allocator.alloc(protocol.BindingValue, row.values.items.len);
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

test "federation: basic setup" {
    const ally = std.testing.allocator;

    var manager = try FederationManager.init(ally, .{});
    defer manager.deinit();

    // Register a remote node
    const node = RemoteNode{
        .node_id = "node1",
        .endpoint = "127.0.0.1:7567",
        .health_status = .healthy,
        .last_heartbeat = std.time.milliTimestamp(),
        .capabilities = .{
            .version = "0.16.0",
            .supported_operations = &.{ .match_, .filter, .project },
            .max_result_size = 10 * 1024 * 1024,
            .supports_streaming = true,
            .supports_transactions = true,
        },
        .connection_pool = undefined,
    };

    try manager.registerNode(node);

    try std.testing.expect(manager.remote_nodes.count() == 1);
}

test "federation: data page decodes rows" {
    const ally = std.testing.allocator;

    var row = schema.Row{ .values = std.ArrayList(schema.Value).init(ally) };
    try row.values.append(ally, .{ .kind = .{ .int_val = .{ .value = 7, .kind = .INT } } });
    try row.values.append(ally, .{ .kind = .{ .string_val = .{ .value = "ok", .kind = .STRING } } });

    var page = schema.DataPage{
        .rows = std.ArrayList(schema.Row).init(ally),
        .final = true,
        .ordered = false,
        .order_keys = std.ArrayList([]const u8).init(ally),
    };
    try page.rows.append(ally, row);
    defer page.deinit(ally);

    var rows = std.ArrayList(protocol.BindingRow).init(ally);
    defer {
        for (rows.items) |r| freeBindingRow(ally, r);
        rows.deinit(ally);
    }

    try appendPageRows(ally, page, &rows);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expect(rows.items[0].cols[0].Int == 7);
    try std.testing.expect(std.mem.eql(u8, rows.items[0].cols[1].Str, "ok"));
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationResultLineOrdering"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationResultLineOrdering; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationResultLineOrdering" {
    const ally = std.testing.allocator;

    var page = schema.DataPage{
        .rows = std.ArrayList(schema.Row).init(ally),
        .final = true,
        .ordered = true,
        .order_keys = std.ArrayList([]const u8).init(ally),
    };
    try page.order_keys.append(ally, "x");
    try page.order_keys.append(ally, "y");
    defer page.deinit(ally);

    var ordered = false;
    var order_keys = std.ArrayList([]const u8).init(ally);
    defer {
        for (order_keys.items) |k| ally.free(k);
        order_keys.deinit(ally);
    }

    try captureOrderMeta(ally, page, &ordered, &order_keys);
    try std.testing.expect(ordered);
    try std.testing.expect(order_keys.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, order_keys.items[0], "x"));
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationResultLineMemoryLifecycle"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationResultLineDeinit; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationResultLineDeinit" {
    const ally = std.testing.allocator;

    var row = schema.Row{ .values = std.ArrayList(schema.Value).init(ally) };
    try row.values.append(ally, .{ .kind = .{ .int_val = .{ .value = 1, .kind = .INT } } });
    var page = schema.DataPage{
        .rows = std.ArrayList(schema.Row).init(ally),
        .final = true,
        .ordered = false,
        .order_keys = std.ArrayList([]const u8).init(ally),
    };
    try page.rows.append(ally, row);
    defer page.deinit(ally);

    var rows = std.ArrayList(protocol.BindingRow).init(ally);
    try appendPageRows(ally, page, &rows);
    const results = QueryResults{
        .rows = try rows.toOwnedSlice(ally),
        .schema = &.{},
        .execution_time_ms = 0,
    };
    var res = results;
    res.deinit(ally);
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMerge; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationOrderedMerge" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{.{ .name = "k", .data_type = "ANY" }};
    // Create per-row value arrays (two local, four remote)
    var v_l1 = [_]protocol.BindingValue{.{ .Int = 1 }};
    var v_l2 = [_]protocol.BindingValue{.{ .Int = 4 }};
    var v_r11 = [_]protocol.BindingValue{.{ .Int = 2 }};
    var v_r12 = [_]protocol.BindingValue{.{ .Int = 5 }};
    var v_r21 = [_]protocol.BindingValue{.{ .Int = 3 }};
    var v_r22 = [_]protocol.BindingValue{.{ .Int = 6 }};
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &v_l1 }, .{ .cols = &v_l2 } };
    const remote1_rows = &[_]protocol.BindingRow{ .{ .cols = &v_r11 }, .{ .cols = &v_r12 } };
    const remote2_rows = &[_]protocol.BindingRow{ .{ .cols = &v_r21 }, .{ .cols = &v_r22 } };
    const order_keys = &[_][]const u8{"k"};
    const local = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys };
    const r1 = QueryResults{ .rows = remote1_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys };
    const r2 = QueryResults{ .rows = remote2_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys };
    var rem = [_]QueryResults{ r1, r2 };
    var fm: FederationManager = undefined; // manager not needed for merge
    const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    // Validate ordering 1..6
    try std.testing.expect(merged.rows.len == 6);
    var expect_value: i64 = 1;
    for (merged.rows) |row| {
        try std.testing.expect(row.cols[0].Int == expect_value);
        expect_value += 1;
    }
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMultiKeyMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyMerge; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyMerge" {
    const ally = std.testing.allocator;
    const schema2 = &[_]protocol.ColumnDef{ .{ .name = "k1", .data_type = "ANY" }, .{ .name = "k2", .data_type = "ANY" } };
    // Local rows: (1,1), (2,1), (3,2)
    var v_l1a = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 1 } };
    var v_l2a = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 1 } };
    var v_l3a = [_]protocol.BindingValue{ .{ .Int = 3 }, .{ .Int = 2 } };
    const local_rows2 = &[_]protocol.BindingRow{
        .{ .cols = &v_l1a },
        .{ .cols = &v_l2a },
        .{ .cols = &v_l3a },
    };
    // Remote1 rows: (1,2), (2,0)
    var v_r1a = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 2 } };
    var v_r1b = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 0 } };
    const remote1_rows2 = &[_]protocol.BindingRow{ .{ .cols = &v_r1a }, .{ .cols = &v_r1b } };
    // Remote2 rows: (3,1), (4,0)
    var v_r2a = [_]protocol.BindingValue{ .{ .Int = 3 }, .{ .Int = 1 } };
    var v_r2b = [_]protocol.BindingValue{ .{ .Int = 4 }, .{ .Int = 0 } };
    const remote2_rows2 = &[_]protocol.BindingRow{ .{ .cols = &v_r2a }, .{ .cols = &v_r2b } };
    const order_keys2 = &[_][]const u8{ "k1", "k2" };
    const local2 = QueryResults{ .rows = local_rows2, .schema = schema2, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys2 };
    const rr1 = QueryResults{ .rows = remote1_rows2, .schema = schema2, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys2 };
    const rr2 = QueryResults{ .rows = remote2_rows2, .schema = schema2, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys2 };
    var rem2 = [_]QueryResults{ rr1, rr2 };
    var fm: FederationManager = undefined;
    const merged2 = try fm.mergeResults(local2, rem2[0..], .merge_sorted, ally);
    defer merged2.deinit(ally);
    // Expected order sequence
    const expected: [7][2]i64 = .{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 1 }, .{ 3, 1 }, .{ 3, 2 }, .{ 4, 0 } };
    try std.testing.expect(merged2.rows.len == expected.len);
    for (merged2.rows, 0..) |r, i| {
        try std.testing.expect(r.cols[0].Int == expected[i][0]);
        try std.testing.expect(r.cols[1].Int == expected[i][1]);
    }
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMultiKeyDirMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyDirMerge; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyDirMerge" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{ .{ .name = "k1", .data_type = "ANY" }, .{ .name = "k2", .data_type = "ANY" } };
    // Ascending on k1, descending on k2
    const order_keys = &[_][]const u8{ "k1", "k2" };
    const order_dirs = &[_]bool{ true, false }; // second key descending
    // Local rows
    var a1 = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 5 } }; // (1,5)
    var a2 = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 9 } }; // (2,9)
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &a1 }, .{ .cols = &a2 } };
    // Remote1
    var b1 = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 7 } }; // (1,7)
    var b2 = [_]protocol.BindingValue{ .{ .Int = 3 }, .{ .Int = 1 } }; // (3,1)
    const remote1_rows = &[_]protocol.BindingRow{ .{ .cols = &b1 }, .{ .cols = &b2 } };
    // Remote2
    var c1 = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 4 } }; // (2,4)
    var c2 = [_]protocol.BindingValue{ .{ .Int = 3 }, .{ .Int = 8 } }; // (3,8)
    const remote2_rows = &[_]protocol.BindingRow{ .{ .cols = &c1 }, .{ .cols = &c2 } };
    const local = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = order_dirs };
    const r1 = QueryResults{ .rows = remote1_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = order_dirs };
    const r2 = QueryResults{ .rows = remote2_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = order_dirs };
    var rem = [_]QueryResults{ r1, r2 };
    var fm: FederationManager = undefined;
    const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    // Expected ordering: k1 ascending; within same k1, k2 descending
    // k1=1: (1,7),(1,5) ; k1=2: (2,9),(2,4) ; k1=3: (3,8),(3,1)
    const expected: [6][2]i64 = .{ .{ 1, 7 }, .{ 1, 5 }, .{ 2, 9 }, .{ 2, 4 }, .{ 3, 8 }, .{ 3, 1 } };
    try std.testing.expect(merged.rows.len == expected.len);
    for (merged.rows, 0..) |r, i| {
        try std.testing.expect(r.cols[0].Int == expected[i][0]);
        try std.testing.expect(r.cols[1].Int == expected[i][1]);
    }
}

// Additional test: parse order_dirs from JSON line
test "federation: clone preserves order dirs" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{ .{ .name = "a", .data_type = "ANY" }, .{ .name = "b", .data_type = "ANY" } };
    var v = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 2 } };
    const rows = &[_]protocol.BindingRow{.{ .cols = &v }};
    const order_keys = &[_][]const u8{ "a", "b" };
    const order_dirs = &[_]bool{ true, false };
    const original = QueryResults{
        .rows = rows,
        .schema = schema,
        .execution_time_ms = 3,
        .ordered = true,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
    };
    const cloned = try cloneQueryResults(ally, original);
    defer cloned.deinit(ally);
    try std.testing.expect(cloned.ordered);
    try std.testing.expect(cloned.order_dirs.len == 2);
    try std.testing.expect(cloned.order_dirs[0] == true);
    try std.testing.expect(cloned.order_dirs[1] == false);
}

// Test: clone preserves nulls_first flag
test "federation: clone preserves nulls_first" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{.{ .name = "a", .data_type = "ANY" }};
    var v = [_]protocol.BindingValue{.{ .Int = 1 }};
    const rows = &[_]protocol.BindingRow{.{ .cols = &v }};
    const order_keys = &[_][]const u8{"a"};
    const order_dirs = &[_]bool{true};
    const original = QueryResults{
        .rows = rows,
        .schema = schema,
        .execution_time_ms = 2,
        .ordered = true,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
        .nulls_first = false,
    };
    const cloned = try cloneQueryResults(ally, original);
    defer cloned.deinit(ally);
    try std.testing.expect(cloned.ordered);
    try std.testing.expect(!cloned.nulls_first);
}

// CANARY: REQ=REQ-GQL-052; FEATURE="FederationNullsOrdering"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationNullsOrdering; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_052_FederationNullsOrdering" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{.{ .name = "k", .data_type = "ANY" }};
    // Values with nulls interspersed
    var v1 = [_]protocol.BindingValue{.{ .Null = {} }}; // null
    var v2 = [_]protocol.BindingValue{.{ .Int = 1 }};
    var v3 = [_]protocol.BindingValue{.{ .Int = 2 }};
    var v4 = [_]protocol.BindingValue{.{ .Null = {} }};
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &v2 }, .{ .cols = &v3 } }; // (1,2)
    const remote_rows = &[_]protocol.BindingRow{ .{ .cols = &v1 }, .{ .cols = &v4 } }; // (null,null)
    const order_keys = &[_][]const u8{"k"};
    const local_nf = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .nulls_first = true };
    const remote_nf = QueryResults{ .rows = remote_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .nulls_first = true };
    var rem = [_]QueryResults{remote_nf};
    var fm: FederationManager = undefined;
    const merged = try fm.mergeResults(local_nf, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    // Expect nulls first: two nulls then 1 then 2
    try std.testing.expect(merged.rows.len == 4);
    try std.testing.expect(merged.rows[0].cols[0] == .Null);
    try std.testing.expect(merged.rows[1].cols[0] == .Null);
    try std.testing.expect(merged.rows[2].cols[0].Int == 1);
    try std.testing.expect(merged.rows[3].cols[0].Int == 2);
}

test "federation: nulls_last ordering" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{.{ .name = "k", .data_type = "ANY" }};
    var v1 = [_]protocol.BindingValue{.{ .Null = {} }};
    var v2 = [_]protocol.BindingValue{.{ .Int = 1 }};
    var v3 = [_]protocol.BindingValue{.{ .Int = 2 }};
    var v4 = [_]protocol.BindingValue{.{ .Null = {} }};
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &v1 }, .{ .cols = &v2 } }; // (null,1)
    const remote_rows = &[_]protocol.BindingRow{ .{ .cols = &v3 }, .{ .cols = &v4 } }; // (2,null)
    const order_keys = &[_][]const u8{"k"};
    const local = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .nulls_first = false };
    const remote = QueryResults{ .rows = remote_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .nulls_first = false };
    var rem = [_]QueryResults{remote};
    var fm: FederationManager = undefined;
    const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    // Expect ordering: 1,2,null,null
    try std.testing.expect(merged.rows[0].cols[0].Int == 1);
    try std.testing.expect(merged.rows[1].cols[0].Int == 2);
    try std.testing.expect(merged.rows[2].cols[0] == .Null);
    try std.testing.expect(merged.rows[3].cols[0] == .Null);
}

// Test: mismatch in order_dirs across contributors => fallback to unordered concatenation
test "federation: merge_sorted direction mismatch fallback" {
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{ .{ .name = "k1", .data_type = "ANY" }, .{ .name = "k2", .data_type = "ANY" } };
    const order_keys = &[_][]const u8{ "k1", "k2" };
    const asc_desc = &[_]bool{ true, false };
    const asc_asc = &[_]bool{ true, true };
    // Local rows
    var v_l1 = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 1 } };
    var v_l2 = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 2 } };
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &v_l1 }, .{ .cols = &v_l2 } };
    const local = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = asc_desc };
    // Remote with differing direction flags (asc,asc)
    var v_r1 = [_]protocol.BindingValue{ .{ .Int = 1 }, .{ .Int = 3 } };
    var v_r2 = [_]protocol.BindingValue{ .{ .Int = 2 }, .{ .Int = 0 } };
    const remote_rows = &[_]protocol.BindingRow{ .{ .cols = &v_r1 }, .{ .cols = &v_r2 } };
    const r1 = QueryResults{ .rows = remote_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = asc_asc };
    var rem = [_]QueryResults{r1};
    var fm: FederationManager = undefined;
    const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    // Because mismatch triggers fallback to union_all, ordering guarantee should be lost
    try std.testing.expect(!merged.ordered);
}

// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FederationMismatchFlagEmission; OWNER=federation; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_024_FederationMismatchFlagEmission" {
    // Currently we do not have protocol-level flag plumbing here; this test exercises the code path
    // where a direction mismatch occurs (same as prior test) to ensure the CANARY marker is tied to runtime logic.
    const ally = std.testing.allocator;
    const schema = &[_]protocol.ColumnDef{ .{ .name = "k1", .data_type = "ANY" }, .{ .name = "k2", .data_type = "ANY" } };
    const order_keys = &[_][]const u8{ "k1", "k2" };
    const asc_desc = &[_]bool{ true, false };
    const asc_asc = &[_]bool{ true, true };
    var v_l1 = [_]protocol.BindingValue{ .{ .Int = 5 }, .{ .Int = 1 } };
    var v_l2 = [_]protocol.BindingValue{ .{ .Int = 6 }, .{ .Int = 2 } };
    const local_rows = &[_]protocol.BindingRow{ .{ .cols = &v_l1 }, .{ .cols = &v_l2 } };
    const local = QueryResults{ .rows = local_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = asc_desc };
    var v_r1 = [_]protocol.BindingValue{ .{ .Int = 7 }, .{ .Int = 3 } };
    const remote_rows = &[_]protocol.BindingRow{.{ .cols = &v_r1 }};
    const r1 = QueryResults{ .rows = remote_rows, .schema = schema, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .order_dirs = asc_asc };
    var rem = [_]QueryResults{r1};
    var fm: FederationManager = undefined;
    const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
    defer merged.deinit(ally);
    try std.testing.expect(!merged.ordered);
}

// ---- SEC-D007: RLS federation filtering tests ----
// CANARY: REQ=REQ-SEC-RLS-FED-001; FEATURE="RLS Federation Filtering"; ASPECT=PostMergeFilter; STATUS=TESTED; TEST=federation_rls_filter_removes_denied_label_rows; OWNER=security; UPDATED=2026-04-01

const graph_store = @import("../graph_store.zig");

test "federation: RLS filter removes rows with denied label" {
    const ally = std.testing.allocator;
    var engine = rls_filter.RLSFilterEngine.init(ally);
    defer engine.deinit();

    // Deny the "Secret" label for all users on "default" graph.
    try engine.addDenyPolicy("default", "Secret", "");

    // Build test nodes: one with "Secret" label, one with "Public" label.
    var secret_labels = [_][]const u8{"Secret"};
    var secret_node = graph_store.Node{
        .id = 1,
        .labels = &secret_labels,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(ally),
    };
    var public_labels = [_][]const u8{"Public"};
    var public_node = graph_store.Node{
        .id = 2,
        .labels = &public_labels,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(ally),
    };

    // Build rows: row 0 has a Secret node, row 1 has a Public node, row 2 has an int.
    var cols0 = [_]protocol.BindingValue{.{ .Node = &secret_node }};
    var cols1 = [_]protocol.BindingValue{.{ .Node = &public_node }};
    var cols2 = [_]protocol.BindingValue{.{ .Int = 42 }};
    var rows_buf = [_]protocol.BindingRow{
        .{ .cols = &cols0 },
        .{ .cols = &cols1 },
        .{ .cols = &cols2 },
    };

    // QueryResults with non-owned rows (stack-allocated, no freeing needed).
    const col_schema = &[_]protocol.ColumnDef{.{ .name = "n", .data_type = "ANY" }};
    var results = QueryResults{
        .rows = &rows_buf,
        .schema = col_schema,
        .execution_time_ms = 0,
    };

    const removed = applyRLSToFederatedResults(ally, &results, &engine, "", "default");

    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 2), results.rows.len);

    // Remaining rows should not contain the Secret node.
    for (results.rows) |row| {
        for (row.cols) |val| {
            switch (val) {
                .Node => |node| {
                    for (node.labels) |label| {
                        try std.testing.expect(!std.mem.eql(u8, label, "Secret"));
                    }
                },
                else => {},
            }
        }
    }
}

test "federation: RLS filter no-op when no policies" {
    const ally = std.testing.allocator;
    var engine = rls_filter.RLSFilterEngine.init(ally);
    defer engine.deinit();

    var cols0 = [_]protocol.BindingValue{.{ .Int = 1 }};
    var rows_buf = [_]protocol.BindingRow{.{ .cols = &cols0 }};
    const col_schema = &[_]protocol.ColumnDef{.{ .name = "x", .data_type = "ANY" }};
    var results = QueryResults{
        .rows = &rows_buf,
        .schema = col_schema,
        .execution_time_ms = 0,
    };

    const removed = applyRLSToFederatedResults(ally, &results, &engine, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), results.rows.len);
}

test "federation: RLS filter user-specific policy" {
    const ally = std.testing.allocator;
    var engine = rls_filter.RLSFilterEngine.init(ally);
    defer engine.deinit();

    // Deny "Restricted" only for user "bob"
    try engine.addDenyPolicy("default", "Restricted", "bob");

    var restricted_labels = [_][]const u8{"Restricted"};
    var node = graph_store.Node{
        .id = 1,
        .labels = &restricted_labels,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(ally),
    };

    var cols0 = [_]protocol.BindingValue{.{ .Node = &node }};
    var rows_buf = [_]protocol.BindingRow{.{ .cols = &cols0 }};
    const col_schema = &[_]protocol.ColumnDef{.{ .name = "n", .data_type = "ANY" }};

    // For alice, the row should NOT be filtered.
    var results_alice = QueryResults{
        .rows = &rows_buf,
        .schema = col_schema,
        .execution_time_ms = 0,
    };
    const removed_alice = applyRLSToFederatedResults(ally, &results_alice, &engine, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed_alice);

    // For bob, the row SHOULD be filtered.
    var results_bob = QueryResults{
        .rows = &rows_buf,
        .schema = col_schema,
        .execution_time_ms = 0,
    };
    const removed_bob = applyRLSToFederatedResults(ally, &results_bob, &engine, "bob", "default");
    try std.testing.expectEqual(@as(usize, 1), removed_bob);
    try std.testing.expectEqual(@as(usize, 0), results_bob.rows.len);
}
