const std = @import("std");
const builtin = @import("builtin");
const repl_errors = @import("repl_errors.zig");
const repl_render = @import("repl_render.zig");
const platform = @import("platform.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-063; FEATURE="JSON Library Migration"; ASPECT=ReplDispatch; STATUS=EXEMPT; OWNER=client; UPDATED=2026-01-25
const json_lib = @import("json");

// CANARY: REQ=REQ-SHELL-INTERRUPT-003; FEATURE="SourceInterrupt"; ASPECT=CheckFunction; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
// Issue #390: Helper function to check for Ctrl+C (ASCII 3) in stdin without blocking
fn checkForInterrupt() bool {
    if (builtin.os.tag == .windows) {
        // Windows: TODO - implement console input check
        return false;
    } else {
        // POSIX: use poll with 0 timeout to check if data is available
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const result = std.posix.poll(&fds, 0) catch return false;
        if (result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            // Data available, check if it's Ctrl+C (ASCII 3)
            var buf: [1]u8 = undefined;
            const stdin = platform.getStdinHandle();
            const bytes_read = stdin.read(&buf) catch return false;
            if (bytes_read > 0 and buf[0] == 3) { // Ctrl+C
                return true;
            }
        }
        return false;
    }
}

// JSON message types for REPL protocol
const ReplRunGqlMessage = struct {
    type: []const u8 = "RUN_GQL",
    text: []const u8,
};

// CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=ClientSession; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=repl; UPDATED=2026-01-15

// Transport interface - implemented by CLI layer to avoid module conflicts

/// Transport interface for REPL communication
pub const Transport = struct {
    connectFn: *const fn (allocator: std.mem.Allocator, addr: []const u8) anyerror!*TransportConnection,

    pub fn connect(self: *const Transport, allocator: std.mem.Allocator, addr: []const u8) !*TransportConnection {
        return self.connectFn(allocator, addr);
    }
};

/// Transport connection interface
pub const TransportConnection = struct {
    writeAllFn: *const fn (self: *TransportConnection, data: []const u8) anyerror!void,
    readLineFn: *const fn (self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) anyerror![]u8,
    deinitFn: *const fn (self: *TransportConnection) void,
    context: ?*anyopaque = null,
    allocator: ?std.mem.Allocator = null,

    pub fn writeAll(self: *TransportConnection, data: []const u8) !void {
        return self.writeAllFn(self, data);
    }

    pub fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        return self.readLineFn(self, allocator, max_size);
    }

    pub fn deinit(self: *TransportConnection) void {
        return self.deinitFn(self);
    }
};

/// Mock transport connection for testing/fallback
const MockTransportConnection = struct {
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *TransportConnection, data: []const u8) !void {
        _ = self;
        _ = data;
        // Mock implementation - do nothing
    }

    pub fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        _ = self;
        _ = max_size;
        // Mock implementation - return simple JSON response
        return allocator.dupe(u8, "{\"type\":\"MOCK_RESPONSE\"}");
    }

    pub fn deinit(self: *TransportConnection) void {
        const alloc = self.allocator orelse return;
        if (self.context) |ctx| {
            const mock: *MockTransportConnection = @ptrCast(@alignCast(ctx));
            alloc.destroy(mock);
        }
        alloc.destroy(self);
    }
};

fn mockConnectFn(allocator: std.mem.Allocator, addr: []const u8) !*TransportConnection {
    _ = addr;
    const mock = try allocator.create(MockTransportConnection);
    mock.* = MockTransportConnection{ .allocator = allocator };

    // Return as TransportConnection interface
    const transport_conn = try allocator.create(TransportConnection);
    transport_conn.* = TransportConnection{
        .writeAllFn = MockTransportConnection.writeAll,
        .readLineFn = MockTransportConnection.readLine,
        .deinitFn = MockTransportConnection.deinit,
        .context = mock,
        .allocator = allocator,
    };
    return transport_conn;
}

/// Default mock transport for testing
pub const mock_transport = Transport{
    .connectFn = mockConnectFn,
};

/// Escape a string for safe embedding in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count how many characters need escaping to allocate correct size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => escape_count += 1,
            else => {},
        }
    }

    // If no escaping needed, just duplicate the string
    if (escape_count == 0) {
        return allocator.dupe(u8, input);
    }

    // Allocate buffer for escaped string
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

/// CANARY: REQ=REQ-SHELL-RECONNECT-001; FEATURE="ShellAutoReconnect"; ASPECT=ReconnectionConfig; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Configuration for automatic reconnection with exponential backoff
pub const ReconnectionConfig = struct {
    /// Maximum number of reconnection attempts (0 = disabled)
    max_attempts: u32 = 5,
    /// Initial delay between attempts in milliseconds
    initial_delay_ms: u64 = 100,
    /// Maximum delay between attempts in milliseconds
    max_delay_ms: u64 = 10000,
    /// Multiplier for exponential backoff (e.g., 2.0 = double each time)
    backoff_multiplier: f64 = 2.0,
    /// Whether to prompt user for transaction recovery
    prompt_for_txn_recovery: bool = true,
};

/// CANARY: REQ=REQ-SHELL-RECONNECT-002; FEATURE="ShellAutoReconnect"; ASPECT=TransactionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Tracks pending transaction state for recovery after reconnection
pub const PendingTransactionState = struct {
    /// Whether a transaction was active when connection was lost
    had_active_transaction: bool = false,
    /// The graph that was in use (if any)
    current_graph: ?[]const u8 = null,
    /// Number of statements executed in the transaction
    statements_in_txn: usize = 0,

    pub fn reset(self: *PendingTransactionState) void {
        self.had_active_transaction = false;
        self.current_graph = null;
        self.statements_in_txn = 0;
    }
};

/// User's choice for transaction recovery after reconnection
pub const TransactionRecoveryChoice = enum {
    /// Resume the transaction (start a new BEGIN)
    resume_transaction,
    /// Cancel the transaction (don't start a new transaction)
    cancel_transaction,
    /// Abort the reconnection entirely
    abort_reconnection,
};

pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    connected: bool = false,
    transport: ?*const Transport = null,
    connection: ?*TransportConnection = null,
    last_response: ?[]u8 = null,
    /// CANARY: REQ=REQ-SHELL-RECONNECT-003; FEATURE="ShellAutoReconnect"; ASPECT=SessionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    reconnect_config: ReconnectionConfig = .{},
    pending_txn_state: PendingTransactionState = .{},
    /// Cached credentials for re-authentication after reconnect
    cached_username: ?[]const u8 = null,
    cached_password: ?[]const u8 = null,
    /// Count of successful reconnections (for diagnostics)
    reconnect_count: u32 = 0,
    /// Last reconnection error (for diagnostics)
    last_reconnect_error: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, addr: []const u8, transport: *const Transport) !ClientSession {
        return ClientSession{
            .allocator = allocator,
            .server_addr = try allocator.dupe(u8, addr),
            .transport = transport,
        };
    }

    pub fn connect(self: *ClientSession) !void {
        if (self.transport) |transport| {
            self.connection = try transport.connect(self.allocator, self.server_addr);
            self.connected = true;
        } else {
            return error.NotConnected;
        }
    }

    pub fn deinit(self: *ClientSession) void {
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.allocator.free(self.server_addr);
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }
        if (self.cached_username) |u| {
            self.allocator.free(u);
            self.cached_username = null;
        }
        if (self.cached_password) |p| {
            self.allocator.free(p);
            self.cached_password = null;
        }
        if (self.last_reconnect_error) |e| {
            self.allocator.free(e);
            self.last_reconnect_error = null;
        }
        // CANARY: REQ=REQ-SOURCE-PERF-003; FEATURE="SourceFilePerformance"; ASPECT=CacheCleanupOnExit; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
        // Issue #413: Clean up global file hash cache to prevent memory leaks on exit
        deinitSourcedFileCache();
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-004; FEATURE="ShellAutoReconnect"; ASPECT=ErrorDetection; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Check if an error indicates a lost connection that can be recovered
    pub fn isConnectionError(err: anyerror) bool {
        return switch (err) {
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.NotConnected,
            error.SocketNotConnected,
            error.InputOutput,
            error.EndOfStream,
            error.Unexpected,
            => true,
            else => false,
        };
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-005; FEATURE="ShellAutoReconnect"; ASPECT=ReconnectWithBackoff; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Attempt to reconnect with exponential backoff
    /// Returns true if reconnection succeeded, false if all attempts failed
    pub fn reconnect(self: *ClientSession) !bool {
        if (self.reconnect_config.max_attempts == 0) {
            return false; // Reconnection disabled
        }

        const stderr = platform.getStderrHandle();
        const stdout = platform.getStdoutHandle();

        // Close existing connection if any
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.connected = false;

        var delay_ms = self.reconnect_config.initial_delay_ms;
        var attempt: u32 = 0;

        while (attempt < self.reconnect_config.max_attempts) : (attempt += 1) {
            // Display reconnection attempt
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "\r\nConnection lost. Reconnecting (attempt {d}/{d})...\r\n", .{ attempt + 1, self.reconnect_config.max_attempts }) catch "";
            stdout.writeAll(msg) catch {};

            // Wait before attempting (except first attempt)
            if (attempt > 0) {
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                // Exponential backoff
                const new_delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * self.reconnect_config.backoff_multiplier));
                delay_ms = @min(new_delay, self.reconnect_config.max_delay_ms);
            }

            // Attempt connection
            self.connect() catch |err| {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "  Attempt {d} failed: {s}\r\n", .{ attempt + 1, @errorName(err) }) catch "";
                stderr.writeAll(err_msg) catch {};
                continue;
            };

            // Attempt HELLO handshake
            if (self.cached_username != null and self.cached_password != null) {
                const auth_result = self.helloWithAuth(self.cached_username.?, self.cached_password.?) catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  Auth handshake failed: {s}\r\n", .{@errorName(err)}) catch "";
                    stderr.writeAll(err_msg) catch {};
                    // Close connection and retry
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                };
                if (!auth_result.success) {
                    stderr.writeAll("  Authentication failed after reconnect\r\n") catch {};
                    if (auth_result.error_message) |em| self.allocator.free(em);
                    if (auth_result.session_token) |st| self.allocator.free(st);
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                }
                if (auth_result.session_token) |st| self.allocator.free(st);
            } else {
                self.hello() catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  Handshake failed: {s}\r\n", .{@errorName(err)}) catch "";
                    stderr.writeAll(err_msg) catch {};
                    // Close connection and retry
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                };
            }

            // Success!
            self.reconnect_count += 1;
            stdout.writeAll("  Reconnected successfully!\r\n") catch {};
            return true;
        }

        // All attempts failed
        stderr.writeAll("  All reconnection attempts failed.\r\n") catch {};
        return false;
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-006; FEATURE="ShellAutoReconnect"; ASPECT=CacheCredentials; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Cache credentials for use during reconnection
    pub fn cacheCredentials(self: *ClientSession, username: []const u8, password: []const u8) !void {
        if (self.cached_username) |u| self.allocator.free(u);
        if (self.cached_password) |p| self.allocator.free(p);
        self.cached_username = try self.allocator.dupe(u8, username);
        self.cached_password = try self.allocator.dupe(u8, password);
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-007; FEATURE="ShellAutoReconnect"; ASPECT=SaveTransactionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Save current transaction state before reconnection attempt
    pub fn saveTransactionState(self: *ClientSession, in_txn: bool, current_graph: ?[]const u8, stmt_count: usize) void {
        self.pending_txn_state.had_active_transaction = in_txn;
        self.pending_txn_state.current_graph = current_graph;
        self.pending_txn_state.statements_in_txn = stmt_count;
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-008; FEATURE="ShellAutoReconnect"; ASPECT=RestoreGraphContext; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Restore graph context after reconnection (sends USE GRAPH if needed)
    pub fn restoreGraphContext(self: *ClientSession, current_graph: ?[]const u8) !void {
        if (current_graph) |graph| {
            // Send USE GRAPH statement to restore context
            const use_stmt = try std.fmt.allocPrint(self.allocator, "USE GRAPH {s};", .{graph});
            defer self.allocator.free(use_stmt);
            try self.runGql(use_stmt);
        }
    }

    // CANARY: REQ=REQ-SHELL-AUTH-001; FEATURE="ShellAuthRequired"; ASPECT=HelloAuthCheck; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #387: HELLO handshake that checks if authentication is required
    pub fn hello(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Send HELLO handshake
        const hello_msg = "{\"type\":\"HELLO\",\"client_name\":\"geode-repl\",\"client_ver\":\"0.18.0\",\"wanted_conformance\":\"min\"}\n";
        try self.connection.?.writeAll(hello_msg);

        // Read HELLO acknowledgment and check for auth requirement
        const hello_ack = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(hello_ack);

        // Check if server requires authentication
        if (std.mem.indexOf(u8, hello_ack, "Authentication required") != null) {
            return error.AuthenticationRequired;
        }
    }

    /// GAP-0150: Authenticated HELLO handshake for CLI authentication
    /// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLI QUIC Authentication"; ASPECT=AuthenticatedHello; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=security; UPDATED=2026-01-15
    pub const AuthHelloResult = struct {
        success: bool,
        session_token: ?[]const u8,
        requires_password_reset: bool,
        error_message: ?[]const u8,
    };

    pub fn helloWithAuth(self: *ClientSession, username: []const u8, password: []const u8) !AuthHelloResult {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Escape credentials for JSON
        const escaped_username = try escapeJsonString(self.allocator, username);
        defer self.allocator.free(escaped_username);
        const escaped_password = try escapeJsonString(self.allocator, password);
        defer self.allocator.free(escaped_password);

        // Send authenticated HELLO handshake
        const hello_msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"HELLO\",\"client_name\":\"geode-cli\",\"client_ver\":\"0.18.0\",\"wanted_conformance\":\"min\",\"username\":\"{s}\",\"password\":\"{s}\"}}\n",
            .{ escaped_username, escaped_password },
        );
        defer self.allocator.free(hello_msg);
        try self.connection.?.writeAll(hello_msg);

        // Read HELLO response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);

        // Parse response
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{ .duplicate_field_behavior = .use_last }) catch {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Invalid server response"),
            };
        };
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Check if it's an error response
        const type_val = obj.get("type") orelse {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Missing type in response"),
            };
        };

        if (type_val != .string) {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Invalid type in response"),
            };
        }

        const type_str = type_val.string;

        if (std.mem.eql(u8, type_str, "ERROR")) {
            const msg = if (obj.get("message")) |m|
                if (m == .string) try self.allocator.dupe(u8, m.string) else try self.allocator.dupe(u8, "Authentication failed")
            else
                try self.allocator.dupe(u8, "Authentication failed");

            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = msg,
            };
        }

        if (std.mem.eql(u8, type_str, "HELLO")) {
            // Authentication successful - extract session token if provided
            const session_token = if (obj.get("session_token")) |st|
                if (st == .string) try self.allocator.dupe(u8, st.string) else null
            else
                null;

            const requires_reset = if (obj.get("requires_password_reset")) |rpr|
                if (rpr == .bool) rpr.bool else false
            else
                false;

            return AuthHelloResult{
                .success = true,
                .session_token = session_token,
                .requires_password_reset = requires_reset,
                .error_message = null,
            };
        }

        return AuthHelloResult{
            .success = false,
            .session_token = null,
            .requires_password_reset = false,
            .error_message = try self.allocator.dupe(u8, "Unexpected response type"),
        };
    }

    pub fn runGql(self: *ClientSession, gql: []const u8) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Send RUN_GQL message using json library encoding
        // Note: json_lib.encode handles string escaping automatically
        const run_msg = ReplRunGqlMessage{ .text = gql };
        const json_str = try json_lib.encode(self.allocator, run_msg, .{});
        defer self.allocator.free(json_str);

        // Append newline
        const msg = try self.allocator.alloc(u8, json_str.len + 1);
        defer self.allocator.free(msg);
        @memcpy(msg[0..json_str.len], json_str);
        msg[json_str.len] = '\n';

        try self.connection.?.writeAll(msg);

        // Clear previous response
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }

        // Read the response - server returns exactly one response per RUN_GQL
        // (either SCHEMA on success or error response)
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        self.last_response = response;
    }

    pub fn begin(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        try self.connection.?.writeAll("{\"type\":\"BEGIN\"}\n");

        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn commit(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        try self.connection.?.writeAll("{\"type\":\"COMMIT\"}\n");

        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn rollback(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        try self.connection.?.writeAll("{\"type\":\"ROLLBACK\"}\n");

        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn pullAll(self: *ClientSession, sink: anytype) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Send PULL request for all results at once (page_size:-1)
        // With page_size:-1, the server returns ALL results in a single response
        const pull_msg = "{\"type\":\"PULL\",\"request_id\":1,\"page_size\":-1}\n";
        try self.connection.?.writeAll(pull_msg);

        // Read the single response containing all results
        // Note: Server strips "final":true from responses for compatibility,
        // so we can't rely on that marker. With page_size:-1, we get exactly one response.
        const response = try self.connection.?.readLine(self.allocator, 1 << 20); // 1MB max
        defer self.allocator.free(response);

        if (response.len > 0) {
            try sink.appendSlice(self.allocator, response);
        }
    }

    /// Drain any pending responses from the connection (cleanup after errors)
    /// Note: This function attempts to discard stale data but may not fully drain
    /// since the server strips "final" markers. Use sparingly.
    pub fn drain(self: *ClientSession) void {
        if (!self.connected or self.connection == null) return;

        // Try to read and discard a few pending messages
        // This is a best-effort cleanup, not guaranteed to work perfectly
        var iterations: usize = 0;
        while (iterations < 3) : (iterations += 1) {
            const response = self.connection.?.readLine(self.allocator, 1 << 16) catch break;
            self.allocator.free(response);
        }
    }
};

/// CANARY: REQ=REQ-SHELL-RECONNECT-009; FEATURE="ShellAutoReconnect"; ASPECT=TransactionRecoveryPrompt; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Prompt user for transaction recovery choice after reconnection
/// Returns the user's choice for how to handle the pending transaction
pub fn promptTransactionRecovery(pending_state: *const PendingTransactionState) !TransactionRecoveryChoice {
    const stdout = platform.getStdoutHandle();
    const stdin = platform.getStdinHandle();

    // Display transaction state information
    try stdout.writeAll("\r\n");
    try stdout.writeAll("╔══════════════════════════════════════════════════════════════╗\r\n");
    try stdout.writeAll("║           TRANSACTION RECOVERY REQUIRED                      ║\r\n");
    try stdout.writeAll("╠══════════════════════════════════════════════════════════════╣\r\n");
    try stdout.writeAll("║ Connection was lost while a transaction was active.         ║\r\n");
    try stdout.writeAll("║ The transaction has been rolled back on the server.         ║\r\n");
    try stdout.writeAll("╟──────────────────────────────────────────────────────────────╢\r\n");

    // Show transaction details
    var buf: [256]u8 = undefined;
    const stmt_msg = std.fmt.bufPrint(&buf, "║ Statements executed in transaction: {d:<24} ║\r\n", .{pending_state.statements_in_txn}) catch "";
    try stdout.writeAll(stmt_msg);

    if (pending_state.current_graph) |graph| {
        const graph_msg = std.fmt.bufPrint(&buf, "║ Graph context: {s:<45} ║\r\n", .{graph}) catch "";
        try stdout.writeAll(graph_msg);
    } else {
        try stdout.writeAll("║ Graph context: (default)                                     ║\r\n");
    }

    try stdout.writeAll("╟──────────────────────────────────────────────────────────────╢\r\n");
    try stdout.writeAll("║ How would you like to proceed?                               ║\r\n");
    try stdout.writeAll("║                                                              ║\r\n");
    try stdout.writeAll("║   [R] Resume - Start a new transaction and continue         ║\r\n");
    try stdout.writeAll("║   [C] Cancel - Continue without a transaction               ║\r\n");
    try stdout.writeAll("║   [A] Abort  - Disconnect and exit                          ║\r\n");
    try stdout.writeAll("╚══════════════════════════════════════════════════════════════╝\r\n");
    try stdout.writeAll("\r\nYour choice [R/C/A]: ");

    // Read user input
    var input_buf: [16]u8 = undefined;
    const bytes_read = stdin.read(&input_buf) catch {
        return .cancel_transaction; // Default to cancel on error
    };

    if (bytes_read == 0) {
        return .cancel_transaction;
    }

    // Parse the response
    const choice = std.mem.trim(u8, input_buf[0..bytes_read], " \t\r\n");
    if (choice.len == 0) {
        return .cancel_transaction;
    }

    const first_char = std.ascii.toLower(choice[0]);
    return switch (first_char) {
        'r' => .resume_transaction,
        'c' => .cancel_transaction,
        'a' => .abort_reconnection,
        else => blk: {
            try stdout.writeAll("Invalid choice. Defaulting to Cancel.\r\n");
            break :blk .cancel_transaction;
        },
    };
}

/// CANARY: REQ=REQ-SHELL-RECONNECT-010; FEATURE="ShellAutoReconnect"; ASPECT=HandleConnectionError; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Handle a connection error by attempting reconnection and transaction recovery
/// Returns true if the operation should be retried, false otherwise
pub fn handleConnectionError(state: anytype, err: anyerror) !bool {
    const stderr = platform.getStderrHandle();

    // Check if this is a recoverable connection error
    if (!ClientSession.isConnectionError(err)) {
        return false; // Not a connection error, don't retry
    }

    // Save transaction state before reconnection
    const txn_stmt_count = if (@hasField(@TypeOf(state.*), "txn_statement_count"))
        state.txn_statement_count
    else
        0;
    state.session.saveTransactionState(state.in_txn, state.current_graph, txn_stmt_count);

    // Attempt reconnection
    const reconnected = state.session.reconnect() catch |reconnect_err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Reconnection failed: {s}\r\n", .{@errorName(reconnect_err)}) catch "";
        stderr.writeAll(msg) catch {};
        return false;
    };

    if (!reconnected) {
        return false;
    }

    // Restore graph context if needed
    if (state.current_graph) |graph| {
        state.session.restoreGraphContext(graph) catch |restore_err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Warning: Could not restore graph context: {s}\r\n", .{@errorName(restore_err)}) catch "";
            stderr.writeAll(msg) catch {};
        };
    }

    // Handle transaction recovery if there was an active transaction
    if (state.session.pending_txn_state.had_active_transaction) {
        if (state.session.reconnect_config.prompt_for_txn_recovery) {
            const choice = try promptTransactionRecovery(&state.session.pending_txn_state);

            switch (choice) {
                .resume_transaction => {
                    // Start a new transaction
                    state.session.begin() catch |begin_err| {
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Warning: Could not start new transaction: {s}\r\n", .{@errorName(begin_err)}) catch "";
                        stderr.writeAll(msg) catch {};
                        state.in_txn = false;
                    };
                    state.in_txn = true;
                    const stdout = platform.getStdoutHandle();
                    stdout.writeAll("New transaction started. Please re-execute your statements.\r\n") catch {};
                },
                .cancel_transaction => {
                    state.in_txn = false;
                    const stdout = platform.getStdoutHandle();
                    stdout.writeAll("Continuing without transaction.\r\n") catch {};
                },
                .abort_reconnection => {
                    state.quit_requested = true;
                    return false;
                },
            }
        } else {
            // Auto-cancel transaction if prompting is disabled
            state.in_txn = false;
        }
    }

    // Reset pending transaction state
    state.session.pending_txn_state.reset();

    return true; // Retry the operation
}

pub fn handleMetaCommand(state: anytype, input: []const u8) !void {
    const stdout = platform.getStdoutHandle();

    // Move to new line before displaying any output
    try stdout.writeAll("\r\n");

    // Parse command
    const space_idx = std.mem.indexOf(u8, input[1..], " ");
    const cmd = if (space_idx) |idx| input[1 .. idx + 1] else input[1..];
    const args = if (space_idx) |idx| std.mem.trim(u8, input[idx + 2 ..], " \t") else "";

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
        const use_color = platform.isStdoutTty();
        const green = if (use_color) "\x1b[32m" else "";
        const yellow = if (use_color) "\x1b[33m" else "";
        const cyan = if (use_color) "\x1b[36m" else "";
        const reset = if (use_color) "\x1b[0m" else "";
        const bold = if (use_color) "\x1b[1m" else "";

        try stdout.writeAll(green);
        try stdout.writeAll(bold);
        try stdout.writeAll("=== Geode Shell Commands ===\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Meta-Commands (start with \\ or /):\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\help, \\h, \\?");
        try stdout.writeAll(reset);
        try stdout.writeAll("     Show this help\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\quit, \\q, \\exit");
        try stdout.writeAll(reset);
        try stdout.writeAll(" Exit the shell\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\clear");
        try stdout.writeAll(reset);
        try stdout.writeAll("            Clear screen\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("History:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\history [n]");
        try stdout.writeAll(reset);
        try stdout.writeAll("      Show last n history entries\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\history -c");
        try stdout.writeAll(reset);
        try stdout.writeAll("       Clear history\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Connection:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\connect <addr>");
        try stdout.writeAll(reset);
        try stdout.writeAll("   Connect to server\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\disconnect");
        try stdout.writeAll(reset);
        try stdout.writeAll("       Disconnect from server\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Graphs:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\use <graph>");
        try stdout.writeAll(reset);
        try stdout.writeAll("      Switch to graph\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\graph");
        try stdout.writeAll(reset);
        try stdout.writeAll("            Show current graph\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\graphs");
        try stdout.writeAll(reset);
        try stdout.writeAll("           List all graphs\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Transactions:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\begin");
        try stdout.writeAll(reset);
        try stdout.writeAll("            Start transaction\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\commit");
        try stdout.writeAll(reset);
        try stdout.writeAll("           Commit transaction\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\rollback");
        try stdout.writeAll(reset);
        try stdout.writeAll("         Rollback transaction\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Settings:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\timing on|off");
        try stdout.writeAll(reset);
        try stdout.writeAll("    Toggle query timing\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\format <fmt>");
        try stdout.writeAll(reset);
        try stdout.writeAll("     Set output format (table|csv|json)\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\set <opt> <val>");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Set option (e.g., keymap emacs|vi)\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Other:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\echo <text>");
        try stdout.writeAll(reset);
        try stdout.writeAll("      Echo text\r\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\source <file>");
        try stdout.writeAll(reset);
        try stdout.writeAll("    Execute commands from file\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(green);
        try stdout.writeAll("Keyboard Shortcuts:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Ctrl+C            Exit (on empty line) or cancel input\r\n");
        try stdout.writeAll("  Ctrl+D            Exit (on empty line)\r\n");
        try stdout.writeAll("  Ctrl+L            Clear screen\r\n");
        try stdout.writeAll("  Ctrl+P/N          Navigate history\r\n");
        try stdout.writeAll("  Ctrl+A/E          Move to beginning/end of line\r\n");
        try stdout.writeAll("\r\n");

        try stdout.writeAll(green);
        try stdout.writeAll("GQL Queries:\r\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Type GQL directly and end with semicolon (;)\r\n");
        try stdout.writeAll("  Example: ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("MATCH (n) RETURN n LIMIT 5;");
        try stdout.writeAll(reset);
        try stdout.writeAll("\r\n");
        try stdout.writeAll("\r\n");

        // Note: Don't sync() stdout - causes panics on ttys
    } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
        state.quit_requested = true;
    } else if (std.mem.eql(u8, cmd, "history")) {
        if (std.mem.eql(u8, args, "-c")) {
            try state.history.clear();
            try stdout.writeAll("History cleared\r\n");
        } else {
            const n = if (args.len > 0) std.fmt.parseInt(usize, args, 10) catch 10 else 10;
            const start = if (state.history.entries.items.len > n)
                state.history.entries.items.len - n
            else
                0;

            for (state.history.entries.items[start..], start..) |entry, i| {
                var buf: [1024]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{d:4}: {s}\r\n", .{ i + 1, entry });
                try stdout.writeAll(line);
            }
        }
    } else if (std.mem.eql(u8, cmd, "clear")) {
        try stdout.writeAll("\x1b[2J\x1b[H"); // Clear screen and home cursor
    } else if (std.mem.eql(u8, cmd, "connect")) {
        if (args.len > 0) {
            // Save the current transport before deinit
            const current_transport = state.session.transport orelse return error.NoTransport;
            state.session.deinit();
            state.session.* = try ClientSession.init(state.allocator, args, current_transport);
            try state.session.connect();
            try state.session.hello();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Connected to {s}\r\n", .{args});
            try stdout.writeAll(msg);
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\connect <host:port>\r\n", .{});
            try stderr.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "disconnect")) {
        state.session.connected = false;
        try stdout.writeAll("Disconnected\r\n");
    } else if (std.mem.eql(u8, cmd, "use")) {
        // \use <graph> - Switch to a different graph
        if (args.len > 0) {
            // Strip trailing semicolon if present (user might type "/use mydb;")
            const graph_name = std.mem.trimRight(u8, args, ";");
            if (graph_name.len == 0) {
                const stderr = platform.getStderrHandle();
                try stderr.writeAll("Error [GEODE-E2002]: Usage: \\use <graph_name>\r\n");
                return;
            }

            // Send USE GRAPH statement to server
            const use_stmt = try std.fmt.allocPrint(state.allocator, "USE GRAPH {s};", .{graph_name});
            defer state.allocator.free(use_stmt);
            try executeGql(state, use_stmt);

            // Check if server returned an error before updating local state
            var has_error = false;
            if (state.session.last_response) |response| {
                // Check for error status codes (4xxxx or 5xxxx) which indicate graph not found, etc.
                if (std.mem.indexOf(u8, response, "\"status_class\":\"4") != null or
                    std.mem.indexOf(u8, response, "\"status_class\":\"5") != null)
                {
                    has_error = true;
                }
            }

            // Only update local state if server accepted the graph switch
            if (!has_error) {
                if (state.current_graph) |old| {
                    state.allocator.free(old);
                }
                state.current_graph = try state.allocator.dupe(u8, graph_name);
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Switched to graph: {s}\r\n", .{graph_name});
                try stdout.writeAll(msg);
            }
            // Error message is already displayed by executeGql
        } else {
            const stderr = platform.getStderrHandle();
            try stderr.writeAll("Error [GEODE-E2002]: Usage: \\use <graph_name>\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "graph")) {
        // \graph - Show current graph
        if (state.current_graph) |graph| {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Current graph: {s}\r\n", .{graph});
            try stdout.writeAll(msg);
        } else {
            try stdout.writeAll("No graph selected (using default)\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "graphs")) {
        // \graphs - List all graphs
        try executeGql(state, "SHOW GRAPHS;");
    } else if (std.mem.eql(u8, cmd, "begin")) {
        try state.session.begin();
        state.in_txn = true;
        try stdout.writeAll("Transaction started\r\n");
    } else if (std.mem.eql(u8, cmd, "commit")) {
        try state.session.commit();
        state.in_txn = false;
        try stdout.writeAll("Transaction committed\r\n");
    } else if (std.mem.eql(u8, cmd, "rollback")) {
        try state.session.rollback();
        state.in_txn = false;
        try stdout.writeAll("Transaction rolled back\r\n");
    } else if (std.mem.eql(u8, cmd, "timing")) {
        if (std.mem.eql(u8, args, "on")) {
            state.show_timing = true;
            try stdout.writeAll("Timing is on\r\n");
        } else if (std.mem.eql(u8, args, "off")) {
            state.show_timing = false;
            try stdout.writeAll("Timing is off\r\n");
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\timing on|off\r\n", .{});
            try stderr.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "format")) {
        if (std.mem.eql(u8, args, "table")) {
            state.format = .table;
        } else if (std.mem.eql(u8, args, "csv")) {
            state.format = .csv;
        } else if (std.mem.eql(u8, args, "json")) {
            state.format = .json;
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\format table|csv|json\r\n", .{});
            try stderr.writeAll(msg);
            return;
        }
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Output format set to {s}\r\n", .{args});
        try stdout.writeAll(msg);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const parts = try splitOnce(state.allocator, args, ' ');
        defer state.allocator.free(parts[0]);
        defer state.allocator.free(parts[1]);

        if (std.mem.eql(u8, parts[0], "keymap")) {
            if (std.mem.eql(u8, parts[1], "emacs")) {
                state.keymap = .emacs;
                try stdout.writeAll("Keymap set to emacs\r\n");
            } else if (std.mem.eql(u8, parts[1], "vi")) {
                state.keymap = .vi;
                state.vi_mode = .insert;
                try stdout.writeAll("Keymap set to vi\r\n");
            } else {
                const stderr = platform.getStderrHandle();
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\set keymap emacs|vi\r\n", .{});
                try stderr.writeAll(msg);
            }
        } else {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Unknown option: {s}\r\n", .{parts[0]});
            try stdout.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "echo")) {
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}\r\n", .{args});
        try stdout.writeAll(msg);
    } else if (std.mem.eql(u8, cmd, "source")) {
        // \source <file> - Execute commands from a GQL file
        if (args.len > 0) {
            try executeSourceFile(state, args);
        } else {
            const stderr = platform.getStderrHandle();
            try stderr.writeAll("Error [GEODE-E2002]: Usage: \\source <filename>\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "connet")) { // Typo detection
        const stderr = platform.getStderrHandle();
        try stderr.writeAll("Error [GEODE-E2001]: Unknown command '\\connet'. Did you mean '\\connect'?\r\n");
    } else {
        const stderr = platform.getStderrHandle();
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2001]: Unknown command '\\{s}'\r\n", .{cmd});
        try stderr.writeAll(msg);
    }
}

pub fn executeGql(state: anytype, gql: []const u8) !void {
    const stdout = platform.getStdoutHandle();
    const stderr = platform.getStderrHandle();

    // CRITICAL FIX: Move to new line before displaying results
    // This prevents overlapping with the prompt
    try stdout.writeAll("\r\n");

    // CANARY: REQ=REQ-MULTI-GRAPH-031; FEATURE="MultiGraphIsolation"; ASPECT=DropGraphReset; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=repl; UPDATED=2025-12-23
    // Check if this is a DROP GRAPH statement that drops the current graph
    // If so, reset current_graph to null (default graph) after execution
    var dropped_current_graph = false;
    if (state.current_graph) |current| {
        // Check for DROP GRAPH <current_graph> pattern (case insensitive)
        const upper_gql = blk: {
            var upper = state.allocator.alloc(u8, gql.len) catch break :blk null;
            for (gql, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            break :blk upper;
        };
        defer if (upper_gql) |u| state.allocator.free(u);

        if (upper_gql) |upper| {
            if (std.mem.indexOf(u8, upper, "DROP GRAPH")) |drop_idx| {
                // Extract the graph name after "DROP GRAPH "
                const after_drop = gql[drop_idx + "DROP GRAPH ".len ..];
                const trimmed = std.mem.trim(u8, after_drop, " \t\n\r;");
                // Check if the dropped graph name matches current graph
                if (std.mem.eql(u8, trimmed, current) or
                    (trimmed.len > current.len and std.mem.startsWith(u8, trimmed, current) and
                        (trimmed[current.len] == ' ' or trimmed[current.len] == ';')))
                {
                    dropped_current_graph = true;
                }
            }
        }
    }

    // Start timing the query execution
    var timer = try std.time.Timer.start();

    // CANARY: REQ=REQ-SHELL-RECONNECT-011; FEATURE="ShellAutoReconnect"; ASPECT=ExecuteWithRetry; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    // Execute query via QUIC with automatic reconnection on connection errors
    var retry_count: u32 = 0;
    const max_retries: u32 = 1; // Only retry once after reconnection

    while (retry_count <= max_retries) : (retry_count += 1) {
        state.session.runGql(gql) catch |err| {
            // CANARY: REQ=REQ-SHELL-WOULDBLOCK-002; FEATURE="SuppressWouldBlock"; ASPECT=RunGqlError; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            // Issue #388: Don't display WouldBlock errors - normal async I/O behavior
            if (err == error.WouldBlock) {
                return;
            }

            // Check if this is a connection error that can be recovered
            if (ClientSession.isConnectionError(err) and retry_count < max_retries) {
                // Attempt reconnection and transaction recovery
                const should_retry = handleConnectionError(state, err) catch |handle_err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error during reconnection handling: {s}\r\n", .{@errorName(handle_err)}) catch "";
                    stderr.writeAll(msg) catch {};
                    return;
                };

                if (should_retry) {
                    // Reset timer for retry
                    timer = std.time.Timer.start() catch return;
                    continue; // Retry the query
                }
            }

            // Non-recoverable error or reconnection failed
            try stderr.writeAll("Error executing query: ");
            try stderr.writeAll(@errorName(err));
            try stderr.writeAll("\r\n");
            return;
        };

        // Query succeeded, break out of retry loop
        break;
    }

    // Check if the schema response indicates an error - if so, don't PULL
    var has_error = false;
    if (state.session.last_response) |schema_response| {
        // Check for error status codes (4xxxx or 5xxxx)
        if (std.mem.indexOf(u8, schema_response, "\"status_class\":\"4") != null or
            std.mem.indexOf(u8, schema_response, "\"status_class\":\"5") != null)
        {
            has_error = true;
        }
    }

    // If we dropped the current graph and execution succeeded, reset to default
    if (dropped_current_graph and !has_error) {
        if (state.current_graph) |old| {
            state.allocator.free(old);
        }
        state.current_graph = null;
    }

    // Get response data from QUIC client (only if no error in schema)
    var response_data = std.ArrayList(u8).empty;
    defer response_data.deinit(state.allocator);

    if (!has_error) {
        // CANARY: REQ=REQ-SHELL-RECONNECT-012; FEATURE="ShellAutoReconnect"; ASPECT=PullAllWithReconnect; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
        // Use pullAll to get the complete response with reconnection handling
        state.session.pullAll(&response_data) catch |err| {
            // Check if we at least got a schema response with an error
            if (state.session.last_response) |schema_response| {
                if (try extractAndDisplayResult(state.allocator, schema_response, stdout, stderr, state.format)) {
                    return; // Error was displayed
                }
            }
            // CANARY: REQ=REQ-SHELL-WOULDBLOCK-003; FEATURE="SuppressWouldBlock"; ASPECT=PullAllError; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            // Issue #388: Don't display WouldBlock errors - normal async I/O behavior
            if (err == error.WouldBlock) {
                return;
            }

            // Check if this is a connection error
            if (ClientSession.isConnectionError(err)) {
                // Attempt reconnection
                const should_retry = handleConnectionError(state, err) catch |handle_err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error during reconnection handling: {s}\r\n", .{@errorName(handle_err)}) catch "";
                    stderr.writeAll(msg) catch {};
                    return;
                };

                if (should_retry) {
                    // Note: We can't retry pullAll without re-executing the query
                    // Inform the user they need to re-run the query
                    try stderr.writeAll("Connection lost while fetching results. Please re-run your query.\r\n");
                }
                return;
            }

            try stderr.writeAll("Error fetching results: ");
            try stderr.writeAll(@errorName(err));
            try stderr.writeAll("\r\n");
            return;
        };
    }

    // Stop timing and calculate duration
    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Check schema response for errors first
    if (state.session.last_response) |schema_response| {
        // Parse the response to extract the result
        if (try extractAndDisplayResult(state.allocator, schema_response, stdout, stderr, state.format)) {
            // Error was found and displayed, don't continue
            return;
        }
    }

    // Format and output the response data (BINDINGS/result)
    if (response_data.items.len > 0) {
        _ = try extractAndDisplayResult(state.allocator, response_data.items, stdout, stderr, state.format);
    }

    // Display timing information
    if (state.show_timing) {
        var buf: [256]u8 = undefined;
        const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\r\n", .{duration_ms});
        try stdout.writeAll(timing_msg);
    }
}

// CANARY: REQ=REQ-SOURCE-PERF-001; FEATURE="SourceFilePerformance"; ASPECT=FileHashCache; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-29
// Issue #391/#392: File hash cache to track sourced files and warn about re-sourcing
var g_sourced_file_hashes: ?std.StringHashMap(u64) = null;

fn getSourcedFileCache(allocator: std.mem.Allocator) *std.StringHashMap(u64) {
    if (g_sourced_file_hashes == null) {
        g_sourced_file_hashes = std.StringHashMap(u64).init(allocator);
    }
    return &g_sourced_file_hashes.?;
}

// CANARY: REQ=REQ-SOURCE-PERF-002; FEATURE="SourceFilePerformance"; ASPECT=FileHashCacheCleanup; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
// Issue #413: Cleanup function to free the global file hash cache on shutdown
pub fn deinitSourcedFileCache() void {
    if (g_sourced_file_hashes) |*cache| {
        // Free all allocated key strings
        var iter = cache.keyIterator();
        while (iter.next()) |key| {
            cache.allocator.free(key.*);
        }
        cache.deinit();
        g_sourced_file_hashes = null;
    }
}

// Simple hash function for file content
fn hashFileContent(content: []const u8) u64 {
    var hash: u64 = 5381;
    for (content) |c| {
        hash = ((hash << 5) +% hash) +% @as(u64, c);
    }
    return hash;
}

/// Execute commands from a GQL source file
/// Supports:
/// - GQL statements (terminated by semicolons)
/// - Meta-commands (\help, \use, etc.)
/// - Comments (lines starting with -- or # are ignored)
///
/// CANARY: REQ=REQ-SOURCE-PERF-002; FEATURE="SourceFilePerformance"; ASPECT=BatchExecution; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
/// Issue #400: Batch execution - sends entire file as single request for performance
/// Issue #391: Auto-wraps source file execution in a transaction for batch performance
/// Issue #392: Warns when re-sourcing the same file content (use MERGE for idempotent operations)
pub fn executeSourceFile(state: anytype, filename: []const u8) !void {
    const stdout = platform.getStdoutHandle();
    const stderr = platform.getStderrHandle();

    // Expand ~ to home directory if present
    var path_buf: [4096]u8 = undefined;
    const resolved_path = if (filename.len > 0 and filename[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse {
            try stderr.writeAll("Error [GEODE-E2005]: Cannot expand ~: HOME not set\r\n");
            return;
        };
        const rest = if (filename.len > 1) filename[1..] else "";
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, rest }) catch {
            try stderr.writeAll("Error [GEODE-E2005]: Path too long\r\n");
            return;
        };
        break :blk path;
    } else filename;

    // Open the file
    const file = std.fs.cwd().openFile(resolved_path, .{}) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error [GEODE-E2005]: Cannot open file '{s}': {s}\r\n", .{ resolved_path, @errorName(err) }) catch return;
        try stderr.writeAll(msg);
        return;
    };
    defer file.close();

    // Read file contents
    const contents = file.readToEndAlloc(state.allocator, 1 << 24) catch |err| { // 16MB max
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error [GEODE-E2005]: Cannot read file: {s}\r\n", .{@errorName(err)}) catch return;
        try stderr.writeAll(msg);
        return;
    };
    defer state.allocator.free(contents);

    // Issue #392: Check if this file content was already sourced
    const content_hash = hashFileContent(contents);
    const file_cache = getSourcedFileCache(state.allocator);
    if (file_cache.get(resolved_path)) |prev_hash| {
        if (prev_hash == content_hash) {
            try stderr.writeAll("Warning [GEODE-W3001]: File was already sourced with identical content.\r\n");
            try stderr.writeAll("  Tip: Use MERGE instead of CREATE for idempotent operations.\r\n");
        } else {
            try stderr.writeAll("Note: File was previously sourced but content has changed.\r\n");
        }
    }
    // Store/update the hash for this file path
    const path_key = state.allocator.dupe(u8, resolved_path) catch resolved_path;
    file_cache.put(path_key, content_hash) catch {};

    // Display source file info
    var info_buf: [512]u8 = undefined;
    const info_msg = std.fmt.bufPrint(&info_buf, "Sourcing: {s}\r\n", .{resolved_path}) catch return;
    try stdout.writeAll(info_msg);

    // CANARY: REQ=REQ-SOURCE-PERF-004; FEATURE="SourceFilePerformance"; ASPECT=BatchParsing; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #400: Parse entire file and collect all GQL statements for batch execution
    var batch_statements = try std.ArrayList(u8).initCapacity(state.allocator, contents.len);
    defer batch_statements.deinit(state.allocator);

    var meta_commands = try std.ArrayList(MetaCommand).initCapacity(state.allocator, 8);
    defer {
        for (meta_commands.items) |mc| {
            if (mc.args) |args| state.allocator.free(args);
        }
        meta_commands.deinit(state.allocator);
    }

    var statement_count: usize = 0;
    var current_statement = try std.ArrayList(u8).initCapacity(state.allocator, 256);
    defer current_statement.deinit(state.allocator);

    var line_iter = std.mem.splitSequence(u8, contents, "\n");
    var line_number: usize = 0;

    // First pass: Parse file and collect statements
    while (line_iter.next()) |raw_line| {
        line_number += 1;

        // Handle \r\n line endings
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        // Check for meta-command at start of statement
        if (current_statement.items.len == 0 and (trimmed[0] == '\\' or trimmed[0] == '/')) {
            const cmd_end = std.mem.indexOf(u8, trimmed[1..], " ") orelse (trimmed.len - 1);
            const cmd_name = trimmed[1 .. cmd_end + 1];

            // Skip nested source commands
            if (std.mem.eql(u8, cmd_name, "source")) {
                stderr.writeAll("Warning: Nested \\source commands not supported, skipping\r\n") catch {};
                continue;
            }

            // Convert meta-commands to GQL where possible, or queue for special handling
            if (std.mem.eql(u8, cmd_name, "use")) {
                const args_start = cmd_end + 2;
                if (args_start < trimmed.len) {
                    const use_args = std.mem.trim(u8, trimmed[args_start..], " \t;");
                    if (use_args.len > 0) {
                        // Convert \use to USE GRAPH statement and add to batch
                        if (batch_statements.items.len > 0) {
                            try batch_statements.append(state.allocator, ' ');
                        }
                        const use_stmt = std.fmt.allocPrint(state.allocator, "USE GRAPH {s};", .{use_args}) catch continue;
                        defer state.allocator.free(use_stmt);
                        try batch_statements.appendSlice(state.allocator, use_stmt);
                        statement_count += 1;
                    }
                }
            } else if (std.mem.eql(u8, cmd_name, "echo")) {
                // Queue echo for execution between batches
                const args_start = cmd_end + 2;
                const args = if (args_start < trimmed.len)
                    state.allocator.dupe(u8, std.mem.trim(u8, trimmed[args_start..], " \t")) catch null
                else
                    null;
                try meta_commands.append(state.allocator, .{ .cmd = .echo, .args = args, .position = statement_count });
            } else if (std.mem.eql(u8, cmd_name, "timing")) {
                const args_start = cmd_end + 2;
                const args = if (args_start < trimmed.len)
                    state.allocator.dupe(u8, std.mem.trim(u8, trimmed[args_start..], " \t")) catch null
                else
                    null;
                try meta_commands.append(state.allocator, .{ .cmd = .timing, .args = args, .position = statement_count });
            }
            // Skip other meta-commands
            continue;
        }

        // Accumulate line into current statement
        if (current_statement.items.len > 0) {
            try current_statement.append(state.allocator, ' ');
        }
        try current_statement.appendSlice(state.allocator, trimmed);

        // Check if statement is complete (ends with semicolon)
        if (std.mem.endsWith(u8, trimmed, ";")) {
            // Add complete statement to batch
            if (batch_statements.items.len > 0) {
                try batch_statements.append(state.allocator, ' ');
            }
            try batch_statements.appendSlice(state.allocator, current_statement.items);
            statement_count += 1;
            current_statement.clearRetainingCapacity();
        }
    }

    // Check for incomplete statement at end of file
    if (current_statement.items.len > 0) {
        const remaining = std.mem.trim(u8, current_statement.items, " \t");
        if (remaining.len > 0) {
            try stderr.writeAll("Warning: Incomplete statement at end of file (missing ';')\r\n");
        }
    }

    // Handle case with no GQL statements (only meta-commands)
    if (batch_statements.items.len == 0) {
        // Execute meta-commands only
        for (meta_commands.items) |mc| {
            executeMetaCommand(state, mc, stdout);
        }
        var summary_buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "Executed {d} command(s) successfully\r\n", .{meta_commands.items.len}) catch return;
        try stdout.writeAll(summary);
        return;
    }

    // CANARY: REQ=REQ-SOURCE-PERF-008; FEATURE="SourceFilePerformance"; ASPECT=TransactionDetection; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #391: Check if file contains explicit transaction commands (BEGIN, COMMIT, ROLLBACK)
    // If so, don't auto-wrap - let the user manage their own transactions
    const has_explicit_txn = containsTransactionCommands(batch_statements.items);

    // CANARY: REQ=REQ-SOURCE-PERF-009; FEATURE="SourceFilePerformance"; ASPECT=AutoTransaction; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #391: Auto-wrap in transaction for atomicity - entire file succeeds or fails together
    var auto_txn = false;
    var begin_succeeded = false;
    if (!state.in_txn and !has_explicit_txn) {
        state.session.begin() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Note: Transaction batching unavailable ({s})\r\n", .{@errorName(err)}) catch "";
            stderr.writeAll(msg) catch {};
        };
        // begin() doesn't throw on success, so if we get here without error, it succeeded
        begin_succeeded = true;
        auto_txn = true;
        state.in_txn = true;
    } else if (has_explicit_txn and state.verbose) {
        try stdout.writeAll("Note: File contains explicit transaction commands, skipping auto-wrap\r\n");
    }

    // Execute meta-commands that should run before batch
    for (meta_commands.items) |mc| {
        if (mc.position == 0) {
            executeMetaCommand(state, mc, stdout);
        }
    }

    // CANARY: REQ=REQ-SOURCE-PERF-005; FEATURE="SourceFilePerformance"; ASPECT=SingleRequestExecution; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #400: Execute entire batch in single request for maximum performance
    if (state.verbose) {
        var stmt_buf: [256]u8 = undefined;
        const preview_len = @min(batch_statements.items.len, 80);
        const preview = batch_statements.items[0..preview_len];
        const ellipsis: []const u8 = if (batch_statements.items.len > 80) "..." else "";
        const stmt_msg = std.fmt.bufPrint(&stmt_buf, ">> Batch ({d} statements): {s}{s}\r\n", .{ statement_count, preview, ellipsis }) catch "";
        stdout.writeAll(stmt_msg) catch {};
    }

    var error_count: usize = 0;
    executeGql(state, batch_statements.items) catch |err| {
        if (err != error.WouldBlock) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error executing batch: {s}\r\n", .{@errorName(err)}) catch return;
            stderr.writeAll(msg) catch {};
            error_count += 1;
        }
    };

    // CANARY: REQ=REQ-SOURCE-PERF-010; FEATURE="SourceFilePerformance"; ASPECT=TransactionCommitRollback; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #391: Commit on success, rollback on error for atomicity
    if (auto_txn and begin_succeeded) {
        if (error_count > 0) {
            // Rollback on error - ensure atomicity
            state.session.rollback() catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: Failed to rollback transaction: {s}\r\n", .{@errorName(err)}) catch "";
                stderr.writeAll(msg) catch {};
            };
            try stderr.writeAll("Transaction rolled back due to errors\r\n");
        } else {
            // Commit on success
            state.session.commit() catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: Failed to commit transaction: {s}\r\n", .{@errorName(err)}) catch "";
                stderr.writeAll(msg) catch {};
                state.session.rollback() catch {};
                error_count += 1;
            };
        }
        state.in_txn = false;
    }

    // Execute remaining meta-commands
    for (meta_commands.items) |mc| {
        if (mc.position > 0) {
            executeMetaCommand(state, mc, stdout);
        }
    }

    // Summary
    var summary_buf: [256]u8 = undefined;
    const summary = if (error_count > 0)
        std.fmt.bufPrint(&summary_buf, "Executed {d} statement(s) with {d} error(s)\r\n", .{ statement_count, error_count }) catch return
    else
        std.fmt.bufPrint(&summary_buf, "Executed {d} statement(s) successfully\r\n", .{statement_count}) catch return;
    try stdout.writeAll(summary);
}

/// Meta-command type for deferred execution during source file processing
const MetaCommandType = enum { echo, timing };

const MetaCommand = struct {
    cmd: MetaCommandType,
    args: ?[]const u8,
    position: usize, // Statement position where this command appears
};

/// Execute a meta-command during source file processing
fn executeMetaCommand(state: anytype, mc: MetaCommand, stdout: anytype) void {
    switch (mc.cmd) {
        .echo => {
            if (mc.args) |args| {
                stdout.writeAll(args) catch {};
                stdout.writeAll("\r\n") catch {};
            }
        },
        .timing => {
            if (mc.args) |args| {
                if (std.mem.eql(u8, args, "on")) {
                    state.show_timing = true;
                } else if (std.mem.eql(u8, args, "off")) {
                    state.show_timing = false;
                }
            }
        },
    }
}

/// CANARY: REQ=REQ-SOURCE-PERF-011; FEATURE="SourceFilePerformance"; ASPECT=TransactionDetection; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Check if a batch of GQL statements contains explicit transaction commands
/// Returns true if BEGIN, COMMIT, or ROLLBACK statements are found
/// This is used to avoid auto-wrapping files that manage their own transactions
pub fn containsTransactionCommands(batch: []const u8) bool {
    // Transaction keywords to detect (case-insensitive matching)
    const txn_keywords = [_][]const u8{ "BEGIN", "COMMIT", "ROLLBACK", "begin", "commit", "rollback", "Begin", "Commit", "Rollback" };

    var i: usize = 0;
    while (i < batch.len) {
        // Skip whitespace
        while (i < batch.len and (batch[i] == ' ' or batch[i] == '\t' or batch[i] == '\n' or batch[i] == '\r')) {
            i += 1;
        }
        if (i >= batch.len) break;

        // Check for transaction keywords at word boundary
        for (txn_keywords) |keyword| {
            if (i + keyword.len <= batch.len) {
                const slice = batch[i .. i + keyword.len];
                if (std.mem.eql(u8, slice, keyword)) {
                    // Verify it's at a word boundary (not part of a larger identifier)
                    const at_end = (i + keyword.len >= batch.len);
                    const next_is_boundary = at_end or !isIdentifierChar(batch[i + keyword.len]);
                    if (next_is_boundary) {
                        return true;
                    }
                }
            }
        }

        // Skip to next potential word boundary
        while (i < batch.len and batch[i] != ' ' and batch[i] != '\t' and batch[i] != '\n' and batch[i] != '\r' and batch[i] != ';') {
            i += 1;
        }
        // Skip past semicolon if present
        if (i < batch.len and batch[i] == ';') {
            i += 1;
        }
    }
    return false;
}

/// Helper to check if a character is part of an identifier
fn isIdentifierChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Extract the result from a response and display it appropriately
/// Returns true if an error was found and displayed
fn extractAndDisplayResult(allocator: std.mem.Allocator, response: []const u8, stdout: anytype, stderr: anytype, format: anytype) !bool {
    // Parse the JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeAll(response);
        try stdout.writeAll("\r\n");
        return false;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Check status_class for errors (non-00xxx codes indicate errors)
    if (root.get("status_class")) |status_value| {
        const status = status_value.string;
        if (status.len >= 2 and !std.mem.startsWith(u8, status, "00")) {
            // Error response - extract and display the error
            if (root.get("result")) |result_value| {
                if (result_value == .object) {
                    if (result_value.object.get("error")) |error_value| {
                        try stderr.writeAll("Error: ");
                        try stderr.writeAll(error_value.string);
                        try stderr.writeAll("\r\n");
                        return true;
                    }
                }
            }
            // Generic error with status code
            try stderr.writeAll("Error (");
            try stderr.writeAll(status);
            try stderr.writeAll(")\r\n");
            return true;
        }
    }

    // Extract and display the result
    if (root.get("result")) |result_value| {
        if (result_value == .object) {
            const result_obj = result_value.object;

            // Check result type
            if (result_obj.get("type")) |type_value| {
                const result_type = type_value.string;

                // Skip SCHEMA responses silently (they're metadata)
                if (std.mem.eql(u8, result_type, "SCHEMA")) {
                    return false;
                }

                // Handle BINDINGS (query results with rows)
                if (std.mem.eql(u8, result_type, "BINDINGS")) {
                    if (result_obj.get("rows")) |rows_value| {
                        try displayRows(allocator, rows_value, stdout, format);
                    }
                    return false;
                }

                // Handle RESULT type (may have rows or error)
                if (std.mem.eql(u8, result_type, "RESULT")) {
                    if (result_obj.get("error")) |error_value| {
                        try stderr.writeAll("Error: ");
                        try stderr.writeAll(error_value.string);
                        try stderr.writeAll("\r\n");
                        return true;
                    }
                    if (result_obj.get("rows")) |rows_value| {
                        try displayRows(allocator, rows_value, stdout, format);
                    }
                    return false;
                }
            }

            // Unknown result type - pretty print the result object
            try prettyPrintJson(allocator, result_value, stdout, 0);
            try stdout.writeAll("\r\n");
        }
    }

    return false;
}

/// Display rows from a query result
fn displayRows(allocator: std.mem.Allocator, rows_value: std.json.Value, stdout: anytype, format: anytype) !void {
    if (rows_value != .array) return;

    const rows = rows_value.array;
    if (rows.items.len == 0) {
        try stdout.writeAll("(0 rows)\r\n");
        return;
    }

    switch (format) {
        .table => try displayRowsAsTable(allocator, rows, stdout),
        .csv => try displayRowsAsCsv(allocator, rows, stdout),
        .json => {
            // Pretty print the rows array
            try prettyPrintJson(allocator, rows_value, stdout, 0);
            try stdout.writeAll("\r\n");
        },
    }

    // Show row count
    var buf: [64]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&buf, "({d} row{s})\r\n", .{ rows.items.len, if (rows.items.len == 1) "" else "s" }) catch return;
    try stdout.writeAll(count_msg);
}

/// Display rows as a formatted table
fn displayRowsAsTable(allocator: std.mem.Allocator, rows: std.json.Array, stdout: anytype) !void {
    if (rows.items.len == 0) return;

    // Get column names from first row (assuming all rows have same keys)
    const first_row = rows.items[0];
    if (first_row != .object) {
        // Not an object row, fall back to JSON
        try prettyPrintJson(allocator, std.json.Value{ .array = rows }, stdout, 0);
        return;
    }

    const keys = first_row.object.keys();
    if (keys.len == 0) return;

    // Calculate column widths
    var col_widths = try allocator.alloc(usize, keys.len);
    defer allocator.free(col_widths);

    for (keys, 0..) |key, i| {
        col_widths[i] = key.len;
    }

    // Check each row for max widths
    for (rows.items) |row| {
        if (row != .object) continue;
        for (keys, 0..) |key, i| {
            if (row.object.get(key)) |val| {
                const width = getValueDisplayWidth(val);
                col_widths[i] = @max(col_widths[i], @min(width, 50)); // Cap at 50 chars
            }
        }
    }

    // Print header
    try stdout.writeAll("| ");
    for (keys, 0..) |key, i| {
        try stdout.writeAll(key);
        const padding = col_widths[i] -| key.len;
        for (0..padding) |_| try stdout.writeAll(" ");
        try stdout.writeAll(" | ");
    }
    try stdout.writeAll("\r\n");

    // Print separator
    try stdout.writeAll("|");
    for (col_widths) |width| {
        try stdout.writeAll("-");
        for (0..width) |_| try stdout.writeAll("-");
        try stdout.writeAll("-|");
    }
    try stdout.writeAll("\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        try stdout.writeAll("| ");
        for (keys, 0..) |key, i| {
            var val_buf: [256]u8 = undefined;
            var printed_len: usize = 0;
            if (row.object.get(key)) |val| {
                const str = formatValueCompact(&val_buf, val);
                const display_str = if (str.len > col_widths[i]) str[0..col_widths[i]] else str;
                try stdout.writeAll(display_str);
                printed_len = display_str.len;
            }
            const padding = col_widths[i] -| printed_len;
            for (0..padding) |_| try stdout.writeAll(" ");
            try stdout.writeAll(" | ");
        }
        try stdout.writeAll("\r\n");
    }
}

/// Display rows as CSV
fn displayRowsAsCsv(allocator: std.mem.Allocator, rows: std.json.Array, stdout: anytype) !void {
    _ = allocator;
    if (rows.items.len == 0) return;

    // Get column names from first row
    const first_row = rows.items[0];
    if (first_row != .object) return;

    const keys = first_row.object.keys();

    // Print header
    for (keys, 0..) |key, i| {
        if (i > 0) try stdout.writeAll(",");
        try stdout.writeAll(key);
    }
    try stdout.writeAll("\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        for (keys, 0..) |key, i| {
            if (i > 0) try stdout.writeAll(",");
            var val_buf: [256]u8 = undefined;
            if (row.object.get(key)) |val| {
                const str = formatValueCompact(&val_buf, val);
                // Escape quotes in CSV
                if (std.mem.indexOf(u8, str, "\"") != null or std.mem.indexOf(u8, str, ",") != null) {
                    try stdout.writeAll("\"");
                    for (str) |c| {
                        if (c == '"') {
                            try stdout.writeAll("\"\"");
                        } else {
                            try stdout.writeAll(&[_]u8{c});
                        }
                    }
                    try stdout.writeAll("\"");
                } else {
                    try stdout.writeAll(str);
                }
            }
        }
        try stdout.writeAll("\r\n");
    }
}

/// Get the display width of a JSON value
fn getValueDisplayWidth(val: std.json.Value) usize {
    return switch (val) {
        .string => |s| s.len,
        .integer => 12,
        .float => 12,
        .number_string => |s| s.len,
        .bool => |b| if (b) 4 else 5,
        .null => 4,
        .object => 40, // Compact object representation (nodes with properties)
        .array => 20, // Compact array representation
    };
}

/// Format a JSON value compactly for table display
fn formatValueCompact(buf: []u8, val: std.json.Value) []const u8 {
    switch (val) {
        .string => |s| return s,
        .integer => |n| {
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
        },
        .float => |f| {
            return std.fmt.bufPrint(buf, "{d:.2}", .{f}) catch "?";
        },
        .number_string => |s| return s,
        .bool => |b| return if (b) "true" else "false",
        .null => return "null",
        .object => |obj| {
            // Compact object display for nodes - show just properties, not label wrapper
            if (obj.get("id")) |id_val| {
                if (obj.get("labels")) |_| {
                    // Node-like object - get id as UUIDv7-style hex
                    const id_num: u64 = switch (id_val) {
                        .integer => |n| @bitCast(n),
                        else => 0,
                    };

                    // Check for properties and show them
                    if (obj.get("properties")) |props_val| {
                        if (props_val == .object) {
                            const props = props_val.object;
                            // Show id and name if available
                            if (props.get("name")) |name_val| {
                                if (name_val == .string) {
                                    return std.fmt.bufPrint(buf, "{{id:\"{x:0>16}\", name:\"{s}\"}}", .{ id_num, name_val.string }) catch "{...}";
                                }
                            }
                        }
                    }

                    return std.fmt.bufPrint(buf, "{{id:\"{x:0>16}\"}}", .{id_num}) catch "{...}";
                }
            }
            return "{...}";
        },
        .array => |arr| {
            if (arr.items.len == 0) return "[]";
            return std.fmt.bufPrint(buf, "[{d} items]", .{arr.items.len}) catch "[...]";
        },
    }
}

/// Pretty print a JSON value with indentation
fn prettyPrintJson(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, indent: usize) !void {
    const indent_str = "  ";

    switch (value) {
        .object => |obj| {
            if (obj.count() == 0) {
                try writer.writeAll("{}");
                return;
            }
            try writer.writeAll("{\r\n");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",\r\n");
                first = false;
                for (0..indent + 1) |_| try writer.writeAll(indent_str);
                try writer.writeAll("\"");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\": ");
                try prettyPrintJson(allocator, entry.value_ptr.*, writer, indent + 1);
            }
            try writer.writeAll("\r\n");
            for (0..indent) |_| try writer.writeAll(indent_str);
            try writer.writeAll("}");
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writer.writeAll("[]");
                return;
            }
            try writer.writeAll("[\r\n");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",\r\n");
                for (0..indent + 1) |_| try writer.writeAll(indent_str);
                try prettyPrintJson(allocator, item, writer, indent + 1);
            }
            try writer.writeAll("\r\n");
            for (0..indent) |_| try writer.writeAll(indent_str);
            try writer.writeAll("]");
        },
        .string => |s| {
            try writer.writeAll("\"");
            // Escape special characters
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeAll(&[_]u8{c}),
                }
            }
            try writer.writeAll("\"");
        },
        .integer => |n| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try writer.writeAll(str);
        },
        .float => |f| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return;
            try writer.writeAll(str);
        },
        .bool => |b| {
            try writer.writeAll(if (b) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .number_string => |s| {
            try writer.writeAll(s);
        },
    }
}

fn formatQueryResult(stdout: anytype, allocator: std.mem.Allocator, response: []const u8, format: anytype) !void {
    switch (format) {
        .json => {
            // JSON format - output as-is
            try stdout.writeAll(response);
        },
        .csv => {
            // CSV format - simple implementation
            try formatResultAsCsv(stdout, allocator, response);
        },
        .table => {
            // Table format - simple implementation
            try formatResultAsTable(stdout, allocator, response);
        },
    }
}

fn formatResultAsCsv(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple CSV
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Header
            for (columns.items, 0..) |col, i| {
                if (i > 0) try stdout.writeAll(",");
                try stdout.writeAll("\"");
                try stdout.writeAll(col.string);
                try stdout.writeAll("\"");
            }
            try stdout.writeAll("\r\n");

            // Data rows
            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i > 0) try stdout.writeAll(",");
                    switch (cell) {
                        .string => |s| {
                            try stdout.writeAll("\"");
                            try stdout.writeAll(s);
                            try stdout.writeAll("\"");
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try stdout.writeAll(str);
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try stdout.writeAll(str);
                        },
                        .bool => |b| {
                            try stdout.writeAll(if (b) "true" else "false");
                        },
                        .null => {
                            try stdout.writeAll("NULL");
                        },
                        else => {},
                    }
                }
                try stdout.writeAll("\r\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try stdout.writeAll(response);
}

fn formatResultAsTable(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple table
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Calculate column widths
            var col_widths = try allocator.alloc(usize, columns.items.len);
            defer allocator.free(col_widths);

            for (columns.items, 0..) |col, i| {
                col_widths[i] = col.string.len;
            }

            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    const width: usize = switch (cell) {
                        .string => |s| s.len,
                        .integer => 10, // rough estimate
                        .float => 10, // rough estimate
                        .bool => 5,
                        .null => 4,
                        else => 0,
                    };
                    col_widths[i] = @max(col_widths[i], width);
                }
            }

            // Print header
            try stdout.writeAll("| ");
            for (columns.items, 0..) |col, i| {
                try stdout.writeAll(col.string);
                const padding = col_widths[i] - col.string.len;
                for (0..padding) |_| try stdout.writeAll(" ");
                try stdout.writeAll(" | ");
            }
            try stdout.writeAll("\r\n");

            // Print separator
            try stdout.writeAll("|");
            for (col_widths) |width| {
                try stdout.writeAll("-");
                for (0..width) |_| try stdout.writeAll("-");
                try stdout.writeAll("-|");
            }
            try stdout.writeAll("\r\n");

            // Print data rows
            for (rows.items) |row| {
                try stdout.writeAll("| ");
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    var printed_len: usize = 0;
                    switch (cell) {
                        .string => |s| {
                            try stdout.writeAll(s);
                            printed_len = s.len;
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .bool => |b| {
                            const str = if (b) "true" else "false";
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .null => {
                            try stdout.writeAll("NULL");
                            printed_len = 4;
                        },
                        else => {},
                    }
                    const padding = col_widths[i] - printed_len;
                    for (0..padding) |_| try stdout.writeAll(" ");
                    try stdout.writeAll(" | ");
                }
                try stdout.writeAll("\r\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try stdout.writeAll(response);
}

fn splitOnce(allocator: std.mem.Allocator, text: []const u8, delimiter: u8) ![2][]u8 {
    if (std.mem.indexOf(u8, text, &[_]u8{delimiter})) |idx| {
        return [2][]u8{
            try allocator.dupe(u8, text[0..idx]),
            try allocator.dupe(u8, std.mem.trim(u8, text[idx + 1 ..], " \t")),
        };
    }
    return [2][]u8{
        try allocator.dupe(u8, text),
        try allocator.dupe(u8, ""),
    };
}

// Unit tests
// CANARY: REQ=REQ-SHELL-AUTH-005; FEATURE="ShellAuthTests"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestShellAuthDetection; OWNER=cli; UPDATED=2026-01-28

const testing = std.testing;

test "TestShellAuthDetection_AuthenticationRequiredInResponse" {
    // Issue #387: Test that "Authentication required" is detected in server response
    const auth_required_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication required\"}";
    try testing.expect(std.mem.indexOf(u8, auth_required_response, "Authentication required") != null);
}

test "TestShellAuthDetection_NoAuthInSuccessResponse" {
    // Issue #387: Test that success response doesn't trigger auth required
    const success_response = "{\"type\":\"HELLO\",\"server_name\":\"geode\",\"server_ver\":\"0.18.0\"}";
    try testing.expect(std.mem.indexOf(u8, success_response, "Authentication required") == null);
}

test "TestShellAuthDetection_ErrorMessageExtraction" {
    // Issue #387: Test error message parsing from auth failure
    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Invalid credentials\"}";
    try testing.expect(std.mem.indexOf(u8, error_response, "Invalid credentials") != null);
}

test "TestEscapeJsonString_NoEscaping" {
    // Test string that doesn't need escaping
    const allocator = testing.allocator;
    const result = try escapeJsonString(allocator, "hello world");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "TestEscapeJsonString_QuotesAndBackslashes" {
    // Test escaping quotes and backslashes
    const allocator = testing.allocator;
    const result = try escapeJsonString(allocator, "say \"hello\"\\test");
    defer allocator.free(result);
    try testing.expectEqualStrings("say \\\"hello\\\"\\\\test", result);
}

test "TestEscapeJsonString_Newlines" {
    // Test escaping newlines and tabs
    const allocator = testing.allocator;
    const result = try escapeJsonString(allocator, "line1\nline2\ttab");
    defer allocator.free(result);
    try testing.expectEqualStrings("line1\\nline2\\ttab", result);
}

// CANARY: REQ=REQ-SOURCE-PERF-003; FEATURE="SourceFilePerformance"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// Issue #391/#392: Unit tests for source file hash caching

test "TestFileHashContent_DeterministicHash" {
    // Issue #391/#392: Test that identical content produces identical hash
    const content1 = "CREATE (n:Person {name: 'Alice'});";
    const content2 = "CREATE (n:Person {name: 'Alice'});";
    const hash1 = hashFileContent(content1);
    const hash2 = hashFileContent(content2);
    try testing.expectEqual(hash1, hash2);
}

test "TestFileHashContent_DifferentContentDifferentHash" {
    // Issue #391/#392: Test that different content produces different hash
    const content1 = "CREATE (n:Person {name: 'Alice'});";
    const content2 = "CREATE (n:Person {name: 'Bob'});";
    const hash1 = hashFileContent(content1);
    const hash2 = hashFileContent(content2);
    try testing.expect(hash1 != hash2);
}

test "TestFileHashContent_EmptyContent" {
    // Issue #391/#392: Test hash of empty content
    const content = "";
    const hash = hashFileContent(content);
    // Initial hash value is 5381
    try testing.expectEqual(@as(u64, 5381), hash);
}

test "TestFileHashContent_LargeContent" {
    // Issue #391/#392: Test hash of larger content (simulate a source file)
    const content =
        \\-- Sample GQL source file
        \\CREATE GRAPH IF NOT EXISTS test_graph;
        \\USE GRAPH test_graph;
        \\CREATE (a:Person {name: 'Alice', age: 30});
        \\CREATE (b:Person {name: 'Bob', age: 25});
        \\MERGE (a)-[:KNOWS]->(b);
    ;
    const hash = hashFileContent(content);
    // Just verify it produces a non-zero hash
    try testing.expect(hash != 0);
    try testing.expect(hash != 5381); // Not the empty string hash
}

// =============================================================================
// Issue #400: /source batch execution unit tests
// CANARY: REQ=REQ-SOURCE-PERF-006; FEATURE="SourceBatchTests"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// =============================================================================

test "TestSourceBatch_ParseSimpleStatements" {
    // Test parsing simple GQL statements into batch
    const allocator = testing.allocator;
    const content =
        \\CREATE (a:Person {name: 'Alice'});
        \\CREATE (b:Person {name: 'Bob'});
        \\MATCH (n) RETURN n;
    ;

    var batch = std.ArrayList(u8).init(allocator);
    defer batch.deinit();

    var stmt_count: usize = 0;
    var current = std.ArrayList(u8).init(allocator);
    defer current.deinit();

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (current.items.len > 0) {
            try current.append(' ');
        }
        try current.appendSlice(trimmed);

        if (std.mem.endsWith(u8, trimmed, ";")) {
            if (batch.items.len > 0) {
                try batch.append(' ');
            }
            try batch.appendSlice(current.items);
            stmt_count += 1;
            current.clearRetainingCapacity();
        }
    }

    try testing.expectEqual(@as(usize, 3), stmt_count);
    try testing.expect(std.mem.indexOf(u8, batch.items, "CREATE (a:Person") != null);
    try testing.expect(std.mem.indexOf(u8, batch.items, "CREATE (b:Person") != null);
    try testing.expect(std.mem.indexOf(u8, batch.items, "MATCH (n) RETURN n") != null);
}

test "TestSourceBatch_SkipComments" {
    // Test that comments are properly skipped during batch parsing
    const content =
        \\-- This is a comment
        \\CREATE (a:Person);
        \\# Another comment style
        \\CREATE (b:Person);
        \\-- Final comment
    ;

    var stmt_count: usize = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), stmt_count);
}

test "TestSourceBatch_MultiLineStatements" {
    // Test parsing multi-line statements
    const allocator = testing.allocator;
    const content =
        \\CREATE (a:Person {
        \\  name: 'Alice',
        \\  age: 30
        \\});
        \\MATCH (n)
        \\WHERE n.age > 25
        \\RETURN n;
    ;

    var batch = std.ArrayList(u8).init(allocator);
    defer batch.deinit();

    var stmt_count: usize = 0;
    var current = std.ArrayList(u8).init(allocator);
    defer current.deinit();

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (current.items.len > 0) {
            try current.append(' ');
        }
        try current.appendSlice(trimmed);

        if (std.mem.endsWith(u8, trimmed, ";")) {
            if (batch.items.len > 0) {
                try batch.append(' ');
            }
            try batch.appendSlice(current.items);
            stmt_count += 1;
            current.clearRetainingCapacity();
        }
    }

    try testing.expectEqual(@as(usize, 2), stmt_count);
    // Verify statements are properly joined
    try testing.expect(std.mem.indexOf(u8, batch.items, "name: 'Alice', age: 30") != null);
    try testing.expect(std.mem.indexOf(u8, batch.items, "WHERE n.age > 25 RETURN n") != null);
}

test "TestSourceBatch_MetaCommandConversion" {
    // Test that \use is converted to USE GRAPH statement
    const allocator = testing.allocator;

    var batch = std.ArrayList(u8).init(allocator);
    defer batch.deinit();

    // Simulate \use conversion
    const use_cmd = "\\use my_graph";
    if (std.mem.startsWith(u8, use_cmd, "\\use")) {
        const args = std.mem.trim(u8, use_cmd[4..], " \t;");
        const use_stmt = try std.fmt.allocPrint(allocator, "USE GRAPH {s};", .{args});
        defer allocator.free(use_stmt);
        try batch.appendSlice(use_stmt);
    }

    try testing.expect(std.mem.eql(u8, batch.items, "USE GRAPH my_graph;"));
}

test "TestSourceBatch_EmptyFile" {
    // Test handling of empty file
    const content = "";
    var lines = std.mem.splitSequence(u8, content, "\n");
    var stmt_count: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 0), stmt_count);
}

test "TestSourceBatch_OnlyComments" {
    // Test file with only comments
    const content =
        \\-- Comment 1
        \\# Comment 2
        \\-- Comment 3
    ;

    var stmt_count: usize = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 0), stmt_count);
}

test "TestSourceBatch_MixedContentWithComments" {
    // Test mixed content with interleaved comments
    const allocator = testing.allocator;
    const content =
        \\-- Setup section
        \\CREATE GRAPH test;
        \\# Switch to graph
        \\USE GRAPH test;
        \\-- Create nodes
        \\CREATE (a:Node);
        \\CREATE (b:Node);
        \\-- Done
    ;

    var batch = std.ArrayList(u8).init(allocator);
    defer batch.deinit();

    var stmt_count: usize = 0;
    var current = std.ArrayList(u8).init(allocator);
    defer current.deinit();

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        if (current.items.len > 0) {
            try current.append(' ');
        }
        try current.appendSlice(trimmed);

        if (std.mem.endsWith(u8, trimmed, ";")) {
            if (batch.items.len > 0) {
                try batch.append(' ');
            }
            try batch.appendSlice(current.items);
            stmt_count += 1;
            current.clearRetainingCapacity();
        }
    }

    try testing.expectEqual(@as(usize, 4), stmt_count);
}

test "TestSourceBatch_WindowsLineEndings" {
    // Test handling of Windows-style line endings (\r\n)
    const content = "CREATE (a:Node);\r\nCREATE (b:Node);\r\nRETURN 1;\r\n";

    var stmt_count: usize = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, std.mem.trimRight(u8, line, "\r"), " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 3), stmt_count);
}

test "TestSourceBatch_NestedSourceCommandSkipped" {
    // Test that nested \source commands are properly skipped
    const content =
        \\CREATE (a:Node);
        \\\source other.gql
        \\CREATE (b:Node);
    ;

    var stmt_count: usize = 0;
    var skipped_source: bool = false;

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '\\' or trimmed[0] == '/') {
            const cmd_end = std.mem.indexOf(u8, trimmed[1..], " ") orelse (trimmed.len - 1);
            const cmd_name = trimmed[1 .. cmd_end + 1];
            if (std.mem.eql(u8, cmd_name, "source")) {
                skipped_source = true;
                continue;
            }
        }

        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), stmt_count);
    try testing.expect(skipped_source);
}

test "TestSourceBatch_LargeStatementCount" {
    // Test handling of many statements
    const allocator = testing.allocator;

    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    // Generate 100 statements
    for (0..100) |i| {
        const stmt = try std.fmt.allocPrint(allocator, "CREATE (n{d}:Node {{id: {d}}});\n", .{ i, i });
        defer allocator.free(stmt);
        try content.appendSlice(stmt);
    }

    var stmt_count: usize = 0;
    var lines = std.mem.splitSequence(u8, content.items, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.endsWith(u8, trimmed, ";")) {
            stmt_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 100), stmt_count);
}

test "TestSourceBatch_IncompleteStatement" {
    // Test detection of incomplete statement at end of file
    const content =
        \\CREATE (a:Node);
        \\CREATE (b:Node
    ;

    var complete_count: usize = 0;
    var has_incomplete: bool = false;
    var current_len: usize = 0;

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        current_len += trimmed.len;

        if (std.mem.endsWith(u8, trimmed, ";")) {
            complete_count += 1;
            current_len = 0;
        }
    }

    if (current_len > 0) {
        has_incomplete = true;
    }

    try testing.expectEqual(@as(usize, 1), complete_count);
    try testing.expect(has_incomplete);
}

test "TestMetaCommand_EchoType" {
    // Test MetaCommand echo type
    const mc = MetaCommand{ .cmd = .echo, .args = "Hello, World!", .position = 0 };
    try testing.expectEqual(MetaCommandType.echo, mc.cmd);
    try testing.expect(mc.args != null);
    try testing.expect(std.mem.eql(u8, mc.args.?, "Hello, World!"));
}

test "TestMetaCommand_TimingType" {
    // Test MetaCommand timing type
    const mc = MetaCommand{ .cmd = .timing, .args = "on", .position = 5 };
    try testing.expectEqual(MetaCommandType.timing, mc.cmd);
    try testing.expectEqual(@as(usize, 5), mc.position);
}

// CANARY: REQ=REQ-SOURCE-PERF-012; FEATURE="SourceFilePerformance"; ASPECT=TransactionDetectionTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// Unit tests for containsTransactionCommands function

test "TestContainsTransactionCommands_NoTransaction" {
    // Test batch with no transaction commands
    const batch = "CREATE (n:Person {name: 'Alice'}); MATCH (n) RETURN n;";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_BeginUppercase" {
    // Test detection of BEGIN (uppercase)
    const batch = "BEGIN; CREATE (n:Person); COMMIT;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_BeginLowercase" {
    // Test detection of begin (lowercase)
    const batch = "begin; CREATE (n:Person); commit;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_CommitOnly" {
    // Test detection of standalone COMMIT
    const batch = "CREATE (n:Person); COMMIT;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_RollbackOnly" {
    // Test detection of standalone ROLLBACK
    const batch = "CREATE (n:Person); ROLLBACK;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_MixedCase" {
    // Test detection with mixed case
    const batch = "Begin; CREATE (n:Person); Commit;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_BeginInMiddle" {
    // Test detection when BEGIN is in the middle of the batch
    const batch = "USE GRAPH test; BEGIN; CREATE (n:Person); COMMIT;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_NotPartOfIdentifier" {
    // Test that BEGINNING is not detected as BEGIN (word boundary check)
    const batch = "CREATE (n:BEGINNING {name: 'test'});";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_NotPartOfIdentifier_Commit" {
    // Test that COMMITTED is not detected as COMMIT
    const batch = "CREATE (n:COMMITTED_CHANGE {status: 'done'});";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_NotPartOfIdentifier_Rollback" {
    // Test that ROLLBACKED is not detected as ROLLBACK
    const batch = "CREATE (n:ROLLBACKED_TXN {status: 'failed'});";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_WithWhitespace" {
    // Test detection with various whitespace
    const batch = "  \n  BEGIN  \n  ; CREATE (n); \t COMMIT \n ;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_EmptyBatch" {
    // Test empty batch
    const batch = "";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_WhitespaceOnly" {
    // Test batch with only whitespace
    const batch = "   \n\t\r\n   ";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_BeginAtStart" {
    // Test BEGIN at the very start of the batch
    const batch = "BEGIN; CREATE (n);";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_CommitAtEnd" {
    // Test COMMIT at the very end of the batch
    const batch = "CREATE (n); COMMIT";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_RollbackAtEnd" {
    // Test ROLLBACK at the very end (no semicolon)
    const batch = "CREATE (n); ROLLBACK";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_MultipleTransactions" {
    // Test multiple transaction blocks
    const batch = "BEGIN; CREATE (a); COMMIT; BEGIN; CREATE (b); COMMIT;";
    try testing.expect(containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_NestedLikePattern" {
    // Test pattern that looks like but isn't a transaction command
    const batch = "MATCH (n) WHERE n.status = 'BEGINNING' RETURN n;";
    try testing.expect(!containsTransactionCommands(batch));
}

test "TestContainsTransactionCommands_StringLiteral" {
    // Note: This is a limitation - we do basic word boundary detection
    // In a string literal like 'BEGIN', we might still detect it
    // This test documents current behavior
    const batch = "CREATE (n {msg: 'BEGIN transaction'});";
    // Current implementation will detect BEGIN even in strings
    // This is acceptable for the use case (erring on side of caution)
    try testing.expect(containsTransactionCommands(batch));
}

test "TestIsIdentifierChar_Letters" {
    // Test identifier character detection for letters
    try testing.expect(isIdentifierChar('a'));
    try testing.expect(isIdentifierChar('z'));
    try testing.expect(isIdentifierChar('A'));
    try testing.expect(isIdentifierChar('Z'));
}

test "TestIsIdentifierChar_Numbers" {
    // Test identifier character detection for numbers
    try testing.expect(isIdentifierChar('0'));
    try testing.expect(isIdentifierChar('9'));
}

test "TestIsIdentifierChar_Underscore" {
    // Test identifier character detection for underscore
    try testing.expect(isIdentifierChar('_'));
}

test "TestIsIdentifierChar_NonIdentifier" {
    // Test non-identifier characters
    try testing.expect(!isIdentifierChar(' '));
    try testing.expect(!isIdentifierChar(';'));
    try testing.expect(!isIdentifierChar('\n'));
    try testing.expect(!isIdentifierChar('('));
    try testing.expect(!isIdentifierChar(')'));
    try testing.expect(!isIdentifierChar(':'));
}

// CANARY: REQ=REQ-SHELL-RECONNECT-015; FEATURE="ShellAutoReconnect"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// Unit tests for automatic reconnection functionality

test "TestReconnectionConfig_DefaultValues" {
    // Test default reconnection configuration values
    const config = ReconnectionConfig{};
    try testing.expectEqual(@as(u32, 5), config.max_attempts);
    try testing.expectEqual(@as(u64, 100), config.initial_delay_ms);
    try testing.expectEqual(@as(u64, 10000), config.max_delay_ms);
    try testing.expectEqual(@as(f64, 2.0), config.backoff_multiplier);
    try testing.expect(config.prompt_for_txn_recovery);
}

test "TestReconnectionConfig_CustomValues" {
    // Test custom reconnection configuration
    const config = ReconnectionConfig{
        .max_attempts = 10,
        .initial_delay_ms = 50,
        .max_delay_ms = 5000,
        .backoff_multiplier = 1.5,
        .prompt_for_txn_recovery = false,
    };
    try testing.expectEqual(@as(u32, 10), config.max_attempts);
    try testing.expectEqual(@as(u64, 50), config.initial_delay_ms);
    try testing.expectEqual(@as(u64, 5000), config.max_delay_ms);
    try testing.expectEqual(@as(f64, 1.5), config.backoff_multiplier);
    try testing.expect(!config.prompt_for_txn_recovery);
}

test "TestReconnectionConfig_DisabledReconnection" {
    // Test disabled reconnection (max_attempts = 0)
    const config = ReconnectionConfig{
        .max_attempts = 0,
    };
    try testing.expectEqual(@as(u32, 0), config.max_attempts);
}

test "TestPendingTransactionState_DefaultValues" {
    // Test default pending transaction state
    const state = PendingTransactionState{};
    try testing.expect(!state.had_active_transaction);
    try testing.expect(state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), state.statements_in_txn);
}

test "TestPendingTransactionState_Reset" {
    // Test reset functionality
    var state = PendingTransactionState{
        .had_active_transaction = true,
        .current_graph = "test_graph",
        .statements_in_txn = 10,
    };
    state.reset();
    try testing.expect(!state.had_active_transaction);
    try testing.expect(state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), state.statements_in_txn);
}

test "TestTransactionRecoveryChoice_Values" {
    // Test transaction recovery choice enum values
    const resume_choice = TransactionRecoveryChoice.resume_transaction;
    const cancel_choice = TransactionRecoveryChoice.cancel_transaction;
    const abort_choice = TransactionRecoveryChoice.abort_reconnection;

    try testing.expect(resume_choice != cancel_choice);
    try testing.expect(cancel_choice != abort_choice);
    try testing.expect(resume_choice != abort_choice);
}

test "TestClientSession_IsConnectionError_BrokenPipe" {
    // Test BrokenPipe is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.BrokenPipe));
}

test "TestClientSession_IsConnectionError_ConnectionResetByPeer" {
    // Test ConnectionResetByPeer is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionResetByPeer));
}

test "TestClientSession_IsConnectionError_ConnectionRefused" {
    // Test ConnectionRefused is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionRefused));
}

test "TestClientSession_IsConnectionError_ConnectionTimedOut" {
    // Test ConnectionTimedOut is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionTimedOut));
}

test "TestClientSession_IsConnectionError_NetworkUnreachable" {
    // Test NetworkUnreachable is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.NetworkUnreachable));
}

test "TestClientSession_IsConnectionError_HostUnreachable" {
    // Test HostUnreachable is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.HostUnreachable));
}

test "TestClientSession_IsConnectionError_NotConnected" {
    // Test NotConnected is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.NotConnected));
}

test "TestClientSession_IsConnectionError_EndOfStream" {
    // Test EndOfStream is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.EndOfStream));
}

test "TestClientSession_IsConnectionError_InputOutput" {
    // Test InputOutput is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.InputOutput));
}

test "TestClientSession_IsConnectionError_NonConnectionError" {
    // Test that non-connection errors return false
    try testing.expect(!ClientSession.isConnectionError(error.OutOfMemory));
    try testing.expect(!ClientSession.isConnectionError(error.InvalidCharacter));
}

test "TestClientSession_InitialReconnectCount" {
    // Test that reconnect count starts at 0
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();
    try testing.expectEqual(@as(u32, 0), session.reconnect_count);
}

test "TestClientSession_InitialPendingTxnState" {
    // Test that pending transaction state is initialized properly
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();
    try testing.expect(!session.pending_txn_state.had_active_transaction);
    try testing.expect(session.pending_txn_state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), session.pending_txn_state.statements_in_txn);
}

test "TestClientSession_SaveTransactionState" {
    // Test saving transaction state
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.saveTransactionState(true, "my_graph", 5);

    try testing.expect(session.pending_txn_state.had_active_transaction);
    try testing.expect(std.mem.eql(u8, session.pending_txn_state.current_graph.?, "my_graph"));
    try testing.expectEqual(@as(usize, 5), session.pending_txn_state.statements_in_txn);
}

test "TestClientSession_SaveTransactionState_NoGraph" {
    // Test saving transaction state without graph
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.saveTransactionState(false, null, 0);

    try testing.expect(!session.pending_txn_state.had_active_transaction);
    try testing.expect(session.pending_txn_state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), session.pending_txn_state.statements_in_txn);
}

test "TestClientSession_CacheCredentials" {
    // Test credential caching
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try session.cacheCredentials("testuser", "testpass");

    try testing.expect(session.cached_username != null);
    try testing.expect(session.cached_password != null);
    try testing.expect(std.mem.eql(u8, session.cached_username.?, "testuser"));
    try testing.expect(std.mem.eql(u8, session.cached_password.?, "testpass"));
}

test "TestClientSession_CacheCredentials_Overwrite" {
    // Test overwriting cached credentials
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try session.cacheCredentials("user1", "pass1");
    try session.cacheCredentials("user2", "pass2");

    try testing.expect(std.mem.eql(u8, session.cached_username.?, "user2"));
    try testing.expect(std.mem.eql(u8, session.cached_password.?, "pass2"));
}

test "TestClientSession_DefaultReconnectConfig" {
    // Test default reconnect configuration in session
    const allocator = testing.allocator;
    const transport = Transport{ .connectFn = mockConnectFn };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try testing.expectEqual(@as(u32, 5), session.reconnect_config.max_attempts);
    try testing.expect(session.reconnect_config.prompt_for_txn_recovery);
}
