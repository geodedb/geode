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

fn run_with_retries(args: []const []const u8, attempts: usize, backoff_ms: u64) !RunResult {
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        const res = try run(args);
        if (res.code == 0) return res;
        // Sleep then retry
        std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
        // Free buffers before next attempt
        std.testing.allocator.free(res.out);
        std.testing.allocator.free(res.err);
    }
    // Final attempt result if still failing
    return run(args);
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

fn extract_bindings_line(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null) return line;
    }
    return null;
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Ordered Rows"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_STDIOverQUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity stdio vs QUIC (ordered rows equal)" {
    // Gate to avoid flaky vendor QUIC teardown in default runs
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const exe = "./zig-out/bin/geode";
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 10";

    // stdio path
    const sres = try run(&.{ exe, q, "--format", "json" });
    defer std.testing.allocator.free(sres.out);
    defer std.testing.allocator.free(sres.err);
    try std.testing.expectEqual(@as(i32, 0), sres.code);
    const sline = extract_bindings_line(sres.out) orelse return error.InvalidTestState;

    // QUIC path
    var server = try run_server(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17662", "--result-format", "json" });
    defer {
        _ = server.child.kill() catch {};
    }
    // Give server time to bind the socket
    std.Thread.sleep(400 * std.time.ns_per_ms);

    const qres = try run_with_retries(&.{ exe, q, "--server", "127.0.0.1:17662", "--quic", "--format", "json" }, 3, 200);
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qline = extract_bindings_line(qres.out) orelse return error.InvalidTestState;

    // Expect exact equality of BINDINGS payload line (ordered scenario)
    try std.testing.expect(std.mem.eql(u8, sline, qline));
}
