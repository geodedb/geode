const std = @import("std");
const enumz = @import("planner_enumerator");
const Context = struct {};

fn rnd(b: []const u8, idx: *usize) u8 { if (b.len == 0) return 0; const v = b[idx.* % b.len]; idx.* += 1; return v; }

fn gen_tree(b: []const u8, idx: *usize, depth: u8) enumz.LogicalPlan {
    if (depth == 0) return .{ .op = .scan, .children = &.{} };
    const op_tag: u8 = rnd(b, idx) % 7;
    const op: enumz.LogicalOp = switch (op_tag) { 0 => .scan, 1 => .filter, 2 => .project, 3 => .join, 4 => .aggregate, 5 => .sort, else => .limit };
    const nchild: usize = if (op == .join) 2 else (rnd(b, idx) % 2);
    var children_buf: [2]enumz.LogicalPlan = undefined;
    var children = children_buf[0..nchild];
    var i: usize = 0;
    while (i < nchild) : (i += 1) children[i] = gen_tree(b, idx, if (depth > 0) depth - 1 else 0);
    return .{ .op = op, .children = children };
}

fn fuzz_planner(context: Context, data: []const u8) anyerror!void {
    _ = context;
    var idx: usize = 0;
    const root = gen_tree(data, &idx, 3);
    var enum_full = enumz.PlanEnumerator.init(std.testing.allocator, .{ .enable_prune = false });
    defer enum_full.deinit();
    var list_full = std.ArrayListUnmanaged(enumz.CandidatePlan){};
    defer list_full.deinit(std.testing.allocator);
    try enum_full.enumerateUnmanaged(root, std.testing.allocator, &list_full);
    var enum_pr = enumz.PlanEnumerator.init(std.testing.allocator, .{ .enable_prune = true, .prune_factor = 4.0 });
    defer enum_pr.deinit();
    var list_pr = std.ArrayListUnmanaged(enumz.CandidatePlan){};
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
