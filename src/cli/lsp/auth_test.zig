// Task 10 of the LSP permission-aware completion plan.
//
// Tests the `initializeOptions.geode.*` parser. `verify()` is Task 11
// and is intentionally NOT exercised here.

const std = @import("std");
const testing = std.testing;
const auth = @import("auth.zig");

test "AuthState.fromInitializeOptions parses geode.authToken" {
    const alloc = testing.allocator;
    const init_opts =
        \\{"geode":{"authToken":"eyJhbGciOi.test.signature","graph":"trade","tenant":"tA"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, init_opts, .{});
    defer parsed.deinit();
    var state = try auth.AuthState.fromInitializeOptions(alloc, parsed.value);
    defer state.deinit(alloc);
    try testing.expectEqualStrings("eyJhbGciOi.test.signature", state.token);
    try testing.expectEqualStrings("trade", state.graph orelse "");
    try testing.expectEqualStrings("tA", state.tenant_id orelse "");
}

test "AuthState.fromInitializeOptions errors on missing token" {
    const alloc = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    try testing.expectError(
        auth.AuthError.MissingToken,
        auth.AuthState.fromInitializeOptions(alloc, parsed.value),
    );
}
