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

fn find_bindings_line(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null) return line;
    }
    return null;
}

// Extract ordered flag and order_keys array substring for comparison
fn extract_order_meta(line: []const u8) !struct { ordered: bool, keys: []const u8 } {
    const ord_idx = std.mem.indexOf(u8, line, "\"ordered\":") orelse return error.Malformed;
    const ord_val = line[ord_idx + 10 .. ord_idx + 15]; // expects true/false
    const ordered = if (std.mem.startsWith(u8, ord_val, "true")) true else false;
    const keys_idx = std.mem.indexOf(u8, line, "\"order_keys\":") orelse return error.Malformed;
    const start = keys_idx + 13;
    const end = start + (std.mem.indexOfPos(u8, line, start, "]") orelse return error.Malformed);
    return .{ .ordered = ordered, .keys = line[start .. end + 1] };
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Order Metadata"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_OrderMetadata; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity order metadata (ordered + order_keys)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const exe = "./zig-out/bin/geode";
    const q = "RETURN 2 AS a, 1 AS b UNION RETURN 1 AS a, 2 AS b ORDER BY a, b LIMIT 2";

    const sres = try run(&.{ exe, q, "--format", "json" });
    defer std.testing.allocator.free(sres.out);
    defer std.testing.allocator.free(sres.err);
    try std.testing.expectEqual(@as(i32, 0), sres.code);
    const sline = find_bindings_line(sres.out) orelse return error.InvalidTestState;
    const smeta = try extract_order_meta(sline);

    var server = try run_server(&.{ "./zig-out/bin/geode", "serve", "--listen-quic", "127.0.0.1:17666", "--result-format", "json" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const qres = try run(&.{ exe, q, "--server", "127.0.0.1:17666", "--quic", "--format", "json" });
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qline = find_bindings_line(qres.out) orelse return error.InvalidTestState;
    const qmeta = try extract_order_meta(qline);

    try std.testing.expectEqual(smeta.ordered, qmeta.ordered);
    try std.testing.expect(std.mem.eql(u8, smeta.keys, qmeta.keys));
}
