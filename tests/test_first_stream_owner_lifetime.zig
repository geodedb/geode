// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME — FirstStreamOwnerContext use-after-free.
//
// CANARY: REQ=REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME; FEATURE="QuicTransport"; ASPECT=FirstStreamOwnerLifetime; STATUS=TESTED; TEST=tests/test_first_stream_owner_lifetime.zig; OWNER=server; UPDATED=2026-06-10
//
// ── Bug (diagnosed) ─────────────────────────────────────────────────────────
// SIGSEGV (GP fault) in std.mem.readInt at
// src/server/quic_connection_handler.zig:1233 (`decodeBufferedMessage`, inlined
// into `nextMessage`) under concurrent load. Root cause: a use-after-free of a
// heap `FirstStreamOwnerContext` (struct at :2542). The detached async-cleanup
// path frees the context:
//
//   finishCooperativeContext (:2920)
//     -> cooperative_done=true; removeContext
//     -> spawn detached cleanupFirstStreamOwnerAsync (:2930)
//       -> cleanupFirstStreamOwner -> destroyFirstStreamOwnerResources (:2667)
//         -> transport.destroyConnection(conn) + gpa.destroy(ctx) (:2678-2680)
//
// This free is NOT synchronized with:
//   (1) the detached-owner read loop still running
//       (handleFirstStreamOwner :3689 -> runStreamQueryLoopWithReader :2269
//        touching &ctx.reader), nor
//   (2) the poll-thread RX-ready notifier (firstStreamReadyCallback :3329 —
//       a TOCTOU on `cooperative_done`; the vendored lib fires the notifier
//       AFTER releasing Connection.mu), nor
//   (3) the submit publish-before-return window (submit :2890 publishes the ctx
//       to workers before returning; handleQuicConnection :4171 then reads
//       first_ctx.cooperative_scheduler — possibly freed).
//
// Unlike the heap-refcounted `StreamAcceptorContext` (:1867) and the 2026-06-02
// deferred-teardown reaper (src/server/leaked_conn_reaper.zig), nothing
// refcounts/quiesces `FirstStreamOwnerContext` before the free.
//
// ── Where the reproduction tests live ───────────────────────────────────────
// The scheduler / owner-context / notifier internals are intentionally NOT
// exported through the `geode` root module (circular dependency, src/lib.zig:652),
// so the deterministic-red reproduction tests are INLINE in
// src/server/quic_connection_handler.zig and run via `src/main.zig` rooted +
// filtered, exactly like `test-acceptor-bail` does for the `StreamAcceptorContext`
// tests. The build step `test-first-stream-owner-lifetime` runs BOTH:
//   * the inline repro (filters `first_stream_owner_` / `first_stream_decode_`), and
//   * this file's geode-reachable supporting suite.
//
// Inline tests (in quic_connection_handler.zig):
//   - first_stream_owner_notifier_vs_async_free_regression  (deterministic RED)
//       async cleanup free races the REAL firstStreamReadyCallback; oracle is a
//       free-counter -> pre-fix double free (testing allocator), post-fix one free.
//   - first_stream_owner_submit_publish_before_return_regression (deterministic RED)
//       worker async-free races the caller's post-submit cooperative_scheduler read.
//   - first_stream_owner_refcount_last_release_signals_free (UNIT)
//       pins the owner_refs last-release-frees contract the fix introduces.
//   - first_stream_owner_concurrent_retain_release_frees_once (UNIT/stress)
//       N reader threads + owner free the allocation exactly once.
//   - first_stream_owner_cleanup_barrier_seam_pin (PIN)
//       exercises the test barrier seam + notifier cooperative_done bail.
//   - first_stream_decode_buffered_framing_bounds_pin (PIN)
//       decodeBufferedMessage must not index OOB on a torn/corrupt reader.
//
// ── Notes for the fixer ─────────────────────────────────────────────────────
// Refcount/quiesce FirstStreamOwnerContext (owner ref + scheduler/notifier ref +
// read-loop ref; free only at 0), mirroring StreamAcceptorContext. The inline
// seams added for these tests (`owner_refs`, `retainOwnerRef`, `releaseOwnerRef`,
// the `test_cleanup_reached` barrier) are the intended fix primitives. After the
// fix gates `destroyFirstStreamOwnerResources`' free on `owner_refs`, swap the
// two `destroyOwnerUnsynchronized()` calls in each regression test for the gated
// variant (see the in-test CONTRACT CHANGE comments) and re-add this step to the
// sharded `zig build test` aggregate.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Keep a compile-time reference to the public surface so this module shares the
// same dependency graph as the rest of the suite (and fails loudly if `geode`
// stops building), without depending on any handler-internal symbol.
comptime {
    std.debug.assert(@hasDecl(geode, "schema_change_notifier"));
}

// Contract pin (self-contained, geode-reachable): the lifetime refcount model
// the fix adds to FirstStreamOwnerContext. This is an intentional, clearly
// labeled MIRROR of the `owner_refs` / retain / release semantics implemented
// inline on the real struct — it pins the contract in a place reachable from
// the public test surface so a reviewer can read the invariant here even though
// the real struct is private. The real refcount is exercised against the actual
// code by the inline `first_stream_owner_*` tests. If this mirror and the real
// methods ever diverge, the inline tests are authoritative.
const OwnerRefcountContract = struct {
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    fn retain(self: *OwnerRefcountContract) void {
        const prev = self.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    /// Returns true on the LAST release (caller frees).
    fn release(self: *OwnerRefcountContract) bool {
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        return prev == 1;
    }
};

test "first_stream_owner_refcount_contract_last_release_frees (mirror pin)" {
    var rc = OwnerRefcountContract{};
    try testing.expectEqual(@as(u32, 1), rc.refs.load(.acquire));

    // A reader (notifier / read loop) retains before touching the ctx.
    rc.retain(); // 2
    try testing.expectEqual(@as(u32, 2), rc.refs.load(.acquire));

    // The async cleanup releases first: NOT the last ref, must not free.
    try testing.expect(!rc.release()); // 1
    // The reader releases last: this is the freeing release.
    try testing.expect(rc.release()); // 0
}

test "first_stream_owner_refcount_contract_concurrent_release_frees_once (mirror pin)" {
    // N threads each retain+release; exactly one observes the last release.
    var trial: usize = 0;
    while (trial < 256) : (trial += 1) {
        var rc = OwnerRefcountContract{};
        const reader_count = 8;
        var r: usize = 0;
        while (r < reader_count) : (r += 1) rc.retain(); // refs = 1 + 8

        var freed = std.atomic.Value(u32).init(0);

        const Worker = struct {
            rc: *OwnerRefcountContract,
            freed: *std.atomic.Value(u32),
            fn run(self: *@This()) void {
                if (self.rc.release()) _ = self.freed.fetchAdd(1, .acq_rel);
            }
        };

        var workers: [reader_count]Worker = undefined;
        var threads: [reader_count]std.Thread = undefined;
        for (&workers, 0..) |*w, i| {
            w.* = .{ .rc = &rc, .freed = &freed };
            threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        }
        for (&threads) |th| th.join();

        // Owner's terminal release.
        if (rc.release()) _ = freed.fetchAdd(1, .acq_rel);

        try testing.expectEqual(@as(u32, 1), freed.load(.acquire));
        try testing.expectEqual(@as(u32, 0), rc.refs.load(.acquire));
    }
}
