//! SONNY-6585: the JSON-RPC error `message` and `data` geode's MCP handlers
//! give for the error they return (mcp v0.1.23 `setErrorDetail`). Without
//! it the client saw the Zig error's name ("InvalidParams") and no data.
//!
//! Call `set` / `setFmt` immediately before returning the error. `data` is
//! any value std.json can stringify (a struct such as `.{ .uri = uri }`);
//! it is serialized with escaping, never spliced into JSON text. The mcp
//! server copies and frees the detail.

const std = @import("std");
const mcp = @import("mcp");

// CANARY: REQ=REQ-SONNY-6585-MCP-ERROR-DETAIL; FEATURE="MCPResultShapes"; ASPECT=ErrorMessageAndData; STATUS=TESTED; TEST=tests/test_sonny6585_mcp_error_detail.zig; OWNER=mcp; UPDATED=2026-11-15

/// Give `message` and `data` (stringified) to the error the handler returns
/// next. If `data` does not serialize to one JSON value (it always should),
/// the message is given alone.
pub fn set(allocator: std.mem.Allocator, message: []const u8, data: anytype) error{OutOfMemory}!void {
    const data_json = try std.json.Stringify.valueAlloc(allocator, data, .{});
    defer allocator.free(data_json);
    mcp.setErrorDetail(allocator, message, data_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidErrorData => mcp.setErrorDetail(allocator, message, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidErrorData => {},
        },
    };
}

/// `set` with a formatted message.
pub fn setFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype, data: anytype) error{OutOfMemory}!void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    return set(allocator, message, data);
}
