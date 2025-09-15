const std = @import("std");
const testing = std.testing;

// Helper to spawn geoded and interact via stdin/stdout JSON line protocol.
fn runSession(script: []const []const u8) !struct { stdout: []u8, stderr: []u8, exit_code: i32 } {
    var gpa = std.heap.page_allocator;
    const exe_path = try std.fs.path.join(gpa, &.{ "zig-out", "bin", "geoded" });
    defer gpa.free(exe_path);
    var child = std.process.Child.init(&.{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdin_writer = child.stdin.?.writer();
    const stdout_reader = child.stdout.?.reader();
    const stderr_reader = child.stderr.?.reader();
    // Send HELLO first (empty capabilities)
    try stdin_writer.print("{s}\n", .{"{\"type\":\"HELLO\"}"});
    // Read and ignore HELLO response (may be empty if server no-op)
    var buf: [8192]u8 = undefined;
    _ = stdout_reader.read(&buf) catch 0; // non-fatal
    // Execute script lines
    for (script) |line| {
        try stdin_writer.print("{s}\n", .{line});
    }
    // Close stdin to signal EOF
    child.stdin.?.close();
    // Collect remaining stdout/stderr
    var out_bytes = std.ArrayList(u8).init(gpa);
    defer out_bytes.deinit();
    while (true) {
        const n = stdout_reader.read(&buf) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => 0,
        };
        if (n == 0) break;
        try out_bytes.appendSlice(buf[0..n]);
    }
    var err_bytes = std.ArrayList(u8).init(gpa);
    defer err_bytes.deinit();
    while (true) {
        const n = stderr_reader.read(&buf) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => 0,
        };
        if (n == 0) break;
        try err_bytes.appendSlice(buf[0..n]);
    }
    const term = try child.wait();
    return .{ .stdout = try out_bytes.toOwnedSlice(), .stderr = try err_bytes.toOwnedSlice(), .exit_code = term.Exited }; // Exited variant holds code
}

// Expect sequence:
// 1) BEGIN -> empty bindings frame
// 2) Nested BEGIN -> TxnState error
// 3) RUN_GQL simple query inside txn -> SCHEMA + BINDINGS
// 4) COMMIT -> empty bindings frame
// 5) ROLLBACK (after commit) -> TxnState error
// We assert presence/order heuristically via substring counts.

test "transactions e2e basic lifecycle" {
    const script = &.{
        // BEGIN
        "{\"type\":\"BEGIN\"}",
        // nested BEGIN (error)
        "{\"type\":\"BEGIN\"}",
        // simple query inside txn
        "{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS x ORDER BY x LIMIT 1\"}",
        // COMMIT
        "{\"type\":\"COMMIT\"}",
        // ROLLBACK after commit (error)
        "{\"type\":\"ROLLBACK\"}",
    };
    const res = try runSession(script);
    defer std.heap.page_allocator.free(res.stdout);
    defer std.heap.page_allocator.free(res.stderr);
    try testing.expect(res.exit_code == 0);
    const out = res.stdout;
    // Must contain two TxnState errors (nested begin + rollback after commit)
    const err_count = std.mem.count(u8, out, "TxnState");
    try testing.expect(err_count >= 2);
    // Must contain SCHEMA for the query
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
    // Must contain BINDINGS row with x=1
    try testing.expect(std.mem.indexOf(u8, out, "{\"x\":1}") != null);
}
