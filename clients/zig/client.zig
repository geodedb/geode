const std = @import("std");
const net = std.net;
const json = std.json;

// Client configuration
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 7567,
    use_quic: bool = true,
    use_tls: bool = true,
    page_size: u32 = 100,
    timeout_ms: u32 = 30000,
    client_name: []const u8 = "geode-zig",
    client_version: []const u8 = "1.0.0",
};

// Value types matching geode's type system
pub const ValueType = enum {
    null,
    bool,
    int,
    float,
    string,
    decimal,
    array,
    object,
    node,
    edge,
    path,
};

pub const Value = union(ValueType) {
    null: void,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    decimal: Decimal,
    array: []Value,
    object: std.StringHashMap(Value),
    node: Node,
    edge: Edge,
    path: Path,
};

pub const Decimal = struct {
    value: []const u8,
    scale: i32,
};

pub const Node = struct {
    id: i64,
    labels: [][]const u8,
    properties: std.StringHashMap(Value),
};

pub const Edge = struct {
    id: i64,
    source_id: i64,
    target_id: i64,
    label: []const u8,
    properties: std.StringHashMap(Value),
};

pub const Path = struct {
    nodes: []Node,
    edges: []Edge,
};

// Protocol message types
pub const MessageType = enum {
    HELLO,
    BEGIN,
    COMMIT,
    ROLLBACK,
    RUN_GQL,
    PULL,
    SCHEMA,
    BINDINGS,
    EXPLAIN,
    PROFILE,
    ERROR,
    // Auth messages
    AUTH_LOGIN,
    AUTH_LOGOUT,
    AUTH_CREATE_USER,
    AUTH_DELETE_USER,
    AUTH_CREATE_ROLE,
    AUTH_GRANT_PERMISSION,
    AUTH_CHECK_PERMISSION,
    // RLS messages
    RLS_CREATE_POLICY,
    RLS_ENABLE_POLICY,
    RLS_DELETE_POLICY,
};

// Result iterator
pub const Iterator = struct {
    client: *Client,
    request_id: []const u8,
    columns: []Column,
    current_page: ?Page,
    done: bool,

    pub const Column = struct {
        name: []const u8,
        type: []const u8,
    };

    pub const Page = struct {
        rows: []std.StringHashMap(Value),
        has_more: bool,
    };

    pub fn next(self: *Iterator) !?std.StringHashMap(Value) {
        if (self.done) return null;

        if (self.current_page) |*page| {
            if (page.rows.len > 0) {
                const row = page.rows[0];
                page.rows = page.rows[1..];
                return row;
            }

            if (!page.has_more) {
                self.done = true;
                return null;
            }
        }

        // Fetch next page
        try self.fetchNextPage();
        return self.next();
    }

    fn fetchNextPage(self: *Iterator) !void {
        const pull_msg = .{
            .type = "PULL",
            .request_id = self.request_id,
            .page_size = self.client.config.page_size,
        };

        try self.client.sendMessage(pull_msg);
        const response = try self.client.receiveMessage();

        // Parse response and update current_page
        // Implementation depends on protocol details
        _ = response;
    }

    pub fn close(self: *Iterator) void {
        self.done = true;
    }
};

// Main client struct
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stream: ?net.Stream = null,
    session_token: ?[]const u8 = null,
    in_transaction: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |stream| {
            stream.close();
        }
        if (self.session_token) |token| {
            self.allocator.free(token);
        }
    }

    pub fn connect(self: *Self) !void {
        if (self.config.use_quic) {
            // QUIC connection would go here
            // For now, fall back to TCP
            try self.connectTCP();
        } else {
            try self.connectTCP();
        }

        // Send HELLO message
        const hello = .{
            .type = "HELLO",
            .client_name = self.config.client_name,
            .client_ver = self.config.client_version,
            .wanted_conformance = "minimum",
        };

        try self.sendMessage(hello);
        _ = try self.receiveMessage();
    }

    fn connectTCP(self: *Self) !void {
        const address = try net.Address.parseIp(self.config.host, self.config.port);
        self.stream = try net.tcpConnectToAddress(address);
    }

    pub fn disconnect(self: *Self) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
    }

    fn sendMessage(self: *Self, message: anytype) !void {
        if (self.stream == null) return error.NotConnected;

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try json.stringify(message, .{}, buffer.writer());
        try buffer.append('\n');

        _ = try self.stream.?.write(buffer.items);
    }

    fn receiveMessage(self: *Self) !json.Value {
        if (self.stream == null) return error.NotConnected;

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Read until newline
        while (true) {
            var byte: [1]u8 = undefined;
            _ = try self.stream.?.read(&byte);
            if (byte[0] == '\n') break;
            try buffer.append(byte[0]);
        }

        const parsed = try json.parseFromSlice(json.Value, self.allocator, buffer.items, .{});
        return parsed.value;
    }

    // Transaction methods
    pub fn beginTransaction(self: *Self) !void {
        if (self.in_transaction) return error.AlreadyInTransaction;

        try self.sendMessage(.{ .type = "BEGIN" });
        _ = try self.receiveMessage();
        self.in_transaction = true;
    }

    pub fn commit(self: *Self) !void {
        if (!self.in_transaction) return error.NotInTransaction;

        try self.sendMessage(.{ .type = "COMMIT" });
        _ = try self.receiveMessage();
        self.in_transaction = false;
    }

    pub fn rollback(self: *Self) !void {
        if (!self.in_transaction) return error.NotInTransaction;

        try self.sendMessage(.{ .type = "ROLLBACK" });
        _ = try self.receiveMessage();
        self.in_transaction = false;
    }

    // Query execution
    pub fn query(self: *Self, gql: []const u8, params: ?std.StringHashMap(Value)) !Iterator {
        const request_id = try self.generateRequestId();

        const run_msg = .{
            .type = "RUN_GQL",
            .request_id = request_id,
            .text = gql,
            .params = params,
        };

        try self.sendMessage(run_msg);
        const response = try self.receiveMessage();

        // Parse schema from response
        const columns = try self.parseSchema(response);

        return Iterator{
            .client = self,
            .request_id = request_id,
            .columns = columns,
            .current_page = null,
            .done = false,
        };
    }

    fn generateRequestId(self: *Self) ![]const u8 {
        _ = self;
        // Simple implementation - would use UUID in production
        return "req_001";
    }

    fn parseSchema(self: *Self, response: json.Value) ![]Iterator.Column {
        _ = self;
        _ = response;
        // Implementation would parse actual schema
        return &[_]Iterator.Column{};
    }

    // Authentication methods
    pub fn login(self: *Self, username: []const u8, password: []const u8) !void {
        const login_msg = .{
            .type = "AUTH_LOGIN",
            .username = username,
            .password = password,
        };

        try self.sendMessage(login_msg);
        const response = try self.receiveMessage();

        // Extract and store session token
        if (response.object.get("token")) |token| {
            self.session_token = try self.allocator.dupe(u8, token.string);
        }
    }

    pub fn logout(self: *Self) !void {
        if (self.session_token == null) return;

        try self.sendMessage(.{
            .type = "AUTH_LOGOUT",
            .token = self.session_token,
        });
        _ = try self.receiveMessage();

        self.allocator.free(self.session_token.?);
        self.session_token = null;
    }

    pub fn createUser(
        self: *Self,
        username: []const u8,
        email: []const u8,
        password: []const u8,
        roles: ?[][]const u8,
    ) !void {
        const msg = .{
            .type = "AUTH_CREATE_USER",
            .username = username,
            .email = email,
            .password = password,
            .roles = roles,
        };

        try self.sendMessage(msg);
        _ = try self.receiveMessage();
    }

    // Graph operations
    pub fn createNode(
        self: *Self,
        labels: [][]const u8,
        properties: ?std.StringHashMap(Value),
    ) !Node {
        var gql = std.ArrayList(u8).init(self.allocator);
        defer gql.deinit();

        try gql.appendSlice("CREATE (n");
        for (labels, 0..) |label, i| {
            if (i == 0) {
                try gql.append(':');
            } else {
                try gql.append('&');
            }
            try gql.appendSlice(label);
        }

        if (properties) |props| {
            try gql.appendSlice(" {");
            var first = true;
            var it = props.iterator();
            while (it.next()) |entry| {
                if (!first) try gql.appendSlice(", ");
                first = false;
                try gql.appendSlice(entry.key_ptr.*);
                try gql.appendSlice(": ");
                try self.appendValue(&gql, entry.value_ptr.*);
            }
            try gql.append('}');
        }

        try gql.appendSlice(") RETURN n");

        var iter = try self.query(gql.items, null);
        defer iter.close();

        if (try iter.next()) |row| {
            if (row.get("n")) |node_value| {
                return self.parseNode(node_value);
            }
        }

        return error.NoNodeReturned;
    }

    pub fn createEdge(
        self: *Self,
        source_id: i64,
        target_id: i64,
        label: []const u8,
        properties: ?std.StringHashMap(Value),
    ) !Edge {
        var gql = std.ArrayList(u8).init(self.allocator);
        defer gql.deinit();

        try gql.writer().print("MATCH (a), (b) WHERE id(a) = {} AND id(b) = {} ", .{ source_id, target_id });

        try gql.writer().print("CREATE (a)-[e:{s}", .{label});

        if (properties) |props| {
            try gql.appendSlice(" {");
            var first = true;
            var it = props.iterator();
            while (it.next()) |entry| {
                if (!first) try gql.appendSlice(", ");
                first = false;
                try gql.appendSlice(entry.key_ptr.*);
                try gql.appendSlice(": ");
                try self.appendValue(&gql, entry.value_ptr.*);
            }
            try gql.append('}');
        }

        try gql.appendSlice("]->(b) RETURN e");

        var iter = try self.query(gql.items, null);
        defer iter.close();

        if (try iter.next()) |row| {
            if (row.get("e")) |edge_value| {
                return self.parseEdge(edge_value);
            }
        }

        return error.NoEdgeReturned;
    }

    pub fn match(self: *Self, pattern: []const u8, where_clause: ?[]const u8) !Iterator {
        var gql = std.ArrayList(u8).init(self.allocator);
        defer gql.deinit();

        try gql.appendSlice("MATCH ");
        try gql.appendSlice(pattern);

        if (where_clause) |where| {
            try gql.appendSlice(" WHERE ");
            try gql.appendSlice(where);
        }

        try gql.appendSlice(" RETURN *");

        return self.query(gql.items, null);
    }

    pub fn shortestPath(
        self: *Self,
        source_id: i64,
        target_id: i64,
        max_hops: u32,
    ) !Path {
        var gql = std.ArrayList(u8).init(self.allocator);
        defer gql.deinit();

        try gql.writer().print("MATCH (a), (b), p = shortestPath((a)-[*..{}]-(b)) WHERE id(a) = {} AND id(b) = {} RETURN p", .{ max_hops, source_id, target_id });

        var iter = try self.query(gql.items, null);
        defer iter.close();

        if (try iter.next()) |row| {
            if (row.get("p")) |path_value| {
                return self.parsePath(path_value);
            }
        }

        return error.NoPathFound;
    }

    // RLS Policy management
    pub fn createRLSPolicy(
        self: *Self,
        name: []const u8,
        table: []const u8,
        graph: []const u8,
        operation: []const u8,
        using_expr: ?[]const u8,
        check_expr: ?[]const u8,
        roles: []i64,
    ) !void {
        const msg = .{
            .type = "RLS_CREATE_POLICY",
            .name = name,
            .table = table,
            .graph = graph,
            .operation = operation,
            .using_expr = using_expr,
            .check_expr = check_expr,
            .roles = roles,
            .enabled = true,
        };

        try self.sendMessage(msg);
        _ = try self.receiveMessage();
    }

    // Helper functions
    fn appendValue(self: *Self, list: *std.ArrayList(u8), value: Value) !void {
        _ = self;
        switch (value) {
            .null => try list.appendSlice("null"),
            .bool => |b| try list.writer().print("{}", .{b}),
            .int => |i| try list.writer().print("{}", .{i}),
            .float => |f| try list.writer().print("{d}", .{f}),
            .string => |s| {
                try list.append('"');
                try list.appendSlice(s);
                try list.append('"');
            },
            .decimal => |d| {
                try list.appendSlice("DECIMAL('");
                try list.appendSlice(d.value);
                try list.writer().print("', {})", .{d.scale});
            },
            else => return error.UnsupportedValueType,
        }
    }

    fn parseNode(self: *Self, value: Value) Node {
        _ = self;
        // Implementation would parse node from Value
        return Node{
            .id = 0,
            .labels = &[_][]const u8{},
            .properties = std.StringHashMap(Value).init(self.allocator),
        };
    }

    fn parseEdge(self: *Self, value: Value) Edge {
        _ = self;
        // Implementation would parse edge from Value
        return Edge{
            .id = 0,
            .source_id = 0,
            .target_id = 0,
            .label = "",
            .properties = std.StringHashMap(Value).init(self.allocator),
        };
    }

    fn parsePath(self: *Self, value: Value) Path {
        _ = self;
        _ = value;
        // Implementation would parse path from Value
        return Path{
            .nodes = &[_]Node{},
            .edges = &[_]Edge{},
        };
    }
};

// Example usage
pub fn example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client with configuration
    const config = Config{
        .host = "127.0.0.1",
        .port = 7567,
        .use_quic = false, // Start with TCP
    };

    var client = Client.init(allocator, config);
    defer client.deinit();

    // Connect to server
    try client.connect();
    defer client.disconnect();

    // Authenticate
    try client.login("admin", "admin123");
    defer client.logout() catch {};

    // Begin transaction
    try client.beginTransaction();

    // Create some nodes
    const node1 = try client.createNode(
        &[_][]const u8{"Person"},
        null,
    );
    _ = node1;

    const node2 = try client.createNode(
        &[_][]const u8{"Company"},
        null,
    );
    _ = node2;

    // Query data
    var iter = try client.query(
        "MATCH (n:Person) RETURN n.name AS name, n.age AS age ORDER BY n.age LIMIT 10",
        null,
    );
    defer iter.close();

    while (try iter.next()) |row| {
        if (row.get("name")) |name| {
            std.debug.print("Name: {s}\n", .{name.string});
        }
    }

    // Commit transaction
    try client.commit();
}
