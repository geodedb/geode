// SONNY-6425 item 5: `GraphStore.dropGraph` called by a thread that holds
// the graph's READ lock refuses (`error.ObjectInUse`) instead of waiting
// forever for its own lock.
//
// Since SONNY-3135 (N7c) the drop takes the graph's write lock unless the
// calling thread already holds it. A thread holding the read lock waited
// for itself: the writer-preferring acquire never completes while that
// thread's shared hold is open. No caller does this today; the refusal
// makes a future one fail loud instead of hanging the server thread (and,
// with it, every writer of the graph queued behind the pending exclusive).
//
// CANARY: REQ=REQ-SONNY-6425-DROP-OWN-READ-LOCK; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6425_drop_under_own_read_lock.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

fn monoMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const ReadThenDrop = struct {
    graph: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?anyerror = null,

    fn go(self: *ReadThenDrop, st: *graph_store.GraphStore) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        if (st.dropGraph(self.graph)) |_| {
            self.result = null;
        } else |err| {
            self.result = err;
        }
        graph_store.releaseGraphLock(lock);
        self.done.store(true, .release);
    }
};

test "SONNY-6425 item 5: dropGraph under the caller's own read lock refuses instead of deadlocking" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.st.createGraph("s6425_self_read");
    var rd: ReadThenDrop = .{ .graph = "s6425_self_read" };
    const t = try std.Thread.spawn(.{}, ReadThenDrop.go, .{ &rd, f.st });
    const t0 = monoMs();
    while (!rd.done.load(.acquire) and monoMs() - t0 < 10_000) fx.sleepMs(5);
    if (!rd.done.load(.acquire)) {
        // Waiting for its own read lock: leave the thread, fail loud.
        t.detach();
        std.debug.print("dropGraph under the caller's own read lock did not return in 10 s\n", .{});
        return error.SelfDeadlock;
    }
    t.join();
    try testing.expectEqual(@as(?anyerror, error.ObjectInUse), rd.result);
    // Refused before anything was dropped.
    try testing.expect(f.st.graphExists("s6425_self_read"));
    // With the read lock released, the same drop goes through.
    try f.st.dropGraph("s6425_self_read");
    try testing.expect(!f.st.graphExists("s6425_self_read"));
}

test "SONNY-6425 item 5: a read lock of ANOTHER graph does not refuse the drop" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.st.createGraph("s6425_other_a");
    try f.st.createGraph("s6425_other_b");
    const lock = graph_store.acquireGraphReadLock("s6425_other_a");
    defer graph_store.releaseGraphLock(lock);
    try f.st.dropGraph("s6425_other_b");
    try testing.expect(!f.st.graphExists("s6425_other_b"));
    try testing.expect(f.st.graphExists("s6425_other_a"));
}
