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

fn extract_rows_array(out: []const u8) ![]const u8 {
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
test "protocol: transport parity stdio vs QUIC (CASE 3VL)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const exe = "./zig-out/bin/geode";
    const q = "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r";
    const param = "[null,true,false]";

    const sres = try run(&.{ exe, q, "--json-param", "a", param", "--format", "json" });
    defer std.testing.allocator.free(sres.out);
    defer std.testing.allocator.free(sres.err);
    try std.testing.expectEqual(@as(i32, 0), sres.code);
    const srows = try extract_rows_array(sres.out);
    const snorm = try normalize_rows(std.testing.allocator, srows);
    defer std.testing.allocator.free(snorm);

    var server = try run_server(&.{ "./zig-out/bin/geode", "serve", "--listen-quic", "127.0.0.1:17670", "--result-format", "json" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const qres = try run(&.{ exe, q, "--json-param", "a", param", "--server", "127.0.0.1:17670", "--quic", "--format", "json" });
    defer std.testing.allocator.free(qres.out);
    defer std.testing.allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows_array(qres.out);
    const qnorm = try normalize_rows(std.testing.allocator, qrows);
    defer std.testing.allocator.free(qnorm);

    try std.testing.expect(std.mem.eql(u8, snorm, qnorm));
}
