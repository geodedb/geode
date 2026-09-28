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
// Round 15 diagnosis: a release server answered 1 MiB in about 0.1 s in
// every run, and 4 MiB in about 1.4 s in two runs of three; in the third
// (the machine busy with other builds) it never answered 4 MiB. A Debug
// server never answers 1 MiB or 4 MiB (256 KiB in 0.1 s), whatever the
// client's build, with detached admission or not, with 4 or 16 poll
// workers. So the stall depends on how fast the server drains the stream,
// not on this repo's framing (a 16 MiB message cap, a 10 MiB stream window):
// a timing-dependent stall in the receive path, most likely the QUIC
// library's stream flow control (a window update that never goes out), not
// yet confirmed.
// A request past the 16 MiB cap is refused at its length prefix, but the
// server ends the stream without a reply and without STOP_SENDING (the
// QUIC library, v0.1.44, cannot send one), so the client, blocked by the
// stream window, fails only at its own timeout (15 to 45 s). Neither is
// contained in this repo: both are left for S2 (SONNY-3232). This test
// holds what is true now: the server survives each request and serves the
// next connection; 256 KiB is answered; a request past the cap is not
// answered as if it ran. It records the 1 MiB and 4 MiB outcomes.
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
        // Recorded, not asserted: a Debug server never answers these, a
        // release server not always 4 MiB (SONNY-3232, left for S2).
        .{ .bytes = 1024 * 1024, .served = null },
        .{ .bytes = 4 * 1024 * 1024, .served = null },
        // The framed message (the query plus its envelope) just over 16 MiB.
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
        std.debug.print("QUIC {s}: a {d}-byte request -> {s} in {d} ms; server alive={}{s}\n", .{ @tagName(builtin.mode), c.bytes, outcome, ms, alive, if (ok) "" else "  <-- UNEXPECTED" });
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
