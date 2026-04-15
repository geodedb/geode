// gRPC HTTP/2 query transport — used by distributed coordination and gRPC fallback paths.
// The primary CLI transport is QUIC via zig_quic_bridge → geode-client-zig.
// Keep this file's QueryTransport interface in sync with quic_query_runner.zig.
const std = @import("std");
const builtin = @import("builtin");
const protobuf = @import("protobuf");
const schema = @import("schema");
const query_runner = @import("query_runner.zig");

pub const handshake_stream_id: u31 = 1;
pub const execute_stream_id: u31 = 3;
pub const handshake_method_path = "/geode.GeodeService/Handshake";
pub const execute_method_path = "/geode.GeodeService/Execute";

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_RST_STREAM: u8 = 0x3;
const H2_SETTINGS: u8 = 0x4;
const H2_PING: u8 = 0x6;
const H2_GOAWAY: u8 = 0x7;
const H2_WINDOW_UPDATE: u8 = 0x8;

pub const ProgressHooks = struct {
    on_progress: ?*const fn () void = null,
};

pub const HelloOptions = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    graph: ?[]const u8 = null,
};

const H2Frame = struct {
    frame_type: u8,
    flags: u8,
    stream_id: u31,
    payload: []u8,
};

fn notifyProgress(hooks: ProgressHooks) void {
    if (hooks.on_progress) |callback| callback();
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try stream.write(bytes[written..]);
        if (n == 0) return error.ConnectionClosed;
        written += n;
    }
}

pub fn setSocketTimeouts(stream: std.net.Stream, timeout_secs: u32) void {
    if (builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    const tv_bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes) catch {};
}

pub fn connectPlaintext(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_secs: u32,
    hooks: ProgressHooks,
) !std.net.Stream {
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();

    setSocketTimeouts(stream, timeout_secs);
    try writeAll(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try writeFrame(stream, H2_SETTINGS, 0, 0, &.{});
    try drainInitialSettings(allocator, stream, hooks);
    return stream;
}

pub fn drainInitialSettings(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hooks: ProgressHooks,
) !void {
    var got_settings_ack = false;
    var iterations: usize = 0;
    while (!got_settings_ack and iterations < 10) : (iterations += 1) {
        const frame = try readFrame(allocator, stream, hooks);
        defer allocator.free(frame.payload);

        if (frame.frame_type != H2_SETTINGS) continue;
        if ((frame.flags & 0x1) != 0) {
            got_settings_ack = true;
        } else {
            try writeFrame(stream, H2_SETTINGS, 0x1, 0, &.{});
        }
    }
}

pub fn writeFrame(
    stream: std.net.Stream,
    frame_type: u8,
    flags: u8,
    stream_id: u31,
    payload: []const u8,
) !void {
    const length: u24 = @intCast(payload.len);
    var header: [9]u8 = undefined;
    header[0] = @intCast((length >> 16) & 0xFF);
    header[1] = @intCast((length >> 8) & 0xFF);
    header[2] = @intCast(length & 0xFF);
    header[3] = frame_type;
    header[4] = flags;
    header[5] = @intCast((@as(u32, stream_id) >> 24) & 0x7F);
    header[6] = @intCast((@as(u32, stream_id) >> 16) & 0xFF);
    header[7] = @intCast((@as(u32, stream_id) >> 8) & 0xFF);
    header[8] = @intCast(@as(u32, stream_id) & 0xFF);

    try writeAll(stream, &header);
    if (payload.len > 0) {
        try writeAll(stream, payload);
    }
}

pub fn readFrame(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hooks: ProgressHooks,
) !H2Frame {
    var header: [9]u8 = undefined;
    var total: usize = 0;
    while (total < header.len) {
        const n = try stream.read(header[total..]);
        if (n == 0) return error.ConnectionClosed;
        notifyProgress(hooks);
        total += n;
    }

    const length: u24 = (@as(u24, header[0]) << 16) | (@as(u24, header[1]) << 8) | @as(u24, header[2]);
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);

    var payload_total: usize = 0;
    while (payload_total < payload.len) {
        const n = try stream.read(payload[payload_total..]);
        if (n == 0) return error.ConnectionClosed;
        notifyProgress(hooks);
        payload_total += n;
    }

    return .{
        .frame_type = header[3],
        .flags = header[4],
        .stream_id = @intCast(
            (@as(u32, header[5] & 0x7F) << 24) |
                (@as(u32, header[6]) << 16) |
                (@as(u32, header[7]) << 8) |
                @as(u32, header[8]),
        ),
        .payload = payload,
    };
}

pub fn sendRequest(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    method_path: []const u8,
    message: []const u8,
    stream_id: u31,
) !void {
    var headers = try std.ArrayList(u8).initCapacity(allocator, 128);
    defer headers.deinit(allocator);

    try headers.append(allocator, 0x83); // :method POST
    try headers.append(allocator, 0x86); // :scheme http
    try headers.append(allocator, 0x04); // :path literal without indexing, name index 4
    try headers.append(allocator, @intCast(method_path.len));
    try headers.appendSlice(allocator, method_path);
    try headers.append(allocator, 0x40 | 31); // content-type with incremental indexing
    try headers.append(allocator, 16);
    try headers.appendSlice(allocator, "application/grpc");

    try writeFrame(stream, H2_HEADERS, 0x4, stream_id, headers.items);

    const message_len: u32 = @intCast(message.len);
    const grpc_frame = try allocator.alloc(u8, 5 + message.len);
    defer allocator.free(grpc_frame);
    grpc_frame[0] = 0;
    grpc_frame[1] = @intCast((message_len >> 24) & 0xFF);
    grpc_frame[2] = @intCast((message_len >> 16) & 0xFF);
    grpc_frame[3] = @intCast((message_len >> 8) & 0xFF);
    grpc_frame[4] = @intCast(message_len & 0xFF);
    @memcpy(grpc_frame[5..], message);

    try writeFrame(stream, H2_DATA, 0x1, stream_id, grpc_frame);
}

pub fn readResponse(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hooks: ProgressHooks,
) !?[]u8 {
    while (true) {
        const frame = readFrame(allocator, stream, hooks) catch |err| {
            if (err == error.ConnectionClosed) return null;
            return err;
        };
        const frame_type = frame.frame_type;
        const flags = frame.flags;
        const payload = frame.payload;

        if (frame_type == H2_DATA) {
            if (payload.len >= 5) {
                const msg_len = (@as(u32, payload[1]) << 24) |
                    (@as(u32, payload[2]) << 16) |
                    (@as(u32, payload[3]) << 8) |
                    @as(u32, payload[4]);
                if (payload.len >= 5 + msg_len) {
                    const result = try allocator.alloc(u8, msg_len);
                    @memcpy(result, payload[5 .. 5 + msg_len]);
                    allocator.free(payload);
                    return result;
                }
            }
            if (payload.len == 0) {
                allocator.free(payload);
                if ((flags & 0x1) != 0) return null;
                continue;
            }
            return payload;
        }

        if (frame_type == H2_HEADERS) {
            const end_stream = (flags & 0x1) != 0;
            allocator.free(payload);
            if (end_stream) return null;
            continue;
        }

        if (frame_type == H2_SETTINGS) {
            if ((flags & 0x1) == 0) {
                try writeFrame(stream, H2_SETTINGS, 0x1, 0, &.{});
            }
            allocator.free(payload);
            continue;
        }

        if (frame_type == H2_WINDOW_UPDATE) {
            allocator.free(payload);
            continue;
        }

        if (frame_type == H2_PING) {
            if ((flags & 0x1) == 0) {
                try writeFrame(stream, H2_PING, 0x1, 0, payload);
            }
            allocator.free(payload);
            continue;
        }

        if (frame_type == H2_RST_STREAM or frame_type == H2_GOAWAY) {
            allocator.free(payload);
            return null;
        }

        allocator.free(payload);
    }
}

pub fn drainUnaryStream(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hooks: ProgressHooks,
) void {
    while (true) {
        const extra = readResponse(allocator, stream, hooks) catch break;
        if (extra) |data| {
            allocator.free(data);
        } else {
            break;
        }
    }
}

pub fn encodeMessage(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

pub fn hello(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    options: HelloOptions,
    hooks: ProgressHooks,
) !schema.HelloResponse {
    const hello_req = schema.HelloRequest{
        .username = options.username orelse "",
        .password = options.password orelse "",
        .tenant_id = null,
        .graph = options.graph,
    };
    const hello_bytes = try encodeMessage(allocator, hello_req);
    defer allocator.free(hello_bytes);
    try sendRequest(allocator, stream, handshake_method_path, hello_bytes, handshake_stream_id);

    const hello_resp_bytes = try readResponse(allocator, stream, hooks) orelse return error.EmptyHandshakeResponse;
    defer allocator.free(hello_resp_bytes);

    var reader: std.Io.Reader = .fixed(hello_resp_bytes);
    return protobuf.decode(schema.HelloResponse, &reader, allocator);
}

pub const StreamingQueryAdapter = struct {
    stream: std.net.Stream,
    hooks: ProgressHooks = .{},

    pub fn asTransport(self: *@This()) query_runner.QueryTransport {
        return .{
            .context = self,
            .beginQueryFn = beginQuery,
            .nextEventFn = nextEvent,
        };
    }

    fn beginQuery(
        query_transport: *query_runner.QueryTransport,
        allocator: std.mem.Allocator,
        opts: query_runner.QueryOptions,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(query_transport.context));
        const exec_req = schema.ExecuteRequest{
            .session_id = opts.session_id,
            .query = opts.query_text,
            .params = opts.params,
        };
        const exec_bytes = try encodeMessage(allocator, exec_req);
        defer allocator.free(exec_bytes);
        try sendRequest(allocator, self.stream, execute_method_path, exec_bytes, execute_stream_id);
    }

    fn nextEvent(
        query_transport: *query_runner.QueryTransport,
        allocator: std.mem.Allocator,
        timeout_secs: u32,
    ) !?query_runner.QueryEvent {
        _ = timeout_secs;
        const self: *@This() = @ptrCast(@alignCast(query_transport.context));
        const resp_bytes = try readResponse(allocator, self.stream, self.hooks) orelse return null;
        defer allocator.free(resp_bytes);
        var reader: std.Io.Reader = .fixed(resp_bytes);
        const exec_resp = try protobuf.decode(schema.ExecutionResponse, &reader, allocator);
        return .{ .execute = exec_resp };
    }
};
