const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Environment already set globally
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchGuardStatusWireMapping"; ASPECT=Wire; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchGuardStatusWireMapping; OWNER=engine; UPDATED=2025-09-25
// This test triggers the result guard (max_results=1) and expects ExecutionGuardTrip to appear in additional_statuses
// on either the SCHEMA frame (now preferred) or the first BINDINGS frame produced by geodec after a MATCH query.

fn makeQuery() []const u8 {
    // Small MATCH expected to produce >1 row; limit results guard artificially low via pragma-like hint (future)
    // For now we rely on default options in engine test harness accepting env vars; simulate by using a varlen path that expands.
    // Remove LIMIT/OFFSET to avoid parser differences; ordering ensures deterministic comparator; guard triggers after first row.
    return "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b ORDER BY a";
}

test "protocol: MATCH guard trip surfaces additional ExecutionGuardTrip" {
    const exe = "./zig-out/bin/geode";
    const server = "./zig-out/bin/geode"; // spawn server as child so env override propagates
    const q = makeQuery();
    // Pass server path to force stdio spawn; include --server before args per geodec usage.
    const res = try run(&.{ exe, q, "--server", server", "--server-arg", "--match-max-results", "--server-arg", "1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Success exit (0) or partial success (0) expected; guard trip should not force non-zero exit (engine treats it as warning-class)
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Presence of additional_statuses with ExecutionGuardTrip token either in stdout (bindings frame) or stderr (if logged)
    const combined = res.out; // geodec prints frames to stdout; diagnostics to stderr only for errors
    try std.testing.expect(std.mem.indexOf(u8, combined, "ExecutionGuardTrip") != null);
    // Ensure additional_statuses array present
    try std.testing.expect(std.mem.indexOf(u8, combined, "additional_statuses") != null);
}
