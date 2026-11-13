// SONNY-3148 (node-copy amplification): the write step's
// `WrittenElements.refresh` took a fresh detached copy of a written node
// (`getNodePtrForScan`) every time it refreshed a cell holding it: at the
// start of every later row, after every SET clause group and REMOVE, and
// once more for the RETURN. Each copy lives in the store's detached-box list
// until the graph's next grace boundary (a checkpoint) and is charged to the
// statement's write budget, so a written row retained several copies of its
// node, and a node every row binds one copy per row per refresh. A refresh
// now reuses the copy it took for a node until the node is written again.
//
// Measured on an in-memory session (no background checkpoint frees the
// boxes mid-statement): the detached boxes a statement leaves and their
// approximate bytes (the write budget's own estimate), per written row. Each
// statement also runs on a leak-checking allocator and its answer is checked.
//
// CANARY: REQ=REQ-SONNY-3148-WRITE-STEP-AMPLIFICATION; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3148_write_step_amplification.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("statement_leak_harness.zig");

const graph_store = geode.graph_store;

const rows: usize = 32;

fn approxBytes(node: *const graph_store.Node) u64 {
    var total: u64 = @sizeOf(graph_store.Node) + node.graph_name.len;
    for (node.labels) |l| total += l.len + @sizeOf([]const u8);
    var it = node.properties.iterator();
    while (it.next()) |entry| {
        total += 64 + entry.key_ptr.len;
        total += switch (entry.value_ptr.*) {
            .String => |s| s.len,
            else => @as(u64, 16),
        };
    }
    return total;
}

const Measure = struct { boxes: usize, bytes: u64 };

/// The detached boxes `q` leaves in the store, and their bytes; its answer
/// must be `want` and it must not leak.
fn measure(s: *h.Session, q: []const u8, want: []const []const u8) !Measure {
    const store = graph_store.getWritableGlobalStore(testing.allocator);
    const before = store.scan_hydrated_nodes.items.len;
    var f: h.Failures = .{};
    defer f.deinit();
    try h.checkCase(s, &f, .{ .q = q, .want = want, .only = &.{.in_memory} });
    try f.check(q);
    const after = store.scan_hydrated_nodes.items;
    var bytes: u64 = 0;
    for (after[before..]) |box| bytes += approxBytes(box);
    return .{ .boxes = after.len - before, .bytes = bytes };
}

test "SONNY-3148: a written row keeps one detached copy per write, not one per refresh" {
    var s = try h.Session.init(.in_memory);
    defer s.deinit();
    var seed: std.ArrayList([]const u8) = .empty;
    const aa = s.arena.allocator();
    for (0..rows) |i| try seed.append(aa, try std.fmt.allocPrint(aa, "CREATE (:W {{i: {d}, pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'}})", .{i}));
    try seed.append(aa, "CREATE (:M {k: 1, c: 0})");
    try s.seed(seed.items, &.{});

    var want_x: std.ArrayList([]const u8) = .empty;
    for (0..rows) |i| try want_x.append(aa, try std.fmt.allocPrint(aa, "{d}", .{i + 1}));

    // Each case runs twice (with and without a scratch arena): halve.
    const one_group = try measure(&s, "MATCH (n:W) SET n.x = n.i + 1 RETURN n.x", want_x.items);
    const two_groups = try measure(&s, "MATCH (n:W) SET n.x = n.i SET n.y = n.x + 1 RETURN n.y", want_x.items);
    const per_row_one = @as(f64, @floatFromInt(one_group.boxes)) / @as(f64, @floatFromInt(2 * rows));
    const per_row_two = @as(f64, @floatFromInt(two_groups.boxes)) / @as(f64, @floatFromInt(2 * rows));
    std.debug.print("\nSONNY-3148: one SET group: {d} boxes ({d:.2}/row), {d} bytes ({d}/row)\n", .{ one_group.boxes, per_row_one, one_group.bytes, one_group.bytes / (2 * rows) });
    std.debug.print("SONNY-3148: two SET groups: {d} boxes ({d:.2}/row), {d} bytes ({d}/row)\n", .{ two_groups.boxes, per_row_two, two_groups.bytes, two_groups.bytes / (2 * rows) });

    // One copy when the row is read, one per clause group that writes it;
    // the RETURN reuses the last.
    try testing.expect(per_row_one <= 2.0);
    try testing.expect(per_row_two <= 3.0);
}
