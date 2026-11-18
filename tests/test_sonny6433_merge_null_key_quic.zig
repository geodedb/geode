// SONNY-6433 item 2, QUIC bulk MERGE fast paths: a null MERGE key is
// refused with 22004 there too.
//
// A `MERGE (n:L {k: <literal or parameter>}) [SET ...]` statement, and a
// `/*+BATCH*/` run of them, is served over QUIC by the bulk MERGE fast paths
// (`executeBulkSimpleMerge`, `executeBatchSimpleMerge`) instead of the
// executor; the detector takes a `null` literal as a scalar. The executor now
// refuses a null key (`crud_operations.evaluateMergeKeyIn`); the fast paths
// created a node without the key on every run. They now refuse it the same
// way, before anything is submitted.
//
// Spawns the real geode this build emitted (SONNY-2697) and speaks the real
// protobuf protocol.
//
// CANARY: REQ=REQ-SONNY-6433-MERGE-KEYS; FEATURE="MergeStatement"; ASPECT=BulkNullKeyRefused; STATUS=TESTED; TEST=tests/test_sonny6433_merge_null_key_quic.zig; OWNER=transport; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");

const node_merge = "MERGE (n:Q6433 {k: null}) SET n.v = 'written'";
const batch_merge = "/*+BATCH*/MERGE (n:Q6433 {k: 1}) SET n.v = 'written'; MERGE (n:Q6433 {k: null}) SET n.v = 'written'";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "SONNY-6433: the null-key statements are the bulk MERGE fast-path shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var p = try geode.parseGql(node_merge, aa);
    defer p.deinit();
    try testing.expectEqual(geode.bulk_ingest.BulkPattern.simple_node_merge, geode.bulk_ingest.matchSingleStatement(&p.program));
    try testing.expect(geode.bulk_ingest.matchSimpleNodeMergeSpec(&p.program) != null);
}

/// The rows of `query` as `a|b` strings, or `error:<code>`.
fn rowsOf(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    var res = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer res.deinit(testing.allocator);
    if (res.error_code) |code| return std.fmt.allocPrint(aa, "error:{s}", .{code});
    var out: std.ArrayList(u8) = .empty;
    for (res.rows, 0..) |row, i| {
        if (i > 0) try out.append(aa, ';');
        for (row, 0..) |cell, j| {
            if (j > 0) try out.append(aa, '|');
            switch (cell) {
                .int => |v| try out.print(aa, "{d}", .{v}),
                .string => |v| try out.appendSlice(aa, v),
                .null => try out.appendSlice(aa, "null"),
                else => try out.appendSlice(aa, "?"),
            }
        }
    }
    return out.toOwnedSlice(aa);
}

test "SONNY-6433: the QUIC bulk MERGE fast paths refuse a null key with 22004 and write nothing" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io(), &cwd_buf);
    const data_dir = try std.fmt.allocPrint(aa, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });

    const port = try util.getRandomPort();
    const addr = try util.formatAddr(testing.allocator, port);
    defer testing.allocator.free(addr);
    var handle = try util.spawnServer(testing.allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{});
    defer handle.deinit();
    try util.waitForServerReady(testing.allocator, addr, 30000);

    var client = try util.QuicProtoClient.connect(testing.allocator, addr);
    defer client.deinit();
    client.watchServerLiveness(handle.child.id.?);
    var hello = try client.helloWith(testing.allocator, util.defaultUsername(), util.defaultPassword(), null, null);
    defer hello.deinit(testing.allocator);
    try testing.expect(hello.success);

    var failures: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ node_merge, node_merge, batch_merge }) |stmt| {
        const got = try rowsOf(aa, &client, stmt);
        if (!std.mem.eql(u8, got, "error:22004")) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: expected error:22004, got '{s}'", .{ stmt, got }));
    }
    const count = try rowsOf(aa, &client, "MATCH (n:Q6433) RETURN count(n)");
    if (!std.mem.eql(u8, count, "0")) try failures.append(aa, try std.fmt.allocPrint(aa, "Q6433 nodes after the refusals: {s}, expected 0", .{count}));
    // Control: a keyed MERGE still takes effect, once.
    for (0..2) |_| _ = try rowsOf(aa, &client, "MERGE (n:Q6433 {k: 7}) SET n.v = 'written'");
    const keyed = try rowsOf(aa, &client, "MATCH (n:Q6433) RETURN n.k, n.v");
    if (!std.mem.eql(u8, keyed, "7|written")) try failures.append(aa, try std.fmt.allocPrint(aa, "keyed MERGE: got '{s}', expected 7|written", .{keyed}));

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("  {s}\n", .{f});
        return error.NullMergeKeyServed;
    }
}
