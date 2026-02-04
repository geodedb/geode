const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

const RunResult = struct { code: i32, out: []u8, err: []u8 };

fn run(args: []const []const u8) !RunResult {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
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

fn run_server(args: []const []const u8) !struct { child: Child } {
    const allocator = std.testing.allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env;
    try child.spawn();
    return .{ .child = child };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics US001"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_US001; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity diagnostics (US001) QUIC (gated)" {

    const exe = "./zig-out/bin/geode";
    const q = "RETURN 1 LIMIT 10 OFFSET 5";

    var server = try run_server(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17667", "--result-format", "json" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const qres = try run(&.{ exe, q, "--server", "127.0.0.1:17667", "--format", "json" });
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 2), qres.code);
    try std.testing.expect(contains(qres.err, "US001"));
    try std.testing.expect(contains(qres.err, "16.18"));

    const qres2 = try run(&.{ exe, q, "--server", "127.0.0.1:17667", "--format", "json" });
    defer std.testing.allocator.free(qres2.out);
    defer std.testing.allocator.free(qres2.err);
    try std.testing.expectEqual(@as(i32, 2), qres2.code);
    try std.testing.expect(contains(qres2.err, "US001"));
    try std.testing.expect(contains(qres2.err, "16.18"));
}
