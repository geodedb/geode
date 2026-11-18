// SONNY-6601 (6): QUIC runs a program that opens a transaction, mutates and
// rolls back in one message, as gRPC does; it refused it with 25001.
//
// geode#830 (2025): the QUIC execute path ran a program's statements without
// honouring an inline START TRANSACTION / ROLLBACK, so `START TRANSACTION;
// CREATE ...; ROLLBACK` committed the CREATE. The fix refused any such
// program with 25001. The executor has since run inline transaction control
// (SONNY-2805 keeps such a program off the single-statement fast paths;
// SONNY-2823 joins its changes to the session transaction; SONNY-3348 undoes
// them), and gRPC accepts the same program; QUIC kept refusing it.
//
// A real `geode serve` over QUIC. Each program below must succeed and leave
// exactly what a rollback (or, for the control, a commit) leaves.
//
// CANARY: REQ=REQ-SONNY-6601-QUIC-INLINE-ROLLBACK; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6601_quic_inline_rollback.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn run(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6601 (6): {s}\n  -> {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn count(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

const Case = struct { program: []const u8, check: []const u8, want: i64 };

const cases = [_]Case{
    .{ .program = "START TRANSACTION; CREATE (:Q6601 {i: 1}); CREATE (:Q6601 {i: 2}); ROLLBACK", .check = "MATCH (n:Q6601) RETURN count(n) AS c", .want = 0 },
    .{ .program = "START TRANSACTION; MERGE (:Q6601M {k: 1}); ROLLBACK", .check = "MATCH (n:Q6601M) RETURN count(n) AS c", .want = 0 },
    .{ .program = "START TRANSACTION; MATCH (n:K6601) DELETE n; ROLLBACK", .check = "MATCH (n:K6601) RETURN count(n) AS c", .want = 1 },
    .{ .program = "START TRANSACTION; MATCH (n:K6601) SET n.v = 2; ROLLBACK", .check = "MATCH (n:K6601) WHERE n.v = 1 RETURN count(n) AS c", .want = 1 },
    // Control: the same shape with COMMIT keeps its change.
    .{ .program = "START TRANSACTION; CREATE (:C6601); COMMIT", .check = "MATCH (n:C6601) RETURN count(n) AS c", .want = 1 },
};

test "SONNY-6601 (6): QUIC runs START TRANSACTION ... ROLLBACK with mutations in one message and undoes them" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6601-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};

    const port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, null);
    defer handle.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    client.watchServerLiveness(handle.child.id orelse return error.NoServerPid);
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) return error.HelloFailed;

    try run(&client, allocator, "CREATE GRAPH q6601");
    try run(&client, allocator, "USE GRAPH q6601");
    try run(&client, allocator, "CREATE (:K6601 {v: 1})");

    var wrong: usize = 0;
    for (cases) |c| {
        run(&client, allocator, c.program) catch {
            wrong += 1;
            continue;
        };
        const got = try count(&client, allocator, c.check);
        if (got != c.want) {
            wrong += 1;
            std.debug.print("SONNY-6601 (6): {s}\n  -> {s} = {d}, want {d}\n", .{ c.program, c.check, got, c.want });
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
