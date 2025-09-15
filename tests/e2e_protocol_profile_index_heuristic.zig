const std = @import("std");
const testing = std.testing;
const util = @import("e2e_protocol_profile_schema_json.zig"); // reuse runCli helper if present

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    return .{ .code = if (term == .Exited) term.Exited else 2, .out = out };
}

// Ensures PROFILE output includes NodeIndexScan when heuristic conditions (WHERE + '=') present.
// Heuristic uses captured query_text (post PROFILE/EXPLAIN strip) stored in ServerState.
// Simple predicate is sufficient to trigger naming substitution.
// Accept either NodeIndexScan or NodeScan if heuristic disabled in future (soft assert path).
// Hard assert for now to exercise path.

test "profile heuristic emits NodeIndexScan" {
    const exe = "./zig-out/bin/geodec";
    const q = "PROFILE RETURN 1 AS x WHERE x=1"; // includes WHERE and '='
    const res = try run(&.{ exe, q });
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
    // Metadata fields should be present
    try testing.expect(std.mem.indexOf(u8, res.out, "\"index_name\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.out, "selectivity_est") != null);
}
