//! Bug 731 (#2): `geode auth login` leaks the decoded HELLO response.
//!
//! Reported stack (v0.8.4, identical at HEAD — `git diff v0.8.4..HEAD -- src/`
//! is empty):
//!
//!     error(DebugAllocator): memory address 0x... leaked:
//!       zig-pkg/protobuf-0.1.4/src/wire.zig:955:51  in decodeMessage
//!       zig-pkg/protobuf-0.1.4/src/wire.zig:1260:77 in decodeMessage
//!       src/cli/main.zig:2542:39 in readProtoMessageViaZigClient
//!       src/cli/main.zig:3576:50 in connectToServer
//!       src/cli/cli_dispatcher.zig:312:30 in dispatch
//!
//! Mechanism: the HELLO response is decoded into a `schema.ServerPacket` with
//! the caller's raw allocator and only the `.quic` payload is returned; the
//! wrapper's owned allocations (`session_id`, the `capabilities` ArrayList
//! backing store PLUS one allocation per element — the server always sends
//! "QUIC", "TLS1.3", "PROTOBUF" — and `graph` when present) are never freed.
//! `schema.ServerPacket.deinit` exists and is simply never called. The command
//! still works because `session_id` is separately duped by the caller.
//!
//! These tests drive the real decode seam
//! (`src/client/hello_decode.zig`, which `connectToServer` calls) with
//! `std.testing.allocator`, so a retained allocation fails the test.
//!
//! Adjacent finding covered here: `connectToServer` hardcoded
//! `.requires_password_reset = false`, discarding the
//! `HelloResponse.password_reset_required` the server actually sends — which
//! makes the CLI's own "password reset required" warning dead code.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");

const hello_decode = geode.hello_decode;

/// Server-side capability list as sent by the real server on every HELLO.
const server_capabilities = [_][]const u8{ "QUIC", "TLS1.3", "PROTOBUF" };

/// Encode a `ServerPacket{ .quic = .{ .hello = ... } }` exactly the way the
/// server writes it on the wire (framing/length prefix stripped — the CLI hands
/// the decoder the frame body only).
fn encodeHelloFrame(
    allocator: std.mem.Allocator,
    success: bool,
    session_id: []const u8,
    error_message: []const u8,
    password_reset_required: bool,
    graph: ?[]const u8,
) ![]u8 {
    var caps: std.ArrayList([]const u8) = .empty;
    defer caps.deinit(allocator);
    for (server_capabilities) |cap| try caps.append(allocator, cap);

    const packet = schema.ServerPacket{ .quic = .{ .hello = .{
        .success = success,
        .session_id = session_id,
        .error_message = error_message,
        .capabilities = caps,
        .password_reset_required = password_reset_required,
        .graph = graph,
    } } };

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, packet);
    return allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

// Regression: the exact reported bug. A successful HELLO decode must not retain
// anything except the returned session token.
test "bug731 regression: successful hello decode leaks nothing but the session token" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, true, "sess-abc123", "", false, null);
    defer allocator.free(frame);

    const result = try hello_decode.decodeHelloAuthResult(allocator, frame);
    defer allocator.free(result.session_token);

    try testing.expectEqualStrings("sess-abc123", result.session_token);
    // testing.allocator fails this test if the decoded ServerPacket wrapper
    // (session_id, capabilities backing store + 3 elements) is still held.
}

// Unit: the `graph` field is an extra owned allocation on the same wrapper, so
// a HELLO that carries a bound graph leaks strictly more.
test "bug731: hello decode with bound graph releases the graph allocation" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, true, "sess-graph", "", false, "social");
    defer allocator.free(frame);

    const result = try hello_decode.decodeHelloAuthResult(allocator, frame);
    defer allocator.free(result.session_token);

    try testing.expectEqualStrings("sess-graph", result.session_token);
}

// Unit: empty session_id is the boundary case — the capabilities list is still
// allocated, so the wrapper must still be released.
test "bug731: hello decode with empty session id still releases capabilities" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, true, "", "", false, null);
    defer allocator.free(frame);

    const result = try hello_decode.decodeHelloAuthResult(allocator, frame);
    defer allocator.free(result.session_token);

    try testing.expectEqualStrings("", result.session_token);
}

// Unit: the error path returns early — it must release the wrapper too.
test "bug731: failed hello decode releases the decoded response on the error path" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, false, "", "invalid credentials", false, null);
    defer allocator.free(frame);

    try testing.expectError(
        error.InvalidCredentials,
        hello_decode.decodeHelloAuthResult(allocator, frame),
    );
}

// Unit (adjacent finding): the server's password_reset_required must reach the
// caller instead of being hardcoded to false, otherwise the CLI's post-login
// "password reset required" warning can never fire.
test "bug731: hello decode propagates password_reset_required from the server" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, true, "sess-reset", "", true, null);
    defer allocator.free(frame);

    const result = try hello_decode.decodeHelloAuthResult(allocator, frame);
    defer allocator.free(result.session_token);

    try testing.expect(result.requires_password_reset);
}

// Unit: the negative case for the same field — a server that does NOT require a
// reset must not be reported as requiring one.
test "bug731: hello decode reports no password reset when the server does not ask" {
    const allocator = testing.allocator;

    const frame = try encodeHelloFrame(allocator, true, "sess-noreset", "", false, null);
    defer allocator.free(frame);

    const result = try hello_decode.decodeHelloAuthResult(allocator, frame);
    defer allocator.free(result.session_token);

    try testing.expect(!result.requires_password_reset);
}
