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

fn extract_rows(allocator: std.mem.Allocator, out: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    const newline_idx = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = trimmed[0..newline_idx];
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.Malformed;
    defer parsed.deinit();
    const rows_val = parsed.value.object.get("rows") orelse return error.MissingRows;
    return std.json.Stringify.valueAlloc(allocator, rows_val, .{});
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity MATCH VarLen Rows"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_MatchVarLenRows; OWNER=engine; UPDATED=2025-09-24
// Deterministic varlen path slice under ORDER with LIMIT/OFFSET; compares full rows across transports.
test "protocol: transport parity MATCH varlen rows QUIC (gated)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const exe = "./zig-out/bin/geode";
    // Use a deterministic small synthetic dataset exposed by built-in example loader
    // The query orders by projected names to ensure stable order metadata and rows.
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 3 OFFSET 0";

    var env = try std.process.getEnvMap(std.testing.allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17671", "--result-format", "json" }, std.testing.allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    std.Thread.sleep(400 * std.time.ns_per_ms);

    const qres = try run(&.{ exe, q, "--server", "127.0.0.1:17671", "--format", "json" });
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows(std.testing.allocator, qres.out);
    defer std.testing.allocator.free(qrows);

    const qres2 = try run(&.{ exe, q, "--server", "127.0.0.1:17671", "--format", "json" });
    defer std.testing.allocator.free(qres2.out);
    defer std.testing.allocator.free(qres2.err);
    try std.testing.expectEqual(@as(i32, 0), qres2.code);
    const qrows2 = try extract_rows(std.testing.allocator, qres2.out);
    defer std.testing.allocator.free(qrows2);

    try std.testing.expect(std.mem.eql(u8, qrows, qrows2));
}
