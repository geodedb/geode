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
// transport. The library bug is SONNY-3351 (quic v0.1.44), fixed in quic
// v0.1.47 ("Stop freeing lost STREAM data before it is retransmitted":
// acknowledged STREAM packets are released by ACK range membership, never
// by the prune) and v0.1.49 (SONNY-6434, ACK work bounded by the ranges);
// geode pins v0.1.49. The 1 MiB and 4 MiB cases are therefore asserted
// (SONNY-3351): they were recorded, not asserted, while the bug stood.
//
// A request past the 16 MiB cap is refused at its length prefix, but the
// server ends the stream without a reply and without STOP_SENDING (the
// library cannot send one), so the client, held by the stream window, fails
// only at its own timeout (34 to 62 s observed). The review's intent was a
// clean, quick refusal: that is NOT met, and this test does not claim it.
// It asserts only what holds now: the server survives each request and
// serves the next connection; 256 KiB, 1 MiB and 4 MiB are answered; a
// request past the cap is not answered as if it ran (an observation of how
// it fails, with its time, is printed). (Since SONNY-3232's follow-up the
// server answers 54000 and closes; tests/test_sonny3232_quic_request_size.zig
// asserts that.)
//
// Every HELLO, and the small request that checks the server serves on, waits
// for its reply as long as the server process stays alive, capped at 60 s
// (SONNY-2394, `watchServerLiveness`), not a fixed 5 s: after a large probe a
// Debug server on a CPU-starved CI runner can still be busy (loss recovery,
// closing the probe's connection, Argon2id for the next HELLO) for longer
// than 5 s, and job 17420288318 failed the next HELLO with error.Timeout
// while the server was alive; for the same reason each QUIC handshake gets
// 30 s, not 5 s. The probe request itself keeps its fixed deadline, since
// its outcome and time are what this test records.
//
// CANARY: REQ=REQ-SONNY-3232-QUIC-LARGE-REQUEST; FEATURE="QuicTransport"; ASPECT=Diagnosis; STATUS=TESTED; TEST=tests/test_sonny3232_quic_large_request.zig; OWNER=transport; UPDATED=2026-09-28

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn monoMs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "SONNY-3232: QUIC requests of 256 KiB, 1 MiB and 4 MiB are answered (SONNY-3351), one past the 16 MiB maximum is not, and the server serves on" {
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
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    const server_pid = server.child.id.?;
    // The QUIC handshake after a large probe meets the same busy server, so
    // it gets more than the default 5 s (a fixed bound: the handshake has no
    // liveness wait).
    const handshake_timeout_s: u32 = 30;

    const Case = struct { bytes: usize, served: ?bool };
    const cases = [_]Case{
        .{ .bytes = 256 * 1024, .served = true },
        // Asserted since quic v0.1.47 fixed the loss recovery that left a hole
        // in the stream (SONNY-3351; they were recorded, not asserted).
        .{ .bytes = 1024 * 1024, .served = true },
        .{ .bytes = 4 * 1024 * 1024, .served = true },
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
        var pc = try util.QuicProtoClient.connectWithHandshakeTimeout(allocator, addr, handshake_timeout_s);
        defer pc.deinit();
        pc.watchServerLiveness(server_pid);
        var ph = try pc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        ph.deinit(allocator);
        // The probe keeps its fixed deadline (see the file comment).
        pc.server_pid = null;
        const t0 = monoMs();
        const timeout_s: u32 = if (c.served == null) 30 else 90;
        const outcome: []const u8 = if (pc.executeAndCollectWithTimeout(allocator, q.items, util.emptyParams(), 10, timeout_s)) |r0| blk: {
            var r = r0;
            defer r.deinit(allocator);
            break :blk if (r.error_code) |code| try allocator.dupe(u8, code) else try allocator.dupe(u8, "served");
        } else |err| try allocator.dupe(u8, @errorName(err));
        defer allocator.free(outcome);
        const ms = monoMs() - t0;
        const alive = util.processAlive(server_pid);
        const served = std.mem.eql(u8, outcome, "served");
        const ok = alive and (c.served == null or served == c.served.?);
        std.debug.print("QUIC {s}: a {d}-byte request -> {s} in {d} ms; server alive={}{s}{s}\n", .{ @tagName(builtin.mode), c.bytes, outcome, ms, alive, if (ok) "" else "  <-- UNEXPECTED", if (c.served != null and !c.served.?) " (observation: not a clean, quick refusal; SONNY-3232)" else "" });
        if (!ok) failures += 1;
        // A small request on a new connection is served.
        var sc = try util.QuicProtoClient.connectWithHandshakeTimeout(allocator, addr, handshake_timeout_s);
        defer sc.deinit();
        sc.watchServerLiveness(server_pid);
        var sh = try sc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        sh.deinit(allocator);
        var small = try sc.executeAndCollectWithTimeout(allocator, "RETURN 1 AS x", util.emptyParams(), 10, 30);
        defer small.deinit(allocator);
        if (small.error_code != null) failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
