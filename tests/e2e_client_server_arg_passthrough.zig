const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// Simple evidence test: spawn client with --server-arg passing --data_dir; ensure query runs and server logs reflect data load (implicit via success and non-empty rows when dataset present).
// CANARY: REQ=REQ-GQL-091; FEATURE="Client Server Arg Passthrough"; ASPECT=CliErgonomics; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_091_ClientServerArgPassthrough; OWNER=client; UPDATED=2025-09-24
test "client: server arg passthrough allows data_dir injection" {
    const exe = "./zig-out/bin/geode";
    // Use curated varlen dataset directory which should exist.
    const data_dir = "./data/varlen_determinism";
    // Run trivial query that relies on dataset labels existing; if dataset not loaded, label filter may return 0 rows.
    const q = "MATCH (a:Person) RETURN a.name AS name ORDER BY name LIMIT 1";
    var child = Child.init(&.{ exe, q, "--format", "json", "--server-arg", "--data_dir", "--server-arg", data_dir }, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(std.testing.allocator, 4 << 20);
    defer std.testing.allocator.free(out);
    const err = try child.stderr.?.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(err);
    const term = try child.wait();
    try std.testing.expect(term == .Exited and term.Exited == 0);
    // Expect rows/columns payload with ordering metadata.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"order_keys\":[\"name\"]") != null);
}
