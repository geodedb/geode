const std = @import("std");

// Test invokes governance-check script and asserts success JSON fields.
// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Backlog Accuracy"; ASPECT=GovernanceScript; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceScript; OWNER=tooling; UPDATED=2025-09-22

fn runScript(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var child = std.ChildProcess.init(&[_][]const u8{ "bash", path }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf = std.ArrayList(u8).init(alloc);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(alloc);
    defer stderr_buf.deinit();

    if (child.stdout) |*out| try stdout_buf.writer().writeAll(try out.reader().readAllAlloc(alloc, 1024 * 16));
    if (child.stderr) |*err| try stderr_buf.writer().writeAll(try err.reader().readAllAlloc(alloc, 1024 * 16));

    const term = try child.wait();
    if (term.Exited != 0) {
        std.debug.print("governance-check failed: code={} stderr={s}\n", .{ term.Exited, stderr_buf.items });
        return error.GovernanceFailed;
    }
    return try stdout_buf.toOwnedSlice();
}

pub fn main() !void {}

test "TestCANARY_REQ_GQL_010_GovernanceScript" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    const script_path = "scripts/governance-check.sh";
    const out = try runScript(alloc, script_path);
    defer alloc.free(out);

    var parser = std.json.Parser.init(alloc, .{});
    defer parser.deinit();
    var tree = try parser.parse(out);
    defer tree.deinit();

    const root = tree.root;
    try std.testing.expect(root.getType() == .object);

    const hash_node = root.object.get("hash") orelse return error.MissingHash;
    try std.testing.expect(hash_node.getType() == .string);
    try std.testing.expect(hash_node.string.len == 64);

    const next_age_node = root.object.get("next_age_sec") orelse return error.MissingFreshness;
    try std.testing.expect(next_age_node.getType() == .number);
}
