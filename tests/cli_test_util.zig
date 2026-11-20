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
    // Zig 0.16: ArrayList is unmanaged — `.init(allocator)` is gone and the
    // allocator travels with each call (as every other line in this function
    // already does). ENG-3907 (B4): this bit-rot was invisible because the only
    // callers that reach it are the transport-parity smokes, which never
    // compiled (missing module graph) and whose failure the Makefile swallowed.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);

    try addDefaultClientArgs(allocator, &argv, args, addr);

    // Zig 0.16 retired `std.process.Child.init` + `Child.spawn`/`wait` in favor
    // of `std.process.run(gpa, io, RunOptions)`, which spawns, pumps both pipes
    // and reaps in one call. Same behavior as the old spawn/readToEnd/wait
    // sequence, and it cannot deadlock on a full pipe. Matches the 0.16
    // migration `proto_test_util.spawnServer` already carries.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    // SONNY-6782: a release build refuses --insecure without GEODE_ALLOW_INSECURE_TLS=1.
    var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
    defer env.deinit();
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");

    const res = try std.process.run(allocator, threaded.io(), .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    const code: i32 = switch (res.term) {
        .exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = res.stdout, .err = res.stderr };
}
