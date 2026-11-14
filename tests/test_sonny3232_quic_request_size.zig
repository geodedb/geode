// SONNY-3232: how QUIC requests of 1 MiB, 4 MiB, the documented maximum
// (16 MiB framed message, `decodeBufferedMessage`; docs/USAGE.md) and just
// over it are answered, against a real `geode serve` over real QUIC.
//
// What holds (quic 0.1.48 fixed the loss-recovery bug, SONNY-3351, that left
// round 15's ~1 MiB requests unanswered; quic 0.1.51 the large-stream crawl):
//   * 1 MiB, 4 MiB and the maximum-size request are answered with their
//     full size (asserted).
//   * A request over the maximum used to be refused by ENDING THE STREAM WITH
//     NO REPLY: the server stopped reading, so the client, held by the stream
//     window, blocked writing and failed only at its own 60 s writer deadline,
//     with nothing to say why. The server now answers 54000 on the stream and
//     closes the connection with application error `message_too_large`, so
//     the client's write stops as soon as the close arrives (asserted: the
//     failure is the server's close or 54000, inside the 60 s writer
//     deadline) and the server serves the next connection.
//   * A request larger than the 10 MiB stream receive window used to crawl
//     (ReleaseSafe: 16 MiB in ~168 s; Debug: no answer in 300 s): the
//     receiver sorted and walked every buffered out-of-order segment for each
//     packet. quic v0.1.51 (SONNY-6475) keeps them sorted and drains only the
//     contiguous prefix, so the maximum-size case is asserted again (Debug:
//     answered in about 3.5 s on loopback). Stalls of long transfers under
//     heavy CPU load that remain in the library are SONNY-6522.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const max_message_bytes: usize = 16 * 1024 * 1024;
/// Envelope room: the ClientPacket / ExecuteRequest framing around the query
/// text, the session id, and `RETURN size('` ... `') AS n`.
const envelope_room: usize = 4096;
/// Bound for the asserted answers (a Debug server on a loaded machine
/// answered 4 MiB in 16 s).
const answer_bound_s: u32 = 120;
/// An over-maximum request must fail inside the client's 60 s writer
/// deadline. The time includes the client encoding and starting to send
/// 16 MiB (about 20 s for a Debug client), so the decisive check is HOW it
/// fails: the server's close (`Closed`) or its 54000 answer, not the
/// writer deadline or a truncated stream (`WriteError` /
/// `IncompleteResponse`, as before the fix).
const refusal_bound_ms: u64 = 45_000;

fn monoMs() u64 {
    return @intCast(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds());
}

fn sizeQuery(allocator: std.mem.Allocator, bytes: usize) ![]u8 {
    var q: std.ArrayList(u8) = .empty;
    errdefer q.deinit(allocator);
    try q.appendSlice(allocator, "RETURN size('");
    try q.appendNTimes(allocator, 'a', bytes);
    try q.appendSlice(allocator, "') AS n");
    return q.toOwnedSlice(allocator);
}

const Outcome = struct {
    served_n: ?i64 = null,
    error_code: ?[]u8 = null,
    transport_error: ?[]const u8 = null,
    ms: u64,
};

/// One request on a connection of its own (a failed one leaves the
/// connection unusable).
fn probe(allocator: std.mem.Allocator, addr: []const u8, server_pid: std.posix.pid_t, bytes: usize, bound_s: u32) !Outcome {
    var client = try util.QuicProtoClient.connectWithHandshakeTimeout(allocator, addr, 30);
    defer client.deinit();
    client.watchServerLiveness(server_pid);
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);
    // The request keeps a fixed deadline; its time is what is measured.
    client.server_pid = null;
    const q = try sizeQuery(allocator, bytes);
    defer allocator.free(q);
    const t0 = monoMs();
    var r = client.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 10, bound_s) catch |err| {
        return .{ .transport_error = @errorName(err), .ms = monoMs() - t0 };
    };
    defer r.deinit(allocator);
    const ms = monoMs() - t0;
    if (r.error_code) |c| return .{ .error_code = try allocator.dupe(u8, c), .ms = ms };
    if (r.rows.len == 1 and r.rows[0].len == 1) switch (r.rows[0][0]) {
        .int => |n| return .{ .served_n = n, .ms = ms },
        else => {},
    };
    return .{ .ms = ms };
}

fn smallRequestServed(allocator: std.mem.Allocator, addr: []const u8, server_pid: std.posix.pid_t) !bool {
    var client = try util.QuicProtoClient.connectWithHandshakeTimeout(allocator, addr, 30);
    defer client.deinit();
    client.watchServerLiveness(server_pid);
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);
    var r = try client.executeAndCollectWithTimeout(allocator, "RETURN 1 AS x", util.emptyParams(), 10, 60);
    defer r.deinit(allocator);
    return r.error_code == null and r.rows.len == 1;
}

test "SONNY-3232 QUIC requests of 1 MiB, 4 MiB and the 16 MiB maximum are answered, one over it fails fast, and the server serves on" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    const server_pid = server.child.id.?;
    const addr = server.getAddr();

    var failures: usize = 0;
    for ([_]usize{ 1024 * 1024, 4 * 1024 * 1024, max_message_bytes - envelope_room }) |bytes| {
        const o = try probe(allocator, addr, server_pid, bytes, answer_bound_s);
        defer if (o.error_code) |c| allocator.free(c);
        const ok = o.served_n != null and o.served_n.? == @as(i64, @intCast(bytes));
        std.debug.print("SONNY-3232 {s}: {d}-byte request -> served={any} error={?s} transport={?s} in {d} ms{s}\n", .{ @tagName(builtin.mode), bytes, o.served_n, o.error_code, o.transport_error, o.ms, if (ok) "" else "  <-- UNEXPECTED" });
        if (!ok) failures += 1;
        if (!try smallRequestServed(allocator, addr, server_pid)) failures += 1;
    }

    // Over the maximum: refused, and fast.
    {
        const bytes = max_message_bytes + 64;
        const o = try probe(allocator, addr, server_pid, bytes, answer_bound_s);
        defer if (o.error_code) |c| allocator.free(c);
        const closed_by_server = if (o.transport_error) |e| std.mem.eql(u8, e, "Closed") else false;
        const answered_54000 = if (o.error_code) |c| std.mem.eql(u8, c, "54000") else false;
        const refused = o.served_n == null and (closed_by_server or answered_54000);
        const ok = refused and o.ms <= refusal_bound_ms;
        std.debug.print("SONNY-3232 {s}: {d}-byte request (over the maximum) -> served={any} error={?s} transport={?s} in {d} ms{s}\n", .{ @tagName(builtin.mode), bytes, o.served_n, o.error_code, o.transport_error, o.ms, if (ok) "" else "  <-- UNEXPECTED (must be refused by the server: Closed or 54000, within 45 s)" });
        if (!ok) failures += 1;
        if (!try smallRequestServed(allocator, addr, server_pid)) failures += 1;
    }

    try testing.expect(util.processAlive(server_pid));
    try testing.expectEqual(@as(usize, 0), failures);
}
