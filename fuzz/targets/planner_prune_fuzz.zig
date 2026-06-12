const std = @import("std");
const enumz = @import("planner_enumerator");
const Context = struct {};

fn rnd(b: []const u8, idx: *usize) u8 {
    if (b.len == 0) return 0;
    const v = b[idx.* % b.len];
    idx.* += 1;
    return v;
}

// GAP-0883 review fix: children must be heap-allocated. The previous version
// returned a slice of a stack-local `children_buf`, so every non-leaf plan's
// children dangled once gen_tree returned.
fn gen_tree(allocator: std.mem.Allocator, b: []const u8, idx: *usize, depth: u8) std.mem.Allocator.Error!enumz.LogicalPlan {
    if (depth == 0) return .{ .op = .scan, .children = &.{} };
    const op_tag: u8 = rnd(b, idx) % 7;
    const op: enumz.LogicalOp = switch (op_tag) {
        0 => .scan,
        1 => .filter,
        2 => .project,
        3 => .join,
        4 => .aggregate,
        5 => .sort,
        else => .limit,
    };
    const nchild: usize = if (op == .join) 2 else (rnd(b, idx) % 2);
    const children = try allocator.alloc(enumz.LogicalPlan, nchild);
    for (children) |*child| child.* = try gen_tree(allocator, b, idx, depth - 1);
    return .{ .op = op, .children = children };
}

// Zig 0.16: std.testing.fuzz hands the test a *Smith generator instead of a
// raw byte slice.  Draw a fuzzer-controlled byte slice from the Smith and
// feed it to the original byte-driven harness.
fn fuzz_planner(context: Context, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    try fuzz_planner_bytes(context, buf[0..len]);
}

fn fuzz_planner_bytes(context: Context, data: []const u8) anyerror!void {
    _ = context;
    var idx: usize = 0;
    var tree_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tree_arena.deinit();
    const root = try gen_tree(tree_arena.allocator(), data, &idx, 3);
    var enum_full = enumz.PlanEnumerator.init(std.testing.allocator, .{ .enable_prune = false });
    defer enum_full.deinit();
    var list_full: std.ArrayListUnmanaged(enumz.CandidatePlan) = .empty;
    defer list_full.deinit(std.testing.allocator);
    try enum_full.enumerateUnmanaged(root, std.testing.allocator, &list_full);
    var enum_pr = enumz.PlanEnumerator.init(std.testing.allocator, .{ .enable_prune = true, .prune_factor = 4.0 });
    defer enum_pr.deinit();
    var list_pr: std.ArrayListUnmanaged(enumz.CandidatePlan) = .empty;
    defer list_pr.deinit(std.testing.allocator);
    try enum_pr.enumerateUnmanaged(root, std.testing.allocator, &list_pr);
    if (list_pr.items.len > list_full.items.len) return error.Unexpected;
    if (list_full.items.len > 0 and list_pr.items.len > 0) {
        var best_full = list_full.items[0].cost;
        for (list_full.items) |cp| {
            if (cp.cost < best_full) best_full = cp.cost;
        }
        var best_pr = list_pr.items[0].cost;
        for (list_pr.items) |cp| {
            if (cp.cost < best_pr) best_pr = cp.cost;
        }
        if (best_pr > best_full * 4.0 + 1e-9) return error.Unexpected;
    }
}

test "fuzz planner prune" {
    try std.testing.fuzz(Context{}, fuzz_planner, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
