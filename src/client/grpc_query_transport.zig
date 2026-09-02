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

// HTTP/2 SETTINGS identifiers (RFC 7540 §6.5.2).
const H2_SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x04;
const H2_SETTINGS_MAX_FRAME_SIZE: u16 = 0x05;

/// RFC 7540 §6.5.2: the default AND minimum legal SETTINGS_MAX_FRAME_SIZE. A
/// peer may advertise a larger value but never a smaller one, so splitting an
/// outbound request into <= this many payload bytes per DATA frame is always
/// accepted even before the peer's SETTINGS are parsed.
const h2_default_max_frame_size: usize = 16384;

/// Window we advertise for our receive side so a large streamed response is not
/// throttled by the 65535-byte default. Paired with per-frame WINDOW_UPDATE
/// replenishment in `readResponse` for the connection-level (stream 0) window.
const h2_client_initial_window: u32 = 16 * 1024 * 1024;

/// Peer's SETTINGS_MAX_FRAME_SIZE, learned in `drainInitialSettings` and read by
/// `sendRequest` to cap outbound DATA-frame fragmentation. Thread-local so each
/// connection (the CLI query thread, a distributed-coordination worker) keeps
/// its own negotiated value without a shared-state race.
threadlocal var tl_peer_max_frame_size: usize = h2_default_max_frame_size;

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

fn writeAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var write_buf: [8192]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    try sw.interface.writeAll(bytes);
    try sw.interface.flush();
}

pub fn setSocketTimeouts(stream: std.Io.net.Stream, timeout_secs: u32) void {
    if (builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    const tv_bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes) catch {};
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes) catch {};
}

pub fn connectPlaintext(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_secs: u32,
    hooks: ProgressHooks,
) !std.Io.net.Stream {
    const io = std.Io.Threaded.global_single_threaded.io();
    var addr = std.Io.net.IpAddress.parse(host, port) catch
        std.Io.net.IpAddress.parseIp4(host, port) catch
        try std.Io.net.IpAddress.parseIp6(host, port);
    const stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    errdefer stream.close(io);

    setSocketTimeouts(stream, timeout_secs);
    // Reset the negotiated peer frame size for this (thread's) connection; it is
    // refined below when the peer's SETTINGS arrive.
    tl_peer_max_frame_size = h2_default_max_frame_size;
    try writeAll(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    // Advertise a large receive window so a big streamed response is not stalled
    // by the 65535-byte default per-stream window (RFC 7540 §6.9.2). Connection-
    // level (stream 0) flow control is replenished incrementally in readResponse.
    var settings_payload: [6]u8 = undefined;
    writeSetting(&settings_payload, H2_SETTINGS_INITIAL_WINDOW_SIZE, h2_client_initial_window);
    try writeFrame(stream, H2_SETTINGS, 0, 0, &settings_payload);
    try drainInitialSettings(allocator, stream, hooks);
    return stream;
}

/// Encode one HTTP/2 SETTINGS entry (2-byte id + 4-byte value, big-endian).
fn writeSetting(dest: *[6]u8, id: u16, value: u32) void {
    dest[0] = @intCast((id >> 8) & 0xFF);
    dest[1] = @intCast(id & 0xFF);
    dest[2] = @intCast((value >> 24) & 0xFF);
    dest[3] = @intCast((value >> 16) & 0xFF);
    dest[4] = @intCast((value >> 8) & 0xFF);
    dest[5] = @intCast(value & 0xFF);
}

/// Parse a SETTINGS frame payload and apply the peer's SETTINGS_MAX_FRAME_SIZE
/// to `tl_peer_max_frame_size`, so `sendRequest` can split an oversized request
/// into frames the peer will accept. Malformed/partial payloads are ignored
/// (the default stays in effect).
fn applyPeerSettings(payload: []const u8) void {
    var i: usize = 0;
    while (i + 6 <= payload.len) : (i += 6) {
        const id = (@as(u16, payload[i]) << 8) | @as(u16, payload[i + 1]);
        const value = (@as(u32, payload[i + 2]) << 24) |
            (@as(u32, payload[i + 3]) << 16) |
            (@as(u32, payload[i + 4]) << 8) |
            @as(u32, payload[i + 5]);
        if (id == H2_SETTINGS_MAX_FRAME_SIZE) {
            // Clamp to the RFC-legal range [16384, 16777215]; never go below the
            // default (a smaller value would be a peer protocol violation, and a
            // smaller split gains nothing).
            const clamped = @max(@as(usize, value), h2_default_max_frame_size);
            tl_peer_max_frame_size = @min(clamped, @as(usize, 16_777_215));
        }
    }
}

pub fn drainInitialSettings(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
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
            // The peer's own SETTINGS: learn its MAX_FRAME_SIZE, then ACK.
            applyPeerSettings(frame.payload);
            try writeFrame(stream, H2_SETTINGS, 0x1, 0, &.{});
        }
    }
}

pub fn writeFrame(
    stream: std.Io.net.Stream,
    frame_type: u8,
    flags: u8,
    stream_id: u31,
    payload: []const u8,
) !void {
    // A single HTTP/2 frame length is a u24; a payload of 16 MiB or more cannot
    // be expressed. Callers that can produce large payloads (DATA) fragment
    // before calling here; guard so an out-of-range @intCast can never wrap.
    if (payload.len > std.math.maxInt(u24)) return error.FrameTooLarge;
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

// CANARY: REQ=REQ-ENG-3907-GRPC-TRANSPORT; FEATURE="GrpcTransport"; ASPECT=ClientFrameReadTimeout; STATUS=TESTED; TEST=test-transport-parity; OWNER=transport; UPDATED=2026-08-24
//
// ENG-3907: read EXACTLY `dest.len` bytes straight off the socket.
//
// `readFrame` used to build a fresh `std.Io.Reader` over an 8 KiB stack buffer
// on every call, which carried two defects:
//
//   * `setSocketTimeouts` puts SO_RCVTIMEO on this socket, so a read that
//     outlives `--timeout` returns EAGAIN — and Zig 0.16's
//     `Io.Threaded.netReadPosix` classifies EAGAIN on a blocking fd as a
//     programmer bug and PANICS ("programmer bug caused syscall error: AGAIN")
//     instead of surfacing an error. Reproduced by the QUIC-vs-gRPC
//     transport-parity smoke the moment it got past the TLS handshake.
//   * the buffered reader was free to read AHEAD of the requested bytes into a
//     stack buffer that died with the call, silently dropping the head of the
//     next HTTP/2 frame.
//
// Reading the fd directly fixes both: no read-ahead is possible, and the
// timeout becomes an ordinary `error.ReadTimeout` the caller can report.
fn readExact(stream: std.Io.net.Stream, dest: []u8, hooks: ProgressHooks) !void {
    var total: usize = 0;
    while (total < dest.len) {
        const n = std.posix.read(stream.socket.handle, dest[total..]) catch |err| switch (err) {
            error.WouldBlock => return error.ReadTimeout,
            else => |e| return e,
        };
        if (n == 0) return error.ConnectionClosed;
        notifyProgress(hooks);
        total += n;
    }
}

pub fn readFrame(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    hooks: ProgressHooks,
) !H2Frame {
    var header: [9]u8 = undefined;
    try readExact(stream, &header, hooks);

    const length: u24 = (@as(u24, header[0]) << 16) | (@as(u24, header[1]) << 8) | @as(u24, header[2]);
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try readExact(stream, payload, hooks);

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
    stream: std.Io.net.Stream,
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

    // Split the length-prefixed gRPC message across as many DATA frames as the
    // peer's SETTINGS_MAX_FRAME_SIZE requires (HTTP/2 default 16384). Emitting it
    // as one oversized frame drew a spec-correct FRAME_SIZE_ERROR from the server
    // and looked like a bogus TLS reset to the caller. END_STREAM rides ONLY the
    // final frame; the gRPC message boundary is the whole reassembled byte run.
    const chunk_size = @max(tl_peer_max_frame_size, @as(usize, 1));
    var offset: usize = 0;
    if (grpc_frame.len == 0) {
        // Degenerate: still send an empty END_STREAM DATA frame.
        try writeFrame(stream, H2_DATA, 0x1, stream_id, grpc_frame);
        return;
    }
    while (offset < grpc_frame.len) {
        const end = @min(offset + chunk_size, grpc_frame.len);
        const is_last = end == grpc_frame.len;
        const flags: u8 = if (is_last) 0x1 else 0x0;
        try writeFrame(stream, H2_DATA, flags, stream_id, grpc_frame[offset..end]);
        offset = end;
    }
}

/// Emit a WINDOW_UPDATE with `increment` credit on `stream_id` (0 = connection).
/// Best-effort: a write failure here just means the peer may throttle, not that
/// the response is lost, so callers ignore the error.
fn sendWindowUpdate(stream: std.Io.net.Stream, stream_id: u31, increment: u32) !void {
    if (increment == 0) return;
    var payload: [4]u8 = .{
        @intCast((increment >> 24) & 0x7F),
        @intCast((increment >> 16) & 0xFF),
        @intCast((increment >> 8) & 0xFF),
        @intCast(increment & 0xFF),
    };
    try writeFrame(stream, H2_WINDOW_UPDATE, 0, stream_id, &payload);
}

/// Read ONE complete gRPC message off the HTTP/2 stream, reassembling it from
/// however many DATA frames the peer fragmented it into (a reply larger than its
/// SETTINGS_MAX_FRAME_SIZE MUST span multiple frames). Returns the message
/// payload WITHOUT its 5-byte gRPC length prefix, or null at end of stream.
///
/// The peer sends each gRPC message as its own DATA-frame run (it never packs
/// two messages into one frame), so a run of DATA frames accumulates to exactly
/// one message with no trailing bytes to carry over between calls.
pub fn readResponse(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    hooks: ProgressHooks,
) !?[]u8 {
    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);

    while (true) {
        const frame = readFrame(allocator, stream, hooks) catch |err| {
            if (err == error.ConnectionClosed) return null;
            return err;
        };
        const frame_type = frame.frame_type;
        const flags = frame.flags;
        const payload = frame.payload;

        if (frame_type == H2_DATA) {
            if (payload.len > 0) {
                // Replenish flow-control credit for the bytes just received so a
                // large streamed response is not stalled by the connection-level
                // (stream 0) window default of 65535.
                sendWindowUpdate(stream, 0, @intCast(payload.len)) catch {};
                sendWindowUpdate(stream, frame.stream_id, @intCast(payload.len)) catch {};
                msg_buf.appendSlice(allocator, payload) catch {
                    allocator.free(payload);
                    return error.OutOfMemory;
                };
            }
            const end_stream = (flags & 0x1) != 0;
            allocator.free(payload);

            if (msg_buf.items.len >= 5) {
                const msg_len: usize = (@as(usize, msg_buf.items[1]) << 24) |
                    (@as(usize, msg_buf.items[2]) << 16) |
                    (@as(usize, msg_buf.items[3]) << 8) |
                    @as(usize, msg_buf.items[4]);
                if (msg_buf.items.len >= 5 + msg_len) {
                    const result = try allocator.alloc(u8, msg_len);
                    @memcpy(result, msg_buf.items[5 .. 5 + msg_len]);
                    return result;
                }
            }
            // Message not complete yet; keep accumulating unless the stream ends.
            if (end_stream) return null;
            continue;
        }

        if (frame_type == H2_HEADERS) {
            const end_stream = (flags & 0x1) != 0;
            allocator.free(payload);
            // Trailers (END_STREAM HEADERS) close the stream. Any partially
            // accumulated message was truncated — surface end of stream.
            if (end_stream) return null;
            continue;
        }

        if (frame_type == H2_SETTINGS) {
            if ((flags & 0x1) == 0) {
                applyPeerSettings(payload);
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
    stream: std.Io.net.Stream,
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
    stream: std.Io.net.Stream,
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
    stream: std.Io.net.Stream,
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
            .read_only = opts.read_only,
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
