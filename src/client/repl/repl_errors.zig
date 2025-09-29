const std = @import("std");

pub const ErrorCode = enum(u16) {
    no_tty = 2,
    connect_fail = 1001,
    auth_fail = 1002,
    query_error = 1003,
    parse_error = 1004,
    unknown_command = 2001,
    usage_error = 2002,
    file_not_found = 2003,
    not_implemented = 2004,
    internal_error = 9999,
};

pub fn printError(writer: anytype, code: ErrorCode, message: []const u8, verbose: bool) !void {
    const code_num = @intFromEnum(code);

    if (verbose) {
        try writer.print("Error [GEODE-E{d:0>4}]: {s}\n", .{ code_num, message });

        // Add additional context for specific errors
        switch (code) {
            .no_tty => try writer.print("  The interactive shell requires a terminal (TTY) for input.\n", .{}),
            .connect_fail => try writer.print("  Check that the server is running and the address is correct.\n", .{}),
            .auth_fail => try writer.print("  Verify your credentials and permissions.\n", .{}),
            .query_error => try writer.print("  Check the GQL syntax and referenced entities.\n", .{}),
            .parse_error => try writer.print("  The input could not be parsed as valid GQL.\n", .{}),
            .unknown_command => try writer.print("  Use \\help to see available commands.\n", .{}),
            .usage_error => try writer.print("  Check the command syntax and required arguments.\n", .{}),
            .file_not_found => try writer.print("  Verify the file path and permissions.\n", .{}),
            .not_implemented => try writer.print("  This feature is not yet available.\n", .{}),
            .internal_error => try writer.print("  An unexpected error occurred. Please report this issue.\n", .{}),
        }
    } else {
        try writer.print("Error [GEODE-E{d:0>4}]: {s}\n", .{ code_num, message });
    }
}

pub fn formatGqlError(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "Query failed: {s}", .{@errorName(err)});
}

test "dispatcher unknown meta" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const writer = output.writer();
    try printError(writer, .unknown_command, "Unknown command '\\connet'. Did you mean '\\connect'?", false);

    try std.testing.expectEqualStrings("Error [GEODE-E2001]: Unknown command '\\connet'. Did you mean '\\connect'?\n", output.items);
}
