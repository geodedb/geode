const std = @import("std");
const value_types = @import("value_types.zig");

pub const PreValidatedAuth = struct {
    role: []const u8,
};

pub const QueryOptions = struct {
    token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    strict_offset_validation: bool = false,
    param_names: []const []const u8 = &.{},
    param_values: []const value_types.Value = &.{},
    current_graph: ?[]const u8 = null,
    pre_validated_role: ?PreValidatedAuth = null,
    skip_txn_session_file: bool = false,
};

pub fn runQueryWithAuth(_: *std.mem.Allocator, _: []const u8, _: QueryOptions) ![]u8 {
    @compileError("test_harness is disabled in production builds");
}

pub fn runQuery(_: *std.mem.Allocator, _: []const u8) ![]u8 {
    @compileError("test_harness is disabled in production builds");
}

pub fn cleanupTestCatalog() void {
    @compileError("test_harness is disabled in production builds");
}

pub fn ensureEvaluatorInitialized() void {
    @compileError("test_harness is disabled in production builds");
}
