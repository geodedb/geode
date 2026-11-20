// SONNY-2412 regression: remote KMS request latency stays flat on one
// long-lived connection.
//
// Found by SONNY-2394: per-request latency on one connection grew from about
// 11 ms to about 110 ms over 64 requests. The client opens one QUIC stream
// per request on the connection (`RemoteKmsClient.sendRequest`).
//
// The cause was in the quic dependency (v0.1.49 and v0.1.50): the server
// endpoint kept retransmitting the already-delivered response data (STREAM
// frames) of every completed request stream, the client acknowledged each
// copy, and it never stopped (about 370 datagrams a second on a connection
// with nothing in flight); each request added one more, so the useful
// exchange got a shrinking share of the endpoint's packet budget (37 ms ->
// 138 ms, 2.9-3.7x). quic v0.1.51 (SONNY-6478) retires a stream once both
// directions are finished and no longer resends acknowledged data; geode
// does not (and need not) call `teardownStream`. On v0.1.51 the run is flat
// (11.1 ms -> 11.3 ms, 1.01x).
//
// A real `RemoteKmsServer` served from a thread, a real `RemoteKmsClient`,
// over QUIC with the per-test TLS pair (tests/kms_test_tls.zig): 64 unwraps
// on one connection, in order. The claim (through tests/perf_gate.zig:
// enforced when CI is unset or GEODE_PERF_GATES=enforce) is that the median
// of the last 16 requests is within 2x of the median of the first 16.
//
// CANARY: REQ=REQ-SONNY-2412-KMS-LATENCY-FLAT; FEATURE="RemoteKMSPrototype"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2412_kms_latency_flat.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const kms = @import("security/kms_remote");
const perf_gate = @import("perf_gate");
const kms_tls = @import("kms_test_tls.zig");

const requests: usize = 64;
const window: usize = 16;
const max_growth: f64 = 2.0;

fn median(xs: []u64) u64 {
    std.sort.heap(u64, xs, {}, comptime std.sort.asc(u64));
    return xs[xs.len / 2];
}

test "SONNY-2412: 64 KMS requests on one connection keep a flat latency" {
    var tls = try kms_tls.TestTls.init(std.testing.allocator);
    defer tls.deinit(std.testing.allocator);
    var server = try kms.RemoteKmsServer.init(std.testing.allocator, 0x2412_2412_2412_2412);
    defer server.deinit();
    try server.startWithOptions(0, tls.startOptions());
    try server.server.setAuthToken("sonny2412-token");

    var stop = std.atomic.Value(bool).init(false);
    const serving = try std.Thread.spawn(.{}, kms.RemoteKmsServer.serveUntilStopped, .{ &server, &stop });
    defer {
        stop.store(true, .release);
        serving.join();
    }

    // Clients on page_allocator (tests/canary_remote_kms.zig, GAP-0514 P3).
    var client = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .ca_cert_path = tls.caPath() });
    defer client.deinit();
    try client.connect("127.0.0.1", server.port);
    client.setAuthToken("sonny2412-token");

    const env = try client.generate();
    const expected = try client.unwrap(env);

    var lat: [requests]u64 = undefined;
    for (&lat) |*l| {
        const t0 = perf_gate.nowNs();
        const got = try client.unwrap(env);
        l.* = perf_gate.nowNs() - t0;
        try std.testing.expectEqualSlices(u8, &expected, &got);
    }

    std.debug.print("SONNY-2412 per-request ms:", .{});
    for (lat) |l| std.debug.print(" {d:.1}", .{@as(f64, @floatFromInt(l)) / std.time.ns_per_ms});
    std.debug.print("\n", .{});

    var first: [window]u64 = lat[0..window].*;
    var last: [window]u64 = lat[requests - window ..][0..window].*;
    const m_first = median(&first);
    const m_last = median(&last);
    const growth = @as(f64, @floatFromInt(m_last)) / @as(f64, @floatFromInt(@max(m_first, 1)));
    std.debug.print("SONNY-2412 median first {d} = {d:.2} ms, last {d} = {d:.2} ms, growth {d:.2}x\n", .{ window, @as(f64, @floatFromInt(m_first)) / std.time.ns_per_ms, window, @as(f64, @floatFromInt(m_last)) / std.time.ns_per_ms, growth });
    try perf_gate.check("remote KMS latency flat over 64 requests on one connection (SONNY-2412)", growth <= max_growth, "growth={d:.2}x (max {d:.1}x)", .{ growth, max_growth });
}
