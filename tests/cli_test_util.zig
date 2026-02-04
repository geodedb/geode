const std = @import("std");
const proto = @import("proto_test_util.zig");

pub const CliResult = struct {
    code: i32,
    out: []u8,
    err: []u8,
};

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn addDefaultClientArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    args: []const []const u8,
    addr: []const u8,
) !void {
    const has_server = hasArg(args, "--server");
    const has_insecure = hasArg(args, "--insecure");
    const has_user = hasArg(args, "--user") or hasArg(args, "-U");
    const has_password = hasArg(args, "--password") or hasArg(args, "-P");
    const has_token = hasArg(args, "--token");

    if (!has_server) {
        try argv.append(allocator, "--server");
        try argv.append(allocator, addr);
    }

    if (!has_insecure) {
        try argv.append(allocator, "--insecure");
    }

    if (!has_token) {
        if (!has_user) {
            try argv.append(allocator, "--user");
            try argv.append(allocator, proto.defaultUsername());
        }
        if (!has_password) {
            try argv.append(allocator, "--password");
            try argv.append(allocator, proto.defaultPassword());
        }
    }
}

pub fn run(args: []const []const u8) !CliResult {
    const allocator = std.testing.allocator;
    var server = try proto.spawnServerRandom(allocator, proto.TestEnv.standard());
    defer server.deinit();

    return runAgainstServer(allocator, server.getAddr(), args);
}

pub fn runAgainstServer(
    allocator: std.mem.Allocator,
    addr: []const u8,
    args: []const []const u8,
) !CliResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);

    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);

    try addDefaultClientArgs(allocator, &argv, args, addr);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}
