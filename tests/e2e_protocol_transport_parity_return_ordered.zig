const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

const RunResult = struct { code: i32, out: []u8, err: []u8 };

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !RunResult {
    const res = try cli_test_util.runAgainstServer(allocator, addr, args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
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

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Simple RETURN"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_ReturnOrdered; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity QUIC (RETURN ORDER/LIMIT)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("transport parity QUIC (RETURN ORDER/LIMIT)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = geode_test_bin.geode_exe;
    const q = "RETURN 1 AS x ORDER BY x LIMIT 1";

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running first query...", .{});
    const qres = try run(allocator, addr, &.{ exe, q, "--format", "json" });
    defer allocator.free(qres.out);
    defer allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 0), qres.code);
    const qrows = try extract_rows(allocator, qres.out);
    defer allocator.free(qrows);

    util.progress("Running second query...", .{});
    const qres2 = try run(allocator, addr, &.{ exe, q, "--format", "json" });
    defer allocator.free(qres2.out);
    defer allocator.free(qres2.err);
    try std.testing.expectEqual(@as(i32, 0), qres2.code);
    const qrows2 = try extract_rows(allocator, qres2.out);
    defer allocator.free(qrows2);

    util.progress("Comparing results...", .{});
    try std.testing.expect(std.mem.eql(u8, qrows, qrows2));

    util.testPass();
}
