const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

const RunResult = struct { code: i32, out: []u8, err: []u8 };

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !RunResult {
    const res = try cli_test_util.runAgainstServer(allocator, addr, args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
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
    // Zig 0.16: ArrayList is unmanaged — `.init(allocator)` is gone and the
    // allocator travels with each call.
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(allocator);
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
        try rows.append(allocator, obj);
    }
    // sort lexicographically
    const slice = try rows.toOwnedSlice(allocator);
    defer allocator.free(slice);
    std.sort.block([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    // join with commas inside brackets
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    for (slice, 0..) |obj, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, obj);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity CASE 3VL"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_Case3VL; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity QUIC (CASE 3VL)" {
    util.testStart("transport parity QUIC (CASE 3VL)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    const q = "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r";
    const param = "[null,true,false]";

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running first query...", .{});
    const qres = try run(allocator, addr, &.{ exe, q, "--param", "a", param, "--format", "json" });
    defer allocator.free(qres.out);
    defer allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows_array(allocator, qres.out);
    const qnorm = try normalize_rows(allocator, qrows);
    defer allocator.free(qrows);
    defer allocator.free(qnorm);

    util.progress("Running second query...", .{});
    const qres2 = try run(allocator, addr, &.{ exe, q, "--param", "a", param, "--format", "json" });
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
