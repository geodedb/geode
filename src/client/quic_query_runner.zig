const std = @import("std");
const schema = @import("schema");
const query_results = @import("query_result_accumulator.zig");

pub const default_page_size: u32 = 128;

pub const QueryEvent = union(enum) {
    execute: schema.ExecutionResponse,
    hello_failure: []const u8,
};

pub const QueryEventSummary = struct {
    schema_received: bool = false,
    saw_page: bool = false,
    page_final: bool = false,
    stop: bool = false,
};

pub const QueryEventConsumer = struct {
    context: *anyopaque,
    handleEventFn: *const fn (self: *QueryEventConsumer, allocator: std.mem.Allocator, event: QueryEvent, request_id: u64) anyerror!QueryEventSummary,

    pub fn handleEvent(self: *QueryEventConsumer, allocator: std.mem.Allocator, event: QueryEvent, request_id: u64) !QueryEventSummary {
        return self.handleEventFn(self, allocator, event, request_id);
    }
};

pub const QueryTransport = struct {
    context: *anyopaque,
    beginQueryFn: *const fn (self: *QueryTransport, allocator: std.mem.Allocator, opts: QueryOptions) anyerror!void,
    nextEventFn: *const fn (self: *QueryTransport, allocator: std.mem.Allocator, timeout_secs: u32) anyerror!?QueryEvent,
    requestNextPageFn: ?*const fn (self: *QueryTransport, allocator: std.mem.Allocator, req: schema.PullRequest, timeout_secs: u32) anyerror!?QueryEvent = null,

    pub fn beginQuery(self: *QueryTransport, allocator: std.mem.Allocator, opts: QueryOptions) !void {
        return self.beginQueryFn(self, allocator, opts);
    }

    pub fn nextEvent(self: *QueryTransport, allocator: std.mem.Allocator, timeout_secs: u32) !?QueryEvent {
        return self.nextEventFn(self, allocator, timeout_secs);
    }

    pub fn requestNextPage(
        self: *QueryTransport,
        allocator: std.mem.Allocator,
        req: schema.PullRequest,
        timeout_secs: u32,
    ) !?QueryEvent {
        const handler = self.requestNextPageFn orelse return null;
        return handler(self, allocator, req, timeout_secs);
    }

    pub fn supportsPull(self: *const QueryTransport) bool {
        return self.requestNextPageFn != null;
    }
};

pub const ProtocolClient = struct {
    context: *anyopaque,
    sendClientMessageFn: *const fn (self: *ProtocolClient, allocator: std.mem.Allocator, msg: schema.QuicClientMessage) anyerror!void,
    readServerMessageFn: *const fn (self: *ProtocolClient, allocator: std.mem.Allocator, timeout_secs: u32) anyerror!schema.QuicServerMessage,

    pub fn sendClientMessage(self: *ProtocolClient, allocator: std.mem.Allocator, msg: schema.QuicClientMessage) !void {
        return self.sendClientMessageFn(self, allocator, msg);
    }

    pub fn readServerMessage(self: *ProtocolClient, allocator: std.mem.Allocator, timeout_secs: u32) !schema.QuicServerMessage {
        return self.readServerMessageFn(self, allocator, timeout_secs);
    }
};

pub const QueryOptions = struct {
    session_id: []const u8,
    query_text: []const u8,
    format: []const u8,
    timeout_secs: u32 = 30,
    page_size: u32 = default_page_size,
    params: std.ArrayList(schema.Param),
};

const ProtocolTransportAdapter = struct {
    protocol_client: *ProtocolClient,

    fn asTransport(self: *@This()) QueryTransport {
        return .{
            .context = self,
            .beginQueryFn = beginQuery,
            .nextEventFn = nextEvent,
            .requestNextPageFn = requestNextPage,
        };
    }

    fn beginQuery(transport: *QueryTransport, allocator_: std.mem.Allocator, transport_opts: QueryOptions) !void {
        const self: *@This() = @ptrCast(@alignCast(transport.context));
        const execute_req = schema.ExecuteRequest{
            .session_id = transport_opts.session_id,
            .query = transport_opts.query_text,
            .params = transport_opts.params,
        };
        try self.protocol_client.sendClientMessage(allocator_, .{ .execute = execute_req });
    }

    fn nextEvent(transport: *QueryTransport, allocator_: std.mem.Allocator, timeout_secs: u32) !?QueryEvent {
        const self: *@This() = @ptrCast(@alignCast(transport.context));
        while (true) {
            const msg = self.protocol_client.readServerMessage(allocator_, timeout_secs) catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };
            switch (msg) {
                .execute => |exec_resp| return .{ .execute = exec_resp },
                .pull => |pull_resp| {
                    const exec_resp = pull_resp.response orelse continue;
                    return .{ .execute = exec_resp };
                },
                .hello => |hello_resp| {
                    if (!hello_resp.success) {
                        return .{ .hello_failure = hello_resp.error_message };
                    }
                },
                .ping => {},
                else => {},
            }
        }
    }

    fn requestNextPage(
        transport: *QueryTransport,
        allocator_: std.mem.Allocator,
        req: schema.PullRequest,
        timeout_secs: u32,
    ) !?QueryEvent {
        const self: *@This() = @ptrCast(@alignCast(transport.context));
        try self.protocol_client.sendClientMessage(allocator_, .{ .pull = req });
        return try nextEvent(transport, allocator_, timeout_secs);
    }
};

pub fn consumeQuery(
    allocator: std.mem.Allocator,
    protocol_client: *ProtocolClient,
    opts: QueryOptions,
    consumer: *QueryEventConsumer,
) !void {
    var adapter = ProtocolTransportAdapter{ .protocol_client = protocol_client };
    var transport = adapter.asTransport();
    try consumeQueryWithTransport(allocator, &transport, opts, consumer);
}

pub fn collectQuery(
    allocator: std.mem.Allocator,
    protocol_client: *ProtocolClient,
    opts: QueryOptions,
) !query_results.ResultAccumulator {
    var adapter = ProtocolTransportAdapter{ .protocol_client = protocol_client };
    var transport = adapter.asTransport();
    return collectQueryWithTransport(allocator, &transport, opts);
}

pub fn consumeQueryWithTransport(
    allocator: std.mem.Allocator,
    transport: *QueryTransport,
    opts: QueryOptions,
    consumer: *QueryEventConsumer,
) !void {
    var params = opts.params;
    defer {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    }

    const owned_opts = QueryOptions{
        .session_id = opts.session_id,
        .query_text = opts.query_text,
        .format = opts.format,
        .timeout_secs = opts.timeout_secs,
        .page_size = opts.page_size,
        .params = params,
    };
    try transport.beginQuery(allocator, owned_opts);

    var schema_received = false;
    var saw_inline_page = false;
    var inline_final = false;

    while (!schema_received) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const event = try transport.nextEvent(arena.allocator(), opts.timeout_secs) orelse break;
        const summary = try consumer.handleEvent(allocator, event, 0);
        schema_received = schema_received or summary.schema_received;
        saw_inline_page = saw_inline_page or summary.saw_page;
        inline_final = inline_final or summary.page_final;
        if (summary.stop) return;
    }

    // Read ALL remaining inline pages.  The server sends all result pages
    // as EXECUTE responses (no PULL round-trip needed).  This avoids the
    // QUIC stream FIN race that caused PULL to arrive on a different handler.
    if (transport.supportsPull()) {
        if (!inline_final) {
            var done = false;
            while (!done) {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const event = transport.nextEvent(arena.allocator(), opts.timeout_secs) catch |err| {
                    if (err == error.EndOfStream or err == error.Timeout or err == error.WouldBlock) break;
                    return err;
                } orelse break;

                const summary = try consumer.handleEvent(allocator, event, 0);
                if (summary.page_final) done = true;
                if (summary.stop) return;
            }
        }
        return;
    }

    if (!inline_final) {
        var done = false;
        while (!done) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const event = transport.nextEvent(arena.allocator(), opts.timeout_secs) catch |err| {
                if (err == error.EndOfStream or err == error.Timeout or err == error.WouldBlock) break;
                return err;
            } orelse break;

            const summary = try consumer.handleEvent(allocator, event, 0);
            if (summary.page_final) {
                done = true;
            }
            if (summary.stop) return;
        }
    }
}

pub fn collectQueryWithTransport(
    allocator: std.mem.Allocator,
    transport: *QueryTransport,
    opts: QueryOptions,
) !query_results.ResultAccumulator {
    var result = try query_results.ResultAccumulator.init(allocator, opts.format);
    errdefer result.deinit();

    const AccumulatorConsumer = struct {
        result: *query_results.ResultAccumulator,

        fn handleEvent(
            consumer: *QueryEventConsumer,
            allocator_: std.mem.Allocator,
            event: QueryEvent,
            request_id: u64,
        ) !QueryEventSummary {
            _ = request_id;
            const self: *@This() = @ptrCast(@alignCast(consumer.context));
            const summary = try captureQueryEvent(allocator_, self.result, event);
            return .{
                .schema_received = summary.schema_received,
                .saw_page = summary.saw_page,
                .page_final = summary.page_final,
                .stop = self.result.has_error or self.result.result_kind != .rows,
            };
        }
    };

    var consumer_state = AccumulatorConsumer{ .result = &result };
    var consumer = QueryEventConsumer{
        .context = &consumer_state,
        .handleEventFn = AccumulatorConsumer.handleEvent,
    };
    try consumeQueryWithTransport(allocator, transport, opts, &consumer);
    return result;
}

fn captureQueryEvent(
    allocator: std.mem.Allocator,
    result: *query_results.ResultAccumulator,
    event: QueryEvent,
) !query_results.CaptureSummary {
    return switch (event) {
        .execute => |exec_resp| try result.captureExecutionResponse(exec_resp),
        .hello_failure => |message| blk: {
            result.has_error = true;
            result.error_message = try allocator.dupe(u8, message);
            result.error_message_allocated = true;
            result.error_status = "28000";
            break :blk .{};
        },
    };
}

fn emptyStrings(_: std.mem.Allocator) !std.ArrayList([]const u8) {
    return std.ArrayList([]const u8).empty;
}

fn buildOkStatus(allocator: std.mem.Allocator) !schema.Status {
    return .{
        .status_class = try allocator.dupe(u8, "00000"),
        .additional_statuses = try emptyStrings(allocator),
        .flagger_findings = try emptyStrings(allocator),
    };
}

fn buildColumn(allocator: std.mem.Allocator, name: []const u8, ty: []const u8) !schema.ColumnDefinition {
    return .{
        .name = try allocator.dupe(u8, name),
        .type = try allocator.dupe(u8, ty),
    };
}

fn buildIntRow(allocator: std.mem.Allocator, value: i64) !schema.Row {
    var values = try std.ArrayList(schema.Value).initCapacity(allocator, 1);
    try values.append(allocator, .{
        .kind = .{ .int_val = .{ .value = value, .kind = .INT } },
    });
    return .{ .values = values };
}

const FakeMessage = union(enum) {
    schema,
    execute_page: struct {
        values: []const i64,
        final: bool,
        ordered: bool = false,
        order_keys: []const []const u8 = &.{},
    },
    pull_page: struct {
        values: []const i64,
        final: bool,
        ordered: bool = false,
        order_keys: []const []const u8 = &.{},
    },
    hello_failure: struct {
        message: []const u8,
    },
    explain,
};

const FakeProtocol = struct {
    allocator: std.mem.Allocator,
    scripted: []const FakeMessage,
    next_message: usize = 0,
    execute_queries: std.ArrayList([]const u8),
    pull_page_sizes: std.ArrayList(u32),

    fn init(allocator: std.mem.Allocator, scripted: []const FakeMessage) !FakeProtocol {
        return .{
            .allocator = allocator,
            .scripted = scripted,
            .execute_queries = try std.ArrayList([]const u8).initCapacity(allocator, 1),
            .pull_page_sizes = try std.ArrayList(u32).initCapacity(allocator, 1),
        };
    }

    fn deinit(self: *FakeProtocol) void {
        for (self.execute_queries.items) |query_text| {
            self.allocator.free(query_text);
        }
        self.execute_queries.deinit(self.allocator);
        self.pull_page_sizes.deinit(self.allocator);
    }

    fn sendClientMessage(proto: *ProtocolClient, allocator: std.mem.Allocator, msg: schema.QuicClientMessage) !void {
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(proto.context));
        switch (msg) {
            .execute => |exec_req| try self.execute_queries.append(self.allocator, try self.allocator.dupe(u8, exec_req.query)),
            .pull => |pull_req| try self.pull_page_sizes.append(self.allocator, pull_req.page_size),
            else => {},
        }
    }

    fn readServerMessage(proto: *ProtocolClient, allocator: std.mem.Allocator, timeout_secs: u32) !schema.QuicServerMessage {
        _ = timeout_secs;
        const self: *@This() = @ptrCast(@alignCast(proto.context));
        if (self.next_message >= self.scripted.len) return error.EndOfStream;

        const scripted = self.scripted[self.next_message];
        self.next_message += 1;
        return switch (scripted) {
            .schema => .{ .execute = try buildSchemaMessage(allocator) },
            .execute_page => |page| .{ .execute = try buildPageMessage(allocator, page.values, page.final, page.ordered, page.order_keys) },
            .pull_page => |page| .{ .pull = try buildPullMessage(allocator, page.values, page.final, page.ordered, page.order_keys) },
            .hello_failure => |failure| .{ .hello = .{
                .success = false,
                .session_id = "",
                .error_message = try allocator.dupe(u8, failure.message),
                .graph = "",
                .server_caps = "",
            } },
            .explain => .{ .execute = try buildExplainMessage(allocator) },
        };
    }
};

fn buildSchemaMessage(allocator: std.mem.Allocator) !schema.ExecutionResponse {
    var columns = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
    try columns.append(allocator, try buildColumn(allocator, "value", "INTEGER"));
    return .{
        .status = try buildOkStatus(allocator),
        .payload = .{ .schema = .{ .columns = columns } },
    };
}

fn buildPage(allocator: std.mem.Allocator, values: []const i64, final: bool, ordered: bool, order_keys: []const []const u8) !schema.DataPage {
    var rows = try std.ArrayList(schema.Row).initCapacity(allocator, values.len);
    for (values) |value| {
        try rows.append(allocator, try buildIntRow(allocator, value));
    }

    var keys = try std.ArrayList([]const u8).initCapacity(allocator, order_keys.len);
    for (order_keys) |key| {
        try keys.append(allocator, try allocator.dupe(u8, key));
    }

    return .{
        .rows = rows,
        .final = final,
        .ordered = ordered,
        .order_keys = keys,
    };
}

fn buildPageMessage(allocator: std.mem.Allocator, values: []const i64, final: bool, ordered: bool, order_keys: []const []const u8) !schema.ExecutionResponse {
    return .{
        .status = try buildOkStatus(allocator),
        .payload = .{ .page = try buildPage(allocator, values, final, ordered, order_keys) },
    };
}

fn buildPullMessage(allocator: std.mem.Allocator, values: []const i64, final: bool, ordered: bool, order_keys: []const []const u8) !schema.PullResponse {
    return .{
        .response = try buildPageMessage(allocator, values, final, ordered, order_keys),
    };
}

fn buildExplainMessage(allocator: std.mem.Allocator) !schema.ExecutionResponse {
    return .{
        .status = try buildOkStatus(allocator),
        .payload = .{ .explain = .{
            .schema = try allocator.dupe(u8, "RETURN 1"),
            .ops = std.ArrayList(schema.ExplainOp).empty,
            .totals = null,
            .properties = null,
            .calibration = null,
            .profile_version = 1,
        } },
    };
}

test "collectQuery merges inline execute page with pulled pages" {
    const allocator = std.testing.allocator;

    const scripted = [_]FakeMessage{
        .schema,
        .{ .execute_page = .{ .values = &.{ 1, 2 }, .final = false } },
        .{ .pull_page = .{ .values = &.{ 3, 4 }, .final = true } },
    };

    var fake = try FakeProtocol.init(allocator, &scripted);
    defer fake.deinit();

    var client = ProtocolClient{
        .context = &fake,
        .sendClientMessageFn = FakeProtocol.sendClientMessage,
        .readServerMessageFn = FakeProtocol.readServerMessage,
    };

    const empty_params = std.ArrayList(schema.Param){};
    var result = try collectQuery(allocator, &client, .{
        .session_id = "session-1",
        .query_text = "RETURN 1",
        .format = "json",
        .page_size = 7,
        .params = empty_params,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.rowCount());
    try std.testing.expectEqual(@as(usize, 1), fake.pull_page_sizes.items.len);
    try std.testing.expectEqual(@as(u32, 7), fake.pull_page_sizes.items[0]);
    try std.testing.expectEqualStrings("RETURN 1", fake.execute_queries.items[0]);
}

test "collectQuery skips pull when inline page is already final" {
    const allocator = std.testing.allocator;

    const scripted = [_]FakeMessage{
        .schema,
        .{ .execute_page = .{ .values = &.{42}, .final = true } },
    };

    var fake = try FakeProtocol.init(allocator, &scripted);
    defer fake.deinit();

    var client = ProtocolClient{
        .context = &fake,
        .sendClientMessageFn = FakeProtocol.sendClientMessage,
        .readServerMessageFn = FakeProtocol.readServerMessage,
    };

    const empty_params = std.ArrayList(schema.Param){};
    var result = try collectQuery(allocator, &client, .{
        .session_id = "session-2",
        .query_text = "RETURN 42",
        .format = "json",
        .params = empty_params,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    try std.testing.expectEqual(@as(usize, 0), fake.pull_page_sizes.items.len);
}

test "collectQuery captures hello auth failure as query error" {
    const allocator = std.testing.allocator;

    const scripted = [_]FakeMessage{
        .{ .hello_failure = .{ .message = "Authentication failed" } },
    };

    var fake = try FakeProtocol.init(allocator, &scripted);
    defer fake.deinit();

    var client = ProtocolClient{
        .context = &fake,
        .sendClientMessageFn = FakeProtocol.sendClientMessage,
        .readServerMessageFn = FakeProtocol.readServerMessage,
    };

    const empty_params = std.ArrayList(schema.Param){};
    var result = try collectQuery(allocator, &client, .{
        .session_id = "",
        .query_text = "RETURN 1",
        .format = "json",
        .params = empty_params,
    });
    defer result.deinit();

    try std.testing.expect(result.has_error);
    try std.testing.expectEqualStrings("28000", result.error_status);
    try std.testing.expectEqualStrings("Authentication failed", result.error_message);
}

test "collectQuery captures explain payload without pulling rows" {
    const allocator = std.testing.allocator;

    const scripted = [_]FakeMessage{
        .explain,
    };

    var fake = try FakeProtocol.init(allocator, &scripted);
    defer fake.deinit();

    var client = ProtocolClient{
        .context = &fake,
        .sendClientMessageFn = FakeProtocol.sendClientMessage,
        .readServerMessageFn = FakeProtocol.readServerMessage,
    };

    const empty_params = std.ArrayList(schema.Param){};
    var result = try collectQuery(allocator, &client, .{
        .session_id = "session-3",
        .query_text = "EXPLAIN RETURN 1",
        .format = "json",
        .params = empty_params,
    });
    defer result.deinit();

    try std.testing.expectEqual(query_results.QueryResultKind.explain, result.result_kind);
    try std.testing.expectEqual(@as(usize, 0), result.rowCount());
    try std.testing.expectEqual(@as(usize, 0), fake.pull_page_sizes.items.len);
}

test "collectQuery drains streaming transport without pull support" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const FakeStreamingTransport = struct {
        scripted: []const QueryEvent,
        next_message: usize = 0,

        fn beginQuery(transport: *QueryTransport, allocator_: std.mem.Allocator, opts: QueryOptions) !void {
            _ = transport;
            _ = allocator_;
            _ = opts;
        }

        fn nextEvent(transport: *QueryTransport, allocator_: std.mem.Allocator, timeout_secs: u32) !?QueryEvent {
            _ = allocator_;
            _ = timeout_secs;
            const self: *@This() = @ptrCast(@alignCast(transport.context));
            if (self.next_message >= self.scripted.len) return null;
            const event = self.scripted[self.next_message];
            self.next_message += 1;
            return event;
        }
    };

    const scripted = [_]QueryEvent{
        .{ .execute = try buildSchemaMessage(scratch) },
        .{ .execute = try buildPageMessage(scratch, &.{ 1, 2 }, false, false, &.{}) },
        .{ .execute = try buildPageMessage(scratch, &.{ 3, 4 }, true, false, &.{}) },
    };

    var fake = FakeStreamingTransport{ .scripted = &scripted };
    var transport = QueryTransport{
        .context = &fake,
        .beginQueryFn = FakeStreamingTransport.beginQuery,
        .nextEventFn = FakeStreamingTransport.nextEvent,
    };

    const empty_params = std.ArrayList(schema.Param){};
    var result = try collectQueryWithTransport(allocator, &transport, .{
        .session_id = "stream-session",
        .query_text = "MATCH (n) RETURN n",
        .format = "json",
        .params = empty_params,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.rowCount());
}

test "consumeQueryWithTransport forwards pull request ids to consumers" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const FakeStreamingTransport = struct {
        scripted: []const QueryEvent,
        next_message: usize = 0,

        fn beginQuery(transport: *QueryTransport, allocator_: std.mem.Allocator, opts: QueryOptions) !void {
            _ = transport;
            _ = allocator_;
            _ = opts;
        }

        fn nextEvent(transport: *QueryTransport, allocator_: std.mem.Allocator, timeout_secs: u32) !?QueryEvent {
            _ = allocator_;
            _ = timeout_secs;
            const self: *@This() = @ptrCast(@alignCast(transport.context));
            if (self.next_message >= self.scripted.len) return null;
            const event = self.scripted[self.next_message];
            self.next_message += 1;
            return event;
        }

        fn requestNextPage(
            transport: *QueryTransport,
            allocator_: std.mem.Allocator,
            req: schema.PullRequest,
            timeout_secs: u32,
        ) !?QueryEvent {
            _ = req;
            return try nextEvent(transport, allocator_, timeout_secs);
        }
    };

    const RequestIdConsumer = struct {
        seen_request_ids: *std.ArrayList(u64),

        fn handleEvent(
            consumer: *QueryEventConsumer,
            allocator_: std.mem.Allocator,
            event: QueryEvent,
            request_id: u64,
        ) !QueryEventSummary {
            _ = allocator_;
            const self: *@This() = @ptrCast(@alignCast(consumer.context));
            return switch (event) {
                .hello_failure => error.AuthenticationFailed,
                .execute => |exec_resp| blk: {
                    if (exec_resp.payload) |payload| switch (payload) {
                        .schema => break :blk .{ .schema_received = true },
                        .page => |page| {
                            try self.seen_request_ids.append(self.seen_request_ids.allocator, request_id);
                            break :blk .{
                                .saw_page = true,
                                .page_final = page.final,
                            };
                        },
                        .@"error" => return error.UnexpectedQueryError,
                        .explain, .profile => return error.UnexpectedPayload,
                        .metrics, .heartbeat => {},
                    };
                    break :blk .{};
                },
            };
        }
    };

    const scripted = [_]QueryEvent{
        .{ .execute = try buildSchemaMessage(scratch) },
        .{ .execute = try buildPageMessage(scratch, &.{ 1, 2 }, false, false, &.{}) },
        .{ .execute = try buildPageMessage(scratch, &.{ 3, 4 }, false, false, &.{}) },
        .{ .execute = try buildPageMessage(scratch, &.{ 5, 6 }, true, false, &.{}) },
    };

    var fake = FakeStreamingTransport{ .scripted = &scripted };
    var transport = QueryTransport{
        .context = &fake,
        .beginQueryFn = FakeStreamingTransport.beginQuery,
        .nextEventFn = FakeStreamingTransport.nextEvent,
        .requestNextPageFn = FakeStreamingTransport.requestNextPage,
    };

    var seen_request_ids = std.ArrayList(u64).empty;
    defer seen_request_ids.deinit(allocator);
    var consumer_state = RequestIdConsumer{ .seen_request_ids = &seen_request_ids };
    var consumer = QueryEventConsumer{
        .context = &consumer_state,
        .handleEventFn = RequestIdConsumer.handleEvent,
    };

    const empty_params = std.ArrayList(schema.Param){};
    try consumeQueryWithTransport(allocator, &transport, .{
        .session_id = "stream-session",
        .query_text = "MATCH (n) RETURN n",
        .format = "json",
        .page_size = 11,
        .params = empty_params,
    }, &consumer);

    try std.testing.expectEqual(@as(usize, 3), seen_request_ids.items.len);
    try std.testing.expectEqual(@as(u64, 0), seen_request_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 1), seen_request_ids.items[1]);
    try std.testing.expectEqual(@as(u64, 2), seen_request_ids.items[2]);
}
