const std = @import("std");
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

/// SONNY-6476 item 1: the dataset the query reads, with equal-length paths
/// whose order only the ORDER BY decides (A reaches D through B and through
/// C; B and C each reach E). Seeded into a fresh data directory every run.
const seed_statements = [_][]const u8{
    "CREATE (:Person {name: 'A'}), (:Person {name: 'B'}), (:Person {name: 'C'}), (:Person {name: 'D'}), (:Person {name: 'E'})",
    "MATCH (a:Person {name: 'A'}), (b:Person {name: 'B'}) CREATE (a)-[:KNOWS]->(b)",
    "MATCH (a:Person {name: 'A'}), (c:Person {name: 'C'}) CREATE (a)-[:KNOWS]->(c)",
    "MATCH (b:Person {name: 'B'}), (d:Person {name: 'D'}) CREATE (b)-[:KNOWS]->(d)",
    "MATCH (c:Person {name: 'C'}), (d:Person {name: 'D'}) CREATE (c)-[:KNOWS]->(d)",
    "MATCH (b:Person {name: 'B'}), (e:Person {name: 'E'}) CREATE (b)-[:KNOWS]->(e)",
    "MATCH (c:Person {name: 'C'}), (e:Person {name: 'E'}) CREATE (c)-[:KNOWS]->(e)",
};

// CANARY: REQ=REQ-GQL-018; FEATURE="Transport Parity VarLen Dataset Rows"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_018_TransportParity_VarLenDatasetRows; OWNER=engine; UPDATED=2026-11-13
// Seeds a dataset of equal-length variable-length paths into a fresh data
// directory and checks that two runs of the same ordered query agree.
// SONNY-6476: the data directory was the fixed, relative
// `./data/varlen_determinism`, which outlived every run; a store left there
// with other credentials made the step fail, and no dataset was ever seeded.
test "protocol: transport parity varlen dataset rows QUIC (gated)" {
    util.testStart("transport parity varlen dataset rows QUIC");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = geode_test_bin.geode_exe;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });
    defer allocator.free(data_dir);
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 6";

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        // SONNY-6548: a failed parity run fails the smoke (it skipped and passed).
        return err;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data_dir", data_dir }, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 10000);

    util.progress("Seeding the dataset...", .{});
    for (seed_statements) |stmt| {
        const sres = try run(allocator, addr, &.{ exe, stmt, "--format", "json" });
        defer allocator.free(sres.out);
        defer allocator.free(sres.err);
        try std.testing.expectEqual(@as(i32, 0), sres.code);
    }

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
    // The rows are the seeded paths, in ORDER BY order (not an empty store).
    try std.testing.expectEqualStrings("[{\"a\":\"A\",\"b\":\"B\"},{\"a\":\"A\",\"b\":\"C\"},{\"a\":\"A\",\"b\":\"D\"},{\"a\":\"A\",\"b\":\"D\"},{\"a\":\"A\",\"b\":\"E\"},{\"a\":\"A\",\"b\":\"E\"}]", qrows);

    util.testPass();
}
