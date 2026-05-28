// Task 17 (enterprise-ingest-throughput): per-posting-list mutex regression.
//
// Before the fix: N threads calling `addToLabelIndex` on the same
// (graph, label) race on the inner `ArrayList(u64)`'s `sortedInsert` —
// data loss, crashes, or corrupted posting lists (CWE-362).
//
// After the fix: per-posting `std.Thread.Mutex` serialises inner list
// mutations; all N*M inserts land, the list stays sorted and unique.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const thread_count: usize = 16;
const per_thread: usize = 1000;

const Ctx = struct {
    store: *geode.graph_store.GraphStore,
    tid: usize,
};

fn runInsert(ctx: Ctx) !void {
    var i: usize = 0;
    while (i < per_thread) : (i += 1) {
        // Dedupe is by value; each thread owns a disjoint id range so no
        // thread's inserts can be dropped as duplicates.
        const id: u64 = @as(u64, @intCast(ctx.tid)) * per_thread + i + 1;
        try ctx.store.addToLabelIndex("default", "User", id);
    }
}

test "concurrent addToLabelIndex on same label preserves all entries" {
    var store = try geode.graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Task 17 contract: the per-posting-list mutex protects the INNER
    // ArrayList only.  The OUTER std.StringHashMap still requires the
    // per-graph `mg.rwlock` (audited in phase4-invariants.md as
    // must-be-exclusive).  Pre-populate the "default:User" key with a
    // sentinel insert so every concurrent thread's `getOrPut` hits the
    // existing-key fast path and the race surface under test is ONLY
    // the inner `sortedInsert` call — which is exactly what Task 17
    // fixes.
    try store.addToLabelIndex("default", "User", 0);

    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]Ctx = undefined;
    for (&threads, 0..) |*t, tid| {
        contexts[tid] = Ctx{ .store = &store, .tid = tid };
        t.* = try std.Thread.spawn(.{}, runInsert, .{contexts[tid]});
    }
    for (threads) |t| t.join();

    const posting = store.getNodesByLabel("default", "User") orelse
        return error.NoPosting;

    // +1 for the sentinel insert (id=0) pre-populated above.
    try testing.expectEqual(thread_count * per_thread + 1, posting.len);

    // Posting list invariant: strictly ascending (sortedInsert dedupes on
    // equality). If a concurrent mutation drops an entry or corrupts the
    // order, this check fires.  Start prev=0 is fine because the sentinel
    // id is 0 and subsequent ids all start at 1 (tid*per_thread + i + 1).
    var prev: ?u64 = null;
    for (posting) |id| {
        if (prev) |p| try testing.expect(id > p);
        prev = id;
    }
}

test "append-ordered addToLabelIndex preserves sorted fallback and dedupe" {
    var store = try geode.graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.addToLabelIndex("default", "User", 100);
    try store.addToLabelIndex("default", "User", 101);
    try store.addToLabelIndex("default", "User", 102);
    try store.addToLabelIndex("default", "User", 101);
    try store.addToLabelIndex("default", "User", 99);

    const posting = store.getNodesByLabel("default", "User") orelse
        return error.NoPosting;
    try testing.expectEqual(@as(usize, 4), posting.len);
    try testing.expectEqual(@as(u64, 99), posting[0]);
    try testing.expectEqual(@as(u64, 100), posting[1]);
    try testing.expectEqual(@as(u64, 101), posting[2]);
    try testing.expectEqual(@as(u64, 102), posting[3]);
}
