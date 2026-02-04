const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const util = @import("proto_test_util.zig");

const RunResult = struct { code: i32, out: []u8, err: []u8 };

fn run(allocator: std.mem.Allocator, args: []const []const u8) !RunResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append("query");
    }
    try argv.appendSlice(args[1..]);
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

fn extract_rows_array(allocator: std.mem.Allocator, out: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    const newline_idx = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = trimmed[0..newline_idx];
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.Malformed;
    defer parsed.deinit();
    const rows_val = parsed.value.object.get("rows") orelse return error.MissingRows;
    return std.json.Stringify.valueAlloc(allocator, rows_val, .{});
}

// Normalize rows array by splitting row objects and lex-sorting them, to ignore order.
fn normalize_rows(allocator: std.mem.Allocator, rows_json: []const u8) ![]u8 {
    // rows_json is like: [ {"r":"n"},{"r":"t"},{"r":"f"} ]
    var rows = std.ArrayList([]const u8).init(allocator);
    defer rows.deinit();
    var i: usize = 0;
    if (rows_json.len < 2 or rows_json[0] != '[' or rows_json[rows_json.len - 1] != ']') return error.Malformed;
    i += 1; // skip '['
    const end = rows_json.len - 1; // position of ']'
    while (i < end) {
        // skip separators and whitespace
        while (i < end and (rows_json[i] == ' ' or rows_json[i] == '\n' or rows_json[i] == ',')) i += 1;
        if (i >= end) break;
        if (rows_json[i] != '{') return error.Malformed;
        const obj_start = i;
        var depth: usize = 0;
        while (i < end) : (i += 1) {
            if (rows_json[i] == '{') depth += 1;
            if (rows_json[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (depth != 0) return error.Malformed;
        const obj = rows_json[obj_start..i];
        try rows.append(obj);
    }
    // sort lexicographically
    const slice = try rows.toOwnedSlice();
    defer allocator.free(slice);
    std.sort.block([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    // join with commas inside brackets
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.append('[');
    for (slice, 0..) |obj, idx| {
        if (idx > 0) try out.appendSlice(",");
        try out.appendSlice(obj);
    }
    try out.append(']');
    return out.toOwnedSlice();
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity CASE 3VL"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_Case3VL; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity QUIC (CASE 3VL)" {
    util.testStart("transport parity QUIC (CASE 3VL)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    const q = "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r";
    const param = "[null,true,false]";

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(300 * std.time.ns_per_ms);

    util.progress("Running first query...", .{});
    const qres = try run(allocator, &.{ exe, q, "--param", "a", param, "--server", addr, "--format", "json" });
    defer allocator.free(qres.out);
    defer allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows_array(allocator, qres.out);
    const qnorm = try normalize_rows(allocator, qrows);
    defer allocator.free(qrows);
    defer allocator.free(qnorm);

    util.progress("Running second query...", .{});
    const qres2 = try run(allocator, &.{ exe, q, "--param", "a", param, "--server", addr, "--format", "json" });
    defer allocator.free(qres2.out);
    defer allocator.free(qres2.err);
    try std.testing.expectEqual(@as(i32, 0), qres2.code);
    const qrows2 = try extract_rows_array(allocator, qres2.out);
    const qnorm2 = try normalize_rows(allocator, qrows2);
    defer allocator.free(qrows2);
    defer allocator.free(qnorm2);

    util.progress("Comparing results...", .{});
    try std.testing.expect(std.mem.eql(u8, qnorm, qnorm2));

    util.testPass();
}
