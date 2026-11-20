// SONNY-2465: gRPC streaming /Execute returned the schema and then zero rows
// whenever the node-scan fast path served the statement.
//
// handleExecuteStreaming sends handleExecute's schema frame and then drains
// the session's result through `pushResultPages`. That drain read only
// `state.active_result_values` (the executor's result). When the `.rows` arm
// served the statement from `node_scan_stream` instead, the session held an
// `active_node_scan_stream` and no executor result, so `pushResultPages`
// answered `.no_result` and the stream ended after the schema: the client saw
// zero rows. Only the legacy Pull handler served node-scan streams.
//
// Over a real `geode serve` the gRPC gate (`getGlobalRLSFilterEngine() != null
// and authenticated_user != null`) keeps every session off the fast path, so
// this was latent; aligning that gate with QUIC's policy-aware gate would have
// exposed it. In process there is no global RLS engine and auth is off, so the
// real `handleExecute` takes the fast path (asserted below) and the real
// `pushResultPages` -- the drain handleExecuteStreaming runs -- must deliver
// every row, end with a final page, and release the session's stream. The
// page sink captures what the transport would have written.

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const protobuf = @import("protobuf");
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const user_mgmt = geode.user_management;

/// More rows than one pushed page (the node-scan default page is 128 rows).
const row_count: usize = 300;

const CaptureSink = struct {
    gpa: std.mem.Allocator,
    pages: std.ArrayList([]u8) = .empty,

    fn deinit(self: *CaptureSink) void {
        for (self.pages.items) |p| self.gpa.free(p);
        self.pages.deinit(self.gpa);
    }

    fn writeThunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        try self.pages.append(self.gpa, try self.gpa.dupe(u8, bytes));
    }

    fn sink(self: *CaptureSink) grpc.PageSink {
        return .{ .ctx = @ptrCast(self), .writeFn = writeThunk };
    }
};

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

test "SONNY-2465: gRPC streaming Execute pushes every node-scan row after the schema frame" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    {
        const aa = h.arena.allocator();
        for (0..row_count) |i| {
            var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:P {{i: {d}}})", .{i}));
            r.deinit(aa);
        }
    }

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();

    var store = grpc.SessionStore.init(ga, .{});
    defer store.deinit();
    grpc.setSessionStore(&store);
    defer grpc.setSessionStore(null);
    const session_id = try store.createSession("", "", null, null, null, false, 0);
    const entry = store.getEntry(session_id) orelse return error.SessionMissing;

    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = "MATCH (n:P) RETURN n.i",
        .params = .empty,
    });
    var claimed_epoch: u64 = 0;
    const first = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, &claimed_epoch));
    switch (first.payload orelse return error.MissingPayload) {
        .schema => {},
        .@"error" => |e| {
            std.debug.print("Execute failed: {s}\n", .{e.message});
            return error.ServerError;
        },
        else => return error.UnexpectedPayload,
    }

    // The fast path served it: a node-scan stream, no executor result.
    try testing.expect(entry.state.active_node_scan_stream != null);
    try testing.expect(entry.state.active_result_values == null);

    var capture = CaptureSink{ .gpa = testing.allocator };
    defer capture.deinit();
    const outcome = grpc.pushResultPages(entry, claimed_epoch, capture.sink(), ga);

    var seen = try testing.allocator.alloc(bool, row_count);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var rows: usize = 0;
    var last_final = false;
    for (capture.pages.items) |bytes| {
        const resp = try decodeProto(schema.ExecutionResponse, ga, bytes);
        const page = switch (resp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            .@"error" => |e| {
                std.debug.print("pushed page is an error: {s}\n", .{e.message});
                return error.ServerError;
            },
            else => return error.UnexpectedPayload,
        };
        for (page.rows.items) |row| {
            try testing.expectEqual(@as(usize, 1), row.values.items.len);
            const v = switch (row.values.items[0].kind orelse return error.NullValue) {
                .int_val => |x| x.value,
                else => return error.UnexpectedValueKind,
            };
            const idx: usize = @intCast(v);
            try testing.expect(idx < row_count);
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            rows += 1;
        }
        last_final = page.final;
    }
    if (outcome != .complete or rows != row_count) {
        std.debug.print("SONNY-2465: pushResultPages -> {s}, {d} pages, {d}/{d} rows\n", .{ @tagName(outcome), capture.pages.items.len, rows, row_count });
    }
    try testing.expectEqual(grpc.PushOutcome.complete, outcome);
    try testing.expectEqual(row_count, rows);
    try testing.expect(capture.pages.items.len > 1);
    try testing.expect(last_final);

    // The drained stream is released, as the executor path's result is.
    try testing.expect(entry.state.active_node_scan_stream == null);
    try testing.expect(!entry.state.active_result);
}
