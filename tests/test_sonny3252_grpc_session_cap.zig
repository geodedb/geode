// SONNY-3252 (round 15, F8, F9): the per-principal gRPC session cap never
// closes a session in an open transaction, keys clients without
// authentication per peer, and loses nothing when a Handshake fails.
//
// The round 14 review:
//   - F8: at the cap, a Handshake closed the principal's least recently used
//     idle session even when it was idle INSIDE an open transaction, and
//     rolled that transaction back. With authentication off every client was
//     the principal "", so any anonymous client could close any other's
//     transaction (cap = 2 repro). The cap is keyed by user name, not tenant.
//   - F9: if the insert failed after the victim was taken out, the victim was
//     never torn down and its graph hold blocked DROP GRAPH forever; the
//     at-cap check was O(n) under the store's exclusive lock; the teardown
//     ran on the Handshake thread; on the federation path the principal was
//     whatever name the client sent.
//
// Now: a session in a transaction (or in use) is never closed; at the cap
// with none other to close, the Handshake is refused (resource exhausted).
// Anonymous clients count as `anonymous@<peer ip>`, federation peers as
// `federation@<peer ip>` (`principalFor`). Each principal's sessions are
// listed, so the check is O(1). Room is reserved before a session is taken
// out. A closed session is torn down on the reaper thread when one runs.
//
// CANARY: REQ=REQ-SONNY-3252-SESSION-CAP; FEATURE="GrpcSessionLifetime"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3252_grpc_session_cap.zig; OWNER=transport; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

fn queryInt(ga: std.mem.Allocator, sid: []const u8, q: []const u8) !?i64 {
    const resp = try fx.execute(ga, sid, q);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        .schema => {},
        else => return null,
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = sid, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| {
            if (p.rows.items.len == 0 or p.rows.items[0].values.items.len == 0) return null;
            const k = p.rows.items[0].values.items[0].kind orelse return null;
            return switch (k) {
                .int_val => |x| x.value,
                else => null,
            };
        },
        else => return error.UnexpectedPayload,
    }
}

test "SONNY-3252: at the cap, two anonymous clients in open transactions are not closed: the third Handshake is refused, and both commit" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    var store = grpc.SessionStore.init(ga, .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 2 });
    grpc.setSessionStore(&store);
    defer {
        grpc.setSessionStore(&f.sessions);
        store.deinit();
    }
    try f.st.createGraph("gc");
    var pbuf: [96]u8 = undefined;
    const anon = grpc.principalFor(&pbuf, .anonymous, "", "10.0.0.7");
    try testing.expectEqualStrings("anonymous@10.0.0.7", anon);
    const a = try ga.dupe(u8, try store.createSessionAs(anon, "", "", null, null, null, false, 0));
    try fx.expectRuns(ga, a, "USE GRAPH gc");
    try fx.begin(ga, a);
    try fx.expectRuns(ga, a, "CREATE (:P {w: 'a'})");
    fx.sleepMs(3);
    const b = try ga.dupe(u8, try store.createSessionAs(anon, "", "", null, null, null, false, 0));
    try fx.expectRuns(ga, b, "USE GRAPH gc");
    try fx.begin(ga, b);
    try fx.expectRuns(ga, b, "CREATE (:P {w: 'b'})");
    try testing.expectEqual(@as(usize, 2), store.principalSessionCount(anon));
    // The third: refused, not made room for by closing a or b (round 14
    // closed a and rolled its transaction back).
    try testing.expectError(error.TooManySessions, store.createSessionAs(anon, "", "", null, null, null, false, 0));
    try testing.expect(store.getEntry(a) != null and store.getEntry(b) != null);
    try testing.expect(try fx.commit(ga, a));
    try testing.expect(try fx.commit(ga, b));
    try testing.expectEqual(@as(usize, 2), fx.countLabel(f.st, "gc", "P"));
    // Idle outside a transaction now: a fourth Handshake closes the least
    // recently used (a), and b serves on.
    const c = try ga.dupe(u8, try store.createSessionAs(anon, "", "", null, null, null, false, 0));
    try testing.expect(store.getEntry(a) == null);
    try testing.expect(store.getEntry(b) != null and store.getEntry(c) != null);
    try testing.expectEqual(@as(usize, 2), store.principalSessionCount(anon));
    try testing.expectEqual(@as(?i64, 2), try queryInt(ga, b, "MATCH (p:P) RETURN count(p) AS n"));
    try testing.expect(!graph_store.graphHeldByTxn("gc"));
}

test "SONNY-3252: anonymous clients of different peers do not take each other's room; the cap is per user name, not per tenant" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    var store = grpc.SessionStore.init(ga, .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 1 });
    grpc.setSessionStore(&store);
    defer {
        grpc.setSessionStore(&f.sessions);
        store.deinit();
    }
    var b1: [96]u8 = undefined;
    var b2: [96]u8 = undefined;
    const p1 = grpc.principalFor(&b1, .anonymous, "", "10.0.0.1");
    const p2 = grpc.principalFor(&b2, .anonymous, "", "10.0.0.2");
    const a = try ga.dupe(u8, try store.createSessionAs(p1, "", "", null, null, null, false, 0));
    const b = try ga.dupe(u8, try store.createSessionAs(p2, "", "", null, null, null, false, 0));
    // A second client of peer 1: closes peer 1's idle session, never peer 2's.
    const c = try ga.dupe(u8, try store.createSessionAs(p1, "", "", null, null, null, false, 0));
    try testing.expect(store.getEntry(a) == null);
    try testing.expect(store.getEntry(b) != null and store.getEntry(c) != null);
    try testing.expectEqual(@as(usize, 1), store.principalSessionCount(p1));
    try testing.expectEqual(@as(usize, 1), store.principalSessionCount(p2));
    // The federation path counts per peer, whatever name it sends.
    var fb: [96]u8 = undefined;
    try testing.expectEqualStrings("federation@10.0.0.9", grpc.principalFor(&fb, .federation, "any-name", "10.0.0.9"));
    // One user name in two tenants is one principal (documented).
    const t1 = try ga.dupe(u8, try store.createSession("alice", "", null, "tenant_a", null, false, 0));
    const t2 = try ga.dupe(u8, try store.createSession("alice", "", null, "tenant_b", null, false, 0));
    try testing.expect(store.getEntry(t1) == null and store.getEntry(t2) != null);
}

test "SONNY-3252: a Handshake that fails at any allocation closes no session and leaks nothing" {
    // Every allocation of a Handshake at the cap fails in turn. Before, the
    // victim was taken out of the map before the insert, and an insert that
    // failed left it neither in the map nor torn down.
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    var k: usize = 0;
    var failures_seen: usize = 0;
    while (k < 64) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        const fa = failing.allocator();
        var store = grpc.SessionStore.init(fa, .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 2 });
        defer store.deinit();
        const s1 = try testing.allocator.dupe(u8, try store.createSession("bob", "", null, null, null, false, 0));
        defer testing.allocator.free(s1);
        const s2 = try testing.allocator.dupe(u8, try store.createSession("bob", "", null, null, null, false, 0));
        defer testing.allocator.free(s2);
        failing.fail_index = failing.alloc_index + k;
        if (store.createSession("bob", "", null, null, null, false, 0)) |s3| {
            // It ran: one of bob's sessions was closed to make room.
            try testing.expectEqual(@as(usize, 2), store.principalSessionCount("bob"));
            try testing.expect(store.getEntry(s3) != null);
            try testing.expect((store.getEntry(s1) == null) != (store.getEntry(s2) == null));
        } else |err| {
            failures_seen += 1;
            try testing.expectEqual(error.OutOfMemory, err);
            // Failed: both of bob's sessions are still there.
            try testing.expect(store.getEntry(s1) != null and store.getEntry(s2) != null);
            try testing.expectEqual(@as(usize, 2), store.principalSessionCount("bob"));
        }
        try testing.expectEqual(store.sessions.count(), store.principalSessionCount("bob"));
    }
    try testing.expect(failures_seen > 0);
}

test "SONNY-3252: with the reaper running, a session the cap closes is torn down on the reaper's thread" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    var store = grpc.SessionStore.init(std.heap.smp_allocator, .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 1 });
    grpc.setSessionStore(&store);
    defer {
        grpc.setSessionStore(&f.sessions);
        store.deinit();
    }
    // The cap alone starts the reaper now (it tears the closed ones down).
    try store.startReaper();
    try testing.expect(store.reaper != null);
    const a = try std.heap.smp_allocator.dupe(u8, try store.createSession("carol", "", null, null, null, false, 0));
    defer std.heap.smp_allocator.free(a);
    _ = try store.createSession("carol", "", null, null, null, false, 0);
    try testing.expect(store.getEntry(a) == null);
    var waited: usize = 0;
    while (store.reaped_total.load(.monotonic) == 0 and waited < 5000) : (waited += 10) fx.sleepMs(10);
    try testing.expectEqual(@as(u64, 1), store.reaped_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), store.pending_teardown_count.load(.monotonic));
}
