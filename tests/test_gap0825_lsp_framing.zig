// GAP-0825: LSP Content-Length / JSON transport framing conformance tests.
//
// These tests drive the REAL framer (`src/cli/lsp/framer.zig`) — the exact
// code the stdio and TCP transports use to parse Content-Length-framed
// JSON-RPC traffic. They do NOT reimplement the parser. The fixture is a
// slice-backed reader that hands out bytes in configurable chunk sizes so the
// incremental / partial-read paths are exercised the same way an OS pipe would
// deliver them.
//
// Coverage:
//   - valid Content-Length round-trip (write-side header + read-side parse)
//   - header name case-insensitivity (LSP/HTTP headers are case-insensitive)
//   - missing Content-Length -> clean MissingContentLength error (no panic)
//   - zero-length body
//   - oversized declared length -> bounded by MAX_LSP_MESSAGE (no huge alloc)
//   - two messages back-to-back in one buffer -> both parse
//   - partial header split across reads (chunk=1) -> still parses
//   - unknown extra headers (Content-Type) tolerated
//
// CANARY: REQ=REQ-LSP-SEC-001; FEATURE="ContentLengthFramingConformance"; ASPECT=ProtocolConformance; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;
const framer = @import("framer");

/// Slice-backed reader that hands out at most `chunk` bytes per read call.
/// `chunk = 1` simulates a byte-at-a-time pipe so the partial-header and
/// partial-body incremental paths are fully exercised.
const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,
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

/// Build a Content-Length-framed message into an arena-owned slice. `header`
/// lets a test inject a custom header block (must include the terminating
/// blank line). When null, the canonical `Content-Length: N\r\n\r\n` is used.
fn frame(alloc: std.mem.Allocator, body: []const u8, header: ?[]const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    if (header) |h| {
        try buf.appendSlice(alloc, h);
    } else {
        const h = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n", .{body.len});
        defer alloc.free(h);
        try buf.appendSlice(alloc, h);
    }
    try buf.appendSlice(alloc, body);
    return buf.toOwnedSlice(alloc);
}

test "GAP-0825: valid Content-Length round-trip" {
    const alloc = testing.allocator;
    const body_text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    const msg = try frame(alloc, body_text, null);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}

test "GAP-0825: header name is case-insensitive (content-length lowercase)" {
    const alloc = testing.allocator;
    const body_text = "{\"x\":1}";
    const header = try std.fmt.allocPrint(alloc, "content-length: {d}\r\n\r\n", .{body_text.len});
    defer alloc.free(header);
    const msg = try frame(alloc, body_text, header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}

test "GAP-0825: header name case-insensitive (CONTENT-LENGTH uppercase)" {
    const alloc = testing.allocator;
    const body_text = "{\"y\":2}";
    const header = try std.fmt.allocPrint(alloc, "CONTENT-LENGTH: {d}\r\n\r\n", .{body_text.len});
    defer alloc.free(header);
    const msg = try frame(alloc, body_text, header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}

test "GAP-0825: missing Content-Length -> clean error (no panic, no hang)" {
    const alloc = testing.allocator;
    const header = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n";
    const msg = try frame(alloc, "ignored", header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.MissingContentLength, f.readMessage(framer.MAX_LSP_MESSAGE, alloc));
}

test "GAP-0825: zero-length body parses to empty slice" {
    const alloc = testing.allocator;
    const msg = try frame(alloc, "", null);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqual(@as(usize, 0), body.len);
}

test "GAP-0825: oversized declared length rejected before allocation" {
    const alloc = testing.allocator;
    // 999999999999 bytes — far above the 16 MiB cap. Must be rejected at the
    // header stage WITHOUT attempting a 1 TB allocation.
    const header = "Content-Length: 999999999999\r\n\r\n";
    const msg = try frame(alloc, "", header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.InvalidContentLength, f.readMessage(framer.MAX_LSP_MESSAGE, alloc));
}

test "GAP-0825: exactly-at-cap declared length is accepted by the bound check" {
    const alloc = testing.allocator;
    // We do NOT allocate 16 MiB of body here; we only assert the cap check
    // admits the value and then fails at the body read (EndOfStream) rather
    // than at the InvalidContentLength gate — proving the boundary is `>` not `>=`.
    const header = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n", .{framer.MAX_LSP_MESSAGE});
    defer alloc.free(header);
    const msg = try frame(alloc, "", header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.EndOfStream, f.readMessage(framer.MAX_LSP_MESSAGE, alloc));
}

test "GAP-0825: two messages back-to-back in one buffer both parse" {
    const alloc = testing.allocator;
    const a = "{\"id\":1}";
    const b = "{\"id\":2}";
    const m1 = try frame(alloc, a, null);
    defer alloc.free(m1);
    const m2 = try frame(alloc, b, null);
    defer alloc.free(m2);

    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(alloc);
    try combined.appendSlice(alloc, m1);
    try combined.appendSlice(alloc, m2);

    var reader = SliceReader{ .data = combined.items };
    var f = framer.Framer.init(SliceReader.read, &reader);

    const body1 = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body1);
    try testing.expectEqualStrings(a, body1);

    const body2 = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body2);
    try testing.expectEqualStrings(b, body2);
}

test "GAP-0825: partial header split across reads (chunk=1) still parses" {
    const alloc = testing.allocator;
    const body_text = "{\"split\":true}";
    const msg = try frame(alloc, body_text, null);
    defer alloc.free(msg);

    // One byte per read — the header arrives one character at a time across
    // many refills, the body crosses arbitrary boundaries.
    var reader = SliceReader{ .data = msg, .chunk = 1 };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}

test "GAP-0825: unknown extra headers (Content-Type) tolerated alongside Content-Length" {
    const alloc = testing.allocator;
    const body_text = "{\"ok\":1}";
    const header = try std.fmt.allocPrint(
        alloc,
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: {d}\r\nX-Custom: whatever\r\n\r\n",
        .{body_text.len},
    );
    defer alloc.free(header);
    const msg = try frame(alloc, body_text, header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}

test "GAP-0825: non-numeric Content-Length value rejected" {
    const alloc = testing.allocator;
    const header = "Content-Length: notanumber\r\n\r\n";
    const msg = try frame(alloc, "", header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    try testing.expectError(framer.FramerError.InvalidContentLength, f.readMessage(framer.MAX_LSP_MESSAGE, alloc));
}

test "GAP-0825: header with extra whitespace after colon parses" {
    const alloc = testing.allocator;
    const body_text = "{\"ws\":1}";
    // Multiple spaces after the colon (lenient OWS per RFC 7230 §3.2).
    const header = try std.fmt.allocPrint(alloc, "Content-Length:   {d}\r\n\r\n", .{body_text.len});
    defer alloc.free(header);
    const msg = try frame(alloc, body_text, header);
    defer alloc.free(msg);

    var reader = SliceReader{ .data = msg };
    var f = framer.Framer.init(SliceReader.read, &reader);
    const body = try f.readMessage(framer.MAX_LSP_MESSAGE, alloc);
    defer alloc.free(body);

    try testing.expectEqualStrings(body_text, body);
}
