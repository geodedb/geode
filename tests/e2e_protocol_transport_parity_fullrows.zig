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
    const out = try child.stdout.?.readToEndAlloc(allocator, 4 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn extract_rows(out: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    var rows_line: ?[]const u8 = null;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null) {
            rows_line = line;
            break;
        }
    }
    if (rows_line == null) return error.MissingBindings;
    const line = rows_line.?;
    const start = std.mem.indexOf(u8, line, "\"rows\":").? + 7;
    const end = start + (std.mem.indexOfPos(u8, line, start, "]}") orelse return error.Malformed);
    return line[start .. end + 1];
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Full Rows"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_FullRows; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity full-rows stdio vs QUIC (gated)" {
    // Gate to avoid flaky vendor QUIC teardown in default runs
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const exe = "./zig-out/bin/geode";
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 10";

    const sres = try run(&.{ exe, q, "--format", "json" });
    defer std.testing.allocator.free(sres.out);
    defer std.testing.allocator.free(sres.err);
    try std.testing.expectEqual(@as(i32, 0), sres.code);
    const srows = try extract_rows(sres.out);

    var env = try std.process.getEnvMap(std.testing.allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen-quic", "127.0.0.1:17663", "--result-format", "json" }, std.testing.allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    std.Thread.sleep(400 * std.time.ns_per_ms);

    const qres = try run(&.{ exe, q, "--server", "127.0.0.1:17663", "--quic", "--format", "json" });
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows(qres.out);

    try std.testing.expect(std.mem.eql(u8, srows, qrows));
}
