//! HELLO-response decode seam for the CLI authentication path.
//!
//! Bug 731 (#2): `geode auth login` prints a `DebugAllocator` leak report on
//! every successful login. The decoded `schema.ServerPacket` wrapper that the
//! HELLO handshake produces (`session_id`, the `capabilities` ArrayList backing
//! store plus one allocation per element, and `graph` when present) is never
//! released — a generated `deinit` exists (`schema.ServerPacket.deinit`) and is
//! simply not called.
//!
//! This module exists so the ownership contract of that decode is reachable
//! from a test binary: `src/cli/main.zig` is only compiled as part of the
//! `geode` executable (root module `src/unified_entry.zig`), so its private
//! `connectToServer` / `readProtoMessageViaZigClient` cannot be driven from
//! `tests/`. `connectToServer` calls straight into this function, so the seam
//! is real rather than a copy.
//
// CANARY: REQ=REQ-AUTH-CLI-HELLO-DECODE-001; FEATURE="CLI QUIC Authentication"; ASPECT=HelloResponseOwnership; STATUS=TESTED; TEST=tests/test_bug731_cli_hello_leak.zig; OWNER=cli; UPDATED=2026-07-31

const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("schema");

/// Result of a successful HELLO handshake. `session_token` is owned by the
/// caller and must be freed with the same allocator.
pub const AuthResult = struct {
    session_token: []const u8,
    requires_password_reset: bool = false,
};

/// Decode a framed HELLO response body (the protobuf payload, length prefix
/// already stripped) into an `AuthResult`.
///
/// Ownership contract: every allocation made from `allocator` during the decode
/// other than the returned `session_token` MUST be released before returning.
pub fn decodeHelloAuthResult(allocator: std.mem.Allocator, frame_body: []const u8) !AuthResult {
    var reader: std.Io.Reader = .fixed(frame_body);
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    const resp = packet.quic orelse return error.InvalidMessage;
    switch (resp) {
        .hello => |h| {
            if (!h.success) {
                std.debug.print("Authentication failed: {s}\n", .{h.error_message});
                return error.InvalidCredentials;
            }
            return AuthResult{
                .session_token = try allocator.dupe(u8, h.session_id),
                .requires_password_reset = false,
            };
        },
        else => return error.ProtocolError,
    }
}
