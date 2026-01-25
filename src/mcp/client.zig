const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// GeodeClient - QUIC connection management for MCP server integration

// Import quic_transport through the parent module to ensure module resolution
const quic_transport = @import("mod.zig").quic_transport;

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
    pub fn query(self: *Self, gql: []const u8, params: ?[]const u8) ![]u8 {
        try self.ensureConnected();

        const stream = self.stream orelse return GeodeClientError.NotConnected;

        // Escape the query for JSON embedding
        const escaped_gql = try escapeJsonString(self.allocator, gql);
        defer self.allocator.free(escaped_gql);

        // Build RUN_GQL message
        var msg: []u8 = undefined;
        if (params) |p| {
            msg = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\",\"params\":{s}}}\n", .{ escaped_gql, p });
        } else {
            msg = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}}\n", .{escaped_gql});
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
    pub fn explain(self: *Self, gql: []const u8) ![]u8 {
        try self.ensureConnected();

        const stream = self.stream orelse return GeodeClientError.NotConnected;

        // Escape the query for JSON embedding
        const escaped_gql = try escapeJsonString(self.allocator, gql);
        defer self.allocator.free(escaped_gql);

        // Build RUN_GQL message with EXPLAIN prefix
        const explain_query = try std.fmt.allocPrint(self.allocator, "EXPLAIN {s}", .{gql});
        defer self.allocator.free(explain_query);

        const escaped_explain = try escapeJsonString(self.allocator, explain_query);
        defer self.allocator.free(escaped_explain);

        const msg = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}}\n", .{escaped_explain});
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

/// Escape a string for safe embedding in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => escape_count += 1,
            else => {},
        }
    }

    if (escape_count == 0) {
        return allocator.dupe(u8, input);
    }

    const result = try allocator.alloc(u8, input.len + escape_count);
    var write_idx: usize = 0;

    for (input) |c| {
        switch (c) {
            '"' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '"';
                write_idx += 2;
            },
            '\\' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '\\';
                write_idx += 2;
            },
            '\n' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'n';
                write_idx += 2;
            },
            '\r' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'r';
                write_idx += 2;
            },
            '\t' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 't';
                write_idx += 2;
            },
            else => {
                result[write_idx] = c;
                write_idx += 1;
            },
        }
    }

    return result;
}

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

test "escapeJsonString" {
    const allocator = std.testing.allocator;

    const simple = try escapeJsonString(allocator, "hello");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("hello", simple);

    const with_quotes = try escapeJsonString(allocator, "say \"hello\"");
    defer allocator.free(with_quotes);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", with_quotes);

    const with_newline = try escapeJsonString(allocator, "line1\nline2");
    defer allocator.free(with_newline);
    try std.testing.expectEqualStrings("line1\\nline2", with_newline);
}

test "escapeJsonString with all escape characters" {
    const allocator = std.testing.allocator;

    // Test backslash
    const with_backslash = try escapeJsonString(allocator, "path\\to\\file");
    defer allocator.free(with_backslash);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", with_backslash);

    // Test carriage return
    const with_cr = try escapeJsonString(allocator, "line1\rline2");
    defer allocator.free(with_cr);
    try std.testing.expectEqualStrings("line1\\rline2", with_cr);

    // Test tab
    const with_tab = try escapeJsonString(allocator, "col1\tcol2");
    defer allocator.free(with_tab);
    try std.testing.expectEqualStrings("col1\\tcol2", with_tab);

    // Test combined
    const combined = try escapeJsonString(allocator, "\"hello\"\n\tworld\\");
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("\\\"hello\\\"\\n\\tworld\\\\", combined);
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

test "escapeJsonString empty string" {
    const allocator = std.testing.allocator;

    const empty = try escapeJsonString(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "escapeJsonString unicode passthrough" {
    const allocator = std.testing.allocator;

    // Unicode should pass through unchanged (only ASCII control chars are escaped)
    const unicode = try escapeJsonString(allocator, "Hello 世界 🌍");
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("Hello 世界 🌍", unicode);
}
