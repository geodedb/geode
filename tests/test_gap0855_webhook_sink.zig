//! GAP-0855a regression: the webhook CDC sink must perform REAL HTTP delivery
//! (method/path/content-type/auth header/body), retry on transient 5xx with
//! bounded backoff, and surface a delivery failure when retries are exhausted
//! (no silent drop).
//!
//! The test stands up a real loopback TCP listener that speaks just enough
//! HTTP/1.1 to parse the POST request the sink sends and to answer with a
//! scripted sequence of status codes. This is a genuine socket fixture (not a
//! mock of the sink); the sink's std.http.Client drives the real wire.
//!
//! Loopback delivery requires GEODE_WEBHOOK_ALLOW_PRIVATE=1 (the production
//! SSRF guard blocks private hosts). The test sets it for the duration.

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const webhook_sink = geode.streaming.sinks.webhook_sink;
const cdc_sinks = geode.streaming.cdc_sinks;
const WebhookSink = webhook_sink.WebhookSink;
const WebhookConfig = webhook_sink.WebhookConfig;
const ChangeEvent = cdc_sinks.ChangeEvent;

const io = std.Io.Threaded.global_single_threaded.io();

/// What the in-test listener captured from the first received request.
const Captured = struct {
    method: [16]u8 = [_]u8{0} ** 16,
    method_len: usize = 0,
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,
    content_type: [128]u8 = [_]u8{0} ** 128,
    content_type_len: usize = 0,
    authorization: [256]u8 = [_]u8{0} ** 256,
    authorization_len: usize = 0,
    body: [4096]u8 = [_]u8{0} ** 4096,
    body_len: usize = 0,

    fn methodSlice(self: *const Captured) []const u8 {
        return self.method[0..self.method_len];
    }
    fn pathSlice(self: *const Captured) []const u8 {
        return self.path[0..self.path_len];
    }
    fn contentTypeSlice(self: *const Captured) []const u8 {
        return self.content_type[0..self.content_type_len];
    }
    fn authSlice(self: *const Captured) []const u8 {
        return self.authorization[0..self.authorization_len];
    }
    fn bodySlice(self: *const Captured) []const u8 {
        return self.body[0..self.body_len];
    }
};

/// A scripted HTTP listener: serves `status_script` in order across accepted
/// connections, capturing the request of the connection indexed by
/// `capture_index`. Runs on its own OS thread.
const ScriptedListener = struct {
    server: std.Io.net.Server,
    port: u16,
    status_script: []const u16,
    capture_index: usize,
    captured: Captured = .{},
    accepted: usize = 0,
    err: ?anyerror = null,
    thread: ?std.Thread = null,

    fn start(status_script: []const u16, capture_index: usize) !*ScriptedListener {
        const self = try std.testing.allocator.create(ScriptedListener);
        errdefer std.testing.allocator.destroy(self);

        // Bind to an ephemeral loopback port. Probe a range so we have a known
        // port to hand to the sink (no getsockname dependency).
        var port: u16 = 0;
        var server: std.Io.net.Server = undefined;
        var p: u16 = 38080;
        while (p < 38980) : (p += 1) {
            const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
            server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch {
                continue;
            };
            port = p;
            break;
        }
        if (port == 0) return error.NoFreePort;

        self.* = .{
            .server = server,
            .port = port,
            .status_script = status_script,
            .capture_index = capture_index,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn stop(self: *ScriptedListener) void {
        if (self.thread) |t| t.join();
        self.server.deinit(io);
        std.testing.allocator.destroy(self);
    }

    fn run(self: *ScriptedListener) void {
        for (self.status_script, 0..) |status, idx| {
            const stream = self.server.accept(io) catch |e| {
                self.err = e;
                return;
            };
            self.handleConn(stream, status, idx) catch |e| {
                self.err = e;
                stream.close(io);
                return;
            };
            stream.close(io);
            self.accepted += 1;
        }
    }

    fn handleConn(self: *ScriptedListener, stream: std.Io.net.Stream, status: u16, idx: usize) !void {
        var rbuf: [8192]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        const r = &reader.interface;

        // Read the request head (up to the blank line) and parse headers to find
        // Content-Length so we can read the exact body.
        var head_buf: [8192]u8 = undefined;
        var head_len: usize = 0;
        var content_length: usize = 0;
        var cap: Captured = .{};

        // Read header lines until an empty line.
        var first_line = true;
        while (true) {
            const line = readLine(r, head_buf[head_len..]) catch |e| return e;
            const consumed = line.len + 2; // include CRLF accounting handled in readLine return
            _ = consumed;
            if (line.len == 0) break; // blank line terminates head
            head_len += line.len;
            if (first_line) {
                first_line = false;
                parseRequestLine(line, &cap);
            } else {
                if (asciiHeaderIs(line, "content-length")) {
                    const v = headerValue(line);
                    content_length = std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch 0;
                } else if (asciiHeaderIs(line, "content-type")) {
                    copyInto(&cap.content_type, &cap.content_type_len, std.mem.trim(u8, headerValue(line), " "));
                } else if (asciiHeaderIs(line, "authorization")) {
                    copyInto(&cap.authorization, &cap.authorization_len, std.mem.trim(u8, headerValue(line), " "));
                }
            }
        }

        // Read exactly content_length bytes of body.
        if (content_length > 0 and content_length <= cap.body.len) {
            try r.readSliceAll(cap.body[0..content_length]);
            cap.body_len = content_length;
        }

        if (idx == self.capture_index) self.captured = cap;

        // Write the scripted response.
        var wbuf: [256]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 {d} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status});
        try w.flush();
    }

    /// Read one CRLF-terminated line into dest, returning the line WITHOUT CRLF.
    fn readLine(r: *std.Io.Reader, dest: []u8) ![]const u8 {
        var n: usize = 0;
        while (true) {
            const b = try r.takeByte();
            if (b == '\r') {
                const nl = try r.takeByte();
                if (nl != '\n') return error.BadLine;
                return dest[0..n];
            }
            if (n >= dest.len) return error.LineTooLong;
            dest[n] = b;
            n += 1;
        }
    }
};

fn parseRequestLine(line: []const u8, cap: *Captured) void {
    // METHOD SP PATH SP VERSION
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return;
    copyInto(&cap.method, &cap.method_len, line[0..sp1]);
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    copyInto(&cap.path, &cap.path_len, rest[0..sp2]);
}

fn asciiHeaderIs(line: []const u8, name: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const hdr = line[0..colon];
    if (hdr.len != name.len) return false;
    for (hdr, name) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

fn headerValue(line: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return "";
    return line[colon + 1 ..];
}

fn copyInto(dst: []u8, dst_len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst_len.* = n;
}

fn makeEvent(allocator: std.mem.Allocator) ChangeEvent {
    return .{
        .timestamp = 1234,
        .transaction_id = 7,
        .sequence = 42,
        .change_type = .insert,
        .entity_type = .node,
        .entity_id = 100,
        .before = null,
        .after = "{\"name\":\"alice\"}",
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setAllowPrivate() void {
    if (builtin.os.tag != .windows) {
        _ = setenv("GEODE_WEBHOOK_ALLOW_PRIVATE", "1", 1);
    }
}

fn unsetAllowPrivate() void {
    if (builtin.os.tag != .windows) {
        _ = unsetenv("GEODE_WEBHOOK_ALLOW_PRIVATE");
    }
}

test "GAP-0855a webhook sink performs real HTTP POST with auth header and exact body" {
    setAllowPrivate();
    defer unsetAllowPrivate();

    const status_script = [_]u16{200};
    var listener = try ScriptedListener.start(&status_script, 0);
    defer listener.stop();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/cdc-hook", .{listener.port});
    defer std.testing.allocator.free(url);

    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    try headers.put("Authorization", "Bearer secret-token-123");

    const config = WebhookConfig{
        .url = url,
        .timeout_ms = 5000,
        .retry_count = 3,
        .headers = headers,
        .base_backoff_ms = 1,
    };

    var sink = WebhookSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent(std.testing.allocator)};
    try sink.send(&events);

    // Listener thread joined in stop(); but we read captured after join in stop().
    // We must assert before stop() joins — so explicitly join here.
    if (listener.thread) |t| {
        t.join();
        listener.thread = null;
    }
    if (listener.err) |e| {
        std.debug.print("listener error: {s}\n", .{@errorName(e)});
        return error.ListenerFailed;
    }

    const cap = &listener.captured;
    try std.testing.expectEqualStrings("POST", cap.methodSlice());
    try std.testing.expectEqualStrings("/cdc-hook", cap.pathSlice());
    try std.testing.expectEqualStrings("application/json", cap.contentTypeSlice());
    try std.testing.expectEqualStrings("Bearer secret-token-123", cap.authSlice());

    // Body is the JSON array of events.
    const body = cap.bodySlice();
    try std.testing.expect(std.mem.startsWith(u8, body, "["));
    try std.testing.expect(std.mem.endsWith(u8, body, "]"));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seq\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"after\":{\"name\":\"alice\"}") != null);
}

test "GAP-0855a webhook sink retries on transient 5xx then succeeds" {
    setAllowPrivate();
    defer unsetAllowPrivate();

    // First attempt 500, second attempt 200.
    const status_script = [_]u16{ 500, 200 };
    var listener = try ScriptedListener.start(&status_script, 1);
    defer listener.stop();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hook", .{listener.port});
    defer std.testing.allocator.free(url);

    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();

    const config = WebhookConfig{
        .url = url,
        .timeout_ms = 5000,
        .retry_count = 3,
        .headers = headers,
        .base_backoff_ms = 1,
    };

    var sink = WebhookSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent(std.testing.allocator)};
    try sink.send(&events); // should succeed on the 2nd attempt

    if (listener.thread) |t| {
        t.join();
        listener.thread = null;
    }
    try std.testing.expect(listener.err == null);
    try std.testing.expectEqual(@as(usize, 2), listener.accepted);
}

test "GAP-0855a webhook sink surfaces failure after exhausting retries" {
    setAllowPrivate();
    defer unsetAllowPrivate();

    // Always 500 across all allowed attempts.
    const status_script = [_]u16{ 500, 500 };
    var listener = try ScriptedListener.start(&status_script, 0);
    defer listener.stop();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hook", .{listener.port});
    defer std.testing.allocator.free(url);

    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();

    const config = WebhookConfig{
        .url = url,
        .timeout_ms = 5000,
        .retry_count = 2,
        .headers = headers,
        .base_backoff_ms = 1,
    };

    var sink = WebhookSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent(std.testing.allocator)};
    const result = sink.send(&events);
    try std.testing.expectError(error.WebhookSendFailed, result);

    if (listener.thread) |t| {
        t.join();
        listener.thread = null;
    }
    try std.testing.expectEqual(@as(usize, 2), listener.accepted);
}
