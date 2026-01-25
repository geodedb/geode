const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// GeodeClient - QUIC connection management for MCP server integration

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-045; FEATURE="JSON Library Migration"; ASPECT=MCPClient; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

// Import quic_transport through the parent module to ensure module resolution
const quic_transport = @import("mod.zig").quic_transport;

// MCP Client Protocol Message Types
const ClientRunGqlMessage = struct {
    type: []const u8 = "RUN_GQL",
    text: []const u8,
    params: ?[]const u8 = null,
};

// For raw params embedding (pre-formatted JSON string)
const ClientRunGqlWithParams = struct {
    type: []const u8 = "RUN_GQL",
    text: []const u8,
};

pub const GeodeClientError = error{
    ConnectionFailed,
    HandshakeFailed,
    QueryFailed,
    InvalidResponse,
    NotConnected,
    StreamError,
    Timeout,
    OutOfMemory,
    ServerError,
};

/// GeodeClient manages a QUIC connection to the Geode server
/// Uses lazy connection - connects on first request
pub const GeodeClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    port: u16,
    quic_client: ?quic_transport.QuicClient,
    stream: ?*quic_transport.QuicClientStream,
    connected: bool,
    handshake_done: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Parse endpoint (host:port)
        var host: []const u8 = endpoint;
        var port: u16 = 3141;

        if (std.mem.lastIndexOfScalar(u8, endpoint, ':')) |colon| {
            host = endpoint[0..colon];
            port = std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10) catch 3141;
        }

        self.* = Self{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, host),
            .port = port,
            .quic_client = null,
            .stream = null,
            .connected = false,
            .handshake_done = false,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.endpoint);
        self.allocator.destroy(self);
    }

    fn disconnect(self: *Self) void {
        if (self.stream) |s| {
            s.deinit();
            self.stream = null;
        }
        if (self.quic_client) |*client| {
            client.deinit();
            self.quic_client = null;
        }
        self.connected = false;
        self.handshake_done = false;
    }

    /// Ensure connection is established (lazy connect)
    fn ensureConnected(self: *Self) !void {
        if (self.connected and self.handshake_done) return;

        // Disconnect any partial state
        self.disconnect();

        // Initialize QUIC client
        self.quic_client = quic_transport.QuicClient.init(self.allocator);

        // Connect with insecure mode for local development (TODO: support TLS config)
        self.quic_client.?.connectInsecure(self.endpoint, self.port, true) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Connection failed to {s}:{d}: {}\n", .{ self.endpoint, self.port, err });
            return GeodeClientError.ConnectionFailed;
        };

        // Wait for handshake
        self.quic_client.?.waitForHandshake(5) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Handshake failed: {}\n", .{err});
            return GeodeClientError.HandshakeFailed;
        };

        // Open bidirectional stream
        self.stream = self.quic_client.?.getStream() catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Stream open failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };

        // Send HELLO and wait for acknowledgment
        const hello_msg = "{\"type\":\"HELLO\",\"client_name\":\"geode-mcp\",\"client_ver\":\"0.19.0\",\"wanted_conformance\":\"min\"}\n";
        self.stream.?.writeAll(hello_msg) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] HELLO send failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };

        // Read HELLO response
        const hello_response = self.readLineWithRetry() catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] HELLO response failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };
        defer self.allocator.free(hello_response);

        self.connected = true;
        self.handshake_done = true;
    }

    /// Read a line with retry logic for QUIC transport
    fn readLineWithRetry(self: *Self) ![]u8 {
        const stream = self.stream orelse return GeodeClientError.NotConnected;

        var retry_count: usize = 0;
        const max_retries: usize = 100;

        while (retry_count < max_retries) {
            const result = stream.readLine(1 << 20) catch |err| {
                if (err == error.WouldBlock) {
                    retry_count += 1;
                    self.quic_client.?.poll(10) catch {};
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return result;
        }

        return GeodeClientError.Timeout;
    }

    /// Execute a GQL query and return the JSON response
    /// CANARY: REQ=REQ-LIB-MIGRATION-JSON-046; FEATURE="JSON Library Migration"; ASPECT=ClientQuery; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
    pub fn query(self: *Self, gql: []const u8, params: ?[]const u8) ![]u8 {
        try self.ensureConnected();

        const stream = self.stream orelse return GeodeClientError.NotConnected;

        // Build RUN_GQL message using JSON library (handles escaping automatically)
        var msg: []u8 = undefined;
        if (params) |p| {
            // Use streaming encoder for raw JSON params embedding
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
            defer buf.deinit(self.allocator);
            var encoder = json_lib.streamingEncoder(self.allocator, buf.writer(self.allocator), .{});
            defer encoder.deinit();

            try encoder.beginObject();
            try encoder.writeKey("type");
            try encoder.writeString("RUN_GQL");
            try encoder.writeKey("text");
            try encoder.writeString(gql);
            try encoder.writeKey("params");
            try encoder.writeRaw(p);
            try encoder.endObject();

            // Add newline for line protocol
            try buf.append(self.allocator, '\n');
            msg = try buf.toOwnedSlice(self.allocator);
        } else {
            // Use struct encoding for simple case
            const message = ClientRunGqlMessage{ .text = gql };
            const json_bytes = try json_lib.encode(self.allocator, message, .{});
            defer self.allocator.free(json_bytes);
            msg = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json_bytes});
        }
        defer self.allocator.free(msg);

        stream.writeAll(msg) catch |err| {
            self.disconnect();
            return err;
        };

        // Read SCHEMA response
        const schema_line = self.readLineWithRetry() catch |err| {
            self.disconnect();
            return err;
        };

        // Check for error
        if (std.mem.indexOf(u8, schema_line, "\"type\":\"ERROR\"") != null) {
            return schema_line; // Return error response as-is
        }

        // Read BINDINGS response
        const bindings_line = self.readLineWithRetry() catch |err| {
            self.allocator.free(schema_line);
            self.disconnect();
            return err;
        };

        // Combine schema and bindings into a single result
        const combined = try std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":{s},\"bindings\":{s}}}",
            .{ schema_line, bindings_line },
        );

        self.allocator.free(schema_line);
        self.allocator.free(bindings_line);

        return combined;
    }

    /// Get database schema information
    pub fn getSchema(self: *Self) ![]u8 {
        // Query to get node labels, relationship types, and properties
        const schema_query =
            \\MATCH (n)
            \\WITH DISTINCT labels(n) AS labels
            \\RETURN labels
            \\LIMIT 100
        ;

        return self.query(schema_query, null) catch |err| {
            // If query fails, return a minimal schema
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8,
                    \\{"error": "Unable to connect to Geode server", "suggestion": "Ensure geode serve is running on the configured endpoint"}
                );
            }
            return err;
        };
    }

    /// Explain a GQL query plan
    /// CANARY: REQ=REQ-LIB-MIGRATION-JSON-047; FEATURE="JSON Library Migration"; ASPECT=ClientExplain; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
    pub fn explain(self: *Self, gql: []const u8) ![]u8 {
        try self.ensureConnected();

        const stream = self.stream orelse return GeodeClientError.NotConnected;

        // Build RUN_GQL message with EXPLAIN prefix using JSON library
        const explain_query = try std.fmt.allocPrint(self.allocator, "EXPLAIN {s}", .{gql});
        defer self.allocator.free(explain_query);

        const message = ClientRunGqlMessage{ .text = explain_query };
        const json_bytes = try json_lib.encode(self.allocator, message, .{});
        defer self.allocator.free(json_bytes);
        const msg = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json_bytes});
        defer self.allocator.free(msg);

        stream.writeAll(msg) catch |err| {
            self.disconnect();
            return err;
        };

        // Read response
        const response = self.readLineWithRetry() catch |err| {
            self.disconnect();
            return err;
        };

        return response;
    }

    /// List available catalogs
    pub fn listCatalogs(self: *Self) ![]u8 {
        // Use SHOW CATALOGS or equivalent query
        return self.query("SHOW CATALOGS", null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"catalogs\": [\"default\"], \"note\": \"Server unavailable, showing defaults\"}");
            }
            return err;
        };
    }

    /// List available graphs in a catalog
    pub fn listGraphs(self: *Self, catalog: ?[]const u8) ![]u8 {
        _ = catalog;
        // Use SHOW GRAPHS or equivalent query
        return self.query("SHOW GRAPHS", null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"graphs\": [\"default\"], \"note\": \"Server unavailable, showing defaults\"}");
            }
            return err;
        };
    }

    /// Get database statistics
    pub fn getStats(self: *Self) ![]u8 {
        const stats_query =
            \\MATCH (n)
            \\RETURN count(n) AS node_count
        ;
        return self.query(stats_query, null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"node_count\": 0, \"relationship_count\": 0, \"note\": \"Server unavailable\"}");
            }
            return err;
        };
    }

    /// Get server configuration
    pub fn getConfig(self: *Self) ![]u8 {
        // Return server info as JSON
        return try self.allocator.dupe(u8,
            \\{"version": "0.19.0", "gql_compliance": "ISO/IEC 39075:2024", "transport": "QUIC+TLS"}
        );
    }

    /// Check if client is currently connected
    pub fn isConnected(self: *Self) bool {
        return self.connected and self.handshake_done;
    }

    /// Reconnect to the server
    pub fn reconnect(self: *Self) !void {
        self.disconnect();
        try self.ensureConnected();
    }
};

// escapeJsonString removed - JSON library handles escaping automatically

// =============================================================================
// Tests
// =============================================================================

test "GeodeClient initialization" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    try std.testing.expectEqualStrings("localhost", client.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client.port);
    try std.testing.expect(!client.connected);
}

test "GeodeClient endpoint parsing" {
    const allocator = std.testing.allocator;

    // Test with port
    const client1 = try GeodeClient.init(allocator, "127.0.0.1:8443");
    defer client1.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", client1.endpoint);
    try std.testing.expectEqual(@as(u16, 8443), client1.port);

    // Test without port (default)
    const client2 = try GeodeClient.init(allocator, "geode.local");
    defer client2.deinit();
    try std.testing.expectEqualStrings("geode.local", client2.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client2.port);
}

test "JSON library handles escaping" {
    const allocator = std.testing.allocator;

    // Verify JSON library properly escapes special characters
    const TestMessage = struct { text: []const u8 };
    const message = TestMessage{ .text = "say \"hello\"\nworld" };
    const result = try json_lib.encode(allocator, message, .{});
    defer allocator.free(result);

    // Should contain escaped quotes and newline
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"hello\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
}

test "GeodeClient endpoint parsing with IPv6" {
    const allocator = std.testing.allocator;

    // IPv6 address without port (uses default)
    const client = try GeodeClient.init(allocator, "::1");
    defer client.deinit();
    try std.testing.expectEqualStrings("::1", client.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client.port);
}

test "GeodeClient isConnected initially false" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
}

test "GeodeClient getConfig returns valid JSON" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    const config = try client.getConfig();
    defer allocator.free(config);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, config, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "gql_compliance") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "QUIC+TLS") != null);
}

test "JSON library unicode passthrough" {
    const allocator = std.testing.allocator;

    // Verify JSON library handles unicode correctly
    const TestMessage = struct { text: []const u8 };
    const message = TestMessage{ .text = "Hello 世界 🌍" };
    const result = try json_lib.encode(allocator, message, .{});
    defer allocator.free(result);

    // Unicode should be present in output
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello 世界 🌍") != null);
}
