// SONNY-3232 (round 15, item 10; pre-existing): how a QUIC request of about
// 1 MB and more is answered, against a spawned server.
//
// Round 14 capped its QUIC chain tests at 400 KB: a request of about 1 MB
// "never got an answer" (a 20 s client timeout), in a Debug build. This
// probes 256 KiB, 1 MiB and 4 MiB string-literal requests, and one just
// over the documented maximum message (16 MiB, `decodeBufferedMessage`),
// each on a connection of its own, and records the outcome and the time;
// the server must stay up and serve a small request after each. Run it in
// Debug and in ReleaseSafe: the answer differs.
//
// Diagnosis (round 15; corrected in round 16, SONNY-3232): the stall is
// loss recovery in the vendored QUIC library, quic v0.1.44, not stream flow
// control (the stream window is 10 MiB and the connection's 100 MiB, so a
// 1 MiB request never needs a window update). When the server drains its
// socket slowly (a Debug server, or a release one on a loaded machine) the
// kernel drops datagrams in bursts. `Recovery.onAckReceived` declares them
// lost and compacts them out of the sent list, so they read as `.unknown`;
// `retransmitLostStreamPackets` resends at most 2 lost packets per ACK; and
// the cumulative-ACK prune in the same call drops every retained STREAM
// packet below largest_acked - 16 that is `.acked` or `.unknown`, including
// lost ones never resent. The stream is left with a hole, and the request is
// never delivered. Whether it is answered therefore depends on timing (does
// a lost packet fall into the pruned range?), not on the request's size:
// round 15 saw a release server answer 1 MiB in about 0.1 s and 4 MiB in
// about 1.4 s, and a Debug server time out on 1 MiB in one run and answer
// 4 MiB in 14.8 s in another. Any size large enough to see burst loss can
// stall. The same loss recovery carries QUIC responses and the Raft
// transport. Filed for S2 against the library.
//
// A request past the 16 MiB cap is refused at its length prefix, but the
// server ends the stream without a reply and without STOP_SENDING (the
// library cannot send one), so the client, held by the stream window, fails
// only at its own timeout (34 to 62 s observed). The review's intent was a
// clean, quick refusal: that is NOT met, and this test does not claim it.
// It asserts only what holds now: the server survives each request and
// serves the next connection; 256 KiB is answered; a request past the cap
// is not answered as if it ran (an observation of how it fails, with its
// time, is printed). The 1 MiB and 4 MiB outcomes are recorded, not
// asserted.
//
// CANARY: REQ=REQ-SONNY-3232-QUIC-LARGE-REQUEST; FEATURE="QuicTransport"; ASPECT=Diagnosis; STATUS=TESTED; TEST=tests/test_sonny3232_quic_large_request.zig; OWNER=transport; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "SONNY-3232: a QUIC request of 256 KiB is answered, one past the 16 MiB maximum is not, and the server survives 1 MiB and 4 MiB requests and serves on" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3232-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    const Case = struct { bytes: usize, served: ?bool };
    const cases = [_]Case{
        .{ .bytes = 256 * 1024, .served = true },
        // Recorded, not asserted: answered or not depending on timing (burst
        // loss and the library's loss recovery; SONNY-3232, left for S2).
        .{ .bytes = 1024 * 1024, .served = null },
        .{ .bytes = 4 * 1024 * 1024, .served = null },
        // The framed message (the query plus its envelope) just over 16 MiB.
        // Asserted: not served. Observed, not asserted: how and how late it
        // fails (the intended quick, clean refusal is not met; S2).
        .{ .bytes = 16 * 1024 * 1024 + 64, .served = false },
    };
    var failures: usize = 0;
    for (cases) |c| {
        var q = std.ArrayList(u8).empty;
        defer q.deinit(allocator);
        try q.appendSlice(allocator, "RETURN '");
        try q.appendNTimes(allocator, 'a', c.bytes);
        try q.appendSlice(allocator, "' AS x");
        var pc = try util.QuicProtoClient.connect(allocator, addr);
        defer pc.deinit();
        var ph = try pc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        ph.deinit(allocator);
        const t0 = monoMs();
        const timeout_s: u32 = if (c.served == null) 30 else 90;
        const outcome: []const u8 = if (pc.executeAndCollectWithTimeout(allocator, q.items, util.emptyParams(), 10, timeout_s)) |r0| blk: {
            var r = r0;
            defer r.deinit(allocator);
            break :blk if (r.error_code) |code| try allocator.dupe(u8, code) else try allocator.dupe(u8, "served");
        } else |err| try allocator.dupe(u8, @errorName(err));
        defer allocator.free(outcome);
        const ms = monoMs() - t0;
        const alive = util.processAlive(server.child.id.?);
        const served = std.mem.eql(u8, outcome, "served");
        const ok = alive and (c.served == null or served == c.served.?);
        std.debug.print("QUIC {s}: a {d}-byte request -> {s} in {d} ms; server alive={}{s}{s}\n", .{ @tagName(builtin.mode), c.bytes, outcome, ms, alive, if (ok) "" else "  <-- UNEXPECTED", if (c.served != null and !c.served.?) " (observation: not a clean, quick refusal; SONNY-3232)" else "" });
        if (!ok) failures += 1;
        // A small request on a new connection is served.
        var sc = try util.QuicProtoClient.connect(allocator, addr);
        defer sc.deinit();
        var sh = try sc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        sh.deinit(allocator);
        var small = try sc.executeAndCollectWithTimeout(allocator, "RETURN 1 AS x", util.emptyParams(), 10, 30);
        defer small.deinit(allocator);
        if (small.error_code != null) failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
