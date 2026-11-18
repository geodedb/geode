// SONNY-3383 (engine side): a COMMIT the server refuses is reported
// unambiguously on the QUIC wire — `CommitResponse.success = false` with the
// SQLSTATE in `CommitResponse.error` — and nothing of the transaction is kept.
//
// geode-client-go's `Tx.Commit` ignored `success` and returned nil, so a
// caller was told a rolled-back transaction committed. That is a driver bug;
// this pins the server half of the contract the driver must read, over the
// real `geode serve` and the real protobuf protocol (the gRPC handler's half,
// `handleCommit`, is pinned in tests/test_sonny3348_round19_undo.zig m5).
//
// CANARY: REQ=REQ-SONNY-3383-COMMIT-REFUSED-WIRE; FEATURE="TransactionManagement"; ASPECT=RefusedCommitOnQuicWire; STATUS=TESTED; TEST=tests/test_sonny3383_commit_refused_wire.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Commit = struct { success: bool, code: ?[]const u8 };

/// Send COMMIT and read the CommitResponse as it came off the wire.
fn commitRaw(aa: std.mem.Allocator, client: *util.QuicProtoClient) !Commit {
    try client.writeMessage(.{ .commit = schema.CommitRequest{ .session_id = "" } });
    var packet = try client.readPacket(testing.allocator, 10_000);
    defer packet.deinit(testing.allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .commit) return error.InvalidMessage;
    return .{
        .success = msg.commit.success,
        .code = if (msg.commit.@"error") |e| try aa.dupe(u8, e.code) else null,
    };
}

fn count(client: *util.QuicProtoClient, query: []const u8) !i64 {
    var res = try client.executeAndCollectWithTimeout(testing.allocator, query, util.emptyParams(), 100, 60);
    defer res.deinit(testing.allocator);
    if (res.error_code != null or res.rows.len != 1) return error.UnexpectedAnswer;
    return switch (res.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedAnswer,
    };
}

test "SONNY-3383: a refused COMMIT answers success=false with SQLSTATE 40000 on the QUIC wire and keeps nothing; an accepted one answers success=true" {
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
    var hello = try client.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(testing.allocator);
    try testing.expect(hello.success);

    // Refused: a statement of the transaction fails, so it is rolled back and
    // its COMMIT must say so.
    {
        var b = try client.begin(testing.allocator);
        b.deinit(testing.allocator);
        var w = try client.executeAndCollectWithTimeout(testing.allocator, "CREATE (:T3383 {k: 1})", util.emptyParams(), 100, 60);
        const write_failed = w.error_code != null;
        w.deinit(testing.allocator);
        try testing.expect(!write_failed);
        var bad = try client.executeAndCollectWithTimeout(testing.allocator, "RETURN 1 / 0 AS x", util.emptyParams(), 100, 60);
        const bad_code = bad.error_code;
        bad.error_code = null;
        bad.deinit(testing.allocator);
        defer if (bad_code) |c| testing.allocator.free(c);
        try testing.expect(bad_code != null);

        const c = try commitRaw(aa, &client);
        if (c.success or c.code == null or !std.mem.eql(u8, c.code.?, "40000")) {
            std.debug.print("SONNY-3383: refused COMMIT answered success={} code={s}\n", .{ c.success, c.code orelse "(none)" });
        }
        try testing.expect(!c.success);
        try testing.expect(c.code != null);
        try testing.expectEqualStrings("40000", c.code.?);
        try testing.expectEqual(@as(i64, 0), try count(&client, "MATCH (n:T3383) RETURN count(n)"));
    }

    // Accepted: success=true, no error, the write is kept.
    {
        var b = try client.begin(testing.allocator);
        b.deinit(testing.allocator);
        var w = try client.executeAndCollectWithTimeout(testing.allocator, "CREATE (:T3383 {k: 2})", util.emptyParams(), 100, 60);
        const write_failed = w.error_code != null;
        w.deinit(testing.allocator);
        try testing.expect(!write_failed);
        const c = try commitRaw(aa, &client);
        try testing.expect(c.success);
        try testing.expect(c.code == null);
        try testing.expectEqual(@as(i64, 1), try count(&client, "MATCH (n:T3383) RETURN count(n)"));
    }
}
