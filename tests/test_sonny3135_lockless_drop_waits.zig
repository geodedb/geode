// SONNY-3135 N7c regression: a graph drop that holds no lock of the graph's
// still waits for the graph's lock holders.
//
// DROP GRAPH's handlers take the graph's write lock before the executor
// drops it (SONNY-3028), so the drop waits for the graph's readers and
// writers and none starts during it. Every other drop called
// `GraphStore.dropGraph` with no lock: the executor's DROP GRAPH and CREATE
// OR REPLACE GRAPH when the graph did not exist at the handler's lock
// attempt (a graph created between the attempt and the execution), or with
// no handler at all (an embedded executor), the CREATE GRAPH rollback
// (execution.zig), the HELLO auto-create rollback (QUIC and gRPC handlers)
// and SchemaManager.createGraph's rollback. `StorageAdapter.dropGraph` only
// marks a pinned graph dropped (pins keep its holders memory-safe), so such
// a drop returned at once while another request held the graph: that
// request's writes went to a dropped graph, and it reported success.
//
// Now `GraphStore.dropGraph` takes the graph's write lock itself when the
// calling thread does not hold it, and drops under it.
//
// CANARY: REQ=REQ-SONNY-3135-LOCKLESS-DROP-WAITS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3135_lockless_drop_waits.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

fn monoMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn expectDropWaitsFor(f: *fx.Fixture, graph: []const u8, write: bool) !void {
    try f.st.createGraph(graph);
    var holder: fx.Holder = .{ .graph = graph, .write = write, .hold_ms = 500 };
    const t = try holder.start();
    // The lockless drop every non-handler site makes.
    const t0 = monoMs();
    const drop_result = f.st.dropGraph(graph);
    const elapsed = monoMs() - t0;
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try drop_result;
    if (!waited) {
        std.debug.print("GraphStore.dropGraph of '{s}' returned after {d} ms while another thread held its {s} lock\n", .{ graph, elapsed, if (write) "write" else "read" });
        return error.DropDidNotWaitForHolder;
    }
    try testing.expect(!f.st.graphExists(graph));
}

test "SONNY-3135 N7c: a drop with no lock of the graph waits for a holder of its write lock" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDropWaitsFor(&f, "n7c_w", true);
}

test "SONNY-3135 N7c: a drop with no lock of the graph waits for a holder of its read lock" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDropWaitsFor(&f, "n7c_r", false);
}

test "SONNY-3135 N7c: the executor's DROP GRAPH with no handler lock waits for the graph's lock holders" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.st.createGraph("n7c_exec");
    var holder: fx.Holder = .{ .graph = "n7c_exec", .write = true, .hold_ms = 500 };
    const t = try holder.start();
    var r = f.h.run("DROP GRAPH n7c_exec");
    const waited = holder.letting_go.load(.acquire);
    t.join();
    if (r) |*res| res.deinit(f.h.arena.allocator()) else |err| return err;
    if (!waited) return error.DropDidNotWaitForHolder;
    try testing.expect(!f.st.graphExists("n7c_exec"));
}

const SelfDrop = struct {
    graph: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn go(self: *SelfDrop, st: *graph_store.GraphStore) void {
        const lock = graph_store.acquireGraphWriteLock(self.graph);
        st.dropGraph(self.graph) catch self.failed.store(true, .release);
        graph_store.releaseGraphLock(lock);
        self.done.store(true, .release);
    }
};

test "SONNY-3135 N7c: a thread that holds the graph's write lock drops it without waiting for itself" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.st.createGraph("n7c_self");
    var sd: SelfDrop = .{ .graph = "n7c_self" };
    const t = try std.Thread.spawn(.{}, SelfDrop.go, .{ &sd, f.st });
    const t0 = monoMs();
    while (!sd.done.load(.acquire) and monoMs() - t0 < 10_000) fx.sleepMs(5);
    if (!sd.done.load(.acquire)) {
        // Deadlocked on its own lock: leave the thread, fail loud.
        t.detach();
        std.debug.print("dropGraph under the caller's own write lock did not return in 10 s\n", .{});
        return error.SelfDeadlock;
    }
    t.join();
    try testing.expect(!sd.failed.load(.acquire));
    try testing.expect(!f.st.graphExists("n7c_self"));
}

test "SONNY-3135 N7c: a drop of a graph that is not there takes no lock and creates nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectError(error.GraphNotFound, f.st.dropGraph("n7c_missing"));
    try testing.expect(!f.st.graphExists("n7c_missing"));
}
