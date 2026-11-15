// SONNY-6613 item 5e: a result adopting another part's entity tracker keeps
// it even when the two free their entities differently.
//
// `adoptEntities` (query_execution.zig and optional_match.zig) merged a
// part's tracker into the result's with `absorb` when both release their
// nodes the same way, and otherwise returned, dropping the part's tracker:
// a node-scan page's tracker (whose nodes are freed in full) adopted into an
// executor's (struct only), or one on another allocator, leaked the tracker
// and every node it held. `OwnedGraphEntities.adopt`, which both now call,
// links such a tracker instead (`link`), so the result frees it with its own,
// each the way it frees.
//
// CANARY: REQ=REQ-SONNY-6613-ENTITY-ADOPT; FEATURE="ExecutionResultOwnership"; ASPECT=MismatchedTrackerLinked; STATUS=TESTED; TEST=tests/test_sonny6613_entity_adopt.zig; OWNER=execution; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const Tracker = geode.execution.OwnedGraphEntities;
const Node = geode.graph_store.Node;

fn destroyNodeInFull(allocator: std.mem.Allocator, node: *Node) void {
    allocator.destroy(node);
}

fn trackedNode(t: *Tracker) !void {
    const node = try t.allocator.create(Node);
    errdefer t.allocator.destroy(node);
    node.* = undefined;
    try t.trackNode(node);
}

test "SONNY-6613 item 5e: a tracker that frees its nodes differently is linked, not dropped" {
    const a = testing.allocator;
    var dst: ?*Tracker = try Tracker.init(a);
    defer if (dst) |d| d.deinit();
    try trackedNode(dst.?);
    const src = try Tracker.init(a);
    src.destroy_node = &destroyNodeInFull;
    trackedNode(src) catch |err| {
        src.deinit();
        return err;
    };
    try testing.expect(!dst.?.canAbsorb(src));
    try Tracker.adopt(&dst, src);
    // Both nodes and both trackers are freed by the deferred deinit; the
    // testing allocator fails the test on a leak.
}

test "SONNY-6613 item 5e: a tracker that frees its nodes the same way is absorbed" {
    const a = testing.allocator;
    var dst: ?*Tracker = try Tracker.init(a);
    defer if (dst) |d| d.deinit();
    const src = try Tracker.init(a);
    trackedNode(src) catch |err| {
        src.deinit();
        return err;
    };
    try Tracker.adopt(&dst, src);
    try testing.expectEqual(@as(usize, 1), dst.?.nodes.items.len);
    try testing.expect(dst.?.next == null);
}

test "SONNY-6613 item 5e: adopting into no tracker takes the tracker; adopting one already held changes nothing" {
    const a = testing.allocator;
    var dst: ?*Tracker = null;
    defer if (dst) |d| d.deinit();
    const src = try Tracker.init(a);
    try Tracker.adopt(&dst, src);
    try testing.expect(dst.? == src);
    try Tracker.adopt(&dst, src);
    try Tracker.adopt(&dst, null);
    try testing.expect(dst.? == src and src.next == null);
    // A linked tracker adopted again is not linked twice (a cycle).
    const other = try Tracker.init(a);
    other.destroy_node = &destroyNodeInFull;
    try Tracker.adopt(&dst, other);
    try Tracker.adopt(&dst, other);
    try testing.expect(src.next == other and other.next == null);
}
