// Zig 0.16 compatibility helpers
//
// std.process.getEnvVarOwned was removed in Zig 0.16.
// This provides a compatible wrapper around std.c.getenv.

const std = @import("std");

/// Drop-in replacement for the removed std.process.getEnvVarOwned.
/// Returns an owned copy of the environment variable value, or
/// error.EnvironmentVariableNotFound if not set.
pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    // Allocate a null-terminated copy to pass to C getenv
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    const slice = std.mem.span(ptr);
    return allocator.dupe(u8, slice) catch return error.OutOfMemory;
}
