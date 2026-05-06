// LSP Framer tests
// Covers F-04 (buffered stdin reader: O(1) syscalls per body, not O(n)).
//
// CANARY: REQ=REQ-PERF-F-04; FEATURE="BufferedTransport"; ASPECT=Throughput; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const framer = @import("framer.zig");

/// Test fixture — a slice-backed reader that hands out bytes in
/// configurable chunk sizes and counts each read.
const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// Maximum bytes returned per read call. The framer should
    /// nevertheless complete each parse with O(1) read calls regardless
    /// of this granularity (within reason). Default: very large so the
    /// framer's first refill grabs everything.
    chunk: usize = 1024 * 1024,

    fn read(ctx: *anyopaque, dest: []u8) framer.FramerError!usize {
        const self: *SliceReader = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.data.len) return 0;
        const remaining = self.data.len - self.pos;
        const take = @min(@min(dest.len, remaining), self.chunk);
        @memcpy(dest[0..take], self.data[self.pos .. self.pos + take]);
        self.pos += take;
        return take;
    }
};

test "F-04: 1024-byte body completes in <= 4 read calls" {
    const allocator = testing.allocator;
    var body_buf: [1024]u8 = undefined;
    @memset(&body_buf, 'a');
    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, "Content-Length: 1024\r\n\r\n");
    try msg.appendSlice(allocator, &body_buf);

    var reader = SliceReader{ .data = msg.items };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, testing.allocator);
    defer testing.allocator.free(body);

    try testing.expectEqual(@as(usize, 1024), body.len);
    // The whole 1048-byte message fits in one refill (4 KiB buffer).
    // Target: 1 read call. Ceiling: 4 (header refill + body
    // boundary-cross + 2 extra rounds for arbitrary chunking).
    try testing.expect(f.read_calls <= 4);
}

test "F-04: 8 KiB body completes in <= 4 read calls" {
    const allocator = testing.allocator;
    const body_size: usize = 8 * 1024;
    const body_buf = try allocator.alloc(u8, body_size);
    defer allocator.free(body_buf);
    @memset(body_buf, 'a');

    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    {
        const hdr = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body_size});
        defer allocator.free(hdr);
        try msg.appendSlice(allocator, hdr);
    }
    try msg.appendSlice(allocator, body_buf);

    var reader = SliceReader{ .data = msg.items };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, allocator);
    defer allocator.free(body);

    try testing.expectEqual(body_size, body.len);
    // 8 KiB body crosses the 4 KiB buffer boundary exactly once;
    // header refill + body refill ≤ 4.
    try testing.expect(f.read_calls <= 4);
}

test "F-04: chunked stream still respects amortization (chunk=64)" {
    const allocator = testing.allocator;
    const body_size: usize = 1024;
    const body_buf = try allocator.alloc(u8, body_size);
    defer allocator.free(body_buf);
    @memset(body_buf, 'a');

    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    {
        const hdr = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body_size});
        defer allocator.free(hdr);
        try msg.appendSlice(allocator, hdr);
    }
    try msg.appendSlice(allocator, body_buf);

    // Stream 64 bytes per OS call. Total bytes ≈ 1048; expected reads
    // ≈ ceil(1048/64) ≈ 17. Without buffering it would have been one
    // per byte (≈1048 reads).
    var reader = SliceReader{ .data = msg.items, .chunk = 64 };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, allocator);
    defer allocator.free(body);

    try testing.expectEqual(body_size, body.len);
    try testing.expect(f.read_calls <= 32);
}

test "F-04: oversized Content-Length rejected before body alloc" {
    const allocator = testing.allocator;
    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    // 17 MiB > MAX_LSP_MESSAGE (16 MiB).
    {
        const hdr = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{17 * 1024 * 1024});
        defer allocator.free(hdr);
        try msg.appendSlice(allocator, hdr);
    }

    var reader = SliceReader{ .data = msg.items };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.InvalidContentLength, f.readMessage(framer.MAX_LSP_MESSAGE, allocator));
}

test "F-04: missing Content-Length header rejected" {
    const allocator = testing.allocator;
    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, "Content-Type: text/plain\r\n\r\n");

    var reader = SliceReader{ .data = msg.items };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.MissingContentLength, f.readMessage(framer.MAX_LSP_MESSAGE, allocator));
}

test "F-04: EOF on first read returns EndOfStream" {
    const allocator = testing.allocator;
    var reader = SliceReader{ .data = "" };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.EndOfStream, f.readMessage(framer.MAX_LSP_MESSAGE, allocator));
}

test "F-04: EOF mid-body returns EndOfStream" {
    const allocator = testing.allocator;
    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, "Content-Length: 100\r\n\r\nshort");

    var reader = SliceReader{ .data = msg.items };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.EndOfStream, f.readMessage(framer.MAX_LSP_MESSAGE, allocator));
}

test "F-04: round-trip preserves body bytes exactly" {
    const allocator = testing.allocator;
    const body_text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";

    var msg = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer msg.deinit(allocator);
    {
        const hdr = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body_text.len});
        defer allocator.free(hdr);
        try msg.appendSlice(allocator, hdr);
    }
    try msg.appendSlice(allocator, body_text);

    var reader = SliceReader{ .data = msg.items, .chunk = 7 };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, allocator);
    defer allocator.free(body);

    try testing.expectEqualStrings(body_text, body);
}
